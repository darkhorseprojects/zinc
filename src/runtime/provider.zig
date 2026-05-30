const std = @import("std");
const config = @import("config.zig");
const files = @import("../sys/fs.zig");

const Allocator = std.mem.Allocator;

pub const Request = struct {
    profile: *const config.RuntimeProfile,
    max_tokens: ?usize,
    reasoning_budget_tokens: ?usize,
    json_response: bool = false,
    tools_json: []const u8,
    messages: []const Message,
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    name: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const AssistantTurn = struct {
    text: []const u8,
    tool_calls: []ToolCall,
};

pub fn call(allocator: Allocator, io: std.Io, request: Request) !AssistantTurn {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try writeChatRequest(allocator, &body, request);

    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{request.profile.provider.base_url});
    defer allocator.free(url);

    var response = std.Io.Writer.Allocating.init(allocator);
    defer response.deinit();
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "authorization", .value = request.profile.provider.authorization },
    };
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body.items,
        .extra_headers = &headers,
        .response_writer = &response.writer,
    });
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        const response_body = response.written();
        if (result.status == .service_unavailable and std.mem.indexOf(u8, response_body, "Loading model") != null) return error.ProviderLoadingModel;
        const preview = response_body[0..@min(response_body.len, 1200)];
        std.debug.print("provider request failed: status={d}\n{s}\n", .{ @intFromEnum(result.status), preview });
        return error.ProviderRequestFailed;
    }
    return parseAssistantTurn(allocator, response.written(), request.profile);
}

pub fn appendMessage(allocator: Allocator, messages: *std.ArrayList(Message), message: Message) !void {
    const role = try allocator.dupe(u8, message.role);
    errdefer allocator.free(role);
    const content = try allocator.dupe(u8, message.content);
    errdefer allocator.free(content);
    const name = if (message.name) |v| try allocator.dupe(u8, v) else null;
    errdefer if (name) |v| allocator.free(v);
    const tool_call_id = if (message.tool_call_id) |v| try allocator.dupe(u8, v) else null;
    errdefer if (tool_call_id) |v| allocator.free(v);
    const tool_calls = try cloneToolCalls(allocator, message.tool_calls);
    errdefer {
        for (tool_calls) |tool_call| freeCall(allocator, tool_call);
        if (tool_calls.len != 0) allocator.free(tool_calls);
    }
    try messages.append(allocator, .{ .role = role, .content = content, .name = name, .tool_call_id = tool_call_id, .tool_calls = tool_calls });
}

pub fn freeMessages(allocator: Allocator, messages: []Message) void {
    for (messages) |message| freeMessage(allocator, message);
}

pub fn freeTurn(allocator: Allocator, turn: AssistantTurn) void {
    allocator.free(turn.text);
    for (turn.tool_calls) |tool_call| freeCall(allocator, tool_call);
    allocator.free(turn.tool_calls);
}

pub fn cleanText(allocator: Allocator, raw: []const u8, profile: *const config.RuntimeProfile) ![]u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (profile.model.reasoning_markers) |markers| {
        if (std.mem.lastIndexOf(u8, text, markers.end)) |last_marker| {
            text = std.mem.trim(u8, text[last_marker + markers.end.len ..], " \t\r\n");
        } else if (startsConfiguredReasoning(text, markers.starts)) {
            text = "";
        }
    }
    if (std.mem.startsWith(u8, text, "```")) {
        const after_open = std.mem.indexOfScalar(u8, text, '\n') orelse return allocator.dupe(u8, text);
        text = std.mem.trim(u8, text[after_open + 1 ..], " \t\r\n");
        if (std.mem.endsWith(u8, text, "```")) text = std.mem.trim(u8, text[0 .. text.len - 3], " \t\r\n");
    }
    return allocator.dupe(u8, text);
}

fn writeChatRequest(allocator: Allocator, out: *std.ArrayList(u8), request: Request) !void {
    const profile = request.profile;
    try out.appendSlice(allocator, "{\"model\":");
    try files.appendJsonString(allocator, out, profile.model.model);
    try out.print(allocator, ",\"temperature\":{d},\"stream\":false", .{profile.model.generation.temperature});
    if (request.max_tokens) |max_tokens| {
        try out.print(allocator, ",\"max_tokens\":{d}", .{max_tokens});
    }
    if (request.reasoning_budget_tokens) |budget| try out.print(allocator, ",\"thinking_budget_tokens\":{d}", .{budget});
    try writeConfiguredReasoningRequest(allocator, out, profile, request.reasoning_budget_tokens != null);
    if (request.json_response) try out.appendSlice(allocator, ",\"response_format\":{\"type\":\"json_object\"}");
    try out.appendSlice(allocator, ",\"messages\":[");
    for (request.messages, 0..) |msg, i| {
        if (i != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"role\":");
        try files.appendJsonString(allocator, out, msg.role);
        try out.appendSlice(allocator, ",\"content\":");
        if (msg.tool_calls.len != 0) try files.appendJsonString(allocator, out, "") else try writeMessageContent(allocator, out, msg);
        if (msg.tool_call_id) |id| {
            try out.appendSlice(allocator, ",\"tool_call_id\":");
            try files.appendJsonString(allocator, out, id);
        }
        if (msg.name) |name| if (!std.mem.eql(u8, msg.role, "tool")) {
            try out.appendSlice(allocator, ",\"name\":");
            try files.appendJsonString(allocator, out, name);
        };
        if (msg.tool_calls.len != 0) {
            try out.appendSlice(allocator, ",\"tool_calls\":[");
            for (msg.tool_calls, 0..) |tool_call, j| {
                if (j != 0) try out.append(allocator, ',');
                try out.appendSlice(allocator, "{\"id\":");
                try files.appendJsonString(allocator, out, tool_call.id);
                try out.appendSlice(allocator, ",\"type\":\"function\",\"function\":{\"name\":");
                try files.appendJsonString(allocator, out, tool_call.name);
                try out.appendSlice(allocator, ",\"arguments\":");
                try files.appendJsonString(allocator, out, tool_call.arguments);
                try out.appendSlice(allocator, "}}");
            }
            try out.append(allocator, ']');
        }
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "],\"tools\":");
    try out.appendSlice(allocator, request.tools_json);
    if (!std.mem.eql(u8, request.tools_json, "[]")) try out.appendSlice(allocator, ",\"tool_choice\":\"auto\"");
    try out.append(allocator, '}');
}

fn writeConfiguredReasoningRequest(allocator: Allocator, out: *std.ArrayList(u8), profile: *const config.RuntimeProfile, enabled: bool) !void {
    const req = profile.model.reasoning_request orelse return;
    if (std.mem.eql(u8, req.kind, "chat_template_kwargs_bool")) {
        try out.appendSlice(allocator, ",\"chat_template_kwargs\":{");
        try files.appendJsonString(allocator, out, req.path);
        try out.appendSlice(allocator, if (enabled) ":true}" else ":false}");
        return;
    }
    if (std.mem.eql(u8, req.kind, "top_level_bool")) {
        try out.append(allocator, ',');
        try files.appendJsonString(allocator, out, req.path);
        try out.appendSlice(allocator, if (enabled) ":true" else ":false");
        return;
    }
}

fn parseAssistantTurn(allocator: Allocator, text: []const u8, profile: *const config.RuntimeProfile) !AssistantTurn {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.BadProviderResponse;
    const choices = parsed.value.object.get("choices") orelse return error.BadProviderResponse;
    if (choices != .array or choices.array.items.len == 0) return error.BadProviderResponse;
    const first = choices.array.items[0];
    if (first != .object) return error.BadProviderResponse;
    const message = first.object.get("message") orelse return error.BadProviderResponse;
    if (message != .object) return error.BadProviderResponse;

    const content = try readMessageContent(message);
    var calls = try readToolCalls(allocator, message);
    errdefer {
        for (calls.items) |c| freeCall(allocator, c);
        calls.deinit(allocator);
    }
    return .{
        .text = if (calls.items.len == 0) try cleanText(allocator, content, profile) else try allocator.dupe(u8, ""),
        .tool_calls = try calls.toOwnedSlice(allocator),
    };
}

fn readMessageContent(message: std.json.Value) ![]const u8 {
    return readOptionalStringField(message, "content");
}

fn startsConfiguredReasoning(text: []const u8, starts: []const []const u8) bool {
    return configuredReasoningPrefix(text, starts) != null;
}

fn configuredReasoningPrefix(text: []const u8, starts: []const []const u8) ?[]const u8 {
    for (starts) |prefix| if (std.mem.startsWith(u8, text, prefix)) return prefix;
    return null;
}

fn readOptionalStringField(object: std.json.Value, field: []const u8) ![]const u8 {
    const value = object.object.get(field) orelse return "";
    return switch (value) {
        .null => "",
        .string => value.string,
        else => error.BadProviderResponse,
    };
}

fn readToolCalls(allocator: Allocator, message: std.json.Value) !std.ArrayList(ToolCall) {
    var calls: std.ArrayList(ToolCall) = .empty;
    errdefer {
        for (calls.items) |c| freeCall(allocator, c);
        calls.deinit(allocator);
    }
    const value = message.object.get("tool_calls") orelse return calls;
    if (value == .null) return calls;
    if (value != .array) return error.BadProviderResponse;
    for (value.array.items) |tool_call| try calls.append(allocator, try readToolCall(allocator, tool_call));
    return calls;
}

fn readToolCall(allocator: Allocator, value: std.json.Value) !ToolCall {
    if (value != .object) return error.BadProviderResponse;
    const id = readStringField(value, "id") catch return error.BadProviderResponse;
    const function = value.object.get("function") orelse return error.BadProviderResponse;
    if (function != .object) return error.BadProviderResponse;
    const name = readStringField(function, "name") catch return error.BadProviderResponse;
    const arguments = readStringField(function, "arguments") catch return error.BadProviderResponse;
    return .{ .id = try allocator.dupe(u8, id), .name = try allocator.dupe(u8, name), .arguments = try allocator.dupe(u8, arguments) };
}

fn readStringField(object: std.json.Value, field: []const u8) ![]const u8 {
    const value = object.object.get(field) orelse return error.BadProviderResponse;
    if (value != .string) return error.BadProviderResponse;
    return value.string;
}

fn writeMessageContent(allocator: Allocator, out: *std.ArrayList(u8), msg: Message) !void {
    return files.appendJsonString(allocator, out, msg.content);
}

fn cloneToolCalls(allocator: Allocator, calls: []const ToolCall) ![]ToolCall {
    if (calls.len == 0) return &.{};
    const out = try allocator.alloc(ToolCall, calls.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |tool_call| freeCall(allocator, tool_call);
        allocator.free(out);
    }
    for (calls, 0..) |tool_call, i| {
        out[i] = try cloneToolCall(allocator, tool_call);
        initialized += 1;
    }
    return out;
}

fn cloneToolCall(allocator: Allocator, tool_call: ToolCall) !ToolCall {
    return .{ .id = try allocator.dupe(u8, tool_call.id), .name = try allocator.dupe(u8, tool_call.name), .arguments = try allocator.dupe(u8, tool_call.arguments) };
}

fn freeMessage(allocator: Allocator, message: Message) void {
    allocator.free(message.role);
    allocator.free(message.content);
    if (message.name) |v| allocator.free(v);
    if (message.tool_call_id) |v| allocator.free(v);
    for (message.tool_calls) |tool_call| freeCall(allocator, tool_call);
    if (message.tool_calls.len != 0) allocator.free(message.tool_calls);
}

fn freeCall(allocator: Allocator, tool_call: ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    allocator.free(tool_call.arguments);
}
