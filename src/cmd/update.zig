const std = @import("std");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const platform = @import("../platform/mod.zig");
const http = @import("../update/http.zig");
const version = @import("../version.zig");

const Allocator = std.mem.Allocator;

const repo = "darkhorseprojects/zinc";
const max_binary_bytes = 100 * 1024 * 1024;
const max_text_bytes = 2 * 1024 * 1024;

const Options = struct {
    check: bool = false,
    yes: bool = false,
    requested_version: []const u8 = "latest",
};

pub fn runUpdate(allocator: Allocator, io: std.Io, args: []const []const u8) !void {
    const opts = try parseArgs(args);
    const target_version = if (std.mem.eql(u8, opts.requested_version, "latest"))
        try latestVersion(allocator, io)
    else
        try allocator.dupe(u8, opts.requested_version);
    defer allocator.free(target_version);

    if (opts.check) {
        try printVersions(target_version);
        return;
    }
    if (std.mem.eql(u8, target_version, version.current)) {
        try files.writeAllOut("Zinc is already current.\n");
        return;
    }
    if (!opts.yes) {
        try files.writeAllOut("Updating Zinc ");
        try files.writeAllOut(version.current);
        try files.writeAllOut(" -> ");
        try files.writeAllOut(target_version);
        try files.writeAllOut("\n");
    }

    const asset = try assetName();
    const asset_url = try releaseAssetUrl(allocator, target_version, asset);
    defer allocator.free(asset_url);
    const checksum_url = try std.fmt.allocPrint(allocator, "{s}.sha256", .{asset_url});
    defer allocator.free(checksum_url);

    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);

    const pending_path = try siblingPath(allocator, exe_path, asset, "pending");
    defer allocator.free(pending_path);

    try http.fetchFile(allocator, io, asset_url, pending_path, max_binary_bytes);
    try verifyChecksum(allocator, io, checksum_url, pending_path);
    if (platform.currentOS() != .windows) try makeExecutable(io, pending_path);

    if (platform.currentOS() == .windows) {
        try replaceOnWindows(allocator, io, exe_path, pending_path, asset);
        try files.writeAllOut("Zinc update staged. It will finish after this process exits.\n");
    } else {
        try std.Io.Dir.renameAbsolute(pending_path, exe_path, io);
        try files.writeAllOut("Zinc updated.\n");
    }
}

pub fn runInternalReplace(allocator: Allocator, io: std.Io, args: []const []const u8) !void {
    _ = allocator;
    if (args.len != 2) return error.InvalidReplaceArgs;
    const from = args[0];
    const to = args[1];

    var attempts: usize = 0;
    while (attempts < 120) : (attempts += 1) {
        std.Io.Dir.deleteFileAbsolute(io, to) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                try pause(io);
                continue;
            },
        };
        std.Io.Dir.renameAbsolute(from, to, io) catch {
            try pause(io);
            continue;
        };
        return;
    }
    return error.ReplaceTimedOut;
}

fn parseArgs(args: []const []const u8) !Options {
    var opts = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            opts.check = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            opts.yes = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            i += 1;
            if (i >= args.len) return error.MissingVersion;
            opts.requested_version = args[i];
        } else {
            return error.UnknownUpdateOption;
        }
    }
    return opts;
}

fn latestVersion(allocator: Allocator, io: std.Io) ![]u8 {
    const url = "https://api.github.com/repos/" ++ repo ++ "/releases/latest";
    const bytes = try http.fetchBytes(allocator, io, url, max_text_bytes);
    defer allocator.free(bytes);

    const Response = struct { tag_name: []const u8 };
    var parsed = try std.json.parseFromSlice(Response, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return try allocator.dupe(u8, parsed.value.tag_name);
}

fn printVersions(target_version: []const u8) !void {
    try files.writeAllOut("installed: ");
    try files.writeAllOut(version.current);
    try files.writeAllOut("\nlatest:    ");
    try files.writeAllOut(target_version);
    try files.writeAllOut("\n");
}

fn assetName() ![]const u8 {
    const builtin = @import("builtin");
    return switch (platform.currentOS()) {
        .linux => if (builtin.cpu.arch == .x86_64) "zn-x86_64-linux" else error.UnsupportedUpdatePlatform,
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => "zn-x86_64-macos",
            .aarch64 => "zn-aarch64-macos",
            else => error.UnsupportedUpdatePlatform,
        },
        .windows => if (builtin.cpu.arch == .x86_64) "zn-x86_64-windows.exe" else error.UnsupportedUpdatePlatform,
    };
}

fn releaseAssetUrl(allocator: Allocator, tag: []const u8, asset: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "https://github.com/{s}/releases/download/{s}/{s}", .{ repo, tag, asset });
}

fn verifyChecksum(allocator: Allocator, io: std.Io, checksum_url: []const u8, file_path: []const u8) !void {
    const checksum_file = try http.fetchBytes(allocator, io, checksum_url, max_text_bytes);
    defer allocator.free(checksum_file);

    const expected = firstToken(checksum_file) orelse return error.InvalidChecksumFile;
    if (expected.len != 64) return error.InvalidChecksumFile;

    const bytes = try files.readLimited(allocator, file_path, max_binary_bytes);
    defer allocator.free(bytes);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.ascii.eqlIgnoreCase(expected, &actual)) return error.ChecksumMismatch;
}

fn firstToken(bytes: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, bytes, " \t\r\n");
    return it.next();
}

fn makeExecutable(io: std.Io, path: []const u8) !void {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);
    try file.setPermissions(io, @enumFromInt(0o755));
}

fn replaceOnWindows(allocator: Allocator, io: std.Io, exe_path: []const u8, pending_path: []const u8, asset: []const u8) !void {
    const updater_name = try std.fmt.allocPrint(allocator, "{s}.updater", .{asset});
    defer allocator.free(updater_name);
    const updater_path = try layout.tempRunPath(allocator, updater_name);
    defer allocator.free(updater_path);

    const exe_bytes = try files.readLimited(allocator, exe_path, max_binary_bytes);
    defer allocator.free(exe_bytes);
    if (std.fs.path.dirname(updater_path)) |dir| try files.mkdirP(dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = updater_path, .data = exe_bytes });

    const argv = [_][]const u8{ updater_path, "internal-replace", pending_path, exe_path };
    _ = try std.process.spawn(io, .{ .argv = &argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
}

fn siblingPath(allocator: Allocator, path: []const u8, name: []const u8, role: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(path) orelse ".";
    return try std.fmt.allocPrint(allocator, "{s}{c}.{s}.{s}", .{ dir, std.fs.path.sep, name, role });
}

fn pause(io: std.Io) !void {
    try std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(250) }, io);
}
