const std = @import("std");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const circuitry = @import("circuitry");
const manifest_pkg = @import("manifest.zig");
const discovery = @import("discovery.zig");

const Allocator = std.mem.Allocator;

pub const project_loop_graph_path = ".zinc/graphs/zinc-loop.circuitry.yaml";
pub const package_graph_path = ".zinc/generated/packages.circuitry.yaml";

pub fn regeneratePackageGraph(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) !void {
    try files.mkdirP(".zinc/generated");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator,
        \\circuitry: "0.5"
        \\title: Zinc packages
        \\resources:
        \\
    );
    try appendInstalledPackageResources(allocator, io, layout_ctx, &out, ".zinc/packages");
    const global = try discovery.scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    try appendInstalledPackageResources(allocator, io, layout_ctx, &out, global);
    if (std.mem.eql(u8, out.items,
        \\circuitry: "0.5"
        \\title: Zinc packages
        \\resources:
        \\
    )) {
        try files.write(package_graph_path,
            \\circuitry: "0.5"
            \\title: Zinc packages
            \\resources: {}
            \\
        );
        out.deinit(allocator);
        return;
    }
    try files.write(package_graph_path, out.items);
    out.deinit(allocator);
}

fn appendInstalledPackageResources(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, out: *std.ArrayList(u8), root_path: []const u8) !void {
    _ = layout_ctx;
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer root.close(io);
    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const package_dir = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(package_dir);
        const manifest = manifest_pkg.loadManifest(allocator, io, package_dir) catch continue;
        defer manifest.deinit(allocator);
        if (manifest.install) |spec| for (spec.input) |ref| try appendPackageInputResource(allocator, io, out, manifest, package_dir, ref);
    }
}

fn appendPackageInputResource(allocator: Allocator, io: std.Io, out: *std.ArrayList(u8), manifest: manifest_pkg.Manifest, package_dir: []const u8, ref: []const u8) !void {
    const parsed = try manifest_pkg.parseInstallRef(ref);
    switch (parsed.kind) {
        .prompt => {
            _ = findAsset(manifest.prompts, parsed.id) orelse return error.InvalidPackageManifest;
            try out.print(allocator,
                \\  {s}:
                \\    text:
                \\      uri: prompt:{s}
                \\
            , .{ parsed.id, parsed.id });
        },
        .file => {
            const asset = findAsset(manifest.files, parsed.id) orelse return error.InvalidPackageManifest;
            const cwd = try currentWorkingDirectory(allocator, io);
            defer allocator.free(cwd);
            const path = try std.fs.path.join(allocator, &.{ cwd, package_dir, asset.path });
            defer allocator.free(path);
            try out.print(allocator,
                \\  {s}:
                \\    text:
                \\
            , .{parsed.id});
            try out.appendSlice(allocator, "      path: ");
            try files.appendJsonString(allocator, out, path);
            try out.append(allocator, '\n');
        },
    }
}

pub fn wireLoopGraph(allocator: Allocator, io: std.Io, loop_path: []const u8, model: []const u8, spec: manifest_pkg.InstallSpec) !void {
    const text = try files.readLimited(allocator, loop_path, 1024 * 1024);
    defer allocator.free(text);
    var edited = try ensurePackagesImport(allocator, io, text);
    defer allocator.free(edited);
    for (spec.input) |ref| {
        const parsed = try manifest_pkg.parseInstallRef(ref);
        const item = try std.fmt.allocPrint(allocator, "packages.{s}", .{parsed.id});
        defer allocator.free(item);
        const next = try ensureModelListItem(allocator, edited, model, "input", item);
        allocator.free(edited);
        edited = next;
    }
    for (spec.tools) |tool| {
        const next = try ensureModelListItem(allocator, edited, model, "tools", tool);
        allocator.free(edited);
        edited = next;
    }
    try files.write(loop_path, edited);
}

pub fn unwireLoopGraph(allocator: Allocator, io: std.Io, loop_path: []const u8, model: []const u8, spec: manifest_pkg.InstallSpec) !void {
    _ = io;
    const text = try files.readLimited(allocator, loop_path, 1024 * 1024);
    defer allocator.free(text);
    var edited = try allocator.dupe(u8, text);
    defer allocator.free(edited);
    for (spec.input) |ref| {
        const parsed = try manifest_pkg.parseInstallRef(ref);
        const item = try std.fmt.allocPrint(allocator, "packages.{s}", .{parsed.id});
        defer allocator.free(item);
        const next = try removeModelListItem(allocator, edited, model, "input", item);
        allocator.free(edited);
        edited = next;
    }
    for (spec.tools) |tool| {
        const next = try removeModelListItem(allocator, edited, model, "tools", tool);
        allocator.free(edited);
        edited = next;
    }
    try files.write(loop_path, edited);
}

pub fn ensurePackagesImport(allocator: Allocator, io: std.Io, text: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, text, "\n  packages:") != null) return allocator.dupe(u8, text);
    const cwd = try currentWorkingDirectory(allocator, io);
    defer allocator.free(cwd);
    const import_path = try std.fs.path.join(allocator, &.{ cwd, package_graph_path });
    defer allocator.free(import_path);
    if (std.mem.indexOf(u8, text, "imports:\n")) |imports_pos| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, "  packages: ");
        try files.appendJsonString(allocator, &line, import_path);
        try line.append(allocator, '\n');
        const insert_pos = imports_pos + "imports:\n".len;
        return splice(allocator, text, insert_pos, line.items);
    }
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(allocator);
    try block.appendSlice(allocator, "imports:\n  packages: ");
    try files.appendJsonString(allocator, &block, import_path);
    try block.appendSlice(allocator, "\n\n");
    if (std.mem.indexOf(u8, text, "\nexports:\n")) |pos| return splice(allocator, text, pos + 1, block.items);
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ block.items, text });
}

pub fn removePackagesImport(allocator: Allocator, io: std.Io, loop_path: []const u8) !void {
    _ = io;
    const text = try files.readLimited(allocator, loop_path, 1024 * 1024);
    defer allocator.free(text);
    const line_start = std.mem.indexOf(u8, text, "  packages:") orelse return;
    const line_end = (std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len - 1) + 1;
    var edited = try spliceRemove(allocator, text, line_start, line_end - line_start);
    defer allocator.free(edited);
    if (std.mem.indexOf(u8, edited, "imports:\n\n")) |empty_imports| {
        const next = try spliceRemove(allocator, edited, empty_imports, "imports:\n\n".len);
        allocator.free(edited);
        edited = next;
    }
    try files.write(loop_path, edited);
}

fn ensureModelListItem(allocator: Allocator, text: []const u8, model: []const u8, field: []const u8, item: []const u8) ![]u8 {
    const field_pos = try modelFieldPosition(allocator, text, model, field);
    const block_end = nextResourcePosition(text, field_pos) orelse text.len;
    if (std.mem.indexOf(u8, text[field_pos..block_end], item) != null) return allocator.dupe(u8, text);
    const header_end = std.mem.indexOfScalarPos(u8, text, field_pos, '\n') orelse return error.PackageInstallTargetNotFound;
    const insert = try std.fmt.allocPrint(allocator, "        - {s}\n", .{item});
    defer allocator.free(insert);
    return splice(allocator, text, header_end + 1, insert);
}

fn removeModelListItem(allocator: Allocator, text: []const u8, model: []const u8, field: []const u8, item: []const u8) ![]u8 {
    const field_pos = modelFieldPosition(allocator, text, model, field) catch return allocator.dupe(u8, text);
    const block_end = nextResourcePosition(text, field_pos) orelse text.len;
    const item_line = try std.fmt.allocPrint(allocator, "        - {s}\n", .{item});
    defer allocator.free(item_line);
    const rel = std.mem.indexOf(u8, text[field_pos..block_end], item_line) orelse return allocator.dupe(u8, text);
    return spliceRemove(allocator, text, field_pos + rel, item_line.len);
}

fn modelFieldPosition(allocator: Allocator, text: []const u8, model: []const u8, field: []const u8) !usize {
    const model_header = try std.fmt.allocPrint(allocator, "  {s}:\n    model:\n", .{model});
    defer allocator.free(model_header);
    const model_pos = std.mem.indexOf(u8, text, model_header) orelse return error.PackageInstallTargetNotFound;
    const model_end = nextResourcePosition(text, model_pos + model_header.len) orelse text.len;
    const field_header = try std.fmt.allocPrint(allocator, "      {s}:\n", .{field});
    defer allocator.free(field_header);
    const rel = std.mem.indexOf(u8, text[model_pos..model_end], field_header) orelse return error.PackageInstallTargetNotFound;
    return model_pos + rel;
}

fn nextResourcePosition(text: []const u8, start: usize) ?usize {
    var pos = start;
    while (std.mem.indexOf(u8, text[pos..], "\n  ")) |rel| {
        pos += rel + 1;
        if (pos + 2 < text.len and text[pos + 2] != ' ') return pos;
        pos += 2;
    }
    return null;
}

fn currentWorkingDirectory(allocator: Allocator, io: std.Io) ![]u8 {
    const cwd_z = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_z);
    return allocator.dupe(u8, cwd_z[0..cwd_z.len]);
}

fn splice(allocator: Allocator, text: []const u8, pos: usize, insert: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text[0..pos]);
    try out.appendSlice(allocator, insert);
    try out.appendSlice(allocator, text[pos..]);
    return out.toOwnedSlice(allocator);
}

fn spliceRemove(allocator: Allocator, text: []const u8, pos: usize, len: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text[0..pos]);
    try out.appendSlice(allocator, text[pos + len ..]);
    return out.toOwnedSlice(allocator);
}

pub fn selectModelTarget(allocator: Allocator, io: std.Io, loop_path: []const u8, requested: ?[]const u8) ![]u8 {
    var graph = try circuitry.loadFile(allocator, io, loop_path);
    defer graph.deinit();
    const matches = try circuitry.query.resourcesByKind(allocator, &graph, "model");
    defer allocator.free(matches);
    if (requested) |id| {
        for (matches) |item| if (std.mem.eql(u8, item.id, id)) return allocator.dupe(u8, id);
        return error.PackageInstallTargetNotFound;
    }
    if (matches.len == 0) return error.PackageInstallTargetNotFound;
    if (matches.len == 1) return allocator.dupe(u8, matches[0].id);
    return error.PackageInstallTargetRequired;
}

pub fn selectPatchedModelTarget(allocator: Allocator, io: std.Io, loop_path: []const u8, requested: ?[]const u8, spec: manifest_pkg.InstallSpec) ![]u8 {
    if (requested != null) return selectModelTarget(allocator, io, loop_path, requested);
    var graph = try circuitry.loadFile(allocator, io, loop_path);
    defer graph.deinit();
    const matches = try circuitry.query.resourcesByKind(allocator, &graph, "model");
    defer allocator.free(matches);
    const text = try files.readLimited(allocator, loop_path, 1024 * 1024);
    defer allocator.free(text);
    var found: ?[]const u8 = null;
    for (matches) |item| {
        if (!modelHasInstallSpec(allocator, text, item.id, spec)) continue;
        if (found != null) return error.PackageInstallTargetRequired;
        found = item.id;
    }
    return allocator.dupe(u8, found orelse return error.PackageInstallTargetNotFound);
}

fn modelHasInstallSpec(allocator: Allocator, text: []const u8, model: []const u8, spec: manifest_pkg.InstallSpec) bool {
    const model_header = std.fmt.allocPrint(allocator, "  {s}:\n    model:\n", .{model}) catch return false;
    defer allocator.free(model_header);
    const model_pos = std.mem.indexOf(u8, text, model_header) orelse return false;
    const model_end = nextResourcePosition(text, model_pos + model_header.len) orelse text.len;
    const block = text[model_pos..model_end];
    for (spec.input) |ref| {
        const parsed = manifest_pkg.parseInstallRef(ref) catch return false;
        const item = std.fmt.allocPrint(allocator, "packages.{s}", .{parsed.id}) catch return false;
        defer allocator.free(item);
        if (std.mem.indexOf(u8, block, item) == null) return false;
    }
    for (spec.tools) |tool| if (std.mem.indexOf(u8, block, tool) == null) return false;
    return true;
}

pub fn ensureProjectLoopGraph(allocator: Allocator, layout_ctx: layout.Context) ![]u8 {
    const project = try allocator.dupe(u8, project_loop_graph_path);
    errdefer allocator.free(project);
    if (files.existsPath(project)) return project;
    const stock = try layout.sharePath(allocator, layout_ctx, "graphs/zinc-loop.circuitry.yaml");
    defer allocator.free(stock);
    const text = try files.readLimited(allocator, stock, 1024 * 1024);
    defer allocator.free(text);
    try files.write(project, text);
    return project;
}

pub fn packageLoopPath(allocator: Allocator, layout_ctx: layout.Context) ![]u8 {
    if (files.existsPath(project_loop_graph_path)) return allocator.dupe(u8, project_loop_graph_path);
    return layout.sharePath(allocator, layout_ctx, "graphs/zinc-loop.circuitry.yaml");
}

fn findAsset(assets: []const manifest_pkg.Asset, id: []const u8) ?manifest_pkg.Asset {
    for (assets) |asset| if (std.mem.eql(u8, asset.id, id)) return asset;
    return null;
}
