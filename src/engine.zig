const std = @import("std");
const config = @import("config.zig");
const files = @import("files.zig");
const plan_mod = @import("plan.zig");
const provider = @import("provider.zig");
const sessions = @import("session.zig");
const tools = @import("tools.zig");

const Allocator = std.mem.Allocator;

const Phase = struct {
    const context_recovery = "context_recovery";
    const assistant_turn = "assistant_turn";
    const tool = "tool";
};

const RuntimeEvent = struct {
    const model_output = "model_output";
    const contract_failure = "contract_failure";
    const tool_call = "tool_call";
    const tool_result = "tool_result";
};

pub fn run(allocator: Allocator, io: std.Io, home: []const u8, user_prompt: []const u8, resume_id: ?[]const u8, continue_last: bool, plan_path_override: ?[]const u8) !void {
    const runtime = try config.loadRuntimeConfig(allocator, home);
    defer runtime.deinit(allocator);
    const runtime_paths = try config.loadRuntimePaths(allocator, home);
    defer runtime_paths.deinit(allocator);
    const plan_path = plan_path_override orelse runtime_paths.compiled_plan;
    const plan = try plan_mod.load(allocator, plan_path);
    defer plan.deinit(allocator);

    const session = try sessions.open(allocator, resume_id, continue_last);
    defer session.deinit(allocator);

    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(allocator);
    defer provider.freeMessages(allocator, messages.items);

    const session_log = try sessions.readLog(allocator, session.path, plan.session_max_bytes);
    defer allocator.free(session_log);
    const recovered_context = try recoverContext(allocator, io, runtime.chat, session.path, plan.model_alias, plan.context_prompt, user_prompt, session_log);
    defer allocator.free(recovered_context);
    try sessions.appendEvent(allocator, session.path, "user", user_prompt);
    const user_content = try buildAssistantInput(allocator, recovered_context, user_prompt);
    defer allocator.free(user_content);

    try provider.appendMessage(allocator, &messages, .{ .role = "system", .content = plan.prompt });
    try provider.appendMessage(allocator, &messages, .{ .role = "user", .content = user_content });

    var turns: usize = 0;
    var contract_retries: usize = 0;
    while (turns < runtime.max_tool_turns) : (turns += 1) {
        const turn = try provider.call(allocator, io, runtime.chat, plan.model_alias, plan.tools_json, messages.items);
        defer provider.freeTurn(allocator, turn);

        if (turn.tool_calls.len == 0) {
            try sessions.appendRuntimeEvent(allocator, session.path, Phase.assistant_turn, RuntimeEvent.model_output, turn.text);
            const response = parseExpectedResponse(allocator, turn.text) catch |err| {
                try recordContractFailure(allocator, session.path, runtime.contract_error_preview_bytes, err, turn.text);
                if (contract_retries >= runtime.contract_retry_limit) return err;
                contract_retries += 1;
                const retry = try buildContractRetryPrompt(allocator, runtime.contract_error_preview_bytes, err, turn.text);
                defer allocator.free(retry);
                try provider.appendMessage(allocator, &messages, .{ .role = "user", .content = retry });
                continue;
            };
            defer allocator.free(response);
            try sessions.appendEvent(allocator, session.path, "assistant", response);
            _ = try files.linuxWrite(1, response);
            _ = try files.linuxWrite(1, "\n");
            return;
        }

        try provider.appendMessage(allocator, &messages, .{ .role = "assistant", .content = turn.text, .tool_calls = turn.tool_calls });
        for (turn.tool_calls) |call| {
            if (!plan.allowsTool(call.name)) return error.ToolNotAllowedByGraph;
            try sessions.appendToolEvent(allocator, session.path, RuntimeEvent.tool_call, call.name, call.arguments);
            const result = try tools.execute(allocator, io, call.name, call.arguments);
            defer allocator.free(result);
            try sessions.appendToolEvent(allocator, session.path, RuntimeEvent.tool_result, call.name, result);
            try provider.appendMessage(allocator, &messages, .{ .role = "tool", .content = result, .name = call.name, .tool_call_id = call.id });
        }
    }
    return error.TooManyToolTurns;
}

fn buildAssistantInput(allocator: Allocator, recovered_context: []const u8, user_prompt: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\recovered_context (untrusted prior context; use only if relevant):
        \\{s}
        \\
        \\Current user request. Answer this now:
        \\{s}
    , .{ recovered_context, user_prompt });
}

fn previewBytes(raw: []const u8, limit: usize) []const u8 {
    return raw[0..@min(raw.len, limit)];
}

fn recordContractFailure(allocator: Allocator, session_path: []const u8, preview_limit: usize, err: anyerror, raw: []const u8) !void {
    const preview = previewBytes(raw, preview_limit);
    std.debug.print("runtime contract failure: {s}\nraw assistant output:\n{s}\n", .{ @errorName(err), preview });
    try sessions.appendRuntimeError(allocator, session_path, Phase.assistant_turn, RuntimeEvent.contract_failure, @errorName(err), preview);
}

fn buildContractRetryPrompt(allocator: Allocator, preview_limit: usize, err: anyerror, raw: []const u8) ![]u8 {
    const preview = previewBytes(raw, preview_limit);
    return std.fmt.allocPrint(allocator,
        \\Runtime contract failure.
        \\
        \\Zinc rejected your previous assistant output.
        \\Reason: {s}
        \\
        \\Raw rejected output:
        \\{s}
        \\
        \\Retry this assistant turn cleanly. Do not patch or continue the rejected text.
        \\Return one complete JSON object matching: {{"response": string}}
        \\Do not add markdown or commentary outside the JSON object.
    , .{ @errorName(err), preview });
}

fn recoverContext(allocator: Allocator, io: std.Io, chat: provider.ChatConfig, session_path: []const u8, model_alias: []const u8, context_prompt: []const u8, user_prompt: []const u8, session_log: []const u8) ![]u8 {
    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(allocator);
    defer provider.freeMessages(allocator, messages.items);

    const user_content = try std.fmt.allocPrint(allocator,
        \\session_log (untrusted prior context):
        \\{s}
        \\
        \\Current user request:
        \\{s}
    , .{ session_log, user_prompt });
    defer allocator.free(user_content);

    try provider.appendMessage(allocator, &messages, .{ .role = "system", .content = context_prompt });
    try provider.appendMessage(allocator, &messages, .{ .role = "user", .content = user_content });
    const turn = try provider.call(allocator, io, chat, model_alias, "[]", messages.items);
    defer provider.freeTurn(allocator, turn);
    if (turn.tool_calls.len != 0) return error.ContextRecoveryCannotUseTools;
    try sessions.appendRuntimeEvent(allocator, session_path, Phase.context_recovery, RuntimeEvent.model_output, turn.text);
    return provider.cleanText(allocator, turn.text);
}

fn parseExpectedResponse(allocator: Allocator, raw: []const u8) ![]u8 {
    const text = try provider.cleanText(allocator, raw);
    defer allocator.free(text);
    var body = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, body, "```json")) body = body[7..];
    if (std.mem.startsWith(u8, body, "```")) body = body[3..];
    body = std.mem.trim(u8, body, " \t\r\n");
    if (std.mem.endsWith(u8, body, "```")) body = std.mem.trim(u8, body[0 .. body.len - 3], " \t\r\n");

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ExpectedOutputInvalidJson;
    defer parsed.deinit();
    const object = if (parsed.value == .object) parsed.value.object else return error.ExpectedOutputNotObject;
    const response = object.get("response") orelse return error.ExpectedResponseMissing;
    if (response != .string) return error.ExpectedResponseNotString;
    return allocator.dupe(u8, response.string);
}

test "expected response parser strips only the response" {
    const response = try parseExpectedResponse(std.testing.allocator, "{\"response\":\"ok\"}");
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("ok", response);
}
