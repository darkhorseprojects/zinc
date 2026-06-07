const std = @import("std");
const runtime = @import("../runtime/mod.zig");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const packages = @import("../pkg/mod.zig");
const cmd = @import("mod.zig");

const Allocator = std.mem.Allocator;

pub fn printDbPath(allocator: Allocator, layout_ctx: layout.Context) !void {
    const path = try runtime.scope.dbPath(allocator, layout_ctx, runtime.scope.default());
    defer allocator.free(path);
    try files.writeAllOut(path);
    try files.writeAllOut("\n");
}

fn runtimeDbPathReady(allocator: Allocator, layout_ctx: layout.Context) ![]u8 {
    return runtime.navigation.dbPathReady(allocator, layout_ctx);
}

pub fn dbTables(allocator: Allocator, layout_ctx: layout.Context) !void {
    const path = try runtimeDbPathReady(allocator, layout_ctx);
    defer allocator.free(path);
    const text = try runtime.inspect.tables(allocator, path);
    defer allocator.free(text);
    try files.writeAllOut(text);
}

pub fn dbSchema(allocator: Allocator, layout_ctx: layout.Context) !void {
    const path = try runtimeDbPathReady(allocator, layout_ctx);
    defer allocator.free(path);
    const text = try runtime.inspect.schema(allocator, path);
    defer allocator.free(text);
    try files.writeAllOut(text);
}

pub fn dbQuery(allocator: Allocator, layout_ctx: layout.Context, sql: []const u8) !void {
    const path = try runtimeDbPathReady(allocator, layout_ctx);
    defer allocator.free(path);
    const text = try runtime.inspect.query(allocator, path, sql);
    defer allocator.free(text);
    try files.writeAllOut(text);
}

pub fn sessionList(allocator: Allocator, layout_ctx: layout.Context) !void {
    try writeRuntimeText(allocator, try runtime.navigation.sessionList(allocator, layout_ctx));
}

pub fn sessionShow(allocator: Allocator, layout_ctx: layout.Context, id: []const u8) !void {
    try writeRuntimeText(allocator, try runtime.navigation.sessionShow(allocator, layout_ctx, id));
}

pub fn sessionEvents(allocator: Allocator, layout_ctx: layout.Context, id: []const u8) !void {
    try writeRuntimeText(allocator, try runtime.navigation.sessionEvents(allocator, layout_ctx, id));
}

pub fn sessionTree(allocator: Allocator, layout_ctx: layout.Context, id: ?[]const u8) !void {
    try writeRuntimeText(allocator, try runtime.navigation.sessionTree(allocator, layout_ctx, id));
}

pub fn sessionBranch(allocator: Allocator, layout_ctx: layout.Context, at: []const u8, name: []const u8) !void {
    try validateRuntimeToken(at);
    try validateRuntimeToken(name);
    var store = try runtime.Store.open(allocator, layout_ctx, runtime.scope.default());
    defer store.close();
    const event_id = try store.createBranch(at, name);
    allocator.free(event_id);
    std.debug.print("created branch {s} at {s}\n", .{ name, at });
}

pub fn sessionCheckout(allocator: Allocator, layout_ctx: layout.Context, name: []const u8) !void {
    try validateRuntimeToken(name);
    var store = try runtime.Store.open(allocator, layout_ctx, runtime.scope.default());
    defer store.close();
    const session_id = try store.lastSessionId(allocator) orelse return error.SessionNotFound;
    defer allocator.free(session_id);
    const event_id = try store.checkoutBranch(session_id, name);
    allocator.free(event_id);
    std.debug.print("checked out branch {s}\n", .{name});
}

fn writeRuntimeText(allocator: Allocator, text: []u8) !void {
    defer allocator.free(text);
    try files.writeAllOut(text);
}

fn validateRuntimeToken(value: []const u8) !void {
    return runtime.navigation.validateToken(value);
}

pub fn eventFromArgs(allocator: Allocator, layout_ctx: layout.Context, args: []const []const u8) !void {
    if (args.len == 0) return cmd.usage();
    const sub = args[0];
    if (std.mem.eql(u8, sub, "tail")) return writeRuntimeText(allocator, try runtime.navigation.eventTail(allocator, layout_ctx));
    if (args.len != 2) return cmd.usage();
    const id = args[1];
    if (std.mem.eql(u8, sub, "show")) return writeRuntimeText(allocator, try runtime.navigation.eventShow(allocator, layout_ctx, id));
    if (std.mem.eql(u8, sub, "payload")) return writeRuntimeText(allocator, try runtime.navigation.eventPayload(allocator, layout_ctx, id));
    if (std.mem.eql(u8, sub, "logs")) return writeRuntimeText(allocator, try runtime.navigation.eventLogs(allocator, layout_ctx, id));
    return cmd.usage();
}

pub fn logsFromArgs(allocator: Allocator, layout_ctx: layout.Context, args: []const []const u8) !void {
    if (args.len == 0) return cmd.usage();
    const sub = args[0];
    if (std.mem.eql(u8, sub, "tail") or std.mem.eql(u8, sub, "current")) return writeRuntimeText(allocator, try runtime.navigation.logsCurrent(allocator, layout_ctx));
    if (args.len != 2) return cmd.usage();
    if (std.mem.eql(u8, sub, "for-event")) return writeRuntimeText(allocator, try runtime.navigation.logsForEvent(allocator, layout_ctx, args[1]));
    if (std.mem.eql(u8, sub, "for-run")) return writeRuntimeText(allocator, try runtime.navigation.logsForRun(allocator, layout_ctx, args[1]));
    return cmd.usage();
}

pub fn clean(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, scope: packages.Scope, target_str: []const u8, yes: bool) !void {
    const Target = enum { runtime, packages, generated, config, all };
    const target = std.meta.stringToEnum(Target, target_str) orelse return error.InvalidCleanTarget;
    std.debug.print("Clean Zinc data\n\nscope: {s}\ntarget: {s}\n", .{ @tagName(scope), @tagName(target) });
    if (!yes) try cmd.confirmOrFail("Continue?");
    var dir = std.Io.Dir.cwd();
    switch (scope) {
        .local => {
            if (target == .packages or target == .all) dir.deleteTree(io, ".zinc/packages") catch |err| if (err != error.FileNotFound) return err;
            if (target == .generated or target == .all) dir.deleteTree(io, ".zinc/generated") catch |err| if (err != error.FileNotFound) return err;
            if (target == .config or target == .all) dir.deleteTree(io, ".zinc/config") catch |err| if (err != error.FileNotFound) return err;
            if (target == .runtime or target == .all) {
                dir.deleteTree(io, ".zinc/state") catch |err| if (err != error.FileNotFound) return err;
                dir.deleteTree(io, ".zinc/runtime") catch |err| if (err != error.FileNotFound) return err;
            }
        },
        .global => {
            if (target == .packages or target == .all) {
                const global_pkgs = try layout.sharePath(allocator, layout_ctx, "packages");
                defer allocator.free(global_pkgs);
                dir.deleteTree(io, global_pkgs) catch |err| if (err != error.FileNotFound) return err;
            }
            if (target == .runtime or target == .all) {
                const global_state = try layout.sharePath(allocator, layout_ctx, "state");
                defer allocator.free(global_state);
                dir.deleteTree(io, global_state) catch |err| if (err != error.FileNotFound) return err;

                const global_runtime = try layout.sharePath(allocator, layout_ctx, "runtime");
                defer allocator.free(global_runtime);
                dir.deleteTree(io, global_runtime) catch |err| if (err != error.FileNotFound) return err;
            }
        },
    }
    std.debug.print("cleaned {s} {s}\n", .{ @tagName(scope), @tagName(target) });
}
