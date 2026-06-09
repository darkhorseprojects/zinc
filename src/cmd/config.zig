const std = @import("std");
const serde = @import("serde");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const Store = @import("../runtime/store.zig").Store;

const Allocator = std.mem.Allocator;

pub const ConfigSettings = struct {
    mode: []const u8,
    scope: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ConfigSettings) void {
        self.arena.deinit();
    }
};

pub fn loadSettings(allocator: Allocator) !ConfigSettings {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var mode_val: []const u8 = "build";
    var scope_val: []const u8 = "project";

    var bytes: ?[]const u8 = null;
    if (try layout.workspacePath(allocator, "config.yaml")) |ws_path| {
        defer allocator.free(ws_path);
        bytes = files.readLimited(arena_allocator, ws_path, 1024 * 1024) catch null;
    }

    if (bytes == null) {
        const g_path = try layout.globalPath(allocator, "config.yaml");
        defer allocator.free(g_path);
        bytes = files.readLimited(arena_allocator, g_path, 1024 * 1024) catch null;
    }

    var root: ?serde.yaml.Value = null;
    if (bytes) |b| {
        root = serde.yaml.parse(arena_allocator, b) catch null;
    }

    if (root) |r| {
        if (r == .mapping) {
            if (r.mapping.getPtr("mode")) |mv| {
                if (mv.* == .string) mode_val = mv.string;
            }
            if (r.mapping.getPtr("scope")) |sv| {
                if (sv.* == .string) scope_val = sv.string;
            }
        }
    }

    return ConfigSettings{
        .mode = try allocator.dupe(u8, mode_val),
        .scope = try allocator.dupe(u8, scope_val),
        .arena = arena,
    };
}

pub fn runConfig(allocator: Allocator, store: *Store, args: []const []const u8) !void {
    _ = store;
    _ = args;
    var settings = try loadSettings(allocator);
    defer settings.deinit();

    try files.writeAllOut("Active Configuration:\n");
    try files.writeAllOut("  mode: ");
    try files.writeAllOut(settings.mode);
    try files.writeAllOut("\n");
    try files.writeAllOut("  scope: ");
    try files.writeAllOut(settings.scope);
    try files.writeAllOut("\n");
}
