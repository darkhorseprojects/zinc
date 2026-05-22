const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn statePath(allocator: Allocator, home: []const u8, basename: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.local/state/zinc/{s}", .{ home, basename });
}

pub fn sharePath(allocator: Allocator, home: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.local/share/zinc/{s}", .{ home, path });
}

pub fn configPath(allocator: Allocator, home: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.config/zinc/config.toml", .{home});
}

test "layout derives all global Zinc paths from home" {
    const allocator = std.testing.allocator;
    const state = try statePath(allocator, "/tmp/home", "server.pid");
    defer allocator.free(state);
    try std.testing.expectEqualStrings("/tmp/home/.local/state/zinc/server.pid", state);

    const share = try sharePath(allocator, "/tmp/home", "graphs/zinc-loop.circuitry.yaml");
    defer allocator.free(share);
    try std.testing.expectEqualStrings("/tmp/home/.local/share/zinc/graphs/zinc-loop.circuitry.yaml", share);

    const config = try configPath(allocator, "/tmp/home");
    defer allocator.free(config);
    try std.testing.expectEqualStrings("/tmp/home/.config/zinc/config.toml", config);
}
