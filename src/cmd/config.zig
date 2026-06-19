const std = @import("std");
const serde = @import("serde");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");

const Allocator = std.mem.Allocator;

pub const ConfigSettings = struct {
    arena: std.heap.ArenaAllocator,
    root: ?serde.yaml.Value,

    pub fn deinit(self: *ConfigSettings) void {
        self.arena.deinit();
    }

    pub fn packetLimit(self: *const ConfigSettings) usize {
        const root = self.root orelse return 1024 * 1024;
        if (root != .mapping) return 1024 * 1024;
        const store = root.mapping.getPtr("store") orelse return 1024 * 1024;
        if (store.* != .mapping) return 1024 * 1024;
        const limit = store.mapping.getPtr("packet_limit") orelse return 1024 * 1024;
        return switch (limit.*) {
            .integer => |n| if (n > 0) @intCast(n) else 1024 * 1024,
            else => 1024 * 1024,
        };
    }
};

pub fn loadSettings(allocator: Allocator) !ConfigSettings {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

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
    if (bytes) |b| root = serde.yaml.parse(arena_allocator, b) catch null;

    return .{ .arena = arena, .root = root };
}

pub fn runConfig(allocator: Allocator, store: anytype, args: []const []const u8) !void {
    _ = store;
    _ = args;
    var settings = try loadSettings(allocator);
    defer settings.deinit();

    try files.writeAllOut("Zinc config:\n");
    try files.writeAllOut("  store.packet_limit: ");
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{settings.packetLimit()});
    try files.writeAllOut(text);
    try files.writeAllOut("\n");
}
