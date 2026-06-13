const std = @import("std");
const Store = @import("../runtime/store.zig").Store;

const Allocator = std.mem.Allocator;

pub const PackageRef = struct {
    alias: []const u8,
    path: []const u8,
};

pub fn parsePackageRef(raw: []const u8) !PackageRef {
    if (std.mem.startsWith(u8, raw, "@")) return error.InvalidPackageRef;
    if (std.mem.indexOfScalar(u8, raw, '/')) |_| return error.NotPackageRef;
    const dot = std.mem.indexOfScalar(u8, raw, '.') orelse return error.NotPackageRef;
    if (dot == 0 or dot + 1 >= raw.len) return error.InvalidPackageRef;
    return .{ .alias = raw[0..dot], .path = raw[dot + 1 ..] };
}

fn assetPath(allocator: Allocator, value: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, value);
    for (out) |*c| {
        if (c.* == '.') c.* = '/';
    }
    return out;
}

pub fn packageNameFromSpec(spec: []const u8) []const u8 {
    const prefix = "zinc://packages/";
    const tail = if (std.mem.startsWith(u8, spec, prefix)) spec[prefix.len..] else spec;
    if (std.mem.indexOfScalar(u8, tail, '@')) |at| return tail[0..at];
    if (std.mem.indexOfScalar(u8, tail, '/')) |slash| return tail[0..slash];
    return tail;
}

pub fn resolveRef(allocator: Allocator, store: *Store, raw: []const u8, package_spec: ?[]const u8) ![]u8 {
    const parsed = try parsePackageRef(raw);
    const pkg_name = if (package_spec) |spec| packageNameFromSpec(spec) else parsed.alias;
    if (package_spec != null) {
        const pkg = (try store.getPackage(pkg_name)) orelse return error.SoftDependencyNotInstalled;
        store.freePackage(pkg);
    }
    const path = try assetPath(allocator, parsed.path);
    defer allocator.free(path);
    return try resolveAsset(allocator, store, pkg_name, path);
}

pub fn resolveAsset(allocator: Allocator, store: *Store, pkg_name: []const u8, asset_path: []const u8) ![]u8 {
    const pkg = (try store.getPackage(pkg_name)) orelse return error.PackageNotFound;
    defer store.freePackage(pkg);
    const root = pkg.path orelse return error.PackagePathMissing;
    const asset = (try store.getPackageAsset(pkg_name, asset_path)) orelse return error.AssetNotFound;
    defer store.freePackageAsset(asset);
    return try std.fs.path.join(allocator, &.{ root, asset.file_path });
}

pub fn resolveShape(allocator: Allocator, store: *Store, pkg_name: []const u8, shape_path: []const u8) ![]u8 {
    return resolveAsset(allocator, store, pkg_name, shape_path);
}
