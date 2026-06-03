const std = @import("std");
const files = @import("fs.zig");

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

pub fn event(subsystem: []const u8, topic: []const u8, comptime fmt: []const u8, args: anytype) void {
    files.mkdirP(".zinc/logs") catch return;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const wall = wallClockParts();
    writer.print("{d:0>2}:{d:0>2}:{d:0>2} [client][{s}] {s} ", .{ wall.hour, wall.minute, wall.second, subsystem, topic }) catch return;
    writer.print(fmt, args) catch return;
    writer.writeByte('\n') catch return;
    files.append(".zinc/logs/current.log", writer.buffered()) catch return;
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

const WallClockParts = struct { hour: u64, minute: u64, second: u64 };

fn wallClockParts() WallClockParts {
    const ts = std.Io.Clock.real.now(std.Options.debug_io);
    const seconds: u64 = @intCast(@divTrunc(@max(ts.nanoseconds, 0), std.time.ns_per_s));
    const day = seconds % std.time.s_per_day;
    return .{
        .hour = day / std.time.s_per_hour,
        .minute = (day % std.time.s_per_hour) / std.time.s_per_min,
        .second = day % std.time.s_per_min,
    };
}
