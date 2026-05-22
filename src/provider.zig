const std = @import("std");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;

pub const Request = struct {
    base_url: []const u8,
    authorization: []const u8,
    model: []const u8,
    temperature: f64,
    tools_json: []const u8,
    messages: []const Message,
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    name: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls: []ToolCall = &.{},
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

    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{request.base_url});
    defer allocator.free(url);

    var response = std.Io.Writer.Allocating.init(allocator);
    defer response.deinit();
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "authorization", .value = request.authorization },
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
    return parseAssistantTurn(allocator, response.written());
}

pub fn appendMessage(allocator: Allocator, messages: *std.ArrayList(Message), message: Message) !void {
    const owned = Message{
        .role = message.role,
        .content = try allocator.dupe(u8, message.content),
        .name = if (message.name) |v| try allocator.dupe(u8, v) else null,
        .tool_call_id = if (message.tool_call_id) |v| try allocator.dupe(u8, v) else null,
        .tool_calls = try cloneToolCalls(allocator, message.tool_calls),
    };
    errdefer freeMessage(allocator, owned);
    try messages.append(allocator, owned);
}

pub fn freeMessages(allocator: Allocator, messages: []Message) void {
    for (messages) |message| freeMessage(allocator, message);
}

pub fn freeTurn(allocator: Allocator, turn: AssistantTurn) void {
    allocator.free(turn.text);
    for (turn.tool_calls) |tool_call| freeCall(allocator, tool_call);
    allocator.free(turn.tool_calls);
}

pub fn cleanText(allocator: Allocator, raw: []const u8) ![]u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    const thought_prefix = "<|channel>thought\n<channel|>";
    if (std.mem.startsWith(u8, text, thought_prefix)) text = std.mem.trim(u8, text[thought_prefix.len..], " \t\r\n");
    while (std.mem.endsWith(u8, text, "</thought>")) text = std.mem.trim(u8, text[0 .. text.len - "</thought>".len], " \t\r\n");
    return allocator.dupe(u8, text);
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
    var out = ToolCall{
        .id = try allocator.dupe(u8, tool_call.id),
        .name = undefined,
        .arguments = undefined,
    };
    errdefer allocator.free(out.id);
    out.name = try allocator.dupe(u8, tool_call.name);
    errdefer allocator.free(out.name);
    out.arguments = try allocator.dupe(u8, tool_call.arguments);
    return out;
}

fn freeMessage(allocator: Allocator, message: Message) void {
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

fn writeChatRequest(allocator: Allocator, out: *std.ArrayList(u8), request: Request) !void {
    try out.appendSlice(allocator, "{\"model\":");
    try files.appendJsonString(allocator, out, request.model);
    try out.print(allocator, ",\"temperature\":{d},\"stream\":false,\"messages\":[", .{request.temperature});
    for (request.messages, 0..) |msg, i| {
        if (i != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"role\":");
        try files.appendJsonString(allocator, out, msg.role);
        try out.appendSlice(allocator, ",\"content\":");
        try files.appendJsonString(allocator, out, msg.content);
        if (msg.tool_call_id) |id| {
            try out.appendSlice(allocator, ",\"tool_call_id\":");
            try files.appendJsonString(allocator, out, id);
        }
        if (msg.name) |name| {
            try out.appendSlice(allocator, ",\"name\":");
            try files.appendJsonString(allocator, out, name);
        }
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
    try out.append(allocator, '}');
}

fn parseAssistantTurn(allocator: Allocator, text: []const u8) !AssistantTurn {
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
        .text = try cleanText(allocator, content),
        .tool_calls = try calls.toOwnedSlice(allocator),
    };
}

fn readMessageContent(message: std.json.Value) ![]const u8 {
    const content = message.object.get("content") orelse return "";
    return switch (content) {
        .null => "",
        .string => content.string,
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
    var out = ToolCall{
        .id = try allocator.dupe(u8, id),
        .name = undefined,
        .arguments = undefined,
    };
    errdefer allocator.free(out.id);
    out.name = try allocator.dupe(u8, name);
    errdefer allocator.free(out.name);
    out.arguments = try allocator.dupe(u8, arguments);
    return out;
}

fn readStringField(object: std.json.Value, field: []const u8) ![]const u8 {
    const value = object.object.get(field) orelse return error.BadProviderResponse;
    if (value != .string) return error.BadProviderResponse;
    return value.string;
}
