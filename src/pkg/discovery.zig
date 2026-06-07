const std = @import("std");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const manifest_pkg = @import("manifest.zig");

const Allocator = std.mem.Allocator;

pub const Scope = enum { local, global };

pub const PackageRef = struct {
    name: []u8,
    scope: Scope,
    path: []u8,

    pub fn deinit(self: PackageRef, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

pub const PackagePlan = struct {
    text: []u8,
    staging: []u8,

    pub fn deinit(self: PackagePlan, allocator: Allocator, io: std.Io) void {
        cleanupPath(io, self.staging);
        allocator.free(self.staging);
        allocator.free(self.text);
    }
};

fn cleanupPath(io: std.Io, path: []const u8) void {
    if (std.mem.indexOf(u8, std.fs.path.basename(path), "zinc-pkg-") == 0) {
        var dir = std.Io.Dir.cwd();
        dir.deleteTree(io, path) catch {};
    }
}

pub fn listPackages(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendPackageNames(allocator, io, &out, .local, ".zinc/packages");
    const global = try scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    try appendPackageNames(allocator, io, &out, .global, global);
    return out.toOwnedSlice(allocator);
}

pub fn listGraphs(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendGraphDir(allocator, io, &out, "project", "graphs");
    try appendPackageGraphAssets(allocator, io, &out, .local, ".zinc/packages");
    const global = try scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    try appendPackageGraphAssets(allocator, io, &out, .global, global);
    const shared = try layout.sharePath(allocator, layout_ctx, "graphs");
    defer allocator.free(shared);
    try appendGraphDir(allocator, io, &out, "stock", shared);
    return out.toOwnedSlice(allocator);
}

pub fn resolveGraph(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, spec: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(spec)) return allocator.dupe(u8, spec);
    if (files.existsPath(spec)) return allocator.dupe(u8, spec);
    if (try graphInDir(allocator, "graphs", spec)) |path| return path;
    if (try graphAssetInRoot(allocator, io, ".zinc/packages", spec)) |path| return path;
    const global = try scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    if (try graphAssetInRoot(allocator, io, global, spec)) |path| return path;
    const shared_graphs = try layout.sharePath(allocator, layout_ctx, "graphs");
    defer allocator.free(shared_graphs);
    if (try graphInDir(allocator, shared_graphs, spec)) |path| return path;
    return error.GraphNotFound;
}

pub fn resolvePrompt(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, spec: []const u8) ![]u8 {
    if (try assetInRoot(allocator, io, ".zinc/packages", spec, .prompts)) |path| return path;
    const global = try scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    if (try assetInRoot(allocator, io, global, spec, .prompts)) |path| return path;
    return error.PromptNotFound;
}

pub fn resolveAsset(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, spec: []const u8) ![]u8 {
    if (try assetInRoot(allocator, io, ".zinc/packages", spec, .files)) |path| return path;
    const global = try scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    if (try assetInRoot(allocator, io, global, spec, .files)) |path| return path;
    return error.AssetNotFound;
}

pub fn findTool(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, name: []const u8) !?manifest_pkg.Tool {
    if (try toolInRoot(allocator, io, ".zinc/packages", name)) |tool| return tool;
    const global = try scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    return toolInRoot(allocator, io, global, name);
}

pub fn findInstalled(allocator: Allocator, layout_ctx: layout.Context, name: []const u8, scope: ?Scope) !PackageRef {
    if (scope) |s| {
        if (try installedAt(allocator, layout_ctx, name, s)) |ref| return ref;
        return error.PackageNotFound;
    }
    const local = try installedAt(allocator, layout_ctx, name, .local);
    const global = try installedAt(allocator, layout_ctx, name, .global);
    if (local != null and global != null) {
        if (local) |l| l.deinit(allocator);
        if (global) |g| g.deinit(allocator);
        return error.PackageScopeRequired;
    }
    if (local) |l| return l;
    if (global) |g| return g;
    return error.PackageNotFound;
}

pub fn installedAt(allocator: Allocator, layout_ctx: layout.Context, name: []const u8, scope: Scope) !?PackageRef {
    const root = try scopeRoot(allocator, layout_ctx, scope);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, name });
    if (!files.existsPath(path)) {
        allocator.free(path);
        return null;
    }
    return .{ .name = try allocator.dupe(u8, name), .scope = scope, .path = path };
}

pub fn scopeRoot(allocator: Allocator, layout_ctx: layout.Context, scope: Scope) ![]u8 {
    return switch (scope) {
        .local => allocator.dupe(u8, ".zinc/packages"),
        .global => layout.sharePath(allocator, layout_ctx, "packages"),
    };
}

fn graphInDir(allocator: Allocator, dir: []const u8, spec: []const u8) !?[]u8 {
    const names = [_][]const u8{ spec, try std.fmt.allocPrint(allocator, "{s}.circuitry.yaml", .{spec}), try std.fmt.allocPrint(allocator, "{s}.yaml", .{spec}) };
    defer allocator.free(names[1]);
    defer allocator.free(names[2]);
    for (names) |name| {
        const path = try std.fs.path.join(allocator, &.{ dir, name });
        if (files.existsPath(path)) return path;
        allocator.free(path);
    }
    return null;
}

fn graphAssetInRoot(allocator: Allocator, io: std.Io, root_path: []const u8, spec: []const u8) !?[]u8 {
    return assetInRoot(allocator, io, root_path, spec, .graphs);
}

const AssetKind = enum { graphs, prompts, files };

fn assetInRoot(allocator: Allocator, io: std.Io, root_path: []const u8, spec: []const u8, kind: AssetKind) !?[]u8 {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return null;
    defer root.close(io);
    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const package_dir = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(package_dir);
        const manifest = manifest_pkg.loadManifest(allocator, io, package_dir) catch continue;
        defer manifest.deinit(allocator);
        const assets = assetsFor(manifest, kind);
        for (assets) |item| {
            if (std.mem.eql(u8, item.id, spec)) {
                const path = try std.fs.path.join(allocator, &.{ package_dir, item.path });
                return path;
            }
        }
    }
    return null;
}

fn toolInRoot(allocator: Allocator, io: std.Io, root_path: []const u8, name: []const u8) !?manifest_pkg.Tool {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return null;
    defer root.close(io);
    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const package_dir = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(package_dir);
        const manifest = manifest_pkg.loadManifest(allocator, io, package_dir) catch continue;
        defer manifest.deinit(allocator);
        for (manifest.tools) |tool| if (std.mem.eql(u8, tool.name, name)) return try cloneTool(allocator, tool);
    }
    return null;
}

fn cloneTool(allocator: Allocator, tool: manifest_pkg.Tool) !manifest_pkg.Tool {
    var params = try allocator.alloc(manifest_pkg.Param, tool.params.len);
    var initialized: usize = 0;
    errdefer {
        for (params[0..initialized]) |param| param.deinit(allocator);
        allocator.free(params);
    }
    for (tool.params, 0..) |param, i| {
        params[i] = .{ .name = try allocator.dupe(u8, param.name), .kind = try allocator.dupe(u8, param.kind), .description = try allocator.dupe(u8, param.description), .required = param.required };
        initialized += 1;
    }
    return .{
        .name = try allocator.dupe(u8, tool.name),
        .label = try allocator.dupe(u8, tool.label),
        .description = try allocator.dupe(u8, tool.description),
        .prompt = try allocator.dupe(u8, tool.prompt),
        .params = params,
        .handler = try cloneHandler(allocator, tool.handler),
        .package_dir = try allocator.dupe(u8, tool.package_dir),
    };
}

fn cloneHandler(allocator: Allocator, handler: manifest_pkg.Handler) !manifest_pkg.Handler {
    return switch (handler) {
        .process => |h| .{ .process = .{ .command = try allocator.dupe(u8, h.command) } },
        .http => |h| .{ .http = .{ .url = try allocator.dupe(u8, h.url), .method = try allocator.dupe(u8, h.method) } },
        .mcp => |h| .{ .mcp = .{ .command = try allocator.dupe(u8, h.command), .tool = try allocator.dupe(u8, h.tool) } },
    };
}

fn appendPackageNames(allocator: Allocator, io: std.Io, out: *std.ArrayList(u8), scope: Scope, root_path: []const u8) !void {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer root.close(io);
    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const package_dir = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(package_dir);
        const manifest = manifest_pkg.loadManifest(allocator, io, package_dir) catch continue;
        defer manifest.deinit(allocator);
        try out.print(allocator, "{s}: {s}", .{ scopeName(scope), manifest.name });
        if (manifest.version.len != 0) try out.print(allocator, "@{s}", .{manifest.version});
        try out.print(allocator, "  {s}\n", .{package_dir});
    }
}

fn appendPackageGraphAssets(allocator: Allocator, io: std.Io, out: *std.ArrayList(u8), scope: Scope, root_path: []const u8) !void {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer root.close(io);
    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const package_dir = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(package_dir);
        const manifest = manifest_pkg.loadManifest(allocator, io, package_dir) catch continue;
        defer manifest.deinit(allocator);
        for (manifest.graphs) |item| try out.print(allocator, "{s} package {s}: {s} -> {s}/{s}\n", .{ scopeName(scope), manifest.name, item.id, package_dir, item.path });
    }
}

fn appendGraphDir(allocator: Allocator, io: std.Io, out: *std.ArrayList(u8), scope: []const u8, dir_path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.endsWith(u8, entry.name, ".yml")) continue;
        try out.print(allocator, "{s}: {s}/{s}\n", .{ scope, dir_path, entry.name });
    }
}

fn assetsFor(manifest: manifest_pkg.Manifest, kind: AssetKind) []const manifest_pkg.Asset {
    return switch (kind) {
        .graphs => manifest.graphs,
        .prompts => manifest.prompts,
        .files => manifest.files,
    };
}

fn scopeName(scope: Scope) []const u8 {
    return switch (scope) {
        .local => "local",
        .global => "global",
    };
}
