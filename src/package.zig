const std = @import("std");
const serde = @import("serde");
const Substrate = @import("substrate.zig").Store;
const files = @import("io/fs.zig");
const layout = @import("io/layout.zig");
const pkg_io = @import("package/io.zig");
const Allocator = std.mem.Allocator;

pub const Ref = struct { alias: []const u8, path: []const u8 };

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    root: serde.yaml.Value,
    name: []const u8,
    version: []const u8,
    about: []const u8,
    source: ?pkg_io.Source,
    interface: pkg_io.Interface,
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
        return .{
            .arena = arena,
            .root = root,
            .name = try aa.dupe(u8, name),
            .version = try aa.dupe(u8, version),
            .about = try aa.dupe(u8, pkg_io.stringField(&root, "about") orelse ""),
            .source = try pkg_io.parseSource(aa, pkg_io.valueField(&root, "source")),
            .interface = try pkg_io.parseInterface(aa, pkg_io.valueField(&root, "interface")),
            .root_path = try aa.dupe(u8, package_root),
            .software = try pkg_io.parseSoftwareList(aa, pkg_io.valueField(&root, "software")),
        };
    }

    pub fn deinit(self: *const Manifest) void {
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
pub const ContextSelection = pkg_io.ContextSelection;
pub const ContextMap = pkg_io.ContextMap;
pub const OutputMapping = pkg_io.OutputMapping;
pub const Software = pkg_io.Software;
pub const ResolvedInvocation = pkg_io.ResolvedInvocation;
pub const Lifecycle = enum { run, install, uninstall };

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

pub fn resolveSoftwareInvocation(allocator: Allocator, store: *Substrate, software_ref: []const u8, lifecycle: Lifecycle) !ResolvedInvocation {
    _ = lifecycle;
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

    const package_dir = switch (scope) {
        .global => try layout.globalPath(allocator, "packages"),
        .workspace => (try layout.workspacePath(allocator, "packages")) orelse return error.NoWorkspace,
    };
    defer allocator.free(package_dir);
    files.mkdirP(package_dir) catch |err| {
        std.debug.print("package install: mkdir packages failed: {s}\n", .{@errorName(err)});
        return err;
    };

    const target = try std.fs.path.join(allocator, &.{ package_dir, manifest.name });
    defer allocator.free(target);
    _ = std.Io.Dir.cwd().deleteTree(io, target) catch {};
    std.Io.Dir.symLinkAbsolute(io, abs_source, target, .{ .is_directory = true }) catch |err| {
        std.debug.print("package install: symlink failed: {s}\n", .{@errorName(err)});
        return err;
    };

    const source = manifest.source orelse Source{ .uri = abs_source, .ref = null, .path = null };
    const source_uri = try allocator.dupe(u8, source.uri);
    const source_ref = if (source.ref) |ref| try allocator.dupe(u8, ref) else null;
    const source_path = if (source.path) |path| try allocator.dupe(u8, path) else null;
    store.putPackage(.{ .package = manifest.name, .version = manifest.version, .root = target, .source_uri = source_uri, .source_ref = source_ref, .source_path = source_path }) catch |err| {
        if (source_ref) |ref| allocator.free(ref);
        if (source_path) |path| allocator.free(path);
        allocator.free(source_uri);
        std.debug.print("package install: putPackage failed: {s}\n", .{@errorName(err)});
        return err;
    };
    if (source_ref) |ref| allocator.free(ref);
    if (source_path) |path| allocator.free(path);
    allocator.free(source_uri);
    try files.writeAllOut("installed ");
    try files.writeAllOut(manifest.name);
    try files.writeAllOut("\n");
}

pub fn remove(allocator: Allocator, io: std.Io, store: *Substrate, alias: []const u8) !void {
    _ = allocator;
    const pkg = (try store.getPackage(alias)) orelse return error.PackageNotInstalled;
    defer store.freePackage(pkg);
    _ = std.Io.Dir.cwd().deleteTree(io, pkg.root) catch {};
    try store.removePackage(alias);
}

pub const Scope = enum { workspace, global };

fn absolute(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
    const cwd_buf = try allocator.alloc(u8, std.fs.max_path_bytes);
    defer allocator.free(cwd_buf);
    const cwd_len = try std.process.currentPath(io, cwd_buf);
    return try std.fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
}
