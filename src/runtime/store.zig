const std = @import("std");
const sqlite = @import("sqlite");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const ids = @import("ids.zig");
const schema = @import("schema.zig");
const scopes = @import("scope.zig");

const Allocator = std.mem.Allocator;

pub const Store = struct {
    allocator: Allocator,
    path: []u8,
    path_z: [:0]u8,
    db: sqlite.Database,

    pub fn open(allocator: Allocator, layout_ctx: layout.Context, scope: scopes.Scope) !Store {
        const path = try scopes.dbPath(allocator, layout_ctx, scope);
        errdefer allocator.free(path);

        const old_path = try oldDbPath(allocator, layout_ctx, scope);
        defer allocator.free(old_path);
        if (files.existsPath(old_path) and !files.existsPath(path)) {
            if (std.fs.path.dirname(path)) |dir| try files.mkdirP(dir);
            const io = std.Options.debug_io;
            std.Io.Dir.cwd().rename(old_path, std.Io.Dir.cwd(), path, io) catch {};
            
            const old_wal = try std.fmt.allocPrint(allocator, "{s}-wal", .{old_path});
            defer allocator.free(old_wal);
            const wal = try std.fmt.allocPrint(allocator, "{s}-wal", .{path});
            defer allocator.free(wal);
            std.Io.Dir.cwd().rename(old_wal, std.Io.Dir.cwd(), wal, io) catch {};

            const old_shm = try std.fmt.allocPrint(allocator, "{s}-shm", .{old_path});
            defer allocator.free(old_shm);
            const shm = try std.fmt.allocPrint(allocator, "{s}-shm", .{path});
            defer allocator.free(shm);
            std.Io.Dir.cwd().rename(old_shm, std.Io.Dir.cwd(), shm, io) catch {};
        }

        if (std.fs.path.dirname(path)) |dir| try files.mkdirP(dir);
        const path_z = try allocator.dupeZ(u8, path);
        errdefer allocator.free(path_z);
        const db = try sqlite.Database.open(.{ .path = path_z.ptr, .mode = .ReadWrite, .create = true });
        var store = Store{ .allocator = allocator, .path = path, .path_z = path_z, .db = db };
        errdefer store.close();
        try schema.configure(store.db);
        try schema.migrate(store.db);
        return store;
    }

    fn oldDbPath(allocator: Allocator, layout_ctx: layout.Context, scope: scopes.Scope) ![]u8 {
        return switch (scope) {
            .local => allocator.dupe(u8, ".zinc/runtime/zinc.db"),
            .global => layout.sharePath(allocator, layout_ctx, "runtime/zinc.db"),
        };
    }

    pub fn close(self: *Store) void {
        self.db.close();
        self.allocator.free(self.path_z);
        self.allocator.free(self.path);
    }

    pub fn lastSessionId(self: Store, allocator: Allocator) !?[]u8 {
        const Row = struct { value_json: sqlite.Text };
        const stmt = try self.db.prepare(struct {}, Row, "select value_json from meta where key = 'last_session_id'");
        defer stmt.finalize();
        try stmt.bind(.{});
        defer stmt.reset();
        const row = try stmt.step() orelse return null;
        return try parseJsonString(allocator, row.value_json.data);
    }

    pub fn setLastSessionId(self: Store, id: []const u8) !void {
        const payload = try jsonString(self.allocator, id);
        defer self.allocator.free(payload);
        try self.db.exec("insert into meta(key, value_json) values ('last_session_id', :value_json) on conflict(key) do update set value_json = excluded.value_json", .{ .value_json = sqlite.text(payload) });
    }

    pub fn ensureSession(self: Store, id: []const u8, cwd: []const u8) !void {
        const now = try ids.timestamp(self.allocator);
        defer self.allocator.free(now);
        try self.db.exec(
            "insert into sessions(id, cwd, created_at, updated_at, current_branch, status) values (:id, :cwd, :created_at, :updated_at, 'main', 'active') on conflict(id) do nothing",
            .{ .id = sqlite.text(id), .cwd = sqlite.text(cwd), .created_at = sqlite.text(now), .updated_at = sqlite.text(now) },
        );
    }

    pub fn sessionExists(self: Store, id: []const u8) !bool {
        const Row = struct { count: usize };
        const stmt = try self.db.prepare(struct { id: sqlite.Text }, Row, "select count(*) as count from sessions where id = :id");
        defer stmt.finalize();
        try stmt.bind(.{ .id = sqlite.text(id) });
        defer stmt.reset();
        const row = try stmt.step() orelse return false;
        return row.count != 0;
    }

    pub fn appendEvent(self: Store, args: EventInsert) ![]u8 {
        const id = try ids.new(self.allocator, "e");
        errdefer self.allocator.free(id);
        const now = try ids.timestamp(self.allocator);
        defer self.allocator.free(now);
        const branch = args.branch orelse try self.currentBranchTemp(args.session_id);
        defer if (args.branch == null) self.allocator.free(branch);
        const parent = args.parent_id orelse try self.branchHeadTemp(args.session_id, branch);
        defer if (args.parent_id == null) if (parent) |p| self.allocator.free(p);
        try self.db.exec(
            \\insert into events(id, session_id, parent_id, branch, type, source_kind, source_name, time, summary, payload_json)
            \\values (:id, :session_id, :parent_id, :branch, :type, :source_kind, :source_name, :time, :summary, :payload_json)
        , .{
            .id = sqlite.text(id),
            .session_id = sqlite.text(args.session_id),
            .parent_id = if (parent) |p| sqlite.text(p) else null,
            .branch = sqlite.text(branch),
            .type = sqlite.text(args.type),
            .source_kind = sqlite.text(args.source_kind),
            .source_name = sqlite.text(args.source_name),
            .time = sqlite.text(now),
            .summary = if (args.summary) |s| sqlite.text(s) else null,
            .payload_json = sqlite.text(args.payload_json),
        });
        try self.db.exec(
            \\insert into branch_heads(session_id, branch, head_event_id, updated_at)
            \\values (:session_id, :branch, :head_event_id, :updated_at)
            \\on conflict(session_id, branch) do update set head_event_id = excluded.head_event_id, updated_at = excluded.updated_at
        , .{ .session_id = sqlite.text(args.session_id), .branch = sqlite.text(branch), .head_event_id = sqlite.text(id), .updated_at = sqlite.text(now) });
        try self.db.exec("update sessions set updated_at = :updated_at where id = :session_id", .{ .updated_at = sqlite.text(now), .session_id = sqlite.text(args.session_id) });
        return id;
    }

    pub fn writeLog(self: Store, args: LogInsert) !void {
        const now = try ids.timestamp(self.allocator);
        defer self.allocator.free(now);
        try self.db.exec(
            \\insert into logs(run_id, session_id, event_id, time, level, component, message, fields_json)
            \\values (:run_id, :session_id, :event_id, :time, :level, :component, :message, :fields_json)
        , .{
            .run_id = if (args.run_id) |v| sqlite.text(v) else null,
            .session_id = if (args.session_id) |v| sqlite.text(v) else null,
            .event_id = if (args.event_id) |v| sqlite.text(v) else null,
            .time = sqlite.text(now),
            .level = sqlite.text(args.level),
            .component = sqlite.text(args.component),
            .message = sqlite.text(args.message),
            .fields_json = sqlite.text(args.fields_json orelse "{}"),
        });
    }

    pub fn startRun(self: Store, session_id: []const u8, command: []const u8, metadata_json: []const u8) ![]u8 {
        const id = try ids.new(self.allocator, "r");
        errdefer self.allocator.free(id);
        const now = try ids.timestamp(self.allocator);
        defer self.allocator.free(now);
        try self.db.exec("insert into runs(id, session_id, started_at, status, command, metadata_json) values (:id, :session_id, :started_at, 'running', :command, :metadata_json)", .{ .id = sqlite.text(id), .session_id = sqlite.text(session_id), .started_at = sqlite.text(now), .command = sqlite.text(command), .metadata_json = sqlite.text(metadata_json) });
        return id;
    }

    pub fn finishRun(self: Store, id: []const u8, status: []const u8, metadata_json: ?[]const u8) !void {
        const now = try ids.timestamp(self.allocator);
        defer self.allocator.free(now);
        if (metadata_json) |meta| try self.db.exec("update runs set finished_at = :finished_at, status = :status, metadata_json = :metadata_json where id = :id", .{ .finished_at = sqlite.text(now), .status = sqlite.text(status), .metadata_json = sqlite.text(meta), .id = sqlite.text(id) }) else try self.db.exec("update runs set finished_at = :finished_at, status = :status where id = :id", .{ .finished_at = sqlite.text(now), .status = sqlite.text(status), .id = sqlite.text(id) });
    }

    pub fn currentBranch(self: Store, allocator: Allocator, session_id: []const u8) ![]u8 {
        const value = try self.currentBranchTemp(session_id);
        if (allocator.ptr == self.allocator.ptr) return value;
        defer self.allocator.free(value);
        return allocator.dupe(u8, value);
    }

    pub fn branchExists(self: Store, session_id: []const u8, branch: []const u8) !bool {
        const Row = struct { count: usize };
        const stmt = try self.db.prepare(struct { session_id: sqlite.Text, branch: sqlite.Text }, Row, "select count(*) as count from branch_heads where session_id = :session_id and branch = :branch");
        defer stmt.finalize();
        try stmt.bind(.{ .session_id = sqlite.text(session_id), .branch = sqlite.text(branch) });
        defer stmt.reset();
        const row = try stmt.step() orelse return false;
        return row.count != 0;
    }

    pub fn eventSession(self: Store, allocator: Allocator, event_id: []const u8) ![]u8 {
        const Row = struct { session_id: sqlite.Text };
        const stmt = try self.db.prepare(struct { id: sqlite.Text }, Row, "select session_id from events where id = :id");
        defer stmt.finalize();
        try stmt.bind(.{ .id = sqlite.text(event_id) });
        defer stmt.reset();
        const row = try stmt.step() orelse return error.EventNotFound;
        return allocator.dupe(u8, row.session_id.data);
    }

    pub fn createBranch(self: Store, at_event_id: []const u8, name: []const u8) ![]u8 {
        const session_id = try self.eventSession(self.allocator, at_event_id);
        defer self.allocator.free(session_id);
        return self.appendEvent(.{ .session_id = session_id, .parent_id = at_event_id, .branch = name, .type = @import("events.zig").session_branch_created, .summary = name, .payload_json = "{}" });
    }

    pub fn checkoutBranch(self: Store, session_id: []const u8, name: []const u8) ![]u8 {
        if (!try self.branchExists(session_id, name)) return error.BranchNotFound;
        try self.db.exec("update sessions set current_branch = :branch where id = :session_id", .{ .branch = sqlite.text(name), .session_id = sqlite.text(session_id) });
        return self.appendEvent(.{ .session_id = session_id, .branch = name, .type = @import("events.zig").session_branch_checked_out, .summary = name, .payload_json = "{}" });
    }

    fn currentBranchTemp(self: Store, session_id: []const u8) ![]u8 {
        const Row = struct { current_branch: sqlite.Text };
        const stmt = try self.db.prepare(struct { session_id: sqlite.Text }, Row, "select current_branch from sessions where id = :session_id");
        defer stmt.finalize();
        try stmt.bind(.{ .session_id = sqlite.text(session_id) });
        defer stmt.reset();
        const row = try stmt.step() orelse return self.allocator.dupe(u8, "main");
        return self.allocator.dupe(u8, row.current_branch.data);
    }

    fn branchHeadTemp(self: Store, session_id: []const u8, branch: []const u8) !?[]u8 {
        const Row = struct { head_event_id: sqlite.Text };
        const stmt = try self.db.prepare(struct { session_id: sqlite.Text, branch: sqlite.Text }, Row, "select head_event_id from branch_heads where session_id = :session_id and branch = :branch");
        defer stmt.finalize();
        try stmt.bind(.{ .session_id = sqlite.text(session_id), .branch = sqlite.text(branch) });
        defer stmt.reset();
        const row = try stmt.step() orelse return null;
        return try self.allocator.dupe(u8, row.head_event_id.data);
    }
};

pub const EventInsert = struct {
    session_id: []const u8,
    parent_id: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    type: []const u8,
    source_kind: []const u8 = "core",
    source_name: []const u8 = "zinc",
    summary: ?[]const u8 = null,
    payload_json: []const u8 = "{}",
};

pub const LogInsert = struct {
    run_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    event_id: ?[]const u8 = null,
    level: []const u8 = "info",
    component: []const u8,
    message: []const u8,
    fields_json: ?[]const u8 = null,
};

fn jsonString(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    try std.json.Stringify.value(value, .{}, &aw.writer);
    out = aw.toArrayList();
    return out.toOwnedSlice(allocator);
}

fn parseJsonString(allocator: Allocator, text: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    if (parsed.value != .string) return error.InvalidRuntimeStoreValue;
    return allocator.dupe(u8, parsed.value.string);
}
