const std = @import("std");
const commands = @import("commands.zig");
const config = @import("../config/mod.zig");
const doctor = @import("../doctor.zig");
const packages = @import("../packages/mod.zig");
const layout = @import("../io/layout.zig");
const Scope = packages.Scope;

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

    const cmd = args.next() orelse return commands.usage();
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return commands.usage();
    if (std.mem.eql(u8, cmd, "check")) return commands.validate(allocator, init.io, layout_ctx, args.next());
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
    return commands.runFromArgs(allocator, init.io, layout_ctx, parts.items);
}

fn runCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    return commands.runFromArgs(allocator, io, layout_ctx, parts);
}

fn configCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const sub = args.next() orelse return commands.usage();
    if (!std.mem.eql(u8, sub, "get")) return commands.usage();
    const path = args.next() orelse return error.MissingConfigPath;
    return commands.configGet(allocator, io, layout_ctx, path);
}

fn graphCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const sub = args.next() orelse return commands.usage();
    if (std.mem.eql(u8, sub, "list")) return commands.graphList(allocator, io, layout_ctx);
    if (std.mem.eql(u8, sub, "show")) return commands.graphShow(allocator, io, layout_ctx, args.next() orelse return error.MissingGraphPath);
    return commands.usage();
}

fn packageCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const sub = args.next() orelse return commands.usage();
    if (std.mem.eql(u8, sub, "list")) return commands.packageList(allocator, io, layout_ctx);
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    if (std.mem.eql(u8, sub, "add")) return commands.packageAdd(allocator, io, layout_ctx, parts);
    if (std.mem.eql(u8, sub, "remove")) return commands.packageRemove(allocator, io, layout_ctx, parts);
    if (std.mem.eql(u8, sub, "update")) return commands.packageUpdate(allocator, io, layout_ctx, parts);
    if (std.mem.eql(u8, sub, "show")) return commands.packageShow(allocator, io, layout_ctx, parts);
    if (std.mem.eql(u8, sub, "exec")) return commands.packageExec(allocator, io, layout_ctx, parts);
    if (std.mem.eql(u8, sub, "call")) return commands.packageCall(allocator, io, layout_ctx, parts);
    return commands.usage();
}

fn compactCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    return commands.compactFromArgs(allocator, io, layout_ctx, parts);
}

fn updateCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    return commands.updateFromArgs(allocator, io, layout_ctx, parts);
}

fn dbCommandArgs(allocator: std.mem.Allocator, io: std.Io, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    _ = io;
    const sub = args.next() orelse return commands.usage();
    if (std.mem.eql(u8, sub, "path")) return commands.printDbPath(allocator, layout_ctx);
    if (std.mem.eql(u8, sub, "tables")) return commands.dbTables(allocator, layout_ctx);
    if (std.mem.eql(u8, sub, "schema")) return commands.dbSchema(allocator, layout_ctx);
    if (std.mem.eql(u8, sub, "query")) return commands.dbQuery(allocator, layout_ctx, args.next() orelse return error.MissingSql);
    return commands.usage();
}

fn sessionCommandArgs(allocator: std.mem.Allocator, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const sub = args.next() orelse return commands.usage();
    if (std.mem.eql(u8, sub, "list")) return commands.sessionList(allocator, layout_ctx);
    if (std.mem.eql(u8, sub, "tree")) return commands.sessionTree(allocator, layout_ctx);
    if (std.mem.eql(u8, sub, "checkout")) return commands.sessionCheckout(allocator, layout_ctx, args.next() orelse return error.MissingBranchName);
    if (std.mem.eql(u8, sub, "branch")) {
        var at: ?[]const u8 = null;
        var name: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--at")) at = args.next() orelse return error.MissingEventId else if (std.mem.eql(u8, arg, "--name")) name = args.next() orelse return error.MissingBranchName else return error.InvalidSessionBranchArgument;
        }
        return commands.sessionBranch(allocator, layout_ctx, at orelse return error.MissingEventId, name orelse return error.MissingBranchName);
    }
    return commands.usage();
}

fn eventCommandArgs(allocator: std.mem.Allocator, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const sub = args.next() orelse return commands.usage();
    if (std.mem.eql(u8, sub, "tail")) return commands.eventTail(allocator, layout_ctx);
    return commands.usage();
}

fn logsCommandArgs(allocator: std.mem.Allocator, layout_ctx: layout.Context, args: *std.process.Args.Iterator) !void {
    const sub = args.next() orelse return commands.usage();
    if (std.mem.eql(u8, sub, "tail")) return commands.logsTail(allocator, layout_ctx);
    return commands.usage();
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

    return commands.clean(allocator, io, layout_ctx, scope orelse .local, target orelse "all", yes);
}

fn collectArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) ![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);
    while (args.next()) |part| try parts.append(allocator, part);
    return parts.toOwnedSlice(allocator);
}
