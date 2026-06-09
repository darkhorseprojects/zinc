const std = @import("std");
const platform = @import("mod.zig");
const path_mod = @import("path.zig");

const Allocator = std.mem.Allocator;

pub const Env = struct {
    path: ?[]const u8 = null,
    pathext: ?[]const u8 = null,
};

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    pub fn deinit(self: Result, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn run(allocator: Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8, max_capture_bytes: usize) !Result {
    if (argv.len == 0) return error.MissingExecutable;
    const child_cwd: std.process.Child.Cwd = if (cwd) |dir| .{ .path = dir } else .inherit;
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = child_cwd,
        .stdout_limit = .limited(max_capture_bytes),
        .stderr_limit = .limited(max_capture_bytes),
    });
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .code = switch (result.term) {
            .exited => |c| c,
            else => 255,
        },
    };
}

pub fn pathEntries(allocator: Allocator, os: platform.OS, raw_path: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, out.items);
    var it = std.mem.splitScalar(u8, raw_path, path_mod.listSeparator(os));
    while (it.next()) |entry| {
        if (entry.len != 0) try out.append(try allocator.dupe(u8, entry));
    }
    return out.toOwnedSlice();
}

pub fn windowsExtensions(allocator: Allocator, raw: ?[]const u8) ![][]u8 {
    const text = raw orelse ".COM;.EXE;.BAT;.CMD;.PS1";
    var out: std.ArrayList([]u8) = std.ArrayList([]u8).init(allocator);
    errdefer freeStringList(allocator, out.items);
    var it = std.mem.splitScalar(u8, text, ';');
    while (it.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " ");
        if (trimmed.len == 0) continue;
        try out.append(try allocator.dupe(u8, trimmed));
    }
    return out.toOwnedSlice();
}

pub fn resolveCommand(allocator: Allocator, io: std.Io, os: platform.OS, env: Env, command: []const u8, package_dir: ?[]const u8) ![]u8 {
    if (command.len == 0) return error.MissingExecutable;
    if (path_mod.isAbsolute(os, command)) return allocator.dupe(u8, command);
    if (path_mod.hasPathSeparator(command)) {
        if (package_dir) |dir| {
            const candidate = try path_mod.joinDisplay(allocator, os, &.{ dir, command });
            defer allocator.free(candidate);
            _ = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch |err| switch (err) {
                error.FileNotFound => return error.ExecutableNotFound,
                else => return err,
            };
        }
        return allocator.dupe(u8, command);
    }
    const path_text = env.path orelse return error.ExecutableNotFound;
    const dirs = try pathEntries(allocator, os, path_text);
    defer freeStringList(allocator, dirs);
    const exts = if (os == .windows) try windowsExtensions(allocator, env.pathext) else try allocator.alloc([]u8, 0);
    defer freeStringList(allocator, exts);
    for (dirs) |dir| {
        if (try candidateExists(allocator, io, os, dir, command, null)) |found| return found;
        for (exts) |ext| {
            if (!hasAnyExtension(command)) {
                if (try candidateExists(allocator, io, os, dir, command, ext)) |found| return found;
            }
        }
    }
    return error.ExecutableNotFound;
}

fn candidateExists(allocator: Allocator, io: std.Io, os: platform.OS, dir: []const u8, command: []const u8, ext: ?[]const u8) !?[]u8 {
    const name = if (ext) |suffix| try std.fmt.allocPrint(allocator, "{s}{s}", .{ command, suffix }) else try allocator.dupe(u8, command);
    defer allocator.free(name);
    const candidate = try path_mod.joinDisplay(allocator, os, &.{ dir, name });
    errdefer allocator.free(candidate);
    _ = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    return candidate;
}

fn hasAnyExtension(command: []const u8) bool {
    return std.fs.path.extension(command).len != 0;
}

pub fn freeStringList(allocator: Allocator, list: []const []u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}
