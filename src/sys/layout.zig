const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn statePath(allocator: Allocator, home: []const u8, basename: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.local/state/zinc/{s}", .{ home, basename });
}

pub fn sharePath(allocator: Allocator, home: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.local/share/zinc/{s}", .{ home, path });
}

pub fn configPath(allocator: Allocator, home: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.config/zinc/config.yaml", .{home});
}
