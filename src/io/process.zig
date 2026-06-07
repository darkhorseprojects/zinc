const std = @import("std");
const files = @import("fs.zig");
const platform = @import("../platform.zig");
const shell = @import("../platform/shell.zig");

const Allocator = std.mem.Allocator;

pub const ProcessResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    output_path: ?[]u8 = null,
    truncated: bool = false,

    pub fn deinit(self: ProcessResult, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        if (self.output_path) |path| allocator.free(path);
    }
};

const Tail = struct {
    text: []u8,
    truncated: bool,
    original_bytes: usize,
    shown_bytes: usize,
    pub fn deinit(self: Tail, allocator: Allocator) void {
        allocator.free(self.text);
    }
};

pub fn runShell(allocator: Allocator, io: std.Io, command: []const u8, cwd: ?[]const u8, max_output_bytes: usize, max_capture_bytes: usize) !ProcessResult {
    const child_cwd: std.process.Child.Cwd = if (cwd) |path| .{ .path = path } else .inherit;
    const shell_name = shell.defaultName(platform.currentOS());
    const argv = try shell.argv(allocator, shell_name, command);
    defer shell.freeArgv(allocator, argv);
    const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = child_cwd, .stdout_limit = .limited(max_capture_bytes), .stderr_limit = .limited(max_capture_bytes) });
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    const total_bytes = result.stdout.len + result.stderr.len;
    var output_path: ?[]u8 = null;
    errdefer if (output_path) |path| allocator.free(path);
    if (total_bytes > max_output_bytes) output_path = try writeTempOutput(allocator, result.stdout, result.stderr);
    return .{ .stdout = result.stdout, .stderr = result.stderr, .code = code, .output_path = output_path, .truncated = output_path != null };
}

pub fn shellSummary(allocator: Allocator, command: []const u8, result: ProcessResult, max_output_bytes: usize, max_output_lines: usize) ![]u8 {
    _ = command;
    const stdout_tail = try tailText(allocator, result.stdout, max_output_bytes, max_output_lines);
    defer stdout_tail.deinit(allocator);
    const stderr_tail = try tailText(allocator, result.stderr, max_output_bytes, max_output_lines);
    defer stderr_tail.deinit(allocator);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "exit={d}\nstdout:\n{s}\nstderr:\n{s}", .{ result.code, stdout_tail.text, stderr_tail.text });
    if (result.output_path) |path| {
        try out.print(allocator, "\n\n[streams truncated: stdout {d} bytes, stderr {d} bytes. Full capture: {s}]", .{ result.stdout.len, result.stderr.len, path });
    } else if (stdout_tail.truncated or stderr_tail.truncated) {
        try out.print(allocator, "\n\n[streams truncated: stdout {d} bytes, stderr {d} bytes]", .{ result.stdout.len, result.stderr.len });
    }
    return out.toOwnedSlice(allocator);
}

pub fn shellMetadata(allocator: Allocator, command: []const u8, result: ProcessResult) ![]u8 {
    var metadata: std.ArrayList(u8) = .empty;
    errdefer metadata.deinit(allocator);
    try metadata.appendSlice(allocator, "{\"command\":");
    try files.appendJsonString(allocator, &metadata, command);
    try metadata.print(allocator, ",\"exit\":{d},\"stdout_bytes\":{d},\"stderr_bytes\":{d},\"truncated\":", .{ result.code, result.stdout.len, result.stderr.len });
    try metadata.appendSlice(allocator, if (result.truncated) "true" else "false");
    if (result.output_path) |path| {
        try metadata.appendSlice(allocator, ",\"output_path\":");
        try files.appendJsonString(allocator, &metadata, path);
    }
    if (!result.truncated) {
        try metadata.appendSlice(allocator, ",\"stdout\":");
        try files.appendJsonString(allocator, &metadata, result.stdout);
        try metadata.appendSlice(allocator, ",\"stderr\":");
        try files.appendJsonString(allocator, &metadata, result.stderr);
    }
    try metadata.appendSlice(allocator, ",\"is_error\":");
    try metadata.appendSlice(allocator, if (result.code == 0) "false}" else "true}");
    return metadata.toOwnedSlice(allocator);
}

fn tailText(allocator: Allocator, text: []const u8, max_output_bytes: usize, max_output_lines: usize) !Tail {
    const start = tailStart(text, max_output_bytes, max_output_lines);
    return .{
        .text = try allocator.dupe(u8, text[start..]),
        .truncated = start != 0,
        .original_bytes = text.len,
        .shown_bytes = text.len - start,
    };
}

fn tailStart(text: []const u8, max_bytes: usize, max_lines: usize) usize {
    const start = if (text.len > max_bytes) text.len - max_bytes else 0;
    var lines: usize = 0;
    var i = text.len;
    while (i > start) {
        i -= 1;
        if (text[i] == '\n') {
            lines += 1;
            if (lines > max_lines) return i + 1;
        }
    }
    return start;
}

fn writeTempOutput(allocator: Allocator, stdout: []const u8, stderr: []const u8) ![]u8 {
    const path = try tempPath(allocator);
    errdefer allocator.free(path);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "stdout:\n");
    try out.appendSlice(allocator, stdout);
    try out.appendSlice(allocator, "\nstderr:\n");
    try out.appendSlice(allocator, stderr);
    try files.write(path, out.items);
    return path;
}

fn tempPath(allocator: Allocator) ![]u8 {
    try files.mkdirP(".zinc/tmp");
    var bytes: [8]u8 = undefined;
    randomBytes(&bytes);
    return std.fmt.allocPrint(allocator, ".zinc/tmp/{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}.log", .{ bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7] });
}

fn randomBytes(bytes: []u8) void {
    const ts = std.Io.Clock.real.now(std.Options.debug_io);
    var prng = std.Random.DefaultPrng.init(@as(u64, @truncate(@as(u96, @bitCast(ts.nanoseconds)))));
    prng.random().bytes(bytes);
}
