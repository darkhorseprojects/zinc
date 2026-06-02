pub const path = @import("platform/path.zig");
pub const dirs = @import("platform/dirs.zig");
pub const process = @import("platform/process.zig");
pub const shell = @import("platform/shell.zig");

const builtin = @import("builtin");

pub const OS = enum { linux, macos, windows };

pub fn currentOS() OS {
    return switch (builtin.os.tag) {
        .linux => .linux,
        .macos => .macos,
        .windows => .windows,
        else => @compileError("Zinc supports Linux, macOS, and Windows"),
    };
}

test {
    _ = path;
    _ = dirs;
    _ = process;
    _ = shell;
}
