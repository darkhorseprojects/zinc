const std = @import("std");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;

pub const Request = struct {
    base_url: []const u8,
    authorization: []const u8,
    model: []const u8,
    temperature: f64,
    max_tokens: usize,
    thinking_enabled: ?bool = null,
    json_response: bool = false,
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
    if (std.mem.startsWith(u8, text, "```")) {
        const after_open = std.mem.indexOfScalar(u8, text, '\n') orelse return allocator.dupe(u8, text);
        text = std.mem.trim(u8, text[after_open + 1 ..], " \t\r\n");
        if (std.mem.endsWith(u8, text, "```")) text = std.mem.trim(u8, text[0 .. text.len - 3], " \t\r\n");
    }
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
    try out.print(allocator, ",\"temperature\":{d},\"max_tokens\":{d},\"stream\":false", .{ request.temperature, request.max_tokens });
    if (request.thinking_enabled) |enabled| {
        try out.print(allocator, ",\"chat_template_kwargs\":{{\"enable_thinking\":{}}}", .{enabled});
    }
    if (request.json_response) try out.appendSlice(allocator, ",\"response_format\":{\"type\":\"json_object\"}");
    try out.appendSlice(allocator, ",\"messages\":[");
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
    if (!std.mem.eql(u8, request.tools_json, "[]")) try out.appendSlice(allocator, ",\"tool_choice\":\"auto\"");
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
    if (calls.items.len == 0) try readNativeToolCalls(allocator, content, &calls);

    return .{
        .text = if (calls.items.len == 0) try cleanText(allocator, content) else try allocator.dupe(u8, ""),
        .tool_calls = try calls.toOwnedSlice(allocator),
    };
}

fn readMessageContent(message: std.json.Value) ![]const u8 {
    return readOptionalStringField(message, "content");
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

fn readNativeToolCalls(allocator: Allocator, content: []const u8, calls: *std.ArrayList(ToolCall)) !void {
    var rest = content;
    var index: usize = 0;
    while (std.mem.indexOf(u8, rest, "<|tool_call>call:")) |start| {
        rest = rest[start + "<|tool_call>call:".len ..];
        const name_end = std.mem.indexOfScalar(u8, rest, '{') orelse return error.BadProviderResponse;
        const args_end = std.mem.indexOf(u8, rest[name_end + 1 ..], "}<tool_call|>") orelse return error.BadProviderResponse;
        const name = rest[0..name_end];
        const args = rest[name_end + 1 .. name_end + 1 + args_end];
        var tool_call = ToolCall{
            .id = try std.fmt.allocPrint(allocator, "native-{d}", .{index}),
            .name = undefined,
            .arguments = undefined,
        };
        errdefer allocator.free(tool_call.id);
        tool_call.name = try allocator.dupe(u8, name);
        errdefer allocator.free(tool_call.name);
        tool_call.arguments = try nativeArgsToJson(allocator, args);
        errdefer allocator.free(tool_call.arguments);
        try calls.append(allocator, tool_call);
        rest = rest[name_end + 1 + args_end + "}<tool_call|>".len ..];
        index += 1;
    }
}

fn nativeArgsToJson(allocator: Allocator, args: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    var cursor: usize = 0;
    var first = true;
    while (cursor < args.len) {
        while (cursor < args.len and (args[cursor] == ' ' or args[cursor] == '\t' or args[cursor] == '\r' or args[cursor] == '\n' or args[cursor] == ',')) cursor += 1;
        if (cursor >= args.len) break;
        const key_start = cursor;
        while (cursor < args.len and args[cursor] != ':') cursor += 1;
        if (cursor >= args.len) return error.BadProviderResponse;
        const key = std.mem.trim(u8, args[key_start..cursor], " \t\r\n");
        cursor += 1;
        const value_start = cursor;
        if (std.mem.startsWith(u8, args[cursor..], "<|\"|>")) {
            cursor += 5;
            const value_end = std.mem.indexOf(u8, args[cursor..], "<|\"|>") orelse return error.BadProviderResponse;
            cursor += value_end + 5;
        } else {
            while (cursor < args.len and args[cursor] != ',') cursor += 1;
        }
        const value = std.mem.trim(u8, args[value_start..cursor], " \t\r\n");
        if (!first) try out.append(allocator, ',');
        first = false;
        try files.appendJsonString(allocator, &out, key);
        try out.append(allocator, ':');
        try appendNativeArgValue(allocator, &out, value);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendNativeArgValue(allocator: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    if (std.mem.startsWith(u8, value, "<|\"|>") and std.mem.endsWith(u8, value, "<|\"|>")) {
        return files.appendJsonString(allocator, out, value[5 .. value.len - 5]);
    }
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "null")) {
        return out.appendSlice(allocator, value);
    }
    _ = std.fmt.parseFloat(f64, value) catch return files.appendJsonString(allocator, out, value);
    return out.appendSlice(allocator, value);
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
