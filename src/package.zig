const std = @import("std");
const serde = @import("serde");
const Substrate = @import("substrate.zig").Store;
const files = @import("io/fs.zig");
const layout = @import("io/layout.zig");
const proc = @import("io/process.zig");
const platform = @import("platform/mod.zig");

const Allocator = std.mem.Allocator;

pub const Ref = struct { alias: []const u8, path: []const u8 };

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    root: serde.yaml.Value,
    name: []const u8,
    version: []const u8,
    about: []const u8,

    pub fn open(allocator: Allocator, package_root: []const u8) !Manifest {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();
        const manifest_path = try std.fs.path.join(aa, &.{ package_root, "zinc.pkg.yaml" });
        const bytes = try files.readLimited(aa, manifest_path, 10 * 1024 * 1024);
        const root = try serde.yaml.parse(aa, bytes);
        if (root != .mapping) return error.InvalidPackageManifest;
        const name = stringField(&root, "name") orelse return error.PackageNameMissing;
        const version = stringField(&root, "version") orelse return error.PackageVersionMissing;
        return .{ .arena = arena, .root = root, .name = name, .version = version, .about = stringField(&root, "about") orelse "" };
    }

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }

    pub fn rel(self: *const Manifest, query: []const u8) ![]const u8 {
        const leaf = try self.node(query);
        return switch (leaf.*) {
            .string => leaf.string,
            .mapping => blk: {
                const path = leaf.mapping.getPtr("path") orelse return error.PackagePathMissing;
                if (path.* != .string) return error.PackagePathInvalid;
                break :blk path.string;
            },
            else => error.PackagePathInvalid,
        };
    }

    pub fn optionalRel(self: *const Manifest, query: []const u8) !?[]const u8 {
        return self.rel(query) catch |err| switch (err) {
            error.PackagePathNotFound => null,
            else => err,
        };
    }

    pub fn node(self: *const Manifest, query: []const u8) !*const serde.yaml.Value {
        if (self.root != .mapping) return error.InvalidPackageManifest;
        var current: *const serde.yaml.Value = &self.root;
        var it = std.mem.tokenizeAny(u8, query, "/.");
        while (it.next()) |segment| {
            if (current.* != .mapping) return error.PackagePathNotFound;
            current = current.mapping.getPtr(segment) orelse return error.PackagePathNotFound;
        }
        return current;
    }

    pub fn source(self: *const Manifest) !?Source {
        const source_node = if (self.root == .mapping) self.root.mapping.getPtr("source") else null;
        const source_map = source_node orelse return null;
        if (source_map.* != .mapping) return error.InvalidPackageSource;
        const git_url = stringField(source_map, "git") orelse return error.PackageSourceGitMissing;
        return .{ .git = git_url, .ref = stringField(source_map, "ref") orelse "main", .path = stringField(source_map, "path") orelse "." };
    }
};

pub const Source = struct { git: []const u8, ref: []const u8, path: []const u8 };

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
    const path = if (query.len == 0 or std.mem.eql(u8, query, "manifest")) blk: {
        const pkg = (try store.getPackage(alias)) orelse return error.PackageNotInstalled;
        defer store.freePackage(pkg);
        break :blk try std.fs.path.join(allocator, &.{ pkg.root, "zinc.pkg.yaml" });
    } else try resolve(allocator, store, alias, query);
    defer allocator.free(path);
    return try files.readLimited(allocator, path, 64 * 1024 * 1024);
}

pub fn install(allocator: Allocator, io: std.Io, store: *Substrate, source_root: []const u8, scope: Scope) !void {
    const abs_source = try absolute(allocator, io, source_root);
    defer allocator.free(abs_source);

    var manifest = try Manifest.open(allocator, abs_source);
    defer manifest.deinit();

    const package_dir = switch (scope) {
        .global => try layout.globalPath(allocator, "packages"),
        .workspace => (try layout.workspacePath(allocator, "packages")) orelse return error.NoWorkspace,
    };
    defer allocator.free(package_dir);
    try files.mkdirP(package_dir);

    const target = try std.fs.path.join(allocator, &.{ package_dir, manifest.name });
    defer allocator.free(target);
    _ = std.Io.Dir.cwd().deleteTree(io, target) catch {};
    try std.Io.Dir.symLinkAbsolute(io, abs_source, target, .{ .is_directory = true });

    try runHook(allocator, io, target, &manifest, "setup");

    _ = std.Io.Clock.now(.real, io).toSeconds();
    try store.putPackage(.{ .package = manifest.name, .root = target });
    try files.writeAllOut("installed ");
    try files.writeAllOut(manifest.name);
    try files.writeAllOut("\n");
}

pub fn remove(allocator: Allocator, io: std.Io, store: *Substrate, alias: []const u8) !void {
    const pkg = (try store.getPackage(alias)) orelse return error.PackageNotInstalled;
    defer store.freePackage(pkg);
    var manifest = try Manifest.open(allocator, pkg.root);
    defer manifest.deinit();
    try runHook(allocator, io, pkg.root, &manifest, "remove");
    _ = std.Io.Dir.cwd().deleteTree(io, pkg.root) catch {};
    try store.removePackage(alias);
}

pub fn check(allocator: Allocator, io: std.Io, store: *Substrate, alias: []const u8) !void {
    const pkg = (try store.getPackage(alias)) orelse return error.PackageNotInstalled;
    defer store.freePackage(pkg);
    var manifest = try Manifest.open(allocator, pkg.root);
    defer manifest.deinit();
    try runHook(allocator, io, pkg.root, &manifest, "check");
    _ = std.Io.Clock.now(.real, io).toSeconds();
}

pub fn update(allocator: Allocator, io: std.Io, store: *Substrate, alias: []const u8, check_only: bool) !void {
    const pkg = (try store.getPackage(alias)) orelse return error.PackageNotInstalled;
    defer store.freePackage(pkg);
    var current = try Manifest.open(allocator, pkg.root);
    defer current.deinit();
    const source = (try current.source()) orelse return error.LocalPackageHasNoSource;
    const checkout = try checkoutSource(allocator, io, source);
    defer checkout.deinit(allocator);
    if (check_only) {
        try files.writeAllOut(alias);
        try files.writeAllOut(": ");
        try files.writeAllOut(checkout.rev);
        try files.writeAllOut("\n");
        return;
    }
    const next_root = try std.fs.path.join(allocator, &.{ checkout.root, source.path });
    defer allocator.free(next_root);
    try install(allocator, io, store, next_root, try scopeForInstalledRoot(allocator, pkg.root));
}

pub const Scope = enum { workspace, global };

const Checkout = struct {
    root: []u8,
    rev: []u8,
    fn deinit(self: Checkout, allocator: Allocator) void {
        allocator.free(self.root);
        allocator.free(self.rev);
    }
};

fn runHook(allocator: Allocator, io: std.Io, root: []const u8, manifest: *const Manifest, hook: []const u8) !void {
    const query = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ hook, @tagName(platform.currentOS()) });
    defer allocator.free(query);
    const rel_path = try manifest.optionalRel(query) orelse return;
    const path = try std.fs.path.join(allocator, &.{ root, rel_path });
    defer allocator.free(path);
    if (!files.existsPath(path)) return error.PackageHookMissing;
    if (platform.currentOS() != .windows) {
        var f = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
        defer f.close(io);
        try f.setPermissions(io, @enumFromInt(0o755));
    }
    const result = try proc.run(allocator, io, &.{path}, root, 10 * 1024 * 1024);
    defer result.deinit(allocator);
    if (result.stdout.len > 0) try files.writeAllOut(result.stdout);
    if (result.stderr.len > 0) try files.writeAllErr(result.stderr);
    if (result.code != 0) return error.PackageHookFailed;
}

fn checkoutSource(allocator: Allocator, io: std.Io, source: Source) !Checkout {
    const root = try cacheRoot(allocator, source.git, source.ref);
    errdefer allocator.free(root);
    const git_dir = try std.fs.path.join(allocator, &.{ root, ".git" });
    defer allocator.free(git_dir);
    if (!files.existsPath(git_dir)) {
        if (std.fs.path.dirname(root)) |parent| try files.mkdirP(parent);
        _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
        try git(allocator, io, &.{ "git", "clone", source.git, root });
    }
    try git(allocator, io, &.{ "git", "-C", root, "fetch", "--tags", "--prune", "origin" });
    const rev = try gitRev(allocator, io, root, source.ref);
    errdefer allocator.free(rev);
    try git(allocator, io, &.{ "git", "-C", root, "checkout", "--detach", rev });
    return .{ .root = root, .rev = rev };
}

fn gitRev(allocator: Allocator, io: std.Io, root: []const u8, ref: []const u8) ![]u8 {
    const remote = try std.fmt.allocPrint(allocator, "origin/{s}", .{ref});
    defer allocator.free(remote);
    if (try revParse(allocator, io, root, remote)) |rev| return rev;
    if (try revParse(allocator, io, root, ref)) |rev| return rev;
    const tag = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{ref});
    defer allocator.free(tag);
    if (try revParse(allocator, io, root, tag)) |rev| return rev;
    return error.GitRefNotFound;
}

fn revParse(allocator: Allocator, io: std.Io, root: []const u8, ref: []const u8) !?[]u8 {
    const commit_ref = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{ref});
    defer allocator.free(commit_ref);
    const result = try proc.run(allocator, io, &.{ "git", "-C", root, "rev-parse", "--verify", commit_ref }, null, 1024 * 1024);
    defer result.deinit(allocator);
    if (result.code != 0) return null;
    return try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

fn git(allocator: Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try proc.run(allocator, io, argv, null, 10 * 1024 * 1024);
    defer result.deinit(allocator);
    if (result.stdout.len > 0) try files.writeAllOut(result.stdout);
    if (result.stderr.len > 0) try files.writeAllErr(result.stderr);
    if (result.code != 0) return error.GitFailed;
}

fn scopeForInstalledRoot(allocator: Allocator, root: []const u8) !Scope {
    const global_packages = try layout.globalPath(allocator, "packages");
    defer allocator.free(global_packages);
    if (std.mem.startsWith(u8, root, global_packages)) return .global;
    return .workspace;
}

fn cacheRoot(allocator: Allocator, git_url: []const u8, ref: []const u8) ![]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(git_url);
    h.update("\n");
    h.update(ref);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const sub = try std.fmt.allocPrint(allocator, "cache/packages/{s}", .{hex});
    defer allocator.free(sub);
    return try layout.globalPath(allocator, sub);
}

fn absolute(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
    const cwd_buf = try allocator.alloc(u8, std.fs.max_path_bytes);
    defer allocator.free(cwd_buf);
    const cwd_len = try std.process.currentPath(io, cwd_buf);
    return try std.fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
}

fn stringField(node: *const serde.yaml.Value, key: []const u8) ?[]const u8 {
    if (node.* != .mapping) return null;
    const value = node.mapping.getPtr(key) orelse return null;
    return if (value.* == .string) value.string else null;
}
