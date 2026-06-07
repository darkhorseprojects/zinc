const std = @import("std");
const config = @import("../config/mod.zig");
const ctxmod = @import("context.zig");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const graph = @import("mod.zig");
const resource = @import("resource.zig");
const sessions = @import("../runtime/session.zig");
const runtime = @import("../runtime/mod.zig");
const runtime_context = @import("../runtime/context.zig");

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
    var store = try runtime.Store.open(allocator, layout_ctx, runtime.scope.default());
    defer store.close();
    const run_meta = try std.fmt.allocPrint(allocator, "{{\"graph\":\"{s}\",\"target\":\"{s}\"}}", .{ graph_path, target });
    defer allocator.free(run_meta);
    const run_id = try store.startRun(session.id, "zn run", run_meta);
    defer allocator.free(run_id);
    const run_started = try store.appendEvent(.{ .session_id = session.id, .type = runtime.events.run_started, .summary = graph_path, .payload_json = run_meta });
    allocator.free(run_started);
    const graph_started = try store.appendEvent(.{ .session_id = session.id, .type = runtime.events.graph_started, .summary = target, .payload_json = run_meta });
    allocator.free(graph_started);
    errdefer {
        store.writeLog(.{ .run_id = run_id, .session_id = session.id, .level = "error", .component = "graph", .message = "run failed" }) catch {};
        const failed_event = store.appendEvent(.{ .session_id = session.id, .type = runtime.events.run_failed, .summary = graph_path, .payload_json = "{}" }) catch null;
        if (failed_event) |id| allocator.free(id);
        store.finishRun(run_id, "failed", null) catch {};
    }

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
    var ctx = ctxmod.RunContext{ .allocator = allocator, .io = io, .layout_ctx = layout_ctx, .home = layout_ctx.dirs.home, .profile = &profile, .graph_path = graph_path, .graph = &loaded_graph, .session = session, .log = &log, .inputs = bound_inputs, .frame = .interactive(target), .bash_allowances = &bash_allowances, .run_id = run_id };
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
    const graph_finished = try store.appendEvent(.{ .session_id = session.id, .type = runtime.events.graph_finished, .summary = target, .payload_json = "{}" });
    allocator.free(graph_finished);
    const run_finished = try store.appendEvent(.{ .session_id = session.id, .type = runtime.events.run_finished, .summary = graph_path, .payload_json = "{}" });
    allocator.free(run_finished);
    try store.finishRun(run_id, "finished", null);

    log.deinit(allocator);
    log = try sessions.read(allocator, layout_ctx, session);
    if (try shouldCompactLog(allocator, io, log, &profile)) try runCompaction(allocator, io, layout_ctx, &profile, session, profile.paths.compaction_graph);
}

fn recoveredContextForRun(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, loaded_graph: graph.Graph, selected_export: ?[]const u8, profile: *const config.RuntimeProfile, session: sessions.Session, log: sessions.Log, user_prompt: []const u8, recovery_override: RecoveryOverride) !?[]u8 {
    if (!try graph.hasInputForExport(allocator, loaded_graph, selected_export, "recovered_context")) return null;
    const boundary = compactionBoundary(log);
    if (log.recovery) |recovery| if (recovery.compaction_message_count == boundary) return try allocator.dupe(u8, recovery.text);
    const graph_path = recovery_override.graph orelse profile.recovery.graph;
    const reach = recovery_override.reach orelse profile.recovery.reach;
    if (std.mem.eql(u8, reach, "none")) return try allocator.dupe(u8, "");
    try sessions.appendRecoveryStarted(allocator, layout_ctx, session, reach, profile.recovery.budget_chars);
    var recovered = runContextRecovery(allocator, io, layout_ctx, profile, session, log, graph_path, user_prompt, reach) catch |err| {
        try sessions.appendRecoveryFailed(allocator, layout_ctx, session, @errorName(err));
        return err;
    };
    defer recovered.deinit(allocator);
    if (log.messageCount() != 0) try sessions.appendRecovery(allocator, layout_ctx, session, log.messageCount(), boundary, recovered.text, recovered.sources, recovered.notes);
    return recovered.takeText();
}

const RecoveryResult = struct {
    text: []u8,
    sources: [][]u8,
    notes: [][]u8,

    fn deinit(self: RecoveryResult, allocator: Allocator) void {
        if (self.text.len != 0) allocator.free(self.text);
        freeStrings(allocator, self.sources);
        freeStrings(allocator, self.notes);
    }

    fn takeText(self: *RecoveryResult) []u8 {
        const text = self.text;
        self.text = &.{};
        return text;
    }
};

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
    const context_snapshot = try runtime_context.build(allocator, layout_ctx, profile, session, log, "", "session");
    defer context_snapshot.deinit(allocator);
    const compaction_inputs = try runtime_context.bindInputsForExport(allocator, loaded_graph, null, context_snapshot);
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

fn runContextRecovery(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, profile: *const config.RuntimeProfile, session: sessions.Session, log: sessions.Log, graph_path: []const u8, user_prompt: []const u8, reach: []const u8) !RecoveryResult {
    if (log.messageCount() == 0) return .{ .text = try allocator.dupe(u8, ""), .sources = try allocator.alloc([]u8, 0), .notes = try allocator.alloc([]u8, 0) };
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
    const context_snapshot = try runtime_context.build(allocator, layout_ctx, profile, session, log, user_prompt, reach);
    defer context_snapshot.deinit(allocator);
    const recovery_inputs = try runtime_context.bindInputsForExport(allocator, loaded_graph, null, context_snapshot);
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
    return parseRecoveryResult(allocator, result.text);
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

fn freeRuntimeInputList(allocator: Allocator, inputs: []const graph.RuntimeInput, borrowed_prefix_len: usize) void {
    for (inputs[borrowed_prefix_len..]) |input| input.deinit(allocator);
    allocator.free(inputs);
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

fn parseRecoveryResult(allocator: Allocator, text: []const u8) !RecoveryResult {
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return error.InvalidModelJson;
    const end = std.mem.lastIndexOfScalar(u8, text, '}') orelse return error.InvalidModelJson;
    if (end <= start) return error.InvalidModelJson;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text[start .. end + 1], .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidModelJson;
    const obj = parsed.value.object;
    const text_value = obj.get("text") orelse return error.InvalidModelJson;
    if (text_value != .string) return error.InvalidModelJson;
    return .{ .text = try allocator.dupe(u8, text_value.string), .sources = try parseStringArray(allocator, obj, "sources"), .notes = try parseStringArray(allocator, obj, "notes") };
}

fn parseStringArray(allocator: Allocator, obj: std.json.ObjectMap, name: []const u8) ![][]u8 {
    const value = obj.get(name) orelse return allocator.alloc([]u8, 0);
    if (value != .array) return error.InvalidModelJson;
    var out = try allocator.alloc([]u8, value.array.items.len);
    errdefer freeStrings(allocator, out);
    for (value.array.items, 0..) |item, i| {
        if (item != .string) return error.InvalidModelJson;
        out[i] = try allocator.dupe(u8, item.string);
    }
    return out;
}

fn freeStrings(allocator: Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}
