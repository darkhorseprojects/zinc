const std = @import("std");
const Store = @import("../runtime/store.zig").Store;
const manifest = @import("manifest.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub const PackageRef = struct {
    alias: []const u8,
    kind: []const u8,
    name: []const u8,
};

pub fn parsePackageRef(raw: []const u8) !PackageRef {
    if (!std.mem.startsWith(u8, raw, "@")) return error.NotPackageRef;
    const body = raw[1..];
    const first = std.mem.indexOfScalar(u8, body, '.') orelse return error.InvalidPackageRef;
    const rest = body[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '.') orelse return error.InvalidPackageRef;
    return .{ .alias = body[0..first], .kind = rest[0..second], .name = rest[second + 1 ..] };
}

pub fn packageNameFromUri(uri: []const u8) []const u8 {
    const prefix = "zinc://package/";
    if (!std.mem.startsWith(u8, uri, prefix)) return uri;
    const tail = uri[prefix.len..];
    if (std.mem.indexOfScalar(u8, tail, '@')) |at| return tail[0..at];
    if (std.mem.indexOfScalar(u8, tail, '/')) |slash| return tail[0..slash];
    return tail;
}

pub fn resolveRef(allocator: Allocator, store: *Store, raw: []const u8, alias_uri: ?[]const u8) ![]u8 {
    const parsed = try parsePackageRef(raw);
    const pkg_name = if (alias_uri) |uri| packageNameFromUri(uri) else parsed.alias;
    if (alias_uri != null) {
        const pkg = (try store.getPackage(pkg_name)) orelse return error.SoftDependencyNotInstalled;
        store.freePackage(pkg);
    }
    return try resolveAsset(allocator, store, pkg_name, parsed.kind, parsed.name);
}

pub fn resolveAsset(allocator: Allocator, store: *Store, pkg_name: []const u8, kind: []const u8, asset_name: []const u8) ![]u8 {
    const pkg = (try store.getPackage(pkg_name)) orelse return error.PackageNotFound;
    defer store.freePackage(pkg);
    const root = pkg.path orelse return error.PackagePathMissing;

    const manifest_path = try std.fs.path.join(allocator, &.{ root, "zinc.pkg.yaml" });
    defer allocator.free(manifest_path);

    const manifest_bytes = try files.readLimited(allocator, manifest_path, 10 * 1024 * 1024);
    defer allocator.free(manifest_bytes);

    var parsed = try manifest.parse(allocator, manifest_bytes);
    defer parsed.deinit();

    const assets = parsed.getMapField(kind) orelse return error.AssetKindNotFound;
    const rel_path = assets.getPtr(asset_name) orelse return error.AssetNotFound;
    if (rel_path.* != .string) return error.InvalidAssetPathType;

    return try std.fs.path.join(allocator, &.{ root, rel_path.string });
}

pub fn resolveShape(allocator: Allocator, store: *Store, pkg_name: []const u8, shape_name: []const u8) ![]u8 {
    return resolveAsset(allocator, store, pkg_name, "shapes", shape_name);
}

pub fn resolvePrompt(allocator: Allocator, store: *Store, pkg_name: []const u8, prompt_name: []const u8) ![]u8 {
    return resolveAsset(allocator, store, pkg_name, "prompts", prompt_name);
}

pub fn resolveFile(allocator: Allocator, store: *Store, pkg_name: []const u8, file_key: []const u8) ![]u8 {
    return resolveAsset(allocator, store, pkg_name, "files", file_key);
}
