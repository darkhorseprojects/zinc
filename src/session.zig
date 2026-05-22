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

pub fn readLog(allocator: Allocator, session_path: []const u8, max_bytes: usize) ![]u8 {
    if (max_bytes == 0) return allocator.dupe(u8, "");
    const fd = std.posix.openat(std.posix.AT.FDCWD, session_path, .{ .ACCMODE = .RDONLY }, 0) catch return allocator.dupe(u8, "");
    defer _ = std.os.linux.close(fd);

    const end_rc = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.END);
    if (std.os.linux.errno(end_rc) != .SUCCESS) return error.ReadFailed;
    const file_size: usize = @intCast(end_rc);
    const start: usize = file_size -| max_bytes;
    const seek_rc = std.os.linux.lseek(fd, @intCast(start), std.os.linux.SEEK.SET);
    if (std.os.linux.errno(seek_rc) != .SUCCESS) return error.ReadFailed;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (start != 0) try out.appendSlice(allocator, "[session log truncated to recent tail]\n");
    var remaining = @min(file_size - start, max_bytes);
    var buffer: [8192]u8 = undefined;
    while (remaining != 0) {
        const take = @min(buffer.len, remaining);
        const n = try files.linuxRead(fd, buffer[0..take]);
        if (n == 0) break;
        try out.appendSlice(allocator, buffer[0..n]);
        remaining -= n;
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

test "session log respects zero byte budget" {
    const log = try readLog(std.testing.allocator, "missing-session.jsonl", 0);
    defer std.testing.allocator.free(log);
    try std.testing.expectEqualStrings("", log);
}
