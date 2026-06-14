const std = @import("std");
const serde = @import("serde");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const Store = @import("../substrate.zig").Store;

const Allocator = std.mem.Allocator;

pub const ModelPreset = struct {
    adapter: ?[]const u8,
    params: ?*const serde.yaml.Value,
};

pub const ConfigSettings = struct {
    mode: []const u8,
    scope: []const u8,
    root: ?serde.yaml.Value,
    shape_zinc: ?*const serde.yaml.Value,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ConfigSettings) void {
        self.arena.deinit();
    }

    pub fn defaultModel(self: *const ConfigSettings) []const u8 {
        const root = self.root orelse return "default";
        if (root != .mapping) return "default";
        const models = root.mapping.getPtr("models") orelse return "default";
        if (models.* != .mapping) return "default";
        const default = models.mapping.getPtr("default") orelse return "default";
        return if (default.* == .string) default.string else "default";
    }

    pub fn packageAlias(self: *const ConfigSettings, alias: []const u8) ?[]const u8 {
        if (self.shape_zinc) |zinc| {
            if (packageAliasFrom(zinc, alias)) |uri| return uri;
        }
        const root = self.root orelse return null;
        return packageAliasFrom(&root, alias);
    }

    pub fn modelPreset(self: *const ConfigSettings, name: []const u8) ?ModelPreset {
        const root = self.root orelse return null;
        if (root != .mapping) return null;
        const models = root.mapping.getPtr("models") orelse return null;
        if (models.* != .mapping) return null;
        const preset = models.mapping.getPtr(name) orelse return null;
        if (preset.* != .mapping) return null;
        const adapter_value = preset.mapping.getPtr("adapter");
        const params = preset.mapping.getPtr("params");
        return .{
            .adapter = if (adapter_value) |adapter| if (adapter.* == .string) adapter.string else null else null,
            .params = params,
        };
    }
};

fn yamlGet(node: *const serde.yaml.Value, key: []const u8) ?*const serde.yaml.Value {
    if (node.* != .mapping) return null;
    var it = node.mapping.iterator();
    while (it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, key)) return entry.value_ptr;
    return null;
}

fn packageAliasFrom(root: *const serde.yaml.Value, alias: []const u8) ?[]const u8 {
    if (root.* != .mapping) return null;
    const packages = yamlGet(root, "packages") orelse return null;
    if (packages.* != .mapping) return null;
    const uri = yamlGet(packages, alias) orelse return null;
    return if (uri.* == .string) uri.string else null;
}

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
    if (bytes) |b| root = serde.yaml.parse(arena_allocator, b) catch null;

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

    return .{
        .mode = try arena_allocator.dupe(u8, mode_val),
        .scope = try arena_allocator.dupe(u8, scope_val),
        .root = root,
        .shape_zinc = null,
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
    try files.writeAllOut("\n  scope: ");
    try files.writeAllOut(settings.scope);
    try files.writeAllOut("\n  models.default: ");
    try files.writeAllOut(settings.defaultModel());
    try files.writeAllOut("\n");
}
