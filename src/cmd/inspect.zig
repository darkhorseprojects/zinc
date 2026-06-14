const std = @import("std");
const Substrate = @import("../substrate.zig").Store;
const package = @import("../package.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub fn runInspect(allocator: Allocator, store: *Substrate, target: []const u8) !void {
    if (std.mem.startsWith(u8, target, "zinc://packages/")) return inspectPackage(allocator, store, target["zinc://packages/".len..]);
    if (std.mem.eql(u8, target, "zinc://packages")) return inspectPackages(allocator, store);
    if (std.mem.eql(u8, target, "zinc://fragments")) return inspectFragments(allocator, store);
    if (std.mem.eql(u8, target, "zinc://choices")) return inspectChoices(allocator, store);
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
    try files.writeAllOut("\n  root: ");
    try files.writeAllOut(pkg.root);
    try files.writeAllOut("\n");
    if (!std.mem.eql(u8, query, "manifest")) {
        const path = try package.resolve(allocator, store, alias, query);
        defer allocator.free(path);
        try files.writeAllOut("  path: ");
        try files.writeAllOut(path);
        try files.writeAllOut("\n");
    }
}

fn inspectPackages(allocator: Allocator, store: *Substrate) !void {
    const rows = try store.listPackages();
    defer {
        for (rows) |row| store.freePackage(row);
        allocator.free(rows);
    }
    for (rows) |row| try line2(row.package, row.root);
}

fn inspectFragments(allocator: Allocator, store: *Substrate) !void {
    const rows = try store.listFragments();
    defer {
        for (rows) |row| store.freeFragment(row);
        allocator.free(rows);
    }
    for (rows) |row| try line3(row.fragment, row.target, row.request);
}

fn inspectChoices(allocator: Allocator, store: *Substrate) !void {
    const rows = try store.listChoices();
    defer {
        for (rows) |row| store.freeChoice(row);
        allocator.free(rows);
    }
    for (rows) |row| try line2(row.choice, row.fragment);
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
