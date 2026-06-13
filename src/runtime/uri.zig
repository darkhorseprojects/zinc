const std = @import("std");
const Store = @import("store.zig").Store;
const files = @import("../io/fs.zig");
const pkg_index = @import("../pkg/index.zig");

const Allocator = std.mem.Allocator;

pub const Root = enum { runs, docs, packages, config };

pub const ParsedUri = struct {
    root: Root,
    id: []const u8,
    path: []const u8,

    pub fn deinit(self: ParsedUri, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
    }
};

pub fn parse(allocator: Allocator, raw_uri: []const u8) !ParsedUri {
    const prefix = "zinc://";
    if (!std.mem.startsWith(u8, raw_uri, prefix)) return error.InvalidScheme;
    const body = raw_uri[prefix.len..];
    var it = std.mem.splitScalar(u8, body, '/');
    const root_text = it.next() orelse return error.InvalidUri;
    const id = it.next() orelse return error.InvalidUri;
    const root: Root = if (std.mem.eql(u8, root_text, "runs")) .runs else if (std.mem.eql(u8, root_text, "docs")) .docs else if (std.mem.eql(u8, root_text, "packages")) .packages else if (std.mem.eql(u8, root_text, "config")) .config else return error.UnknownUriRoot;

    const rest_start = prefix.len + root_text.len + 1 + id.len;
    const rest = if (raw_uri.len > rest_start + 1) raw_uri[rest_start + 1 ..] else "";
    return .{ .root = root, .id = try allocator.dupe(u8, id), .path = try allocator.dupe(u8, rest) };
}

pub fn resolveRead(allocator: Allocator, store: *Store, raw_uri: []const u8) ![]u8 {
    const parsed = try parse(allocator, raw_uri);
    defer parsed.deinit(allocator);

    switch (parsed.root) {
        .runs => return try readRunPath(allocator, store, parsed.id, parsed.path),
        .docs => {
            if (parsed.path.len != 0 and !std.mem.eql(u8, parsed.path, "source")) return error.DocPathNotReadable;
            const doc = (try store.getDoc(parsed.id)) orelse return error.DocNotFound;
            defer store.freeDoc(doc);
            return try allocator.dupe(u8, doc.source_payload);
        },
        .packages => {
            const pkg = (try store.getPackage(parsed.id)) orelse return error.PackageNotFound;
            defer store.freePackage(pkg);
            const root = pkg.path orelse return error.PackagePathMissing;
            if (parsed.path.len == 0 or std.mem.eql(u8, parsed.path, "manifest")) {
                const manifest_path = try std.fs.path.join(allocator, &.{ root, "zinc.pkg.yaml" });
                defer allocator.free(manifest_path);
                return try files.readLimited(allocator, manifest_path, 10 * 1024 * 1024);
            }
            const asset_path = try pkg_index.resolveAsset(allocator, store, parsed.id, parsed.path);
            defer allocator.free(asset_path);
            return try files.readLimited(allocator, asset_path, 64 * 1024 * 1024);
        },
        .config => return error.ConfigPathNotReadable,
    }
}

fn readRunPath(allocator: Allocator, store: *Store, run_id: []const u8, path: []const u8) ![]u8 {
    if (path.len == 0) return runSummary(allocator, store, run_id);
    if (std.mem.startsWith(u8, path, "values/")) {
        const row = (try store.getRunValue(run_id, path)) orelse return error.RunValueNotFound;
        defer store.freeRunValue(row);
        return try allocator.dupe(u8, row.payload);
    }
    if (std.mem.startsWith(u8, path, "parts/")) {
        const parts = try store.listRunParts(run_id);
        defer {
            for (parts) |part| store.freeRunPart(part);
            allocator.free(parts);
        }
        for (parts) |part| if (std.mem.eql(u8, part.path, path)) return try std.fmt.allocPrint(allocator, "part: {s}\npath: {s}\nstatus: {s}\n", .{ part.name, part.path, part.status });
        return error.RunPartNotFound;
    }
    if (std.mem.startsWith(u8, path, "actions/")) {
        const row = (try store.getActionOutput(run_id, path)) orelse return error.ActionOutputNotFound;
        defer store.freeActionOutput(row);
        return try allocator.dupe(u8, row.payload);
    }
    if (std.mem.eql(u8, path, "plan") or std.mem.startsWith(u8, path, "artifacts/") or std.mem.startsWith(u8, path, "reasoning/")) {
        const row = (try store.getRunText(run_id, path)) orelse return error.RunTextNotFound;
        defer store.freeRunText(row);
        return try allocator.dupe(u8, row.payload);
    }
    return error.RunPathNotReadable;
}

fn runSummary(allocator: Allocator, store: *Store, run_id: []const u8) ![]u8 {
    const run = (try store.getRun(run_id)) orelse return error.RunNotFound;
    defer store.freeRun(run);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "run: {s}\nstatus: {s}\ndoc: {s}\n", .{ run.id, run.status orelse "unknown", run.doc_id orelse "none" });
    return out.toOwnedSlice(allocator);
}
