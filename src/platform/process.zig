const std = @import("std");
const platform = @import("mod.zig");
const path_mod = @import("path.zig");

const Allocator = std.mem.Allocator;

extern fn write(fd: std.posix.fd_t, buf: [*]const u8, count: usize) callconv(.c) isize;

pub const EnvPair = struct { key: []const u8, value: []const u8 };

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

pub fn run(allocator: Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8, env_pairs: []const EnvPair, max_capture_bytes: usize) !Result {
    return runWithInput(allocator, io, argv, null, cwd, env_pairs, 0, max_capture_bytes);
}

pub fn runWithInput(allocator: Allocator, io: std.Io, argv: []const []const u8, stdin: ?[]const u8, cwd: ?[]const u8, env_pairs: []const EnvPair, timeout_seconds: u64, max_capture_bytes: usize) !Result {
    if (argv.len == 0) return error.MissingExecutable;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    if (env_pairs.len != 0) {
        for (env_pairs) |pair| try env_map.put(pair.key, pair.value);
    }

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |dir| .{ .path = dir } else .inherit,
        .environ_map = if (env_pairs.len == 0) null else &env_map,
        .stdin = if (stdin) |_| .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    if (stdin) |data| {
        var written: usize = 0;
        while (written < data.len) {
            const n = write(child.stdin.?.handle, data[written..].ptr, data.len - written);
            if (n <= 0) return error.WriteFailed;
            written += @intCast(n);
        }
        std.Io.File.close(child.stdin.?, io);
        child.stdin = null;
    }

    const buffer: [4096]u8 = undefined;
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(buffer.len, if (timeout_seconds == 0) .none else .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(@intCast(timeout_seconds)), .clock = .real } })) |_| {
        if (max_capture_bytes != 0) {
            if (stdout_reader.buffered().len > max_capture_bytes) return error.StreamTooLong;
            if (stderr_reader.buffered().len > max_capture_bytes) return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();
    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer allocator.free(stderr_slice);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .code = switch (term) {
            .exited => |c| c,
            else => 255,
        },
    };
}

pub fn pathEntries(allocator: Allocator, os: platform.OS, raw_path: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    var it = std.mem.splitScalar(u8, raw_path, path_mod.listSeparator(os));
    while (it.next()) |entry| {
        if (entry.len != 0) try out.append(try allocator.dupe(u8, entry));
    }
    return out.toOwnedSlice();
}

pub fn windowsExtensions(allocator: Allocator, raw: ?[]const u8) ![][]u8 {
    const text = raw orelse ".COM;.EXE;.BAT;.CMD;.PS1";
    var out: std.ArrayList([]u8) = .empty;
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
