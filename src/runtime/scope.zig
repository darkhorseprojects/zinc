const std = @import("std");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");

const Allocator = std.mem.Allocator;

pub const Scope = enum { local, global };

pub fn default() Scope {
    return if (files.existsPath(".zinc")) .local else .global;
}

pub fn dbPath(allocator: Allocator, layout_ctx: layout.Context, scope: Scope) ![]u8 {
    return switch (scope) {
        .local => allocator.dupe(u8, ".zinc/state/zinc.db"),
        .global => layout.sharePath(allocator, layout_ctx, "state/zinc.db"),
    };
}

