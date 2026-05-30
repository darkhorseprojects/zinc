const std = @import("std");
const files = @import("../sys/fs.zig");
const provider = @import("provider.zig");
const tools = @import("tools.zig");

const Allocator = std.mem.Allocator;
const first_message_count: usize = 6;

pub const ToolResult = tools.ToolResult;

pub const Session = struct {
    id: []u8,
    path: []u8,
    pub fn deinit(self: Session, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
    }
};

pub const Message = struct {
    role: []u8,
    content: []u8,
    name: ?[]u8 = null,
    tool_call_id: ?[]u8 = null,
    tool_calls: []provider.ToolCall = &.{},
    fn deinit(self: Message, allocator: Allocator) void {
        allocator.free(self.role);
        allocator.free(self.content);
        if (self.name) |v| allocator.free(v);
        if (self.tool_call_id) |v| allocator.free(v);
        for (self.tool_calls) |call| freeCall(allocator, call);
        if (self.tool_calls.len != 0) allocator.free(self.tool_calls);
    }
};

pub const Compaction = struct {
    message_count: usize,
    summary: []u8,
    fn deinit(self: Compaction, allocator: Allocator) void {
        allocator.free(self.summary);
    }
};

pub const Log = struct {
    raw: []u8,
    messages: []Message,
    compaction: ?Compaction,

    pub fn deinit(self: Log, allocator: Allocator) void {
        allocator.free(self.raw);
        for (self.messages) |message| message.deinit(allocator);
        allocator.free(self.messages);
        if (self.compaction) |c| c.deinit(allocator);
    }
    pub fn messageCount(self: Log) usize {
        return self.messages.len;
    }

    pub fn transcript(self: Log, allocator: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        const first_end: usize = @min(first_message_count, self.messages.len);
        for (self.messages[0..first_end], 0..) |message, i| try renderMessageSmart(allocator, &out, message, i);
        var tail_start = first_end;
        if (self.compaction) |c| {
            tail_start = @max(first_end, @as(usize, @min(c.message_count, self.messages.len)));
            try out.print(allocator, "compaction_summary: {s}\n", .{c.summary});
        }
        for (self.messages[tail_start..], 0..) |message, i| {
            try renderMessageSmart(allocator, &out, message, tail_start + i);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn appendReplayMessages(self: Log, allocator: Allocator, out: *std.ArrayList(provider.Message), focused_context: []const u8) !void {
        const first_end: usize = @min(first_message_count, self.messages.len);
        for (self.messages[0..first_end]) |message| try appendReplayMessage(allocator, out, message);
        var tail_start = first_end;
        if (self.compaction) |c| {
            tail_start = @max(first_end, @as(usize, @min(c.message_count, self.messages.len)));
            const summary = try std.fmt.allocPrint(allocator, "Compacted middle conversation summary. This summary covers prior messages before the following transcript tail.\n{s}", .{c.summary});
            defer allocator.free(summary);
            try provider.appendMessage(allocator, out, .{ .role = "user", .content = summary });
        }
        for (self.messages[tail_start..]) |message| try appendReplayMessage(allocator, out, message);
        if (std.mem.trim(u8, focused_context, " \t\r\n").len != 0) try provider.appendMessage(allocator, out, .{ .role = "user", .content = focused_context });
    }
};

pub fn open(allocator: Allocator, resume_id: ?[]const u8, continue_last: bool) !Session {
    try files.mkdirP(".zinc/sessions");
    const id = if (continue_last) try readLastId(allocator) else if (resume_id) |given| blk: {
        try validateId(given);
        break :blk try allocator.dupe(u8, given);
    } else try newId(allocator);
    errdefer allocator.free(id);
    const path = try std.fmt.allocPrint(allocator, ".zinc/sessions/{s}.jsonl", .{id});
    errdefer allocator.free(path);
    if (resume_id != null or continue_last) {
        if (files.exists(path)) |_| {} else |_| return error.SessionNotFound;
    } else try writeSessionStart(allocator, path, id);
    return .{ .id = id, .path = path };
}

pub fn rememberLast(session: Session) !void {
    try files.write(".zinc/sessions/last", session.id);
}
pub fn readLog(allocator: Allocator, path: []const u8) ![]u8 {
    return files.readLimited(allocator, path, std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound, error.ReadFailed => try allocator.dupe(u8, ""),
        else => err,
    };
}
pub fn readParsed(allocator: Allocator, path: []const u8) !Log {
    return parseOwnedRaw(allocator, try readLog(allocator, path));
}
pub fn parseRaw(allocator: Allocator, raw: []const u8) !Log {
    return parseOwnedRaw(allocator, try allocator.dupe(u8, raw));
}

pub fn appendUserMessage(allocator: Allocator, path: []const u8, content: []const u8) !void {
    try appendMessage(allocator, path, .{ .role = "user", .content = content });
}
pub fn appendAssistantText(allocator: Allocator, path: []const u8, content: []const u8) !void {
    try appendMessage(allocator, path, .{ .role = "assistant", .content = content });
}
pub fn appendAssistantToolCalls(allocator: Allocator, path: []const u8, content: []const u8, calls: []const provider.ToolCall) !void {
    try appendMessage(allocator, path, .{ .role = "assistant", .content = content, .tool_calls = calls });
}
pub fn appendProviderError(allocator: Allocator, path: []const u8, message: []const u8) !void {
    try appendError(allocator, path, "provider_error", message);
}
pub fn appendContractError(allocator: Allocator, path: []const u8, message: []const u8) !void {
    try appendError(allocator, path, "contract_error", message);
}

pub fn appendInvalidToolCallAttempt(allocator: Allocator, path: []const u8, call: provider.ToolCall, result: []const u8) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try beginRow(allocator, &line, "invalid_tool_call");
    try line.appendSlice(allocator, ",\"call\":");
    try writeToolCall(allocator, &line, call);
    try line.appendSlice(allocator, ",\"error\":");
    try files.appendJsonString(allocator, &line, result);
    try line.appendSlice(allocator, "}\n");
    try appendLine(path, line.items);
}

pub fn appendToolResult(allocator: Allocator, path: []const u8, call: provider.ToolCall, result: ToolResult) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try beginRow(allocator, &line, "tool");
    try line.appendSlice(allocator, ",\"name\":");
    try files.appendJsonString(allocator, &line, call.name);
    try line.appendSlice(allocator, ",\"tool_call_id\":");
    try files.appendJsonString(allocator, &line, call.id);
    try line.appendSlice(allocator, ",\"ok\":");
    try line.appendSlice(allocator, if (result.is_error) "false" else "true");
    try line.appendSlice(allocator, ",\"content\":");
    try files.appendJsonString(allocator, &line, result.content);
    if (result.metadata_json) |metadata| {
        try line.appendSlice(allocator, ",\"result\":");
        try line.appendSlice(allocator, metadata);
    }
    try line.appendSlice(allocator, "}\n");
    try appendLine(path, line.items);
}

pub fn appendCompaction(allocator: Allocator, path: []const u8, message_count: usize, summary: []const u8) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try beginRow(allocator, &line, "compaction");
    try line.print(allocator, ",\"message_count\":{d},\"summary\":", .{message_count});
    try files.appendJsonString(allocator, &line, summary);
    try line.appendSlice(allocator, "}\n");
    try appendLine(path, line.items);
}

fn parseOwnedRaw(allocator: Allocator, raw: []u8) !Log {
    errdefer allocator.free(raw);
    var messages: std.ArrayList(Message) = .empty;
    errdefer freeMessages(allocator, messages.items);
    var compaction: ?Compaction = null;
    errdefer if (compaction) |c| c.deinit(allocator);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const row = parsed.value.object;
        const typ = stringField(row, "type") orelse continue;
        if (std.mem.eql(u8, typ, "message")) try messages.append(allocator, try readMessage(allocator, row)) else if (std.mem.eql(u8, typ, "tool")) try messages.append(allocator, try readToolMessage(allocator, row)) else if (std.mem.eql(u8, typ, "compaction")) {
            const count = row.get("message_count") orelse continue;
            const summary = stringField(row, "summary") orelse continue;
            if (count != .integer or count.integer < 0) continue;
            if (compaction) |old| old.deinit(allocator);
            compaction = .{ .message_count = @intCast(count.integer), .summary = try allocator.dupe(u8, summary) };
        }
    }
    return .{ .raw = raw, .messages = try messages.toOwnedSlice(allocator), .compaction = compaction };
}

fn writeSessionStart(allocator: Allocator, path: []const u8, id: []const u8) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try beginRow(allocator, &line, "session");
    try line.appendSlice(allocator, ",\"version\":3,\"runtime\":\"zinc\",\"id\":");
    try files.appendJsonString(allocator, &line, id);
    try line.appendSlice(allocator, "}\n");
    try files.write(path, line.items);
}

fn appendMessage(allocator: Allocator, path: []const u8, message: provider.Message) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try beginRow(allocator, &line, "message");
    try line.appendSlice(allocator, ",\"role\":");
    try files.appendJsonString(allocator, &line, message.role);
    try line.appendSlice(allocator, ",\"content\":");
    try files.appendJsonString(allocator, &line, message.content);
    if (message.name) |name| {
        try line.appendSlice(allocator, ",\"name\":");
        try files.appendJsonString(allocator, &line, name);
    }
    if (message.tool_call_id) |id| {
        try line.appendSlice(allocator, ",\"tool_call_id\":");
        try files.appendJsonString(allocator, &line, id);
    }
    if (message.tool_calls.len != 0) {
        try line.appendSlice(allocator, ",\"tool_calls\":[");
        for (message.tool_calls, 0..) |call, i| {
            if (i != 0) try line.append(allocator, ',');
            try writeToolCall(allocator, &line, call);
        }
        try line.append(allocator, ']');
    }
    try line.appendSlice(allocator, "}\n");
    try appendLine(path, line.items);
}

fn appendError(allocator: Allocator, path: []const u8, kind: []const u8, message: []const u8) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try beginRow(allocator, &line, kind);
    try line.appendSlice(allocator, ",\"message\":");
    try files.appendJsonString(allocator, &line, message);
    try line.appendSlice(allocator, "}\n");
    try appendLine(path, line.items);
}

fn beginRow(allocator: Allocator, out: *std.ArrayList(u8), kind: []const u8) !void {
    const t = try timestamp(allocator);
    defer allocator.free(t);
    try out.appendSlice(allocator, "{\"t\":");
    try files.appendJsonString(allocator, out, t);
    try out.appendSlice(allocator, ",\"type\":");
    try files.appendJsonString(allocator, out, kind);
}

fn timestamp(allocator: Allocator) ![]u8 {
    var ts: std.os.linux.timespec = undefined;
    if (std.os.linux.errno(std.os.linux.clock_gettime(.REALTIME, &ts)) != .SUCCESS) return error.ClockFailed;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts.sec) };
    const day = epoch.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const s = epoch.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ day.year, md.month.numeric(), md.day_index + 1, s.getHoursIntoDay(), s.getMinutesIntoHour(), s.getSecondsIntoMinute(), @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms });
}

fn readMessage(allocator: Allocator, row: std.json.ObjectMap) !Message {
    return .{ .role = try dupeField(allocator, row, "role"), .content = try allocator.dupe(u8, stringField(row, "content") orelse ""), .name = try optionalField(allocator, row, "name"), .tool_call_id = try optionalField(allocator, row, "tool_call_id"), .tool_calls = try readToolCalls(allocator, row) };
}
fn readToolMessage(allocator: Allocator, row: std.json.ObjectMap) !Message {
    return .{ .role = try allocator.dupe(u8, "tool"), .content = try allocator.dupe(u8, stringField(row, "content") orelse ""), .name = try optionalField(allocator, row, "name"), .tool_call_id = try optionalField(allocator, row, "tool_call_id") };
}
fn readToolCalls(allocator: Allocator, row: std.json.ObjectMap) ![]provider.ToolCall {
    const value = row.get("tool_calls") orelse return &.{};
    if (value != .array) return &.{};
    var out = try allocator.alloc(provider.ToolCall, value.array.items.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |call| freeCall(allocator, call);
        allocator.free(out);
    }
    for (value.array.items, 0..) |item, i| {
        if (item != .object) return error.BadSessionLog;
        out[i] = .{ .id = try dupeField(allocator, item.object, "id"), .name = try dupeField(allocator, item.object, "name"), .arguments = try dupeField(allocator, item.object, "arguments") };
        n += 1;
    }
    return out;
}

fn writeToolCall(allocator: Allocator, out: *std.ArrayList(u8), call: provider.ToolCall) !void {
    try out.appendSlice(allocator, "{\"id\":");
    try files.appendJsonString(allocator, out, call.id);
    try out.appendSlice(allocator, ",\"name\":");
    try files.appendJsonString(allocator, out, call.name);
    try out.appendSlice(allocator, ",\"arguments\":");
    try files.appendJsonString(allocator, out, call.arguments);
    try out.append(allocator, '}');
}
fn renderMessage(allocator: Allocator, out: *std.ArrayList(u8), message: Message) !void {
    if (std.mem.eql(u8, message.role, "assistant") and message.tool_calls.len != 0) {
        for (message.tool_calls) |call| try out.print(allocator, "assistant tool call {s} {s}\n", .{ call.name, call.arguments });
        return;
    }
    if (std.mem.eql(u8, message.role, "tool")) return out.print(allocator, "tool {s} call_id={s}: {s}\n", .{ message.name orelse "", message.tool_call_id orelse "", message.content });
    try out.print(allocator, "{s}: {s}\n", .{ message.role, message.content });
}
fn appendReplayMessage(allocator: Allocator, out: *std.ArrayList(provider.Message), message: Message) !void {
    if (std.mem.eql(u8, message.role, "user") or std.mem.eql(u8, message.role, "assistant") or std.mem.eql(u8, message.role, "tool")) try provider.appendMessage(allocator, out, .{ .role = message.role, .content = message.content, .name = message.name, .tool_call_id = message.tool_call_id, .tool_calls = message.tool_calls });
}

fn appendLine(path: []const u8, line: []const u8) !void {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .APPEND = true }, 0);
    defer _ = std.os.linux.close(fd);
    var n: usize = 0;
    while (n < line.len) n += try files.linuxWrite(fd, line[n..]);
}
pub fn readLastId(allocator: Allocator) ![]u8 {
    const raw = try files.readLimited(allocator, ".zinc/sessions/last", 256);
    defer allocator.free(raw);
    const id = std.mem.trim(u8, raw, " \t\r\n");
    try validateId(id);
    return allocator.dupe(u8, id);
}
fn newId(allocator: Allocator) ![]u8 {
    var bytes: [8]u8 = undefined;
    const rc = std.os.linux.getrandom(&bytes, bytes.len, 0);
    if (std.os.linux.errno(rc) != .SUCCESS or rc != bytes.len) return error.RandomFailed;
    return std.fmt.allocPrint(allocator, "s{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7] });
}
fn validateId(id: []const u8) !void {
    if (id.len == 0 or id.len > 96) return error.InvalidSessionId;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidSessionId;
}
fn stringField(row: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = row.get(name) orelse return null;
    return if (value == .string) value.string else null;
}
fn dupeField(allocator: Allocator, row: std.json.ObjectMap, name: []const u8) ![]u8 {
    return allocator.dupe(u8, stringField(row, name) orelse return error.BadSessionLog);
}
fn optionalField(allocator: Allocator, row: std.json.ObjectMap, name: []const u8) !?[]u8 {
    return if (stringField(row, name)) |v| try allocator.dupe(u8, v) else null;
}
fn freeMessages(allocator: Allocator, messages: []Message) void {
    for (messages) |message| message.deinit(allocator);
    allocator.free(messages);
}
fn freeCall(allocator: Allocator, call: provider.ToolCall) void {
    allocator.free(call.id);
    allocator.free(call.name);
    allocator.free(call.arguments);
}

fn renderMessageSmart(allocator: Allocator, out: *std.ArrayList(u8), message: Message, index: usize) !void {
    if (std.mem.eql(u8, message.role, "assistant") and message.tool_calls.len != 0) {
        for (message.tool_calls) |call| try out.print(allocator, "assistant tool call {s} {s}\n", .{ call.name, call.arguments });
        return;
    }
    if (std.mem.eql(u8, message.role, "tool")) {
        const content = try truncateMessageContent(allocator, message, index);
        defer allocator.free(content);
        try out.print(allocator, "tool {s} call_id={s}: {s}\n", .{ message.name orelse "", message.tool_call_id orelse "", content });
        return;
    }
    const content = try truncateMessageContent(allocator, message, index);
    defer allocator.free(content);
    try out.print(allocator, "{s}: {s}\n", .{ message.role, content });
}

fn truncateMessageContent(allocator: Allocator, message: Message, index: usize) ![]u8 {
    const content = message.content;
    const max_preview = 2048;

    if (content.len <= max_preview) {
        return try allocator.dupe(u8, content);
    }

    const preview = content[0..max_preview];
    if (std.mem.eql(u8, message.role, "tool")) {
        const call_id = message.tool_call_id orelse "";
        return std.fmt.allocPrint(allocator, "{s}... [truncated, {d} chars - use session:current:tools:{s} for full]", .{ preview, content.len, call_id });
    } else {
        return std.fmt.allocPrint(allocator, "{s}... [truncated, {d} chars - use session:current:messages:{d} for full]", .{ preview, content.len, index });
    }
}
