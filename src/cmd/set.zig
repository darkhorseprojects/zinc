const std = @import("std");
const Store = @import("../substrate.zig").Store;

const Allocator = std.mem.Allocator;

pub fn runSet(allocator: Allocator, store: *Store, args: []const []const u8) !void {
    _ = allocator;
    if (args.len != 2) return error.InvalidUsage;
    const target = args[0];
    const value = args[1];
    const run = parseRunCurrent(target) orelse return error.UnknownZincUri;
    const step = parseStep(value) orelse return error.UnknownZincUri;
    try store.setCurrent(run, step);
}

fn parseRunCurrent(uri: []const u8) ?[]const u8 {
    const prefix = "zinc://runs/";
    const suffix = "/current";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    if (!std.mem.endsWith(u8, uri, suffix)) return null;
    const id = uri[prefix.len .. uri.len - suffix.len];
    return if (id.len == 0) null else id;
}

fn parseStep(uri: []const u8) ?[]const u8 {
    const prefix = "zinc://steps/";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const id = uri[prefix.len..];
    return if (id.len == 0) null else id;
}
