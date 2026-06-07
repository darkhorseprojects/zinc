const std = @import("std");
const sqlite = @import("sqlite");

const Allocator = std.mem.Allocator;
const c = sqlite.c;

fn throw(code: c_int) !void {
    if ((code & 0xff) == c.SQLITE_OK) return;
    return sqlite.Error.SQLITE_ERROR;
}

pub fn query(allocator: Allocator, path: []const u8, sql: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var db: ?*c.sqlite3 = null;
    try throw(c.sqlite3_open_v2(path_z.ptr, &db, c.SQLITE_OPEN_READONLY, null));
    defer _ = c.sqlite3_close_v2(db);
    var stmt: ?*c.sqlite3_stmt = null;
    try throw(c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null));
    defer _ = c.sqlite3_finalize(stmt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const cols: usize = @intCast(c.sqlite3_column_count(stmt));
    if (cols == 0) return allocator.dupe(u8, "ok\n");
    for (0..cols) |i| {
        if (i != 0) try out.append(allocator, '\t');
        try out.appendSlice(allocator, std.mem.span(c.sqlite3_column_name(stmt, @intCast(i))));
    }
    try out.append(allocator, '\n');
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) try throw(rc);
        for (0..cols) |i| {
            if (i != 0) try out.append(allocator, '\t');
            if (c.sqlite3_column_text(stmt, @intCast(i))) |ptr| {
                try out.appendSlice(allocator, std.mem.span(ptr));
            } else try out.appendSlice(allocator, "null");
        }
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

pub fn tables(allocator: Allocator, path: []const u8) ![]u8 {
    return query(allocator, path, "select name, type from sqlite_schema where type in ('table','view') and name not like 'sqlite_%' order by type, name");
}

pub fn schema(allocator: Allocator, path: []const u8) ![]u8 {
    return query(allocator, path, "select sql from sqlite_schema where sql is not null and name not like 'sqlite_%' order by type, name");
}
