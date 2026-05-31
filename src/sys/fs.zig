const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn exists(path: []const u8) !void {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    _ = std.os.linux.close(fd);
}

pub fn existsPath(path: []const u8) bool {
    exists(path) catch return false;
    return true;
}

pub fn readLimited(allocator: Allocator, path: []const u8, limit: usize) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.os.linux.close(fd);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = try linuxRead(fd, &buffer);
        if (n == 0) break;
        if (out.items.len + n > limit) return error.FileTooLarge;
        try out.appendSlice(allocator, buffer[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

pub fn write(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try mkdirP(dir);
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer _ = std.os.linux.close(fd);
    var written: usize = 0;
    while (written < content.len) written += try linuxWrite(fd, content[written..]);
}

pub fn edit(allocator: Allocator, path: []const u8, old: []const u8, new: []const u8) !void {
    return editLimited(allocator, path, old, new, 8 * 1024 * 1024);
}

pub fn editLimited(allocator: Allocator, path: []const u8, old: []const u8, new: []const u8, limit: usize) !void {
    const original = try readLimited(allocator, path, limit);
    defer allocator.free(original);
    const first = std.mem.indexOf(u8, original, old) orelse return error.OldTextNotFound;
    if (std.mem.indexOf(u8, original[first + old.len ..], old) != null) return error.OldTextNotUnique;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, original[0..first]);
    try out.appendSlice(allocator, new);
    try out.appendSlice(allocator, original[first + old.len ..]);
    try write(path, out.items);
}

pub fn mkdirP(path: []const u8) !void {
    if (path.len == 0) return;
    var end: usize = if (path[0] == '/') 1 else 0;
    while (end < path.len) {
        while (end < path.len and path[end] != '/') end += 1;
        if (end > 0) try mkdirOne(path[0..end]);
        while (end < path.len and path[end] == '/') end += 1;
    }
    if (path[path.len - 1] != '/') try mkdirOne(path);
}

pub fn appendJsonString(allocator: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    try std.json.Stringify.value(value, .{}, &aw.writer);
}

pub fn linuxRead(fd: i32, buffer: []u8) !usize {
    const rc = std.os.linux.read(fd, buffer.ptr, buffer.len);
    const errno = std.os.linux.errno(rc);
    if (errno != .SUCCESS) return error.ReadFailed;
    return rc;
}

pub fn linuxWrite(fd: i32, buffer: []const u8) !usize {
    const rc = std.os.linux.write(fd, buffer.ptr, buffer.len);
    const errno = std.os.linux.errno(rc);
    if (errno != .SUCCESS) return error.WriteFailed;
    return rc;
}

fn mkdirOne(path: []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len >= buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    const rc = std.os.linux.mkdir(&buffer, 0o755);
    const errno = std.os.linux.errno(rc);
    if (errno == .SUCCESS or errno == .EXIST) return;
    return error.MkdirFailed;
}
