const std = @import("std");
const Substrate = @import("../substrate.zig").Store;
const execute = @import("../execute.zig");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;

pub fn run(allocator: Allocator, io: std.Io, store: *Substrate, settings: *const config.ConfigSettings, shape_path: []const u8, args: []const []const u8) !void {
    const shape_bytes = try execute.readShape(allocator, shape_path);
    defer allocator.free(shape_bytes);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const shape = try execute.parseShape(arena.allocator(), shape_bytes);
    const result = try execute.runShape(allocator, io, store, settings, shape, args);
    defer result.deinit();
    try execute.writeResult(result);
}
