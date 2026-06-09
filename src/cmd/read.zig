const std = @import("std");
const Store = @import("../runtime/store.zig").Store;
const uri = @import("../runtime/uri.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub fn runRead(allocator: Allocator, store: *Store, arg: []const u8) !void {
    _ = store;
    if (std.mem.startsWith(u8, arg, "zinc://")) {
        const content = try uri.resolveRead(allocator, arg);
        defer allocator.free(content);
        try files.writeAllOut(content);
    } else {
        const content = try files.readLimited(allocator, arg, 64 * 1024 * 1024);
        defer allocator.free(content);
        try files.writeAllOut(content);
    }
}
