const std = @import("std");
const sqlite = @import("sqlite");
const files = @import("fs.zig");
const ids = @import("../runtime/ids.zig");
const schema = @import("../runtime/schema.zig");

pub const Span = struct {
    name: []const u8,
    start_ns: u64,

    pub fn end(self: Span, subsystem: []const u8, comptime fmt: []const u8, args: anytype) void {
        const elapsed_ms = elapsedMillis(self.start_ns);
        event(subsystem, self.name, "ms={d} " ++ fmt, .{elapsed_ms} ++ args);
    }
};

pub fn span(name: []const u8) Span {
    return .{ .name = name, .start_ns = monotonicNanos() };
}

pub fn event(component: []const u8, topic: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!files.existsPath(".zinc")) return;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print(fmt, args) catch return;
    writeLocalLog(component, topic, writer.buffered()) catch return;
}

fn writeLocalLog(component: []const u8, topic: []const u8, message: []const u8) !void {
    const allocator = std.heap.page_allocator;
    try files.mkdirP(".zinc/runtime");
    const path_z: [:0]u8 = try allocator.dupeZ(u8, ".zinc/runtime/zinc.db");
    defer allocator.free(path_z);
    const db = try sqlite.Database.open(.{ .path = path_z.ptr, .mode = .ReadWrite, .create = true });
    defer db.close();
    try schema.configure(db);
    try schema.migrate(db);
    const now = try ids.timestamp(allocator);
    defer allocator.free(now);
    var fields: [256]u8 = undefined;
    var fields_writer = std.Io.Writer.fixed(&fields);
    fields_writer.print("{{\"topic\":\"{s}\"}}", .{topic}) catch return;
    try db.exec(
        \\insert into logs(time, level, component, message, fields_json)
        \\values (:time, 'debug', :component, :message, :fields_json)
    , .{ .time = sqlite.text(now), .component = sqlite.text(component), .message = sqlite.text(message), .fields_json = sqlite.text(fields_writer.buffered()) });
}

pub fn monotonicNanos() u64 {
    const ts = std.Io.Clock.awake.now(std.Options.debug_io);
    return @intCast(@max(ts.nanoseconds, 0));
}

pub fn elapsedMillis(start_ns: u64) u64 {
    const now = monotonicNanos();
    if (now <= start_ns) return 0;
    return (now - start_ns) / std.time.ns_per_ms;
}
