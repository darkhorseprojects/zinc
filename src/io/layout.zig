const std = @import("std");
const platform = @import("../platform.zig");

const Allocator = std.mem.Allocator;

pub const Context = struct {
    os: platform.OS,
    dirs: platform.dirs.Dirs,

    pub fn fromProcess(allocator: Allocator, env: *const std.process.Environ.Map) !Context {
        return .{ .os = platform.currentOS(), .dirs = try platform.dirs.fromProcess(allocator, env) };
    }

    pub fn deinit(self: Context, allocator: Allocator) void {
        self.dirs.deinit(allocator);
    }
};

pub fn statePath(allocator: Allocator, layout: Context, basename: []const u8) ![]u8 {
    return platform.path.joinDisplay(allocator, layout.os, &.{ layout.dirs.state_dir, basename });
}

pub fn sharePath(allocator: Allocator, layout: Context, path: []const u8) ![]u8 {
    return platform.path.joinDisplay(allocator, layout.os, &.{ layout.dirs.data_dir, path });
}

pub fn configPath(allocator: Allocator, layout: Context) ![]u8 {
    return platform.dirs.configFile(allocator, layout.os, layout.dirs);
}
