const std = @import("std");
const limbo = @import("limbo");
const layout = @import("../io/layout.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub const circuitry_docs = struct {
    id: []const u8,
    path: ?[]const u8,
    name: ?[]const u8,
    source_payload: []const u8,
    updated_at: i64,
};

pub const circuitry_doc_values = struct {
    id: []const u8,
    doc_id: []const u8,
    path: []const u8,
    order_index: i64,
    name: []const u8,
    type_label: ?[]const u8,
    direction: []const u8,
};

pub const circuitry_doc_parts = struct {
    id: []const u8,
    doc_id: []const u8,
    path: []const u8,
    order_index: i64,
    name: []const u8,
    shape: ?[]const u8,
    model: ?[]const u8,
    instructions: ?[]const u8,
};

pub const circuitry_doc_bindings = struct {
    id: []const u8,
    doc_id: []const u8,
    path: []const u8,
    part_id: []const u8,
    side: []const u8,
    local_name: ?[]const u8,
    value_name: []const u8,
    type_label: ?[]const u8,
};

pub const circuitry_doc_diagnostics = struct {
    id: []const u8,
    doc_id: []const u8,
    path: []const u8,
    severity: []const u8,
    kind: []const u8,
    message: []const u8,
};

pub const runs = struct {
    id: []const u8,
    doc_id: ?[]const u8,
    status: ?[]const u8,
    started_at: ?i64,
    finished_at: ?i64,
};

pub const actions = struct {
    id: []const u8,
    run_id: ?[]const u8,
    path: []const u8,
    seq: i64,
    action: ?[]const u8,
    cwd: ?[]const u8,
    status: ?[]const u8,
    approval: ?[]const u8,
    metadata_json: ?[]const u8,
};

pub const action_outputs = struct {
    id: []const u8,
    action_id: []const u8,
    run_id: []const u8,
    path: []const u8,
    stream: []const u8,
    payload: []const u8,
    bytes: i64,
    truncated: i64,
};

pub const approvals = struct {
    id: []const u8,
    run_id: ?[]const u8,
    kind: ?[]const u8,
    subject: ?[]const u8,
    decision: ?[]const u8,
    created_at: ?i64,
};

pub const run_values = struct {
    id: []const u8,
    run_id: []const u8,
    path: []const u8,
    name: []const u8,
    type_label: ?[]const u8,
    origin: ?[]const u8,
    producer_part_path: ?[]const u8,
    payload: []const u8,
};

pub const run_parts = struct {
    id: []const u8,
    run_id: []const u8,
    path: []const u8,
    doc_part_id: []const u8,
    name: []const u8,
    status: []const u8,
};

pub const run_text = struct {
    id: []const u8,
    run_id: []const u8,
    path: []const u8,
    role: []const u8,
    payload: []const u8,
};

pub const run_plan_steps = struct {
    id: []const u8,
    run_id: []const u8,
    path: []const u8,
    part_path: []const u8,
    order_index: i64,
    required: i64,
    status: []const u8,
    reason: ?[]const u8,
};

pub const packages = struct {
    name: []const u8,
    version: ?[]const u8,
    source: ?[]const u8,
    scope: ?[]const u8,
    path: ?[]const u8,
    status: ?[]const u8,
    installed_at: ?i64,
    checked_at: ?i64,
};

pub const package_sources = struct {
    package_name: []const u8,
    kind: []const u8,
    url: []const u8,
    ref: []const u8,
    path: []const u8,
    rev: ?[]const u8,
};

pub const package_assets = struct {
    package_name: []const u8,
    path: []const u8,
    file_path: []const u8,
    metadata_json: ?[]const u8,
};

pub const package_scripts = struct {
    package_name: []const u8,
    path: []const u8,
    file_path: []const u8,
};

pub const package_dependencies = struct {
    package_name: []const u8,
    alias: []const u8,
    package_spec: []const u8,
    about: ?[]const u8,
};

pub const Store = struct {
    allocator: Allocator,
    global_db: limbo.Database,
    workspace_db: limbo.Database,
    has_workspace: bool,

    pub fn open(allocator: Allocator) !Store {
        const global_dir = try layout.globalPath(allocator, "");
        defer allocator.free(global_dir);
        try files.mkdirP(global_dir);

        const global_db_path = try layout.globalPath(allocator, "zinc.db");
        defer allocator.free(global_db_path);
        const global_db_path_z = try allocator.dupeZ(u8, global_db_path);
        defer allocator.free(global_db_path_z);
        var global_db = try limbo.Database.open(.{ .path = global_db_path_z });
        errdefer global_db.close();

        var workspace_db = global_db;
        var has_workspace = false;

        if (try layout.workspacePath(allocator, "")) |ws_dir| {
            defer allocator.free(ws_dir);
            try files.mkdirP(ws_dir);

            if (try layout.workspacePath(allocator, "zinc.db")) |ws_db_path| {
                defer allocator.free(ws_db_path);
                const ws_db_path_z = try allocator.dupeZ(u8, ws_db_path);
                defer allocator.free(ws_db_path_z);
                workspace_db = try limbo.Database.open(.{ .path = ws_db_path_z });
                has_workspace = true;
            }
        }

        var store = Store{
            .allocator = allocator,
            .global_db = global_db,
            .workspace_db = workspace_db,
            .has_workspace = has_workspace,
        };

        try store.ensureSchema();
        return store;
    }

    pub fn close(self: *Store) void {
        self.global_db.close();
        if (self.has_workspace) {
            self.workspace_db.close();
        }
    }

    fn ensureSchema(self: *Store) !void {
        try self.ensureGlobalSchema();
        try self.ensureWorkspaceSchema();
    }

    fn ensureGlobalSchema(self: *Store) !void {
        try resetIfWrongSchema(self.global_db, "zinc_global_schema", "7", &.{
            "package_dependencies", "package_scripts", "package_assets", "package_sources", "packages", "config",
        });
        try self.global_db.exec("create table if not exists zinc_global_schema(version text not null)", .{});
        try self.global_db.exec("delete from zinc_global_schema", .{});
        try self.global_db.exec("insert into zinc_global_schema(version) values ('7')", .{});
        try self.global_db.exec("create table if not exists packages(name text primary key, version text, source text, scope text, path text, status text, installed_at integer, checked_at integer)", .{});
        try self.global_db.exec("create table if not exists package_sources(package_name text primary key, kind text not null, url text not null, ref text not null, path text not null, rev text)", .{});
        try self.global_db.exec("create table if not exists package_assets(package_name text not null, path text not null, file_path text not null, metadata_json text, primary key(package_name, path))", .{});
        try self.global_db.exec("create table if not exists package_scripts(package_name text not null, path text not null, file_path text not null, primary key(package_name, path))", .{});
        try self.global_db.exec("create table if not exists package_dependencies(package_name text not null, alias text not null, package_spec text not null, about text, primary key(package_name, alias))", .{});
        try self.global_db.exec("create table if not exists config(key text primary key, value text)", .{});
    }

    fn ensureWorkspaceSchema(self: *Store) !void {
        try resetIfWrongSchema(self.workspace_db, "zinc_workspace_schema", "7", &.{
            "action_outputs",            "actions",                "approvals",           "run_plan_steps",       "run_text",       "run_parts", "run_values", "runs",
            "circuitry_doc_diagnostics", "circuitry_doc_bindings", "circuitry_doc_parts", "circuitry_doc_values", "circuitry_docs", "config",
        });
        try self.workspace_db.exec("create table if not exists zinc_workspace_schema(version text not null)", .{});
        try self.workspace_db.exec("delete from zinc_workspace_schema", .{});
        try self.workspace_db.exec("insert into zinc_workspace_schema(version) values ('7')", .{});
        try self.workspace_db.exec("create table if not exists circuitry_docs(id text primary key, path text, name text, source_payload blob not null, updated_at integer not null)", .{});
        try self.workspace_db.exec("create table if not exists circuitry_doc_values(id text primary key, doc_id text not null, path text not null, order_index integer not null, name text not null, type_label text, direction text not null)", .{});
        try self.workspace_db.exec("create table if not exists circuitry_doc_parts(id text primary key, doc_id text not null, path text not null, order_index integer not null, name text not null, shape text, model text, instructions text)", .{});
        try self.workspace_db.exec("create table if not exists circuitry_doc_bindings(id text primary key, doc_id text not null, path text not null, part_id text not null, side text not null, local_name text, value_name text not null, type_label text)", .{});
        try self.workspace_db.exec("create table if not exists circuitry_doc_diagnostics(id text primary key, doc_id text not null, path text not null, severity text not null, kind text not null, message text not null)", .{});
        try self.workspace_db.exec("create table if not exists runs(id text primary key, doc_id text not null, status text not null, started_at integer, finished_at integer)", .{});
        try self.workspace_db.exec("create table if not exists actions(id text primary key, run_id text, path text not null, seq integer, action text, cwd text, status text, approval text, metadata_json text)", .{});
        try self.workspace_db.exec("create table if not exists action_outputs(id text primary key, action_id text not null, run_id text not null, path text not null, stream text not null, payload blob not null, bytes integer not null, truncated integer not null)", .{});
        try self.workspace_db.exec("create table if not exists approvals(id text primary key, run_id text, kind text, subject text, decision text, created_at integer)", .{});
        try self.workspace_db.exec("create table if not exists run_values(id text primary key, run_id text not null, path text not null, name text not null, type_label text, origin text, producer_part_path text, payload blob not null)", .{});
        try self.workspace_db.exec("create table if not exists run_parts(id text primary key, run_id text not null, path text not null, doc_part_id text not null, name text not null, status text not null)", .{});
        try self.workspace_db.exec("create table if not exists run_text(id text primary key, run_id text not null, path text not null, role text not null, payload blob not null)", .{});
        try self.workspace_db.exec("create table if not exists run_plan_steps(id text primary key, run_id text not null, path text not null, part_path text not null, order_index integer not null, required integer not null, status text not null, reason text)", .{});
        try self.workspace_db.exec("create table if not exists config(key text primary key, value text)", .{});
    }

    fn resetIfWrongSchema(db: limbo.Database, marker: []const u8, version: []const u8, comptime tables: []const []const u8) !void {
        const Row = struct { value: limbo.Text };
        const sql = try std.fmt.allocPrint(std.heap.page_allocator, "select version from {s} limit 1", .{marker});
        defer std.heap.page_allocator.free(sql);
        var matches = false;
        if (db.prepare(struct {}, Row, sql)) |stmt_raw| {
            var stmt = stmt_raw;
            defer stmt.finalize();
            try stmt.bind(.{});
            if (try stmt.step()) |row| matches = std.mem.eql(u8, row.value.data, version);
        } else |_| {}
        if (matches) return;
        inline for (tables) |table| {
            const drop = "drop table if exists " ++ table;
            try db.exec(drop, .{});
        }
        const drop_marker = try std.fmt.allocPrint(std.heap.page_allocator, "drop table if exists {s}", .{marker});
        defer std.heap.page_allocator.free(drop_marker);
        try db.exec(drop_marker, .{});
    }

    // --- Config ---
    pub fn setConfig(self: *Store, key: []const u8, value: []const u8) !void {
        try self.global_db.exec(
            "insert into config(key, value) values (:key, :value) on conflict(key) do update set value = excluded.value",
            .{ .key = limbo.text(key), .value = limbo.text(value) },
        );
    }

    pub fn getConfig(self: *Store, key: []const u8) !?[]const u8 {
        const Row = struct { value: limbo.Text };
        var stmt = try self.global_db.prepare(struct { key: limbo.Text }, Row, "select value from config where key = :key");
        defer stmt.finalize();
        try stmt.bind(.{ .key = limbo.text(key) });
        if (try stmt.step()) |row| {
            return try self.allocator.dupe(u8, row.value.data);
        }
        return null;
    }

    // --- Circuitry Docs ---
    pub fn insertDoc(self: *Store, doc: circuitry_docs) !void {
        try self.workspace_db.exec(
            "insert into circuitry_docs(id, path, name, source_payload, updated_at) values (:id, :path, :name, :source_payload, :updated_at) on conflict(id) do update set path=excluded.path, name=excluded.name, source_payload=excluded.source_payload, updated_at=excluded.updated_at",
            .{
                .id = limbo.text(doc.id),
                .path = if (doc.path) |p| limbo.text(p) else null,
                .name = if (doc.name) |n| limbo.text(n) else null,
                .source_payload = limbo.blob(doc.source_payload),
                .updated_at = doc.updated_at,
            },
        );
    }

    pub fn getDoc(self: *Store, id: []const u8) !?circuitry_docs {
        const Row = struct {
            id: limbo.Text,
            path: ?limbo.Text,
            name: ?limbo.Text,
            source_payload: limbo.Blob,
            updated_at: i64,
        };
        var stmt = try self.workspace_db.prepare(struct { id: limbo.Text }, Row, "select id, path, name, source_payload, updated_at from circuitry_docs where id = :id");
        defer stmt.finalize();
        try stmt.bind(.{ .id = limbo.text(id) });
        if (try stmt.step()) |row| {
            return circuitry_docs{
                .id = try self.allocator.dupe(u8, row.id.data),
                .path = if (row.path) |p| try self.allocator.dupe(u8, p.data) else null,
                .name = if (row.name) |n| try self.allocator.dupe(u8, n.data) else null,
                .source_payload = try self.allocator.dupe(u8, row.source_payload.data),
                .updated_at = row.updated_at,
            };
        }
        return null;
    }

    pub fn freeDoc(self: *Store, doc: circuitry_docs) void {
        self.allocator.free(doc.id);
        if (doc.path) |p| self.allocator.free(p);
        if (doc.name) |n| self.allocator.free(n);
        self.allocator.free(doc.source_payload);
    }

    pub fn clearDocFacts(self: *Store, doc_id: []const u8) !void {
        try self.workspace_db.exec("delete from circuitry_doc_values where doc_id = :doc_id", .{ .doc_id = limbo.text(doc_id) });
        try self.workspace_db.exec("delete from circuitry_doc_parts where doc_id = :doc_id", .{ .doc_id = limbo.text(doc_id) });
        try self.workspace_db.exec("delete from circuitry_doc_bindings where doc_id = :doc_id", .{ .doc_id = limbo.text(doc_id) });
        try self.workspace_db.exec("delete from circuitry_doc_diagnostics where doc_id = :doc_id", .{ .doc_id = limbo.text(doc_id) });
    }

    pub fn insertDocValue(self: *Store, row: circuitry_doc_values) !void {
        try self.workspace_db.exec(
            "insert into circuitry_doc_values(id, doc_id, path, order_index, name, type_label, direction) values (:id, :doc_id, :path, :order_index, :name, :type_label, :direction) on conflict(id) do update set path=excluded.path, order_index=excluded.order_index, type_label=excluded.type_label, direction=excluded.direction",
            .{ .id = limbo.text(row.id), .doc_id = limbo.text(row.doc_id), .path = limbo.text(row.path), .order_index = row.order_index, .name = limbo.text(row.name), .type_label = if (row.type_label) |t| limbo.text(t) else null, .direction = limbo.text(row.direction) },
        );
    }

    pub fn insertDocPart(self: *Store, row: circuitry_doc_parts) !void {
        try self.workspace_db.exec(
            "insert into circuitry_doc_parts(id, doc_id, path, order_index, name, shape, model, instructions) values (:id, :doc_id, :path, :order_index, :name, :shape, :model, :instructions) on conflict(id) do update set path=excluded.path, order_index=excluded.order_index, shape=excluded.shape, model=excluded.model, instructions=excluded.instructions",
            .{ .id = limbo.text(row.id), .doc_id = limbo.text(row.doc_id), .path = limbo.text(row.path), .order_index = row.order_index, .name = limbo.text(row.name), .shape = if (row.shape) |s| limbo.text(s) else null, .model = if (row.model) |m| limbo.text(m) else null, .instructions = if (row.instructions) |i| limbo.text(i) else null },
        );
    }

    pub fn insertDocBinding(self: *Store, row: circuitry_doc_bindings) !void {
        try self.workspace_db.exec(
            "insert into circuitry_doc_bindings(id, doc_id, path, part_id, side, local_name, value_name, type_label) values (:id, :doc_id, :path, :part_id, :side, :local_name, :value_name, :type_label) on conflict(id) do update set path=excluded.path, local_name=excluded.local_name, value_name=excluded.value_name, type_label=excluded.type_label",
            .{ .id = limbo.text(row.id), .doc_id = limbo.text(row.doc_id), .path = limbo.text(row.path), .part_id = limbo.text(row.part_id), .side = limbo.text(row.side), .local_name = if (row.local_name) |l| limbo.text(l) else null, .value_name = limbo.text(row.value_name), .type_label = if (row.type_label) |t| limbo.text(t) else null },
        );
    }

    pub fn insertDocDiagnostic(self: *Store, row: circuitry_doc_diagnostics) !void {
        try self.workspace_db.exec(
            "insert into circuitry_doc_diagnostics(id, doc_id, path, severity, kind, message) values (:id, :doc_id, :path, :severity, :kind, :message) on conflict(id) do update set path=excluded.path, severity=excluded.severity, kind=excluded.kind, message=excluded.message",
            .{ .id = limbo.text(row.id), .doc_id = limbo.text(row.doc_id), .path = limbo.text(row.path), .severity = limbo.text(row.severity), .kind = limbo.text(row.kind), .message = limbo.text(row.message) },
        );
    }

    pub fn listDocValues(self: *Store, doc_id: []const u8) ![]circuitry_doc_values {
        const Row = struct { id: limbo.Text, doc_id: limbo.Text, path: limbo.Text, order_index: i64, name: limbo.Text, type_label: ?limbo.Text, direction: limbo.Text };
        var stmt = try self.workspace_db.prepare(struct { doc_id: limbo.Text }, Row, "select id, doc_id, path, order_index, name, type_label, direction from circuitry_doc_values where doc_id = :doc_id order by direction asc, order_index asc");
        defer stmt.finalize();
        try stmt.bind(.{ .doc_id = limbo.text(doc_id) });
        var list: std.ArrayList(circuitry_doc_values) = .empty;
        errdefer {
            for (list.items) |row| self.freeDocValue(row);
            list.deinit(self.allocator);
        }
        while (try stmt.step()) |row| try list.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, row.id.data),
            .doc_id = try self.allocator.dupe(u8, row.doc_id.data),
            .path = try self.allocator.dupe(u8, row.path.data),
            .order_index = row.order_index,
            .name = try self.allocator.dupe(u8, row.name.data),
            .type_label = if (row.type_label) |t| try self.allocator.dupe(u8, t.data) else null,
            .direction = try self.allocator.dupe(u8, row.direction.data),
        });
        return list.toOwnedSlice(self.allocator);
    }

    pub fn listDocParts(self: *Store, doc_id: []const u8) ![]circuitry_doc_parts {
        const Row = struct { id: limbo.Text, doc_id: limbo.Text, path: limbo.Text, order_index: i64, name: limbo.Text, shape: ?limbo.Text, model: ?limbo.Text, instructions: ?limbo.Text };
        var stmt = try self.workspace_db.prepare(struct { doc_id: limbo.Text }, Row, "select id, doc_id, path, order_index, name, shape, model, instructions from circuitry_doc_parts where doc_id = :doc_id order by order_index asc");
        defer stmt.finalize();
        try stmt.bind(.{ .doc_id = limbo.text(doc_id) });
        var list: std.ArrayList(circuitry_doc_parts) = .empty;
        errdefer {
            for (list.items) |row| self.freeDocPart(row);
            list.deinit(self.allocator);
        }
        while (try stmt.step()) |row| try list.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, row.id.data),
            .doc_id = try self.allocator.dupe(u8, row.doc_id.data),
            .path = try self.allocator.dupe(u8, row.path.data),
            .order_index = row.order_index,
            .name = try self.allocator.dupe(u8, row.name.data),
            .shape = if (row.shape) |s| try self.allocator.dupe(u8, s.data) else null,
            .model = if (row.model) |m| try self.allocator.dupe(u8, m.data) else null,
            .instructions = if (row.instructions) |i| try self.allocator.dupe(u8, i.data) else null,
        });
        return list.toOwnedSlice(self.allocator);
    }

    pub fn listDocBindings(self: *Store, doc_id: []const u8) ![]circuitry_doc_bindings {
        const Row = struct { id: limbo.Text, doc_id: limbo.Text, path: limbo.Text, part_id: limbo.Text, side: limbo.Text, local_name: ?limbo.Text, value_name: limbo.Text, type_label: ?limbo.Text };
        var stmt = try self.workspace_db.prepare(struct { doc_id: limbo.Text }, Row, "select id, doc_id, path, part_id, side, local_name, value_name, type_label from circuitry_doc_bindings where doc_id = :doc_id order by path asc");
        defer stmt.finalize();
        try stmt.bind(.{ .doc_id = limbo.text(doc_id) });
        var list: std.ArrayList(circuitry_doc_bindings) = .empty;
        errdefer {
            for (list.items) |row| self.freeDocBinding(row);
            list.deinit(self.allocator);
        }
        while (try stmt.step()) |row| try list.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, row.id.data),
            .doc_id = try self.allocator.dupe(u8, row.doc_id.data),
            .path = try self.allocator.dupe(u8, row.path.data),
            .part_id = try self.allocator.dupe(u8, row.part_id.data),
            .side = try self.allocator.dupe(u8, row.side.data),
            .local_name = if (row.local_name) |l| try self.allocator.dupe(u8, l.data) else null,
            .value_name = try self.allocator.dupe(u8, row.value_name.data),
            .type_label = if (row.type_label) |t| try self.allocator.dupe(u8, t.data) else null,
        });
        return list.toOwnedSlice(self.allocator);
    }

    pub fn freeDocValue(self: *Store, row: circuitry_doc_values) void {
        self.allocator.free(row.id);
        self.allocator.free(row.doc_id);
        self.allocator.free(row.path);
        self.allocator.free(row.name);
        if (row.type_label) |t| self.allocator.free(t);
        self.allocator.free(row.direction);
    }
    pub fn freeDocPart(self: *Store, row: circuitry_doc_parts) void {
        self.allocator.free(row.id);
        self.allocator.free(row.doc_id);
        self.allocator.free(row.path);
        self.allocator.free(row.name);
        if (row.shape) |s| self.allocator.free(s);
        if (row.model) |m| self.allocator.free(m);
        if (row.instructions) |i| self.allocator.free(i);
    }
    pub fn freeDocBinding(self: *Store, row: circuitry_doc_bindings) void {
        self.allocator.free(row.id);
        self.allocator.free(row.doc_id);
        self.allocator.free(row.path);
        self.allocator.free(row.part_id);
        self.allocator.free(row.side);
        if (row.local_name) |l| self.allocator.free(l);
        self.allocator.free(row.value_name);
        if (row.type_label) |t| self.allocator.free(t);
    }

    // --- Runs ---
    pub fn insertRun(self: *Store, run_obj: runs) !void {
        try self.workspace_db.exec(
            "insert into runs(id, doc_id, status, started_at, finished_at) values (:id, :doc_id, :status, :started_at, :finished_at) on conflict(id) do update set status=excluded.status, finished_at=excluded.finished_at",
            .{ .id = limbo.text(run_obj.id), .doc_id = if (run_obj.doc_id) |d| limbo.text(d) else null, .status = if (run_obj.status) |s| limbo.text(s) else null, .started_at = run_obj.started_at, .finished_at = run_obj.finished_at },
        );
    }

    pub fn getRun(self: *Store, id: []const u8) !?runs {
        const Row = struct { id: limbo.Text, doc_id: ?limbo.Text, status: ?limbo.Text, started_at: ?i64, finished_at: ?i64 };
        var stmt = try self.workspace_db.prepare(struct { id: limbo.Text }, Row, "select id, doc_id, status, started_at, finished_at from runs where id = :id");
        defer stmt.finalize();
        try stmt.bind(.{ .id = limbo.text(id) });
        if (try stmt.step()) |row| return .{ .id = try self.allocator.dupe(u8, row.id.data), .doc_id = if (row.doc_id) |d| try self.allocator.dupe(u8, d.data) else null, .status = if (row.status) |st| try self.allocator.dupe(u8, st.data) else null, .started_at = row.started_at, .finished_at = row.finished_at };
        return null;
    }

    pub fn freeRun(self: *Store, row: runs) void {
        self.allocator.free(row.id);
        if (row.doc_id) |doc_id| self.allocator.free(doc_id);
        if (row.status) |status| self.allocator.free(status);
    }

    // --- Actions ---
    pub fn insertAction(self: *Store, act: actions) !void {
        try self.workspace_db.exec(
            "insert into actions(id, run_id, path, seq, action, cwd, status, approval, metadata_json) values (:id, :run_id, :path, :seq, :action, :cwd, :status, :approval, :metadata_json)",
            .{ .id = limbo.text(act.id), .run_id = if (act.run_id) |r| limbo.text(r) else null, .path = limbo.text(act.path), .seq = act.seq, .action = if (act.action) |a| limbo.text(a) else null, .cwd = if (act.cwd) |c| limbo.text(c) else null, .status = if (act.status) |st| limbo.text(st) else null, .approval = if (act.approval) |ap| limbo.text(ap) else null, .metadata_json = if (act.metadata_json) |m| limbo.text(m) else null },
        );
    }

    pub fn insertActionOutput(self: *Store, out: action_outputs) !void {
        try self.workspace_db.exec(
            "insert into action_outputs(id, action_id, run_id, path, stream, payload, bytes, truncated) values (:id, :action_id, :run_id, :path, :stream, :payload, :bytes, :truncated) on conflict(id) do update set payload=excluded.payload, bytes=excluded.bytes, truncated=excluded.truncated",
            .{ .id = limbo.text(out.id), .action_id = limbo.text(out.action_id), .run_id = limbo.text(out.run_id), .path = limbo.text(out.path), .stream = limbo.text(out.stream), .payload = limbo.blob(out.payload), .bytes = out.bytes, .truncated = out.truncated },
        );
    }

    pub fn getActionOutput(self: *Store, run_id: []const u8, path: []const u8) !?action_outputs {
        const Row = struct { id: limbo.Text, action_id: limbo.Text, run_id: limbo.Text, path: limbo.Text, stream: limbo.Text, payload: limbo.Blob, bytes: i64, truncated: i64 };
        var stmt = try self.workspace_db.prepare(struct { run_id: limbo.Text, path: limbo.Text }, Row, "select id, action_id, run_id, path, stream, payload, bytes, truncated from action_outputs where run_id = :run_id and path = :path");
        defer stmt.finalize();
        try stmt.bind(.{ .run_id = limbo.text(run_id), .path = limbo.text(path) });
        if (try stmt.step()) |row| return .{ .id = try self.allocator.dupe(u8, row.id.data), .action_id = try self.allocator.dupe(u8, row.action_id.data), .run_id = try self.allocator.dupe(u8, row.run_id.data), .path = try self.allocator.dupe(u8, row.path.data), .stream = try self.allocator.dupe(u8, row.stream.data), .payload = try self.allocator.dupe(u8, row.payload.data), .bytes = row.bytes, .truncated = row.truncated };
        return null;
    }

    pub fn freeActionOutput(self: *Store, row: action_outputs) void {
        self.allocator.free(row.id);
        self.allocator.free(row.action_id);
        self.allocator.free(row.run_id);
        self.allocator.free(row.path);
        self.allocator.free(row.stream);
        self.allocator.free(row.payload);
    }

    pub fn listActions(self: *Store, run_id: []const u8) ![]actions {
        const Row = struct { id: limbo.Text, run_id: ?limbo.Text, path: limbo.Text, seq: i64, action: ?limbo.Text, cwd: ?limbo.Text, status: ?limbo.Text, approval: ?limbo.Text, metadata_json: ?limbo.Text };
        var stmt = try self.workspace_db.prepare(struct { run_id: limbo.Text }, Row, "select id, run_id, path, seq, action, cwd, status, approval, metadata_json from actions where run_id = :run_id order by seq asc");
        defer stmt.finalize();
        try stmt.bind(.{ .run_id = limbo.text(run_id) });
        var list: std.ArrayList(actions) = .empty;
        errdefer {
            for (list.items) |act| self.freeAction(act);
            list.deinit(self.allocator);
        }
        while (try stmt.step()) |row| try list.append(self.allocator, .{ .id = try self.allocator.dupe(u8, row.id.data), .run_id = if (row.run_id) |r| try self.allocator.dupe(u8, r.data) else null, .path = try self.allocator.dupe(u8, row.path.data), .seq = row.seq, .action = if (row.action) |a| try self.allocator.dupe(u8, a.data) else null, .cwd = if (row.cwd) |c| try self.allocator.dupe(u8, c.data) else null, .status = if (row.status) |st| try self.allocator.dupe(u8, st.data) else null, .approval = if (row.approval) |ap| try self.allocator.dupe(u8, ap.data) else null, .metadata_json = if (row.metadata_json) |m| try self.allocator.dupe(u8, m.data) else null });
        return list.toOwnedSlice(self.allocator);
    }

    pub fn freeAction(self: *Store, act: actions) void {
        self.allocator.free(act.id);
        if (act.run_id) |r| self.allocator.free(r);
        self.allocator.free(act.path);
        if (act.action) |a| self.allocator.free(a);
        if (act.cwd) |c| self.allocator.free(c);
        if (act.status) |st| self.allocator.free(st);
        if (act.approval) |ap| self.allocator.free(ap);
        if (act.metadata_json) |m| self.allocator.free(m);
    }

    // --- Approvals ---
    pub fn insertApproval(self: *Store, app: approvals) !void {
        try self.workspace_db.exec(
            "insert into approvals(id, run_id, kind, subject, decision, created_at) values (:id, :run_id, :kind, :subject, :decision, :created_at) on conflict(id) do update set decision=excluded.decision",
            .{ .id = limbo.text(app.id), .run_id = if (app.run_id) |r| limbo.text(r) else null, .kind = if (app.kind) |k| limbo.text(k) else null, .subject = if (app.subject) |sub| limbo.text(sub) else null, .decision = if (app.decision) |d| limbo.text(d) else null, .created_at = app.created_at },
        );
    }

    pub fn getApprovalForSubject(self: *Store, run_id: []const u8, kind: []const u8, subject: []const u8) !?approvals {
        const Row = struct { id: limbo.Text, run_id: ?limbo.Text, kind: ?limbo.Text, subject: ?limbo.Text, decision: ?limbo.Text, created_at: ?i64 };
        var stmt = try self.workspace_db.prepare(struct { run_id: limbo.Text, kind: limbo.Text, subject: limbo.Text }, Row, "select id, run_id, kind, subject, decision, created_at from approvals where run_id = :run_id and kind = :kind and subject = :subject");
        defer stmt.finalize();
        try stmt.bind(.{ .run_id = limbo.text(run_id), .kind = limbo.text(kind), .subject = limbo.text(subject) });
        if (try stmt.step()) |row| return .{ .id = try self.allocator.dupe(u8, row.id.data), .run_id = if (row.run_id) |r| try self.allocator.dupe(u8, r.data) else null, .kind = if (row.kind) |k| try self.allocator.dupe(u8, k.data) else null, .subject = if (row.subject) |sub| try self.allocator.dupe(u8, sub.data) else null, .decision = if (row.decision) |d| try self.allocator.dupe(u8, d.data) else null, .created_at = row.created_at };
        return null;
    }

    // --- System runs ---
    pub fn insertRunValue(self: *Store, row: run_values) !void {
        try self.workspace_db.exec(
            "insert into run_values(id, run_id, path, name, type_label, origin, producer_part_path, payload) values (:id, :run_id, :path, :name, :type_label, :origin, :producer_part_path, :payload) on conflict(id) do update set payload=excluded.payload, type_label=excluded.type_label, origin=excluded.origin, producer_part_path=excluded.producer_part_path",
            .{ .id = limbo.text(row.id), .run_id = limbo.text(row.run_id), .path = limbo.text(row.path), .name = limbo.text(row.name), .type_label = if (row.type_label) |t| limbo.text(t) else null, .origin = if (row.origin) |o| limbo.text(o) else null, .producer_part_path = if (row.producer_part_path) |pp| limbo.text(pp) else null, .payload = limbo.blob(row.payload) },
        );
    }

    pub fn insertRunPart(self: *Store, row: run_parts) !void {
        try self.workspace_db.exec(
            "insert into run_parts(id, run_id, path, doc_part_id, name, status) values (:id, :run_id, :path, :doc_part_id, :name, :status) on conflict(id) do update set status=excluded.status",
            .{ .id = limbo.text(row.id), .run_id = limbo.text(row.run_id), .path = limbo.text(row.path), .doc_part_id = limbo.text(row.doc_part_id), .name = limbo.text(row.name), .status = limbo.text(row.status) },
        );
    }

    pub fn listRunParts(self: *Store, run_id: []const u8) ![]run_parts {
        const Row = struct { id: limbo.Text, run_id: limbo.Text, path: limbo.Text, doc_part_id: limbo.Text, name: limbo.Text, status: limbo.Text };
        var stmt = try self.workspace_db.prepare(struct { run_id: limbo.Text }, Row, "select id, run_id, path, doc_part_id, name, status from run_parts where run_id = :run_id order by path asc");
        defer stmt.finalize();
        try stmt.bind(.{ .run_id = limbo.text(run_id) });
        var list: std.ArrayList(run_parts) = .empty;
        errdefer {
            for (list.items) |row| self.freeRunPart(row);
            list.deinit(self.allocator);
        }
        while (try stmt.step()) |row| try list.append(self.allocator, .{ .id = try self.allocator.dupe(u8, row.id.data), .run_id = try self.allocator.dupe(u8, row.run_id.data), .path = try self.allocator.dupe(u8, row.path.data), .doc_part_id = try self.allocator.dupe(u8, row.doc_part_id.data), .name = try self.allocator.dupe(u8, row.name.data), .status = try self.allocator.dupe(u8, row.status.data) });
        return list.toOwnedSlice(self.allocator);
    }

    pub fn freeRunPart(self: *Store, row: run_parts) void {
        self.allocator.free(row.id);
        self.allocator.free(row.run_id);
        self.allocator.free(row.path);
        self.allocator.free(row.doc_part_id);
        self.allocator.free(row.name);
        self.allocator.free(row.status);
    }

    pub fn insertRunText(self: *Store, row: run_text) !void {
        try self.workspace_db.exec(
            "insert into run_text(id, run_id, path, role, payload) values (:id, :run_id, :path, :role, :payload) on conflict(id) do update set payload=excluded.payload, role=excluded.role",
            .{ .id = limbo.text(row.id), .run_id = limbo.text(row.run_id), .path = limbo.text(row.path), .role = limbo.text(row.role), .payload = limbo.blob(row.payload) },
        );
    }

    pub fn getRunText(self: *Store, run_id: []const u8, path: []const u8) !?run_text {
        const Row = struct { id: limbo.Text, run_id: limbo.Text, path: limbo.Text, role: limbo.Text, payload: limbo.Blob };
        var stmt = try self.workspace_db.prepare(struct { run_id: limbo.Text, path: limbo.Text }, Row, "select id, run_id, path, role, payload from run_text where run_id = :run_id and path = :path");
        defer stmt.finalize();
        try stmt.bind(.{ .run_id = limbo.text(run_id), .path = limbo.text(path) });
        if (try stmt.step()) |row| return .{ .id = try self.allocator.dupe(u8, row.id.data), .run_id = try self.allocator.dupe(u8, row.run_id.data), .path = try self.allocator.dupe(u8, row.path.data), .role = try self.allocator.dupe(u8, row.role.data), .payload = try self.allocator.dupe(u8, row.payload.data) };
        return null;
    }

    pub fn listRunText(self: *Store, run_id: []const u8) ![]run_text {
        const Row = struct { id: limbo.Text, run_id: limbo.Text, path: limbo.Text, role: limbo.Text, payload: limbo.Blob };
        var stmt = try self.workspace_db.prepare(struct { run_id: limbo.Text }, Row, "select id, run_id, path, role, payload from run_text where run_id = :run_id order by path asc");
        defer stmt.finalize();
        try stmt.bind(.{ .run_id = limbo.text(run_id) });
        var list: std.ArrayList(run_text) = .empty;
        errdefer {
            for (list.items) |row| self.freeRunText(row);
            list.deinit(self.allocator);
        }
        while (try stmt.step()) |row| try list.append(self.allocator, .{ .id = try self.allocator.dupe(u8, row.id.data), .run_id = try self.allocator.dupe(u8, row.run_id.data), .path = try self.allocator.dupe(u8, row.path.data), .role = try self.allocator.dupe(u8, row.role.data), .payload = try self.allocator.dupe(u8, row.payload.data) });
        return list.toOwnedSlice(self.allocator);
    }

    pub fn freeRunText(self: *Store, row: run_text) void {
        self.allocator.free(row.id);
        self.allocator.free(row.run_id);
        self.allocator.free(row.path);
        self.allocator.free(row.role);
        self.allocator.free(row.payload);
    }

    pub fn insertRunPlanStep(self: *Store, row: run_plan_steps) !void {
        try self.workspace_db.exec(
            "insert into run_plan_steps(id, run_id, path, part_path, order_index, required, status, reason) values (:id, :run_id, :path, :part_path, :order_index, :required, :status, :reason) on conflict(id) do update set required=excluded.required, status=excluded.status, reason=excluded.reason",
            .{ .id = limbo.text(row.id), .run_id = limbo.text(row.run_id), .path = limbo.text(row.path), .part_path = limbo.text(row.part_path), .order_index = row.order_index, .required = row.required, .status = limbo.text(row.status), .reason = if (row.reason) |r| limbo.text(r) else null },
        );
    }

    pub fn listRunValues(self: *Store, run_id: []const u8) ![]run_values {
        const Row = struct { id: limbo.Text, run_id: limbo.Text, path: limbo.Text, name: limbo.Text, type_label: ?limbo.Text, origin: ?limbo.Text, producer_part_path: ?limbo.Text, payload: limbo.Blob };
        var stmt = try self.workspace_db.prepare(struct { run_id: limbo.Text }, Row, "select id, run_id, path, name, type_label, origin, producer_part_path, payload from run_values where run_id = :run_id order by path asc");
        defer stmt.finalize();
        try stmt.bind(.{ .run_id = limbo.text(run_id) });
        var list: std.ArrayList(run_values) = .empty;
        errdefer {
            for (list.items) |row| self.freeRunValue(row);
            list.deinit(self.allocator);
        }
        while (try stmt.step()) |row| try list.append(self.allocator, .{ .id = try self.allocator.dupe(u8, row.id.data), .run_id = try self.allocator.dupe(u8, row.run_id.data), .path = try self.allocator.dupe(u8, row.path.data), .name = try self.allocator.dupe(u8, row.name.data), .type_label = if (row.type_label) |t| try self.allocator.dupe(u8, t.data) else null, .origin = if (row.origin) |o| try self.allocator.dupe(u8, o.data) else null, .producer_part_path = if (row.producer_part_path) |pp| try self.allocator.dupe(u8, pp.data) else null, .payload = try self.allocator.dupe(u8, row.payload.data) });
        return list.toOwnedSlice(self.allocator);
    }

    pub fn getRunValue(self: *Store, run_id: []const u8, path: []const u8) !?run_values {
        const Row = struct { id: limbo.Text, run_id: limbo.Text, path: limbo.Text, name: limbo.Text, type_label: ?limbo.Text, origin: ?limbo.Text, producer_part_path: ?limbo.Text, payload: limbo.Blob };
        var stmt = try self.workspace_db.prepare(struct { run_id: limbo.Text, path: limbo.Text }, Row, "select id, run_id, path, name, type_label, origin, producer_part_path, payload from run_values where run_id = :run_id and path = :path");
        defer stmt.finalize();
        try stmt.bind(.{ .run_id = limbo.text(run_id), .path = limbo.text(path) });
        if (try stmt.step()) |row| return .{ .id = try self.allocator.dupe(u8, row.id.data), .run_id = try self.allocator.dupe(u8, row.run_id.data), .path = try self.allocator.dupe(u8, row.path.data), .name = try self.allocator.dupe(u8, row.name.data), .type_label = if (row.type_label) |t| try self.allocator.dupe(u8, t.data) else null, .origin = if (row.origin) |o| try self.allocator.dupe(u8, o.data) else null, .producer_part_path = if (row.producer_part_path) |pp| try self.allocator.dupe(u8, pp.data) else null, .payload = try self.allocator.dupe(u8, row.payload.data) };
        return null;
    }

    pub fn freeRunValue(self: *Store, row: run_values) void {
        self.allocator.free(row.id);
        self.allocator.free(row.run_id);
        self.allocator.free(row.path);
        self.allocator.free(row.name);
        if (row.type_label) |t| self.allocator.free(t);
        if (row.origin) |o| self.allocator.free(o);
        if (row.producer_part_path) |pp| self.allocator.free(pp);
        self.allocator.free(row.payload);
    }

    // --- Packages ---
    pub fn insertPackage(self: *Store, pkg: packages) !void {
        try self.global_db.exec(
            "insert into packages(name, version, source, scope, path, status, installed_at, checked_at) values (:name, :version, :source, :scope, :path, :status, :installed_at, :checked_at) on conflict(name) do update set version=excluded.version, source=excluded.source, scope=excluded.scope, path=excluded.path, status=excluded.status, checked_at=excluded.checked_at",
            .{
                .name = limbo.text(pkg.name),
                .version = if (pkg.version) |v| limbo.text(v) else null,
                .source = if (pkg.source) |s| limbo.text(s) else null,
                .scope = if (pkg.scope) |sc| limbo.text(sc) else null,
                .path = if (pkg.path) |p| limbo.text(p) else null,
                .status = if (pkg.status) |st| limbo.text(st) else null,
                .installed_at = pkg.installed_at,
                .checked_at = pkg.checked_at,
            },
        );
    }

    pub fn deletePackage(self: *Store, name: []const u8) !void {
        try self.clearPackageFacts(name);
        try self.global_db.exec("delete from package_sources where package_name = :name", .{ .name = limbo.text(name) });
        try self.global_db.exec("delete from packages where name = :name", .{ .name = limbo.text(name) });
    }

    pub fn clearPackageFacts(self: *Store, name: []const u8) !void {
        try self.global_db.exec("delete from package_assets where package_name = :name", .{ .name = limbo.text(name) });
        try self.global_db.exec("delete from package_scripts where package_name = :name", .{ .name = limbo.text(name) });
        try self.global_db.exec("delete from package_dependencies where package_name = :name", .{ .name = limbo.text(name) });
    }

    pub fn getPackage(self: *Store, name: []const u8) !?packages {
        const Row = struct {
            name: limbo.Text,
            version: ?limbo.Text,
            source: ?limbo.Text,
            scope: ?limbo.Text,
            path: ?limbo.Text,
            status: ?limbo.Text,
            installed_at: ?i64,
            checked_at: ?i64,
        };
        var stmt = try self.global_db.prepare(struct { name: limbo.Text }, Row, "select name, version, source, scope, path, status, installed_at, checked_at from packages where name = :name");
        defer stmt.finalize();
        try stmt.bind(.{ .name = limbo.text(name) });
        if (try stmt.step()) |row| {
            return packages{
                .name = try self.allocator.dupe(u8, row.name.data),
                .version = if (row.version) |v| try self.allocator.dupe(u8, v.data) else null,
                .source = if (row.source) |s| try self.allocator.dupe(u8, s.data) else null,
                .scope = if (row.scope) |sc| try self.allocator.dupe(u8, sc.data) else null,
                .path = if (row.path) |p| try self.allocator.dupe(u8, p.data) else null,
                .status = if (row.status) |st| try self.allocator.dupe(u8, st.data) else null,
                .installed_at = row.installed_at,
                .checked_at = row.checked_at,
            };
        }
        return null;
    }

    pub fn listPackages(self: *Store) ![]packages {
        const Row = struct {
            name: limbo.Text,
            version: ?limbo.Text,
            source: ?limbo.Text,
            scope: ?limbo.Text,
            path: ?limbo.Text,
            status: ?limbo.Text,
            installed_at: ?i64,
            checked_at: ?i64,
        };
        var stmt = try self.global_db.prepare(struct {}, Row, "select name, version, source, scope, path, status, installed_at, checked_at from packages order by name asc");
        defer stmt.finalize();
        try stmt.bind(.{});
        var list: std.ArrayList(packages) = .empty;
        errdefer {
            for (list.items) |pkg| self.freePackage(pkg);
            list.deinit(self.allocator);
        }
        while (try stmt.step()) |row| {
            try list.append(self.allocator, packages{
                .name = try self.allocator.dupe(u8, row.name.data),
                .version = if (row.version) |v| try self.allocator.dupe(u8, v.data) else null,
                .source = if (row.source) |s| try self.allocator.dupe(u8, s.data) else null,
                .scope = if (row.scope) |sc| try self.allocator.dupe(u8, sc.data) else null,
                .path = if (row.path) |p| try self.allocator.dupe(u8, p.data) else null,
                .status = if (row.status) |st| try self.allocator.dupe(u8, st.data) else null,
                .installed_at = row.installed_at,
                .checked_at = row.checked_at,
            });
        }
        return list.toOwnedSlice(self.allocator);
    }

    pub fn upsertPackageSource(self: *Store, source: package_sources) !void {
        try self.global_db.exec(
            "insert into package_sources(package_name, kind, url, ref, path, rev) values (:package_name, :kind, :url, :ref, :path, :rev) on conflict(package_name) do update set kind=excluded.kind, url=excluded.url, ref=excluded.ref, path=excluded.path, rev=excluded.rev",
            .{
                .package_name = limbo.text(source.package_name),
                .kind = limbo.text(source.kind),
                .url = limbo.text(source.url),
                .ref = limbo.text(source.ref),
                .path = limbo.text(source.path),
                .rev = if (source.rev) |r| limbo.text(r) else null,
            },
        );
    }

    pub fn getPackageSource(self: *Store, package_name: []const u8) !?package_sources {
        const Row = struct {
            package_name: limbo.Text,
            kind: limbo.Text,
            url: limbo.Text,
            ref: limbo.Text,
            path: limbo.Text,
            rev: ?limbo.Text,
        };
        var stmt = try self.global_db.prepare(struct { package_name: limbo.Text }, Row, "select package_name, kind, url, ref, path, rev from package_sources where package_name = :package_name");
        defer stmt.finalize();
        try stmt.bind(.{ .package_name = limbo.text(package_name) });
        if (try stmt.step()) |row| {
            return package_sources{
                .package_name = try self.allocator.dupe(u8, row.package_name.data),
                .kind = try self.allocator.dupe(u8, row.kind.data),
                .url = try self.allocator.dupe(u8, row.url.data),
                .ref = try self.allocator.dupe(u8, row.ref.data),
                .path = try self.allocator.dupe(u8, row.path.data),
                .rev = if (row.rev) |r| try self.allocator.dupe(u8, r.data) else null,
            };
        }
        return null;
    }

    pub fn freePackageSource(self: *Store, source: package_sources) void {
        self.allocator.free(source.package_name);
        self.allocator.free(source.kind);
        self.allocator.free(source.url);
        self.allocator.free(source.ref);
        self.allocator.free(source.path);
        if (source.rev) |r| self.allocator.free(r);
    }

    pub fn insertPackageAsset(self: *Store, row: package_assets) !void {
        try self.global_db.exec(
            "insert into package_assets(package_name, path, file_path, metadata_json) values (:package_name, :path, :file_path, :metadata_json) on conflict(package_name, path) do update set file_path=excluded.file_path, metadata_json=excluded.metadata_json",
            .{ .package_name = limbo.text(row.package_name), .path = limbo.text(row.path), .file_path = limbo.text(row.file_path), .metadata_json = if (row.metadata_json) |m| limbo.text(m) else null },
        );
    }

    pub fn getPackageAsset(self: *Store, package_name: []const u8, asset_path: []const u8) !?package_assets {
        const Row = struct { package_name: limbo.Text, path: limbo.Text, file_path: limbo.Text, metadata_json: ?limbo.Text };
        var stmt = try self.global_db.prepare(struct { package_name: limbo.Text, path: limbo.Text }, Row, "select package_name, path, file_path, metadata_json from package_assets where package_name = :package_name and path = :path");
        defer stmt.finalize();
        try stmt.bind(.{ .package_name = limbo.text(package_name), .path = limbo.text(asset_path) });
        if (try stmt.step()) |row| return .{ .package_name = try self.allocator.dupe(u8, row.package_name.data), .path = try self.allocator.dupe(u8, row.path.data), .file_path = try self.allocator.dupe(u8, row.file_path.data), .metadata_json = if (row.metadata_json) |m| try self.allocator.dupe(u8, m.data) else null };
        return null;
    }

    pub fn listPackageAssets(self: *Store, package_name: []const u8) ![]package_assets {
        const Row = struct { package_name: limbo.Text, path: limbo.Text, file_path: limbo.Text, metadata_json: ?limbo.Text };
        var stmt = try self.global_db.prepare(struct { package_name: limbo.Text }, Row, "select package_name, path, file_path, metadata_json from package_assets where package_name = :package_name order by path asc");
        defer stmt.finalize();
        try stmt.bind(.{ .package_name = limbo.text(package_name) });
        var list: std.ArrayList(package_assets) = .empty;
        errdefer {
            for (list.items) |row| self.freePackageAsset(row);
            list.deinit(self.allocator);
        }
        while (try stmt.step()) |row| try list.append(self.allocator, .{ .package_name = try self.allocator.dupe(u8, row.package_name.data), .path = try self.allocator.dupe(u8, row.path.data), .file_path = try self.allocator.dupe(u8, row.file_path.data), .metadata_json = if (row.metadata_json) |m| try self.allocator.dupe(u8, m.data) else null });
        return list.toOwnedSlice(self.allocator);
    }

    pub fn freePackageAsset(self: *Store, row: package_assets) void {
        self.allocator.free(row.package_name);
        self.allocator.free(row.path);
        self.allocator.free(row.file_path);
        if (row.metadata_json) |m| self.allocator.free(m);
    }

    pub fn insertPackageScript(self: *Store, row: package_scripts) !void {
        try self.global_db.exec(
            "insert into package_scripts(package_name, path, file_path) values (:package_name, :path, :file_path) on conflict(package_name, path) do update set file_path=excluded.file_path",
            .{ .package_name = limbo.text(row.package_name), .path = limbo.text(row.path), .file_path = limbo.text(row.file_path) },
        );
    }

    pub fn getPackageScript(self: *Store, package_name: []const u8, script_path: []const u8) !?package_scripts {
        const Row = struct { package_name: limbo.Text, path: limbo.Text, file_path: limbo.Text };
        var stmt = try self.global_db.prepare(struct { package_name: limbo.Text, path: limbo.Text }, Row, "select package_name, path, file_path from package_scripts where package_name = :package_name and path = :path");
        defer stmt.finalize();
        try stmt.bind(.{ .package_name = limbo.text(package_name), .path = limbo.text(script_path) });
        if (try stmt.step()) |row| return .{ .package_name = try self.allocator.dupe(u8, row.package_name.data), .path = try self.allocator.dupe(u8, row.path.data), .file_path = try self.allocator.dupe(u8, row.file_path.data) };
        return null;
    }

    pub fn freePackageScript(self: *Store, row: package_scripts) void {
        self.allocator.free(row.package_name);
        self.allocator.free(row.path);
        self.allocator.free(row.file_path);
    }

    pub fn insertPackageDependency(self: *Store, row: package_dependencies) !void {
        try self.global_db.exec(
            "insert into package_dependencies(package_name, alias, package_spec, about) values (:package_name, :alias, :package_spec, :about) on conflict(package_name, alias) do update set package_spec=excluded.package_spec, about=excluded.about",
            .{ .package_name = limbo.text(row.package_name), .alias = limbo.text(row.alias), .package_spec = limbo.text(row.package_spec), .about = if (row.about) |a| limbo.text(a) else null },
        );
    }

    pub fn freePackage(self: *Store, pkg: packages) void {
        self.allocator.free(pkg.name);
        if (pkg.version) |v| self.allocator.free(v);
        if (pkg.source) |s| self.allocator.free(s);
        if (pkg.scope) |sc| self.allocator.free(sc);
        if (pkg.path) |p| self.allocator.free(p);
        if (pkg.status) |st| self.allocator.free(st);
    }
};
