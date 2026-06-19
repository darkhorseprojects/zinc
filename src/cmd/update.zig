const std = @import("std");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const platform = @import("../platform/mod.zig");
const http = @import("../update/http.zig");
const proc = @import("../io/process.zig");
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
    if (!opts.check) {
        const exe_path = try std.process.executablePathAlloc(io, allocator);
        defer allocator.free(exe_path);
        if (try packageManagerOwner(allocator, io, exe_path)) |owner| {
            defer owner.deinit(allocator);
            try files.writeAllOut("Zinc is managed by ");
            try files.writeAllOut(owner.manager);
            try files.writeAllOut(".\nUse: ");
            try files.writeAllOut(owner.command);
            try files.writeAllOut("\n");
            return error.PackageManagerOwned;
        }
    }
    if (!opts.check) try progress("resolve", 0, "checking target");
    const target_version = if (std.mem.eql(u8, opts.requested_version, "latest"))
        try latestVersion(allocator, io)
    else
        try allocator.dupe(u8, opts.requested_version);
    if (!opts.check) try progress("resolve", 1, target_version);
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
        try files.writeAllOut("\nZinc update\n");
        try files.writeAllOut("  ");
        try files.writeAllOut(version.current);
        try files.writeAllOut(" -> ");
        try files.writeAllOut(target_version);
        try files.writeAllOut("\n\n");
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

    try progress("download", 0, asset);
    try http.fetchFile(allocator, io, asset_url, pending_path, max_binary_bytes);
    try progress("download", 1, asset);

    try progress("verify", 0, "sha256");
    try verifyChecksum(allocator, io, checksum_url, pending_path);
    try progress("verify", 1, "sha256");

    if (platform.currentOS() != .windows) {
        try progress("prepare", 0, "permissions");
        try makeExecutable(io, pending_path);
        try progress("prepare", 1, "permissions");
    }

    try progress("install", 0, "binary");
    if (platform.currentOS() == .windows) {
        try replaceOnWindows(allocator, io, exe_path, pending_path, asset);
        try progress("install", 1, "staged");
        try files.writeAllOut("\nZinc update staged. It will finish after this process exits.\n");
    } else {
        try std.Io.Dir.renameAbsolute(pending_path, exe_path, io);
        try progress("install", 1, "binary");
        try files.writeAllOut("\nZinc updated.\n");
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

fn progress(label: []const u8, complete: usize, detail: []const u8) !void {
    const width: usize = 24;
    const filled: usize = if (complete == 0) 0 else width;
    try files.writeAllOut("  ");
    try files.writeAllOut(label);
    var pad = label.len;
    while (pad < 10) : (pad += 1) try files.writeAllOut(" ");
    try files.writeAllOut("[");
    var i: usize = 0;
    while (i < width) : (i += 1) try files.writeAllOut(if (i < filled) "#" else "-");
    try files.writeAllOut("] ");
    try files.writeAllOut(if (complete == 0) "  0% " else "100% ");
    try files.writeAllOut(detail);
    try files.writeAllOut("\n");
}

const Owner = struct {
    manager: []const u8,
    command: []const u8,

    fn deinit(self: Owner, allocator: Allocator) void {
        allocator.free(self.manager);
        allocator.free(self.command);
    }
};

fn packageManagerOwner(allocator: Allocator, io: std.Io, exe_path: []const u8) !?Owner {
    return switch (platform.currentOS()) {
        .linux => try linuxOwner(allocator, io, exe_path),
        .macos => try macosOwner(allocator, io, exe_path),
        .windows => try windowsOwner(allocator, io, exe_path),
    };
}

fn linuxOwner(allocator: Allocator, io: std.Io, exe_path: []const u8) !?Owner {
    if (try pacmanOwner(allocator, io, exe_path)) |pkg| {
        defer allocator.free(pkg);
        const command = if (try commandAvailable(allocator, io, "paru"))
            try std.fmt.allocPrint(allocator, "paru -Syu {s}", .{pkg})
        else if (try commandAvailable(allocator, io, "yay"))
            try std.fmt.allocPrint(allocator, "yay -Syu {s}", .{pkg})
        else
            try std.fmt.allocPrint(allocator, "sudo pacman -Syu {s}", .{pkg});
        return .{ .manager = try allocator.dupe(u8, "pacman/AUR"), .command = command };
    }
    if (try dpkgOwner(allocator, io, exe_path)) |pkg| {
        defer allocator.free(pkg);
        return .{ .manager = try allocator.dupe(u8, "apt/dpkg"), .command = try std.fmt.allocPrint(allocator, "sudo apt update && sudo apt install --only-upgrade {s}", .{pkg}) };
    }
    if (try rpmOwner(allocator, io, exe_path)) |pkg| {
        defer allocator.free(pkg);
        const command = if (try commandAvailable(allocator, io, "dnf"))
            try std.fmt.allocPrint(allocator, "sudo dnf upgrade {s}", .{pkg})
        else if (try commandAvailable(allocator, io, "zypper"))
            try std.fmt.allocPrint(allocator, "sudo zypper update {s}", .{pkg})
        else
            try std.fmt.allocPrint(allocator, "use your RPM package manager to update {s}", .{pkg});
        const manager = if (try commandAvailable(allocator, io, "zypper")) "zypper/rpm" else "dnf/rpm";
        return .{ .manager = try allocator.dupe(u8, manager), .command = command };
    }
    if (try npmOwner(allocator, io, exe_path)) |owner| return owner;
    return null;
}

fn macosOwner(allocator: Allocator, io: std.Io, exe_path: []const u8) !?Owner {
    if (try brewOwner(allocator, io, exe_path)) |owner| return owner;
    if (try npmOwner(allocator, io, exe_path)) |owner| return owner;
    return null;
}

fn windowsOwner(allocator: Allocator, io: std.Io, exe_path: []const u8) !?Owner {
    _ = io;
    const lower = try asciiLower(allocator, exe_path);
    defer allocator.free(lower);
    if (std.mem.indexOf(u8, lower, "scoop") != null) return .{ .manager = try allocator.dupe(u8, "Scoop"), .command = try allocator.dupe(u8, "scoop update zinc") };
    if (std.mem.indexOf(u8, lower, "chocolatey") != null or std.mem.indexOf(u8, lower, "choco") != null) return .{ .manager = try allocator.dupe(u8, "Chocolatey"), .command = try allocator.dupe(u8, "choco upgrade zinc") };
    if (std.mem.indexOf(u8, lower, "windowsapps") != null or std.mem.indexOf(u8, lower, "winget") != null) return .{ .manager = try allocator.dupe(u8, "winget"), .command = try allocator.dupe(u8, "winget upgrade zinc") };
    return null;
}

fn pacmanOwner(allocator: Allocator, io: std.Io, exe_path: []const u8) !?[]u8 {
    if (!try commandAvailable(allocator, io, "pacman")) return null;
    const result = proc.run(allocator, io, &.{ "pacman", "-Qo", exe_path }, null, &.{}, max_text_bytes) catch return null;
    defer result.deinit(allocator);
    if (result.code != 0) return null;
    const marker = " is owned by ";
    const start = std.mem.indexOf(u8, result.stdout, marker) orelse return null;
    const rest = result.stdout[start + marker.len ..];
    return try firstWord(allocator, rest);
}

fn dpkgOwner(allocator: Allocator, io: std.Io, exe_path: []const u8) !?[]u8 {
    if (!try commandAvailable(allocator, io, "dpkg")) return null;
    const result = proc.run(allocator, io, &.{ "dpkg", "-S", exe_path }, null, &.{}, max_text_bytes) catch return null;
    defer result.deinit(allocator);
    if (result.code != 0) return null;
    const colon = std.mem.indexOfScalar(u8, result.stdout, ':') orelse return null;
    return try allocator.dupe(u8, std.mem.trim(u8, result.stdout[0..colon], " \t\r\n"));
}

fn rpmOwner(allocator: Allocator, io: std.Io, exe_path: []const u8) !?[]u8 {
    if (!try commandAvailable(allocator, io, "rpm")) return null;
    const result = proc.run(allocator, io, &.{ "rpm", "-qf", exe_path }, null, &.{}, max_text_bytes) catch return null;
    defer result.deinit(allocator);
    if (result.code != 0) return null;
    return try firstWord(allocator, result.stdout);
}

fn brewOwner(allocator: Allocator, io: std.Io, exe_path: []const u8) !?Owner {
    if (!try commandAvailable(allocator, io, "brew")) return null;
    const result = proc.run(allocator, io, &.{ "brew", "--prefix", "zinc" }, null, &.{}, max_text_bytes) catch return null;
    defer result.deinit(allocator);
    if (result.code != 0) return null;
    const prefix = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!std.mem.startsWith(u8, exe_path, prefix)) return null;
    return .{ .manager = try allocator.dupe(u8, "Homebrew"), .command = try allocator.dupe(u8, "brew upgrade zinc") };
}

fn npmOwner(allocator: Allocator, io: std.Io, exe_path: []const u8) !?Owner {
    if (!try commandAvailable(allocator, io, "npm")) return null;
    const result = proc.run(allocator, io, &.{ "npm", "prefix", "-g" }, null, &.{}, max_text_bytes) catch return null;
    defer result.deinit(allocator);
    if (result.code != 0) return null;
    const prefix = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!std.mem.startsWith(u8, exe_path, prefix)) return null;
    return .{ .manager = try allocator.dupe(u8, "npm"), .command = try allocator.dupe(u8, "npm update -g @darkhorseprojects/zinc") };
}

fn commandAvailable(allocator: Allocator, io: std.Io, command: []const u8) !bool {
    if (platform.currentOS() == .windows) return false;
    const shell_command = try std.fmt.allocPrint(allocator, "command -v {s}", .{command});
    defer allocator.free(shell_command);
    const result = proc.run(allocator, io, &.{ "sh", "-c", shell_command }, null, &.{}, 32 * 1024) catch return false;
    defer result.deinit(allocator);
    return result.code == 0;
}

fn firstWord(allocator: Allocator, text: []const u8) !?[]u8 {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    return if (it.next()) |word| try allocator.dupe(u8, word) else null;
}

fn asciiLower(allocator: Allocator, text: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, text);
    for (out) |*ch| ch.* = std.ascii.toLower(ch.*);
    return out;
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

    return try parseTagName(allocator, bytes);
}

fn parseTagName(allocator: Allocator, json: []const u8) ![]u8 {
    var scanner = std.json.Scanner.initCompleteInput(allocator, json);
    defer scanner.deinit();

    while (true) {
        const token = try scanner.nextAlloc(allocator, .alloc_if_needed);
        defer freeToken(allocator, token);

        switch (token) {
            .string, .allocated_string => |key| {
                if (!std.mem.eql(u8, key, "tag_name")) continue;
                const value = try scanner.nextAlloc(allocator, .alloc_if_needed);
                defer freeToken(allocator, value);
                return switch (value) {
                    .string => |tag| try allocator.dupe(u8, tag),
                    .allocated_string => |tag| try allocator.dupe(u8, tag),
                    else => error.InvalidReleaseJson,
                };
            },
            .end_of_document => return error.MissingReleaseTag,
            else => {},
        }
    }
}

fn freeToken(allocator: Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_string, .allocated_number => |bytes| allocator.free(bytes),
        else => {},
    }
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
