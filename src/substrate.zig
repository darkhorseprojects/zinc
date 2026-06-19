const std = @import("std");
const limbo = @import("limbo");
const layout = @import("io/layout.zig");
const files = @import("io/fs.zig");

const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Package = struct {
    package: []const u8,
    version: []const u8,
    root: []const u8,
    uri: []const u8,

    pub fn deinit(self: *const Package, allocator: Allocator) void {
        allocator.free(self.package);
        allocator.free(self.version);
        allocator.free(self.root);
        allocator.free(self.uri);
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

    pub fn close(self: *Store) void { self.db.close(); }

    fn schema(self: *Store) !void {
        try self.db.exec("create table if not exists meta(key text primary key, value text not null)", .{});
        try self.db.exec("create table if not exists packages(name text primary key, version text not null, uri text not null, root text not null, at integer not null)", .{});
        try self.db.exec("create table if not exists packets(id text primary key, size integer not null, sha256 text not null, bytes blob, tail text, uri text, preserve integer not null, at integer not null)", .{});
        try self.db.exec("create table if not exists events(id text primary key, run text not null, advance integer not null, path text not null, surface text not null, request text, response text, outputs text, preserve integer not null, at integer not null)", .{});
        try self.db.exec("insert into meta(key, value) values ('schema', '2') on conflict(key) do update set value = excluded.value", .{});
    }

    pub fn putPacket(self: *Store, bytes: []const u8, preserve: bool, packet_limit: usize) ![]const u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(bytes);
        var digest: [32]u8 = undefined;
        h.final(&digest);
        const sha = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.bytesToHex(digest, .lower)});
        errdefer self.allocator.free(sha);
        const id = try std.fmt.allocPrint(self.allocator, "packet:{s}", .{sha});
        errdefer self.allocator.free(id);
        const limit = @max(packet_limit, 1);
        const tail = if (bytes.len > limit) bytes[bytes.len - limit ..] else bytes;
        try self.db.exec(
            "insert into packets(id, size, sha256, bytes, tail, uri, preserve, at) values (:id, :size, :sha, :bytes, :tail, :uri, :preserve, :at) on conflict(id) do nothing",
            .{
                .id = limbo.text(id),
                .size = @as(i64, @intCast(bytes.len)),
                .sha = limbo.text(sha),
                .bytes = if (preserve) limbo.blob(bytes) else limbo.blob(""),
                .tail = limbo.text(tail),
                .uri = limbo.text(""),
                .preserve = @as(i64, if (preserve) 1 else 0),
                .at = now(),
            },
        );
        self.allocator.free(sha);
        return id;
    }

    pub fn recordEvent(self: *Store, run: []const u8, advance: usize, path: []const u8, surface: []const u8, request: ?[]const u8, response: []const u8, outputs: []const u8, preserve: bool, packet_limit: usize) !void {
        const request_packet = if (request) |r| try self.putPacket(r, preserve, packet_limit) else null;
        defer if (request_packet) |id| self.allocator.free(id);
        const response_packet = try self.putPacket(response, preserve, packet_limit);
        defer self.allocator.free(response_packet);
        const event_id = try eventId(self.allocator, run, advance, path, surface, request_packet, response_packet, now());
        defer self.allocator.free(event_id);
        try self.db.exec(
            "insert into events(id, run, advance, path, surface, request, response, outputs, preserve, at) values (:id, :run, :advance, :path, :surface, :request, :response, :outputs, :preserve, :at) on conflict(id) do nothing",
            .{
                .id = limbo.text(event_id),
                .run = limbo.text(run),
                .advance = @as(i64, @intCast(advance)),
                .path = limbo.text(path),
                .surface = limbo.text(surface),
                .request = limbo.text(request_packet orelse ""),
                .response = limbo.text(response_packet),
                .outputs = limbo.text(outputs),
                .preserve = @as(i64, if (preserve) 1 else 0),
                .at = now(),
            },
        );

    }

    pub fn putPackage(self: *Store, row: Package) !void {
        try self.db.exec(
            "insert into packages(name, version, uri, root, at) values (:name, :version, :uri, :root, :at) on conflict(name) do update set version = excluded.version, uri = excluded.uri, root = excluded.root, at = excluded.at",
            .{ .name = limbo.text(row.package), .version = limbo.text(row.version), .uri = limbo.text(row.uri), .root = limbo.text(row.root), .at = now() },
        );
    }

    pub fn getPackage(self: *Store, package: []const u8) !?Package {
        const Row = struct { name: limbo.Text, version: limbo.Text, uri: limbo.Text, root: limbo.Text };
        var stmt = try self.db.prepare(struct { name: limbo.Text }, Row, "select name, version, uri, root from packages where name = :name");
        defer stmt.finalize();
        try stmt.bind(.{ .name = limbo.text(package) });
        const row = (try stmt.step()) orelse return null;
        return .{
            .package = try self.allocator.dupe(u8, row.name.data),
            .version = try self.allocator.dupe(u8, row.version.data),
            .uri = try self.allocator.dupe(u8, row.uri.data),
            .root = try self.allocator.dupe(u8, row.root.data),
        };
    }

    pub fn listPackages(self: *Store) ![]Package {
        const Row = struct { name: limbo.Text };
        var stmt = try self.db.prepare(struct {}, Row, "select name from packages order by name asc");
        defer stmt.finalize();
        try stmt.bind(.{});
        var out = std.ArrayList(Package).empty;
        errdefer {
            for (out.items) |*pkg| pkg.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        while (try stmt.step()) |row| if (try self.getPackage(row.name.data)) |pkg| try out.append(self.allocator, pkg);
        return out.toOwnedSlice(self.allocator);
    }

    pub fn removePackage(self: *Store, package: []const u8) !void {
        try self.db.exec("delete from packages where name = :package", .{ .package = limbo.text(package) });
    }

    pub fn freePackage(self: *Store, row: Package) void { row.deinit(self.allocator); }
};

const Timeval = extern struct { tv_sec: isize, tv_usec: isize };
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

fn eventId(allocator: Allocator, run: []const u8, advance: usize, path: []const u8, surface: []const u8, request: ?[]const u8, response: []const u8, at: i64) ![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(run);
    h.update("\n");
    const advance_text = try std.fmt.allocPrint(allocator, "{d}", .{advance});
    defer allocator.free(advance_text);
    h.update(advance_text);
    h.update("\n");
    h.update(path);
    h.update("\n");
    h.update(surface);
    h.update("\n");
    h.update(request orelse "");
    h.update("\n");
    h.update(response);
    h.update("\n");
    const at_text = try std.fmt.allocPrint(allocator, "{d}", .{at});
    defer allocator.free(at_text);
    h.update(at_text);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return try std.fmt.allocPrint(allocator, "event:{s}", .{std.fmt.bytesToHex(digest, .lower)});
}
