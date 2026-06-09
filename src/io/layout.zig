const std = @import("std");
const platform = @import("../platform/mod.zig");

const Allocator = std.mem.Allocator;
const io_opt = std.Options.debug_io;

pub fn findWorkspaceRoot(allocator: Allocator) !?[]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io_opt, &path_buf) catch return null;
    const cwd = path_buf[0..cwd_len];
    
    var current = try allocator.dupe(u8, cwd);
    errdefer allocator.free(current);
    
    while (true) {
        const dot_zinc = try std.fs.path.join(allocator, &.{ current, ".zinc" });
        defer allocator.free(dot_zinc);
        
        var stat_success = false;
        if (std.Io.Dir.cwd().statFile(io_opt, dot_zinc, .{})) |_| {
            stat_success = true;
        } else |_| {}
        
        if (stat_success) {
            return current;
        }
        
        const parent = std.fs.path.dirname(current);
        if (parent == null or std.mem.eql(u8, parent.?, current)) {
            allocator.free(current);
            return null;
        }
        
        const next = try allocator.dupe(u8, parent.?);
        allocator.free(current);
        current = next;
    }
}

pub var process_env: ?*const std.process.Environ.Map = null;

pub fn setEnvironmentMap(env: *const std.process.Environ.Map) void {
    process_env = env;
}

pub fn homeDir(allocator: Allocator) ![]u8 {
    const env = process_env orelse return error.EnvironmentNotInitialized;
    const os = platform.currentOS();
    const home = switch (os) {
        .linux, .macos => env.get("HOME") orelse return error.HomeNotSet,
        .windows => env.get("USERPROFILE") orelse env.get("HOME") orelse return error.HomeNotSet,
    };
    return try allocator.dupe(u8, home);
}

pub fn workspacePath(allocator: Allocator, sub: []const u8) !?[]u8 {
    if (try findWorkspaceRoot(allocator)) |root| {
        defer allocator.free(root);
        return try std.fs.path.join(allocator, &.{ root, ".zinc", sub });
    }
    return null;
}

pub fn globalPath(allocator: Allocator, sub: []const u8) ![]u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".zinc", sub });
}

pub fn tempRunPath(allocator: Allocator, sub: []const u8) ![]u8 {
    const env = process_env orelse return error.EnvironmentNotInitialized;
    const os = platform.currentOS();
    const temp = switch (os) {
        .windows => env.get("TEMP") orelse env.get("TMP") orelse "C:\\Windows\\Temp",
        .linux, .macos => env.get("TMPDIR") orelse env.get("TEMP") orelse env.get("TMP") orelse "/tmp",
    };
    return try std.fs.path.join(allocator, &.{ temp, "zinc", sub });
}

