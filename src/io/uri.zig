const std = @import("std");
const config = @import("../config/mod.zig");
const layout = @import("layout.zig");
const runtime = @import("../runtime/mod.zig");
const sessions = @import("../runtime/session.zig");

const Allocator = std.mem.Allocator;

pub const Context = struct {
    layout_ctx: layout.Context,
    session_id: []const u8,
    session_head_messages: usize,
    session_tail_messages: usize,
    session_context_truncate_chars: usize,
    inputs: []const Input,
};

pub const Input = struct {
    id: []const u8,
    value: []const u8,
};

pub fn resolve(allocator: Allocator, io: std.Io, ctx: Context, raw: []const u8) !?[]u8 {
    const split = splitByteRange(raw);
    const content = try resolveWithoutRange(allocator, io, ctx, split.base) orelse return null;
    errdefer allocator.free(content);
    if (split.range) |range| return try sliceRange(allocator, content, range);
    return content;
}

fn resolveWithoutRange(allocator: Allocator, io: std.Io, ctx: Context, raw: []const u8) !?[]u8 {
    if (std.mem.startsWith(u8, raw, "prompt:")) return try config.readPromptPack(allocator, io, ctx.layout_ctx, raw["prompt:".len..]);
    if (std.mem.startsWith(u8, raw, "input:")) return try inputValue(allocator, ctx, raw["input:".len..]);
    if (std.mem.eql(u8, raw, "runtime:db")) return try runtime.scope.dbPath(allocator, ctx.layout_ctx, runtime.scope.default());
    if (std.mem.eql(u8, raw, "runtime:current")) return try runtimeSummary(allocator, ctx);
    if (std.mem.eql(u8, raw, "session:current")) return try sessionTranscript(allocator, ctx);
    if (std.mem.eql(u8, raw, "session:last")) return try std.fmt.allocPrint(allocator, "id: {s}\n", .{ctx.session_id});
    if (std.mem.eql(u8, raw, "sessions:index")) return try sessionsIndex(allocator, ctx);
    if (std.mem.startsWith(u8, raw, "session:current:tools:")) return try sessionToolResult(allocator, ctx, raw["session:current:tools:".len..]);
    if (std.mem.startsWith(u8, raw, "session:current:messages:")) return try sessionMessage(allocator, ctx, raw["session:current:messages:".len..]);
    if (std.mem.eql(u8, raw, "event:current")) return try queryRuntime(allocator, ctx, "select * from recent_events limit 1");
    if (std.mem.startsWith(u8, raw, "event:") and std.mem.endsWith(u8, raw, ":payload")) return try eventPayload(allocator, ctx, raw["event:".len .. raw.len - ":payload".len]);
    if (std.mem.startsWith(u8, raw, "event:") and std.mem.endsWith(u8, raw, ":logs")) return try queryRuntimeFmt(allocator, ctx, "select time, level, component, message from logs where event_id = '{s}' order by time", raw["event:".len .. raw.len - ":logs".len]);
    if (std.mem.startsWith(u8, raw, "event:") and std.mem.endsWith(u8, raw, ":artifacts")) return try queryRuntimeFmt(allocator, ctx, "select id, kind, uri, bytes from artifacts where event_id = '{s}' order by created_at", raw["event:".len .. raw.len - ":artifacts".len]);
    if (std.mem.startsWith(u8, raw, "event:")) return try queryRuntimeFmt(allocator, ctx, "select time, id, session_id, branch, type, summary from events where id = '{s}'", raw["event:".len..]);
    if (std.mem.eql(u8, raw, "branch:current")) return try queryRuntimeFmt(allocator, ctx, "select current_branch from sessions where id = '{s}'", ctx.session_id);
    if (std.mem.startsWith(u8, raw, "branch:") and std.mem.endsWith(u8, raw, ":events")) return try branchEvents(allocator, ctx, raw["branch:".len .. raw.len - ":events".len]);
    if (std.mem.eql(u8, raw, "log:current")) return try queryRuntime(allocator, ctx, "select time, level, component, message, event_id from recent_logs limit 80");
    if (std.mem.startsWith(u8, raw, "log:event:")) return try queryRuntimeFmt(allocator, ctx, "select time, level, component, message from logs where event_id = '{s}' order by time", raw["log:event:".len..]);
    if (std.mem.startsWith(u8, raw, "log:run:")) return try queryRuntimeFmt(allocator, ctx, "select time, level, component, message, event_id from logs where run_id = '{s}' order by time", raw["log:run:".len..]);
    if (std.mem.startsWith(u8, raw, "artifact:") and std.mem.endsWith(u8, raw, ":metadata")) return try queryRuntimeFmt(allocator, ctx, "select metadata_json from artifacts where id = '{s}'", raw["artifact:".len .. raw.len - ":metadata".len]);
    if (std.mem.startsWith(u8, raw, "artifact:")) return try artifactContent(allocator, ctx, raw["artifact:".len..]);
    if (std.mem.eql(u8, raw, "recovery:current")) return try queryRuntime(allocator, ctx, "select time, id, type, summary, payload_json from events where type like 'context.recovery.%' order by time desc limit 8");
    if (std.mem.startsWith(u8, raw, "package:") and std.mem.endsWith(u8, raw, ":events")) return try packageEvents(allocator, ctx, raw["package:".len .. raw.len - ":events".len]);
    return null;
}

fn queryRuntime(allocator: Allocator, ctx: Context, sql: []const u8) ![]u8 {
    const path = try runtime.scope.dbPath(allocator, ctx.layout_ctx, runtime.scope.default());
    defer allocator.free(path);
    return runtime.inspect.query(allocator, path, sql);
}

fn queryRuntimeFmt(allocator: Allocator, ctx: Context, comptime fmt: []const u8, value: []const u8) ![]u8 {
    try validateToken(value);
    const sql = try std.fmt.allocPrint(allocator, fmt, .{value});
    defer allocator.free(sql);
    return try queryRuntime(allocator, ctx, sql);
}

fn eventPayload(allocator: Allocator, ctx: Context, event_id: []const u8) ![]u8 {
    return try queryRuntimeFmt(allocator, ctx, "select payload_json from events where id = '{s}'", event_id);
}

fn artifactContent(allocator: Allocator, ctx: Context, artifact_id: []const u8) ![]u8 {
    try validateToken(artifact_id);
    var store = try runtime.Store.open(allocator, ctx.layout_ctx, runtime.scope.default());
    defer store.close();
    const sqlite = @import("sqlite");
    const Row = struct { uri: sqlite.Text };
    const stmt = try store.db.prepare(struct { id: sqlite.Text }, Row, "select uri from artifacts where id = :id");
    defer stmt.finalize();
    try stmt.bind(.{ .id = sqlite.text(artifact_id) });
    defer stmt.reset();
    const row = try stmt.step() orelse return error.ArtifactNotFound;
    if (std.mem.startsWith(u8, row.uri.data, "file:")) return std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, row.uri.data["file:".len..], allocator, .limited(32 * 1024 * 1024));
    return allocator.dupe(u8, row.uri.data);
}

fn branchEvents(allocator: Allocator, ctx: Context, branch: []const u8) ![]u8 {
    try validateToken(branch);
    const sql = try std.fmt.allocPrint(allocator, "select time, id, type, summary from events where session_id = '{s}' and branch = '{s}' order by time", .{ ctx.session_id, branch });
    defer allocator.free(sql);
    return try queryRuntime(allocator, ctx, sql);
}

fn packageEvents(allocator: Allocator, ctx: Context, name: []const u8) ![]u8 {
    try validateToken(name);
    const sql = try std.fmt.allocPrint(allocator, "select time, id, type, summary from events where source_name = '{s}' or type like 'package.{s}.%' order by time desc limit 40", .{ name, name });
    defer allocator.free(sql);
    return try queryRuntime(allocator, ctx, sql);
}

fn validateToken(value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidRuntimeUri;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.InvalidRuntimeUri;
}

fn inputValue(allocator: Allocator, ctx: Context, id: []const u8) ![]u8 {
    for (ctx.inputs) |input| if (std.mem.eql(u8, input.id, id)) return allocator.dupe(u8, input.value);
    return error.InputNotFound;
}

fn runtimeSummary(allocator: Allocator, ctx: Context) ![]u8 {
    const db_path = try runtime.scope.dbPath(allocator, ctx.layout_ctx, runtime.scope.default());
    defer allocator.free(db_path);
    return try std.fmt.allocPrint(allocator, "scope: {s}\ndb: {s}\nsession: {s}\n", .{ @tagName(runtime.scope.default()), db_path, ctx.session_id });
}

fn sessionLog(allocator: Allocator, ctx: Context) !sessions.Log {
    const session = sessions.Session{ .id = try allocator.dupe(u8, ctx.session_id) };
    defer session.deinit(allocator);
    return sessions.read(allocator, ctx.layout_ctx, session);
}

fn sessionTranscript(allocator: Allocator, ctx: Context) ![]u8 {
    const log = try sessionLog(allocator, ctx);
    defer log.deinit(allocator);
    return log.transcript(allocator, ctx.session_head_messages, ctx.session_tail_messages, ctx.session_context_truncate_chars);
}

fn sessionsIndex(allocator: Allocator, ctx: Context) ![]u8 {
    var store = try runtime.Store.open(allocator, ctx.layout_ctx, runtime.scope.default());
    defer store.close();
    const Row = struct { id: @import("sqlite").Text, title: ?@import("sqlite").Text, updated_at: @import("sqlite").Text };
    const stmt = try store.db.prepare(struct {}, Row, "select id, title, updated_at from sessions order by updated_at desc limit 64");
    defer stmt.finalize();
    try stmt.bind(.{});
    defer stmt.reset();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    while (try stmt.step()) |row| try out.print(allocator, "- {s} updated={s}\n", .{ row.id.data, row.updated_at.data });
    return out.toOwnedSlice(allocator);
}

fn sessionToolResult(allocator: Allocator, ctx: Context, tool_id: []const u8) ![]u8 {
    const log = try sessionLog(allocator, ctx);
    defer log.deinit(allocator);
    for (log.messages) |message| {
        if (!std.mem.eql(u8, message.role, "tool")) continue;
        if (message.tool_call_id) |id| if (std.mem.eql(u8, id, tool_id)) return allocator.dupe(u8, message.content);
    }
    return error.ToolResultNotFound;
}

fn sessionMessage(allocator: Allocator, ctx: Context, raw_index: []const u8) ![]u8 {
    const index = try std.fmt.parseInt(usize, raw_index, 10);
    const log = try sessionLog(allocator, ctx);
    defer log.deinit(allocator);
    if (index >= log.messages.len) return error.MessageIndexOutOfBounds;
    return allocator.dupe(u8, log.messages[index].content);
}

const ByteRange = struct { start: usize, end: ?usize };
const RangeSplit = struct { base: []const u8, range: ?[]const u8 };

fn splitByteRange(raw: []const u8) RangeSplit {
    const marker = ":bytes=";
    if (std.mem.lastIndexOf(u8, raw, marker)) |pos| return .{ .base = raw[0..pos], .range = raw[pos + marker.len ..] };
    return .{ .base = raw, .range = null };
}

fn parseRange(raw: []const u8) !ByteRange {
    var start: usize = 0;
    var end: ?usize = null;
    if (std.mem.indexOfScalar(u8, raw, '-')) |dash| {
        if (dash > 0) start = try std.fmt.parseInt(usize, raw[0..dash], 10);
        if (dash + 1 < raw.len) end = try std.fmt.parseInt(usize, raw[dash + 1 ..], 10);
    } else start = try std.fmt.parseInt(usize, raw, 10);
    return .{ .start = start, .end = end };
}

fn sliceRange(allocator: Allocator, content: []u8, raw_range: []const u8) ![]u8 {
    defer allocator.free(content);
    const range = try parseRange(raw_range);
    const start = @min(range.start, content.len);
    const end = if (range.end) |e| @min(e, content.len) else content.len;
    if (start > end) return error.InvalidByteRange;
    return allocator.dupe(u8, content[start..end]);
}
