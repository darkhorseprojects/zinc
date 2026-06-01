const std = @import("std");
const config = @import("../runtime/config.zig");
const ctxmod = @import("context.zig");
const files = @import("../sys/fs.zig");
const graph = @import("graph.zig");
const provider = @import("../runtime/provider.zig");
const resource = @import("resource.zig");
const sessions = @import("../runtime/session.zig");
const trace = @import("../sys/trace.zig");

const Allocator = std.mem.Allocator;
const context_chars_per_token: usize = 3;

fn fail(comptime fmt: []const u8, args: anytype) error{UserError}!void {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    return error.UserError;
}

pub fn run(allocator: Allocator, io: std.Io, home: []const u8, user_prompt: []const u8, resume_id: ?[]const u8, continue_last: bool, graph_path_override: ?[]const u8, runtime_inputs: []const graph.RuntimeInput) !void {
    const runtime_paths = try config.loadRuntimePaths(allocator, io, home);
    defer runtime_paths.deinit(allocator);
    return runGraph(allocator, io, home, graph_path_override orelse runtime_paths.graph, null, user_prompt, resume_id, continue_last, runtime_inputs);
}

pub fn compactSession(allocator: Allocator, io: std.Io, home: []const u8, graph_path: []const u8, resume_id: ?[]const u8, continue_last: bool) !void {
    const model_id = try config.resolveConfiguredModelId(allocator, io, home);
    defer allocator.free(model_id);
    const profile = try config.loadRuntimeProfile(allocator, io, home, model_id);
    defer profile.deinit(allocator);
    const session = try sessions.open(allocator, resume_id, continue_last);
    defer session.deinit(allocator);
    try runCompaction(allocator, io, home, &profile, session, graph_path);
    try sessions.rememberLast(session);
}

pub fn runGraph(allocator: Allocator, io: std.Io, home: []const u8, graph_path: []const u8, entry_override: ?[]const u8, user_prompt: []const u8, resume_id: ?[]const u8, continue_last: bool, runtime_inputs: []const graph.RuntimeInput) !void {
    const span = trace.span("engine_run");
    defer span.end("engine", "graph={s} prompt_chars={d}", .{ graph_path, user_prompt.len });

    const loaded_graph = try graph.load(allocator, io, graph_path);
    defer loaded_graph.deinit(allocator);
    try graph.validate(loaded_graph);
    const entry = graph.entryResourceId(loaded_graph, entry_override) orelse return fail("graph has no entry; add `entry: <resource>` or pass `--entry`", .{});
    if (graph.resource(loaded_graph, entry) == null) return fail("entry not found: {s}", .{entry});

    const model_id = try config.resolveGraphModelId(allocator, io, loaded_graph, home);
    defer allocator.free(model_id);
    const profile = try config.loadRuntimeProfile(allocator, io, home, model_id);
    defer profile.deinit(allocator);

    const session = try sessions.open(allocator, resume_id, continue_last);
    defer session.deinit(allocator);

    var log = try sessions.readParsed(allocator, session.path);
    defer log.deinit(allocator);
    if (try shouldCompactLog(allocator, log, &profile)) {
        try runCompaction(allocator, io, home, &profile, session, profile.paths.compaction_graph);
        log.deinit(allocator);
        log = try sessions.readParsed(allocator, session.path);
    }

    const bound_inputs = try resource.bindInputs(allocator, loaded_graph, user_prompt, runtime_inputs);
    defer resource.freeBoundInputs(allocator, bound_inputs);

    var bash_allowances: ctxmod.BashAllowances = .empty;
    defer {
        for (bash_allowances.items) |item| item.deinit(allocator);
        bash_allowances.deinit(allocator);
    }
    var ctx = ctxmod.RunContext{ .allocator = allocator, .io = io, .home = home, .profile = &profile, .graph_path = graph_path, .graph = &loaded_graph, .session = session, .log = &log, .inputs = bound_inputs, .frame = .interactive(entry), .bash_allowances = &bash_allowances };
    const result = resource.resolve(&ctx, entry) catch |err| switch (err) {
        error.GraphRunDeniedByUser => {
            _ = try files.linuxWrite(1, "graph run denied\n");
            return;
        },
        else => return err,
    };
    defer result.deinit(allocator);
    const response = std.mem.trim(u8, result.text, " \t\r\n");
    if (response.len == 0) return error.EmptyAssistantResponse;
    _ = try files.linuxWrite(1, response);
    _ = try files.linuxWrite(1, "\n");

    log.deinit(allocator);
    log = try sessions.readParsed(allocator, session.path);
    if (try shouldCompactLog(allocator, log, &profile)) try runCompaction(allocator, io, home, &profile, session, profile.paths.compaction_graph);
}

fn runCompaction(allocator: Allocator, io: std.Io, home: []const u8, profile: *const config.RuntimeProfile, session: sessions.Session, graph_path: []const u8) !void {
    const log = try sessions.readParsed(allocator, session.path);
    defer log.deinit(allocator);
    if (log.messageCount() == 0) return;
    const loaded_graph = try graph.load(allocator, io, graph_path);
    defer loaded_graph.deinit(allocator);
    const entry = loaded_graph.entry orelse return fail("graph has no entry; add `entry: <resource>` or pass `--entry`", .{});
    if (graph.resource(loaded_graph, entry) == null) return fail("entry not found: {s}", .{entry});
    var log_mut = try sessions.readParsed(allocator, session.path);
    defer log_mut.deinit(allocator);
    const bound = try resource.bindInputs(allocator, loaded_graph, "", &.{});
    defer resource.freeBoundInputs(allocator, bound);
    var bash_allowances: ctxmod.BashAllowances = .empty;
    defer {
        for (bash_allowances.items) |item| item.deinit(allocator);
        bash_allowances.deinit(allocator);
    }
    var ctx = ctxmod.RunContext{ .allocator = allocator, .io = io, .home = home, .profile = profile, .graph_path = graph_path, .graph = &loaded_graph, .session = session, .log = &log_mut, .inputs = bound, .frame = .maintenance(entry), .bash_allowances = &bash_allowances };
    const result = try resource.resolve(&ctx, entry);
    defer result.deinit(allocator);
    const summary = try parseSummary(allocator, result.text);
    defer allocator.free(summary);
    try sessions.appendCompaction(allocator, session.path, log.messageCount(), summary);
}

fn shouldCompactLog(allocator: Allocator, log: sessions.Log, profile: *const config.RuntimeProfile) !bool {
    if (profile.runtime.compaction_threshold_percent == 0 or log.messageCount() == 0) return false;
    if (log.compaction) |c| if (c.message_count >= log.messageCount()) return false;
    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(allocator);
    defer provider.freeMessages(allocator, messages.items);
    try log.appendReplayMessages(allocator, &messages, "", profile.runtime.session_head_messages, profile.runtime.session_tail_messages, profile.runtime.replay_truncate_chars);
    return shouldCompactMessages(messages.items, profile);
}

fn shouldCompactMessages(messages: []const provider.Message, profile: *const config.RuntimeProfile) bool {
    const context_tokens = profile.model.loader.fit_ctx;
    if (context_tokens == 0) return false;
    return messageChars(messages) / context_chars_per_token >= context_tokens * profile.runtime.compaction_threshold_percent / 100;
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

fn parseSummary(allocator: Allocator, text: []const u8) ![]u8 {
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return allocator.dupe(u8, text);
    const end = std.mem.lastIndexOfScalar(u8, text, '}') orelse return allocator.dupe(u8, text);
    if (end <= start) return allocator.dupe(u8, text);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text[start .. end + 1], .{}) catch return allocator.dupe(u8, text);
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, text);
    const summary = parsed.value.object.get("summary") orelse return allocator.dupe(u8, text);
    if (summary != .string or std.mem.trim(u8, summary.string, " \t\r\n").len == 0) return allocator.dupe(u8, text);
    return allocator.dupe(u8, summary.string);
}
