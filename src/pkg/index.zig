const std = @import("std");
const Store = @import("../runtime/store.zig").Store;
const manifest = @import("manifest.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub const PackageRef = struct {
    alias: []const u8,
    name: []const u8,
};

pub fn parsePackageRef(raw: []const u8) !PackageRef {
    if (std.mem.startsWith(u8, raw, "@")) return error.InvalidPackageRef;
    if (std.mem.indexOfScalar(u8, raw, '/')) |_| return error.NotPackageRef;
    const dot = std.mem.indexOfScalar(u8, raw, '.') orelse return error.NotPackageRef;
    if (dot == 0 or dot + 1 >= raw.len) return error.InvalidPackageRef;
    if (std.mem.indexOfScalar(u8, raw[dot + 1 ..], '.')) |_| return error.InvalidPackageRef;
    return .{ .alias = raw[0..dot], .name = raw[dot + 1 ..] };
}

pub fn packageNameFromSpec(spec: []const u8) []const u8 {
    const prefix = "zinc://package/";
    const tail = if (std.mem.startsWith(u8, spec, prefix)) spec[prefix.len..] else spec;
    if (std.mem.indexOfScalar(u8, tail, '@')) |at| return tail[0..at];
    if (std.mem.indexOfScalar(u8, tail, '/')) |slash| return tail[0..slash];
    return tail;
}

pub fn resolveRef(allocator: Allocator, store: *Store, raw: []const u8, package_spec: ?[]const u8, capability: []const u8) ![]u8 {
    const parsed = try parsePackageRef(raw);
    const pkg_name = if (package_spec) |spec| packageNameFromSpec(spec) else parsed.alias;
    if (package_spec != null) {
        const pkg = (try store.getPackage(pkg_name)) orelse return error.SoftDependencyNotInstalled;
        store.freePackage(pkg);
    }
    return try resolveAsset(allocator, store, pkg_name, parsed.name, capability);
}

pub fn resolveAsset(allocator: Allocator, store: *Store, pkg_name: []const u8, asset_name: []const u8, capability: []const u8) ![]u8 {
    const pkg = (try store.getPackage(pkg_name)) orelse return error.PackageNotFound;
    defer store.freePackage(pkg);
    const root = pkg.path orelse return error.PackagePathMissing;

    const manifest_path = try std.fs.path.join(allocator, &.{ root, "zinc.pkg.yaml" });
    defer allocator.free(manifest_path);

    const manifest_bytes = try files.readLimited(allocator, manifest_path, 10 * 1024 * 1024);
    defer allocator.free(manifest_bytes);

    var parsed = try manifest.parse(allocator, manifest_bytes);
    defer parsed.deinit();

    const asset = try parsed.asset(asset_name);
    if (!try manifest.assetDoes(asset, capability)) return error.AssetCapabilityMismatch;

    return try std.fs.path.join(allocator, &.{ root, asset.path });
}

pub fn resolveShape(allocator: Allocator, store: *Store, pkg_name: []const u8, shape_name: []const u8) ![]u8 {
    return resolveAsset(allocator, store, pkg_name, shape_name, "circuitry.shape");
}
