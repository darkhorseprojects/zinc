const std = @import("std");
const config = @import("config.zig");
const files = @import("files.zig");
const layout = @import("layout.zig");

const Allocator = std.mem.Allocator;

pub fn start(allocator: Allocator, io: std.Io, home: []const u8, model_arg: ?[]const u8) !void {
    const pid_path = try layout.statePath(allocator, home, "server.pid");
    defer allocator.free(pid_path);
    const model_id = if (model_arg) |model| blk: {
        try requireSafeModelId(model);
        break :blk try allocator.dupe(u8, model);
    } else try config.resolveConfiguredModelId(allocator, home);
    defer allocator.free(model_id);
    try requireSafeModelId(model_id);

    const runtime = try config.loadRuntimeConfig(allocator, home);
    defer runtime.deinit(allocator);

    if (try readLivePid(allocator, pid_path)) |pid| {
        try waitUntilReady(allocator, io, runtime.provider_base_url, pid);
        std.debug.print("Zinc server ready: pid {d}, model {s}\n", .{ pid, model_id });
        return;
    }

    const script = try findServeScript(allocator, home);
    defer allocator.free(script);
    const log_path = try layout.statePath(allocator, home, "server.log");
    defer allocator.free(log_path);
    if (std.fs.path.dirname(log_path)) |dir| try files.mkdirP(dir);

    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);
    try command.print(allocator, "nohup ", .{});
    try appendShellWord(allocator, &command, script);
    try command.append(allocator, ' ');
    try appendShellWord(allocator, &command, model_id);
    try command.print(allocator, " >> ", .{});
    try appendShellWord(allocator, &command, log_path);
    try command.print(allocator, " 2>&1 </dev/null & echo $!", .{});

    const result = try std.process.run(allocator, io, .{ .argv = &.{ "sh", "-c", command.items }, .stderr_limit = .limited(4096), .stdout_limit = .limited(1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const pid_text = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (pid_text.len == 0) return error.ServerStartFailed;
    const pid = try std.fmt.parseInt(std.posix.pid_t, pid_text, 10);
    sleepMillis(250);
    if (!pidAlive(allocator, pid)) return error.ServerStartFailed;

    try waitUntilReady(allocator, io, runtime.provider_base_url, pid);

    const pid_file = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    defer allocator.free(pid_file);
    try files.write(pid_path, pid_file);
    std.debug.print("Zinc server up: pid {d}, model {s}, log {s}\n", .{ pid, model_id, log_path });
}

pub fn stop(allocator: Allocator, home: []const u8) !void {
    const pid_path = try layout.statePath(allocator, home, "server.pid");
    defer allocator.free(pid_path);
    const pid = try readStoredPid(allocator, pid_path) orelse {
        std.debug.print("Zinc server is not up\n", .{});
        return;
    };
    if (!pidAlive(allocator, pid)) {
        removeFile(pid_path);
        std.debug.print("Zinc server was not running\n", .{});
        return;
    }
    if (!pidLooksLikeZincServer(allocator, pid)) {
        removeFile(pid_path);
        return error.PidIsNotZincServer;
    }

    try std.posix.kill(pid, .TERM);
    if (waitUntilStopped(allocator, pid, 5000)) {
        removeFile(pid_path);
        std.debug.print("Zinc server down\n", .{});
        return;
    }

    try std.posix.kill(pid, .KILL);
    if (!waitUntilStopped(allocator, pid, 5000)) return error.ServerStopFailed;
    removeFile(pid_path);
    std.debug.print("Zinc server down after SIGKILL\n", .{});
}

pub fn isUp(allocator: Allocator, home: []const u8) !bool {
    const pid_path = try layout.statePath(allocator, home, "server.pid");
    defer allocator.free(pid_path);
    return (try readLivePid(allocator, pid_path)) != null;
}

fn findServeScript(allocator: Allocator, home: []const u8) ![]u8 {
    if (files.exists("scripts/serve-model.sh")) |_| return allocator.dupe(u8, "scripts/serve-model.sh") else |_| {}
    const installed = try layout.sharePath(allocator, home, "scripts/serve-model.sh");
    errdefer allocator.free(installed);
    if (files.exists(installed)) |_| return installed else |_| {}
    allocator.free(installed);
    return error.ServeScriptNotFound;
}

fn readLivePid(allocator: Allocator, path: []const u8) !?std.posix.pid_t {
    const pid = try readStoredPid(allocator, path) orelse return null;
    if (pidAlive(allocator, pid) and pidLooksLikeZincServer(allocator, pid)) return pid;
    removeFile(path);
    return null;
}

fn readStoredPid(allocator: Allocator, path: []const u8) !?std.posix.pid_t {
    const text = files.readLimited(allocator, path, 64) catch return null;
    defer allocator.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch null;
}

fn waitUntilReady(allocator: Allocator, io: std.Io, base_url: []const u8, pid: std.posix.pid_t) !void {
    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        if (!pidAlive(allocator, pid)) return error.ServerStartFailed;
        const status = readinessProbe(allocator, io, base_url);
        if (status >= 200 and status < 300) return;
        if (status >= 400 and status < 500) return error.ServerReadinessFailed;
        if (attempts != 0 and attempts % 10 == 0) std.debug.print("Zinc server still loading model...\n", .{});
        sleepMillis(1000);
    }
}

fn readinessProbe(allocator: Allocator, io: std.Io, base_url: []const u8) u16 {
    const url = std.fmt.allocPrint(allocator, "{s}/models", .{base_url}) catch return 0;
    defer allocator.free(url);

    var response = std.Io.Writer.Allocating.init(allocator);
    defer response.deinit();
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response.writer,
    }) catch return 0;
    return @intFromEnum(result.status);
}

fn waitUntilStopped(allocator: Allocator, pid: std.posix.pid_t, timeout_ms: usize) bool {
    var waited: usize = 0;
    while (waited < timeout_ms) : (waited += 100) {
        sleepMillis(100);
        if (!pidAlive(allocator, pid)) return true;
    }
    return !pidAlive(allocator, pid);
}

fn pidLooksLikeZincServer(allocator: Allocator, pid: std.posix.pid_t) bool {
    const path = std.fmt.allocPrint(allocator, "/proc/{d}/cmdline", .{pid}) catch return false;
    defer allocator.free(path);
    const cmdline = files.readLimited(allocator, path, 4096) catch return false;
    defer allocator.free(cmdline);
    return std.mem.indexOf(u8, cmdline, "llama-server") != null or std.mem.indexOf(u8, cmdline, "serve-model.sh") != null;
}

fn pidAlive(allocator: Allocator, pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @as(std.posix.SIG, @enumFromInt(0))) catch return false;
    const stat_path = std.fmt.allocPrint(allocator, "/proc/{d}/stat", .{pid}) catch return true;
    defer allocator.free(stat_path);
    const stat = files.readLimited(allocator, stat_path, 512) catch return true;
    defer allocator.free(stat);
    const close_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return true;
    const rest = std.mem.trim(u8, stat[close_paren + 1 ..], " ");
    return rest.len == 0 or rest[0] != 'Z';
}

fn sleepMillis(ms: usize) void {
    var request = std.os.linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    while (true) {
        var remaining: std.os.linux.timespec = undefined;
        const rc = std.os.linux.nanosleep(&request, &remaining);
        const errno = std.os.linux.errno(rc);
        if (errno == .SUCCESS) return;
        if (errno != .INTR) return;
        request = remaining;
    }
}

fn removeFile(path: []const u8) void {
    var buffer: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len >= buffer.len) return;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    _ = std.os.linux.unlink(&buffer);
}

fn requireSafeModelId(model: []const u8) !void {
    if (model.len == 0) return error.InvalidModelId;
    for (model) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return error.InvalidModelId,
    };
}

fn appendShellWord(allocator: Allocator, out: *std.ArrayList(u8), word: []const u8) !void {
    try out.append(allocator, '\'');
    for (word) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}
