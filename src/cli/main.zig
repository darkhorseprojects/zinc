const std = @import("std");
const commands = @import("commands.zig");
const server = @import("../server.zig");
const root = @import("../root.zig");
const Scope = root.core.packages.Scope;
const platform = root.platform;

pub fn run(init: std.process.Init) !void {
    runInner(init) catch |err| switch (err) {
        error.UserError => return,
        else => return err,
    };
}

fn runInner(init: std.process.Init) !void {
    const allocator = init.gpa;
    const platform_dirs = try platform.dirs.fromProcess(allocator, init.environ_map);
    defer platform_dirs.deinit(allocator);
    const home = platform_dirs.home;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    const cmd = args.next() orelse return commands.usage();
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return commands.usage();
    if (std.mem.eql(u8, cmd, "check")) return commands.validate(allocator, init.io, home, args.next());
    if (std.mem.eql(u8, cmd, "clean")) return cleanCommandArgs(allocator, init.io, home, &args);
    if (std.mem.eql(u8, cmd, "run")) return runCommandArgs(allocator, init.io, home, &args);
    if (std.mem.eql(u8, cmd, "serve")) return server.start(allocator, init.io, home, args.next());
    if (std.mem.eql(u8, cmd, "stop")) return server.stop(allocator, init.io, home);
    if (std.mem.eql(u8, cmd, "doctor")) return server.doctor(allocator, init.io, home);
    if (std.mem.eql(u8, cmd, "config")) return configCommandArgs(allocator, init.io, home, &args);
    if (std.mem.eql(u8, cmd, "graph")) return graphCommandArgs(allocator, init.io, home, &args);
    if (std.mem.eql(u8, cmd, "pkg")) return packageCommandArgs(allocator, init.io, home, &args);
    if (std.mem.eql(u8, cmd, "compact")) return compactCommandArgs(allocator, init.io, home, &args);
    if (std.mem.eql(u8, cmd, "update")) return updateCommandArgs(allocator, init.io, home, &args);
    if (std.mem.eql(u8, cmd, "session-dir")) return commands.printSessionDir(allocator);

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    try parts.append(allocator, cmd);
    while (args.next()) |part| try parts.append(allocator, part);
    return commands.runFromArgs(allocator, init.io, home, parts.items);
}

fn runCommandArgs(allocator: std.mem.Allocator, io: std.Io, home: []const u8, args: *std.process.Args.Iterator) !void {
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    return commands.runFromArgs(allocator, io, home, parts);
}

fn configCommandArgs(allocator: std.mem.Allocator, io: std.Io, home: []const u8, args: *std.process.Args.Iterator) !void {
    const sub = args.next() orelse return commands.usage();
    if (!std.mem.eql(u8, sub, "get")) return commands.usage();
    const path = args.next() orelse return error.MissingConfigPath;
    return commands.configGet(allocator, io, home, path);
}

fn graphCommandArgs(allocator: std.mem.Allocator, io: std.Io, home: []const u8, args: *std.process.Args.Iterator) !void {
    const sub = args.next() orelse return commands.usage();
    if (std.mem.eql(u8, sub, "list")) return commands.graphList(allocator, io, home);
    if (std.mem.eql(u8, sub, "show")) return commands.graphShow(allocator, io, home, args.next() orelse return error.MissingGraphPath);
    return commands.usage();
}

fn packageCommandArgs(allocator: std.mem.Allocator, io: std.Io, home: []const u8, args: *std.process.Args.Iterator) !void {
    const sub = args.next() orelse return commands.usage();
    if (std.mem.eql(u8, sub, "list")) return commands.packageList(allocator, io, home);
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    if (std.mem.eql(u8, sub, "add")) return commands.packageAdd(allocator, io, home, parts);
    if (std.mem.eql(u8, sub, "remove")) return commands.packageRemove(allocator, io, home, parts);
    if (std.mem.eql(u8, sub, "update")) return commands.packageUpdate(allocator, io, home, parts);
    if (std.mem.eql(u8, sub, "show")) return commands.packageShow(allocator, io, home, parts);
    if (std.mem.eql(u8, sub, "exec")) return commands.packageExec(allocator, io, home, parts);
    if (std.mem.eql(u8, sub, "attach")) return commands.packageAttach(allocator, io, home, parts);
    if (std.mem.eql(u8, sub, "detach")) return commands.packageDetach(allocator, io, home, parts);
    if (std.mem.eql(u8, sub, "attachments")) return commands.packageAttachments(allocator, io, home, parts);
    return commands.usage();
}

fn compactCommandArgs(allocator: std.mem.Allocator, io: std.Io, home: []const u8, args: *std.process.Args.Iterator) !void {
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    return commands.compactFromArgs(allocator, io, home, parts);
}

fn updateCommandArgs(allocator: std.mem.Allocator, io: std.Io, home: []const u8, args: *std.process.Args.Iterator) !void {
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    return commands.updateFromArgs(allocator, io, home, parts);
}

fn cleanCommandArgs(allocator: std.mem.Allocator, io: std.Io, home: []const u8, args: *std.process.Args.Iterator) !void {
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

    return commands.clean(allocator, io, home, scope orelse .local, target orelse "all", yes);
}

fn collectArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) ![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);
    while (args.next()) |part| try parts.append(allocator, part);
    return parts.toOwnedSlice(allocator);
}
