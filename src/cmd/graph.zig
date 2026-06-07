const std = @import("std");
const config = @import("../config/mod.zig");
const graph = @import("../graph/mod.zig");
const packages = @import("../pkg/mod.zig");
const cmd = @import("mod.zig");

const Allocator = std.mem.Allocator;

pub fn validate(allocator: Allocator, io: std.Io, layout_ctx: @import("../io/layout.zig").Context, path_arg: ?[]const u8) !void {
    const runtime_paths = try config.loadRuntimePaths(allocator, io, layout_ctx);
    defer runtime_paths.deinit(allocator);
    const path = if (path_arg) |spec| packages.resolveGraph(allocator, io, layout_ctx, spec) catch |err| switch (err) {
        error.GraphNotFound => return cmd.fail("graph not found: {s}", .{spec}),
        else => return err,
    } else try allocator.dupe(u8, runtime_paths.graph);
    defer allocator.free(path);
    try cmd.validateGraphFile(allocator, io, path);
    std.debug.print("ok: {s}\n", .{path});
}

pub fn graphList(allocator: Allocator, io: std.Io, layout_ctx: @import("../io/layout.zig").Context) !void {
    const text = try packages.listGraphs(allocator, io, layout_ctx);
    defer allocator.free(text);
    if (text.len == 0) std.debug.print("no graphs found\n", .{}) else std.debug.print("{s}", .{text});
}

pub fn graphShow(allocator: Allocator, io: std.Io, layout_ctx: @import("../io/layout.zig").Context, spec: []const u8) !void {
    const path = packages.resolveGraph(allocator, io, layout_ctx, spec) catch |err| switch (err) {
        error.GraphNotFound => return cmd.fail("graph not found: {s}", .{spec}),
        else => return err,
    };
    defer allocator.free(path);
    const loaded_graph = try graph.load(allocator, io, path);
    defer loaded_graph.deinit(allocator);
    try cmd.printGraph(allocator, spec, path, loaded_graph);
}
