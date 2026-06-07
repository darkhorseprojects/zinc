const std = @import("std");
const circuitry = @import("circuitry");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const platform = @import("../platform.zig");
const manifest_pkg = @import("manifest.zig");
const source_pkg = @import("source.zig");
const discovery_pkg = @import("discovery.zig");
const assets_pkg = @import("assets.zig");

const Allocator = std.mem.Allocator;

pub const Scope = discovery_pkg.Scope;
pub const PackageRef = discovery_pkg.PackageRef;
pub const PackagePlan = discovery_pkg.PackagePlan;
pub const Tool = manifest_pkg.Tool;
pub const Script = manifest_pkg.Script;

pub const InstallOptions = struct {
    scope: Scope = .local,
    replace: bool = false,
    model: ?[]const u8 = null,
};

pub const resolveGraph = discovery_pkg.resolveGraph;
pub const resolvePrompt = discovery_pkg.resolvePrompt;
pub const resolveAsset = discovery_pkg.resolveAsset;
pub const findTool = discovery_pkg.findTool;
pub const listPackages = discovery_pkg.listPackages;
pub const listGraphs = discovery_pkg.listGraphs;

pub fn add(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, source_text: []const u8, options: InstallOptions) !PackageRef {
    var source = try source_pkg.parseSource(allocator, source_text);
    defer source.deinit(allocator);
    const staging = try source_pkg.stageSource(allocator, io, source);
    defer cleanupPath(io, staging);
    defer allocator.free(staging);
    return installStaged(allocator, io, layout_ctx, source, staging, source_text, options);
}

pub fn previewAdd(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, source_text: []const u8, options: InstallOptions) !PackagePlan {
    var source = try source_pkg.parseSource(allocator, source_text);
    defer source.deinit(allocator);
    const staging = try source_pkg.stageSource(allocator, io, source);
    errdefer {
        cleanupPath(io, staging);
        allocator.free(staging);
    }
    const text = try packagePlanText(allocator, io, layout_ctx, source, staging, source_text, options, null);
    return .{ .text = text, .staging = staging };
}

pub fn installPreviewed(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, plan: PackagePlan, source_text: []const u8, options: InstallOptions) !PackageRef {
    var source = try source_pkg.parseSource(allocator, source_text);
    defer source.deinit(allocator);
    return installStaged(allocator, io, layout_ctx, source, plan.staging, source_text, options);
}

pub fn previewUpdate(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, name: []const u8, scope: ?Scope) !PackagePlan {
    var found = try discovery_pkg.findInstalled(allocator, layout_ctx, name, scope);
    defer found.deinit(allocator);
    const source_text = try readMetadataSource(allocator, found.path);
    defer allocator.free(source_text);
    var source = try source_pkg.parseSource(allocator, source_text);
    defer source.deinit(allocator);
    const staging = try source_pkg.stageSource(allocator, io, source);
    errdefer {
        cleanupPath(io, staging);
        allocator.free(staging);
    }
    const text = try packagePlanText(allocator, io, layout_ctx, source, staging, source_text, .{ .scope = found.scope, .replace = true }, found.path);
    return .{ .text = text, .staging = staging };
}

pub fn remove(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, name: []const u8, scope: ?Scope, model: ?[]const u8) !PackageRef {
    const found = try discovery_pkg.findInstalled(allocator, layout_ctx, name, scope);
    errdefer found.deinit(allocator);
    const manifest = try manifest_pkg.loadManifest(allocator, io, found.path);
    defer manifest.deinit(allocator);
    try removePackagePatch(allocator, io, layout_ctx, manifest, .{ .scope = found.scope, .model = model });
    try removePath(io, found.path);
    if (found.scope == .local) {
        try assets_pkg.regeneratePackageGraph(allocator, io, layout_ctx);
        if (!files.existsPath(assets_pkg.package_graph_path) and files.existsPath(assets_pkg.project_loop_graph_path)) try assets_pkg.removePackagesImport(allocator, io, assets_pkg.project_loop_graph_path);
    }
    return found;
}

pub fn update(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, name: []const u8, scope: ?Scope) !PackageRef {
    var found = try discovery_pkg.findInstalled(allocator, layout_ctx, name, scope);
    defer found.deinit(allocator);
    const source = try readMetadataSource(allocator, found.path);
    defer allocator.free(source);
    return add(allocator, io, layout_ctx, source, .{ .scope = found.scope, .replace = true });
}

pub fn updateAll(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try updatePackagesInRoot(allocator, io, layout_ctx, &out, .local, ".zinc/packages");
    const global = try discovery_pkg.scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    try updatePackagesInRoot(allocator, io, layout_ctx, &out, .global, global);
    return out.toOwnedSlice(allocator);
}

pub fn show(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, name: []const u8, scope: ?Scope) ![]u8 {
    const found = try discovery_pkg.findInstalled(allocator, layout_ctx, name, scope);
    defer found.deinit(allocator);
    const manifest = try manifest_pkg.loadManifest(allocator, io, found.path);
    defer manifest.deinit(allocator);
    const source = readMetadataSource(allocator, found.path) catch try allocator.dupe(u8, "");
    defer allocator.free(source);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "name: {s}\nscope: {s}\npath: {s}\n", .{ manifest.name, scopeName(found.scope), found.path });
    if (manifest.version.len != 0) try out.print(allocator, "version: {s}\n", .{manifest.version});
    if (manifest.description.len != 0) try out.print(allocator, "description: {s}\n", .{manifest.description});
    if (source.len != 0) try out.print(allocator, "source: {s}\n", .{source});
    try appendAssets(allocator, &out, "graphs", manifest.graphs);
    try appendAssets(allocator, &out, "prompts", manifest.prompts);
    try appendAssets(allocator, &out, "files", manifest.files);
    try appendInstall(allocator, io, layout_ctx, &out, manifest, .{ .scope = found.scope });
    return out.toOwnedSlice(allocator);
}

pub fn execScript(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, package_name: []const u8, script_name: []const u8) ![]u8 {
    var found = try discovery_pkg.findInstalled(allocator, layout_ctx, package_name, null);
    defer found.deinit(allocator);
    const manifest = try manifest_pkg.loadManifest(allocator, io, found.path);
    defer manifest.deinit(allocator);
    for (manifest.scripts) |script| if (std.mem.eql(u8, script.name, script_name)) {
        const command = try platform.process.resolveCommand(allocator, io, platform.currentOS(), .{}, script.command, found.path);
        defer allocator.free(command);
        const result = try platform.process.run(allocator, io, &.{command}, found.path, 1024 * 1024);
        defer allocator.free(result.stderr);
        if (result.code != 0) {
            allocator.free(result.stdout);
            return error.PackageScriptFailed;
        }
        return result.stdout;
    };
    return error.PackageScriptNotFound;
}

fn installStaged(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, source: source_pkg.Source, staging: []const u8, source_text: []const u8, options: InstallOptions) !PackageRef {
    const package_dir = try sourcePackageDir(allocator, staging, source.subdir);
    defer allocator.free(package_dir);
    const manifest = try manifest_pkg.loadManifest(allocator, io, package_dir);
    defer manifest.deinit(allocator);

    const root = try discovery_pkg.scopeRoot(allocator, layout_ctx, options.scope);
    defer allocator.free(root);
    const destination = try std.fs.path.join(allocator, &.{ root, manifest.name });
    errdefer allocator.free(destination);

    var patch_model: ?[]u8 = null;
    defer if (patch_model) |value| allocator.free(value);
    if (files.existsPath(destination)) {
        if (!options.replace) return error.PackageAlreadyAdded;
        const current_manifest = manifest_pkg.loadManifest(allocator, io, destination) catch null;
        if (current_manifest) |m| {
            defer m.deinit(allocator);
            if (m.install) |spec| {
                if (options.scope == .local and files.existsPath(assets_pkg.project_loop_graph_path)) patch_model = assets_pkg.selectPatchedModelTarget(allocator, io, assets_pkg.project_loop_graph_path, options.model, spec) catch null;
            }
            try removePackagePatch(allocator, io, layout_ctx, m, options);
        }
        try removePath(io, destination);
    }
    try files.mkdirP(root);
    try copyTree(allocator, io, package_dir, destination);
    try writeMetadata(allocator, destination, source_text, options.scope);
    try installPackagePatch(allocator, io, layout_ctx, manifest, .{ .scope = options.scope, .replace = options.replace, .model = options.model orelse patch_model });
    return .{ .name = try allocator.dupe(u8, manifest.name), .scope = options.scope, .path = destination };
}

fn installPackagePatch(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, manifest: manifest_pkg.Manifest, options: InstallOptions) !void {
    const spec = manifest.install orelse return;
    if (options.scope != .local) return;
    const loop_path = try assets_pkg.ensureProjectLoopGraph(allocator, layout_ctx);
    defer allocator.free(loop_path);
    const model = try assets_pkg.selectModelTarget(allocator, io, loop_path, options.model);
    defer allocator.free(model);
    try assets_pkg.regeneratePackageGraph(allocator, io, layout_ctx);
    try assets_pkg.wireLoopGraph(allocator, io, loop_path, model, spec);
}

fn removePackagePatch(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, manifest: manifest_pkg.Manifest, options: InstallOptions) !void {
    _ = layout_ctx;
    const spec = manifest.install orelse return;
    if (options.scope != .local or !files.existsPath(assets_pkg.project_loop_graph_path)) return;
    const model = assets_pkg.selectPatchedModelTarget(allocator, io, assets_pkg.project_loop_graph_path, options.model, spec) catch |err| switch (err) {
        error.PackageInstallTargetNotFound => return,
        else => return err,
    };
    defer allocator.free(model);
    try assets_pkg.unwireLoopGraph(allocator, io, assets_pkg.project_loop_graph_path, model, spec);
}

fn packagePlanText(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, source: source_pkg.Source, staging: []const u8, source_text: []const u8, options: InstallOptions, current_path: ?[]const u8) ![]u8 {
    const package_dir = try sourcePackageDir(allocator, staging, source.subdir);
    defer allocator.free(package_dir);
    const manifest = try manifest_pkg.loadManifest(allocator, io, package_dir);
    defer manifest.deinit(allocator);
    const root = try discovery_pkg.scopeRoot(allocator, layout_ctx, options.scope);
    defer allocator.free(root);
    const destination = try std.fs.path.join(allocator, &.{ root, manifest.name });
    defer allocator.free(destination);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "source: {s}\nname: {s}\n", .{ source_text, manifest.name });
    if (manifest.version.len != 0) try out.print(allocator, "version: {s}\n", .{manifest.version});
    if (manifest.description.len != 0) try out.print(allocator, "description: {s}\n", .{manifest.description});
    try out.print(allocator, "scope: {s}\ntarget: {s}\n", .{ scopeName(options.scope), destination });
    if (current_path) |path| try out.print(allocator, "current: {s}\n", .{path});
    try appendAssets(allocator, &out, "graphs", manifest.graphs);
    try appendAssets(allocator, &out, "prompts", manifest.prompts);
    try appendAssets(allocator, &out, "files", manifest.files);
    try appendTools(allocator, &out, manifest.tools);
    try appendScripts(allocator, &out, manifest.scripts);
    try appendInstall(allocator, io, layout_ctx, &out, manifest, options);
    return out.toOwnedSlice(allocator);
}

fn sourcePackageDir(allocator: Allocator, root: []const u8, subdir: []const u8) ![]u8 {
    if (subdir.len == 0) return allocator.dupe(u8, root);
    return std.fs.path.join(allocator, &.{ root, subdir });
}

fn writeMetadata(allocator: Allocator, package_dir: []const u8, source: []const u8, scope: Scope) !void {
    const path = try std.fs.path.join(allocator, &.{ package_dir, meta_file });
    defer allocator.free(path);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.print(allocator, "source: {s}\nscope: {s}\n", .{ source, scopeName(scope) });
    try files.write(path, out.items);
}

fn readMetadataSource(allocator: Allocator, package_dir: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ package_dir, meta_file });
    defer allocator.free(path);
    var parsed = try circuitry.loadYamlFile(allocator, std.Options.debug_io, path);
    defer parsed.deinit();
    const source = manifest_pkg.scalarAt(&parsed.root, &.{"source"}) orelse return error.InvalidPackageMetadata;
    return allocator.dupe(u8, source);
}

fn updatePackagesInRoot(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, out: *std.ArrayList(u8), scope: Scope, root_path: []const u8) !void {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer root.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    for (names.items) |name| {
        var package = try update(allocator, io, layout_ctx, name, scope);
        defer package.deinit(allocator);
        try out.print(allocator, "updated {s}: {s}\n", .{ scopeName(package.scope), package.name });
    }
}

fn appendAssets(allocator: Allocator, out: *std.ArrayList(u8), label: []const u8, assets: []const manifest_pkg.Asset) !void {
    if (assets.len == 0) return;
    try out.print(allocator, "{s}:\n", .{label});
    for (assets) |item| try out.print(allocator, "  {s}: {s}\n", .{ item.id, item.path });
}

fn appendTools(allocator: Allocator, out: *std.ArrayList(u8), tools: []const Tool) !void {
    if (tools.len == 0) return;
    try out.appendSlice(allocator, "tools:\n");
    for (tools) |tool| try out.print(allocator, "  {s}: {s}\n", .{ tool.name, @tagName(tool.handler) });
}

fn appendScripts(allocator: Allocator, out: *std.ArrayList(u8), scripts: []const Script) !void {
    if (scripts.len == 0) return;
    try out.appendSlice(allocator, "scripts:\n");
    for (scripts) |script| try out.print(allocator, "  {s}: {s}\n", .{ script.name, script.command });
}

fn appendInstall(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, out: *std.ArrayList(u8), manifest: manifest_pkg.Manifest, options: InstallOptions) !void {
    const spec = manifest.install orelse return;
    if (options.scope != .local) return;
    const loop_path = try assets_pkg.packageLoopPath(allocator, layout_ctx);
    defer allocator.free(loop_path);
    const model = try assets_pkg.selectModelTarget(allocator, io, loop_path, options.model);
    defer allocator.free(model);
    try out.print(allocator, "install:\n  loop: {s}\n  model: {s}\n", .{ assets_pkg.project_loop_graph_path, model });
    if (spec.input.len != 0) {
        try out.appendSlice(allocator, "  add input:\n");
        for (spec.input) |ref| {
            const parsed = try manifest_pkg.parseInstallRef(ref);
            try out.print(allocator, "    - packages.{s}\n", .{parsed.id});
        }
    }
    if (spec.tools.len != 0) {
        try out.appendSlice(allocator, "  add tools:\n");
        for (spec.tools) |tool| try out.print(allocator, "    - {s}\n", .{tool});
    }
}

const meta_file = ".zinc-package.yaml";

fn scopeName(scope: Scope) []const u8 {
    return switch (scope) {
        .local => "local",
        .global => "global",
    };
}

fn cleanupPath(io: std.Io, path: []const u8) void {
    if (std.mem.indexOf(u8, std.fs.path.basename(path), "zinc-pkg-") == 0) {
        removePath(io, path) catch {};
    }
}

fn removePath(io: std.Io, path: []const u8) !void {
    var dir = std.Io.Dir.cwd();
    try dir.deleteTree(io, path);
}

fn copyTree(allocator: Allocator, io: std.Io, source: []const u8, destination: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true }) catch return error.PackageSourceNotDirectory;
    defer dir.close(io);
    try files.mkdirP(destination);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        const source_path = try std.fs.path.join(allocator, &.{ source, entry.name });
        defer allocator.free(source_path);
        const dest_path = try std.fs.path.join(allocator, &.{ destination, entry.name });
        defer allocator.free(dest_path);
        switch (entry.kind) {
            .file => try std.Io.Dir.copyFile(std.Io.Dir.cwd(), source_path, std.Io.Dir.cwd(), dest_path, io, .{ .make_path = true, .replace = true }),
            .directory => try copyTree(allocator, io, source_path, dest_path),
            else => return error.UnsupportedPackageEntry,
        }
    }
}
