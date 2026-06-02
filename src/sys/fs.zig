const std = @import("std");

const Allocator = std.mem.Allocator;
const io = std.Options.debug_io;

pub fn exists(path: []const u8) !void {
    _ = try std.Io.Dir.cwd().statFile(io, path, .{});
}

pub fn existsPath(path: []const u8) bool {
    exists(path) catch return false;
    return true;
}

pub fn readLimited(allocator: Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit)) catch |err| switch (err) {
        error.StreamTooLong => error.FileTooLarge,
        else => err,
    };
}

pub fn write(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try mkdirP(dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

pub fn append(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try mkdirP(dir);
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false }),
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    try file.writePositionalAll(io, content, stat.size);
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
    try std.Io.Dir.cwd().createDirPath(io, path);
}

pub fn appendJsonString(allocator: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    try std.json.Stringify.value(value, .{}, &aw.writer);
}

pub fn writeAllErr(bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

pub fn writeAllOut(bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

pub fn readStdin(buffer: []u8) !usize {
    var stdin_buffer: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    return reader.interface.readSliceShort(buffer);
}
