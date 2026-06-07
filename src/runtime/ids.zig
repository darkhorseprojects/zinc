const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn new(allocator: Allocator, prefix: []const u8) ![]u8 {
    var bytes: [8]u8 = undefined;
    randomBytes(&bytes);
    return std.fmt.allocPrint(allocator, "{s}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ prefix, bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7] });
}

pub fn timestamp(allocator: Allocator) ![]u8 {
    const ts = std.Io.Clock.real.now(std.Options.debug_io);
    const ns = @max(ts.nanoseconds, 0);
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(ns, std.time.ns_per_s)) };
    const day = epoch.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const s = epoch.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ day.year, md.month.numeric(), md.day_index + 1, s.getHoursIntoDay(), s.getMinutesIntoHour(), s.getSecondsIntoMinute(), @as(u64, @intCast(@mod(ns, std.time.ns_per_s))) / std.time.ns_per_ms });
}

fn randomBytes(bytes: []u8) void {
    const ts = std.Io.Clock.real.now(std.Options.debug_io);
    var prng = std.Random.DefaultPrng.init(@as(u64, @truncate(@as(u96, @bitCast(ts.nanoseconds)))));
    prng.random().bytes(bytes);
}
