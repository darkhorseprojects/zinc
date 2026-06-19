const std = @import("std");
const turso = @import("turso");
const layout = @import("io/layout.zig");
const files = @import("io/fs.zig");

const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const raw = turso.raw;

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
    database: *const raw.turso_database_t,
    connection: *raw.turso_connection_t,

    pub fn open(allocator: Allocator) !Store {
        const global_dir = try layout.globalPath(allocator, "");
        defer allocator.free(global_dir);
        try files.mkdirP(global_dir);

        const path = try layout.globalPath(allocator, "zinc.db");
        defer allocator.free(path);
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var config = std.mem.zeroes(raw.turso_database_config_t);
        config.path = path_z.ptr;

        var database: ?*const raw.turso_database_t = null;
        try turso.check(raw.turso_database_new(&config, &database, null));
        errdefer if (database) |db| raw.turso_database_deinit(db);
        try turso.check(raw.turso_database_open(database.?, null));

        var connection: ?*raw.turso_connection_t = null;
        try turso.check(raw.turso_database_connect(database.?, &connection, null));
        errdefer if (connection) |conn| raw.turso_connection_deinit(conn);
        raw.turso_connection_set_busy_timeout_ms(connection.?, 5000);

        var store = Store{ .allocator = allocator, .database = database.?, .connection = connection.? };
        try store.schema();
        return store;
    }

    pub fn close(self: *Store) void {
        raw.turso_connection_deinit(self.connection);
        raw.turso_database_deinit(self.database);
    }

    fn schema(self: *Store) !void {
        try self.exec("create table if not exists meta(key text primary key, value text not null)");
        try self.exec("create table if not exists packages(name text primary key, version text not null, uri text not null, root text not null, at integer not null)");

        const schema_value = try self.metaValue("schema");
        defer if (schema_value) |value| self.allocator.free(value);
        if (schema_value == null or !std.mem.eql(u8, schema_value.?, "3")) {
            try self.exec("drop table if exists events");
            try self.exec("drop table if exists packets");
            try self.exec("drop table if exists steps");
            try self.exec("drop table if exists runs");
            try self.exec("delete from meta where key = 'schema'");
        }

        try self.exec("create table if not exists runs(id text primary key, current text, meta blob not null)");
        try self.exec("create table if not exists steps(id text primary key, run text not null, body blob not null)");
        try self.exec("create table if not exists packets(id text primary key, step text not null, bytes blob not null)");
        try self.exec("insert into meta(key, value) values ('schema', '3') on conflict(key) do update set value = excluded.value");
    }

    pub fn createRun(self: *Store, meta: []const u8) ![]const u8 {
        const id = try self.hashedId("run", meta, nowNs());
        errdefer self.allocator.free(id);
        var statement = try self.prepare("insert into runs(id, current, meta) values (?1, '', ?2) on conflict(id) do nothing");
        defer statement.deinit();
        try statement.bindText(1, id);
        try statement.bindBlob(2, meta);
        try statement.execute();
        return id;
    }

    pub fn recordStep(self: *Store, run: []const u8, parent: ?[]const u8, body: []const u8, packets: []const StepPacket) ![]const u8 {
        const seed = try std.fmt.allocPrint(self.allocator, "{s}\n{s}\n{d}", .{ run, body, nowNs() });
        defer self.allocator.free(seed);
        const step = try self.hashedId("step", seed, nowNs());
        errdefer self.allocator.free(step);

        try self.exec("begin");
        errdefer self.exec("rollback") catch {};

        var step_statement = try self.prepare("insert into steps(id, run, body) values (?1, ?2, ?3)");
        defer step_statement.deinit();
        try step_statement.bindText(1, step);
        try step_statement.bindText(2, run);
        try step_statement.bindBlob(3, body);
        try step_statement.execute();

        for (packets) |packet| {
            var packet_statement = try self.prepare("insert into packets(id, step, bytes) values (?1, ?2, ?3) on conflict(id) do nothing");
            defer packet_statement.deinit();
            try packet_statement.bindText(1, packet.id);
            try packet_statement.bindText(2, step);
            try packet_statement.bindBlob(3, packet.bytes);
            try packet_statement.execute();
        }

        var current_statement = try self.prepare("update runs set current = ?1 where id = ?2");
        defer current_statement.deinit();
        try current_statement.bindText(1, step);
        try current_statement.bindText(2, run);
        try current_statement.execute();

        try self.exec("commit");
        _ = parent;
        return step;
    }

    pub fn packetId(self: *Store, bytes: []const u8) ![]const u8 {
        return self.hashedId("packet", bytes, 0);
    }

    pub fn setCurrent(self: *Store, run: []const u8, step: []const u8) !void {
        var statement = try self.prepare("update runs set current = ?1 where id = ?2");
        defer statement.deinit();
        try statement.bindText(1, step);
        try statement.bindText(2, run);
        try statement.execute();
    }

    pub fn readRuns(self: *Store) ![]u8 {
        var statement = try self.prepare("select id, current, meta from runs order by id asc");
        defer statement.deinit();
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "runs:\n");
        while (try statement.step()) {
            const id = statement.text(0);
            const current = statement.text(1);
            const meta = statement.text(2);
            try out.print(self.allocator, "  {s}:\n    current: {s}\n    meta: |\n", .{ id, current });
            try appendIndented(self.allocator, &out, meta, 6);
        }
        return out.toOwnedSlice(self.allocator);
    }

    pub fn readRun(self: *Store, id: []const u8) ![]u8 {
        var statement = try self.prepare("select current, meta from runs where id = ?1");
        defer statement.deinit();
        try statement.bindText(1, id);
        if (!try statement.step()) return error.RunNotFound;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try out.print(self.allocator, "id: {s}\ncurrent: {s}\nmeta: |\n", .{ id, statement.text(0) });
        try appendIndented(self.allocator, &out, statement.text(1), 2);
        return out.toOwnedSlice(self.allocator);
    }

    pub fn readRunCurrent(self: *Store, id: []const u8) ![]u8 {
        var statement = try self.prepare("select current from runs where id = ?1");
        defer statement.deinit();
        try statement.bindText(1, id);
        if (!try statement.step()) return error.RunNotFound;
        return try std.fmt.allocPrint(self.allocator, "current: zinc://steps/{s}\n", .{statement.text(0)});
    }

    pub fn readRunSteps(self: *Store, id: []const u8) ![]u8 {
        var statement = try self.prepare("select id from steps where run = ?1 order by id asc");
        defer statement.deinit();
        try statement.bindText(1, id);
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "steps:\n");
        while (try statement.step()) try out.print(self.allocator, "  - zinc://steps/{s}\n", .{statement.text(0)});
        return out.toOwnedSlice(self.allocator);
    }

    pub fn stepRun(self: *Store, id: []const u8) ![]u8 {
        var statement = try self.prepare("select run from steps where id = ?1");
        defer statement.deinit();
        try statement.bindText(1, id);
        if (!try statement.step()) return error.StepNotFound;
        return try self.allocator.dupe(u8, statement.text(0));
    }

    pub fn readStep(self: *Store, id: []const u8) ![]u8 {
        var statement = try self.prepare("select run, body from steps where id = ?1");
        defer statement.deinit();
        try statement.bindText(1, id);
        if (!try statement.step()) return error.StepNotFound;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);
        try out.print(self.allocator, "id: {s}\nrun: zinc://runs/{s}\nbody: |\n", .{ id, statement.text(0) });
        try appendIndented(self.allocator, &out, statement.text(1), 2);
        return out.toOwnedSlice(self.allocator);
    }

    pub fn readPacket(self: *Store, id: []const u8) ![]u8 {
        var statement = try self.prepare("select bytes from packets where id = ?1");
        defer statement.deinit();
        try statement.bindText(1, id);
        if (!try statement.step()) return error.PacketNotFound;
        return try self.allocator.dupe(u8, statement.blob(0));
    }

    pub fn putPackage(self: *Store, row: Package) !void {
        var statement = try self.prepare("insert into packages(name, version, uri, root, at) values (?1, ?2, ?3, ?4, ?5) on conflict(name) do update set version = excluded.version, uri = excluded.uri, root = excluded.root, at = excluded.at");
        defer statement.deinit();
        try statement.bindText(1, row.package);
        try statement.bindText(2, row.version);
        try statement.bindText(3, row.uri);
        try statement.bindText(4, row.root);
        try statement.bindInt(5, now());
        try statement.execute();
    }

    pub fn getPackage(self: *Store, package: []const u8) !?Package {
        var statement = try self.prepare("select name, version, uri, root from packages where name = ?1");
        defer statement.deinit();
        try statement.bindText(1, package);
        if (!try statement.step()) return null;
        return .{
            .package = try self.allocator.dupe(u8, statement.text(0)),
            .version = try self.allocator.dupe(u8, statement.text(1)),
            .uri = try self.allocator.dupe(u8, statement.text(2)),
            .root = try self.allocator.dupe(u8, statement.text(3)),
        };
    }

    pub fn listPackages(self: *Store) ![]Package {
        var statement = try self.prepare("select name, version, uri, root from packages order by name asc");
        defer statement.deinit();
        var out = std.ArrayList(Package).empty;
        errdefer {
            for (out.items) |*pkg| pkg.deinit(self.allocator);
            out.deinit(self.allocator);
        }
        while (try statement.step()) {
            try out.append(self.allocator, .{
                .package = try self.allocator.dupe(u8, statement.text(0)),
                .version = try self.allocator.dupe(u8, statement.text(1)),
                .uri = try self.allocator.dupe(u8, statement.text(2)),
                .root = try self.allocator.dupe(u8, statement.text(3)),
            });
        }
        return out.toOwnedSlice(self.allocator);
    }

    pub fn removePackage(self: *Store, package: []const u8) !void {
        var statement = try self.prepare("delete from packages where name = ?1");
        defer statement.deinit();
        try statement.bindText(1, package);
        try statement.execute();
    }

    pub fn freePackage(self: *Store, row: Package) void { row.deinit(self.allocator); }

    fn exec(self: *Store, sql: [:0]const u8) !void {
        var statement = try self.prepare(sql);
        defer statement.deinit();
        try statement.execute();
    }

    fn metaValue(self: *Store, key: []const u8) !?[]u8 {
        var statement = try self.prepare("select value from meta where key = ?1");
        defer statement.deinit();
        try statement.bindText(1, key);
        if (!try statement.step()) return null;
        return try self.allocator.dupe(u8, statement.text(0));
    }

    fn prepare(self: *Store, sql: [:0]const u8) !Statement {
        var statement: ?*raw.turso_statement_t = null;
        try turso.check(raw.turso_connection_prepare_single(self.connection, sql.ptr, &statement, null));
        return .{ .statement = statement.? };
    }

    fn hashedId(self: *Store, prefix: []const u8, bytes: []const u8, salt: i128) ![]const u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(bytes);
        if (salt != 0) {
            var salt_buf: [48]u8 = undefined;
            const salt_text = try std.fmt.bufPrint(&salt_buf, "{d}", .{salt});
            h.update(salt_text);
        }
        var digest: [32]u8 = undefined;
        h.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        return try std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ prefix, hex[0..] });
    }
};

pub const StepPacket = struct {
    id: []const u8,
    bytes: []const u8,
};

const Statement = struct {
    statement: *raw.turso_statement_t,

    fn deinit(self: *Statement) void { raw.turso_statement_deinit(self.statement); }

    fn bindText(self: *Statement, position: usize, value: []const u8) !void {
        try turso.check(raw.turso_statement_bind_positional_text(self.statement, position, value.ptr, value.len));
    }

    fn bindBlob(self: *Statement, position: usize, value: []const u8) !void {
        try turso.check(raw.turso_statement_bind_positional_blob(self.statement, position, value.ptr, value.len));
    }

    fn bindInt(self: *Statement, position: usize, value: i64) !void {
        try turso.check(raw.turso_statement_bind_positional_int(self.statement, position, value));
    }

    fn execute(self: *Statement) !void { _ = try turso.executeBlocking(self.statement); }

    fn step(self: *Statement) !bool {
        const status = try turso.stepBlocking(self.statement);
        if (status == raw.TURSO_DONE) return false;
        if (status == raw.TURSO_ROW) return true;
        try turso.check(status);
        return false;
    }

    fn text(self: *Statement, index: usize) []const u8 {
        const len = raw.turso_statement_row_value_bytes_count(self.statement, index);
        if (len <= 0) return "";
        const ptr = raw.turso_statement_row_value_bytes_ptr(self.statement, index) orelse return "";
        return ptr[0..@intCast(len)];
    }

    fn blob(self: *Statement, index: usize) []const u8 { return self.text(index); }
};

const Timeval = extern struct { tv_sec: isize, tv_usec: isize };
extern fn gettimeofday(tv: *Timeval, tz: ?*anyopaque) callconv(.c) c_int;

fn nowNs() i128 {
    if (builtin.target.os.tag == .windows) {
        const epoch_ns = std.time.epoch.windows * std.time.ns_per_s;
        const ns = @as(i96, std.os.windows.ntdll.RtlGetSystemTimePrecise()) * 100 + epoch_ns;
        return ns;
    }
    var tv: Timeval = undefined;
    if (gettimeofday(&tv, null) != 0) return 0;
    return @as(i128, tv.tv_sec) * std.time.us_per_s + tv.tv_usec;
}

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

fn appendIndented(allocator: Allocator, out: *std.ArrayList(u8), value: []const u8, spaces: usize) !void {
    var it = std.mem.splitScalar(u8, value, '\n');
    while (it.next()) |line| {
        var i: usize = 0;
        while (i < spaces) : (i += 1) try out.append(allocator, ' ');
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
}
