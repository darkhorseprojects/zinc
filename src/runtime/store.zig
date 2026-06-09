const std = @import("std");
const limbo = @import("limbo");
const layout = @import("../io/layout.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub const circuitry_docs = struct {
    id: []const u8,
    path: ?[]const u8,
    name: ?[]const u8,
    source: []const u8,
    updated_at: i64,
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
    seq: i64,
    action: ?[]const u8,
    cwd: ?[]const u8,
    status: ?[]const u8,
    approval: ?[]const u8,
    stdout_uri: ?[]const u8,
    stderr_uri: ?[]const u8,
    metadata_json: ?[]const u8,
};

pub const approvals = struct {
    id: []const u8,
    run_id: ?[]const u8,
    kind: ?[]const u8,
    subject: ?[]const u8,
    decision: ?[]const u8,
    created_at: ?i64,
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

        try store.migrate();
        return store;
    }

    pub fn close(self: *Store) void {
        self.global_db.close();
        if (self.has_workspace) {
            self.workspace_db.close();
        }
    }

    fn migrate(self: *Store) !void {
        // Global tables
        try self.global_db.exec("create table if not exists packages(name text primary key, version text, source text, scope text, path text, status text, installed_at integer, checked_at integer)", .{});
        try self.global_db.exec("create table if not exists config(key text primary key, value text)", .{});

        // Workspace tables
        try self.workspace_db.exec("create table if not exists circuitry_docs(id text primary key, path text, name text, source text not null, updated_at integer not null)", .{});
        try self.workspace_db.exec("create table if not exists runs(id text primary key, doc_id text, status text, started_at integer, finished_at integer)", .{});
        try self.workspace_db.exec("create table if not exists actions(id text primary key, run_id text, seq integer, action text, cwd text, status text, approval text, stdout_uri text, stderr_uri text, metadata_json text)", .{});
        try self.workspace_db.exec("create table if not exists approvals(id text primary key, run_id text, kind text, subject text, decision text, created_at integer)", .{});
        try self.workspace_db.exec("create table if not exists config(key text primary key, value text)", .{});
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
            "insert into circuitry_docs(id, path, name, source, updated_at) values (:id, :path, :name, :source, :updated_at) on conflict(id) do update set path=excluded.path, name=excluded.name, source=excluded.source, updated_at=excluded.updated_at",
            .{
                .id = limbo.text(doc.id),
                .path = if (doc.path) |p| limbo.text(p) else null,
                .name = if (doc.name) |n| limbo.text(n) else null,
                .source = limbo.text(doc.source),
                .updated_at = doc.updated_at,
            },
        );
    }

    pub fn getDoc(self: *Store, id: []const u8) !?circuitry_docs {
        const Row = struct {
            id: limbo.Text,
            path: ?limbo.Text,
            name: ?limbo.Text,
            source: limbo.Text,
            updated_at: i64,
        };
        var stmt = try self.workspace_db.prepare(struct { id: limbo.Text }, Row, "select id, path, name, source, updated_at from circuitry_docs where id = :id");
        defer stmt.finalize();
        try stmt.bind(.{ .id = limbo.text(id) });
        if (try stmt.step()) |row| {
            return circuitry_docs{
                .id = try self.allocator.dupe(u8, row.id.data),
                .path = if (row.path) |p| try self.allocator.dupe(u8, p.data) else null,
                .name = if (row.name) |n| try self.allocator.dupe(u8, n.data) else null,
                .source = try self.allocator.dupe(u8, row.source.data),
                .updated_at = row.updated_at,
            };
        }
        return null;
    }

    pub fn freeDoc(self: *Store, doc: circuitry_docs) void {
        self.allocator.free(doc.id);
        if (doc.path) |p| self.allocator.free(p);
        if (doc.name) |n| self.allocator.free(n);
        self.allocator.free(doc.source);
    }

    // --- Runs ---
    pub fn insertRun(self: *Store, run_obj: runs) !void {
        try self.workspace_db.exec(
            "insert into runs(id, doc_id, status, started_at, finished_at) values (:id, :doc_id, :status, :started_at, :finished_at) on conflict(id) do update set status=excluded.status, finished_at=excluded.finished_at",
            .{
                .id = limbo.text(run_obj.id),
                .doc_id = if (run_obj.doc_id) |d| limbo.text(d) else null,
                .status = if (run_obj.status) |s| limbo.text(s) else null,
                .started_at = run_obj.started_at,
                .finished_at = run_obj.finished_at,
            },
        );
    }

    pub fn getRun(self: *Store, id: []const u8) !?runs {
        const Row = struct {
            id: limbo.Text,
            doc_id: ?limbo.Text,
            status: ?limbo.Text,
            started_at: ?i64,
            finished_at: ?i64,
        };
        var stmt = try self.workspace_db.prepare(struct { id: limbo.Text }, Row, "select id, doc_id, status, started_at, finished_at from runs where id = :id");
        defer stmt.finalize();
        try stmt.bind(.{ .id = limbo.text(id) });
        if (try stmt.step()) |row| {
            return runs{
                .id = try self.allocator.dupe(u8, row.id.data),
                .doc_id = if (row.doc_id) |d| try self.allocator.dupe(u8, d.data) else null,
                .status = if (row.status) |s| try self.allocator.dupe(u8, s.data) else null,
                .started_at = row.started_at,
                .finished_at = row.finished_at,
            };
        }
        return null;
    }

    // --- Actions ---
    pub fn insertAction(self: *Store, act: actions) !void {
        try self.workspace_db.exec(
            "insert into actions(id, run_id, seq, action, cwd, status, approval, stdout_uri, stderr_uri, metadata_json) values (:id, :run_id, :seq, :action, :cwd, :status, :approval, :stdout_uri, :stderr_uri, :metadata_json)",
            .{
                .id = limbo.text(act.id),
                .run_id = if (act.run_id) |r| limbo.text(r) else null,
                .seq = act.seq,
                .action = if (act.action) |a| limbo.text(a) else null,
                .cwd = if (act.cwd) |c| limbo.text(c) else null,
                .status = if (act.status) |s| limbo.text(s) else null,
                .approval = if (act.approval) |ap| limbo.text(ap) else null,
                .stdout_uri = if (act.stdout_uri) |o| limbo.text(o) else null,
                .stderr_uri = if (act.stderr_uri) |se| limbo.text(se) else null,
                .metadata_json = if (act.metadata_json) |m| limbo.text(m) else null,
            },
        );
    }

    pub fn listActions(self: *Store, run_id: []const u8) ![]actions {
        const Row = struct {
            id: limbo.Text,
            run_id: ?limbo.Text,
            seq: i64,
            action: ?limbo.Text,
            cwd: ?limbo.Text,
            status: ?limbo.Text,
            approval: ?limbo.Text,
            stdout_uri: ?limbo.Text,
            stderr_uri: ?limbo.Text,
            metadata_json: ?limbo.Text,
        };
        var stmt = try self.workspace_db.prepare(struct { run_id: limbo.Text }, Row, "select id, run_id, seq, action, cwd, status, approval, stdout_uri, stderr_uri, metadata_json from actions where run_id = :run_id order by seq asc");
        defer stmt.finalize();
        try stmt.bind(.{ .run_id = limbo.text(run_id) });
        var list: std.ArrayList(actions) = .empty;
        errdefer {
            for (list.items) |act| self.freeAction(act);
            list.deinit(self.allocator);
        }
        while (try stmt.step()) |row| {
            try list.append(self.allocator, actions{
                .id = try self.allocator.dupe(u8, row.id.data),
                .run_id = if (row.run_id) |r| try self.allocator.dupe(u8, r.data) else null,
                .seq = row.seq,
                .action = if (row.action) |a| try self.allocator.dupe(u8, a.data) else null,
                .cwd = if (row.cwd) |c| try self.allocator.dupe(u8, c.data) else null,
                .status = if (row.status) |s| try self.allocator.dupe(u8, s.data) else null,
                .approval = if (row.approval) |ap| try self.allocator.dupe(u8, ap.data) else null,
                .stdout_uri = if (row.stdout_uri) |o| try self.allocator.dupe(u8, o.data) else null,
                .stderr_uri = if (row.stderr_uri) |se| try self.allocator.dupe(u8, se.data) else null,
                .metadata_json = if (row.metadata_json) |m| try self.allocator.dupe(u8, m.data) else null,
            });
        }
        return list.toOwnedSlice(self.allocator);
    }

    pub fn freeAction(self: *Store, act: actions) void {
        self.allocator.free(act.id);
        if (act.run_id) |r| self.allocator.free(r);
        if (act.action) |a| self.allocator.free(a);
        if (act.cwd) |c| self.allocator.free(c);
        if (act.status) |s| self.allocator.free(s);
        if (act.approval) |ap| self.allocator.free(ap);
        if (act.stdout_uri) |o| self.allocator.free(o);
        if (act.stderr_uri) |se| self.allocator.free(se);
        if (act.metadata_json) |m| self.allocator.free(m);
    }

    // --- Approvals ---
    pub fn insertApproval(self: *Store, app: approvals) !void {
        try self.workspace_db.exec(
            "insert into approvals(id, run_id, kind, subject, decision, created_at) values (:id, :run_id, :kind, :subject, :decision, :created_at) on conflict(id) do update set decision=excluded.decision",
            .{
                .id = limbo.text(app.id),
                .run_id = if (app.run_id) |r| limbo.text(r) else null,
                .kind = if (app.kind) |k| limbo.text(k) else null,
                .subject = if (app.subject) |s| limbo.text(s) else null,
                .decision = if (app.decision) |d| limbo.text(d) else null,
                .created_at = app.created_at,
            },
        );
    }

    pub fn getApprovalForSubject(self: *Store, run_id: []const u8, kind: []const u8, subject: []const u8) !?approvals {
        const Row = struct {
            id: limbo.Text,
            run_id: ?limbo.Text,
            kind: ?limbo.Text,
            subject: ?limbo.Text,
            decision: ?limbo.Text,
            created_at: ?i64,
        };
        var stmt = try self.workspace_db.prepare(struct { run_id: limbo.Text, kind: limbo.Text, subject: limbo.Text }, Row, "select id, run_id, kind, subject, decision, created_at from approvals where run_id = :run_id and kind = :kind and subject = :subject");
        defer stmt.finalize();
        try stmt.bind(.{ .run_id = limbo.text(run_id), .kind = limbo.text(kind), .subject = limbo.text(subject) });
        if (try stmt.step()) |row| {
            return approvals{
                .id = try self.allocator.dupe(u8, row.id.data),
                .run_id = if (row.run_id) |r| try self.allocator.dupe(u8, r.data) else null,
                .kind = if (row.kind) |k| try self.allocator.dupe(u8, k.data) else null,
                .subject = if (row.subject) |s| try self.allocator.dupe(u8, s.data) else null,
                .decision = if (row.decision) |d| try self.allocator.dupe(u8, d.data) else null,
                .created_at = row.created_at,
            };
        }
        return null;
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
        try self.global_db.exec("delete from packages where name = :name", .{ .name = limbo.text(name) });
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

    pub fn freePackage(self: *Store, pkg: packages) void {
        self.allocator.free(pkg.name);
        if (pkg.version) |v| self.allocator.free(v);
        if (pkg.source) |s| self.allocator.free(s);
        if (pkg.scope) |sc| self.allocator.free(sc);
        if (pkg.path) |p| self.allocator.free(p);
        if (pkg.status) |st| self.allocator.free(st);
    }
};
