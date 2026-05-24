const std = @import("std");
const provider = @import("provider.zig");

const Allocator = std.mem.Allocator;

const first_message_count = 6;

const StoredMessage = struct {
    role: []u8,
    content: []u8,

    fn deinit(self: StoredMessage, allocator: Allocator) void {
        allocator.free(self.role);
        allocator.free(self.content);
    }
};

const Compaction = struct {
    message_count: usize,
    summary: []u8,

    fn deinit(self: Compaction, allocator: Allocator) void {
        allocator.free(self.summary);
    }
};

pub fn appendPriorContext(
    allocator: Allocator,
    messages: *std.ArrayList(provider.Message),
    session_log: []const u8,
    focused_context: []const u8,
) !void {
    const stored = try readStoredMessages(allocator, session_log);
    defer freeStoredMessages(allocator, stored);

    const compaction = try readLastCompaction(allocator, session_log);
    defer if (compaction) |c| c.deinit(allocator);

    try appendWindowedMessages(allocator, messages, stored, compaction);
    if (std.mem.trim(u8, focused_context, " \t\r\n").len != 0) {
        const content = try std.fmt.allocPrint(allocator,
            \\Extra context selected by the focused recovery graph agent. This is background only; prefer the current conversation when it conflicts.
            \\{s}
        , .{focused_context});
        defer allocator.free(content);
        try provider.appendMessage(allocator, messages, .{ .role = "user", .content = content });
    }
}

pub fn buildPriorContextText(allocator: Allocator, session_log: []const u8) ![]u8 {
    const stored = try readStoredMessages(allocator, session_log);
    defer freeStoredMessages(allocator, stored);
    const compaction = try readLastCompaction(allocator, session_log);
    defer if (compaction) |c| c.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const first_end: usize = @min(@as(usize, first_message_count), stored.len);
    for (stored[0..first_end]) |message| try out.print(allocator, "{s}: {s}\n", .{ message.role, message.content });
    var tail_start = first_end;
    if (compaction) |c| {
        const covered: usize = @min(c.message_count, stored.len);
        tail_start = @max(first_end, covered);
        try out.print(allocator, "compaction_summary: {s}\n", .{c.summary});
    }
    for (stored[tail_start..]) |message| try out.print(allocator, "{s}: {s}\n", .{ message.role, message.content });
    return out.toOwnedSlice(allocator);
}

fn appendWindowedMessages(
    allocator: Allocator,
    messages: *std.ArrayList(provider.Message),
    stored: []const StoredMessage,
    compaction: ?Compaction,
) !void {
    const first_end: usize = @min(@as(usize, first_message_count), stored.len);
    for (stored[0..first_end]) |message| try appendStoredMessage(allocator, messages, message);

    var tail_start = first_end;
    if (compaction) |c| {
        const covered: usize = @min(c.message_count, stored.len);
        tail_start = @max(first_end, covered);
        const summary = try std.fmt.allocPrint(allocator,
            \\Compacted middle conversation summary. This summary covers prior messages before the following transcript tail.
            \\{s}
        , .{c.summary});
        defer allocator.free(summary);
        try provider.appendMessage(allocator, messages, .{ .role = "user", .content = summary });
    }

    for (stored[tail_start..]) |message| try appendStoredMessage(allocator, messages, message);
}

fn appendStoredMessage(allocator: Allocator, messages: *std.ArrayList(provider.Message), message: StoredMessage) !void {
    if (!isReplayableRole(message.role)) return;
    try provider.appendMessage(allocator, messages, .{ .role = message.role, .content = message.content });
}

fn isReplayableRole(role: []const u8) bool {
    return std.mem.eql(u8, role, "user") or std.mem.eql(u8, role, "assistant") or std.mem.eql(u8, role, "system");
}

fn readStoredMessages(allocator: Allocator, log: []const u8) ![]StoredMessage {
    var out: std.ArrayList(StoredMessage) = .empty;
    errdefer freeStoredMessages(allocator, out.items);

    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const root = parsed.value.object;
        const typ = readString(root, "type") orelse continue;
        if (!std.mem.eql(u8, typ, "message")) continue;
        const message_value = root.get("message") orelse continue;
        if (message_value != .object) continue;
        const role = readString(message_value.object, "role") orelse continue;
        const content = readString(message_value.object, "content") orelse continue;
        const item = StoredMessage{
            .role = try allocator.dupe(u8, role),
            .content = try allocator.dupe(u8, content),
        };
        try out.append(allocator, item);
    }
    return out.toOwnedSlice(allocator);
}

fn readLastCompaction(allocator: Allocator, log: []const u8) !?Compaction {
    var last: ?Compaction = null;
    errdefer if (last) |c| c.deinit(allocator);

    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const root = parsed.value.object;
        const typ = readString(root, "type") orelse continue;
        if (!std.mem.eql(u8, typ, "compaction")) continue;
        const summary = readString(root, "summary") orelse continue;
        const message_count_value = root.get("message_count") orelse continue;
        if (message_count_value != .integer or message_count_value.integer < 0) continue;
        if (last) |old| old.deinit(allocator);
        last = .{
            .message_count = @intCast(message_count_value.integer),
            .summary = try allocator.dupe(u8, summary),
        };
    }
    return last;
}

fn readString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn freeStoredMessages(allocator: Allocator, messages: []StoredMessage) void {
    for (messages) |message| message.deinit(allocator);
    allocator.free(messages);
}

test "context replay keeps exact prior turns without compaction" {
    const log =
        \\{"type":"message","message":{"role":"user","content":"what does youtube contain"}}
        \\{"type":"message","message":{"role":"assistant","content":"guess"}}
        \\
    ;
    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    defer provider.freeMessages(std.testing.allocator, messages.items);
    try appendPriorContext(std.testing.allocator, &messages, log, "");
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("user", messages.items[0].role);
    try std.testing.expectEqualStrings("what does youtube contain", messages.items[0].content);
}

test "last compaction replaces covered middle" {
    const log =
        \\{"type":"message","message":{"role":"user","content":"first"}}
        \\{"type":"message","message":{"role":"assistant","content":"second"}}
        \\{"type":"compaction","message_count":2,"summary":"middle summary"}
        \\{"type":"message","message":{"role":"user","content":"tail"}}
        \\
    ;
    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(std.testing.allocator);
    defer provider.freeMessages(std.testing.allocator, messages.items);
    try appendPriorContext(std.testing.allocator, &messages, log, "selected old fact");
    try std.testing.expectEqual(@as(usize, 5), messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, messages.items[2].content, "middle summary") != null);
    try std.testing.expectEqualStrings("tail", messages.items[3].content);
    try std.testing.expect(std.mem.indexOf(u8, messages.items[4].content, "selected old fact") != null);
}
