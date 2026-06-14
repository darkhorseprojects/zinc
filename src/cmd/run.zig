const std = @import("std");
const Substrate = @import("../substrate.zig").Store;
const execute = @import("../execute.zig");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;

pub fn run(allocator: Allocator, io: std.Io, store: *Substrate, shape_path: []const u8, args: []const []const u8) !void {
    var settings = try config.loadSettings(allocator);
    defer settings.deinit();
    try execute.shape(allocator, io, store, shape_path, args, &settings);
}
