const std = @import("std");

pub const OS = enum { linux, macos, windows };

pub fn currentOS() OS {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .linux => .linux,
        .macos => .macos,
        .windows => .windows,
        else => .linux,
    };
}

pub const dirs = @import("dirs.zig");
pub const path = @import("path.zig");
