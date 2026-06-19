const std = @import("std");
const Store = @import("substrate.zig").Store;
const cmd_run = @import("cmd/run.zig");
const cmd_read = @import("cmd/read.zig");
const cmd_inspect = @import("cmd/inspect.zig");
const cmd_pkg = @import("cmd/pkg.zig");
const cmd_config = @import("cmd/config.zig");
const cmd_update = @import("cmd/update.zig");
const files = @import("io/fs.zig");

pub fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    @import("io/layout.zig").setEnvironmentMap(init.environ_map);
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    _ = args.next();

    const cmd = args.next() orelse {
        try usage();
        return error.InvalidUsage;
    };

    if (std.mem.eql(u8, cmd, "update")) {
        var remaining: std.ArrayList([]const u8) = .empty;
        defer remaining.deinit(allocator);
        while (args.next()) |arg| try remaining.append(allocator, arg);
        try cmd_update.runUpdate(allocator, init.io, remaining.items);
        return;
    }
    if (std.mem.eql(u8, cmd, "internal-replace")) {
        var remaining: std.ArrayList([]const u8) = .empty;
        defer remaining.deinit(allocator);
        while (args.next()) |arg| try remaining.append(allocator, arg);
        try cmd_update.runInternalReplace(allocator, init.io, remaining.items);
        return;
    }

    var settings = try cmd_config.loadSettings(allocator);
    defer settings.deinit();
    var store = try Store.open(allocator);
    defer store.close();

    if (std.mem.eql(u8, cmd, "run")) {
        const shape = args.next() orelse {
            try files.writeAllErr("Error: Missing shape path.\n");
            try usage();
            return error.InvalidUsage;
        };
        var remaining: std.ArrayList([]const u8) = .empty;
        defer remaining.deinit(allocator);
        while (args.next()) |arg| {
            try remaining.append(allocator, arg);
        }
        try cmd_run.run(allocator, init.io, &store, &settings, shape, remaining.items);
    } else if (std.mem.eql(u8, cmd, "read")) {
        const target = args.next() orelse {
            try files.writeAllErr("Error: Missing target to read.\n");
            try usage();
            return error.InvalidUsage;
        };
        try cmd_read.runRead(allocator, &store, target);
    } else if (std.mem.eql(u8, cmd, "inspect")) {
        const target = args.next() orelse {
            try files.writeAllErr("Error: Missing target to inspect.\n");
            try usage();
            return error.InvalidUsage;
        };
        try cmd_inspect.runInspect(allocator, &store, target);
    } else if (std.mem.eql(u8, cmd, "pkg")) {
        var remaining: std.ArrayList([]const u8) = .empty;
        defer remaining.deinit(allocator);
        while (args.next()) |arg| {
            try remaining.append(allocator, arg);
        }
        try cmd_pkg.runPkg(allocator, init.io, &store, remaining.items);
    } else if (std.mem.eql(u8, cmd, "config")) {
        var remaining: std.ArrayList([]const u8) = .empty;
        defer remaining.deinit(allocator);
        while (args.next()) |arg| {
            try remaining.append(allocator, arg);
        }
        try cmd_config.runConfig(allocator, &store, remaining.items);
    } else {
        try files.writeAllErr("Error: Unknown command: ");
        try files.writeAllErr(cmd);
        try files.writeAllErr("\n");
        try usage();
        return error.InvalidUsage;
    }
}

fn usage() !void {
    try files.writeAllErr(
        \\Usage: zn <command> [args]
        \\
        \\Commands:
        \\  run <shape>                   Run a Circuitry shape
        \\  read <uri-or-file>            Read a file or zinc:// reference
        \\  inspect <uri-or-file>         Inspect a shape, package, substrate, or reference
        \\  pkg <subcommand> [args]       Manage packages (install, remove, list, update, neighbors)
        \\  update                        Update the zn binary
        \\  config                        Manage configuration
        \\
    );
}
