const std = @import("std");
const sqlite = @import("sqlite");
const inspect = @import("inspect.zig");
const layout = @import("../io/layout.zig");
const scope = @import("scope.zig");
const sessions = @import("session.zig");
const Store = @import("store.zig").Store;

const Allocator = std.mem.Allocator;

pub fn dbPathReady(allocator: Allocator, layout_ctx: layout.Context) ![]u8 {
    var store = try Store.open(allocator, layout_ctx, scope.default());
    const path = try allocator.dupe(u8, store.path);
    store.close();
    return path;
}

pub fn query(allocator: Allocator, layout_ctx: layout.Context, sql: []const u8) ![]u8 {
    const path = try dbPathReady(allocator, layout_ctx);
    defer allocator.free(path);
    return inspect.query(allocator, path, sql);
}

pub fn sessionList(allocator: Allocator, layout_ctx: layout.Context) ![]u8 {
    return query(allocator, layout_ctx, "select id, current_branch, updated_at, cwd from sessions order by updated_at desc limit 64");
}

pub fn sessionShow(allocator: Allocator, layout_ctx: layout.Context, id: []const u8) ![]u8 {
    return query1(allocator, layout_ctx, "select id, title, cwd, current_branch, status, created_at, updated_at from sessions where id = '{s}'", id);
}

pub fn sessionEvents(allocator: Allocator, layout_ctx: layout.Context, id: []const u8) ![]u8 {
    return query1(allocator, layout_ctx, "select time, id, parent_id, branch, type, source_kind, source_name, summary from events where session_id = '{s}' order by time", id);
}

pub fn sessionTree(allocator: Allocator, layout_ctx: layout.Context, id: ?[]const u8) ![]u8 {
    if (id) |session_id| return query1(allocator, layout_ctx, "select session_id, branch, head_event_id, updated_at from branch_heads where session_id = '{s}' order by updated_at desc", session_id);
    return query(allocator, layout_ctx, "select session_id, branch, head_event_id, updated_at from branch_heads order by updated_at desc");
}

pub fn eventTail(allocator: Allocator, layout_ctx: layout.Context) ![]u8 {
    return query(allocator, layout_ctx, "select time, id, session_id, branch, type, summary from recent_events limit 40");
}

pub fn eventCurrent(allocator: Allocator, layout_ctx: layout.Context) ![]u8 {
    return query(allocator, layout_ctx, "select * from recent_events limit 1");
}

pub fn eventShow(allocator: Allocator, layout_ctx: layout.Context, id: []const u8) ![]u8 {
    return query1(allocator, layout_ctx, "select time, id, session_id, parent_id, branch, type, source_kind, source_name, summary from events where id = '{s}'", id);
}

pub fn eventPayload(allocator: Allocator, layout_ctx: layout.Context, id: []const u8) ![]u8 {
    return query1(allocator, layout_ctx, "select payload_json from events where id = '{s}'", id);
}

pub fn eventLogs(allocator: Allocator, layout_ctx: layout.Context, id: []const u8) ![]u8 {
    return query1(allocator, layout_ctx, "select time, level, component, message, run_id from logs where event_id = '{s}' order by time", id);
}

pub fn logsCurrent(allocator: Allocator, layout_ctx: layout.Context) ![]u8 {
    return query(allocator, layout_ctx, "select time, level, component, message, event_id, run_id from recent_logs limit 80");
}

pub fn logsForEvent(allocator: Allocator, layout_ctx: layout.Context, id: []const u8) ![]u8 {
    return query1(allocator, layout_ctx, "select time, level, component, message, run_id from logs where event_id = '{s}' order by time", id);
}

pub fn logsForRun(allocator: Allocator, layout_ctx: layout.Context, id: []const u8) ![]u8 {
    return query1(allocator, layout_ctx, "select time, level, component, message, event_id from logs where run_id = '{s}' order by time", id);
}

pub fn branchCurrent(allocator: Allocator, layout_ctx: layout.Context, session_id: []const u8) ![]u8 {
    return query1(allocator, layout_ctx, "select current_branch from sessions where id = '{s}'", session_id);
}

pub fn branchSummary(allocator: Allocator, layout_ctx: layout.Context, session_id: []const u8, branch: []const u8) ![]u8 {
    try validateToken(session_id);
    try validateToken(branch);
    const sql = try std.fmt.allocPrint(allocator, "select session_id, branch, head_event_id, updated_at from branch_heads where session_id = '{s}' and branch = '{s}'", .{ session_id, branch });
    defer allocator.free(sql);
    return query(allocator, layout_ctx, sql);
}

pub fn branchEvents(allocator: Allocator, layout_ctx: layout.Context, session_id: []const u8, branch: []const u8) ![]u8 {
    try validateToken(session_id);
    try validateToken(branch);
    const sql = try std.fmt.allocPrint(allocator, "select time, id, type, summary from events where session_id = '{s}' and branch = '{s}' order by time", .{ session_id, branch });
    defer allocator.free(sql);
    return query(allocator, layout_ctx, sql);
}

pub fn recoveryCurrent(allocator: Allocator, layout_ctx: layout.Context) ![]u8 {
    return query(allocator, layout_ctx, "select time, id, type, summary, payload_json from events where type like 'context.recovery.%' order by time desc limit 8");
}

pub fn recoverySources(allocator: Allocator, layout_ctx: layout.Context, event_id: []const u8) ![]u8 {
    return query1(allocator, layout_ctx, "select json_extract(payload_json, '$.sources') as sources from events where id = '{s}' and type = 'context.recovery.finished'", event_id);
}

pub fn packageSummary(allocator: Allocator, layout_ctx: layout.Context, name: []const u8) ![]u8 {
    try validateToken(name);
    const sql = try std.fmt.allocPrint(allocator, "select source_name, count(*) as events from events where source_name = '{s}' or type like 'package.{s}.%' group by source_name", .{ name, name });
    defer allocator.free(sql);
    return query(allocator, layout_ctx, sql);
}

pub fn packageEvents(allocator: Allocator, layout_ctx: layout.Context, name: []const u8) ![]u8 {
    try validateToken(name);
    const sql = try std.fmt.allocPrint(allocator, "select time, id, type, summary from events where source_name = '{s}' or type like 'package.{s}.%' order by time desc limit 40", .{ name, name });
    defer allocator.free(sql);
    return query(allocator, layout_ctx, sql);
}

pub fn runtimeSummary(allocator: Allocator, layout_ctx: layout.Context, session_id: []const u8) ![]u8 {
    const db_path = try scope.dbPath(allocator, layout_ctx, scope.default());
    defer allocator.free(db_path);
    return std.fmt.allocPrint(allocator, "scope: {s}\ndb: {s}\nsession: {s}\n", .{ @tagName(scope.default()), db_path, session_id });
}

pub fn sessionsIndex(allocator: Allocator, layout_ctx: layout.Context) ![]u8 {
    var store = try Store.open(allocator, layout_ctx, scope.default());
    defer store.close();
    const Row = struct { id: sqlite.Text, title: ?sqlite.Text, updated_at: sqlite.Text };
    const stmt = try store.db.prepare(struct {}, Row, "select id, title, updated_at from sessions order by updated_at desc limit 64");
    defer stmt.finalize();
    try stmt.bind(.{});
    defer stmt.reset();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (try stmt.step()) |row| try out.print(allocator, "- {s} updated={s}\n", .{ row.id.data, row.updated_at.data });
    return out.toOwnedSlice(allocator);
}

pub fn sessionLog(allocator: Allocator, layout_ctx: layout.Context, session_id: []const u8) !sessions.Log {
    const session = sessions.Session{ .id = try allocator.dupe(u8, session_id) };
    defer session.deinit(allocator);
    return sessions.read(allocator, layout_ctx, session);
}

pub fn sessionTranscript(allocator: Allocator, layout_ctx: layout.Context, session_id: []const u8, head_messages: usize, tail_messages: usize, truncate_chars: usize) ![]u8 {
    const log = try sessionLog(allocator, layout_ctx, session_id);
    defer log.deinit(allocator);
    return log.transcript(allocator, head_messages, tail_messages, truncate_chars);
}

pub fn sessionToolResult(allocator: Allocator, layout_ctx: layout.Context, session_id: []const u8, tool_id: []const u8) ![]u8 {
    const log = try sessionLog(allocator, layout_ctx, session_id);
    defer log.deinit(allocator);
    for (log.messages) |message| {
        if (!std.mem.eql(u8, message.role, "tool")) continue;
        if (message.tool_call_id) |id| if (std.mem.eql(u8, id, tool_id)) return allocator.dupe(u8, message.content);
    }
    return error.ToolResultNotFound;
}

pub fn sessionMessage(allocator: Allocator, layout_ctx: layout.Context, session_id: []const u8, raw_index: []const u8) ![]u8 {
    const index = try std.fmt.parseInt(usize, raw_index, 10);
    const log = try sessionLog(allocator, layout_ctx, session_id);
    defer log.deinit(allocator);
    if (index >= log.messages.len) return error.MessageIndexOutOfBounds;
    return allocator.dupe(u8, log.messages[index].content);
}

fn query1(allocator: Allocator, layout_ctx: layout.Context, comptime sql_fmt: []const u8, id: []const u8) ![]u8 {
    try validateToken(id);
    const sql = try std.fmt.allocPrint(allocator, sql_fmt, .{id});
    defer allocator.free(sql);
    return query(allocator, layout_ctx, sql);
}

pub fn validateToken(value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidRuntimeToken;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.InvalidRuntimeToken;
}
