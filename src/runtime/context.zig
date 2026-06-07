const std = @import("std");
const config = @import("../config/mod.zig");
const graph = @import("../graph/mod.zig");
const layout = @import("../io/layout.zig");
const scopes = @import("scope.zig");
const sessions = @import("session.zig");
const Store = @import("store.zig").Store;

const Allocator = std.mem.Allocator;

pub const Snapshot = struct {
    primary_scope: []u8,
    cwd: []u8,
    session_id: []u8,
    branch: []u8,
    message: []u8,
    reach: []u8,
    budget_chars: []u8,
    runtime_uri: []u8,
    session_uri: []u8,
    branch_uri: []u8,
    logs_uri: []u8,
    session_head: []u8,
    existing_compaction: []u8,
    retained_tail: []u8,
    messages_to_compact: []u8,

    pub fn deinit(self: Snapshot, allocator: Allocator) void {
        allocator.free(self.primary_scope);
        allocator.free(self.cwd);
        allocator.free(self.session_id);
        allocator.free(self.branch);
        allocator.free(self.message);
        allocator.free(self.reach);
        allocator.free(self.budget_chars);
        allocator.free(self.runtime_uri);
        allocator.free(self.session_uri);
        allocator.free(self.branch_uri);
        allocator.free(self.logs_uri);
        allocator.free(self.session_head);
        allocator.free(self.existing_compaction);
        allocator.free(self.retained_tail);
        allocator.free(self.messages_to_compact);
    }
};

pub fn build(allocator: Allocator, layout_ctx: layout.Context, profile: *const config.RuntimeProfile, session: sessions.Session, log: sessions.Log, message: []const u8, reach: []const u8) !Snapshot {
    const scope = scopes.default();
    const primary_scope = try allocator.dupe(u8, @tagName(scope));
    errdefer allocator.free(primary_scope);
    const path = try std.process.currentPathAlloc(std.Options.debug_io, allocator);
    defer allocator.free(path);
    const cwd = try allocator.dupe(u8, path);
    errdefer allocator.free(cwd);
    const session_id = try allocator.dupe(u8, session.id);
    errdefer allocator.free(session_id);
    var store = try Store.open(allocator, layout_ctx, scope);
    defer store.close();
    const branch = try store.currentBranch(allocator, session.id);
    errdefer allocator.free(branch);
    const message_text = try allocator.dupe(u8, message);
    errdefer allocator.free(message_text);
    const reach_text = try allocator.dupe(u8, reach);
    errdefer allocator.free(reach_text);
    const budget_chars = try std.fmt.allocPrint(allocator, "{d}", .{profile.recovery.budget_chars});
    errdefer allocator.free(budget_chars);
    const runtime_uri = try allocator.dupe(u8, "runtime:current");
    errdefer allocator.free(runtime_uri);
    const session_uri = try allocator.dupe(u8, "session:current");
    errdefer allocator.free(session_uri);
    const branch_uri = try allocator.dupe(u8, "branch:current");
    errdefer allocator.free(branch_uri);
    const logs_uri = try allocator.dupe(u8, "log:current");
    errdefer allocator.free(logs_uri);
    const session_head = try renderSessionHead(allocator, log, profile);
    errdefer allocator.free(session_head);
    const existing_compaction = try renderExistingCompaction(allocator, log);
    errdefer allocator.free(existing_compaction);
    const retained_tail = try renderRetainedTail(allocator, log, profile);
    errdefer allocator.free(retained_tail);
    const messages_to_compact = try renderMessagesToCompact(allocator, log, profile);
    errdefer allocator.free(messages_to_compact);
    return .{
        .primary_scope = primary_scope,
        .cwd = cwd,
        .session_id = session_id,
        .branch = branch,
        .message = message_text,
        .reach = reach_text,
        .budget_chars = budget_chars,
        .runtime_uri = runtime_uri,
        .session_uri = session_uri,
        .branch_uri = branch_uri,
        .logs_uri = logs_uri,
        .session_head = session_head,
        .existing_compaction = existing_compaction,
        .retained_tail = retained_tail,
        .messages_to_compact = messages_to_compact,
    };
}

pub fn bindInputsForExport(allocator: Allocator, loaded_graph: graph.Graph, selected_export: ?[]const u8, snapshot: Snapshot) ![]graph.RuntimeInput {
    const specs = try graph.readInputSpecsForExport(allocator, loaded_graph, selected_export);
    defer graph.freeInputSpecs(allocator, specs);
    var out: std.ArrayList(graph.RuntimeInput) = .empty;
    errdefer {
        for (out.items) |input| input.deinit(allocator);
        out.deinit(allocator);
    }
    for (specs) |spec| if (try valueFor(allocator, snapshot, spec.id)) |value| {
        errdefer allocator.free(value);
        try out.append(allocator, .{ .id = try allocator.dupe(u8, spec.id), .kind = .text, .value = value, .content_type = try allocator.dupe(u8, "text/plain") });
    };
    return out.toOwnedSlice(allocator);
}

fn valueFor(allocator: Allocator, snapshot: Snapshot, id: []const u8) !?[]u8 {
    if (std.mem.eql(u8, id, "primary_scope")) return try allocator.dupe(u8, snapshot.primary_scope);
    if (std.mem.eql(u8, id, "scope")) return try allocator.dupe(u8, snapshot.primary_scope);
    if (std.mem.eql(u8, id, "cwd")) return try allocator.dupe(u8, snapshot.cwd);
    if (std.mem.eql(u8, id, "session_id")) return try allocator.dupe(u8, snapshot.session_id);
    if (std.mem.eql(u8, id, "branch")) return try allocator.dupe(u8, snapshot.branch);
    if (std.mem.eql(u8, id, "message")) return try allocator.dupe(u8, snapshot.message);
    if (std.mem.eql(u8, id, "reach")) return try allocator.dupe(u8, snapshot.reach);
    if (std.mem.eql(u8, id, "budget_chars")) return try allocator.dupe(u8, snapshot.budget_chars);
    if (std.mem.eql(u8, id, "runtime_uri")) return try allocator.dupe(u8, snapshot.runtime_uri);
    if (std.mem.eql(u8, id, "session_uri")) return try allocator.dupe(u8, snapshot.session_uri);
    if (std.mem.eql(u8, id, "branch_uri")) return try allocator.dupe(u8, snapshot.branch_uri);
    if (std.mem.eql(u8, id, "logs_uri")) return try allocator.dupe(u8, snapshot.logs_uri);
    if (std.mem.eql(u8, id, "session_head")) return try allocator.dupe(u8, snapshot.session_head);
    if (std.mem.eql(u8, id, "existing_compaction")) return try allocator.dupe(u8, snapshot.existing_compaction);
    if (std.mem.eql(u8, id, "retained_tail")) return try allocator.dupe(u8, snapshot.retained_tail);
    if (std.mem.eql(u8, id, "messages_to_compact")) return try allocator.dupe(u8, snapshot.messages_to_compact);
    return null;
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
