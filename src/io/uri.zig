const std = @import("std");
const config = @import("../config/mod.zig");
const layout = @import("layout.zig");
const runtime = @import("../runtime/mod.zig");

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
    if (std.mem.eql(u8, raw, "runtime:current")) return try runtime.navigation.runtimeSummary(allocator, ctx.layout_ctx, ctx.session_id);
    if (std.mem.eql(u8, raw, "session:current")) return try runtime.navigation.sessionTranscript(allocator, ctx.layout_ctx, ctx.session_id, ctx.session_head_messages, ctx.session_tail_messages, ctx.session_context_truncate_chars);
    if (std.mem.eql(u8, raw, "session:last")) return try std.fmt.allocPrint(allocator, "id: {s}\n", .{ctx.session_id});
    if (std.mem.eql(u8, raw, "sessions:index")) return try runtime.navigation.sessionsIndex(allocator, ctx.layout_ctx);
    if (std.mem.startsWith(u8, raw, "session:current:tools:")) return try runtime.navigation.sessionToolResult(allocator, ctx.layout_ctx, ctx.session_id, raw["session:current:tools:".len..]);
    if (std.mem.startsWith(u8, raw, "session:current:messages:")) return try runtime.navigation.sessionMessage(allocator, ctx.layout_ctx, ctx.session_id, raw["session:current:messages:".len..]);
    if (std.mem.eql(u8, raw, "event:current")) return try runtime.navigation.eventCurrent(allocator, ctx.layout_ctx);
    if (std.mem.startsWith(u8, raw, "event:") and std.mem.endsWith(u8, raw, ":payload")) return try runtime.navigation.eventPayload(allocator, ctx.layout_ctx, raw["event:".len .. raw.len - ":payload".len]);
    if (std.mem.startsWith(u8, raw, "event:") and std.mem.endsWith(u8, raw, ":logs")) return try runtime.navigation.eventLogs(allocator, ctx.layout_ctx, raw["event:".len .. raw.len - ":logs".len]);
    if (std.mem.startsWith(u8, raw, "event:")) return try runtime.navigation.eventShow(allocator, ctx.layout_ctx, raw["event:".len..]);
    if (std.mem.eql(u8, raw, "branch:current")) return try runtime.navigation.branchCurrent(allocator, ctx.layout_ctx, ctx.session_id);
    if (std.mem.startsWith(u8, raw, "branch:") and std.mem.endsWith(u8, raw, ":events")) return try runtime.navigation.branchEvents(allocator, ctx.layout_ctx, ctx.session_id, raw["branch:".len .. raw.len - ":events".len]);
    if (std.mem.startsWith(u8, raw, "branch:")) return try runtime.navigation.branchSummary(allocator, ctx.layout_ctx, ctx.session_id, raw["branch:".len..]);
    if (std.mem.eql(u8, raw, "log:current")) return try runtime.navigation.logsCurrent(allocator, ctx.layout_ctx);
    if (std.mem.startsWith(u8, raw, "log:event:")) return try runtime.navigation.logsForEvent(allocator, ctx.layout_ctx, raw["log:event:".len..]);
    if (std.mem.startsWith(u8, raw, "log:run:")) return try runtime.navigation.logsForRun(allocator, ctx.layout_ctx, raw["log:run:".len..]);
    if (std.mem.eql(u8, raw, "recovery:current")) return try runtime.navigation.recoveryCurrent(allocator, ctx.layout_ctx);
    if (std.mem.startsWith(u8, raw, "recovery:") and std.mem.endsWith(u8, raw, ":sources")) return try runtime.navigation.recoverySources(allocator, ctx.layout_ctx, raw["recovery:".len .. raw.len - ":sources".len]);
    if (std.mem.startsWith(u8, raw, "recovery:")) return try runtime.navigation.eventPayload(allocator, ctx.layout_ctx, raw["recovery:".len..]);
    if (std.mem.startsWith(u8, raw, "package:") and std.mem.endsWith(u8, raw, ":events")) return try runtime.navigation.packageEvents(allocator, ctx.layout_ctx, raw["package:".len .. raw.len - ":events".len]);
    if (std.mem.startsWith(u8, raw, "package:")) return try runtime.navigation.packageSummary(allocator, ctx.layout_ctx, raw["package:".len..]);
    return null;
}

fn inputValue(allocator: Allocator, ctx: Context, id: []const u8) ![]u8 {
    for (ctx.inputs) |input| if (std.mem.eql(u8, input.id, id)) return allocator.dupe(u8, input.value);
    return error.InputNotFound;
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
