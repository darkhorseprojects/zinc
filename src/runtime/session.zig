const std = @import("std");
const sqlite = @import("sqlite");
const provider = @import("../model/provider.zig");
const tools = @import("../tools/schema.zig");
const layout = @import("../io/layout.zig");
const Store = @import("store.zig").Store;
const ids = @import("ids.zig");
const scopes = @import("scope.zig");

const Allocator = std.mem.Allocator;

pub const Session = struct {
    id: []u8,
    pub fn deinit(self: Session, allocator: Allocator) void {
        allocator.free(self.id);
    }
};

pub const Message = struct {
    role: []u8,
    content: []u8,
    model: ?[]u8 = null,
    reasoning: ?[]u8 = null,
    name: ?[]u8 = null,
    tool_call_id: ?[]u8 = null,
    tool_calls: []provider.ToolCall = &.{},

    fn deinit(self: Message, allocator: Allocator) void {
        allocator.free(self.role);
        allocator.free(self.content);
        if (self.model) |v| allocator.free(v);
        if (self.reasoning) |v| allocator.free(v);
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

pub const Recovery = struct {
    message_count: usize,
    compaction_message_count: usize,
    context: []u8,
    fn deinit(self: Recovery, allocator: Allocator) void {
        allocator.free(self.context);
    }
};

pub const ProviderUsage = struct {
    model: []u8,
    prompt_tokens: usize,
    fn deinit(self: ProviderUsage, allocator: Allocator) void {
        allocator.free(self.model);
    }
};

pub const Log = struct {
    messages: []Message,
    compaction: ?Compaction,
    recovery: ?Recovery,
    provider_usage: ?ProviderUsage,

    pub fn deinit(self: Log, allocator: Allocator) void {
        for (self.messages) |message| message.deinit(allocator);
        allocator.free(self.messages);
        if (self.compaction) |c| c.deinit(allocator);
        if (self.recovery) |r| r.deinit(allocator);
        if (self.provider_usage) |usage| usage.deinit(allocator);
    }

    pub fn messageCount(self: Log) usize {
        return self.messages.len;
    }

    pub fn latestPromptTokens(self: Log, model_id: []const u8) ?usize {
        return if (self.provider_usage) |usage| if (usage.model.len == 0 or std.mem.eql(u8, usage.model, model_id)) usage.prompt_tokens else null else null;
    }

    pub fn transcript(self: Log, allocator: Allocator, head_messages: usize, tail_messages: usize, truncate_chars: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var latest_reads = try latestReadCalls(allocator, self.messages);
        defer freeLatestReads(allocator, &latest_reads);
        const ranges = sessionContextRanges(self, head_messages, tail_messages);
        for (self.messages[0..ranges.head_end], 0..) |message, i| if (shouldIncludeInSessionContext(message, latest_reads)) try renderMessageSmart(allocator, &out, message, i, truncate_chars);
        if (self.compaction) |c| try out.print(allocator, "compaction_summary: {s}\n", .{c.summary});
        for (self.messages[ranges.tail_start..], 0..) |message, i| {
            const index = ranges.tail_start + i;
            if (shouldIncludeInSessionContext(message, latest_reads)) try renderMessageSmart(allocator, &out, message, index, truncate_chars);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn appendSessionContext(self: Log, allocator: Allocator, out: *std.ArrayList(provider.Message), focused_context: []const u8, head_messages: usize, tail_messages: usize, truncate_chars: usize) !void {
        const context = try self.transcript(allocator, head_messages, tail_messages, truncate_chars);
        defer allocator.free(context);
        if (context.len != 0) {
            const rendered = try std.fmt.allocPrint(allocator, "Previous session context. These are inert Zinc session events, not live provider tool calls. Use session:current:messages:<index> or session:current:tools:<id> when exact details are needed.\n\n{s}", .{context});
            defer allocator.free(rendered);
            try provider.appendMessage(allocator, out, .{ .role = "user", .content = rendered });
        }
        if (std.mem.trim(u8, focused_context, " \t\r\n").len != 0) try provider.appendMessage(allocator, out, .{ .role = "user", .content = focused_context });
    }
};

pub fn open(allocator: Allocator, layout_ctx: layout.Context, resume_id: ?[]const u8, continue_last: bool) !Session {
    var store = try Store.open(allocator, layout_ctx, scopes.default());
    defer store.close();
    const id = if (continue_last) blk: {
        break :blk try store.lastSessionId(allocator) orelse return error.SessionNotFound;
    } else if (resume_id) |given| blk: {
        try validateId(given);
        if (!try store.sessionExists(given)) return error.SessionNotFound;
        break :blk try allocator.dupe(u8, given);
    } else try ids.new(allocator, "s");
    errdefer allocator.free(id);
    try store.ensureSession(id, ".");
    if (resume_id == null and !continue_last) {
        const event_id = try store.appendEvent(.{ .session_id = id, .type = "session.started", .summary = "session started" });
        allocator.free(event_id);
    }
    try store.setLastSessionId(id);
    return .{ .id = id };
}

pub fn rememberLast(allocator: Allocator, layout_ctx: layout.Context, session: Session) !void {
    var store = try Store.open(allocator, layout_ctx, scopes.default());
    defer store.close();
    try store.setLastSessionId(session.id);
}

pub fn read(allocator: Allocator, layout_ctx: layout.Context, session: Session) !Log {
    var store = try Store.open(allocator, layout_ctx, scopes.default());
    defer store.close();
    return readFromStore(allocator, store, session.id);
}

pub fn appendUserMessage(allocator: Allocator, layout_ctx: layout.Context, session: Session, content: []const u8) !void {
    var store = try Store.open(allocator, layout_ctx, scopes.default());
    defer store.close();
    try appendJsonPayloadEvent(allocator, store, session.id, "session.message.user", "user message", .{ .role = "user", .content = content });
}

pub fn appendAssistantText(allocator: Allocator, layout_ctx: layout.Context, session: Session, model_id: []const u8, content: []const u8, reasoning: ?[]const u8) !void {
    var store = try Store.open(allocator, layout_ctx, scopes.default());
    defer store.close();
    try appendJsonPayloadEvent(allocator, store, session.id, "session.message.assistant", "assistant message", .{ .role = "assistant", .content = content, .model = model_id, .reasoning = reasoning orelse "" });
}

pub fn appendAssistantToolCalls(allocator: Allocator, layout_ctx: layout.Context, session: Session, model_id: []const u8, content: []const u8, reasoning: ?[]const u8, calls: []const provider.ToolCall) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.appendSlice(allocator, "{\"role\":\"assistant\",\"content\":");
    try appendJsonString(allocator, &payload, content);
    try payload.appendSlice(allocator, ",\"model\":");
    try appendJsonString(allocator, &payload, model_id);
    try payload.appendSlice(allocator, ",\"reasoning\":");
    try appendJsonString(allocator, &payload, reasoning orelse "");
    try payload.appendSlice(allocator, ",\"tool_calls\":[");
    for (calls, 0..) |call, i| {
        if (i != 0) try payload.append(allocator, ',');
        try writeToolCall(allocator, &payload, call);
    }
    try payload.appendSlice(allocator, "]}");
    var store = try Store.open(allocator, layout_ctx, scopes.default());
    defer store.close();
    const id = try store.appendEvent(.{ .session_id = session.id, .type = "session.message.assistant", .summary = "assistant tool calls", .payload_json = payload.items });
    allocator.free(id);
}

pub fn appendToolResult(allocator: Allocator, layout_ctx: layout.Context, session: Session, call: provider.ToolCall, result: tools.ToolResult) !void {
    var store = try Store.open(allocator, layout_ctx, scopes.default());
    defer store.close();
    try appendJsonPayloadEvent(allocator, store, session.id, "tool.finished", call.name, .{ .role = "tool", .name = call.name, .tool_call_id = call.id, .ok = !result.is_error, .content = result.content });
}

pub fn appendProviderError(allocator: Allocator, layout_ctx: layout.Context, session: Session, message: []const u8) !void {
    var store = try Store.open(allocator, layout_ctx, scopes.default());
    defer store.close();
    const event_id = try store.appendEvent(.{ .session_id = session.id, .type = "provider.error", .summary = message, .payload_json = "{}" });
    defer allocator.free(event_id);
    try store.writeLog(.{ .session_id = session.id, .event_id = event_id, .level = "warn", .component = "provider", .message = message });
}

pub fn appendProviderUsage(allocator: Allocator, layout_ctx: layout.Context, session: Session, model_id: []const u8, prompt_tokens: usize) !void {
    var store = try Store.open(allocator, layout_ctx, scopes.default());
    defer store.close();
    try appendJsonPayloadEvent(allocator, store, session.id, "model.usage", "provider usage", .{ .model = model_id, .prompt_tokens = prompt_tokens });
}

pub fn appendCompaction(allocator: Allocator, layout_ctx: layout.Context, session: Session, message_count: usize, summary: []const u8) !void {
    var store = try Store.open(allocator, layout_ctx, scopes.default());
    defer store.close();
    try appendJsonPayloadEvent(allocator, store, session.id, "session.compacted", "session compacted", .{ .message_count = message_count, .summary = summary });
}

pub fn appendRecoveryStarted(allocator: Allocator, layout_ctx: layout.Context, session: Session, reach: []const u8, budget_chars: usize) !void {
    var store = try Store.open(allocator, layout_ctx, scopes.default());
    defer store.close();
    try appendJsonPayloadEvent(allocator, store, session.id, "context.recovery.started", "context recovery started", .{ .reach = reach, .budget_chars = budget_chars });
}

pub fn appendRecovery(allocator: Allocator, layout_ctx: layout.Context, session: Session, message_count: usize, compaction_message_count: usize, context: []const u8) !void {
    var store = try Store.open(allocator, layout_ctx, scopes.default());
    defer store.close();
    try appendJsonPayloadEvent(allocator, store, session.id, "context.recovery.finished", "context recovery finished", .{ .message_count = message_count, .compaction_message_count = compaction_message_count, .context = context });
}

pub fn appendRecoveryFailed(allocator: Allocator, layout_ctx: layout.Context, session: Session, message: []const u8) !void {
    var store = try Store.open(allocator, layout_ctx, scopes.default());
    defer store.close();
    try appendJsonPayloadEvent(allocator, store, session.id, "context.recovery.failed", "context recovery failed", .{ .message = message });
}

fn readFromStore(allocator: Allocator, store: Store, session_id: []const u8) !Log {
    const Row = struct { type: sqlite.Text, payload_json: sqlite.Text };
    const stmt = try store.db.prepare(struct { session_id: sqlite.Text }, Row, "select type, payload_json from events where session_id = :session_id order by time, rowid");
    defer stmt.finalize();
    try stmt.bind(.{ .session_id = sqlite.text(session_id) });
    defer stmt.reset();
    var messages: std.ArrayList(Message) = .empty;
    errdefer freeMessages(allocator, messages.items);
    var compaction: ?Compaction = null;
    errdefer if (compaction) |c| c.deinit(allocator);
    var recovery: ?Recovery = null;
    errdefer if (recovery) |r| r.deinit(allocator);
    var usage: ?ProviderUsage = null;
    errdefer if (usage) |u| u.deinit(allocator);
    while (try stmt.step()) |row| {
        if (std.mem.eql(u8, row.type.data, "session.message.user") or std.mem.eql(u8, row.type.data, "session.message.assistant")) {
            try messages.append(allocator, try readMessagePayload(allocator, row.payload_json.data));
        } else if (std.mem.eql(u8, row.type.data, "tool.finished")) {
            try messages.append(allocator, try readToolPayload(allocator, row.payload_json.data));
        } else if (std.mem.eql(u8, row.type.data, "session.compacted")) {
            if (compaction) |old| old.deinit(allocator);
            compaction = try readCompactionPayload(allocator, row.payload_json.data);
        } else if (std.mem.eql(u8, row.type.data, "context.recovery.finished")) {
            if (recovery) |old| old.deinit(allocator);
            recovery = try readRecoveryPayload(allocator, row.payload_json.data);
        } else if (std.mem.eql(u8, row.type.data, "model.usage")) {
            if (usage) |old| old.deinit(allocator);
            usage = try readUsagePayload(allocator, row.payload_json.data);
        }
    }
    return .{ .messages = try messages.toOwnedSlice(allocator), .compaction = compaction, .recovery = recovery, .provider_usage = usage };
}

fn appendJsonPayloadEvent(allocator: Allocator, store: Store, session_id: []const u8, typ: []const u8, summary: []const u8, payload: anytype) !void {
    const text = try jsonObject(allocator, payload);
    defer allocator.free(text);
    const event_id = try store.appendEvent(.{ .session_id = session_id, .type = typ, .summary = summary, .payload_json = text });
    allocator.free(event_id);
}

fn jsonObject(allocator: Allocator, payload: anytype) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &out);
    try std.json.Stringify.value(payload, .{}, &aw.writer);
    out = aw.toArrayList();
    return out.toOwnedSlice(allocator);
}

fn readMessagePayload(allocator: Allocator, text: []const u8) !Message {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadSessionEvent;
    const row = parsed.value.object;
    return .{ .role = try dupeField(allocator, row, "role"), .content = try allocator.dupe(u8, stringField(row, "content") orelse ""), .model = try optionalNonEmptyField(allocator, row, "model"), .reasoning = try optionalNonEmptyField(allocator, row, "reasoning"), .tool_calls = try readToolCalls(allocator, row) };
}

fn readToolPayload(allocator: Allocator, text: []const u8) !Message {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadSessionEvent;
    const row = parsed.value.object;
    return .{ .role = try allocator.dupe(u8, "tool"), .content = try allocator.dupe(u8, stringField(row, "content") orelse ""), .name = try optionalNonEmptyField(allocator, row, "name"), .tool_call_id = try optionalNonEmptyField(allocator, row, "tool_call_id") };
}

fn readCompactionPayload(allocator: Allocator, text: []const u8) !Compaction {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const row = parsed.value.object;
    const count = row.get("message_count") orelse return error.BadSessionEvent;
    if (count != .integer or count.integer < 0) return error.BadSessionEvent;
    return .{ .message_count = @intCast(count.integer), .summary = try allocator.dupe(u8, stringField(row, "summary") orelse "") };
}

fn readRecoveryPayload(allocator: Allocator, text: []const u8) !Recovery {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const row = parsed.value.object;
    const message_count = row.get("message_count") orelse return error.BadSessionEvent;
    const compaction_message_count = row.get("compaction_message_count") orelse return error.BadSessionEvent;
    if (message_count != .integer or message_count.integer < 0 or compaction_message_count != .integer or compaction_message_count.integer < 0) return error.BadSessionEvent;
    return .{ .message_count = @intCast(message_count.integer), .compaction_message_count = @intCast(compaction_message_count.integer), .context = try allocator.dupe(u8, stringField(row, "context") orelse "") };
}

fn readUsagePayload(allocator: Allocator, text: []const u8) !ProviderUsage {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const row = parsed.value.object;
    const prompt_tokens = row.get("prompt_tokens") orelse return error.BadSessionEvent;
    if (prompt_tokens != .integer or prompt_tokens.integer < 0) return error.BadSessionEvent;
    return .{ .model = try allocator.dupe(u8, stringField(row, "model") orelse ""), .prompt_tokens = @intCast(prompt_tokens.integer) };
}

fn writeToolCall(allocator: Allocator, out: *std.ArrayList(u8), call: provider.ToolCall) !void {
    try out.appendSlice(allocator, "{\"id\":");
    try appendJsonString(allocator, out, call.id);
    try out.appendSlice(allocator, ",\"name\":");
    try appendJsonString(allocator, out, call.name);
    try out.appendSlice(allocator, ",\"arguments\":");
    try appendJsonString(allocator, out, call.arguments);
    try out.append(allocator, '}');
}

fn appendJsonString(allocator: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    try std.json.Stringify.value(value, .{}, &aw.writer);
    out.* = aw.toArrayList();
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
        if (item != .object) return error.BadSessionEvent;
        out[i] = .{ .id = try dupeField(allocator, item.object, "id"), .name = try dupeField(allocator, item.object, "name"), .arguments = try dupeField(allocator, item.object, "arguments") };
        n += 1;
    }
    return out;
}

const LatestRead = struct {
    path: []u8,
    tool_call_id: []u8,
    fn deinit(self: LatestRead, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.tool_call_id);
    }
};

fn latestReadCalls(allocator: Allocator, messages: []const Message) !std.ArrayList(LatestRead) {
    var reads: std.ArrayList(LatestRead) = .empty;
    errdefer freeLatestReads(allocator, &reads);
    for (messages) |message| {
        if (!std.mem.eql(u8, message.role, "assistant")) continue;
        for (message.tool_calls) |call| {
            if (!std.mem.eql(u8, call.name, "read")) continue;
            const path = try readToolPath(allocator, call.arguments) orelse continue;
            defer allocator.free(path);
            try rememberLatestRead(allocator, &reads, path, call.id);
        }
    }
    return reads;
}

fn freeLatestReads(allocator: Allocator, reads: *std.ArrayList(LatestRead)) void {
    for (reads.items) |item| item.deinit(allocator);
    reads.deinit(allocator);
}

fn rememberLatestRead(allocator: Allocator, reads: *std.ArrayList(LatestRead), path: []const u8, tool_call_id: []const u8) !void {
    for (reads.items) |*item| if (std.mem.eql(u8, item.path, path)) {
        allocator.free(item.tool_call_id);
        item.tool_call_id = try allocator.dupe(u8, tool_call_id);
        return;
    };
    try reads.append(allocator, .{ .path = try allocator.dupe(u8, path), .tool_call_id = try allocator.dupe(u8, tool_call_id) });
}

fn readToolPath(allocator: Allocator, arguments: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const path = parsed.value.object.get("path") orelse return null;
    if (path != .string) return null;
    return try allocator.dupe(u8, path.string);
}

fn shouldIncludeInSessionContext(message: Message, latest_reads: std.ArrayList(LatestRead)) bool {
    if (std.mem.eql(u8, message.role, "assistant") and message.tool_calls.len != 0) {
        var has_read = false;
        for (message.tool_calls) |call| {
            if (!std.mem.eql(u8, call.name, "read")) return true;
            has_read = true;
            if (isLatestReadCall(call.id, latest_reads)) return true;
        }
        return !has_read;
    }
    if (!std.mem.eql(u8, message.role, "tool")) return true;
    if (message.name == null or !std.mem.eql(u8, message.name.?, "read")) return true;
    const call_id = message.tool_call_id orelse return true;
    return isLatestReadCall(call_id, latest_reads);
}

fn isLatestReadCall(call_id: []const u8, latest_reads: std.ArrayList(LatestRead)) bool {
    for (latest_reads.items) |item| if (std.mem.eql(u8, item.tool_call_id, call_id)) return true;
    return false;
}

const SessionContextRanges = struct { head_end: usize, tail_start: usize };

fn sessionContextRanges(log: Log, head_messages: usize, tail_messages: usize) SessionContextRanges {
    const head_end = @min(head_messages, log.messages.len);
    if (log.compaction) |c| {
        const compacted = @as(usize, @min(c.message_count, log.messages.len));
        return .{ .head_end = head_end, .tail_start = @max(head_end, compacted) };
    }
    const tail_start = if (log.messages.len > tail_messages) log.messages.len - tail_messages else head_end;
    return .{ .head_end = head_end, .tail_start = @max(head_end, tail_start) };
}

fn renderMessageSmart(allocator: Allocator, out: *std.ArrayList(u8), message: Message, index: usize, truncate_chars: usize) !void {
    if (std.mem.eql(u8, message.role, "assistant") and message.tool_calls.len != 0) {
        for (message.tool_calls) |call| try out.print(allocator, "assistant tool call {s} {s}\n", .{ call.name, call.arguments });
        return;
    }
    if (std.mem.eql(u8, message.role, "tool")) {
        const content = try truncateMessageContent(allocator, message, index, truncate_chars);
        defer allocator.free(content);
        try out.print(allocator, "tool {s} call_id={s}: {s}\n", .{ message.name orelse "", message.tool_call_id orelse "", content });
        return;
    }
    const content = try truncateMessageContent(allocator, message, index, truncate_chars);
    defer allocator.free(content);
    if (message.reasoning) |reasoning| if (reasoning.len != 0) try out.print(allocator, "{s} reasoning: {s}\n", .{ message.role, reasoning });
    try out.print(allocator, "{s}: {s}\n", .{ message.role, content });
}

fn truncateMessageContent(allocator: Allocator, message: Message, index: usize, truncate_chars: usize) ![]u8 {
    const content = message.content;
    if (truncate_chars == 0 or content.len <= truncate_chars) return allocator.dupe(u8, content);
    const preview = content[0..truncate_chars];
    if (std.mem.eql(u8, message.role, "tool")) return std.fmt.allocPrint(allocator, "{s}... [truncated, {d} chars - use session:current:tools:{s} for full]", .{ preview, content.len, message.tool_call_id orelse "" });
    return std.fmt.allocPrint(allocator, "{s}... [truncated, {d} chars - use session:current:messages:{d} for full]", .{ preview, content.len, index });
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
    return allocator.dupe(u8, stringField(row, name) orelse return error.BadSessionEvent);
}

fn optionalNonEmptyField(allocator: Allocator, row: std.json.ObjectMap, name: []const u8) !?[]u8 {
    const value = stringField(row, name) orelse return null;
    if (value.len == 0) return null;
    return try allocator.dupe(u8, value);
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

test "session context renders historical tool events as inert provider text" {
    const allocator = std.testing.allocator;
    var messages = [_]Message{
        .{ .role = try allocator.dupe(u8, "user"), .content = try allocator.dupe(u8, "control my browser") },
        .{ .role = try allocator.dupe(u8, "assistant"), .content = try allocator.dupe(u8, ""), .tool_calls = try allocator.dupe(provider.ToolCall, &.{.{ .id = try allocator.dupe(u8, "bad1"), .name = try allocator.dupe(u8, "browser_observe"), .arguments = try allocator.dupe(u8, "{\"code\":\"") }}) },
        .{ .role = try allocator.dupe(u8, "tool"), .content = try allocator.dupe(u8, "abcdefghijklmnopqrstuvwxyz"), .name = try allocator.dupe(u8, "browser_observe"), .tool_call_id = try allocator.dupe(u8, "bad1") },
    };
    const owned = try allocator.dupe(Message, &messages);
    var log = Log{ .messages = owned, .compaction = null, .recovery = null, .provider_usage = null };
    defer log.deinit(allocator);
    var out: std.ArrayList(provider.Message) = .empty;
    defer out.deinit(allocator);
    defer provider.freeMessages(allocator, out.items);
    try log.appendSessionContext(allocator, &out, "", 6, 12, 8);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("user", out.items[0].role);
    try std.testing.expectEqual(@as(usize, 0), out.items[0].tool_calls.len);
    try std.testing.expect(std.mem.indexOf(u8, out.items[0].content, "assistant tool call browser_observe {\"code\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items[0].content, "tool browser_observe call_id=bad1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items[0].content, "session:current:tools:bad1") != null);
}
