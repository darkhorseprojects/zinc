const std = @import("std");
const Substrate = @import("../substrate.zig").Store;
const package = @import("../package.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub fn runInspect(allocator: Allocator, store: *Substrate, target: []const u8) !void {
    if (std.mem.startsWith(u8, target, "zinc://packages/")) return inspectPackage(allocator, store, target["zinc://packages/".len..]);
    if (std.mem.startsWith(u8, target, "zinc://package/")) return inspectPackage(allocator, store, target["zinc://package/".len..]);
    if (std.mem.eql(u8, target, "zinc://packages") or std.mem.eql(u8, target, "zinc://package")) return inspectPackages(allocator, store);
    if (std.mem.eql(u8, target, "zinc://fragments")) return inspectFragments(allocator, store);
    if (std.mem.eql(u8, target, "zinc://heads")) return inspectHeads(allocator, store);
    if (std.mem.eql(u8, target, "zinc://config")) return inspectConfig(allocator, store);
    try files.writeAllOut("file: ");
    try files.writeAllOut(target);
    try files.writeAllOut("\n");
}

fn inspectPackage(allocator: Allocator, store: *Substrate, tail: []const u8) !void {
    const slash = std.mem.indexOfScalar(u8, tail, '/');
    const alias = if (slash) |i| tail[0..i] else tail;
    const query = if (slash) |i| tail[i + 1 ..] else "manifest";
    const pkg = (try store.getPackage(alias)) orelse return error.PackageNotInstalled;
    defer store.freePackage(pkg);
    try files.writeAllOut("package ");
    try files.writeAllOut(pkg.package);
    try files.writeAllOut("\n  version: ");
    try files.writeAllOut(pkg.version);
    try files.writeAllOut("\n  root: ");
    try files.writeAllOut(pkg.root);
    if (pkg.source_uri) |uri| {
        try files.writeAllOut("\n  source:");
        try files.writeAllOut(uri);
        if (pkg.source_ref) |ref| {
            try files.writeAllOut("@");
            try files.writeAllOut(ref);
        }
    }
    try files.writeAllOut("\n");
    var manifest = package.Manifest.open(allocator, pkg.root) catch null;
    defer if (manifest) |*m| m.deinit();
    if (!std.mem.eql(u8, query, "manifest")) {
        if (std.mem.startsWith(u8, query, "files/")) {
            try files.writeAllOut("  file: ");
            try files.writeAllOut(query["files/".len..]);
            try files.writeAllOut("\n");
        } else if (std.mem.startsWith(u8, query, "manifest/")) {
            const manifest_bytes = try package.read(allocator, store, alias, query);
            defer allocator.free(manifest_bytes);
            try files.writeAllOut(manifest_bytes);
            try files.writeAllOut("\n");
        } else {
            const path = try package.resolve(allocator, store, alias, query);
            defer allocator.free(path);
            try files.writeAllOut("  path: ");
            try files.writeAllOut(path);
            try files.writeAllOut("\n");
        }
    }
}

fn inspectPackages(allocator: Allocator, store: *Substrate) !void {
    const rows = try store.listPackages();
    defer {
        for (rows) |row| store.freePackage(row);
        allocator.free(rows);
    }
    for (rows) |row| try line3(row.package, row.version, row.root);
}

fn inspectFragments(allocator: Allocator, store: *Substrate) !void {
    const rows = try store.listFragments();
    defer {
        for (rows) |row| store.freeFragment(row);
        allocator.free(rows);
    }
    for (rows) |row| try line3(row.fragment, row.target, row.request);
}

fn inspectHeads(allocator: Allocator, store: *Substrate) !void {
    const rows = try store.listHeads();
    defer {
        for (rows) |row| store.freeHead(row);
        allocator.free(rows);
    }
    for (rows) |row| try line2(row.head, row.fragment);
}

fn inspectConfig(allocator: Allocator, store: *Substrate) !void {
    const rows = try store.listConfig();
    defer {
        for (rows) |row| store.freeConfig(row);
        allocator.free(rows);
    }
    for (rows) |row| try line2(row.key, row.value);
}

fn line2(a: []const u8, b: []const u8) !void {
    try files.writeAllOut(a);
    if (b.len > 0) {
        try files.writeAllOut(" ");
        try files.writeAllOut(b);
    }
    try files.writeAllOut("\n");
}

fn line3(a: []const u8, b: []const u8, c: []const u8) !void {
    try files.writeAllOut(a);
    if (b.len > 0) {
        try files.writeAllOut(" ");
        try files.writeAllOut(b);
    }
    if (c.len > 0) {
        try files.writeAllOut(" ");
        try files.writeAllOut(c);
    }
    try files.writeAllOut("\n");
}
