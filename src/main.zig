const std = @import("std");
const clean = @import("clean.zig");
const commands = @import("commands.zig");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const home = std.process.Environ.getPosix(init.minimal.environ, "HOME") orelse return error.HomeNotSet;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    const cmd = args.next() orelse return commands.usage();
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return commands.usage();
    if (std.mem.eql(u8, cmd, "validate")) return commands.validate(allocator, home, args.next());
    if (std.mem.eql(u8, cmd, "compile")) return commands.compile(allocator, home, args.next(), args.next());
    if (std.mem.eql(u8, cmd, "run")) return runCommandArgs(allocator, init.io, home, &args);
    if (std.mem.eql(u8, cmd, "up")) return server.start(allocator, init.io, home, args.next());
    if (std.mem.eql(u8, cmd, "down")) return server.stop(allocator, home);
    if (std.mem.eql(u8, cmd, "clean")) return cleanCommandArgs(allocator, init.io, home, &args);
    if (std.mem.eql(u8, cmd, "compact")) return compactCommandArgs(allocator, init.io, home, &args);
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

fn cleanCommandArgs(allocator: std.mem.Allocator, io: std.Io, home: []const u8, args: *std.process.Args.Iterator) !void {
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    return clean.run(allocator, io, home, parts);
}

fn compactCommandArgs(allocator: std.mem.Allocator, io: std.Io, home: []const u8, args: *std.process.Args.Iterator) !void {
    const parts = try collectArgs(allocator, args);
    defer allocator.free(parts);
    return commands.compactFromArgs(allocator, io, home, parts);
}

fn collectArgs(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) ![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);
    while (args.next()) |part| try parts.append(allocator, part);
    return parts.toOwnedSlice(allocator);
}
