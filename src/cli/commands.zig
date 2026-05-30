const std = @import("std");
const root = @import("../root.zig");
const sys = root.sys;
const core = root.core;
const runtime = @import("../runtime/engine.zig");
const config = @import("../runtime/config.zig");

const Allocator = std.mem.Allocator;

pub fn usage() void {
    std.debug.print(
        \\zn - Zinc, a tiny Circuitry-native runtime
        \\
        \\usage:
        \\  zn "prompt"              Run with default graph
        \\  zn run [graph] [--entry id] [--input name=value] "prompt"
        \\  zn check [graph]         Validate a graph
        \\  zn graph list            List available graphs
        \\  zn pkg add <source>      Install a package
        \\  zn pkg list              List installed packages
        \\  zn pkg remove <name>     Remove a package
        \\  zn serve [model]         Start model server
        \\  zn stop                  Stop model server
        \\  zn status                Check server status
        \\  zn session-dir           Print session directory path
        \\
    , .{});
}

pub fn validate(allocator: Allocator, io: std.Io, home: []const u8, path_arg: ?[]const u8) !void {
    const path = if (path_arg) |spec| try core.packages.resolveGraph(allocator, io, home, spec) else try allocator.dupe(u8, "stock/graphs/zinc-loop.circuitry.yaml");
    defer allocator.free(path);
    try validateGraphFile(allocator, io, path);
    std.debug.print("ok: {s}\n", .{path});
}

pub fn runPrompt(allocator: Allocator, io: std.Io, home: []const u8, graph_path: ?[]const u8, entry: ?[]const u8) !void {
    const path = if (graph_path) |spec| try core.packages.resolveGraph(allocator, io, home, spec) else try allocator.dupe(u8, "stock/graphs/zinc-loop.circuitry.yaml");
    defer allocator.free(path);

    try runtime.runGraph(allocator, io, home, path, entry);
}

pub fn graphList(allocator: Allocator, io: std.Io, home: []const u8) !void {
    const text = try core.packages.listGraphs(allocator, io, home);
    defer allocator.free(text);
    if (text.len == 0) std.debug.print("no graphs found\n", .{}) else std.debug.print("{s}", .{text});
}

pub fn packageList(allocator: Allocator, io: std.Io, home: []const u8) !void {
    const text = try core.packages.listPackages(allocator, io, home);
    defer allocator.free(text);
    if (text.len == 0) std.debug.print("no packages found\n", .{}) else std.debug.print("{s}", .{text});
}

pub fn validateGraphFile(allocator: Allocator, io: std.Io, path: []const u8) !void {
    const loaded_graph = try core.graph.load(allocator, io, path);
    defer loaded_graph.deinit(allocator);
    try core.graph.validate(loaded_graph);
}

pub fn packageAdd(allocator: Allocator, io: std.Io, home: []const u8, source: []const u8) !void {
    var package = try core.packages.add(allocator, io, home, source, .{ .scope = .local });
    defer package.deinit(allocator);
    std.debug.print("added local: {s}\n", .{package.path});
}

pub fn packageRemove(allocator: Allocator, io: std.Io, home: []const u8, name: []const u8, scope: ?core.packages.Scope) !void {
    var package = try core.packages.remove(allocator, io, home, name, scope);
    defer package.deinit(allocator);
    std.debug.print("removed {s}: {s}\n", .{ if (package.scope == .local) "local" else "global", package.name });
}

pub fn printSessionDir(_: Allocator) !void {
    std.debug.print(".zinc/sessions\n", .{});
}
