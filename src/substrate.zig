const std = @import("std");
const limbo = @import("limbo");
const layout = @import("io/layout.zig");
const files = @import("io/fs.zig");

const Allocator = std.mem.Allocator;

pub const Package = struct {
    package: []const u8,
    root: []const u8,
};

pub const Fragment = struct {
    fragment: []const u8,
    target: []const u8,
    request: []const u8,
    result: []const u8,
    time: i64,
};

pub const Choice = struct {
    choice: []const u8,
    fragment: []const u8,
};

pub const Config = struct {
    key: []const u8,
    value: []const u8,
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
        try reset(self.db, "zinc_schema", "14", &.{ "packages", "fragments", "choices", "config" });
        try self.db.exec("create table if not exists zinc_schema(version text not null)", .{});
        try self.db.exec("delete from zinc_schema", .{});
        try self.db.exec("insert into zinc_schema(version) values ('14')", .{});
        try self.db.exec("create table if not exists packages(package text primary key, root text not null)", .{});
        try self.db.exec("create table if not exists fragments(fragment text primary key, target text not null, request text not null, result text not null, time integer not null)", .{});
        try self.db.exec("create table if not exists choices(choice text primary key, fragment text not null)", .{});
        try self.db.exec("create table if not exists config(key text primary key, value text not null)", .{});
    }

    pub fn putPackage(self: *Store, row: Package) !void {
        try self.db.exec("insert into packages(package, root) values (:package, :root) on conflict(package) do update set root = excluded.root", .{ .package = limbo.text(row.package), .root = limbo.text(row.root) });
    }

    pub fn getPackage(self: *Store, package: []const u8) !?Package {
        const Row = PackageRow;
        var stmt = try self.db.prepare(struct { package: limbo.Text }, Row, "select package, root from packages where package = :package");
        defer stmt.finalize();
        try stmt.bind(.{ .package = limbo.text(package) });
        if (try stmt.step()) |row| return try clonePackage(self, row);
        return null;
    }

    pub fn listPackages(self: *Store) ![]Package {
        const Row = PackageRow;
        var stmt = try self.db.prepare(struct {}, Row, "select package, root from packages order by package asc");
        defer stmt.finalize();
        try stmt.bind(.{});
        var out: std.ArrayList(Package) = .empty;
        errdefer {
            for (out.items) |item| self.freePackage(item);
            out.deinit(self.allocator);
        }
        while (try stmt.step()) |row| try out.append(self.allocator, try clonePackage(self, row));
        return out.toOwnedSlice(self.allocator);
    }

    pub fn removePackage(self: *Store, package: []const u8) !void {
        try self.db.exec("delete from packages where package = :package", .{ .package = limbo.text(package) });
    }

    pub fn freePackage(self: *Store, row: Package) void {
        self.allocator.free(row.package);
        self.allocator.free(row.root);
    }

    pub fn putFragment(self: *Store, row: Fragment) !void {
        try self.db.exec("insert into fragments(fragment, target, request, result, time) values (:fragment, :target, :request, :result, :time) on conflict(fragment) do update set target = excluded.target, request = excluded.request, result = excluded.result, time = excluded.time", .{ .fragment = limbo.text(row.fragment), .target = limbo.text(row.target), .request = limbo.text(row.request), .result = limbo.text(row.result), .time = row.time });
    }

    pub fn getFragment(self: *Store, fragment: []const u8) !?Fragment {
        const Row = FragmentRow;
        var stmt = try self.db.prepare(struct { fragment: limbo.Text }, Row, "select fragment, target, request, result, time from fragments where fragment = :fragment");
        defer stmt.finalize();
        try stmt.bind(.{ .fragment = limbo.text(fragment) });
        if (try stmt.step()) |row| return try cloneFragment(self, row);
        return null;
    }

    pub fn listFragments(self: *Store) ![]Fragment {
        const Row = FragmentRow;
        var stmt = try self.db.prepare(struct {}, Row, "select fragment, target, request, result, time from fragments order by time desc, fragment desc");
        defer stmt.finalize();
        try stmt.bind(.{});
        var out: std.ArrayList(Fragment) = .empty;
        errdefer {
            for (out.items) |item| self.freeFragment(item);
            out.deinit(self.allocator);
        }
        while (try stmt.step()) |row| try out.append(self.allocator, try cloneFragment(self, row));
        return out.toOwnedSlice(self.allocator);
    }

    pub fn freeFragment(self: *Store, row: Fragment) void {
        self.allocator.free(row.fragment);
        self.allocator.free(row.target);
        self.allocator.free(row.request);
        self.allocator.free(row.result);
    }

    pub fn putChoice(self: *Store, row: Choice) !void {
        try self.db.exec("insert into choices(choice, fragment) values (:choice, :fragment) on conflict(choice) do update set fragment = excluded.fragment", .{ .choice = limbo.text(row.choice), .fragment = limbo.text(row.fragment) });
    }

    pub fn getChoice(self: *Store, choice: []const u8) !?Choice {
        const Row = ChoiceRow;
        var stmt = try self.db.prepare(struct { choice: limbo.Text }, Row, "select choice, fragment from choices where choice = :choice");
        defer stmt.finalize();
        try stmt.bind(.{ .choice = limbo.text(choice) });
        if (try stmt.step()) |row| return try cloneChoice(self, row);
        return null;
    }

    pub fn listChoices(self: *Store) ![]Choice {
        const Row = ChoiceRow;
        var stmt = try self.db.prepare(struct {}, Row, "select choice, fragment from choices order by choice asc");
        defer stmt.finalize();
        try stmt.bind(.{});
        var out: std.ArrayList(Choice) = .empty;
        errdefer {
            for (out.items) |item| self.freeChoice(item);
            out.deinit(self.allocator);
        }
        while (try stmt.step()) |row| try out.append(self.allocator, try cloneChoice(self, row));
        return out.toOwnedSlice(self.allocator);
    }

    pub fn freeChoice(self: *Store, row: Choice) void {
        self.allocator.free(row.choice);
        self.allocator.free(row.fragment);
    }

    pub fn putConfig(self: *Store, key: []const u8, value: []const u8) !void {
        try self.db.exec("insert into config(key, value) values (:key, :value) on conflict(key) do update set value = excluded.value", .{ .key = limbo.text(key), .value = limbo.text(value) });
    }

    pub fn getConfig(self: *Store, key: []const u8) !?[]u8 {
        const row = (try self.getConfigRow(key)) orelse return null;
        defer self.freeConfig(row);
        return try self.allocator.dupe(u8, row.value);
    }

    pub fn getConfigRow(self: *Store, key: []const u8) !?Config {
        const Row = ConfigRow;
        var stmt = try self.db.prepare(struct { key: limbo.Text }, Row, "select key, value from config where key = :key");
        defer stmt.finalize();
        try stmt.bind(.{ .key = limbo.text(key) });
        if (try stmt.step()) |row| return try cloneConfig(self, row);
        return null;
    }

    pub fn listConfig(self: *Store) ![]Config {
        const Row = ConfigRow;
        var stmt = try self.db.prepare(struct {}, Row, "select key, value from config order by key asc");
        defer stmt.finalize();
        try stmt.bind(.{});
        var out: std.ArrayList(Config) = .empty;
        errdefer {
            for (out.items) |item| self.freeConfig(item);
            out.deinit(self.allocator);
        }
        while (try stmt.step()) |row| try out.append(self.allocator, try cloneConfig(self, row));
        return out.toOwnedSlice(self.allocator);
    }

    pub fn freeConfig(self: *Store, row: Config) void {
        self.allocator.free(row.key);
        self.allocator.free(row.value);
    }
};

const PackageRow = struct { package: limbo.Text, root: limbo.Text };
const FragmentRow = struct { fragment: limbo.Text, target: limbo.Text, request: limbo.Text, result: limbo.Text, time: i64 };
const ChoiceRow = struct { choice: limbo.Text, fragment: limbo.Text };
const ConfigRow = struct { key: limbo.Text, value: limbo.Text };

fn reset(db: limbo.Database, marker: []const u8, version: []const u8, comptime tables: []const []const u8) !void {
    const Row = struct { value: limbo.Text };
    const sql = try std.fmt.allocPrint(std.heap.page_allocator, "select version from {s} limit 1", .{marker});
    defer std.heap.page_allocator.free(sql);
    var same = false;
    if (db.prepare(struct {}, Row, sql)) |stmt_raw| {
        var stmt = stmt_raw;
        defer stmt.finalize();
        try stmt.bind(.{});
        if (try stmt.step()) |row| same = std.mem.eql(u8, row.value.data, version);
    } else |_| {}
    if (same) return;

    _ = tables;
    try purgeTables(db);

    const drop = try std.fmt.allocPrint(std.heap.page_allocator, "drop table if exists {s}", .{marker});
    defer std.heap.page_allocator.free(drop);
    try db.exec(drop, .{});
}

fn purgeTables(db: limbo.Database) !void {
    const Row = struct { name: limbo.Text };
    var stmt = try db.prepare(struct {}, Row, "select name from sqlite_schema where type = 'table' and name not like 'sqlite_%'");
    defer stmt.finalize();
    try stmt.bind(.{});
    while (try stmt.step()) |row| {
        const name = try quotedIdentifier(row.name.data);
        defer std.heap.page_allocator.free(name);
        const sql = try std.fmt.allocPrint(std.heap.page_allocator, "drop table if exists {s}", .{name});
        defer std.heap.page_allocator.free(sql);
        try db.exec(sql, .{});
    }
}

fn quotedIdentifier(name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(std.heap.page_allocator);
    try out.append(std.heap.page_allocator, '"');
    for (name) |c| {
        if (c == '"') try out.append(std.heap.page_allocator, '"');
        try out.append(std.heap.page_allocator, c);
    }
    try out.append(std.heap.page_allocator, '"');
    return out.toOwnedSlice(std.heap.page_allocator);
}

fn clonePackage(store: *Store, row: PackageRow) !Package {
    return .{ .package = try dupeText(store.allocator, row.package), .root = try dupeText(store.allocator, row.root) };
}

fn cloneFragment(store: *Store, row: FragmentRow) !Fragment {
    return .{ .fragment = try dupeText(store.allocator, row.fragment), .target = try dupeText(store.allocator, row.target), .request = try dupeText(store.allocator, row.request), .result = try dupeText(store.allocator, row.result), .time = row.time };
}

fn cloneChoice(store: *Store, row: ChoiceRow) !Choice {
    return .{ .choice = try dupeText(store.allocator, row.choice), .fragment = try dupeText(store.allocator, row.fragment) };
}

fn cloneConfig(store: *Store, row: ConfigRow) !Config {
    return .{ .key = try dupeText(store.allocator, row.key), .value = try dupeText(store.allocator, row.value) };
}

fn dupeText(allocator: Allocator, value: limbo.Text) ![]u8 {
    return try allocator.dupe(u8, value.data);
}
