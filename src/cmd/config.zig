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

    pub fn defaultRun(self: *const ConfigSettings) []const u8 {
        const root = self.root orelse return "openai-responses.software.responses";
        if (root != .mapping) return "openai-responses.software.responses";
        const defaults = root.mapping.getPtr("defaults") orelse return "openai-responses.software.responses";
        if (defaults.* != .mapping) return "openai-responses.software.responses";
        const run = defaults.mapping.getPtr("run") orelse return "openai-responses.software.responses";
        return if (run.* == .string and run.string.len != 0) run.string else "openai-responses.software.responses";
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
    try files.writeAllOut("  defaults.run: ");
    try files.writeAllOut(settings.defaultRun());
    try files.writeAllOut("\n");
}
