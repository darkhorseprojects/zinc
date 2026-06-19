const std = @import("std");
const Substrate = @import("../substrate.zig").Store;
const package = @import("../package.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub fn runRead(allocator: Allocator, store: *Substrate, target: []const u8) !void {
    const content = if (std.mem.startsWith(u8, target, "zinc://"))
        try readZinc(allocator, store, target)
    else
        try files.readLimited(allocator, target, 64 * 1024 * 1024);
    defer allocator.free(content);
    try files.writeAllOut(content);
}

fn readZinc(allocator: Allocator, store: *Substrate, uri: []const u8) ![]u8 {
    const body = uri["zinc://".len..];
    if (std.mem.eql(u8, body, "runs")) return store.readRuns();
    if (std.mem.startsWith(u8, body, "runs/")) return readRun(store, body["runs/".len..]);
    if (std.mem.startsWith(u8, body, "steps/")) return store.readStep(body["steps/".len..]);
    if (std.mem.startsWith(u8, body, "packets/")) return store.readPacket(body["packets/".len..]);
    if (std.mem.eql(u8, body, "packages") or std.mem.eql(u8, body, "package")) return packageList(allocator, store);
    if (std.mem.startsWith(u8, body, "packages/")) return readPackage(allocator, store, body["packages/".len..]);
    if (std.mem.startsWith(u8, body, "package/")) return readPackage(allocator, store, body["package/".len..]);
    return error.UnknownZincUri;
}

fn readRun(store: *Substrate, tail: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, tail, "/current")) return store.readRunCurrent(tail[0 .. tail.len - "/current".len]);
    if (std.mem.endsWith(u8, tail, "/steps")) return store.readRunSteps(tail[0 .. tail.len - "/steps".len]);
    return store.readRun(tail);
}

fn readPackage(allocator: Allocator, store: *Substrate, tail: []const u8) ![]u8 {
    const slash = std.mem.indexOfScalar(u8, tail, '/');
    const alias = if (slash) |i| tail[0..i] else tail;
    const query = if (slash) |i| tail[i + 1 ..] else "manifest";
    return try package.read(allocator, store, alias, query);
}

fn packageList(allocator: Allocator, store: *Substrate) ![]u8 {
    const rows = try store.listPackages();
    defer {
        for (rows) |row| store.freePackage(row);
        allocator.free(rows);
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "packages:\n");
    for (rows) |row| {
        try out.print(allocator, "  {s}:\n", .{row.package});
        try out.print(allocator, "    version: {s}\n", .{row.version});
        try out.print(allocator, "    root: {s}\n", .{row.root});
        try out.print(allocator, "    uri: {s}\n", .{row.uri});
    }
    return out.toOwnedSlice(allocator);
}
