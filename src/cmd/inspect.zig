const std = @import("std");
const Store = @import("../runtime/store.zig").Store;
const uri = @import("../runtime/uri.zig");
const manifest = @import("../pkg/manifest.zig");
const pkg_deps = @import("../pkg/deps.zig");
const files = @import("../io/fs.zig");
const circuitry = @import("circuitry");

const Allocator = std.mem.Allocator;

pub fn runInspect(allocator: Allocator, store: *Store, arg: []const u8) !void {
    if (std.mem.startsWith(u8, arg, "zinc://")) return try inspectUri(allocator, store, arg);
    return try inspectFile(allocator, store, arg);
}

fn inspectUri(allocator: Allocator, store: *Store, arg: []const u8) !void {
    const parsed = try uri.parse(allocator, arg);
    defer parsed.deinit(allocator);
    switch (parsed.root) {
        .runs => try inspectRunUri(allocator, store, parsed.id, parsed.path),
        .docs => try inspectDocUri(store, parsed.id),
        .packages => try inspectPackageUri(allocator, store, parsed.id, parsed.path),
        .config => try files.writeAllErr("Config paths are not inspectable yet.\n"),
    }
}

fn inspectRunUri(allocator: Allocator, store: *Store, run_id: []const u8, path: []const u8) !void {
    if (path.len != 0) {
        const ref = try uriString(allocator, "runs", run_id, path);
        defer allocator.free(ref);
        const content = try uri.resolveRead(allocator, store, ref);
        defer allocator.free(content);
        try files.writeAllOut("Path: runs/");
        try files.writeAllOut(run_id);
        try files.writeAllOut("/");
        try files.writeAllOut(path);
        try files.writeAllOut("\n\n");
        try files.writeAllOut(content);
        if (!std.mem.endsWith(u8, content, "\n")) try files.writeAllOut("\n");
        return;
    }

    const run = (try store.getRun(run_id)) orelse {
        try files.writeAllErr("Run not found.\n");
        return;
    };
    defer store.freeRun(run);
    try files.writeAllOut("Run\n");
    try files.writeAllOut("  id: ");
    try files.writeAllOut(run.id);
    try files.writeAllOut("\n");
    try files.writeAllOut("  status: ");
    try files.writeAllOut(run.status orelse "unknown");
    try files.writeAllOut("\n");
    try files.writeAllOut("  doc: ");
    try files.writeAllOut(run.doc_id orelse "none");
    try files.writeAllOut("\n\n");

    const parts = try store.listRunParts(run.id);
    defer {
        for (parts) |part| store.freeRunPart(part);
        allocator.free(parts);
    }
    try files.writeAllOut("Parts\n");
    for (parts) |part| {
        try files.writeAllOut("  ");
        try files.writeAllOut(part.path);
        try files.writeAllOut("  ");
        try files.writeAllOut(part.status);
        try files.writeAllOut("\n");
    }

    const values = try store.listRunValues(run.id);
    defer {
        for (values) |val| store.freeRunValue(val);
        allocator.free(values);
    }
    try files.writeAllOut("\nValues\n");
    for (values) |val| {
        try files.writeAllOut("  ");
        try files.writeAllOut(val.path);
        try files.writeAllOut("  ");
        try files.writeAllOut(val.type_label orelse "value");
        if (val.origin) |origin| {
            try files.writeAllOut("  ");
            try files.writeAllOut(origin);
        }
        try files.writeAllOut("\n");
    }

    const texts = try store.listRunText(run.id);
    defer {
        for (texts) |text| store.freeRunText(text);
        allocator.free(texts);
    }
    try files.writeAllOut("\nText\n");
    for (texts) |text| {
        try files.writeAllOut("  ");
        try files.writeAllOut(text.path);
        try files.writeAllOut("  ");
        try files.writeAllOut(text.role);
        try files.writeAllOut("\n");
    }

    const actions = try store.listActions(run.id);
    defer {
        for (actions) |act| store.freeAction(act);
        allocator.free(actions);
    }
    try files.writeAllOut("\nActions\n");
    for (actions) |act| {
        try files.writeAllOut("  ");
        try files.writeAllOut(act.path);
        try files.writeAllOut("  ");
        try files.writeAllOut(act.status orelse "unknown");
        try files.writeAllOut("  ");
        try files.writeAllOut(act.action orelse "");
        try files.writeAllOut("\n");
    }
}

fn inspectDocUri(store: *Store, doc_id: []const u8) !void {
    const doc = (try store.getDoc(doc_id)) orelse {
        try files.writeAllErr("Document not found.\n");
        return;
    };
    defer store.freeDoc(doc);
    try files.writeAllOut("Doc\n  id: ");
    try files.writeAllOut(doc.id);
    try files.writeAllOut("\n  name: ");
    try files.writeAllOut(doc.name orelse "untitled");
    try files.writeAllOut("\n  path: ");
    try files.writeAllOut(doc.path orelse "unknown");
    try files.writeAllOut("\n");
}

fn inspectPackageUri(allocator: Allocator, store: *Store, name: []const u8, asset_path: []const u8) !void {
    if (asset_path.len != 0) {
        const ref = try uriString(allocator, "packages", name, asset_path);
        defer allocator.free(ref);
        const content = try uri.resolveRead(allocator, store, ref);
        defer allocator.free(content);
        try files.writeAllOut(content);
        if (!std.mem.endsWith(u8, content, "\n")) try files.writeAllOut("\n");
        return;
    }
    const pkg = (try store.getPackage(name)) orelse {
        try files.writeAllErr("Package not found.\n");
        return;
    };
    defer store.freePackage(pkg);
    try files.writeAllOut("Package\n  name: ");
    try files.writeAllOut(pkg.name);
    try files.writeAllOut("\n  version: ");
    try files.writeAllOut(pkg.version orelse "unknown");
    try files.writeAllOut("\n  path: ");
    try files.writeAllOut(pkg.path orelse "unknown");
    try files.writeAllOut("\n\nAssets\n");
    const assets = try store.listPackageAssets(name);
    defer {
        for (assets) |asset| store.freePackageAsset(asset);
        allocator.free(assets);
    }
    for (assets) |asset| {
        try files.writeAllOut("  ");
        try files.writeAllOut(asset.path);
        try files.writeAllOut(" -> ");
        try files.writeAllOut(asset.file_path);
        try files.writeAllOut("\n");
    }
}

fn inspectFile(allocator: Allocator, store: *Store, arg: []const u8) !void {
    const local_manifest_path = try localPackageManifestPath(allocator, arg);
    defer if (local_manifest_path) |path| allocator.free(path);
    if (local_manifest_path) |manifest_path_arg| {
        const bytes = try files.readLimited(allocator, manifest_path_arg, 10 * 1024 * 1024);
        defer allocator.free(bytes);
        var parsed = try manifest.parse(allocator, bytes);
        defer parsed.deinit();
        try files.writeAllOut("Package Manifest:\n  Name: ");
        try files.writeAllOut(parsed.name);
        try files.writeAllOut("\n  Version: ");
        try files.writeAllOut(parsed.version);
        try files.writeAllOut("\n  About: ");
        try files.writeAllOut(parsed.about);
        try files.writeAllOut("\n");
        try pkg_deps.reportSoftDependencies(allocator, store, parsed);
        return;
    }

    var shape = try circuitry.loadFile(std.Options.debug_io, allocator, arg);
    defer shape.deinit();
    var conf = try circuitry.confirm(allocator, &shape);
    defer conf.deinit();
    const card = conf.card;
    try files.writeAllOut("Shape Name: ");
    try files.writeAllOut(card.name);
    try files.writeAllOut("\nAbout: ");
    try files.writeAllOut(card.about orelse "none");
    try files.writeAllOut("\nTakes:\n");
    for (card.takes) |t| {
        try files.writeAllOut("  - ");
        try files.writeAllOut(t);
        try files.writeAllOut("\n");
    }
    try files.writeAllOut("Uses:\n");
    for (card.uses) |u| {
        try files.writeAllOut("  - ");
        try files.writeAllOut(u);
        try files.writeAllOut("\n");
    }
    try files.writeAllOut("Does:\n");
    for (card.does) |d| {
        try files.writeAllOut("  - ");
        try files.writeAllOut(d);
        try files.writeAllOut("\n");
    }
    try files.writeAllOut("Gives:\n");
    for (card.gives) |g| {
        try files.writeAllOut("  - ");
        try files.writeAllOut(g);
        try files.writeAllOut("\n");
    }
}

fn uriString(allocator: Allocator, root: []const u8, id: []const u8, path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "zinc://{s}/{s}/{s}", .{ root, id, path });
}

fn localPackageManifestPath(allocator: Allocator, arg: []const u8) !?[]const u8 {
    if (std.mem.endsWith(u8, arg, "zinc.pkg.yaml")) return try allocator.dupe(u8, arg);
    const candidate = try std.fs.path.join(allocator, &.{ arg, "zinc.pkg.yaml" });
    if (files.existsPath(candidate)) return candidate;
    allocator.free(candidate);
    return null;
}
