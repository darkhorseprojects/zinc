const std = @import("std");
const Store = @import("../runtime/store.zig").Store;
const store_types = @import("../runtime/store.zig");
const packages_table = store_types.packages;
const package_sources_table = store_types.package_sources;
const manifest = @import("manifest.zig");
const deps = @import("deps.zig");
const layout = @import("../io/layout.zig");
const files = @import("../io/fs.zig");
const proc = @import("../io/process.zig");
const platform = @import("../platform/mod.zig");

const Allocator = std.mem.Allocator;
const io_opt = std.Options.debug_io;

pub const SourceMeta = struct {
    git: []const u8,
    ref: []const u8,
    path: []const u8,
    rev: ?[]const u8 = null,
};

pub fn install(allocator: Allocator, io: std.Io, store: *Store, source_path: []const u8, is_global: bool) !void {
    try installResolved(allocator, io, store, source_path, is_global, null);
}

pub fn installResolved(allocator: Allocator, io: std.Io, store: *Store, source_path: []const u8, is_global: bool, source_meta: ?SourceMeta) !void {
    const abs_source_path = try absoluteDirPath(allocator, io, source_path);
    defer allocator.free(abs_source_path);

    const manifest_path = try std.fs.path.join(allocator, &.{ abs_source_path, "zinc.pkg.yaml" });
    defer allocator.free(manifest_path);

    const manifest_bytes = try files.readLimited(allocator, manifest_path, 10 * 1024 * 1024);
    defer allocator.free(manifest_bytes);

    var parsed = try manifest.parse(allocator, manifest_bytes);
    defer parsed.deinit();

    const name = parsed.name;
    const version = parsed.version;
    try deps.reportSoftDependencies(allocator, store, parsed);

    // Target packages directory
    const target_packages_dir = if (is_global)
        try layout.globalPath(allocator, "packages")
    else
        (try layout.workspacePath(allocator, "packages")) orelse return error.NoWorkspaceFound;
    defer allocator.free(target_packages_dir);
    try files.mkdirP(target_packages_dir);

    // Target package path
    const target_package_path = try std.fs.path.join(allocator, &.{ target_packages_dir, name });
    defer allocator.free(target_package_path);

    // Remove old symlink/directory if exists
    _ = std.Io.Dir.cwd().deleteTree(io, target_package_path) catch {};

    // Create symlink to source folder
    const os = platform.currentOS();
    if (os == .windows) {
        // Windows uses junctions or symlinks
        std.Io.Dir.symLinkAbsolute(io, abs_source_path, target_package_path, .{ .is_directory = true }) catch {
            // Fallback: copy tree if symlink fails
            try copyDir(io, abs_source_path, target_package_path);
        };
    } else {
        try std.Io.Dir.symLinkAbsolute(io, abs_source_path, target_package_path, .{ .is_directory = true });
    }

    // Run setup script if defined
    const os_name = @tagName(os);
    if (parsed.getScript("setup", os_name)) |script_rel| {
        const setup_script_path = try std.fs.path.join(allocator, &.{ target_package_path, script_rel });
        defer allocator.free(setup_script_path);

        if (files.existsPath(setup_script_path)) {
            // Make executable on POSIX
            if (os != .windows) {
                var file = try std.Io.Dir.openFileAbsolute(io, setup_script_path, .{ .mode = .read_only });
                defer file.close(io);
                file.setPermissions(io, @enumFromInt(0o755)) catch {};
            }

            try files.writeAllOut("Running package setup script...\n");
            const run_res = try proc.run(allocator, io, &.{setup_script_path}, abs_source_path, 10 * 1024 * 1024);
            defer run_res.deinit(allocator);

            if (run_res.stdout.len > 0) try files.writeAllOut(run_res.stdout);
            if (run_res.stderr.len > 0) try files.writeAllErr(run_res.stderr);

            if (run_res.code != 0) {
                return error.PackageSetupFailed;
            }
        }
    }

    // Add to Database
    const now = std.Io.Clock.now(.real, io).toSeconds();
    try store.insertPackage(packages_table{
        .name = name,
        .version = version,
        .source = abs_source_path,
        .scope = if (is_global) "global" else "workspace",
        .path = target_package_path,
        .status = "installed",
        .installed_at = now,
        .checked_at = now,
    });

    try materializePackageFacts(allocator, store, parsed, os_name);

    if (source_meta orelse manifestSource(parsed)) |source| {
        try store.upsertPackageSource(package_sources_table{
            .package_name = name,
            .kind = "git",
            .url = source.git,
            .ref = source.ref,
            .path = source.path,
            .rev = source.rev,
        });
    }

    try files.writeAllOut("Package installed successfully.\n");
}

fn materializePackageFacts(allocator: Allocator, store: *Store, parsed: manifest.PackageManifest, os_name: []const u8) !void {
    try store.clearPackageFacts(parsed.name);
    const assets = try parsed.assets(allocator);
    defer manifest.freeAssets(allocator, assets);
    for (assets) |asset| try store.insertPackageAsset(.{ .package_name = parsed.name, .path = asset.path, .file_path = asset.file_path, .metadata_json = null });
    inline for (&.{ "setup", "check", "remove" }) |script_name| {
        if (parsed.getScript(script_name, os_name)) |script_rel| try store.insertPackageScript(.{ .package_name = parsed.name, .path = script_name, .file_path = script_rel });
    }
    const soft_deps = try parsed.softDependencies(allocator);
    defer manifest.freeSoftDependencies(allocator, soft_deps);
    for (soft_deps) |dep| try store.insertPackageDependency(.{ .package_name = parsed.name, .alias = dep.alias, .package_spec = dep.package, .about = dep.about });
}

pub fn remove(allocator: Allocator, io: std.Io, store: *Store, name: []const u8) !void {
    const pkg = (try store.getPackage(name)) orelse {
        try files.writeAllErr("Package not found.\n");
        return error.PackageNotFound;
    };
    defer store.freePackage(pkg);

    // Read manifest
    const manifest_path = try std.fs.path.join(allocator, &.{ pkg.path.?, "zinc.pkg.yaml" });
    defer allocator.free(manifest_path);

    if (files.existsPath(manifest_path)) {
        const manifest_bytes = files.readLimited(allocator, manifest_path, 10 * 1024 * 1024) catch null;
        if (manifest_bytes) |bytes| {
            defer allocator.free(bytes);
            if (manifest.parse(allocator, bytes)) |parsed| {
                var mut_parsed = parsed;
                defer mut_parsed.deinit();
                const os = platform.currentOS();
                const os_name = @tagName(os);
                if (mut_parsed.getScript("remove", os_name)) |script_rel| {
                    const remove_script_path = try std.fs.path.join(allocator, &.{ pkg.path.?, script_rel });
                    defer allocator.free(remove_script_path);
                    if (files.existsPath(remove_script_path)) {
                        try files.writeAllOut("Running package remove script...\n");
                        const run_res = proc.run(allocator, io, &.{remove_script_path}, pkg.source.?, 10 * 1024 * 1024) catch null;
                        if (run_res) |res| {
                            defer res.deinit(allocator);
                            if (res.stdout.len > 0) try files.writeAllOut(res.stdout);
                            if (res.stderr.len > 0) try files.writeAllErr(res.stderr);
                        }
                    }
                }
            } else |_| {}
        }
    }

    // Delete folder symlink
    _ = std.Io.Dir.cwd().deleteTree(io, pkg.path.?) catch {};

    // Delete from Database
    try store.deletePackage(name);
    try files.writeAllOut("Package removed successfully.\n");
}

fn absoluteDirPath(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
    const cwd_buf = try allocator.alloc(u8, std.fs.max_path_bytes);
    defer allocator.free(cwd_buf);
    const cwd_len = try std.process.currentPath(io, cwd_buf);
    return try std.fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
}

fn manifestSource(parsed: manifest.PackageManifest) ?SourceMeta {
    const source = parsed.source orelse return null;
    return .{ .git = source.git, .ref = source.ref, .path = source.path };
}

fn copyDir(io: std.Io, src: []const u8, dest: []const u8) !void {
    var src_dir = try std.Io.Dir.openDirAbsolute(io, src, .{ .iterate = true });
    defer src_dir.close(io);
    try std.Io.Dir.createDirAbsolute(io, dest, .default_dir);
    var dest_dir = try std.Io.Dir.openDirAbsolute(io, dest, .{});
    defer dest_dir.close(io);
    try copyDirContents(io, src_dir, dest_dir);
}

fn copyDirContents(io: std.Io, src_dir: std.Io.Dir, dest_dir: std.Io.Dir) !void {
    var it = src_dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file => try src_dir.copyFile(entry.name, dest_dir, entry.name, io, .{}),
            .directory => {
                dest_dir.createDir(io, entry.name, .default_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                var child_src = try src_dir.openDir(io, entry.name, .{ .iterate = true });
                defer child_src.close(io);
                var child_dest = try dest_dir.openDir(io, entry.name, .{});
                defer child_dest.close(io);
                try copyDirContents(io, child_src, child_dest);
            },
            else => {},
        }
    }
}
