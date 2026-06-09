const std = @import("std");
const serde = @import("serde");

const Allocator = std.mem.Allocator;

pub const PackageManifest = struct {
    name: []const u8,
    version: []const u8,
    about: []const u8,
    arena: std.heap.ArenaAllocator,
    root: serde.yaml.Value,

    pub fn deinit(self: *PackageManifest) void {
        self.arena.deinit();
    }

    pub fn getMapField(self: PackageManifest, key: []const u8) ?serde.yaml.Mapping {
        if (self.root != .mapping) return null;
        const val = self.root.mapping.getPtr(key) orelse return null;
        if (val.* != .mapping) return null;
        return val.mapping;
    }

    pub fn getScript(self: PackageManifest, script_name: []const u8, os_name: []const u8) ?[]const u8 {
        if (self.root != .mapping) return null;
        const scripts = self.root.mapping.getPtr("scripts") orelse return null;
        if (scripts.* != .mapping) return null;
        const script = scripts.mapping.getPtr(script_name) orelse return null;
        if (script.* != .mapping) return null;
        const os_script = script.mapping.getPtr(os_name) orelse return null;
        if (os_script.* != .string) return null;
        return os_script.string;
    }
};

pub fn parse(allocator: Allocator, bytes: []const u8) !PackageManifest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const root = try serde.yaml.parse(arena_allocator, bytes);
    if (root != .mapping) return error.InvalidManifestType;

    const name_val = root.mapping.getPtr("name") orelse return error.MissingName;
    if (name_val.* != .string) return error.InvalidNameType;

    const version_val = root.mapping.getPtr("version") orelse return error.MissingVersion;
    if (version_val.* != .string) return error.InvalidVersionType;

    const about_val = root.mapping.getPtr("about") orelse root.mapping.getPtr("description") orelse &serde.yaml.Value{ .string = "" };
    if (about_val.* != .string) return error.InvalidAboutType;

    return PackageManifest{
        .name = name_val.string,
        .version = version_val.string,
        .about = about_val.string,
        .arena = arena,
        .root = root,
    };
}
