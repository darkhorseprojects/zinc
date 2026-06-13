const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn isSegment(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') continue;
        return false;
    }
    return true;
}

pub fn validateSegment(value: []const u8) !void {
    if (!isSegment(value)) return error.InvalidPathSegment;
}

pub fn validate(value: []const u8) !void {
    if (value.len == 0) return error.InvalidPath;
    var it = std.mem.splitScalar(u8, value, '/');
    while (it.next()) |segment| try validateSegment(segment);
}

pub fn valueSegment(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "$")) name[1..] else name;
}

pub fn valuePath(allocator: Allocator, prefix: []const u8, name: []const u8) ![]u8 {
    const segment = valueSegment(name);
    try validateSegment(segment);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, segment });
}

pub fn join(allocator: Allocator, segments: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (segments, 0..) |segment, index| {
        try validateSegment(segment);
        if (index > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, segment);
    }
    return out.toOwnedSlice(allocator);
}

pub fn dotted(allocator: Allocator, slash_path: []const u8) ![]u8 {
    try validate(slash_path);
    const out = try allocator.dupe(u8, slash_path);
    for (out) |*c| {
        if (c.* == '/') c.* = '.';
    }
    return out;
}

pub fn slashFromDotted(allocator: Allocator, dotted_path: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, dotted_path, '/')) |_| return error.InvalidPath;
    const out = try allocator.dupe(u8, dotted_path);
    errdefer allocator.free(out);
    for (out) |*c| {
        if (c.* == '.') c.* = '/';
    }
    try validate(out);
    return out;
}

pub fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}
