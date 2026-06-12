const std = @import("std");
const Store = @import("../runtime/store.zig").Store;
const files = @import("../io/fs.zig");
const index = @import("index.zig");
const manifest = @import("manifest.zig");

const Allocator = std.mem.Allocator;

pub fn reportSoftDependencies(allocator: Allocator, store: *Store, parsed: manifest.PackageManifest) !void {
    const deps = try parsed.softDependencies(allocator);
    defer manifest.freeSoftDependencies(allocator, deps);
    if (deps.len == 0) return;

    try files.writeAllOut("\nSoft dependencies:\n");
    for (deps) |dep| {
        const name = index.packageNameFromSpec(dep.package);
        const installed = try store.getPackage(name);
        if (installed) |pkg| {
            defer store.freePackage(pkg);
            try files.writeAllOut("  - ");
            try files.writeAllOut(dep.alias);
            try files.writeAllOut(": ");
            try files.writeAllOut(dep.package);
            try files.writeAllOut(" [installed]\n");
        } else {
            try files.writeAllOut("  - ");
            try files.writeAllOut(dep.alias);
            try files.writeAllOut(": ");
            try files.writeAllOut(dep.package);
            try files.writeAllOut(" [missing]\n");
        }
        if (dep.about.len > 0) {
            try files.writeAllOut("    ");
            try files.writeAllOut(dep.about);
            try files.writeAllOut("\n");
        }
    }
    try files.writeAllOut("These are not installed automatically. References to missing soft dependencies fail only when used.\n");
}
