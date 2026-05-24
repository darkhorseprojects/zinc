const std = @import("std");
const compaction = @import("compaction.zig");
const config = @import("config.zig");
const context = @import("context.zig");
const files = @import("files.zig");
const plan_mod = @import("plan.zig");
const provider = @import("provider.zig");
const sessions = @import("session.zig");
const tools = @import("tools.zig");

const Allocator = std.mem.Allocator;

const Phase = struct {
    const assistant_turn = "assistant_turn";
    const tool = "tool";
};

const RuntimeEvent = struct {
    const model_output = "model_output";
    const contract_failure = "contract_failure";
    const retryable_failure = "retryable_failure";
    const tool_call = "tool_call";
    const tool_result = "tool_result";
};

const local_auth_header = "Bearer zinc";

const RuntimeReadContext = struct {
    prompts: []const plan_mod.PromptPack,
    session_id: []const u8,
    session_path: []const u8,
    session_dir: []const u8,
    session_log: []const u8,
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

    var session_log = try sessions.readLog(allocator, session.path);
    defer allocator.free(session_log);
    if (try shouldCompact(allocator, session_log, plan.context_tokens, runtime.compaction_threshold_percent)) {
        _ = try compaction.runGraph(allocator, io, home, session, runtime.compaction_graph);
        allocator.free(session_log);
        session_log = try sessions.readLog(allocator, session.path);
    }

    const prior_context_text = try context.buildPriorContextText(allocator, session_log);
    defer allocator.free(prior_context_text);
    const session_dir = std.fs.path.dirname(session.path) orelse ".zinc/sessions";
    const focused_context = try recoverFocusedContext(allocator, io, runtime.provider_base_url, runtime.max_retries, session.path, plan.model_alias, plan.temperature, plan.max_tokens, plan.tool_format, plan.focused_recovery_prompt, plan.focused_recovery_tools, plan.focused_recovery_tools_json, prior_context_text, user_prompt, session_dir);
    defer allocator.free(focused_context);
    const read_context = RuntimeReadContext{
        .prompts = plan.prompts,
        .session_id = session.id,
        .session_path = session.path,
        .session_dir = session_dir,
        .session_log = session_log,
    };
    const runtime_uri_catalog = try buildRuntimeUriCatalog(allocator, read_context);
    defer allocator.free(runtime_uri_catalog);
    const system_prompt = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ plan.prompt, runtime_uri_catalog });
    defer allocator.free(system_prompt);

    try provider.appendMessage(allocator, &messages, .{ .role = "system", .content = system_prompt });
    try context.appendPriorContext(allocator, &messages, session_log, focused_context);
    try provider.appendMessage(allocator, &messages, .{ .role = "user", .content = user_prompt });

    try sessions.appendEvent(allocator, session.path, "user", user_prompt);
    try sessions.rememberLast(session);

    var correction_retries: usize = 0;
    while (true) {
        const turn = try callProviderWithTransientRetries(allocator, io, session.path, Phase.assistant_turn, runtime.max_retries, .{
            .base_url = runtime.provider_base_url,
            .authorization = local_auth_header,
            .model = plan.model_alias,
            .temperature = plan.temperature,
            .max_tokens = plan.max_tokens,
            .reasoning_format = plan.reasoning_format,
            .reasoning_budget_tokens = reasoningBudgetTokens(plan.reasoning_tokens),
            .thinking_enabled = reasoningEnabled(plan.reasoning_tokens),
            .parse_native_tools = std.mem.eql(u8, plan.tool_format, "gemma-native"),
            .tools_json = plan.tools_json,
            .messages = messages.items,
        });
        defer provider.freeTurn(allocator, turn);

        if (turn.tool_calls.len == 0) {
            const response = std.mem.trim(u8, turn.text, " \t\r\n");
            try sessions.appendRuntimeEvent(allocator, session.path, Phase.assistant_turn, RuntimeEvent.model_output, response);
            if (response.len == 0) {
                try recordContractFailure(allocator, session.path, error.EmptyAssistantResponse, turn.text);
                if (correction_retries >= runtime.max_retries) return error.EmptyAssistantResponse;
                correction_retries += 1;
                const retry = try buildContractRetryPrompt(allocator, error.EmptyAssistantResponse, turn.text);
                defer allocator.free(retry);
                try provider.appendMessage(allocator, &messages, .{ .role = "user", .content = retry });
                continue;
            }
            if (looksLikeTextToolCall(response, plan.tools)) {
                try recordContractFailure(allocator, session.path, error.TextToolCall, response);
                if (correction_retries >= runtime.max_retries) return error.TextToolCall;
                correction_retries += 1;
                const retry = try buildTextToolCallRetryPrompt(allocator, response);
                defer allocator.free(retry);
                try provider.appendMessage(allocator, &messages, .{ .role = "user", .content = retry });
                continue;
            }
            try sessions.appendEvent(allocator, session.path, "assistant", response);
            _ = try files.linuxWrite(1, response);
            _ = try files.linuxWrite(1, "\n");
            return;
        }

        if (try logAndReportUnreplayableToolCall(allocator, session.path, plan.tools, turn.tool_calls, &messages, runtime.max_retries, &correction_retries)) continue;
        try provider.appendMessage(allocator, &messages, .{ .role = "assistant", .content = turn.text, .tool_calls = turn.tool_calls });
        if (turn.reasoning.len > 0) {
            try sessions.appendRuntimeEvent(allocator, session.path, Phase.assistant_turn, RuntimeEvent.model_output, turn.reasoning);
        }
        for (turn.tool_calls) |call| {
            try sessions.appendToolEvent(allocator, session.path, RuntimeEvent.tool_call, call.name, call.arguments);
            const result = try executeToolCall(allocator, io, read_context, plan.tools, call);
            defer allocator.free(result);
            if (isToolFailure(result)) {
                if (correction_retries >= runtime.max_retries) return error.ToolCallFailed;
                correction_retries += 1;
            } else {
                correction_retries = 0;
            }
            try sessions.appendToolEvent(allocator, session.path, RuntimeEvent.tool_result, call.name, result);
            try provider.appendMessage(allocator, &messages, .{ .role = "tool", .content = result, .name = call.name, .tool_call_id = call.id });
        }
    }
}

fn logAndReportUnreplayableToolCall(allocator: Allocator, session_path: []const u8, available_tools: []const []const u8, calls: []const provider.ToolCall, messages: *std.ArrayList(provider.Message), max_retries: usize, correction_retries: *usize) !bool {
    for (calls) |call| {
        const result = try unreplayableToolFailure(allocator, available_tools, call) orelse continue;
        defer allocator.free(result);
        try sessions.appendToolEvent(allocator, session_path, RuntimeEvent.tool_call, call.name, call.arguments);
        try sessions.appendToolEvent(allocator, session_path, RuntimeEvent.tool_result, call.name, result);
        if (correction_retries.* >= max_retries) return error.ToolCallFailed;
        correction_retries.* += 1;
        const retry = try buildToolFailureRetryPrompt(allocator, result);
        defer allocator.free(retry);
        try provider.appendMessage(allocator, messages, .{ .role = "user", .content = retry });
        return true;
    }
    return false;
}

fn unreplayableToolFailure(allocator: Allocator, available_tools: []const []const u8, call: provider.ToolCall) !?[]u8 {
    if (!allowsTool(available_tools, call.name)) return try toolFailureResult(allocator, call.name, "ToolNotAvailable", "tool is not available in this graph", call.arguments);
    tools.validateArguments(allocator, call.name, call.arguments) catch |err| return switch (err) {
        error.OutOfMemory => err,
        else => try toolFailureResult(allocator, call.name, @errorName(err), "tool arguments did not match the required JSON schema", call.arguments),
    };
    return null;
}

fn executeToolCall(allocator: Allocator, io: std.Io, ctx: RuntimeReadContext, available_tools: []const []const u8, call: provider.ToolCall) ![]u8 {
    if (!allowsTool(available_tools, call.name)) return toolFailureResult(allocator, call.name, "ToolNotAvailable", "tool is not available in this graph", call.arguments);
    tools.validateArguments(allocator, call.name, call.arguments) catch |err| return switch (err) {
        error.OutOfMemory => err,
        else => toolFailureResult(allocator, call.name, @errorName(err), "tool arguments did not match the required JSON schema", call.arguments),
    };
    return executeToolWithRuntimeReads(allocator, io, ctx, call.name, call.arguments) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => toolFailureResult(allocator, call.name, @errorName(err), "tool execution failed", call.arguments),
    };
}

fn executeToolWithRuntimeReads(allocator: Allocator, io: std.Io, ctx: RuntimeReadContext, name: []const u8, arg_text: []const u8) ![]u8 {
    if (std.mem.eql(u8, name, "read")) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, arg_text, .{}) catch |err| return switch (err) {
            error.OutOfMemory => err,
            else => error.InvalidToolArguments,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidToolArguments;
        const path = try tools.requireStringArg(parsed.value.object, "path");
        if (try readRuntimeUri(allocator, io, ctx, path)) |content| return content;
    }
    return tools.execute(allocator, io, name, arg_text);
}

fn readRuntimeUri(allocator: Allocator, io: std.Io, ctx: RuntimeReadContext, path: []const u8) !?[]u8 {
    if (std.mem.startsWith(u8, path, "prompt:")) {
        const id = path["prompt:".len..];
        for (ctx.prompts) |prompt| if (std.mem.eql(u8, prompt.id, id)) return try allocator.dupe(u8, prompt.content);
        return error.PromptNotFound;
    }
    if (std.mem.eql(u8, path, "session:current")) return try sessionMessageTranscript(allocator, ctx.session_log);
    if (std.mem.eql(u8, path, "session:last")) return try std.fmt.allocPrint(allocator, "id: {s}\npath: {s}\n", .{ ctx.session_id, ctx.session_path });
    if (std.mem.eql(u8, path, "sessions:index")) return try sessionsIndex(allocator, io, ctx.session_dir);
    return null;
}

fn buildRuntimeUriCatalog(allocator: Allocator, ctx: RuntimeReadContext) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Runtime-readable URIs. These are optional views available through the existing read tool; load only when useful.\n");
    for (ctx.prompts) |prompt| try out.print(allocator, "- prompt:{s}: {s} — {s} (read {{\"path\":\"prompt:{s}\"}})\n", .{ prompt.id, prompt.title, prompt.description, prompt.id });
    try out.appendSlice(allocator,
        \\- session:current: current session transcript as message-only text
        \\- session:last: current session id/path metadata
        \\- sessions:index: compact index of session files and latest user turns
    );
    return out.toOwnedSlice(allocator);
}

fn sessionMessageTranscript(allocator: Allocator, session_log: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, session_log, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const root = parsed.value.object;
        const typ = root.get("type") orelse continue;
        if (typ != .string or !std.mem.eql(u8, typ.string, "message")) continue;
        const message = root.get("message") orelse continue;
        if (message != .object) continue;
        const role_value = message.object.get("role") orelse continue;
        const content_value = message.object.get("content") orelse continue;
        if (role_value != .string or content_value != .string) continue;
        try out.print(allocator, "{s}: {s}\n", .{ role_value.string, content_value.string });
    }
    return out.toOwnedSlice(allocator);
}

fn sessionsIndex(allocator: Allocator, io: std.Io, session_dir: []const u8) ![]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, session_dir, .{ .iterate = true }) catch return allocator.dupe(u8, "");
    defer dir.close(io);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next(io)) |entry| {
        if (count >= 64) break;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const path = try std.fs.path.join(allocator, &.{ session_dir, entry.name });
        defer allocator.free(path);
        const log = sessions.readLog(allocator, path) catch continue;
        defer allocator.free(log);
        const message_count = sessions.countMessages(allocator, log) catch 0;
        const latest = try latestUserMessage(allocator, log);
        defer allocator.free(latest);
        try out.print(allocator, "- {s}: messages={d} latest_user={s}\n", .{ entry.name, message_count, latest });
        count += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn latestUserMessage(allocator: Allocator, session_log: []const u8) ![]u8 {
    var latest = try allocator.dupe(u8, "");
    errdefer allocator.free(latest);
    var lines = std.mem.splitScalar(u8, session_log, '\n');
    while (lines.next()) |line| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const root = parsed.value.object;
        const typ = root.get("type") orelse continue;
        if (typ != .string or !std.mem.eql(u8, typ.string, "message")) continue;
        const message = root.get("message") orelse continue;
        if (message != .object) continue;
        const role_value = message.object.get("role") orelse continue;
        const content_value = message.object.get("content") orelse continue;
        if (role_value == .string and content_value == .string and std.mem.eql(u8, role_value.string, "user")) {
            allocator.free(latest);
            latest = try allocator.dupe(u8, content_value.string[0..@min(content_value.string.len, 160)]);
        }
    }
    return latest;
}

fn recordContractFailure(allocator: Allocator, session_path: []const u8, err: anyerror, raw: []const u8) !void {
    std.debug.print("runtime contract failure: {s}\nraw assistant output:\n{s}\n", .{ @errorName(err), raw });
    try sessions.appendRuntimeError(allocator, session_path, Phase.assistant_turn, RuntimeEvent.contract_failure, @errorName(err), raw);
}

fn looksLikeTextToolCall(text: []const u8, available_tools: []const []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        var line = std.mem.trim(u8, line_raw, " \t\r`*_>");
        if (std.mem.startsWith(u8, line, "tool:")) line = std.mem.trim(u8, line["tool:".len..], " \t");
        for (available_tools) |tool| {
            if (!std.mem.startsWith(u8, line, tool)) continue;
            const rest = std.mem.trim(u8, line[tool.len..], " \t");
            if (rest.len != 0 and (rest[0] == ':' or rest[0] == '{' or rest[0] == '(')) return true;
        }
    }
    return false;
}

fn buildTextToolCallRetryPrompt(allocator: Allocator, output: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\wrong. you printed a tool call as text instead of using the actual tool channel.
        \\
        \\printed output:
        \\{s}
        \\
        \\try again. if you need bash/read/etc, make an actual tool call. do not write markdown or textual tool calls.
    , .{output});
}

fn buildContractRetryPrompt(allocator: Allocator, err: anyerror, raw: []const u8) ![]u8 {
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
        \\Answer the current user request in final text.
    , .{ @errorName(err), raw });
}

fn toolFailureResult(allocator: Allocator, tool_name: []const u8, error_name: []const u8, message: []const u8, arguments: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":false,\"tool\":");
    try files.appendJsonString(allocator, &out, tool_name);
    try out.appendSlice(allocator, ",\"error\":");
    try files.appendJsonString(allocator, &out, error_name);
    try out.appendSlice(allocator, ",\"message\":");
    try files.appendJsonString(allocator, &out, message);
    try out.appendSlice(allocator, ",\"arguments\":");
    try files.appendJsonString(allocator, &out, arguments);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn isToolFailure(result: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trim(u8, result, " \t\r\n"), "{\"ok\":false");
}

fn buildToolFailureRetryPrompt(allocator: Allocator, result: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\wrong. your actual tool call failed.
        \\
        \\tool output:
        \\{s}
        \\
        \\try again with a valid actual tool call, or answer if no tool is needed.
    , .{result});
}

fn buildUnavailableToolRetryPrompt(allocator: Allocator, unavailable: []const u8, available: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator,
        \\Runtime contract failure.
        \\
        \\The tool "{s}" is not available in this graph.
        \\Retry this assistant turn cleanly using only available tools.
        \\Available tools:
    , .{unavailable});
    for (available) |tool| try out.print(allocator, "\n- {s}", .{tool});
    try out.appendSlice(allocator,
        \\
        \\
        \\If no available tool can satisfy the request, explain the blocker in final text.
    );
    return out.toOwnedSlice(allocator);
}

fn shouldCompact(allocator: Allocator, session_log: []const u8, context_tokens: usize, threshold_percent: usize) !bool {
    if (threshold_percent == 0) return false;
    if (context_tokens == 0) return false;
    const message_count = try sessions.countMessages(allocator, session_log);
    if (message_count == 0) return false;
    if (try sessions.latestCompactionMessageCount(allocator, session_log)) |compacted_count| {
        if (compacted_count >= message_count) return false;
    }
    const estimated_tokens = (session_log.len + 3) / 4;
    return estimated_tokens * 100 >= context_tokens * threshold_percent;
}

fn recoverFocusedContext(allocator: Allocator, io: std.Io, provider_base_url: []const u8, max_retries: usize, session_path: []const u8, model_alias: []const u8, temperature: f64, max_tokens: ?usize, tool_format: []const u8, focused_prompt: []const u8, available_tools: []const []const u8, available_tools_json: []const u8, prior_context: []const u8, user_prompt: []const u8, session_dir: []const u8) ![]u8 {
    const user_content = try std.fmt.allocPrint(allocator,
        \\assembled_context:
        \\{s}
        \\
        \\user_turn:
        \\{s}
        \\
        \\session_dir:
        \\{s}
    , .{ prior_context, user_prompt, session_dir });
    defer allocator.free(user_content);

    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(allocator);
    defer provider.freeMessages(allocator, messages.items);
    try provider.appendMessage(allocator, &messages, .{ .role = "system", .content = focused_prompt });
    try provider.appendMessage(allocator, &messages, .{ .role = "user", .content = user_content });

    var correction_retries: usize = 0;
    while (true) {
        const turn = try callProviderWithTransientRetries(allocator, io, session_path, "focused_recovery", max_retries, .{
            .base_url = provider_base_url,
            .authorization = local_auth_header,
            .model = model_alias,
            .temperature = temperature,
            .max_tokens = max_tokens,
            .reasoning_format = "auto",
            .reasoning_budget_tokens = null,
            .thinking_enabled = false,
            .parse_native_tools = std.mem.eql(u8, tool_format, "gemma-native"),
            .json_response = true,
            .tools_json = available_tools_json,
            .messages = messages.items,
        });
        defer provider.freeTurn(allocator, turn);

        if (turn.tool_calls.len == 0) return provider.cleanText(allocator, turn.text);

        if (try logAndReportUnreplayableToolCall(allocator, session_path, available_tools, turn.tool_calls, &messages, max_retries, &correction_retries)) continue;
        try provider.appendMessage(allocator, &messages, .{ .role = "assistant", .content = turn.text, .tool_calls = turn.tool_calls });
        if (turn.reasoning.len > 0) try sessions.appendRuntimeEvent(allocator, session_path, "focused_recovery", RuntimeEvent.model_output, turn.reasoning);
        for (turn.tool_calls) |call| {
            try sessions.appendToolEvent(allocator, session_path, RuntimeEvent.tool_call, call.name, call.arguments);
            const result = try executeFocusedToolCall(allocator, io, available_tools, call);
            defer allocator.free(result);
            if (isToolFailure(result)) {
                if (correction_retries >= max_retries) return error.ToolCallFailed;
                correction_retries += 1;
            } else {
                correction_retries = 0;
            }
            try sessions.appendToolEvent(allocator, session_path, RuntimeEvent.tool_result, call.name, result);
            try provider.appendMessage(allocator, &messages, .{ .role = "tool", .content = result, .name = call.name, .tool_call_id = call.id });
        }
    }
}

fn executeFocusedToolCall(allocator: Allocator, io: std.Io, available_tools: []const []const u8, call: provider.ToolCall) ![]u8 {
    if (!allowsTool(available_tools, call.name)) return toolFailureResult(allocator, call.name, "ToolNotAvailable", "tool is not available in this graph", call.arguments);
    tools.validateArguments(allocator, call.name, call.arguments) catch |err| return switch (err) {
        error.OutOfMemory => err,
        else => toolFailureResult(allocator, call.name, @errorName(err), "tool arguments did not match the required JSON schema", call.arguments),
    };
    return tools.execute(allocator, io, call.name, call.arguments) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => toolFailureResult(allocator, call.name, @errorName(err), "tool execution failed", call.arguments),
    };
}

fn allowsTool(available: []const []const u8, name: []const u8) bool {
    for (available) |tool| if (std.mem.eql(u8, tool, name)) return true;
    return false;
}

fn reasoningEnabled(reasoning_tokens: isize) bool {
    return reasoning_tokens != 0;
}

fn reasoningBudgetTokens(reasoning_tokens: isize) ?usize {
    if (reasoning_tokens <= 0) return null;
    return @intCast(reasoning_tokens);
}

fn callProviderWithTransientRetries(allocator: Allocator, io: std.Io, session_path: []const u8, phase: []const u8, max_retries: usize, request: provider.Request) !provider.AssistantTurn {
    var attempts: usize = 0;
    while (true) {
        return provider.call(allocator, io, request) catch |err| {
            if (err == error.ProviderLoadingModel) {
                try sessions.appendRuntimeError(allocator, session_path, phase, RuntimeEvent.retryable_failure, @errorName(err), "provider is still loading the model; waiting before retry");
                sleepMillis(1000);
                continue;
            }
            if (!isTransientProviderError(err) or attempts >= max_retries) return err;
            attempts += 1;
            try sessions.appendRuntimeError(allocator, session_path, phase, RuntimeEvent.retryable_failure, @errorName(err), "provider call failed; retrying immediately");
            continue;
        };
    }
}

fn isTransientProviderError(err: anyerror) bool {
    return switch (err) {
        error.ProviderRequestFailed,
        error.ProviderLoadingModel,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        error.BadProviderResponse,
        => true,
        else => false,
    };
}

fn sleepMillis(ms: usize) void {
    var request = std.os.linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    while (true) {
        var remaining: std.os.linux.timespec = undefined;
        const rc = std.os.linux.nanosleep(&request, &remaining);
        const errno = std.os.linux.errno(rc);
        if (errno == .SUCCESS) return;
        if (errno != .INTR) return;
        request = remaining;
    }
}
