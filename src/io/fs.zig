const std = @import("std");

const Allocator = std.mem.Allocator;
const io_opt = std.Options.debug_io;

pub fn exists(path: []const u8) !void {
    _ = try std.Io.Dir.cwd().statFile(io_opt, path, .{});
}

pub fn existsPath(path: []const u8) bool {
    if (path.len == 0 or path.len > std.fs.max_path_bytes) return false;
    if (std.mem.indexOfAny(u8, path, "\n\r") != null) return false;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| if (part.len > 255) return false;
    exists(path) catch return false;
    return true;
}

pub fn readLimited(allocator: Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io_opt, path, allocator, .limited(limit)) catch |err| switch (err) {
        error.StreamTooLong => error.FileTooLarge,
        else => err,
    };
}

pub fn write(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try mkdirP(dir);
    try std.Io.Dir.cwd().writeFile(io_opt, .{ .sub_path = path, .data = content });
}

pub fn append(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try mkdirP(dir);
    var file = std.Io.Dir.cwd().openFile(io_opt, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().createFile(io_opt, path, .{ .read = true, .truncate = false }),
        else => return err,
    };
    defer file.close(io_opt);
    const stat = try file.stat(io_opt);
    try file.writePositionalAll(io_opt, content, stat.size);
}

pub fn mkdirP(path: []const u8) !void {
    if (path.len == 0) return;
    try std.Io.Dir.cwd().createDirPath(io_opt, path);
}

pub fn writeAllErr(bytes: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io_opt, bytes);
}

pub fn writeAllOut(bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_opt, bytes);
}

pub fn readStdin(buffer: []u8) !usize {
    var stdin_buffer: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io_opt, &stdin_buffer);
    return reader.interface.readSliceShort(buffer);
}

pub fn readAllStdin(allocator: Allocator, limit: usize) ![]u8 {
    var stdin_buffer: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io_opt, &stdin_buffer);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&buffer);
        if (n == 0) break;
        if (out.items.len + n > limit) return error.FileTooLarge;
        try out.appendSlice(allocator, buffer[0..n]);
    }
    return out.toOwnedSlice(allocator);
}
