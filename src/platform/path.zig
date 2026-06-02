const std = @import("std");
const platform = @import("../platform.zig");

const Allocator = std.mem.Allocator;

pub fn separator(os: platform.OS) u8 {
    return if (os == .windows) '\\' else '/';
}

pub fn listSeparator(os: platform.OS) u8 {
    return if (os == .windows) ';' else ':';
}

pub fn isAbsolute(os: platform.OS, raw: []const u8) bool {
    if (raw.len == 0) return false;
    return switch (os) {
        .linux, .macos => raw[0] == '/',
        .windows => isWindowsAbsolute(raw),
    };
}

pub fn hasPathSeparator(raw: []const u8) bool {
    return std.mem.indexOfAny(u8, raw, "/\\") != null;
}

pub fn join(allocator: Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

pub fn expandHome(allocator: Allocator, os: platform.OS, home: []const u8, raw: []const u8) ![]u8 {
    if (raw.len == 1 and raw[0] == '~') return allocator.dupe(u8, home);
    if (std.mem.startsWith(u8, raw, "~/") or std.mem.startsWith(u8, raw, "~\\")) return joinDisplay(allocator, os, &.{ home, raw[2..] });
    return allocator.dupe(u8, raw);
}

pub fn normalizeForCompare(allocator: Allocator, os: platform.OS, raw: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, raw);
    errdefer allocator.free(out);
    if (os == .windows) {
        for (out) |*c| {
            if (c.* == '/') c.* = '\\';
            c.* = std.ascii.toLower(c.*);
        }
    }
    return out;
}

pub fn joinDisplay(allocator: Allocator, os: platform.OS, parts: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const sep = separator(os);
    for (parts) |part| {
        if (part.len == 0) continue;
        if (out.items.len == 0) {
            try out.appendSlice(allocator, trimTrailingSeparators(part));
            continue;
        }
        if (!endsWithSeparator(out.items)) try out.append(allocator, sep);
        try out.appendSlice(allocator, trimSeparators(part));
    }
    return out.toOwnedSlice(allocator);
}

pub fn nearestExistingParent(allocator: Allocator, io: std.Io, raw: []const u8) ![]u8 {
    var candidate = try allocator.dupe(u8, raw);
    errdefer allocator.free(candidate);
    while (candidate.len != 0) {
        if (std.Io.Dir.cwd().statFile(io, candidate, .{})) |_| return candidate else |_| {}
        const parent = std.fs.path.dirname(candidate) orelse break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(candidate);
        candidate = next;
    }
    allocator.free(candidate);
    return allocator.dupe(u8, ".");
}

fn isWindowsAbsolute(raw: []const u8) bool {
    if (raw.len >= 2 and raw[0] == '\\' and raw[1] == '\\') return true;
    return raw.len >= 3 and std.ascii.isAlphabetic(raw[0]) and raw[1] == ':' and (raw[2] == '\\' or raw[2] == '/');
}

fn trimSeparators(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, "/\\");
}

fn trimTrailingSeparators(raw: []const u8) []const u8 {
    return std.mem.trimEnd(u8, raw, "/\\");
}

fn endsWithSeparator(raw: []const u8) bool {
    if (raw.len == 0) return false;
    return raw[raw.len - 1] == '/' or raw[raw.len - 1] == '\\';
}

test "platform path absolute detection" {
    try std.testing.expect(isAbsolute(.linux, "/tmp/x"));
    try std.testing.expect(!isAbsolute(.linux, "C:\\tmp"));
    try std.testing.expect(isAbsolute(.windows, "C:\\tmp"));
    try std.testing.expect(isAbsolute(.windows, "C:/tmp"));
    try std.testing.expect(isAbsolute(.windows, "\\\\server\\share"));
}

test "platform path normalization for compare" {
    const got = try normalizeForCompare(std.testing.allocator, .windows, "C:/Users/Colin/File.txt");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("c:\\users\\colin\\file.txt", got);
}

test "platform display join" {
    const win = try joinDisplay(std.testing.allocator, .windows, &.{ "C:\\Users\\colin", "AppData", "zinc" });
    defer std.testing.allocator.free(win);
    try std.testing.expectEqualStrings("C:\\Users\\colin\\AppData\\zinc", win);
    const posix = try joinDisplay(std.testing.allocator, .linux, &.{ "/home/colin/", "./x" });
    defer std.testing.allocator.free(posix);
    try std.testing.expectEqualStrings("/home/colin/./x", posix);
}
