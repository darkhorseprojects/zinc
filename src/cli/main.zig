const std = @import("std");
const commands = @import("commands.zig");
const server = @import("../server.zig");

pub fn run(init: std.process.Init) !void {
    try runInner(init);
}

fn runInner(init: std.process.Init) !void {
    const allocator = init.gpa;
    const home = std.process.Environ.getPosix(init.minimal.environ, "HOME") orelse return error.HomeNotSet;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    const cmd = args.next() orelse return commands.usage();
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return commands.usage();
    if (std.mem.eql(u8, cmd, "check")) return commands.validate(allocator, init.io, home, args.next());
    if (std.mem.eql(u8, cmd, "run")) return runCommandArgs(allocator, init.io, home, &args);
    if (std.mem.eql(u8, cmd, "serve")) return server.start(allocator, init.io, home, args.next());
    if (std.mem.eql(u8, cmd, "stop")) return server.stop(allocator, home);
    if (std.mem.eql(u8, cmd, "status")) return server.status(allocator, home);
    if (std.mem.eql(u8, cmd, "session-dir")) return commands.printSessionDir(allocator);
    if (std.mem.eql(u8, cmd, "graph")) {
        const sub = args.next() orelse return commands.usage();
        if (std.mem.eql(u8, sub, "list")) return commands.graphList(allocator, init.io, home);
        return commands.usage();
    }
    if (std.mem.eql(u8, cmd, "pkg")) {
        const sub = args.next() orelse return commands.usage();
        if (std.mem.eql(u8, sub, "add")) {
            const source = args.next() orelse return error.MissingPackageSource;
            return commands.packageAdd(allocator, init.io, home, source);
        }
        if (std.mem.eql(u8, sub, "list")) return commands.packageList(allocator, init.io, home);
        if (std.mem.eql(u8, sub, "remove")) {
            const name = args.next() orelse return error.MissingPackageName;
            return commands.packageRemove(allocator, init.io, home, name, null);
        }
        return commands.usage();
    }

    // Default: run as prompt
    try commands.runPrompt(allocator, init.io, home, null, null);
}

fn runCommandArgs(allocator: std.mem.Allocator, io: std.Io, home: []const u8, args: *std.process.Args.Iterator) !void {
    var graph_path: ?[]const u8 = null;
    var entry: ?[]const u8 = null;
    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--entry")) {
            const e = args.next() orelse return error.MissingEntry;
            entry = e;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--entry=")) {
            entry = arg["--entry=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--input=")) continue; // Skip input processing for now
        if (std.mem.startsWith(u8, arg, "--graph=")) {
            graph_path = arg["--graph=".len..];
            continue;
        }
        if (arg.len > 0 and std.mem.indexOf(u8, arg, "=") == null and !std.mem.startsWith(u8, arg, "-")) {
            graph_path = arg;
            continue;
        }
        // Treat remaining args as prompt parts
        if (prompt.items.len > 0) try prompt.append(allocator, ' ');
        try prompt.appendSlice(allocator, arg);
    }

    try commands.runPrompt(allocator, io, home, graph_path, entry);
}
