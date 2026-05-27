const std = @import("std");
const compaction = @import("compaction.zig");
const config = @import("../runtime/config.zig");
const files = @import("../sys/fs.zig");
const plan_mod = @import("plan.zig");
const provider = @import("../runtime/provider.zig");
const resource = @import("resource.zig");
const sessions = @import("../runtime/session.zig");
const tools = @import("../sys/process.zig");
const trace = @import("../sys/trace.zig");

const Allocator = std.mem.Allocator;

const RuntimeReadContext = struct {
    prompts: []const plan_mod.PromptPack,
    inputs: []const BoundInput,
    session_id: []const u8,
    session_path: []const u8,
    session_dir: []const u8,
    session_log: []const u8,
};

const Agent = struct {
    label: []const u8,
    system: []const u8,
    tools: []const []const u8,
    tools_json: []const u8,
    json: bool = false,
    runtime_reads: bool = false,
};

const BoundInput = struct {
    id: []u8,
    kind: plan_mod.InputKind,
    value: []u8,
    mime: []u8,

    fn deinit(self: BoundInput, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.value);
        allocator.free(self.mime);
    }
};

pub fn run(allocator: Allocator, io: std.Io, home: []const u8, user_prompt: []const u8, resume_id: ?[]const u8, continue_last: bool, plan_path_override: ?[]const u8, runtime_inputs: []const plan_mod.RuntimeInput) !void {
    const span = trace.span("engine_run");
    defer span.end("engine", "continue={} prompt_chars={d}", .{ continue_last, user_prompt.len });

    const profile = try config.loadRuntimeProfile(allocator, io, home, null);
    defer profile.deinit(allocator);
    const plan = try plan_mod.load(allocator, plan_path_override orelse profile.paths.compiled_plan);
    defer plan.deinit(allocator);
    const session = try sessions.open(allocator, resume_id, continue_last);
    defer session.deinit(allocator);

    var log = try sessions.readParsed(allocator, session.path);
    defer log.deinit(allocator);
    trace.event("session", "open", "id={s} bytes={d} messages={d}", .{ session.id, log.raw.len, log.messageCount() });
    if (try shouldCompact(log, plan.context_tokens, profile.runtime.compaction_threshold_percent)) {
        _ = try compaction.runGraph(allocator, io, home, session, profile.paths.compaction_graph);
        log.deinit(allocator);
        log = try sessions.readParsed(allocator, session.path);
    }

    const prior = try log.transcript(allocator);
    defer allocator.free(prior);
    const session_dir = std.fs.path.dirname(session.path) orelse ".zinc/sessions";
    const focused = if (log.compaction != null) try runFocused(allocator, io, &profile, &plan, session.path, prior, user_prompt, session_dir) else blk: {
        trace.event("context", "focused_recovery_skip", "session_bytes={d} messages={d}", .{ log.raw.len, log.messageCount() });
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(focused);

    const bound_inputs = try bindInputs(allocator, &plan, user_prompt, runtime_inputs);
    defer freeBoundInputs(allocator, bound_inputs);
    const read_ctx = RuntimeReadContext{ .prompts = plan.prompts, .inputs = bound_inputs, .session_id = session.id, .session_path = session.path, .session_dir = session_dir, .session_log = log.raw };
    const uri_catalog = try runtimeUriCatalog(allocator);
    defer allocator.free(uri_catalog);
    const system = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ plan.prompt, uri_catalog });
    defer allocator.free(system);

    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(allocator);
    defer provider.freeMessages(allocator, messages.items);
    const input_parts = try modelPartsForInputs(allocator, plan.image_inputs, bound_inputs);
    defer freeModelParts(allocator, input_parts);
    try provider.appendMessage(allocator, &messages, .{ .role = "system", .content = system });
    try log.appendReplayMessages(allocator, &messages, focused);
    const user_content = try userContent(allocator, user_prompt, bound_inputs);
    defer allocator.free(user_content);
    try provider.appendMessage(allocator, &messages, .{ .role = "user", .content = user_content, .parts = input_parts });
    try sessions.appendUserMessage(allocator, session.path, user_content);
    try sessions.rememberLast(session);

    const text = try runAgent(allocator, io, &profile, session.path, &messages, read_ctx, .{ .label = "main", .system = system, .tools = plan.tools, .tools_json = plan.tools_json, .runtime_reads = true }, plan.max_tokens, reasoningBudget(plan.reasoning_tokens));
    defer allocator.free(text);
    const response = std.mem.trim(u8, text, " \t\r\n");
    if (response.len == 0) return error.EmptyAssistantResponse;
    try sessions.appendAssistantText(allocator, session.path, response);
    _ = try files.linuxWrite(1, response);
    _ = try files.linuxWrite(1, "\n");
}

fn runFocused(allocator: Allocator, io: std.Io, profile: *const config.RuntimeProfile, plan: *const plan_mod.Plan, session_path: []const u8, prior: []const u8, user_prompt: []const u8, session_dir: []const u8) ![]u8 {
    const content = try std.fmt.allocPrint(allocator, "assembled_context:\n{s}\n\nuser_turn:\n{s}\n\nsession_dir:\n{s}", .{ prior, user_prompt, session_dir });
    defer allocator.free(content);
    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(allocator);
    defer provider.freeMessages(allocator, messages.items);
    try provider.appendMessage(allocator, &messages, .{ .role = "system", .content = plan.focused_recovery_prompt });
    try provider.appendMessage(allocator, &messages, .{ .role = "user", .content = content });
    const dummy = RuntimeReadContext{ .prompts = &.{}, .inputs = &.{}, .session_id = "", .session_path = session_path, .session_dir = session_dir, .session_log = "" };
    return runAgent(allocator, io, profile, session_path, &messages, dummy, .{ .label = "focused_recovery", .system = plan.focused_recovery_prompt, .tools = plan.focused_recovery_tools, .tools_json = plan.focused_recovery_tools_json, .json = true }, profile.model.generation.max_tokens, null);
}

fn runAgent(allocator: Allocator, io: std.Io, profile: *const config.RuntimeProfile, session_path: []const u8, messages: *std.ArrayList(provider.Message), read_ctx: RuntimeReadContext, agent: Agent, max_tokens: ?usize, reasoning: ?usize) ![]u8 {
    var retries: usize = 0;
    while (true) {
        const turn = try callProvider(allocator, io, session_path, profile.runtime.max_retries, agent.label, .{ .profile = profile, .max_tokens = max_tokens, .reasoning_budget_tokens = reasoning, .json_response = agent.json, .tools_json = agent.tools_json, .messages = messages.items });
        defer provider.freeTurn(allocator, turn);
        if (turn.tool_calls.len == 0) return provider.cleanText(allocator, turn.text, profile);
        try provider.appendMessage(allocator, messages, .{ .role = "assistant", .content = turn.text, .tool_calls = turn.tool_calls });
        if (std.mem.eql(u8, agent.label, "main")) try sessions.appendAssistantToolCalls(allocator, session_path, turn.text, turn.tool_calls);
        for (turn.tool_calls) |call| {
            const result = try executeTool(allocator, io, read_ctx, agent, call);
            defer result.deinit(allocator);
            if (std.mem.eql(u8, agent.label, "main")) try sessions.appendToolResult(allocator, session_path, call, result);
            if (result.is_error) {
                if (retries >= profile.runtime.max_retries) return error.ToolCallFailed;
                retries += 1;
            } else retries = 0;
            try provider.appendMessage(allocator, messages, .{ .role = "tool", .content = result.content, .name = call.name, .tool_call_id = call.id });
        }
    }
}

fn executeTool(allocator: Allocator, io: std.Io, ctx: RuntimeReadContext, agent: Agent, call: provider.ToolCall) !tools.ToolResult {
    if (!hasTool(agent.tools, call.name)) return toolError(allocator, call, "ToolNotAvailable", "tool is not available in this graph");
    tools.validateArguments(allocator, call.name, call.arguments) catch |err| return switch (err) {
        error.OutOfMemory => err,
        else => toolError(allocator, call, @errorName(err), "tool arguments did not match the required JSON schema"),
    };
    if (agent.runtime_reads and std.mem.eql(u8, call.name, "read")) {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, call.arguments, .{});
        defer parsed.deinit();
        const path = try tools.requireStringArg(parsed.value.object, "path");
        if (try readRuntimeUri(allocator, io, ctx, path)) |content| return .{ .content = content, .is_error = false };
    }
    return tools.executeResult(allocator, io, call.name, call.arguments) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => toolError(allocator, call, @errorName(err), "tool execution failed"),
    };
}

fn toolError(allocator: Allocator, call: provider.ToolCall, name: []const u8, message: []const u8) !tools.ToolResult {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":false,\"tool\":");
    try files.appendJsonString(allocator, &out, call.name);
    try out.appendSlice(allocator, ",\"error\":");
    try files.appendJsonString(allocator, &out, name);
    try out.appendSlice(allocator, ",\"message\":");
    try files.appendJsonString(allocator, &out, message);
    try out.appendSlice(allocator, ",\"arguments\":");
    try files.appendJsonString(allocator, &out, call.arguments);
    try out.append(allocator, '}');
    return .{ .content = try out.toOwnedSlice(allocator), .is_error = true };
}

fn readRuntimeUri(allocator: Allocator, io: std.Io, ctx: RuntimeReadContext, path: []const u8) !?[]u8 {
    if (std.mem.startsWith(u8, path, "prompt:")) {
        const id = path["prompt:".len..];
        for (ctx.prompts) |prompt| if (std.mem.eql(u8, prompt.id, id)) return try allocator.dupe(u8, prompt.content);
        return error.PromptNotFound;
    }
    if (std.mem.startsWith(u8, path, "input:")) {
        const id = path["input:".len..];
        for (ctx.inputs) |input| if (std.mem.eql(u8, input.id, id)) return try readInputValue(allocator, input);
        return error.InputNotFound;
    }
    if (std.mem.eql(u8, path, "session:current")) {
        const log = try sessions.parseRaw(allocator, ctx.session_log);
        defer log.deinit(allocator);
        return try log.transcript(allocator);
    }
    if (std.mem.eql(u8, path, "session:last")) return try std.fmt.allocPrint(allocator, "id: {s}\npath: {s}\n", .{ ctx.session_id, ctx.session_path });
    if (std.mem.eql(u8, path, "sessions:index")) return try sessionsIndex(allocator, io, ctx.session_dir);
    return null;
}

fn bindInputs(allocator: Allocator, plan: *const plan_mod.Plan, user_prompt: []const u8, runtime_inputs: []const plan_mod.RuntimeInput) ![]BoundInput {
    var out: std.ArrayList(BoundInput) = .empty;
    errdefer {
        for (out.items) |input| input.deinit(allocator);
        out.deinit(allocator);
    }
    for (runtime_inputs) |input| {
        const spec = inputSpec(plan, input.id) orelse return error.UnknownGraphInput;
        if (spec.kind != input.kind) return error.GraphInputTypeMismatch;
        try out.append(allocator, try cloneRuntimeInput(allocator, input));
    }
    if (user_prompt.len != 0) {
        if (inputSpec(plan, "user_turn")) |spec| if (!hasBoundInput(out.items, "user_turn")) {
            if (spec.kind != .text) return error.GraphInputTypeMismatch;
            try out.append(allocator, .{ .id = try allocator.dupe(u8, "user_turn"), .kind = .text, .value = try allocator.dupe(u8, user_prompt), .mime = try allocator.dupe(u8, "text/plain") });
        };
    }
    for (plan.inputs) |spec| if (spec.required and !hasBoundInput(out.items, spec.id)) return error.MissingRequiredGraphInput;
    return out.toOwnedSlice(allocator);
}

fn cloneRuntimeInput(allocator: Allocator, input: plan_mod.RuntimeInput) !BoundInput {
    return .{ .id = try allocator.dupe(u8, input.id), .kind = input.kind, .value = try allocator.dupe(u8, input.value), .mime = try allocator.dupe(u8, input.mime) };
}

fn freeBoundInputs(allocator: Allocator, inputs: []const BoundInput) void {
    for (inputs) |input| input.deinit(allocator);
    allocator.free(inputs);
}

fn inputSpec(plan: *const plan_mod.Plan, id: []const u8) ?plan_mod.InputSpec {
    for (plan.inputs) |input| if (std.mem.eql(u8, input.id, id)) return input;
    return null;
}

fn hasBoundInput(inputs: []const BoundInput, id: []const u8) bool {
    for (inputs) |input| if (std.mem.eql(u8, input.id, id)) return true;
    return false;
}

fn userContent(allocator: Allocator, user_prompt: []const u8, inputs: []const BoundInput) ![]u8 {
    if (inputs.len == 0) return allocator.dupe(u8, user_prompt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (user_prompt.len != 0 and !hasBoundInput(inputs, "user_turn")) try out.appendSlice(allocator, user_prompt);
    for (inputs) |input| {
        if (input.kind == .image) continue;
        if (out.items.len != 0) try out.appendSlice(allocator, "\n\n");
        if (input.kind == .text) {
            const text = try readInputValue(allocator, input);
            defer allocator.free(text);
            try out.print(allocator, "input {s}:\n{s}", .{ input.id, text });
        } else try out.print(allocator, "file input {s}: input:{s}", .{ input.id, input.id });
    }
    return out.toOwnedSlice(allocator);
}

fn readInputValue(allocator: Allocator, input: BoundInput) ![]u8 {
    if (input.kind == .text and std.mem.startsWith(u8, input.value, "@")) return files.readLimited(allocator, input.value[1..], 8 * 1024 * 1024);
    if (input.kind == .text) return allocator.dupe(u8, input.value);
    if (input.kind == .file) return files.readLimited(allocator, input.value, 32 * 1024 * 1024);
    return error.GraphInputNotReadable;
}

fn modelPartsForInputs(allocator: Allocator, plan_images: []const plan_mod.ImageInput, inputs: []const BoundInput) ![]resource.ModelPart {
    var total = plan_images.len;
    for (inputs) |input| {
        if (input.kind == .image) total += 1;
    }
    if (total == 0) return &.{};
    var out = try allocator.alloc(resource.ModelPart, total);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |part| part.deinit(allocator);
        allocator.free(out);
    }
    for (plan_images) |image| {
        const ref = try resource.parseRef(allocator, image.path, null);
        defer ref.deinit(allocator);
        out[initialized] = try resource.refToImagePart(allocator, ref, image.mime);
        initialized += 1;
    }
    for (inputs) |input| if (input.kind == .image) {
        const ref = try resource.parseRef(allocator, input.value, null);
        defer ref.deinit(allocator);
        out[initialized] = try resource.refToImagePart(allocator, ref, input.mime);
        initialized += 1;
    };
    return out;
}

fn freeModelParts(allocator: Allocator, parts: []const resource.ModelPart) void {
    for (parts) |part| part.deinit(allocator);
    if (parts.len != 0) allocator.free(parts);
}

fn runtimeUriCatalog(allocator: Allocator) ![]u8 {
    return allocator.dupe(u8,
        \\Runtime reads
        \\
        \\- session:current: current session transcript with tool calls and tool results
        \\
        \\- session:last: current session id and path
        \\
        \\- sessions:index: session file index with latest user turns
        \\- input:<id>: content for bound file/text graph inputs
    );
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
        const log = sessions.readParsed(allocator, path) catch continue;
        defer log.deinit(allocator);
        try out.print(allocator, "- {s}: messages={d}\n", .{ entry.name, log.messageCount() });
        count += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn callProvider(allocator: Allocator, io: std.Io, session_path: []const u8, max_retries: usize, label: []const u8, request: provider.Request) !provider.AssistantTurn {
    var attempts: usize = 0;
    while (true) {
        const span = trace.span("provider_call");
        trace.event("llm", "request", "label={s} attempt={d} messages={d} chars={d} tools={d}", .{ label, attempts + 1, request.messages.len, messageChars(request.messages), request.tools_json.len });
        const turn = provider.call(allocator, io, request) catch |err| {
            span.end("llm", "label={s} attempt={d} error={s}", .{ label, attempts + 1, @errorName(err) });
            if (err == error.ProviderLoadingModel) {
                try sessions.appendProviderError(allocator, session_path, "provider loading");
                sleepMillis(1000);
                continue;
            }
            if (!isTransient(err) or attempts >= max_retries) return err;
            attempts += 1;
            try sessions.appendProviderError(allocator, session_path, "provider retry");
            continue;
        };
        span.end("llm", "label={s} attempt={d} text_chars={d} tool_calls={d}", .{ label, attempts + 1, turn.text.len, turn.tool_calls.len });
        return turn;
    }
}

fn shouldCompact(log: sessions.Log, context_tokens: usize, threshold_percent: usize) !bool {
    if (threshold_percent == 0 or context_tokens == 0 or log.messageCount() == 0) return false;
    if (log.compaction) |c| if (c.message_count >= log.messageCount()) return false;
    return ((log.raw.len + 3) / 4) * 100 >= context_tokens * threshold_percent;
}

fn messageChars(messages: []const provider.Message) usize {
    var n: usize = 0;
    for (messages) |m| {
        n += m.role.len + m.content.len;
        for (m.parts) |part| switch (part) {
            .text => |text| n += text.len,
            .image_url => |url| n += url.len,
        };
    }
    return n;
}

fn hasTool(available: []const []const u8, name: []const u8) bool {
    for (available) |tool| if (std.mem.eql(u8, tool, name)) return true;
    return false;
}
fn reasoningBudget(tokens: isize) ?usize {
    return if (tokens <= 0) null else @intCast(tokens);
}
fn isTransient(err: anyerror) bool {
    return switch (err) {
        error.ProviderRequestFailed, error.ProviderLoadingModel, error.ConnectionRefused, error.ConnectionResetByPeer, error.BrokenPipe, error.BadProviderResponse => true,
        else => false,
    };
}
fn sleepMillis(ms: usize) void {
    var req = std.os.linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    while (true) {
        var rem: std.os.linux.timespec = undefined;
        const rc = std.os.linux.nanosleep(&req, &rem);
        const errno = std.os.linux.errno(rc);
        if (errno == .SUCCESS) return;
        if (errno != .INTR) return;
        req = rem;
    }
}
