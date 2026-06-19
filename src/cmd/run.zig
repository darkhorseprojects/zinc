const std = @import("std");
const Substrate = @import("../substrate.zig").Store;
const execute = @import("../execute.zig");
const config = @import("config.zig");
const package = @import("../package.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub fn run(allocator: Allocator, io: std.Io, store: *Substrate, settings: *const config.ConfigSettings, shape_source: []const u8, args: []const []const u8, report: bool) !void {
    const shape_bytes = try readShapeSource(allocator, store, shape_source);
    defer allocator.free(shape_bytes);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const shape = try execute.parseShape(arena.allocator(), shape_bytes);
    if (report) {
        writeReport(allocator, io, store, settings, shape, args) catch |err| {
            try writeErrorReport(allocator, err);
            return err;
        };
    } else {
        const result = try execute.runShape(allocator, io, store, settings, shape, args);
        defer result.deinit();
        try execute.writeResult(result);
    }
}

fn readShapeSource(allocator: Allocator, store: *Substrate, source: []const u8) ![]const u8 {
    const bytes = if (std.mem.eql(u8, source, "-"))
        try files.readAllStdin(allocator, 10 * 1024 * 1024)
    else if (std.mem.startsWith(u8, source, "zinc://"))
        try readZinc(allocator, store, source)
    else
        try files.readLimited(allocator, source, 10 * 1024 * 1024);

    if (isMarkdown(source)) {
        defer allocator.free(bytes);
        return try execute.markdownFrontMatter(allocator, bytes);
    }
    return bytes;
}

fn readZinc(allocator: Allocator, store: *Substrate, uri: []const u8) ![]u8 {
    const body = uri["zinc://".len..];
    if (std.mem.startsWith(u8, body, "packages/")) return readPackage(allocator, store, body["packages/".len..]);
    if (std.mem.startsWith(u8, body, "package/")) return readPackage(allocator, store, body["package/".len..]);
    return error.UnknownZincUri;
}

fn readPackage(allocator: Allocator, store: *Substrate, tail: []const u8) ![]u8 {
    const slash = std.mem.indexOfScalar(u8, tail, '/');
    const alias = if (slash) |i| tail[0..i] else tail;
    const query = if (slash) |i| tail[i + 1 ..] else "manifest";
    return try package.read(allocator, store, alias, query);
}

fn isMarkdown(source: []const u8) bool {
    const ext = std.fs.path.extension(source);
    return std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".markdown");
}

fn writeReport(allocator: Allocator, io: std.Io, store: *Substrate, settings: *const config.ConfigSettings, shape: anytype, args: []const []const u8) !void {
    const result = try execute.runShape(allocator, io, store, settings, shape, args);
    defer result.deinit();
    try files.writeAllOut("ok: true\noutput:\n");
    try writeIndented(result.output, 2);
    try files.writeAllOut(result.events);
}

fn writeErrorReport(allocator: Allocator, err: anyerror) !void {
    _ = allocator;
    try files.writeAllOut("ok: false\nerror: ");
    try files.writeAllOut(@errorName(err));
    try files.writeAllOut("\nstderr: \"\"\nevents: []\n");
}

fn writeIndented(bytes: []const u8, indent: usize) !void {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        var i: usize = 0;
        while (i < indent) : (i += 1) try files.writeAllOut(" ");
        try files.writeAllOut(line);
        try files.writeAllOut("\n");
    }
}
