const std = @import("std");
const config = @import("config.zig");
const files = @import("files.zig");
const plan_mod = @import("plan.zig");
const provider = @import("provider.zig");
const sessions = @import("session.zig");
const tools = @import("tools.zig");

const Allocator = std.mem.Allocator;

const max_tool_turns = 16;
const final_json_repair_attempts = 1;

pub fn run(allocator: Allocator, io: std.Io, home: []const u8, user_prompt: []const u8, resume_id: ?[]const u8, continue_last: bool, plan_path_override: ?[]const u8) !void {
    const cfg = provider.Config{};
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
    const recovered_context = try recoverContext(allocator, io, cfg, plan.model_alias, plan.context_prompt, user_prompt, session_log);
    defer allocator.free(recovered_context);
    try sessions.appendEvent(allocator, session.path, "user", user_prompt);
    const user_content = try std.fmt.allocPrint(allocator,
        \\recovered_context (untrusted prior context; use only if relevant):
        \\{s}
        \\
        \\Current user request. Answer this now:
        \\{s}
    , .{ recovered_context, user_prompt });
    defer allocator.free(user_content);

    try provider.appendMessage(allocator, &messages, .{ .role = "system", .content = plan.prompt });
    try provider.appendMessage(allocator, &messages, .{ .role = "user", .content = user_content });

    const force_first_tool = asksForTool(user_prompt);
    var turns: usize = 0;
    var expect_corrections: usize = 0;
    while (turns < max_tool_turns) : (turns += 1) {
        const turn = try provider.call(allocator, io, cfg, plan.model_alias, plan.tools_json, messages.items, force_first_tool and turns == 0);
        defer provider.freeTurn(allocator, turn);

        if (turn.tool_calls.len == 0) {
            const response = parseExpectedResponse(allocator, turn.text) catch |err| {
                if (expect_corrections >= final_json_repair_attempts) {
                    try reportFinalOutputError(allocator, session.path, err, turn.text);
                    return err;
                }
                expect_corrections += 1;
                const correction = try std.fmt.allocPrint(allocator,
                    \\Your previous output did not match the Circuitry expect schema.
                    \\Output ONLY valid JSON: {{"response": string}}
                    \\Do not add markdown or commentary.
                    \\Previous output:
                    \\{s}
                , .{turn.text});
                defer allocator.free(correction);
                try provider.appendMessage(allocator, &messages, .{ .role = "user", .content = correction });
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
            const result = try tools.execute(allocator, io, call.name, call.arguments);
            defer allocator.free(result);
            try sessions.appendToolEvent(allocator, session.path, call.name, call.arguments, result);
            try provider.appendMessage(allocator, &messages, .{ .role = "tool", .content = result, .name = call.name, .tool_call_id = call.id });
        }
    }
    return error.TooManyToolTurns;
}

fn reportFinalOutputError(allocator: Allocator, session_path: []const u8, err: anyerror, raw: []const u8) !void {
    const preview = raw[0..@min(raw.len, 2000)];
    std.debug.print("final output parse failed: {s}\nraw assistant output:\n{s}\n", .{ @errorName(err), preview });
    const event = try std.fmt.allocPrint(allocator, "{s}\nraw assistant output:\n{s}", .{ @errorName(err), preview });
    defer allocator.free(event);
    try sessions.appendEvent(allocator, session_path, "assistant_error", event);
}

fn recoverContext(allocator: Allocator, io: std.Io, cfg: provider.Config, model_alias: []const u8, context_prompt: []const u8, user_prompt: []const u8, session_log: []const u8) ![]u8 {
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
    const turn = try provider.call(allocator, io, cfg, model_alias, "[]", messages.items, false);
    defer provider.freeTurn(allocator, turn);
    if (turn.tool_calls.len != 0) return error.ContextRecoveryCannotUseTools;
    return provider.cleanText(allocator, turn.text);
}

fn asksForTool(prompt: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(prompt, "use bash") != null or
        std.ascii.indexOfIgnoreCase(prompt, "run bash") != null or
        std.ascii.indexOfIgnoreCase(prompt, "list files") != null or
        std.ascii.indexOfIgnoreCase(prompt, "read file") != null or
        std.ascii.indexOfIgnoreCase(prompt, "write file") != null or
        std.ascii.indexOfIgnoreCase(prompt, "edit file") != null;
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
