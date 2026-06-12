const std = @import("std");
const serde = @import("serde");

const Allocator = std.mem.Allocator;

pub const Source = struct {
    git: []const u8,
    ref: []const u8 = "main",
    path: []const u8 = ".",
};

pub const SoftDependency = struct {
    alias: []const u8,
    package: []const u8,
    about: []const u8,
};

pub const Asset = struct {
    name: []const u8,
    path: []const u8,
    does: ?*const serde.yaml.Value,
};

pub const PackageManifest = struct {
    name: []const u8,
    version: []const u8,
    about: []const u8,
    source: ?Source,
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

    pub fn asset(self: PackageManifest, name: []const u8) !Asset {
        const assets = self.getMapField("assets") orelse return error.AssetSectionNotFound;
        const node = assets.getPtr(name) orelse return error.AssetNotFound;
        if (node.* == .string) return .{ .name = name, .path = node.string, .does = null };
        if (node.* != .mapping) return error.InvalidAssetType;
        const path_val = node.mapping.getPtr("path") orelse return error.MissingAssetPath;
        if (path_val.* != .string) return error.InvalidAssetPathType;
        return .{ .name = name, .path = path_val.string, .does = node.mapping.getPtr("does") };
    }

    pub fn softDependencies(self: PackageManifest, allocator: Allocator) ![]SoftDependency {
        if (self.root != .mapping) return try allocator.alloc(SoftDependency, 0);
        const deps = self.root.mapping.getPtr("soft_dependencies") orelse return try allocator.alloc(SoftDependency, 0);
        if (deps.* != .mapping) return error.InvalidSoftDependenciesType;
        var out: std.ArrayList(SoftDependency) = .empty;
        errdefer {
            for (out.items) |dep| {
                allocator.free(dep.alias);
                allocator.free(dep.package);
                allocator.free(dep.about);
            }
            out.deinit(allocator);
        }
        var it = deps.mapping.iterator();
        while (it.next()) |entry| {
            const alias = entry.key_ptr.*;
            if (entry.value_ptr.* == .string) {
                try out.append(allocator, try makeSoftDependency(allocator, alias, entry.value_ptr.string, ""));
            } else if (entry.value_ptr.* == .mapping) {
                const package_val = entry.value_ptr.mapping.getPtr("package") orelse return error.MissingSoftDependencyPackage;
                if (package_val.* != .string) return error.InvalidSoftDependencyPackageType;
                const about_val = entry.value_ptr.mapping.getPtr("about");
                const about_text = if (about_val) |about| blk: {
                    if (about.* != .string) return error.InvalidSoftDependencyAboutType;
                    break :blk about.string;
                } else "";
                try out.append(allocator, try makeSoftDependency(allocator, alias, package_val.string, about_text));
            } else return error.InvalidSoftDependencyType;
        }
        return out.toOwnedSlice(allocator);
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

pub fn assetDoes(asset: Asset, capability: []const u8) !bool {
    const node = asset.does orelse return false;
    switch (node.*) {
        .string => |s| return std.mem.eql(u8, s, capability),
        .sequence => |items| {
            for (items) |item| {
                if (item != .string) return error.InvalidAssetDoesType;
                if (std.mem.eql(u8, item.string, capability)) return true;
            }
            return false;
        },
        else => return error.InvalidAssetDoesType,
    }
}

fn makeSoftDependency(allocator: Allocator, alias: []const u8, package: []const u8, about: []const u8) !SoftDependency {
    const owned_alias = try allocator.dupe(u8, alias);
    errdefer allocator.free(owned_alias);
    const owned_package = try allocator.dupe(u8, package);
    errdefer allocator.free(owned_package);
    const owned_about = try allocator.dupe(u8, about);
    errdefer allocator.free(owned_about);
    return .{ .alias = owned_alias, .package = owned_package, .about = owned_about };
}

pub fn freeSoftDependencies(allocator: Allocator, deps: []SoftDependency) void {
    for (deps) |dep| {
        allocator.free(dep.alias);
        allocator.free(dep.package);
        allocator.free(dep.about);
    }
    allocator.free(deps);
}

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
        .source = try parseSource(root),
        .arena = arena,
        .root = root,
    };
}

fn parseSource(root: serde.yaml.Value) !?Source {
    const source_val = root.mapping.getPtr("source") orelse return null;
    if (source_val.* != .mapping) return error.InvalidSourceType;

    const git_val = source_val.mapping.getPtr("git") orelse return error.MissingSourceGit;
    if (git_val.* != .string) return error.InvalidSourceGitType;

    return .{
        .git = git_val.string,
        .ref = try optionalString(source_val.mapping, "ref", "main", error.InvalidSourceRefType),
        .path = try optionalString(source_val.mapping, "path", ".", error.InvalidSourcePathType),
    };
}

fn optionalString(mapping: serde.yaml.Mapping, key: []const u8, default: []const u8, comptime type_error: anyerror) ![]const u8 {
    const val = mapping.getPtr(key) orelse return default;
    if (val.* != .string) return type_error;
    return val.string;
}
