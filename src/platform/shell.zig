const std = @import("std");
const platform = @import("../platform.zig");
const proc = @import("process.zig");

const Allocator = std.mem.Allocator;

pub const Shell = enum { sh, zsh, powershell, pwsh, cmd, custom };

pub const CommandClass = enum { inspect, other };

pub fn defaultName(os: platform.OS) []const u8 {
    return switch (os) {
        .linux => "sh",
        .macos => "sh",
        .windows => "powershell",
    };
}

pub fn detect(name: []const u8) Shell {
    const base = normalizedBase(name);
    if (std.ascii.eqlIgnoreCase(base, "sh")) return .sh;
    if (std.ascii.eqlIgnoreCase(base, "zsh")) return .zsh;
    if (std.ascii.eqlIgnoreCase(base, "powershell")) return .powershell;
    if (std.ascii.eqlIgnoreCase(base, "pwsh")) return .pwsh;
    if (std.ascii.eqlIgnoreCase(base, "cmd")) return .cmd;
    return .custom;
}

pub fn argv(allocator: Allocator, shell_path: []const u8, command: []const u8) ![][]const u8 {
    const kind = detect(std.fs.path.basename(shell_path));
    const flag = switch (kind) {
        .powershell, .pwsh => "-Command",
        .cmd => "/C",
        else => "-lc",
    };
    const out = try allocator.alloc([]const u8, 3);
    out[0] = shell_path;
    out[1] = flag;
    out[2] = command;
    return out;
}

pub fn freeArgv(allocator: Allocator, args: []const []const u8) void {
    allocator.free(args);
}

pub fn classify(os: platform.OS, command: []const u8) CommandClass {
    const head = commandHead(command) orelse return .other;
    if (isInspectHead(os, head, command)) return .inspect;
    return .other;
}

pub fn commandHead(command: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return null;
    var end: usize = 0;
    while (end < trimmed.len and std.mem.indexOfScalar(u8, " \t\r\n;&|()<>\"'", trimmed[end]) == null) end += 1;
    if (end == 0) return null;
    return std.fs.path.basename(trimmed[0..end]);
}

fn normalizedBase(name: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfAny(u8, name, "/\\")) |i| i + 1 else 0;
    const base = name[start..];
    inline for (.{ ".exe", ".cmd", ".bat" }) |suffix| {
        if (base.len > suffix.len and std.ascii.eqlIgnoreCase(base[base.len - suffix.len ..], suffix)) return base[0 .. base.len - suffix.len];
    }
    return base;
}

fn isInspectHead(os: platform.OS, head: []const u8, command: []const u8) bool {
    if (std.mem.eql(u8, head, "git")) return gitInspect(command);
    return switch (os) {
        .linux, .macos => in(head, &.{ "pwd", "ls", "cat", "head", "tail", "grep", "rg", "find", "tree", "wc", "du" }),
        .windows => in(head, &.{ "pwd", "Get-ChildItem", "Get-Content", "Select-String", "rg" }),
    };
}

fn gitInspect(command: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
    _ = it.next() orelse return false;
    const sub = it.next() orelse return false;
    return in(sub, &.{ "status", "diff", "log", "branch", "show" });
}

fn in(value: []const u8, list: []const []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, value, item)) return true;
    return false;
}

pub fn resolveDefault(allocator: Allocator, io: std.Io, os: platform.OS, env: proc.Env, configured: ?[]const u8) ![]u8 {
    const name = configured orelse defaultName(os);
    return proc.resolveCommand(allocator, io, os, env, name, null) catch |err| switch (err) {
        error.ExecutableNotFound => return error.ShellUnavailable,
        else => err,
    };
}

test "shell detection normalizes windows executable names" {
    try std.testing.expectEqual(Shell.pwsh, detect("C:\\Program Files\\PowerShell\\7\\pwsh.exe"));
    try std.testing.expectEqual(Shell.powershell, detect("PowerShell.EXE"));
    try std.testing.expectEqual(Shell.cmd, detect("cmd.exe"));
}

test "default shell names" {
    try std.testing.expectEqualStrings("sh", defaultName(.linux));
    try std.testing.expectEqualStrings("powershell", defaultName(.windows));
}

test "inspect classification is platform-aware" {
    try std.testing.expectEqual(CommandClass.inspect, classify(.linux, "ls src"));
    try std.testing.expectEqual(CommandClass.other, classify(.windows, "ls src"));
    try std.testing.expectEqual(CommandClass.inspect, classify(.windows, "Get-ChildItem src"));
    try std.testing.expectEqual(CommandClass.inspect, classify(.linux, "git status --short"));
    try std.testing.expectEqual(CommandClass.other, classify(.linux, "git checkout main"));
}
