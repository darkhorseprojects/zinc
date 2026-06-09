const std = @import("std");
const Store = @import("../runtime/store.zig").Store;
const manifest = @import("manifest.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub fn resolveShape(allocator: Allocator, store: *Store, pkg_name: []const u8, shape_name: []const u8) ![]u8 {
    const pkg = (try store.getPackage(pkg_name)) orelse return error.PackageNotFound;
    defer store.freePackage(pkg);

    const manifest_path = try std.fs.path.join(allocator, &.{ pkg.path.?, "zinc.pkg.yaml" });
    defer allocator.free(manifest_path);

    const manifest_bytes = try files.readLimited(allocator, manifest_path, 10 * 1024 * 1024);
    defer allocator.free(manifest_bytes);

    var parsed = try manifest.parse(allocator, manifest_bytes);
    defer parsed.deinit();

    const shapes = parsed.getMapField("shapes") orelse return error.NoShapesInPackage;
    const rel_path = shapes.getPtr(shape_name) orelse return error.ShapeNotFound;
    if (rel_path.* != .string) return error.InvalidShapePathType;

    return try std.fs.path.join(allocator, &.{ pkg.path.?, rel_path.string });
}

pub fn resolvePrompt(allocator: Allocator, store: *Store, pkg_name: []const u8, prompt_name: []const u8) ![]u8 {
    const pkg = (try store.getPackage(pkg_name)) orelse return error.PackageNotFound;
    defer store.freePackage(pkg);

    const manifest_path = try std.fs.path.join(allocator, &.{ pkg.path.?, "zinc.pkg.yaml" });
    defer allocator.free(manifest_path);

    const manifest_bytes = try files.readLimited(allocator, manifest_path, 10 * 1024 * 1024);
    defer allocator.free(manifest_bytes);

    var parsed = try manifest.parse(allocator, manifest_bytes);
    defer parsed.deinit();

    const prompts = parsed.getMapField("prompts") orelse return error.NoPromptsInPackage;
    const rel_path = prompts.getPtr(prompt_name) orelse return error.PromptNotFound;
    if (rel_path.* != .string) return error.InvalidPromptPathType;

    return try std.fs.path.join(allocator, &.{ pkg.path.?, rel_path.string });
}

pub fn resolveFile(allocator: Allocator, store: *Store, pkg_name: []const u8, file_key: []const u8) ![]u8 {
    const pkg = (try store.getPackage(pkg_name)) orelse return error.PackageNotFound;
    defer store.freePackage(pkg);

    const manifest_path = try std.fs.path.join(allocator, &.{ pkg.path.?, "zinc.pkg.yaml" });
    defer allocator.free(manifest_path);

    const manifest_bytes = try files.readLimited(allocator, manifest_path, 10 * 1024 * 1024);
    defer allocator.free(manifest_bytes);

    var parsed = try manifest.parse(allocator, manifest_bytes);
    defer parsed.deinit();

    const files_map = parsed.getMapField("files") orelse return error.NoFilesInPackage;
    const rel_path = files_map.getPtr(file_key) orelse return error.FileNotFound;
    if (rel_path.* != .string) return error.InvalidFilePathType;

    return try std.fs.path.join(allocator, &.{ pkg.path.?, rel_path.string });
}
