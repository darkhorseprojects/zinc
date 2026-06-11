const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn fetchBytes(allocator: Allocator, io: std.Io, url: []const u8, max_bytes: usize) ![]u8 {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .headers = .{ .user_agent = .{ .override = "zinc" } },
        .redirect_behavior = @enumFromInt(5),
    });
    if (result.status != .ok) return error.HttpRequestFailed;
    if (body.writer.end > max_bytes) return error.DownloadTooLarge;

    return try body.toOwnedSlice();
}

pub fn fetchFile(allocator: Allocator, io: std.Io, url: []const u8, path: []const u8, max_bytes: usize) !void {
    const bytes = try fetchBytes(allocator, io, url, max_bytes);
    defer allocator.free(bytes);
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}
