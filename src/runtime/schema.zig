const sqlite = @import("sqlite");

pub fn configure(db: sqlite.Database) !void {
    try db.exec("pragma journal_mode = WAL", .{});
    try db.exec("pragma synchronous = NORMAL", .{});
    try db.exec("pragma foreign_keys = ON", .{});
    try db.exec("pragma busy_timeout = 5000", .{});
}

pub fn migrate(db: sqlite.Database) !void {
    try db.exec("create table if not exists schema_version (version integer not null)", .{});
    try db.exec("create table if not exists meta (key text primary key, value_json text not null)", .{});
    try db.exec("create table if not exists sessions (id text primary key, title text, cwd text not null, created_at text not null, updated_at text not null, current_branch text not null default 'main', status text not null default 'active')", .{});
    try db.exec("create table if not exists events (id text primary key, session_id text not null references sessions(id), parent_id text references events(id), branch text not null, type text not null, source_kind text not null, source_name text not null, time text not null, summary text, payload_json text not null)", .{});
    try db.exec("create index if not exists events_session_time on events(session_id, time)", .{});
    try db.exec("create index if not exists events_session_branch_time on events(session_id, branch, time)", .{});
    try db.exec("create index if not exists events_parent on events(parent_id)", .{});
    try db.exec("create index if not exists events_type on events(type)", .{});
    try db.exec("create index if not exists events_source on events(source_kind, source_name)", .{});
    try db.exec("create table if not exists branch_heads (session_id text not null references sessions(id), branch text not null, head_event_id text not null references events(id), updated_at text not null, primary key (session_id, branch))", .{});
    try db.exec("create table if not exists runs (id text primary key, session_id text references sessions(id), started_at text not null, finished_at text, status text not null, command text, metadata_json text not null)", .{});
    try db.exec("create table if not exists logs (id integer primary key autoincrement, run_id text references runs(id), session_id text references sessions(id), event_id text references events(id), time text not null, level text not null, component text not null, message text not null, fields_json text not null)", .{});
    try db.exec("create index if not exists logs_run_time on logs(run_id, time)", .{});
    try db.exec("create index if not exists logs_session_time on logs(session_id, time)", .{});
    try db.exec("create index if not exists logs_event on logs(event_id)", .{});
    try db.exec("create index if not exists logs_component on logs(component)", .{});
    try db.exec("create view if not exists recent_events as select e.time, e.id, e.session_id, e.branch, e.type, e.source_name, e.summary from events e order by e.time desc", .{});
    try db.exec("create view if not exists recent_logs as select l.time, l.level, l.component, l.message, l.event_id, l.run_id from logs l order by l.time desc", .{});
    try db.exec("create view if not exists session_heads as select s.id as session_id, s.title, s.current_branch, b.head_event_id, s.updated_at from sessions s left join branch_heads b on b.session_id = s.id and b.branch = s.current_branch", .{});
}
