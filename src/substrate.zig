const std = @import("std");
const limbo = @import("limbo");
const layout = @import("io/layout.zig");
const files = @import("io/fs.zig");
const serde = @import("serde");

const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const blob_threshold = 1024 * 1024;

pub const Package = struct {
    package: []const u8,
    version: []const u8,
    root: []const u8,
    source_uri: ?[]const u8,
    source_ref: ?[]const u8,
    source_path: ?[]const u8,

    pub fn deinit(self: *const Package, allocator: Allocator) void {
        allocator.free(self.package);
        allocator.free(self.version);
        allocator.free(self.root);
        if (self.source_uri) |v| allocator.free(v);
        if (self.source_ref) |v| allocator.free(v);
        if (self.source_path) |v| allocator.free(v);
    }
};

pub const Store = struct {
    allocator: Allocator,
    db: limbo.Database,

    pub fn open(allocator: Allocator) !Store {
        const global_dir = try layout.globalPath(allocator, "");
        defer allocator.free(global_dir);
        try files.mkdirP(global_dir);

        const path = try layout.globalPath(allocator, "zinc.db");
        defer allocator.free(path);
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var db = try limbo.Database.open(.{ .path = path_z });
        errdefer db.close();

        var store = Store{ .allocator = allocator, .db = db };
        try store.schema();
        return store;
    }

    pub fn close(self: *Store) void {
        self.db.close();
    }

    fn schema(self: *Store) !void {
        try self.db.exec("create table if not exists lineage_meta(key text primary key, value text not null)", .{});
        try self.db.exec("create table if not exists lineage_blobs(id text primary key, size integer not null, bytes blob, path text, at integer not null)", .{});
        try self.db.exec("create table if not exists lineage_nodes(id text primary key, kind text not null, key text not null, parent text, request text, output text not null, at integer not null)", .{});
        try self.db.exec("create index if not exists lineage_nodes_by_kind_key on lineage_nodes(kind, key)", .{});
        try self.db.exec("create table if not exists lineage_heads(kind text not null, key text not null, node text not null, at integer not null, primary key (kind, key))", .{});
        try self.db.exec("insert into lineage_meta(key, value) values ('schema', '1') on conflict(key) do update set value = excluded.value", .{});
    }

    pub fn putBlob(self: *Store, bytes: []const u8) ![]const u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(bytes);
        var digest: [32]u8 = undefined;
        h.final(&digest);
        const id = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.bytesToHex(digest, .lower)});

        var path: ?[]const u8 = null;
        var blob_bytes: ?[]const u8 = null;
        if (bytes.len > blob_threshold) {
            const dir = try layout.globalPath(self.allocator, "tmp/lineage_blobs");
            defer self.allocator.free(dir);
            try files.mkdirP(dir);
            const blob_path = try std.fs.path.join(self.allocator, &.{ dir, id });
            try files.write(blob_path, bytes);
            path = blob_path;
        } else {
            blob_bytes = try self.allocator.dupe(u8, bytes);
        }

        try self.db.exec(
            "insert into lineage_blobs(id, size, bytes, path, at) values (:id, :size, :bytes, :path, :at) on conflict(id) do nothing",
            .{
                .id = limbo.text(id),
                .size = @as(i64, @intCast(bytes.len)),
                .bytes = if (blob_bytes) |b| limbo.blob(b) else limbo.blob(""),
                .path = limbo.text(path orelse ""),
                .at = now(),
            },
        );
        if (blob_bytes) |b| self.allocator.free(b);
        return id;
    }

    pub fn advance(self: *Store, kind: []const u8, key: []const u8, parent: ?[]const u8, request: ?[]const u8, output: []const u8) ![]const u8 {
        const request_blob = if (request) |r| try self.putBlob(r) else null;
        defer if (request_blob) |id| self.allocator.free(id);
        const output_blob = try self.putBlob(output);
        defer self.allocator.free(output_blob);
        const parent_id = parent orelse (try self.currentNode(kind, key));
        defer if (parent_id) |id| self.allocator.free(id);
        const node_id = try nodeId(self.allocator, kind, key, parent_id, request_blob, output_blob, now());
        defer self.allocator.free(node_id);
        try self.db.exec(
            "insert into lineage_nodes(id, kind, key, parent, request, output, at) values (:id, :kind, :key, :parent, :request, :output, :at) on conflict(id) do nothing",
            .{
                .id = limbo.text(node_id),
                .kind = limbo.text(kind),
                .key = limbo.text(key),
                .parent = limbo.text(parent_id orelse ""),
                .request = limbo.text(request_blob orelse ""),
                .output = limbo.text(output_blob),
                .at = now(),
            },
        );
        try self.moveHead(kind, key, node_id);
        return node_id;
    }

    pub fn moveHead(self: *Store, kind: []const u8, key: []const u8, node: []const u8) !void {
        try self.db.exec(
            "insert into lineage_heads(kind, key, node, at) values (:kind, :key, :node, :at) on conflict(kind, key) do update set node = excluded.node, at = excluded.at",
            .{ .kind = limbo.text(kind), .key = limbo.text(key), .node = limbo.text(node), .at = now() },
        );
    }

    pub fn currentNode(self: *Store, kind: []const u8, key: []const u8) !?[]const u8 {
        const Row = struct { node: limbo.Text };
        var stmt = try self.db.prepare(struct { kind: limbo.Text, key: limbo.Text }, Row, "select node from lineage_heads where kind = :kind and key = :key");
        defer stmt.finalize();
        try stmt.bind(.{ .kind = limbo.text(kind), .key = limbo.text(key) });
        if (try stmt.step()) |row| return try self.allocator.dupe(u8, row.node.data);
        return null;
    }

    pub fn putPackage(self: *Store, row: Package) !void {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.allocator);
        try out.print(self.allocator, "name: {s}\nversion: {s}\nroot: {s}\n", .{ row.package, row.version, row.root });
        if (row.source_uri) |uri| try out.print(self.allocator, "source:\n  uri: {s}\n", .{uri});
        if (row.source_ref) |ref| try out.print(self.allocator, "  ref: {s}\n", .{ref});
        if (row.source_path) |path| try out.print(self.allocator, "  path: {s}\n", .{path});
        _ = try self.advance("package", row.package, null, null, out.items);
    }

    pub fn getPackage(self: *Store, package: []const u8) !?Package {
        const node = (try self.currentNode("package", package)) orelse return null;
        defer self.allocator.free(node);
        const row = (try self.currentOutput("package", package)) orelse return null;
        defer self.allocator.free(row);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const root = try serde.yaml.parse(arena.allocator(), row);
        const source = valueField(&root, "source");
        return .{
            .package = try self.allocator.dupe(u8, stringField(&root, "name") orelse package),
            .version = try self.allocator.dupe(u8, stringField(&root, "version") orelse ""),
            .root = try self.allocator.dupe(u8, stringField(&root, "root") orelse ""),
            .source_uri = try dupOptional(self.allocator, sourceField(source, "uri")),
            .source_ref = try dupOptional(self.allocator, sourceField(source, "ref")),
            .source_path = try dupOptional(self.allocator, sourceField(source, "path")),
        };
    }

    pub fn listPackages(self: *Store) ![]Package {
        const Row = struct { key: limbo.Text };
        var stmt = try self.db.prepare(struct {}, Row, "select key from lineage_heads where kind = 'package' order by key asc");
        defer stmt.finalize();
        try stmt.bind(.{});
        var out = std.ArrayList(Package).empty;
        errdefer {
            for (out.items) |*pkg| pkg.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        while (try stmt.step()) |row| {
            if (try self.getPackage(row.key.data)) |pkg| try out.append(self.allocator, pkg);
        }
        return out.toOwnedSlice(self.allocator);
    }

    pub fn removePackage(self: *Store, package: []const u8) !void {
        try self.db.exec("delete from lineage_heads where kind = 'package' and key = :package", .{ .package = limbo.text(package) });
    }

    pub fn freePackage(self: *Store, row: Package) void {
        row.deinit(self.allocator);
    }

    fn currentOutput(self: *Store, kind: []const u8, key: []const u8) !?[]u8 {
        const node = (try self.currentNode(kind, key)) orelse return null;
        defer self.allocator.free(node);
        const Row = struct { output: limbo.Text };
        var stmt = try self.db.prepare(struct { node: limbo.Text }, Row, "select output from lineage_nodes where id = :node");
        defer stmt.finalize();
        try stmt.bind(.{ .node = limbo.text(node) });
        const blob_id = (try stmt.step()) orelse return null;
        return try self.blobBytes(blob_id.output.data);
    }

    fn blobBytes(self: *Store, id: []const u8) !?[]u8 {
        const Row = struct { bytes: limbo.Blob, path: limbo.Text };
        var stmt = try self.db.prepare(struct { id: limbo.Text }, Row, "select bytes, path from lineage_blobs where id = :id");
        defer stmt.finalize();
        try stmt.bind(.{ .id = limbo.text(id) });
        const row = (try stmt.step()) orelse return null;
        if (row.bytes.data.len != 0) return try self.allocator.dupe(u8, row.bytes.data);
        if (row.path.data.len == 0) return try self.allocator.dupe(u8, "");
        return try files.readLimited(self.allocator, row.path.data, 64 * 1024 * 1024);
    }
};

const Timeval = extern struct {
    tv_sec: isize,
    tv_usec: isize,
};

extern fn gettimeofday(tv: *Timeval, tz: ?*anyopaque) callconv(.c) c_int;

fn now() i64 {
    if (builtin.target.os.tag == .windows) {
        const epoch_ns = std.time.epoch.windows * std.time.ns_per_s;
        const ns = @as(i96, std.os.windows.ntdll.RtlGetSystemTimePrecise()) * 100 + epoch_ns;
        return @intCast(@divTrunc(ns, std.time.ns_per_s));
    }

    var tv: Timeval = undefined;
    if (gettimeofday(&tv, null) != 0) return 0;
    return @intCast(tv.tv_sec);
}

fn nodeId(allocator: Allocator, kind: []const u8, key: []const u8, parent: ?[]const u8, request: ?[]const u8, output: []const u8, at: i64) ![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(kind);
    h.update("\n");
    h.update(key);
    h.update("\n");
    h.update(parent orelse "");
    h.update("\n");
    h.update(request orelse "");
    h.update("\n");
    h.update(output);
    h.update("\n");
    const tail = try std.fmt.allocPrint(allocator, "{d}", .{at});
    defer allocator.free(tail);
    h.update(tail);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(digest, .lower)});
}

fn stringField(root: *const serde.yaml.Value, key: []const u8) ?[]const u8 {
    if (root.* != .mapping) return null;
    var it = root.mapping.iterator();
    while (it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, key)) return switch (entry.value_ptr.*) {
        .string => |s| s,
        else => null,
    };
    return null;
}

fn valueField(root: *const serde.yaml.Value, key: []const u8) ?*const serde.yaml.Value {
    if (root.* != .mapping) return null;
    var it = root.mapping.iterator();
    while (it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, key)) return entry.value_ptr;
    return null;
}

fn sourceField(source: ?*const serde.yaml.Value, key: []const u8) ?[]const u8 {
    const node = source orelse return null;
    if (node.* != .mapping) return null;
    return stringField(node, key);
}

fn dupOptional(allocator: Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |v| try allocator.dupe(u8, v) else null;
}
