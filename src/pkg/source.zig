const std = @import("std");
const config = @import("../config/mod.zig");
const platform = @import("../platform.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub const Source = struct {
    raw: []const u8,
    kind: enum { directory, git },
    url: []u8,
    subdir: []u8,
    ref: []u8,

    pub fn deinit(self: Source, allocator: Allocator) void {
        allocator.free(self.url);
        allocator.free(self.subdir);
        allocator.free(self.ref);
    }
};

pub fn stageSource(allocator: Allocator, io: std.Io, source: Source) ![]u8 {
    switch (source.kind) {
        .directory => return allocator.dupe(u8, source.url),
        .git => {
            const base = try tempPath(allocator, io, "zinc-pkg-");
            errdefer allocator.free(base);
            if (source.ref.len == 0) {
                try run(allocator, io, &.{ "git", "clone", "--depth", "1", source.url, base });
            } else {
                try run(allocator, io, &.{ "git", "clone", source.url, base });
                try run(allocator, io, &.{ "git", "-C", base, "checkout", "--detach", source.ref });
            }
            return base;
        },
    }
}

pub fn parseSource(allocator: Allocator, raw: []const u8) !Source {
    const split = splitRef(raw);
    const body = split.body;
    if (std.mem.startsWith(u8, body, "github:")) return parseGithub(allocator, body["github:".len..], raw, split.ref);
    if (std.mem.startsWith(u8, body, "git+")) return .{ .raw = raw, .kind = .git, .url = try allocator.dupe(u8, body["git+".len..]), .subdir = try allocator.dupe(u8, ""), .ref = try allocator.dupe(u8, split.ref) };
    if (std.mem.endsWith(u8, body, ".git") or std.mem.startsWith(u8, body, "https://github.com/") or std.mem.startsWith(u8, body, "http://github.com/")) return parseGitUrl(allocator, body, raw, split.ref);
    if (split.ref.len != 0) return error.InvalidPackageSource;
    return .{ .raw = raw, .kind = .directory, .url = try allocator.dupe(u8, raw), .subdir = try allocator.dupe(u8, ""), .ref = try allocator.dupe(u8, "") };
}

pub const RefSplit = struct { body: []const u8, ref: []const u8 };

pub fn splitRef(raw: []const u8) RefSplit {
    if (std.mem.lastIndexOfScalar(u8, raw, '#')) |idx| return .{ .body = raw[0..idx], .ref = raw[idx + 1 ..] };
    return .{ .body = raw, .ref = "" };
}

fn parseGithub(allocator: Allocator, spec: []const u8, raw: []const u8, ref: []const u8) !Source {
    var parts = std.mem.splitScalar(u8, spec, '/');
    const user = parts.next() orelse return error.InvalidPackageSource;
    const repo = parts.next() orelse return error.InvalidPackageSource;
    if (user.len == 0 or repo.len == 0) return error.InvalidPackageSource;
    var sub: std.ArrayList(u8) = .empty;
    defer sub.deinit(allocator);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (sub.items.len != 0) try sub.append(allocator, '/');
        try sub.appendSlice(allocator, part);
    }
    return .{ .raw = raw, .kind = .git, .url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}.git", .{ user, repo }), .subdir = try sub.toOwnedSlice(allocator), .ref = try allocator.dupe(u8, ref) };
}

fn parseGitUrl(allocator: Allocator, body: []const u8, raw: []const u8, ref: []const u8) !Source {
    const marker = ".git/";
    if (std.mem.indexOf(u8, body, marker)) |idx| {
        return .{ .raw = raw, .kind = .git, .url = try allocator.dupe(u8, body[0 .. idx + 4]), .subdir = try allocator.dupe(u8, body[idx + marker.len ..]), .ref = try allocator.dupe(u8, ref) };
    }
    return .{ .raw = raw, .kind = .git, .url = try allocator.dupe(u8, body), .subdir = try allocator.dupe(u8, ""), .ref = try allocator.dupe(u8, ref) };
}

fn tempPath(allocator: Allocator, io: std.Io, prefix: []const u8) ![]u8 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    const tmp_dir = config.getEnv("TMPDIR") orelse config.getEnv("TEMP") orelse config.getEnv("TMP") orelse "/tmp";
    const filename = try std.fmt.allocPrint(allocator, "{s}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ prefix, bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7] });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ tmp_dir, filename });
}

fn run(allocator: Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("command failed: {s}\n{s}\n", .{ argv[0], result.stderr });
        return error.PackageCommandFailed;
    }
}
