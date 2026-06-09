const std = @import("std");
const platform = @import("mod.zig");
const Allocator = std.mem.Allocator;

pub fn isAbsolute(os: platform.OS, p: []const u8) bool {
    if (p.len == 0) return false;
    return switch (os) {
        .linux, .macos => p[0] == '/',
        .windows => (p.len >= 3 and p[1] == ':' and (p[2] == '/' or p[2] == '\\')) or (p[0] == '/' or p[0] == '\\'),
    };
}

pub fn hasPathSeparator(p: []const u8) bool {
    return std.mem.indexOfAny(u8, p, "/\\") != null;
}

pub fn listSeparator(os: platform.OS) u8 {
    return switch (os) {
        .linux, .macos => ':',
        .windows => ';',
    };
}

pub fn joinDisplay(allocator: Allocator, os: platform.OS, paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const sep: []const u8 = switch (os) {
        .linux, .macos => "/",
        .windows => "\\",
    };
    for (paths, 0..) |p, i| {
        if (p.len == 0) continue;
        if (i > 0 and out.items.len > 0) {
            const last = out.items[out.items.len - 1];
            const first = p[0];
            const last_is_sep = last == '/' or last == '\\';
            const first_is_sep = first == '/' or first == '\\';
            if (!last_is_sep and !first_is_sep) {
                try out.appendSlice(sep);
            } else if (last_is_sep and first_is_sep) {
                _ = out.pop();
            }
        }
        try out.appendSlice(p);
    }
    return out.toOwnedSlice();
}
