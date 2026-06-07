const std = @import("std");
const cmd_pkg = @import("cmd/mod.zig");
const config = @import("config/mod.zig");
const doctor = @import("doctor.zig");
const packages = @import("pkg/mod.zig");
const Scope = packages.Scope;
const layout = @import("io/layout.zig");

pub fn run(init: std.process.Init) !void {
    runInner(init) catch |err| switch (err) {
        error.UserError => return,
        error.ModelNotConfigured => {
            std.debug.print("error: model endpoint not configured; add default_model and models.<id> to your Zinc config\n", .{});
            return;
        },
        error.UnknownModel => {
            std.debug.print("error: unknown model id; add it under models in your Zinc config\n", .{});
            return;
        },
        else => return err,
    };
}

fn runInner(init: std.process.Init) !void {
    const allocator = init.gpa;
    config.setEnvironmentMap(init.environ_map);
    const layout_ctx = try layout.Context.fromProcess(allocator, init.environ_map);
    defer layout_ctx.deinit(allocator);

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    const cmd = args.next() orelse return cmd_pkg.usage();
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return cmd_pkg.usage();
    if (std.mem.eql(u8, cmd, "check")) return cmd_pkg.graph.validate(allocator, init.io, layout_ctx, args.next());
    if (std.mem.eql(u8, cmd, "clean")) return cleanCommandArgs(allocator, init.io, layout_ctx, &args);
    if (std.mem.eql(u8, cmd, "run")) return runCommandArgs(allocator, init.io, layout_ctx, &args);
    if (std.mem.eql(u8, cmd, "doctor")) return doctor.run(allocator, init.io, layout_ctx);
    if (std.mem.eql(u8, cmd, "config")) return configCommandArgs(allocator, init.io, layout_ctx, &args);
    if (std.mem.eql(u8, cmd, "graph")) return graphCommandArgs(allocator, init.io, layout_ctx, &args);
    if (std.mem.eql(u8, cmd, "pkg")) return packageCommandArgs(allocator, init.io, layout_ctx, &args);
    if (std.mem.eql(u8, cmd, "compact")) return compactCommandArgs(allocator, init.io, layout_ctx, &args);
    if (std.mem.eql(u8, cmd, "update")) return updateCommandArgs(allocator, init.io, layout_ctx, &args);
    if (std.mem.eql(u8, cmd, "db")) return dbCommandArgs(allocator, init.io, layout_ctx, &args);
    if (std.mem.eql(u8, cmd, "session")) return sessionCommandArgs(allocator, layout_ctx, &args);
    if (std.mem.eql(u8, cmd, "event")) return eventCommandArgs(allocator, layout_ctx, &args);
    if (std.mem.eql(u8, cmd, "logs")) return logsCommandArgs(allocator, layout_ctx, &args);

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, cmd);
    while (args.next()) |part| try parts.append(allocator, part);
    return cmd_pkg.run.runFromArgs(allocator, init.io, layout_ctx, parts.items);
}

fn runCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    return cmd_pkg.run.runFromArgs(allocator, io, layout_ctx, parts);
}

fn configCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const sub = args.next() orelse return cmd_pkg.usage();
    if (!std.mem.eql(u8, sub, "get")) return cmd_pkg.usage();
    const path = args.next() orelse return error.MissingConfigPath;
    return cmd_pkg.config.configGet(allocator, io, layout_ctx, path);
}

fn graphCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const sub = args.next() orelse return cmd_pkg.usage();
    if (std.mem.eql(u8, sub, "list")) return cmd_pkg.graph.graphList(allocator, io, layout_ctx);
    if (std.mem.eql(u8, sub, "show")) return cmd_pkg.graph.graphShow(allocator, io, layout_ctx, args.next() orelse return error.MissingGraphPath);
    return cmd_pkg.usage();
}

fn packageCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const sub = args.next() orelse return cmd_pkg.usage();
    if (std.mem.eql(u8, sub, "list")) return cmd_pkg.pkg.packageList(allocator, io, layout_ctx);
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    if (std.mem.eql(u8, sub, "add")) return cmd_pkg.pkg.packageAdd(allocator, io, layout_ctx, parts);
    if (std.mem.eql(u8, sub, "remove")) return cmd_pkg.pkg.packageRemove(allocator, io, layout_ctx, parts);
    if (std.mem.eql(u8, sub, "update")) return cmd_pkg.pkg.packageUpdate(allocator, io, layout_ctx, parts);
    if (std.mem.eql(u8, sub, "show")) return cmd_pkg.pkg.packageShow(allocator, io, layout_ctx, parts);
    if (std.mem.eql(u8, sub, "exec")) return cmd_pkg.pkg.packageExec(allocator, io, layout_ctx, parts);
    if (std.mem.eql(u8, sub, "call")) return cmd_pkg.pkg.packageCall(allocator, io, layout_ctx, parts);
    return cmd_pkg.usage();
}

fn compactCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    return cmd_pkg.run.compactFromArgs(allocator, io, layout_ctx, parts);
}

fn updateCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    return cmd_pkg.run.updateFromArgs(allocator, io, layout_ctx, parts);
}

fn dbCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    _ = io;
    const sub = args.next() orelse return cmd_pkg.usage();
    if (std.mem.eql(u8, sub, "path")) return cmd_pkg.runtime.printDbPath(allocator, layout_ctx);
    if (std.mem.eql(u8, sub, "tables")) return cmd_pkg.runtime.dbTables(allocator, layout_ctx);
    if (std.mem.eql(u8, sub, "schema")) return cmd_pkg.runtime.dbSchema(allocator, layout_ctx);
    if (std.mem.eql(u8, sub, "query")) return cmd_pkg.runtime.dbQuery(allocator, layout_ctx, args.next() orelse return error.MissingSql);
    return cmd_pkg.usage();
}

fn sessionCommandArgs(allocator: std.mem.Allocator, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const sub = args.next() orelse return cmd_pkg.usage();
    if (std.mem.eql(u8, sub, "list")) return cmd_pkg.runtime.sessionList(allocator, layout_ctx);
    if (std.mem.eql(u8, sub, "show")) return cmd_pkg.runtime.sessionShow(allocator, layout_ctx, args.next() orelse return error.MissingSessionId);
    if (std.mem.eql(u8, sub, "events")) return cmd_pkg.runtime.sessionEvents(allocator, layout_ctx, args.next() orelse return error.MissingSessionId);
    if (std.mem.eql(u8, sub, "tree")) return cmd_pkg.runtime.sessionTree(allocator, layout_ctx, args.next());
    if (std.mem.eql(u8, sub, "checkout")) return cmd_pkg.runtime.sessionCheckout(allocator, layout_ctx, args.next() orelse return error.MissingBranchName);
    if (std.mem.eql(u8, sub, "branch")) {
        var at: ?[]const u8 = null;
        var name: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--at")) at = args.next() orelse return error.MissingEventId else if (std.mem.eql(u8, arg, "--name")) name = args.next() orelse return error.MissingBranchName else return error.InvalidSessionBranchArgument;
        }
        return cmd_pkg.runtime.sessionBranch(allocator, layout_ctx, at orelse return error.MissingEventId, name orelse return error.MissingBranchName);
    }
    return cmd_pkg.usage();
}

fn eventCommandArgs(allocator: std.mem.Allocator, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    return cmd_pkg.runtime.eventFromArgs(allocator, layout_ctx, parts);
}

fn logsCommandArgs(allocator: std.mem.Allocator, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    return cmd_pkg.runtime.logsFromArgs(allocator, layout_ctx, parts);
}

fn cleanCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    var scope: ?Scope = null;
    var target: ?[]const u8 = null;
    var yes = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--local")) {
            if (scope != null) return error.ConflictingScopeFlags;
            scope = .local;
        } else if (std.mem.eql(u8, arg, "--global")) {
            if (scope != null) return error.ConflictingScopeFlags;
            scope = .global;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            yes = true;
        } else {
            if (target != null) return error.TooManyArguments;
            target = arg;
        }
    }

    return cmd_pkg.runtime.clean(allocator, io, layout_ctx, scope orelse .local, target orelse "all", yes);
}

fn collectArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) ![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);
    while (args.next()) |part| try parts.append(allocator, part);
    return parts.toOwnedSlice(allocator);
}
