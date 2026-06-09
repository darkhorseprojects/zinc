const std = @import("std");
const files = @import("fs.zig");
const platform = @import("../platform/mod.zig");
const shell = @import("../platform/shell.zig");
const layout = @import("layout.zig");

const Allocator = std.mem.Allocator;

pub const run = @import("../platform/process.zig").run;
pub const Result = @import("../platform/process.zig").Result;

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

pub fn runShell(allocator: Allocator, io: std.Io, command: []const u8, cwd: ?[]const u8, max_output_bytes: usize, max_capture_bytes: usize, run_id: []const u8) !ProcessResult {
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
    if (total_bytes > max_output_bytes) {
        output_path = try writeTempOutput(allocator, run_id, result.stdout, result.stderr);
    }
    return .{ .stdout = result.stdout, .stderr = result.stderr, .code = code, .output_path = output_path, .truncated = output_path != null };
}

pub fn shellSummary(allocator: Allocator, command: []const u8, result: ProcessResult, max_output_bytes: usize, max_output_lines: usize, run_id: []const u8) ![]u8 {
    _ = command;
    const stdout_tail = try tailText(allocator, result.stdout, max_output_bytes, max_output_lines);
    defer stdout_tail.deinit(allocator);
    const stderr_tail = try tailText(allocator, result.stderr, max_output_bytes, max_output_lines);
    defer stderr_tail.deinit(allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.print(allocator, "exit: {d}\nstdout: {d} bytes captured\n\npreview:\n{s}\n", .{ result.code, result.stdout.len, stdout_tail.text });
    if (stderr_tail.text.len > 0) {
        try out.print(allocator, "\nstderr:\n{s}\n", .{stderr_tail.text});
    }
    if (result.output_path) |_| {
        try out.print(allocator, "\n[truncated]\n\nfull:\n  zinc://run/{s}/stdout\n", .{run_id});
    } else if (stdout_tail.truncated or stderr_tail.truncated) {
        try out.print(allocator, "\n[truncated]\n\nfull:\n  zinc://run/{s}/stdout\n", .{run_id});
    }
    return out.toOwnedSlice(allocator);
}

pub fn shellMetadata(allocator: Allocator, command: []const u8, result: ProcessResult) ![]u8 {
    var metadata: std.ArrayList(u8) = .empty;
    errdefer metadata.deinit(allocator);
    try metadata.appendSlice(allocator, "{\"command\":");
    try appendJsonEscaped(allocator, &metadata, command);
    try metadata.print(allocator, ",\"exit\":{d},\"stdout_bytes\":{d},\"stderr_bytes\":{d},\"truncated\":", .{ result.code, result.stdout.len, result.stderr.len });
    try metadata.appendSlice(allocator, if (result.truncated) "true" else "false");
    if (result.output_path) |path| {
        try metadata.appendSlice(allocator, ",\"output_path\":");
        try appendJsonEscaped(allocator, &metadata, path);
    }
    try metadata.appendSlice(allocator, "}");
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

fn writeTempOutput(allocator: Allocator, run_id: []const u8, stdout: []const u8, stderr: []const u8) ![]u8 {
    const run_sub = try std.fmt.allocPrint(allocator, "runs/{s}", .{run_id});
    defer allocator.free(run_sub);
    const dir = try layout.tempRunPath(allocator, run_sub);
    defer allocator.free(dir);
    try files.mkdirP(dir);
    
    const out_sub = try std.fmt.allocPrint(allocator, "runs/{s}/stdout", .{run_id});
    defer allocator.free(out_sub);
    const out_path = try layout.tempRunPath(allocator, out_sub);
    errdefer allocator.free(out_path);
    try files.write(out_path, stdout);

    const err_sub = try std.fmt.allocPrint(allocator, "runs/{s}/stderr", .{run_id});
    defer allocator.free(err_sub);
    const err_path = try layout.tempRunPath(allocator, err_sub);
    defer allocator.free(err_path);
    try files.write(err_path, stderr);

    return out_path;
}

fn appendJsonEscaped(allocator: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    try std.json.Stringify.value(value, .{}, &aw.writer);
}
