const std = @import("std");
const config = @import("../config/mod.zig");
const ctxmod = @import("context.zig");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const graph = @import("mod.zig");
const resource = @import("resource.zig");
const sessions = @import("../runtime/session.zig");
const trace = @import("../io/trace.zig");

const Allocator = std.mem.Allocator;
const context_chars_per_token: usize = 3;

pub const RecoveryOverride = struct {
    reach: ?[]const u8 = null,
    graph: ?[]const u8 = null,
};

fn fail(comptime fmt: []const u8, args: anytype) error{UserError}!void {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    return error.UserError;
}

pub fn run(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, user_prompt: []const u8, resume_id: ?[]const u8, continue_last: bool, graph_path_override: ?[]const u8, runtime_inputs: []const graph.RuntimeInput) !void {
    const runtime_paths = try config.loadRuntimePaths(allocator, io, layout_ctx);
    defer runtime_paths.deinit(allocator);
    return runGraph(allocator, io, layout_ctx, graph_path_override orelse runtime_paths.graph, null, null, user_prompt, resume_id, continue_last, runtime_inputs, .{});
}

pub fn compactSession(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, graph_path: []const u8, resume_id: ?[]const u8, continue_last: bool) !void {
    const model_id = try config.resolveConfiguredModelId(allocator, io, layout_ctx);
    defer allocator.free(model_id);
    const profile = try config.loadRuntimeProfile(allocator, io, layout_ctx, model_id);
    defer profile.deinit(allocator);
    const session = try sessions.open(allocator, layout_ctx, resume_id, continue_last);
    defer session.deinit(allocator);
    try runCompaction(allocator, io, layout_ctx, &profile, session, graph_path);
    try sessions.rememberLast(allocator, layout_ctx, session);
}

pub fn runGraph(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, graph_path: []const u8, selected_export: ?[]const u8, model_override: ?[]const u8, user_prompt: []const u8, resume_id: ?[]const u8, continue_last: bool, runtime_inputs: []const graph.RuntimeInput, recovery_override: RecoveryOverride) !void {
    const span = trace.span("engine_run");
    defer span.end("engine", "graph={s} prompt_chars={d}", .{ graph_path, user_prompt.len });

    const loaded_graph = try graph.load(allocator, io, graph_path);
    defer loaded_graph.deinit(allocator);
    try graph.validate(loaded_graph);
    const target = graph.exportTargetResourceId(loaded_graph, selected_export) orelse return fail("graph has no default export; add `exports.main` or pass `--export`", .{});
    if (graph.resource(loaded_graph, target) == null) return fail("export target not found: {s}", .{target});

    const model_id = if (model_override) |id| try allocator.dupe(u8, id) else try config.resolveGraphModelId(allocator, io, loaded_graph, selected_export, layout_ctx);
    defer allocator.free(model_id);
    const profile = try config.loadRuntimeProfile(allocator, io, layout_ctx, model_id);
    defer profile.deinit(allocator);

    const session = try sessions.open(allocator, layout_ctx, resume_id, continue_last);
    defer session.deinit(allocator);

    var log = try sessions.read(allocator, layout_ctx, session);
    defer log.deinit(allocator);
    if (try shouldCompactLog(allocator, io, log, &profile)) {
        try runCompaction(allocator, io, layout_ctx, &profile, session, profile.paths.compaction_graph);
        log.deinit(allocator);
        log = try sessions.read(allocator, layout_ctx, session);
    }

    const recovered_context = try recoveredContextForRun(allocator, io, layout_ctx, loaded_graph, selected_export, &profile, session, log, user_prompt, recovery_override);
    defer if (recovered_context) |text| allocator.free(text);
    const graph_inputs = try runtimeInputsForLoop(allocator, loaded_graph, selected_export, runtime_inputs, recovered_context);
    defer freeRuntimeInputList(allocator, graph_inputs, runtime_inputs.len);
    const bound_inputs = try resource.bindInputs(allocator, loaded_graph, selected_export, user_prompt, graph_inputs);
    defer resource.freeBoundInputs(allocator, bound_inputs);

    var bash_allowances: ctxmod.BashAllowances = .empty;
    defer {
        for (bash_allowances.items) |item| item.deinit(allocator);
        bash_allowances.deinit(allocator);
    }
    var ctx = ctxmod.RunContext{ .allocator = allocator, .io = io, .layout_ctx = layout_ctx, .home = layout_ctx.dirs.home, .profile = &profile, .graph_path = graph_path, .graph = &loaded_graph, .session = session, .log = &log, .inputs = bound_inputs, .frame = .interactive(target), .bash_allowances = &bash_allowances };
    const result = resource.resolve(&ctx, target) catch |err| switch (err) {
        error.GraphRunDeniedByUser => {
            try files.writeAllOut("graph run denied\n");
            return;
        },
        else => return err,
    };
    defer result.deinit(allocator);
    const response = std.mem.trim(u8, result.text, " \t\r\n");
    if (response.len == 0) return error.EmptyAssistantResponse;
    try files.writeAllOut(response);
    try files.writeAllOut("\n");

    log.deinit(allocator);
    log = try sessions.read(allocator, layout_ctx, session);
    if (try shouldCompactLog(allocator, io, log, &profile)) try runCompaction(allocator, io, layout_ctx, &profile, session, profile.paths.compaction_graph);
}

fn recoveredContextForRun(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, loaded_graph: graph.Graph, selected_export: ?[]const u8, profile: *const config.RuntimeProfile, session: sessions.Session, log: sessions.Log, user_prompt: []const u8, recovery_override: RecoveryOverride) !?[]u8 {
    if (!try graph.hasInputForExport(allocator, loaded_graph, selected_export, "recovered_context")) return null;
    const boundary = compactionBoundary(log);
    if (log.recovery) |recovery| if (recovery.compaction_message_count == boundary) return try allocator.dupe(u8, recovery.context);
    const graph_path = recovery_override.graph orelse profile.recovery.graph;
    const reach = recovery_override.reach orelse profile.recovery.reach;
    if (std.mem.eql(u8, reach, "none")) return try allocator.dupe(u8, "");
    try sessions.appendRecoveryStarted(allocator, layout_ctx, session, reach, profile.recovery.budget_chars);
    const context = runContextRecovery(allocator, io, layout_ctx, profile, session, log, graph_path, user_prompt, reach) catch |err| {
        try sessions.appendRecoveryFailed(allocator, layout_ctx, session, @errorName(err));
        return err;
    };
    errdefer allocator.free(context);
    if (log.messageCount() != 0) try sessions.appendRecovery(allocator, layout_ctx, session, log.messageCount(), boundary, context);
    return context;
}

fn compactionBoundary(log: sessions.Log) usize {
    return if (log.compaction) |c| c.message_count else 0;
}

fn runCompaction(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, profile: *const config.RuntimeProfile, session: sessions.Session, graph_path: []const u8) !void {
    const log = try sessions.read(allocator, layout_ctx, session);
    defer log.deinit(allocator);
    if (log.messageCount() == 0) return;
    const loaded_graph = try graph.load(allocator, io, graph_path);
    defer loaded_graph.deinit(allocator);
    const target = graph.exportTargetResourceId(loaded_graph, null) orelse return fail("graph has no default export; add `exports.main`", .{});
    if (graph.resource(loaded_graph, target) == null) return fail("export target not found: {s}", .{target});
    var log_mut = try sessions.read(allocator, layout_ctx, session);
    defer log_mut.deinit(allocator);
    const compaction_inputs = try runtimeInputsForCompaction(allocator, loaded_graph, log, profile);
    defer freeRuntimeInputList(allocator, compaction_inputs, 0);
    const bound = try resource.bindInputs(allocator, loaded_graph, null, "", compaction_inputs);
    defer resource.freeBoundInputs(allocator, bound);
    var bash_allowances: ctxmod.BashAllowances = .empty;
    defer {
        for (bash_allowances.items) |item| item.deinit(allocator);
        bash_allowances.deinit(allocator);
    }
    var ctx = ctxmod.RunContext{ .allocator = allocator, .io = io, .layout_ctx = layout_ctx, .home = layout_ctx.dirs.home, .profile = profile, .graph_path = graph_path, .graph = &loaded_graph, .session = session, .log = &log_mut, .inputs = bound, .frame = .maintenance(target), .bash_allowances = &bash_allowances };
    const result = try resource.resolve(&ctx, target);
    defer result.deinit(allocator);
    const summary = try parseStringField(allocator, result.text, "summary");
    defer allocator.free(summary);
    try sessions.appendCompaction(allocator, layout_ctx, session, log.messageCount(), summary);
}

fn runContextRecovery(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, profile: *const config.RuntimeProfile, session: sessions.Session, log: sessions.Log, graph_path: []const u8, user_prompt: []const u8, reach: []const u8) ![]u8 {
    if (log.messageCount() == 0) return allocator.dupe(u8, "");
    const loaded_graph = try graph.load(allocator, io, graph_path);
    defer loaded_graph.deinit(allocator);
    const target = graph.exportTargetResourceId(loaded_graph, null) orelse {
        std.debug.print("error: context recovery graph has no default export; add `exports.main`\n", .{});
        return error.UserError;
    };
    if (graph.resource(loaded_graph, target) == null) {
        std.debug.print("error: context recovery target not found: {s}\n", .{target});
        return error.UserError;
    }
    var log_mut = try sessions.read(allocator, layout_ctx, session);
    defer log_mut.deinit(allocator);
    const recovery_inputs = try runtimeInputsForRecovery(allocator, loaded_graph, log, profile, session, user_prompt, reach);
    defer freeRuntimeInputList(allocator, recovery_inputs, 0);
    const bound = try resource.bindInputs(allocator, loaded_graph, null, "", recovery_inputs);
    defer resource.freeBoundInputs(allocator, bound);
    var bash_allowances: ctxmod.BashAllowances = .empty;
    defer {
        for (bash_allowances.items) |item| item.deinit(allocator);
        bash_allowances.deinit(allocator);
    }
    var ctx = ctxmod.RunContext{ .allocator = allocator, .io = io, .layout_ctx = layout_ctx, .home = layout_ctx.dirs.home, .profile = profile, .graph_path = graph_path, .graph = &loaded_graph, .session = session, .log = &log_mut, .inputs = bound, .frame = .maintenance(target), .bash_allowances = &bash_allowances };
    const result = try resource.resolve(&ctx, target);
    defer result.deinit(allocator);
    return parseStringField(allocator, result.text, "context");
}

fn runtimeInputsForLoop(allocator: Allocator, loaded_graph: graph.Graph, selected_export: ?[]const u8, provided: []const graph.RuntimeInput, recovered_context: ?[]const u8) ![]graph.RuntimeInput {
    var out: std.ArrayList(graph.RuntimeInput) = .empty;
    errdefer {
        freeRuntimeInputList(allocator, out.items, provided.len);
        out.deinit(allocator);
    }
    try out.appendSlice(allocator, provided);
    if (try graph.hasInputForExport(allocator, loaded_graph, selected_export, "recovered_context")) {
        const context = try allocator.dupe(u8, recovered_context orelse "");
        errdefer allocator.free(context);
        try out.append(allocator, .{ .id = try allocator.dupe(u8, "recovered_context"), .kind = .text, .value = context, .content_type = try allocator.dupe(u8, "text/plain") });
    }
    return out.toOwnedSlice(allocator);
}

fn runtimeInputsForRecovery(allocator: Allocator, loaded_graph: graph.Graph, log: sessions.Log, profile: *const config.RuntimeProfile, session: sessions.Session, user_prompt: []const u8, reach: []const u8) ![]graph.RuntimeInput {
    var out: std.ArrayList(graph.RuntimeInput) = .empty;
    errdefer {
        freeRuntimeInputList(allocator, out.items, 0);
        out.deinit(allocator);
    }
    if (graph.hasInput(loaded_graph, "primary_scope")) try appendRuntimeInput(allocator, &out, "primary_scope", try allocator.dupe(u8, if (@import("../runtime/scope.zig").default() == .local) "local" else "global"));
    if (graph.hasInput(loaded_graph, "session_id")) try appendRuntimeInput(allocator, &out, "session_id", try allocator.dupe(u8, session.id));
    if (graph.hasInput(loaded_graph, "branch")) try appendRuntimeInput(allocator, &out, "branch", try allocator.dupe(u8, "main"));
    if (graph.hasInput(loaded_graph, "message")) try appendRuntimeInput(allocator, &out, "message", try allocator.dupe(u8, user_prompt));
    if (graph.hasInput(loaded_graph, "reach")) try appendRuntimeInput(allocator, &out, "reach", try allocator.dupe(u8, reach));
    if (graph.hasInput(loaded_graph, "budget_chars")) try appendRuntimeInput(allocator, &out, "budget_chars", try std.fmt.allocPrint(allocator, "{d}", .{profile.recovery.budget_chars}));
    if (graph.hasInput(loaded_graph, "runtime_uri")) try appendRuntimeInput(allocator, &out, "runtime_uri", try allocator.dupe(u8, "runtime:current"));
    if (graph.hasInput(loaded_graph, "session_head")) try appendRuntimeInput(allocator, &out, "session_head", try renderSessionHead(allocator, log, profile));
    if (graph.hasInput(loaded_graph, "existing_compaction")) try appendRuntimeInput(allocator, &out, "existing_compaction", try renderExistingCompaction(allocator, log));
    if (graph.hasInput(loaded_graph, "retained_tail")) try appendRuntimeInput(allocator, &out, "retained_tail", try renderRetainedTail(allocator, log, profile));
    if (graph.hasInput(loaded_graph, "messages_to_compact")) try appendRuntimeInput(allocator, &out, "messages_to_compact", try renderMessagesToCompact(allocator, log, profile));
    return out.toOwnedSlice(allocator);
}

fn runtimeInputsForCompaction(allocator: Allocator, loaded_graph: graph.Graph, log: sessions.Log, profile: *const config.RuntimeProfile) ![]graph.RuntimeInput {
    var out: std.ArrayList(graph.RuntimeInput) = .empty;
    errdefer {
        freeRuntimeInputList(allocator, out.items, 0);
        out.deinit(allocator);
    }
    if (graph.hasInput(loaded_graph, "session_head")) try appendRuntimeInput(allocator, &out, "session_head", try renderSessionHead(allocator, log, profile));
    if (graph.hasInput(loaded_graph, "existing_compaction")) try appendRuntimeInput(allocator, &out, "existing_compaction", try renderExistingCompaction(allocator, log));
    if (graph.hasInput(loaded_graph, "messages_to_compact")) try appendRuntimeInput(allocator, &out, "messages_to_compact", try renderMessagesToCompact(allocator, log, profile));
    if (graph.hasInput(loaded_graph, "retained_tail")) try appendRuntimeInput(allocator, &out, "retained_tail", try renderRetainedTail(allocator, log, profile));
    return out.toOwnedSlice(allocator);
}

fn appendRuntimeInput(allocator: Allocator, out: *std.ArrayList(graph.RuntimeInput), id: []const u8, value: []u8) !void {
    errdefer allocator.free(value);
    try out.append(allocator, .{ .id = try allocator.dupe(u8, id), .kind = .text, .value = value, .content_type = try allocator.dupe(u8, "text/plain") });
}

fn freeRuntimeInputList(allocator: Allocator, inputs: []const graph.RuntimeInput, borrowed_prefix_len: usize) void {
    for (inputs[borrowed_prefix_len..]) |input| input.deinit(allocator);
    allocator.free(inputs);
}

fn renderSessionHead(allocator: Allocator, log: sessions.Log, profile: *const config.RuntimeProfile) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const head_end = @min(profile.runtime.session_head_messages, log.messages.len);
    for (log.messages[0..head_end], 0..) |message, i| try appendMessageLine(allocator, &out, i, message, profile.runtime.session_context_truncate_chars);
    return out.toOwnedSlice(allocator);
}

fn renderExistingCompaction(allocator: Allocator, log: sessions.Log) ![]u8 {
    if (log.compaction) |c| return std.fmt.allocPrint(allocator, "compacted_messages: {d}\nsummary: {s}\n", .{ c.message_count, c.summary });
    return allocator.dupe(u8, "");
}

fn renderMessagesToCompact(allocator: Allocator, log: sessions.Log, profile: *const config.RuntimeProfile) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const head_end = @min(profile.runtime.session_head_messages, log.messages.len);
    const tail_start = if (log.messages.len > profile.runtime.session_tail_messages) log.messages.len - profile.runtime.session_tail_messages else head_end;
    const compact_start = if (log.compaction) |c| @max(head_end, @as(usize, @min(c.message_count, log.messages.len))) else head_end;
    const compact_end = @max(compact_start, tail_start);
    for (log.messages[compact_start..compact_end], compact_start..) |message, i| try appendMessageLine(allocator, &out, i, message, profile.runtime.session_context_truncate_chars);
    return out.toOwnedSlice(allocator);
}

fn renderRetainedTail(allocator: Allocator, log: sessions.Log, profile: *const config.RuntimeProfile) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const head_end = @min(profile.runtime.session_head_messages, log.messages.len);
    const tail_start = if (log.messages.len > profile.runtime.session_tail_messages) log.messages.len - profile.runtime.session_tail_messages else head_end;
    for (log.messages[tail_start..], tail_start..) |message, i| try appendMessageLine(allocator, &out, i, message, profile.runtime.session_context_truncate_chars);
    return out.toOwnedSlice(allocator);
}

fn appendMessageLine(allocator: Allocator, out: *std.ArrayList(u8), index: usize, message: sessions.Message, max_chars: usize) !void {
    const content = std.mem.trim(u8, message.content, " \t\r\n");
    const limit = if (max_chars == 0) content.len else max_chars;
    try out.print(allocator, "[{d}] {s}: ", .{ index, message.role });
    if (content.len > limit) try out.print(allocator, "{s}... [truncated {d} chars; use session:current:messages:{d}]", .{ content[0..limit], content.len, index }) else try out.appendSlice(allocator, content);
    if (message.tool_call_id) |id| try out.print(allocator, " [tool_call_id={s}]", .{id});
    if (message.tool_calls.len != 0) try out.print(allocator, " [tool_calls={d}]", .{message.tool_calls.len});
    try out.append(allocator, '\n');
}

fn shouldCompactLog(allocator: Allocator, io: std.Io, log: sessions.Log, profile: *const config.RuntimeProfile) !bool {
    _ = io;
    if (profile.runtime.compaction_threshold_percent == 0 or log.messageCount() == 0) return false;
    if (log.compaction) |c| if (c.message_count >= log.messageCount()) return false;
    const prompt_tokens = try promptTokensForCompaction(allocator, log, profile);
    return prompt_tokens >= profile.model.context_window * profile.runtime.compaction_threshold_percent / 100;
}

fn promptTokensForCompaction(allocator: Allocator, log: sessions.Log, profile: *const config.RuntimeProfile) !usize {
    if (log.latestPromptTokens(profile.model.id)) |tokens| return tokens;
    const transcript = try log.transcript(allocator, profile.runtime.session_head_messages, profile.runtime.session_tail_messages, profile.runtime.session_context_truncate_chars);
    defer allocator.free(transcript);
    return (transcript.len + profile.model.chars_per_token - 1) / profile.model.chars_per_token;
}

fn parseStringField(allocator: Allocator, text: []const u8, field: []const u8) ![]u8 {
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return error.InvalidModelJson;
    const end = std.mem.lastIndexOfScalar(u8, text, '}') orelse return error.InvalidModelJson;
    if (end <= start) return error.InvalidModelJson;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text[start .. end + 1], .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidModelJson;
    const value = parsed.value.object.get(field) orelse return error.InvalidModelJson;
    if (value != .string or std.mem.trim(u8, value.string, " \t\r\n").len == 0) return error.InvalidModelJson;
    return allocator.dupe(u8, value.string);
}
