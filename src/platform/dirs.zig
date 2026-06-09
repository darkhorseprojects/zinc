const std = @import("std");
const platform = @import("mod.zig");
const path = @import("path.zig");

const Allocator = std.mem.Allocator;

pub const Env = struct {
    home: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    xdg_cache_home: ?[]const u8 = null,
    appdata: ?[]const u8 = null,
    localappdata: ?[]const u8 = null,
    userprofile: ?[]const u8 = null,
};

pub const Dirs = struct {
    home: []u8,
    config_dir: []u8,
    data_dir: []u8,
    cache_dir: []u8,

    pub fn deinit(self: Dirs, allocator: Allocator) void {
        allocator.free(self.home);
        allocator.free(self.config_dir);
        allocator.free(self.data_dir);
        allocator.free(self.cache_dir);
    }
};

pub fn fromProcess(allocator: Allocator, env_map: *const std.process.Environ.Map) !Dirs {
    return resolve(allocator, platform.currentOS(), .{
        .home = env_map.get("HOME"),
        .xdg_config_home = env_map.get("XDG_CONFIG_HOME"),
        .xdg_data_home = env_map.get("XDG_DATA_HOME"),
        .xdg_cache_home = env_map.get("XDG_CACHE_HOME"),
        .appdata = env_map.get("APPDATA"),
        .localappdata = env_map.get("LOCALAPPDATA"),
        .userprofile = env_map.get("USERPROFILE"),
    });
}

pub fn resolve(allocator: Allocator, os: platform.OS, env: Env) !Dirs {
    const home = try homeDir(allocator, os, env);
    errdefer allocator.free(home);
    const config_dir = try defaultConfigDir(allocator, os, home, env);
    errdefer allocator.free(config_dir);
    const data_dir = try defaultDataDir(allocator, os, home, env);
    errdefer allocator.free(data_dir);
    const cache_dir = try defaultCacheDir(allocator, os, home, env);
    errdefer allocator.free(cache_dir);
    return .{
        .home = home,
        .config_dir = config_dir,
        .data_dir = data_dir,
        .cache_dir = cache_dir,
    };
}

pub fn configFile(allocator: Allocator, os: platform.OS, dirs: Dirs) ![]u8 {
    return path.joinDisplay(allocator, os, &.{ dirs.config_dir, "config.yaml" });
}

pub fn dataPath(allocator: Allocator, os: platform.OS, dirs: Dirs, rel: []const u8) ![]u8 {
    return path.joinDisplay(allocator, os, &.{ dirs.data_dir, rel });
}

pub fn cachePath(allocator: Allocator, os: platform.OS, dirs: Dirs, rel: []const u8) ![]u8 {
    return path.joinDisplay(allocator, os, &.{ dirs.cache_dir, rel });
}

fn homeDir(allocator: Allocator, os: platform.OS, env: Env) ![]u8 {
    return switch (os) {
        .linux, .macos => allocator.dupe(u8, env.home orelse return error.HomeNotSet),
        .windows => allocator.dupe(u8, env.userprofile orelse env.home orelse return error.HomeNotSet),
    };
}

fn defaultConfigDir(allocator: Allocator, os: platform.OS, home: []const u8, env: Env) ![]u8 {
    return switch (os) {
        .linux => if (env.xdg_config_home) |v| path.joinDisplay(allocator, os, &.{ v, "zinc" }) else path.joinDisplay(allocator, os, &.{ home, ".config", "zinc" }),
        .macos => path.joinDisplay(allocator, os, &.{ home, "Library", "Application Support", "zinc" }),
        .windows => path.joinDisplay(allocator, os, &.{ env.appdata orelse return error.AppDataNotSet, "zinc" }),
    };
}

fn defaultDataDir(allocator: Allocator, os: platform.OS, home: []const u8, env: Env) ![]u8 {
    return switch (os) {
        .linux => if (env.xdg_data_home) |v| path.joinDisplay(allocator, os, &.{ v, "zinc" }) else path.joinDisplay(allocator, os, &.{ home, ".local", "share", "zinc" }),
        .macos => path.joinDisplay(allocator, os, &.{ home, "Library", "Application Support", "zinc" }),
        .windows => path.joinDisplay(allocator, os, &.{ env.appdata orelse return error.AppDataNotSet, "zinc" }),
    };
}

fn defaultCacheDir(allocator: Allocator, os: platform.OS, home: []const u8, env: Env) ![]u8 {
    return switch (os) {
        .linux => if (env.xdg_cache_home) |v| path.joinDisplay(allocator, os, &.{ v, "zinc" }) else path.joinDisplay(allocator, os, &.{ home, ".cache", "zinc" }),
        .macos => path.joinDisplay(allocator, os, &.{ home, "Library", "Caches", "zinc" }),
        .windows => path.joinDisplay(allocator, os, &.{ env.localappdata orelse return error.LocalAppDataNotSet, "zinc", "Cache" }),
    };
}
