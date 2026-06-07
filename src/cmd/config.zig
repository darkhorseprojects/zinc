const std = @import("std");
const config = @import("../config/mod.zig");
const layout = @import("../io/layout.zig");

const Allocator = std.mem.Allocator;

pub fn configGet(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, dotted_path: []const u8) !void {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var split = std.mem.splitScalar(u8, dotted_path, '.');
    while (split.next()) |part| try parts.append(allocator, part);
    const value = try config.configGet(allocator, io, layout_ctx, parts.items);
    defer allocator.free(value);
    std.debug.print("{s}\n", .{value});
}
