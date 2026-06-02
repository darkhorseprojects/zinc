const std = @import("std");
const config = @import("config.zig");
const files = @import("../sys/fs.zig");
const sessions = @import("session.zig");

const Allocator = std.mem.Allocator;
const sessions_index_limit: usize = 64;

pub const Context = struct {
    home: []const u8,
    session_id: []const u8,
    session_path: []const u8,
    session_dir: []const u8,
    session_log: []const u8,
    session_head_messages: usize,
    session_tail_messages: usize,
    replay_truncate_chars: usize,
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
    if (std.mem.startsWith(u8, raw, "prompt:")) {
        const prompt = try config.readPromptPack(allocator, io, ctx.home, raw["prompt:".len..]);
        return prompt;
    }
    if (std.mem.startsWith(u8, raw, "input:")) {
        const id = raw["input:".len..];
        for (ctx.inputs) |input| if (std.mem.eql(u8, input.id, id)) {
            const value = try allocator.dupe(u8, input.value);
            return value;
        };
        return error.InputNotFound;
    }
    if (std.mem.eql(u8, raw, "session:current")) {
        const log = try sessions.parseRaw(allocator, ctx.session_log);
        defer log.deinit(allocator);
        const transcript = try log.transcript(allocator, ctx.session_head_messages, ctx.session_tail_messages, ctx.replay_truncate_chars);
        return transcript;
    }
    if (std.mem.eql(u8, raw, "session:compaction")) return try sessionCompaction(allocator, ctx);
    if (std.mem.startsWith(u8, raw, "session:current:tools:")) return try sessionToolResult(allocator, ctx, raw["session:current:tools:".len..]);
    if (std.mem.startsWith(u8, raw, "session:current:messages:")) return try sessionMessage(allocator, ctx, raw["session:current:messages:".len..]);
    if (std.mem.eql(u8, raw, "session:last")) {
        const text = try std.fmt.allocPrint(allocator, "id: {s}\npath: {s}\n", .{ ctx.session_id, ctx.session_path });
        return text;
    }
    if (std.mem.eql(u8, raw, "sessions:index")) {
        const index = try sessionsIndex(allocator, io, ctx.session_dir, sessions_index_limit);
        return index;
    }
    if (std.mem.eql(u8, raw, "sessions:dir")) {
        const dir = try allocator.dupe(u8, ctx.session_dir);
        return dir;
    }
    return null;
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

fn sessionCompaction(allocator: Allocator, ctx: Context) ![]u8 {
    const log = try sessions.parseRaw(allocator, ctx.session_log);
    defer log.deinit(allocator);
    if (log.compaction) |c| return std.fmt.allocPrint(allocator, "compacted_messages: {d}\nsummary: {s}\n", .{ c.message_count, c.summary });
    return allocator.dupe(u8, "");
}

fn sessionToolResult(allocator: Allocator, ctx: Context, tool_id: []const u8) ![]u8 {
    const log = try sessions.parseRaw(allocator, ctx.session_log);
    defer log.deinit(allocator);
    for (log.messages) |message| {
        if (!std.mem.eql(u8, message.role, "tool")) continue;
        if (message.tool_call_id) |id| if (std.mem.eql(u8, id, tool_id)) return allocator.dupe(u8, message.content);
    }
    return error.ToolResultNotFound;
}

fn sessionMessage(allocator: Allocator, ctx: Context, raw_index: []const u8) ![]u8 {
    const index = try std.fmt.parseInt(usize, raw_index, 10);
    const log = try sessions.parseRaw(allocator, ctx.session_log);
    defer log.deinit(allocator);
    if (index >= log.messages.len) return error.MessageIndexOutOfBounds;
    return allocator.dupe(u8, log.messages[index].content);
}

fn sessionsIndex(allocator: Allocator, io: std.Io, session_dir: []const u8, limit: usize) ![]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, session_dir, .{ .iterate = true }) catch return allocator.dupe(u8, "");
    defer dir.close(io);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next(io)) |entry| {
        if (count >= limit) break;
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
