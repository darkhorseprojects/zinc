const std = @import("std");
const Store = @import("store.zig").Store;
const layout = @import("../io/layout.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub const UriType = enum {
    run,
    run_stdout,
    run_stderr,
    run_artifact,
    run_action,
    doc,
    package,
    package_shape,
    approval,
};

pub const ParsedUri = struct {
    type: UriType,
    id: []const u8,
    extra: ?[]const u8 = null,

    pub fn deinit(self: ParsedUri, allocator: Allocator) void {
        allocator.free(self.id);
        if (self.extra) |e| allocator.free(e);
    }
};

pub fn parse(allocator: Allocator, raw_uri: []const u8) !ParsedUri {
    const prefix = "zinc://";
    if (!std.mem.startsWith(u8, raw_uri, prefix)) return error.InvalidScheme;
    const path = raw_uri[prefix.len..];

    var it = std.mem.splitScalar(u8, path, '/');
    const category = it.next() orelse return error.InvalidUriCategory;
    const id = it.next() orelse return error.InvalidUriId;

    if (std.mem.eql(u8, category, "run")) {
        const sub1 = it.next();
        if (sub1 == null) {
            return ParsedUri{ .type = .run, .id = try allocator.dupe(u8, id) };
        }
        if (std.mem.eql(u8, sub1.?, "stdout")) {
            return ParsedUri{ .type = .run_stdout, .id = try allocator.dupe(u8, id) };
        }
        if (std.mem.eql(u8, sub1.?, "stderr")) {
            return ParsedUri{ .type = .run_stderr, .id = try allocator.dupe(u8, id) };
        }
        if (std.mem.eql(u8, sub1.?, "artifact")) {
            const art_name = it.next() orelse return error.InvalidArtifactUri;
            return ParsedUri{ .type = .run_artifact, .id = try allocator.dupe(u8, id), .extra = try allocator.dupe(u8, art_name) };
        }
        if (std.mem.eql(u8, sub1.?, "action")) {
            const seq_str = it.next() orelse return error.InvalidActionUri;
            return ParsedUri{ .type = .run_action, .id = try allocator.dupe(u8, id), .extra = try allocator.dupe(u8, seq_str) };
        }
    } else if (std.mem.eql(u8, category, "doc")) {
        return ParsedUri{ .type = .doc, .id = try allocator.dupe(u8, id) };
    } else if (std.mem.eql(u8, category, "package")) {
        const sub1 = it.next();
        if (sub1 == null) {
            return ParsedUri{ .type = .package, .id = try allocator.dupe(u8, id) };
        }
        if (std.mem.eql(u8, sub1.?, "shape")) {
            const shape_name = it.next() orelse return error.InvalidPackageShapeUri;
            return ParsedUri{ .type = .package_shape, .id = try allocator.dupe(u8, id), .extra = try allocator.dupe(u8, shape_name) };
        }
    } else if (std.mem.eql(u8, category, "approval")) {
        return ParsedUri{ .type = .approval, .id = try allocator.dupe(u8, id) };
    }

    return error.UnknownUriPattern;
}

pub fn resolveRead(allocator: Allocator, raw_uri: []const u8) ![]u8 {
    const parsed = try parse(allocator, raw_uri);
    defer parsed.deinit(allocator);

    switch (parsed.type) {
        .run_stdout => {
            // Check workspace runs first
            if (try layout.workspacePath(allocator, "")) |ws| {
                defer allocator.free(ws);
                const ws_path = try std.fmt.allocPrint(allocator, ".zinc/tmp/runs/{s}/stdout", .{parsed.id});
                defer allocator.free(ws_path);
                if (files.existsPath(ws_path)) {
                    return try files.readLimited(allocator, ws_path, 64 * 1024 * 1024);
                }
            }
            // Check global runs
            const g_path = try layout.globalPath(allocator, "");
            defer allocator.free(g_path);
            const global_path = try std.fmt.allocPrint(allocator, "{s}/tmp/runs/{s}/stdout", .{ g_path, parsed.id });
            defer allocator.free(global_path);
            if (files.existsPath(global_path)) {
                return try files.readLimited(allocator, global_path, 64 * 1024 * 1024);
            }
            return error.RunOutputNotFound;
        },
        .run_stderr => {
            if (try layout.workspacePath(allocator, "")) |ws| {
                defer allocator.free(ws);
                const ws_path = try std.fmt.allocPrint(allocator, ".zinc/tmp/runs/{s}/stderr", .{parsed.id});
                defer allocator.free(ws_path);
                if (files.existsPath(ws_path)) {
                    return try files.readLimited(allocator, ws_path, 64 * 1024 * 1024);
                }
            }
            const g_path = try layout.globalPath(allocator, "");
            defer allocator.free(g_path);
            const global_path = try std.fmt.allocPrint(allocator, "{s}/tmp/runs/{s}/stderr", .{ g_path, parsed.id });
            defer allocator.free(global_path);
            if (files.existsPath(global_path)) {
                return try files.readLimited(allocator, global_path, 64 * 1024 * 1024);
            }
            return error.RunOutputNotFound;
        },
        .run_artifact => {
            const art_name = parsed.extra.?;
            if (try layout.workspacePath(allocator, "")) |ws| {
                defer allocator.free(ws);
                const ws_path = try std.fmt.allocPrint(allocator, ".zinc/tmp/runs/{s}/artifacts/{s}", .{ parsed.id, art_name });
                defer allocator.free(ws_path);
                if (files.existsPath(ws_path)) {
                    return try files.readLimited(allocator, ws_path, 64 * 1024 * 1024);
                }
            }
            const g_path = try layout.globalPath(allocator, "");
            defer allocator.free(g_path);
            const global_path = try std.fmt.allocPrint(allocator, "{s}/tmp/runs/{s}/artifacts/{s}", .{ g_path, parsed.id, art_name });
            defer allocator.free(global_path);
            if (files.existsPath(global_path)) {
                return try files.readLimited(allocator, global_path, 64 * 1024 * 1024);
            }
            return error.RunArtifactNotFound;
        },
        else => return error.UriNotReadable,
    }
}
