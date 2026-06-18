const std = @import("std");
const Substrate = @import("../substrate.zig").Store;
const package = @import("../package.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub fn runRead(allocator: Allocator, store: *Substrate, target: []const u8) !void {
    const content = if (std.mem.startsWith(u8, target, "zinc://"))
        try readZinc(allocator, store, target)
    else
        try files.readLimited(allocator, target, 64 * 1024 * 1024);
    defer allocator.free(content);
    try files.writeAllOut(content);
}

fn readZinc(allocator: Allocator, store: *Substrate, uri: []const u8) ![]u8 {
    const body = uri["zinc://".len..];
    if (std.mem.startsWith(u8, body, "packages/")) return readPackage(allocator, store, body["packages/".len..]);
    if (std.mem.startsWith(u8, body, "package/")) return readPackage(allocator, store, body["package/".len..]);
    return error.UnknownZincUri;
}

fn readPackage(allocator: Allocator, store: *Substrate, tail: []const u8) ![]u8 {
    const slash = std.mem.indexOfScalar(u8, tail, '/');
    const alias = if (slash) |i| tail[0..i] else tail;
    const query = if (slash) |i| tail[i + 1 ..] else "manifest";
    return try package.read(allocator, store, alias, query);
}
