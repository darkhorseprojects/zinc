const std = @import("std");
const Store = @import("../runtime/store.zig").Store;
const run_mod = @import("../runtime/run.zig");
const config_cmd = @import("config.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub fn run(allocator: Allocator, io: std.Io, store: *Store, shape_path: []const u8, args: []const []const u8) !void {
    var settings = try config_cmd.loadSettings(allocator);
    defer settings.deinit();

    try run_mod.runShape(allocator, io, store, shape_path, args, &settings);
}
