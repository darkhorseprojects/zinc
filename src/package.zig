const std = @import("std");
const serde = @import("serde");
const Substrate = @import("substrate.zig").Store;
const files = @import("io/fs.zig");
const layout = @import("io/layout.zig");
const pkg_io = @import("package/io.zig");
const proc = @import("io/process.zig");
const Allocator = std.mem.Allocator;

pub const Ref = struct { alias: []const u8, path: []const u8 };
pub const UpdateOptions = struct {
    requested_version: ?[]const u8 = null,
    requested_ref: ?[]const u8 = null,
    dry_run: bool = false,
    yes: bool = false,
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    root: serde.yaml.Value,
    name: []const u8,
    version: []const u8,
    about: []const u8,
    uri: []const u8,
    dependencies: []pkg_io.PackageDependency,
    root_path: []const u8,
    surfaces: []pkg_io.Surface,

    pub fn open(allocator: Allocator, package_root: []const u8) !Manifest {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const manifest_path = try std.fs.path.join(aa, &.{ package_root, "zinc.pkg.yaml" });
        const bytes = try files.readLimited(aa, manifest_path, 10 * 1024 * 1024);
        const root = try serde.yaml.parse(aa, bytes);
        if (root != .mapping) return error.InvalidPackageManifest;

        const name = pkg_io.stringField(&root, "name") orelse return error.PackageNameMissing;
        const version = pkg_io.stringField(&root, "version") orelse return error.PackageVersionMissing;
        const parsed_name = try aa.dupe(u8, name);
        const parsed_version = try aa.dupe(u8, version);
        const about = try aa.dupe(u8, pkg_io.stringField(&root, "about") orelse "");
        const uri = try aa.dupe(u8, pkg_io.stringField(&root, "uri") orelse package_root);
        const dependencies = try pkg_io.parsePackageDependencies(aa, pkg_io.valueField(&root, "packages"));
        const root_path = try aa.dupe(u8, package_root);
        const surfaces = try pkg_io.parseSurfaceList(aa, pkg_io.valueField(&root, "surfaces"));

        return .{
            .arena = arena,
            .root = root,
            .name = parsed_name,
            .version = parsed_version,
            .about = about,
            .uri = uri,
            .dependencies = dependencies,
            .root_path = root_path,
            .surfaces = surfaces,
        };
    }

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }

    pub fn surfaceEntry(self: *const Manifest, name: []const u8) ?*const pkg_io.Surface {
        for (self.surfaces) |*entry| if (std.mem.eql(u8, entry.name, name)) return entry;
        return null;
    }

    pub fn rel(self: *const Manifest, query: []const u8) ![]const u8 {
        const leaf = try self.node(query) orelse return error.PackagePathNotFound;
        return switch (leaf.*) {
            .string => leaf.string,
            .mapping => blk: {
                const path = pkg_io.valueField(leaf, "path") orelse return error.PackagePathMissing;
                if (path.* != .string) return error.PackagePathInvalid;
                break :blk path.string;
            },
            else => error.PackagePathInvalid,
        };
    }

    pub fn node(self: *const Manifest, query: []const u8) !?*const serde.yaml.Value {
        if (self.root != .mapping) return error.InvalidPackageManifest;
        var current: *const serde.yaml.Value = &self.root;
        var it = std.mem.tokenizeAny(u8, query, "/.");
        while (it.next()) |segment| {
            current = pkg_io.valueField(current, segment) orelse return null;
        }
        return current;
    }
};

pub const Surface = pkg_io.Surface;
pub const ResolvedInvocation = pkg_io.ResolvedInvocation;
pub const PackageStatus = struct {
    owner: []const u8,
    package: []const u8,
    ref: ?[]const u8,
    installed: bool,
    version: ?[]const u8,
    root: ?[]const u8,

    pub fn deinit(self: *const PackageStatus, allocator: Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.package);
        if (self.ref) |v| allocator.free(v);
        if (self.version) |v| allocator.free(v);
        if (self.root) |v| allocator.free(v);
    }
};

pub fn parseRef(raw: []const u8) !Ref {
    if (std.mem.indexOfScalar(u8, raw, '/')) |_| return error.NotPackageRef;
    const dot = std.mem.indexOfScalar(u8, raw, '.') orelse return error.NotPackageRef;
    if (dot == 0 or dot + 1 == raw.len) return error.InvalidPackageRef;
    return .{ .alias = raw[0..dot], .path = raw[dot + 1 ..] };
}

pub fn resolveRef(allocator: Allocator, store: *Substrate, raw: []const u8) ![]u8 {
    const ref = try parseRef(raw);
    return resolve(allocator, store, ref.alias, ref.path);
}

pub fn resolve(allocator: Allocator, store: *Substrate, alias: []const u8, query: []const u8) ![]u8 {
    const pkg = (try store.getPackage(alias)) orelse return error.PackageNotInstalled;
    defer store.freePackage(pkg);
    var manifest = try Manifest.open(allocator, pkg.root);
    defer manifest.deinit();
    const rel_path = try manifest.rel(query);
    return try std.fs.path.join(allocator, &.{ pkg.root, rel_path });
}

pub fn read(allocator: Allocator, store: *Substrate, alias: []const u8, query: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, query, "manifest/")) {
        const pkg = (try store.getPackage(alias)) orelse return error.PackageNotInstalled;
        defer store.freePackage(pkg);
        var manifest = try Manifest.open(allocator, pkg.root);
        defer manifest.deinit();
        const node = (try manifest.node(query["manifest/".len..])) orelse return error.PackagePathNotFound;
        return try pkg_io.nodeText(allocator, node);
    }
    const path = if (query.len == 0 or std.mem.eql(u8, query, "manifest")) blk: {
        const pkg = (try store.getPackage(alias)) orelse return error.PackageNotInstalled;
        defer store.freePackage(pkg);
        break :blk try std.fs.path.join(allocator, &.{ pkg.root, "zinc.pkg.yaml" });
    } else if (std.mem.startsWith(u8, query, "files/")) blk: {
        const rel_path = query["files/".len..];
        try validatePackageFilePath(rel_path);
        const pkg = (try store.getPackage(alias)) orelse return error.PackageNotInstalled;
        defer store.freePackage(pkg);
        break :blk try std.fs.path.join(allocator, &.{ pkg.root, rel_path });
    } else try resolve(allocator, store, alias, query);
    defer allocator.free(path);
    return try files.readLimited(allocator, path, 64 * 1024 * 1024);
}

fn validatePackageFilePath(rel_path: []const u8) !void {
    if (rel_path.len == 0 or std.fs.path.isAbsolute(rel_path)) return error.InvalidPackagePath;
    var it = std.mem.tokenizeScalar(u8, rel_path, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPackagePath;
    }
}

pub fn resolveSurfaceInvocation(allocator: Allocator, store: *Substrate, surface_ref: []const u8) !ResolvedInvocation {
    const ref = try parseRef(surface_ref);
    const pkg = (try store.getPackage(ref.alias)) orelse return error.PackageNotInstalled;
    defer store.freePackage(pkg);
    var manifest = try Manifest.open(allocator, pkg.root);
    defer manifest.deinit();
    const surface = manifest.surfaceEntry(ref.path) orelse return error.SurfaceNotFound;
    return surface.resolve(pkg.root);
}

pub fn install(allocator: Allocator, io: std.Io, store: *Substrate, source_root: []const u8, scope: Scope) !void {
    const abs_source = try absolute(allocator, io, source_root);
    defer allocator.free(abs_source);

    var manifest = Manifest.open(allocator, abs_source) catch |err| {
        std.debug.print("package install: manifest open failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer manifest.deinit();

    const package_dir = try packageDir(allocator, io, scope);
    defer allocator.free(package_dir);
    try files.mkdirP(package_dir);

    const target = try std.fs.path.join(allocator, &.{ package_dir, manifest.name });
    defer allocator.free(target);
    try replaceLocal(allocator, io, target, abs_source);
    try putInstalled(allocator, store, &manifest, target);
    try files.writeAllOut("installed ");
    try files.writeAllOut(manifest.name);
    try files.writeAllOut("\n");
}

pub fn update(allocator: Allocator, io: std.Io, store: *Substrate, selector: []const u8, scope: Scope, options: UpdateOptions) !void {
    if (std.mem.eql(u8, selector, "all")) {
        const pkgs = try store.listPackages();
        defer {
            for (pkgs) |pkg| store.freePackage(pkg);
            allocator.free(pkgs);
        }
        for (pkgs) |pkg| try updateInstalled(allocator, io, store, pkg.package, scope, options);
        return;
    }
    try updateInstalled(allocator, io, store, selector, scope, options);
}

pub fn listPackageDependencies(allocator: Allocator, store: *Substrate, selector: []const u8, missing_only: bool) ![]PackageStatus {
    const pkgs = try store.listPackages();
    defer {
        for (pkgs) |pkg| store.freePackage(pkg);
        allocator.free(pkgs);
    }

    var count: usize = 0;
    for (pkgs) |pkg| {
        if (!std.mem.eql(u8, selector, "all") and !std.mem.eql(u8, selector, pkg.package)) continue;
        {
            var manifest = Manifest.open(allocator, pkg.root) catch continue;
            defer manifest.deinit();
            for (manifest.dependencies) |dependency| {
                if (try dependencyStatusCounts(store, dependency, missing_only)) count += 1;
            }
        }
    }

    const rows = try allocator.alloc(PackageStatus, count);
    errdefer allocator.free(rows);
    var index: usize = 0;
    for (pkgs) |pkg| {
        if (!std.mem.eql(u8, selector, "all") and !std.mem.eql(u8, selector, pkg.package)) continue;
        {
            var manifest = Manifest.open(allocator, pkg.root) catch continue;
            defer manifest.deinit();
            for (manifest.dependencies) |dependency| {
                if (try appendPackageStatus(allocator, store, rows, &index, pkg.package, dependency, missing_only)) {}
            }
        }
    }
    return rows;
}

fn dependencyStatusCounts(store: *Substrate, dependency: pkg_io.PackageDependency, missing_only: bool) !bool {
    const installed = try store.getPackage(dependency.package);
    defer if (installed) |row| store.freePackage(row);
    if (installed) |row| {
        const matches = if (dependency.ref) |ref| std.mem.eql(u8, ref, row.version) else true;
        return !missing_only or !matches;
    }
    return missing_only;
}

fn appendPackageStatus(allocator: Allocator, store: *Substrate, rows: []PackageStatus, index: *usize, owner: []const u8, dependency: pkg_io.PackageDependency, missing_only: bool) !bool {
    const installed = try store.getPackage(dependency.package);
    if (installed) |row| {
        defer store.freePackage(row);
        const matches = if (dependency.ref) |ref| std.mem.eql(u8, ref, row.version) else true;
        if (missing_only and matches) return false;
        rows[index.*] = .{
            .owner = try allocator.dupe(u8, owner),
            .package = try allocator.dupe(u8, dependency.package),
            .ref = if (dependency.ref) |ref| try allocator.dupe(u8, ref) else null,
            .installed = true,
            .version = try allocator.dupe(u8, row.version),
            .root = try allocator.dupe(u8, row.root),
        };
    } else {
        if (missing_only == false) return false;
        rows[index.*] = .{
            .owner = try allocator.dupe(u8, owner),
            .package = try allocator.dupe(u8, dependency.package),
            .ref = if (dependency.ref) |ref| try allocator.dupe(u8, ref) else null,
            .installed = false,
            .version = null,
            .root = null,
        };
    }
    index.* += 1;
    return true;
}

pub fn remove(allocator: Allocator, io: std.Io, store: *Substrate, alias: []const u8) !void {
    _ = allocator;
    const pkg = (try store.getPackage(alias)) orelse return error.PackageNotInstalled;
    defer store.freePackage(pkg);
    _ = std.Io.Dir.cwd().deleteTree(io, pkg.root) catch {};
    try store.removePackage(alias);
}

pub const Scope = enum { workspace, global };

fn updateInstalled(allocator: Allocator, io: std.Io, store: *Substrate, alias: []const u8, scope: Scope, options: UpdateOptions) !void {
    const pkg = (try store.getPackage(alias)) orelse return error.PackageNotInstalled;
    defer store.freePackage(pkg);

    if (options.dry_run) {
        try files.writeAllOut("would update ");
        try files.writeAllOut(pkg.package);
        try files.writeAllOut(" ");
        try files.writeAllOut(pkg.version);
        try files.writeAllOut(" from ");
        try files.writeAllOut(pkg.uri);
        try files.writeAllOut("\n");
        return;
    }

    const resolved = try resolveSource(allocator, io, pkg.package, pkg.uri, options.requested_ref);
    defer resolved.deinit(allocator);
    errdefer {
        if (resolved.checkout) |checkout| _ = std.Io.Dir.cwd().deleteTree(io, checkout) catch {};
    }

    var manifest = try Manifest.open(allocator, resolved.root);
    defer manifest.deinit();
    if (!std.mem.eql(u8, manifest.name, pkg.package)) return error.PackageNameMismatch;
    if (options.requested_version) |wanted| if (!std.mem.eql(u8, wanted, manifest.version)) return error.PackageVersionMismatch;

    if (!options.yes) {
        try files.writeAllOut("update ");
        try files.writeAllOut(pkg.package);
        try files.writeAllOut(" ");
        try files.writeAllOut(pkg.version);
        try files.writeAllOut(" -> ");
        try files.writeAllOut(manifest.version);
        try files.writeAllOut("? [y/N] ");
        var answer = std.ArrayList(u8).empty;
        defer answer.deinit(allocator);
        var one: [1]u8 = undefined;
        while (true) {
            const n = std.Io.File.stdin().readStreaming(io, &.{one[0..]}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (n == 0) break;
            if (one[0] == '\n') break;
            try answer.append(allocator, one[0]);
        }
        if (answer.items.len == 0 or !std.ascii.startsWithIgnoreCase(answer.items, "y")) return;
    }

    const package_dir = try packageDir(allocator, io, scope);
    defer allocator.free(package_dir);
    try files.mkdirP(package_dir);
    const target = try std.fs.path.join(allocator, &.{ package_dir, manifest.name });
    defer allocator.free(target);

    if (resolved.moved) {
        try replaceMoved(allocator, io, store, &manifest, target, resolved.root);
        if (resolved.checkout) |checkout| _ = std.Io.Dir.cwd().deleteTree(io, checkout) catch {};
    } else {
        try replaceLocal(allocator, io, target, resolved.root);
        try putInstalled(allocator, store, &manifest, target);
    }

    try files.writeAllOut("updated ");
    try files.writeAllOut(pkg.package);
    try files.writeAllOut(" ");
    try files.writeAllOut(pkg.version);
    try files.writeAllOut(" -> ");
    try files.writeAllOut(manifest.version);
    try files.writeAllOut("\n");
}

const ResolvedSource = struct {
    root: []const u8,
    checkout: ?[]const u8,
    moved: bool,

    fn deinit(self: ResolvedSource, allocator: Allocator) void {
        if (self.checkout) |checkout| {
            if (self.root.ptr != checkout.ptr) allocator.free(self.root);
            allocator.free(checkout);
        } else {
            allocator.free(self.root);
        }
    }
};

fn resolveSource(allocator: Allocator, io: std.Io, alias: []const u8, uri: []const u8, override_ref: ?[]const u8) !ResolvedSource {
    if (!std.mem.startsWith(u8, uri, "git+")) {
        const local = if (std.mem.startsWith(u8, uri, "file://")) uri["file://".len..] else uri;
        return .{ .root = try absolute(allocator, io, local), .checkout = null, .moved = false };
    }

    const parsed = try parseGitUri(allocator, uri, override_ref);
    defer parsed.deinit(allocator);
    const base = try layout.tempRunPath(allocator, "updates");
    defer allocator.free(base);
    try files.mkdirP(base);
    const repo_dir = try std.fs.path.join(allocator, &.{ base, alias });
    errdefer _ = std.Io.Dir.cwd().deleteTree(io, repo_dir) catch {};

    try runGit(allocator, io, &.{ "clone", "--depth", "1", parsed.repo, repo_dir }, null);
    if (parsed.ref) |ref| try runGit(allocator, io, &.{ "-C", repo_dir, "checkout", ref }, null);
    const root = if (parsed.path) |path| try std.fs.path.join(allocator, &.{ repo_dir, path }) else repo_dir;
    return .{ .root = root, .checkout = repo_dir, .moved = true };
}

fn replaceMoved(allocator: Allocator, io: std.Io, store: *Substrate, manifest: *const Manifest, target: []const u8, from: []const u8) !void {
    const package_dir = std.fs.path.dirname(target) orelse return error.InvalidPackagePath;
    try files.mkdirP(package_dir);
    const backup = try std.fmt.allocPrint(allocator, "{s}/{s}.previous", .{ package_dir, manifest.name });
    defer allocator.free(backup);
    _ = std.Io.Dir.cwd().deleteTree(io, backup) catch {};
    std.Io.Dir.renameAbsolute(target, backup, io) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    var copied = false;
    std.Io.Dir.renameAbsolute(from, target, io) catch |err| switch (err) {
        error.CrossDevice => {
            copyTreeAbsolute(allocator, io, from, target) catch |copy_err| {
                restorePrevious(io, backup, target);
                return copy_err;
            };
            copied = true;
        },
        else => {
            restorePrevious(io, backup, target);
            return err;
        },
    };
    putInstalled(allocator, store, manifest, target) catch |err| {
        if (copied) {
            _ = std.Io.Dir.cwd().deleteTree(io, target) catch {};
        } else {
            _ = std.Io.Dir.renameAbsolute(target, from, io) catch {};
        }
        restorePrevious(io, backup, target);
        return err;
    };
    deletePrevious(io, backup);
}

fn copyTreeAbsolute(allocator: Allocator, io: std.Io, from: []const u8, target: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, target);
    var source = try std.Io.Dir.openDirAbsolute(io, from, .{ .iterate = true });
    defer source.close(io);
    var it = source.iterate();
    while (try it.next(io)) |entry| {
        const child_from = try std.fs.path.join(allocator, &.{ from, entry.name });
        defer allocator.free(child_from);
        const child_target = try std.fs.path.join(allocator, &.{ target, entry.name });
        defer allocator.free(child_target);
        switch (entry.kind) {
            .directory => try copyTreeAbsolute(allocator, io, child_from, child_target),
            .file => try std.Io.Dir.copyFileAbsolute(child_from, child_target, io, .{ .make_path = true, .replace = true }),
            .sym_link => try copySymlinkAbsolute(io, child_from, child_target),
            else => {},
        }
    }
}

fn copySymlinkAbsolute(io: std.Io, from: []const u8, target: []const u8) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.readLinkAbsolute(io, from, &buffer);
    _ = std.Io.Dir.deleteFileAbsolute(io, target) catch {};
    try std.Io.Dir.symLinkAbsolute(io, buffer[0..len], target, .{});
}

fn restorePrevious(io: std.Io, backup: []const u8, target: []const u8) void {
    _ = std.Io.Dir.renameAbsolute(backup, target, io) catch {};
}

fn deletePrevious(io: std.Io, backup: []const u8) void {
    _ = std.Io.Dir.deleteFileAbsolute(io, backup) catch {
        _ = std.Io.Dir.cwd().deleteTree(io, backup) catch {};
    };
}

fn replaceLocal(allocator: Allocator, io: std.Io, target: []const u8, from: []const u8) !void {
    _ = allocator;
    const package_dir = std.fs.path.dirname(target) orelse return error.InvalidPackagePath;
    try files.mkdirP(package_dir);
    _ = std.Io.Dir.cwd().deleteTree(io, target) catch {};
    try std.Io.Dir.symLinkAbsolute(io, from, target, .{ .is_directory = true });
}

fn putInstalled(allocator: Allocator, store: *Substrate, manifest: *const Manifest, target: []const u8) !void {
    const uri = try allocator.dupe(u8, manifest.uri);
    defer allocator.free(uri);
    try store.putPackage(.{ .package = manifest.name, .version = manifest.version, .root = target, .uri = uri });
}

const ParsedGitUri = struct {
    repo: []const u8,
    ref: ?[]const u8,
    path: ?[]const u8,

    fn deinit(self: ParsedGitUri, allocator: Allocator) void {
        allocator.free(self.repo);
        if (self.ref) |ref| allocator.free(ref);
        if (self.path) |path| allocator.free(path);
    }
};

fn parseGitUri(allocator: Allocator, uri: []const u8, override_ref: ?[]const u8) !ParsedGitUri {
    const body = uri["git+".len..];
    const split = std.mem.lastIndexOf(u8, body, "//");
    const repo_ref = if (split) |i| body[0..i] else body;
    const path = if (split) |i| body[i + 2 ..] else null;
    const at = std.mem.lastIndexOfScalar(u8, repo_ref, '@');
    const repo = if (at) |i| repo_ref[0..i] else repo_ref;
    const embedded_ref = if (at) |i| repo_ref[i + 1 ..] else null;
    return .{
        .repo = try allocator.dupe(u8, repo),
        .ref = if (override_ref orelse embedded_ref) |ref| try allocator.dupe(u8, ref) else null,
        .path = if (path) |p| try allocator.dupe(u8, p) else null,
    };
}

fn runGit(allocator: Allocator, io: std.Io, args: []const []const u8, cwd: ?[]const u8) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (args) |arg| try argv.append(allocator, arg);
    const result = try proc.run(allocator, io, argv.items, cwd, &.{}, 2 * 1024 * 1024);
    defer result.deinit(allocator);
    if (result.code != 0) {
        try files.writeAllErr(result.stderr);
        return error.GitCommandFailed;
    }
}

fn isRemote(uri: []const u8) bool {
    return std.mem.indexOf(u8, uri, "://") != null;
}
fn packageDir(allocator: Allocator, _: std.Io, scope: Scope) ![]u8 {
    return switch (scope) {
        .global => try layout.globalPath(allocator, "packages"),
        .workspace => (try layout.workspacePath(allocator, "packages")) orelse error.NoWorkspace,
    };
}

fn absolute(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
    const cwd_buf = try allocator.alloc(u8, std.fs.max_path_bytes);
    defer allocator.free(cwd_buf);
    const cwd_len = try std.process.currentPath(io, cwd_buf);
    return try std.fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
}
