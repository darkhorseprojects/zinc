const std = @import("std");
const Store = @import("../runtime/store.zig").Store;
const package_sources_table = @import("../runtime/store.zig").package_sources;
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const proc = @import("../io/process.zig");
const install = @import("install.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    name: ?[]const u8 = null,
    all: bool = false,
    check: bool = false,
};

pub fn update(allocator: Allocator, io: std.Io, store: *Store, opts: Options) !void {
    if (opts.all) {
        const pkgs = try store.listPackages();
        defer {
            for (pkgs) |pkg| store.freePackage(pkg);
            allocator.free(pkgs);
        }
        for (pkgs) |pkg| try updateOne(allocator, io, store, pkg.name, opts.check);
        return;
    }

    const name = opts.name orelse return error.MissingPackageName;
    try updateOne(allocator, io, store, name, opts.check);
}

fn updateOne(allocator: Allocator, io: std.Io, store: *Store, name: []const u8, check_only: bool) !void {
    const pkg = (try store.getPackage(name)) orelse {
        try files.writeAllErr("Package not found: ");
        try files.writeAllErr(name);
        try files.writeAllErr("\n");
        return;
    };
    defer store.freePackage(pkg);

    const source = (try store.getPackageSource(name)) orelse {
        try files.writeAllOut("Skipping local package without git source: ");
        try files.writeAllOut(name);
        try files.writeAllOut("\n");
        return;
    };
    defer store.freePackageSource(source);

    if (!std.mem.eql(u8, source.kind, "git")) return error.UnsupportedPackageSource;

    const checkout = try prepareCheckout(allocator, io, source);
    defer checkout.deinit(allocator);

    if (check_only) {
        try files.writeAllOut(name);
        try files.writeAllOut(": ");
        try files.writeAllOut(source.rev orelse "unknown");
        try files.writeAllOut(" -> ");
        try files.writeAllOut(checkout.rev);
        try files.writeAllOut("\n");
        return;
    }

    const package_root = try std.fs.path.join(allocator, &.{ checkout.dir, source.path });
    defer allocator.free(package_root);

    const is_global = if (pkg.scope) |scope| std.mem.eql(u8, scope, "global") else false;
    try install.installResolved(allocator, io, store, package_root, is_global, .{
        .git = source.url,
        .ref = source.ref,
        .path = source.path,
        .rev = checkout.rev,
    });

    try files.writeAllOut("Updated package: ");
    try files.writeAllOut(name);
    try files.writeAllOut("\n");
}

const Checkout = struct {
    dir: []u8,
    rev: []u8,

    fn deinit(self: Checkout, allocator: Allocator) void {
        allocator.free(self.dir);
        allocator.free(self.rev);
    }
};

fn prepareCheckout(allocator: Allocator, io: std.Io, source: package_sources_table) !Checkout {
    const dir = try cacheDir(allocator, source.url, source.ref);
    errdefer allocator.free(dir);

    const git_dir = try std.fs.path.join(allocator, &.{ dir, ".git" });
    defer allocator.free(git_dir);

    if (!files.existsPath(git_dir)) {
        if (std.fs.path.dirname(dir)) |parent| try files.mkdirP(parent);
        _ = std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        try runGit(allocator, io, &.{ "git", "clone", source.url, dir }, null);
    }

    try runGit(allocator, io, &.{ "git", "-C", dir, "fetch", "--tags", "--prune", "origin" }, null);

    const rev = resolveRef(allocator, io, dir, source.ref) catch |err| {
        try files.writeAllErr("Could not resolve git ref: ");
        try files.writeAllErr(source.ref);
        try files.writeAllErr("\n");
        return err;
    };
    errdefer allocator.free(rev);

    try runGit(allocator, io, &.{ "git", "-C", dir, "checkout", "--detach", rev }, null);
    return .{ .dir = dir, .rev = rev };
}

fn resolveRef(allocator: Allocator, io: std.Io, dir: []const u8, ref: []const u8) ![]u8 {
    const remote_ref = try std.fmt.allocPrint(allocator, "origin/{s}", .{ref});
    defer allocator.free(remote_ref);
    if (try revParse(allocator, io, dir, remote_ref)) |rev| return rev;

    if (try revParse(allocator, io, dir, ref)) |rev| return rev;

    const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{ref});
    defer allocator.free(tag_ref);
    if (try revParse(allocator, io, dir, tag_ref)) |rev| return rev;

    return error.GitRefNotFound;
}

fn revParse(allocator: Allocator, io: std.Io, dir: []const u8, ref: []const u8) !?[]u8 {
    const commit_ref = try std.fmt.allocPrint(allocator, "{s}^{{commit}}", .{ref});
    defer allocator.free(commit_ref);
    const result = try proc.run(allocator, io, &.{ "git", "-C", dir, "rev-parse", "--verify", commit_ref }, null, 1024 * 1024);
    defer result.deinit(allocator);
    if (result.code != 0) return null;
    return try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

fn runGit(allocator: Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8) !void {
    const result = try proc.run(allocator, io, argv, cwd, 10 * 1024 * 1024);
    defer result.deinit(allocator);
    if (result.stdout.len > 0) try files.writeAllOut(result.stdout);
    if (result.stderr.len > 0) try files.writeAllErr(result.stderr);
    if (result.code != 0) return error.GitCommandFailed;
}

fn cacheDir(allocator: Allocator, url: []const u8, ref: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(url);
    hasher.update("\n");
    hasher.update(ref);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const sub = try std.fmt.allocPrint(allocator, "cache/packages/{s}", .{hex});
    defer allocator.free(sub);
    return try layout.globalPath(allocator, sub);
}
