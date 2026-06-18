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
    source: ?pkg_io.Source,
    interface: pkg_io.Interface,
    links: []pkg_io.Link,
    root_path: []const u8,
    software: []pkg_io.Software,

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
        const source = try pkg_io.parseSource(aa, pkg_io.valueField(&root, "source"));
        const interface = try pkg_io.parseInterface(aa, pkg_io.valueField(&root, "interface"));
        const links = try pkg_io.parseLinks(aa, pkg_io.valueField(&root, "links"));
        const root_path = try aa.dupe(u8, package_root);
        const software = try pkg_io.parseSoftwareList(aa, pkg_io.valueField(&root, "software"));

        return .{
            .arena = arena,
            .root = root,
            .name = parsed_name,
            .version = parsed_version,
            .about = about,
            .source = source,
            .interface = interface,
            .links = links,
            .root_path = root_path,
            .software = software,
        };
    }

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }

    pub fn softwareEntry(self: *const Manifest, name: []const u8) ?*const pkg_io.Software {
        for (self.software) |*entry| if (std.mem.eql(u8, entry.name, name)) return entry;
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

pub const Source = pkg_io.Source;
pub const Interface = pkg_io.Interface;
pub const OutputMapping = pkg_io.OutputMapping;
pub const Software = pkg_io.Software;
pub const ResolvedInvocation = pkg_io.ResolvedInvocation;
pub const LinkStatus = struct {
    owner: []const u8,
    package: []const u8,
    ref: ?[]const u8,
    installed: bool,
    version: ?[]const u8,
    root: ?[]const u8,

    pub fn deinit(self: *const LinkStatus, allocator: Allocator) void {
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
    } else try resolve(allocator, store, alias, query);
    defer allocator.free(path);
    return try files.readLimited(allocator, path, 64 * 1024 * 1024);
}

pub fn resolveSoftwareInvocation(allocator: Allocator, store: *Substrate, software_ref: []const u8) !ResolvedInvocation {
    const ref = try parseRef(software_ref);
    const pkg = (try store.getPackage(ref.alias)) orelse return error.PackageNotInstalled;
    defer store.freePackage(pkg);
    var manifest = try Manifest.open(allocator, pkg.root);
    defer manifest.deinit();
    const software = manifest.softwareEntry(ref.path) orelse return error.SoftwareNotFound;
    return software.resolve(pkg.root);
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

pub fn listLinks(allocator: Allocator, store: *Substrate, selector: []const u8, missing_only: bool) ![]LinkStatus {
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
            for (manifest.links) |link| {
                if (try linkStatusCounts(store, link, missing_only)) count += 1;
            }
        }
    }

    const rows = try allocator.alloc(LinkStatus, count);
    errdefer allocator.free(rows);
    var index: usize = 0;
    for (pkgs) |pkg| {
        if (!std.mem.eql(u8, selector, "all") and !std.mem.eql(u8, selector, pkg.package)) continue;
        {
            var manifest = Manifest.open(allocator, pkg.root) catch continue;
            defer manifest.deinit();
            for (manifest.links) |link| {
                if (try appendLinkStatus(allocator, store, rows, &index, pkg.package, link, missing_only)) {}
            }
        }
    }
    return rows;
}

fn linkStatusCounts(store: *Substrate, link: pkg_io.Link, missing_only: bool) !bool {
    const installed = try store.getPackage(link.package);
    defer if (installed) |row| store.freePackage(row);
    if (installed) |row| {
        const matches = if (link.ref) |ref| std.mem.eql(u8, ref, row.version) else true;
        return !missing_only or !matches;
    }
    return missing_only;
}

fn appendLinkStatus(allocator: Allocator, store: *Substrate, rows: []LinkStatus, index: *usize, owner: []const u8, link: pkg_io.Link, missing_only: bool) !bool {
    const installed = try store.getPackage(link.package);
    if (installed) |row| {
        defer store.freePackage(row);
        const matches = if (link.ref) |ref| std.mem.eql(u8, ref, row.version) else true;
        if (missing_only and matches) return false;
        rows[index.*] = .{
            .owner = try allocator.dupe(u8, owner),
            .package = try allocator.dupe(u8, link.package),
            .ref = if (link.ref) |ref| try allocator.dupe(u8, ref) else null,
            .installed = true,
            .version = try allocator.dupe(u8, row.version),
            .root = try allocator.dupe(u8, row.root),
        };
    } else {
        if (missing_only == false) return false;
        rows[index.*] = .{
            .owner = try allocator.dupe(u8, owner),
            .package = try allocator.dupe(u8, link.package),
            .ref = if (link.ref) |ref| try allocator.dupe(u8, ref) else null,
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

    const source = pkg.source_uri orelse {
        try files.writeAllOut("skipped ");
        try files.writeAllOut(pkg.package);
        try files.writeAllOut(" source metadata missing\n");
        return;
    };
    const source_ref = options.requested_ref orelse pkg.source_ref orelse {
        try files.writeAllOut("skipped ");
        try files.writeAllOut(pkg.package);
        try files.writeAllOut(" source ref missing\n");
        return;
    };
    const source_path = pkg.source_path;

    if (options.dry_run) {
        try files.writeAllOut("would update ");
        try files.writeAllOut(pkg.package);
        try files.writeAllOut(" ");
        try files.writeAllOut(pkg.version);
        try files.writeAllOut(" from ");
        try files.writeAllOut(source);
        try files.writeAllOut("@");
        try files.writeAllOut(source_ref);
        if (source_path) |path| {
            try files.writeAllOut("/");
            try files.writeAllOut(path);
        }
        try files.writeAllOut("\n");
        return;
    }

    var resolved = try resolveSource(allocator, io, pkg.package, source, source_ref, source_path);
    if (resolved.moved) {
        defer _ = std.Io.Dir.cwd().deleteTree(io, resolved.root) catch {};
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
        resolved.moved = true;
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

const ResolvedSource = struct { root: []const u8, moved: bool };

fn resolveSource(allocator: Allocator, io: std.Io, alias: []const u8, uri: []const u8, ref: []const u8, path: ?[]const u8) !ResolvedSource {
    if (!isRemote(uri)) {
        const abs = try absolute(allocator, io, uri);
        const root = if (path) |p| try std.fs.path.join(allocator, &.{ abs, p }) else abs;
        return .{ .root = root, .moved = false };
    }

    const base = try layout.tempRunPath(allocator, "updates");
    defer allocator.free(base);
    try files.mkdirP(base);
    const token = try allocator.dupe(u8, alias);
    defer allocator.free(token);
    const repo_dir = try std.fs.path.join(allocator, &.{ base, token });
    errdefer _ = std.Io.Dir.cwd().deleteTree(io, repo_dir) catch {};

    const clean_uri = if (std.mem.startsWith(u8, uri, "git+")) uri[4..] else uri;
    try runGit(allocator, io, &.{ "clone", "--depth", "1", clean_uri, repo_dir }, null);
    try runGit(allocator, io, &.{ "-C", repo_dir, "checkout", ref }, null);

    const root = if (path) |p| try std.fs.path.join(allocator, &.{ repo_dir, p }) else repo_dir;
    return .{ .root = root, .moved = true };
}

fn replaceMoved(allocator: Allocator, io: std.Io, store: *Substrate, manifest: *const Manifest, target: []const u8, source: []const u8) !void {
    const package_dir = std.fs.path.dirname(target) orelse return error.InvalidPackagePath;
    try files.mkdirP(package_dir);
    const backup = try std.fmt.allocPrint(allocator, "{s}/{s}.previous", .{ package_dir, manifest.name });
    defer allocator.free(backup);
    _ = std.Io.Dir.cwd().deleteTree(io, backup) catch {};
    std.Io.Dir.renameAbsolute(target, backup, io) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.renameAbsolute(source, target, io) catch |err| {
        _ = std.Io.Dir.renameAbsolute(backup, target, io) catch {};
        return err;
    };
    putInstalled(allocator, store, manifest, target) catch |err| {
        _ = std.Io.Dir.renameAbsolute(target, source, io) catch {};
        _ = std.Io.Dir.renameAbsolute(backup, target, io) catch {};
        return err;
    };
    _ = std.Io.Dir.cwd().deleteTree(io, backup) catch {};
}

fn replaceLocal(allocator: Allocator, io: std.Io, target: []const u8, source: []const u8) !void {
    _ = allocator;
    const package_dir = std.fs.path.dirname(target) orelse return error.InvalidPackagePath;
    try files.mkdirP(package_dir);
    _ = std.Io.Dir.cwd().deleteTree(io, target) catch {};
    try std.Io.Dir.symLinkAbsolute(io, source, target, .{ .is_directory = true });
}

fn putInstalled(allocator: Allocator, store: *Substrate, manifest: *const Manifest, target: []const u8) !void {
    const source = manifest.source orelse Source{ .uri = target, .ref = null, .path = null };
    const source_uri = try allocator.dupe(u8, source.uri);
    const source_ref = if (source.ref) |ref| try allocator.dupe(u8, ref) else null;
    const source_path = if (source.path) |path| try allocator.dupe(u8, path) else null;
    store.putPackage(.{ .package = manifest.name, .version = manifest.version, .root = target, .source_uri = source_uri, .source_ref = source_ref, .source_path = source_path }) catch |err| {
        if (source_ref) |ref| allocator.free(ref);
        if (source_path) |path| allocator.free(path);
        allocator.free(source_uri);
        return err;
    };
    if (source_ref) |ref| allocator.free(ref);
    if (source_path) |path| allocator.free(path);
    allocator.free(source_uri);
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
