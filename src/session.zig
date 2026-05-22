const std = @import("std");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;

pub const Session = struct {
    id: []u8,
    path: []u8,

    pub fn deinit(self: Session, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
    }
};

pub fn open(allocator: Allocator, resume_id: ?[]const u8, continue_last: bool) !Session {
    const session_dir = try ensureDir(allocator);
    defer allocator.free(session_dir);

    const id = if (continue_last)
        try readLastId(allocator)
    else if (resume_id) |given| blk: {
        try validateId(given);
        break :blk try allocator.dupe(u8, given);
    } else try newId(allocator);
    errdefer allocator.free(id);

    const path = try std.fmt.allocPrint(allocator, ".zinc/sessions/{s}.jsonl", .{id});
    errdefer allocator.free(path);

    if (resume_id != null or continue_last) {
        if (files.exists(path)) |_| {} else |_| return error.SessionNotFound;
    } else {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, "{\"type\":\"session\",\"version\":1,\"runtime\":\"zinc\",\"id\":");
        try files.appendJsonString(allocator, &line, id);
        try line.print(allocator, ",\"createdAt\":{d}}}\n", .{0});
        try files.write(path, line.items);
    }

    try files.write(".zinc/sessions/last", id);
    return .{ .id = id, .path = path };
}

pub fn buildProjection(allocator: Allocator, session_path: []const u8, user_prompt: []const u8, max_bytes: usize) ![]u8 {
    if (max_bytes == 0) return allocator.dupe(u8, "");
    const text = files.readLimited(allocator, session_path, 512 * 1024) catch return allocator.dupe(u8, "");
    defer allocator.free(text);
    if (text.len == 0) return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Relevant session projection:\n");

    try appendKeywordLines(allocator, &out, text, user_prompt, max_bytes);
    try appendRecentTail(allocator, &out, text, max_bytes);

    if (out.items.len > max_bytes) {
        const start = out.items.len - max_bytes;
        const trimmed = try allocator.dupe(u8, out.items[start..]);
        out.deinit(allocator);
        return trimmed;
    }
    return out.toOwnedSlice(allocator);
}

pub fn appendEvent(allocator: Allocator, path: []const u8, role: []const u8, content: []const u8) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try line.print(allocator, "{{\"type\":\"message\",\"timestamp\":{d},\"message\":{{\"role\":", .{0});
    try files.appendJsonString(allocator, &line, role);
    try line.appendSlice(allocator, ",\"content\":");
    try files.appendJsonString(allocator, &line, content);
    try line.appendSlice(allocator, "}}}\n");
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .APPEND = true }, 0);
    defer _ = std.os.linux.close(fd);
    var written: usize = 0;
    while (written < line.items.len) written += try files.linuxWrite(fd, line.items[written..]);
}

pub fn appendToolEvent(allocator: Allocator, path: []const u8, name: []const u8, args: []const u8, result: []const u8) !void {
    const text = try std.fmt.allocPrint(allocator, "tool {s}\nargs: {s}\nresult:\n{s}", .{ name, args, result });
    defer allocator.free(text);
    try appendEvent(allocator, path, "tool", text);
}

pub fn ensureDir(allocator: Allocator) ![]u8 {
    try files.mkdirP(".zinc/sessions");
    return allocator.dupe(u8, ".zinc/sessions");
}

fn readLastId(allocator: Allocator) ![]u8 {
    const raw = try files.readLimited(allocator, ".zinc/sessions/last", 256);
    defer allocator.free(raw);
    const id = std.mem.trim(u8, raw, " \t\r\n");
    try validateId(id);
    return allocator.dupe(u8, id);
}

fn newId(allocator: Allocator) ![]u8 {
    var bytes: [8]u8 = undefined;
    const rc = std.os.linux.getrandom(&bytes, bytes.len, 0);
    const errno = std.os.linux.errno(rc);
    if (errno != .SUCCESS or rc != bytes.len) return error.RandomFailed;
    return std.fmt.allocPrint(allocator, "s{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7] });
}

fn validateId(id: []const u8) !void {
    if (id.len == 0 or id.len > 96) return error.InvalidSessionId;
    for (id) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
        if (!ok) return error.InvalidSessionId;
    }
}

fn appendKeywordLines(allocator: Allocator, out: *std.ArrayList(u8), session: []const u8, prompt: []const u8, max_bytes: usize) !void {
    var words = std.mem.tokenizeAny(u8, prompt, " \t\r\n.,:;!?()[]{}<>\\/\"'");
    var lines = std.mem.splitScalar(u8, session, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var matched = false;
        words.reset();
        while (words.next()) |word| {
            if (word.len < 4) continue;
            if (std.ascii.indexOfIgnoreCase(line, word) != null) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;
        try appendCappedLine(allocator, out, line, max_bytes);
    }
}

fn appendRecentTail(allocator: Allocator, out: *std.ArrayList(u8), session: []const u8, max_bytes: usize) !void {
    const tail_len = @min(session.len, @min(max_bytes / 2, 2048));
    if (tail_len == 0) return;
    try out.appendSlice(allocator, "Recent session tail:\n");
    var tail = session[session.len - tail_len ..];
    if (std.mem.indexOfScalar(u8, tail, '\n')) |first_newline| tail = tail[first_newline + 1 ..];
    var lines = std.mem.splitScalar(u8, tail, '\n');
    while (lines.next()) |line| {
        if (line.len != 0) try appendCappedLine(allocator, out, line, max_bytes);
    }
}

fn appendCappedLine(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8, max_bytes: usize) !void {
    if (out.items.len >= max_bytes) return;
    const remaining = max_bytes - out.items.len;
    const take = @min(line.len, remaining -| 1);
    try out.appendSlice(allocator, line[0..take]);
    if (out.items.len < max_bytes) try out.append(allocator, '\n');
}

test "projection respects zero byte budget" {
    const projection = try buildProjection(std.testing.allocator, "missing-session.jsonl", "hello", 0);
    defer std.testing.allocator.free(projection);
    try std.testing.expectEqualStrings("", projection);
}
