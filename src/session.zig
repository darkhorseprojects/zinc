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

    return .{ .id = id, .path = path };
}

pub fn rememberLast(session: Session) !void {
    try files.write(".zinc/sessions/last", session.id);
}

pub fn readLog(allocator: Allocator, session_path: []const u8) ![]u8 {
    return files.readLimited(allocator, session_path, std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        error.ReadFailed => try allocator.dupe(u8, ""),
        else => err,
    };
}

pub fn appendEvent(allocator: Allocator, path: []const u8, role: []const u8, content: []const u8) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try line.print(allocator, "{{\"type\":\"message\",\"timestamp\":{d},\"message\":{{\"role\":", .{0});
    try files.appendJsonString(allocator, &line, role);
    try line.appendSlice(allocator, ",\"content\":");
    try files.appendJsonString(allocator, &line, content);
    try line.appendSlice(allocator, "}}}\n");
    try appendLine(path, line.items);
}

pub fn appendRuntimeEvent(allocator: Allocator, path: []const u8, phase: []const u8, event: []const u8, content: []const u8) !void {
    try appendRuntimeEventFull(allocator, path, phase, event, null, null, content);
}

pub fn appendRuntimeError(allocator: Allocator, path: []const u8, phase: []const u8, event: []const u8, error_name: []const u8, content: []const u8) !void {
    try appendRuntimeEventFull(allocator, path, phase, event, error_name, null, content);
}

pub fn appendToolEvent(allocator: Allocator, path: []const u8, event: []const u8, name: []const u8, content: []const u8) !void {
    try appendRuntimeEventFull(allocator, path, "tool", event, null, name, content);
}

fn appendRuntimeEventFull(allocator: Allocator, path: []const u8, phase: []const u8, event: []const u8, error_name: ?[]const u8, tool: ?[]const u8, content: []const u8) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try line.print(allocator, "{{\"type\":\"runtime\",\"timestamp\":{d},\"phase\":", .{0});
    try files.appendJsonString(allocator, &line, phase);
    try line.appendSlice(allocator, ",\"event\":");
    try files.appendJsonString(allocator, &line, event);
    if (error_name) |name| {
        try line.appendSlice(allocator, ",\"error\":");
        try files.appendJsonString(allocator, &line, name);
    }
    if (tool) |name| {
        try line.appendSlice(allocator, ",\"tool\":");
        try files.appendJsonString(allocator, &line, name);
    }
    try line.appendSlice(allocator, ",\"content\":");
    try files.appendJsonString(allocator, &line, content);
    try line.appendSlice(allocator, "}\n");
    try appendLine(path, line.items);
}

fn appendLine(path: []const u8, line: []const u8) !void {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .APPEND = true }, 0);
    defer _ = std.os.linux.close(fd);
    var written: usize = 0;
    while (written < line.len) written += try files.linuxWrite(fd, line[written..]);
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

test "missing session log reads empty" {
    const log = try readLog(std.testing.allocator, "missing-session.jsonl");
    defer std.testing.allocator.free(log);
    try std.testing.expectEqualStrings("", log);
}
