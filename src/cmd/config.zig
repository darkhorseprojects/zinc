const std = @import("std");
const serde = @import("serde");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");

const Allocator = std.mem.Allocator;
const default_packet_limit: usize = 1024 * 1024;
const default_parallel: usize = 1;

pub const ConfigSettings = struct {
    arena: std.heap.ArenaAllocator,
    root: ?serde.yaml.Value,

    pub fn deinit(self: *ConfigSettings) void {
        self.arena.deinit();
    }

    pub fn packetLimit(self: *const ConfigSettings, package: []const u8) usize {
        const packages = mappingField(self.rootValue() orelse return default_packet_limit, "packages") orelse return default_packet_limit;
        const policy = mappingField(packages, package) orelse return default_packet_limit;
        return positiveIntegerField(policy, "packet_limit") orelse default_packet_limit;
    }

    pub fn runtimeParallel(self: *const ConfigSettings) usize {
        const runtime = mappingField(self.rootValue() orelse return default_parallel, "runtime") orelse return default_parallel;
        return positiveIntegerField(runtime, "parallel") orelse default_parallel;
    }

    fn rootValue(self: *const ConfigSettings) ?*const serde.yaml.Value {
        return if (self.root) |*root| root else null;
    }
};

pub fn loadSettings(allocator: Allocator) !ConfigSettings {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var bytes: ?[]const u8 = null;
    if (try layout.workspacePath(allocator, "config.yaml")) |ws_path| {
        defer allocator.free(ws_path);
        bytes = try readOptionalConfig(arena_allocator, ws_path);
    }

    if (bytes == null) {
        const g_path = try layout.globalPath(allocator, "config.yaml");
        defer allocator.free(g_path);
        bytes = try readOptionalConfig(arena_allocator, g_path);
    }

    var root: ?serde.yaml.Value = null;
    if (bytes) |b| {
        const parsed = try serde.yaml.parse(arena_allocator, b);
        try validateConfig(&parsed);
        root = parsed;
    }

    return .{ .arena = arena, .root = root };
}

pub fn runConfig(allocator: Allocator, store: anytype, args: []const []const u8) !void {
    _ = store;
    _ = args;
    var settings = try loadSettings(allocator);
    defer settings.deinit();

    try files.writeAllOut("Zinc config:\n");
    try files.writeAllOut("  runtime.parallel: ");
    try writeInt(settings.runtimeParallel());
    try files.writeAllOut("\n");

    const root = settings.rootValue() orelse return;
    const packages = mappingField(root, "packages") orelse return;
    var it = packages.mapping.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .mapping) continue;
        try files.writeAllOut("  packages.");
        try files.writeAllOut(entry.key_ptr.*);
        try files.writeAllOut(".packet_limit: ");
        try writeInt(positiveIntegerField(entry.value_ptr, "packet_limit") orelse default_packet_limit);
        try files.writeAllOut("\n");
    }
}

fn readOptionalConfig(allocator: Allocator, path: []const u8) !?[]const u8 {
    return files.readLimited(allocator, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

fn validateConfig(root: *const serde.yaml.Value) !void {
    if (root.* != .mapping) return error.InvalidConfig;
    if (root.mapping.getPtr("runtime")) |runtime| {
        if (runtime.* != .mapping) return error.InvalidConfigRuntime;
        if (runtime.mapping.getPtr("parallel")) |parallel| _ = positiveInteger(parallel) orelse return error.InvalidConfigRuntimeParallel;
    }
    if (root.mapping.getPtr("packages")) |packages| {
        if (packages.* != .mapping) return error.InvalidConfigPackages;
        var it = packages.mapping.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .mapping) return error.InvalidConfigPackage;
            if (entry.value_ptr.mapping.getPtr("packet_limit")) |limit| _ = positiveInteger(limit) orelse return error.InvalidConfigPacketLimit;
        }
    }
}

fn mappingField(root: *const serde.yaml.Value, key: []const u8) ?*const serde.yaml.Value {
    if (root.* != .mapping) return null;
    const value = root.mapping.getPtr(key) orelse return null;
    return if (value.* == .mapping) value else null;
}

fn positiveIntegerField(root: *const serde.yaml.Value, key: []const u8) ?usize {
    if (root.* != .mapping) return null;
    const value = root.mapping.getPtr(key) orelse return null;
    return positiveInteger(value);
}

fn positiveInteger(value: *const serde.yaml.Value) ?usize {
    return switch (value.*) {
        .integer => |n| if (n > 0) @intCast(n) else null,
        else => null,
    };
}

fn writeInt(value: usize) !void {
    var buf: [32]u8 = undefined;
    try files.writeAllOut(try std.fmt.bufPrint(&buf, "{d}", .{value}));
}
