const std = @import("std");
const files = @import("files.zig");
const layout = @import("layout.zig");
const server = @import("server.zig");

const Allocator = std.mem.Allocator;

pub fn run(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    var yes = false;
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(allocator);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--yes")) {
            yes = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            yes = false;
        } else {
            try words.append(allocator, arg);
        }
    }

    if (words.items.len == 0) return cleanLocalGenerated(io, yes);
    const scope = words.items[0];
    if (std.mem.eql(u8, scope, "compiled") or std.mem.eql(u8, scope, "local")) {
        if (words.items.len != 1) return error.InvalidCleanCommand;
        return cleanLocalGenerated(io, yes);
    }
    if (std.mem.eql(u8, scope, "sessions")) {
        if (words.items.len != 1) return error.InvalidCleanCommand;
        return cleanPaths(io, yes, &.{".zinc/sessions"});
    }
    if (std.mem.eql(u8, scope, "all")) {
        if (words.items.len != 1) return error.InvalidCleanCommand;
        return cleanPaths(io, yes, &.{ ".zinc/compiled", ".zinc/sessions" });
    }
    if (std.mem.eql(u8, scope, "build")) {
        if (words.items.len != 1) return error.InvalidCleanCommand;
        return cleanGlobalBuild(allocator, io, home, yes);
    }
    if (std.mem.eql(u8, scope, "global")) {
        const target = if (words.items.len == 1) "state" else words.items[1];
        if (words.items.len > 2) return error.InvalidCleanCommand;
        if (std.mem.eql(u8, target, "state") or std.mem.eql(u8, target, "logs")) return cleanGlobalState(allocator, io, home, yes);
        if (std.mem.eql(u8, target, "build")) return cleanGlobalBuild(allocator, io, home, yes);
        if (std.mem.eql(u8, target, "all")) {
            try cleanGlobalState(allocator, io, home, yes);
            return cleanGlobalBuild(allocator, io, home, yes);
        }
        return error.InvalidCleanCommand;
    }
    return error.InvalidCleanCommand;
}

fn cleanLocalGenerated(io: std.Io, yes: bool) !void {
    return cleanPaths(io, yes, &.{".zinc/compiled"});
}

fn cleanGlobalState(allocator: Allocator, io: std.Io, home: []const u8, yes: bool) !void {
    if (yes and try server.isUp(allocator, home)) {
        std.debug.print("refusing global state cleanup while Zinc server is running; run zn down first\n", .{});
        return;
    }
    const pid_path = try layout.statePath(allocator, home, "server.pid");
    defer allocator.free(pid_path);
    const log_path = try layout.statePath(allocator, home, "server.log");
    defer allocator.free(log_path);
    return cleanPaths(io, yes, &.{ pid_path, log_path });
}

fn cleanGlobalBuild(allocator: Allocator, io: std.Io, home: []const u8, yes: bool) !void {
    if (yes and try server.isUp(allocator, home)) {
        std.debug.print("refusing global build cleanup while Zinc server is running; run zn down first\n", .{});
        return;
    }
    const build_path = try layout.sharePath(allocator, home, "llama-cpp-turboquant");
    defer allocator.free(build_path);
    return cleanPaths(io, yes, &.{build_path});
}

fn cleanPaths(io: std.Io, yes: bool, paths: []const []const u8) !void {
    if (!yes) std.debug.print("dry run; add --yes to remove\n", .{});
    for (paths) |path| {
        if (files.existsPath(path)) {
            if (yes) {
                try std.Io.Dir.cwd().deleteTree(io, path);
                std.debug.print("removed {s}\n", .{path});
            } else {
                std.debug.print("would remove {s}\n", .{path});
            }
        } else {
            std.debug.print("missing {s}\n", .{path});
        }
    }
}
