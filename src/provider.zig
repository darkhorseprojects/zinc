const std = @import("std");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;
const chat_max_tokens = 256;

pub const Config = struct {
    base_url: []const u8 = "http://127.0.0.1:30000/v1",
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

pub fn call(allocator: Allocator, io: std.Io, cfg: Config, model: []const u8, tools_json: []const u8, messages: []const Message, require_tool: bool) !AssistantTurn {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try writeChatRequest(allocator, &body, model, tools_json, messages, require_tool);

    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{cfg.base_url});
    defer allocator.free(url);

    var response = std.Io.Writer.Allocating.init(allocator);
    defer response.deinit();
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "authorization", .value = "Bearer zinc" },
    };
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body.items,
        .extra_headers = &headers,
        .response_writer = &response.writer,
    });
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) return error.ProviderRequestFailed;
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
    errdefer allocator.free(out);
    for (calls, 0..) |tool_call, i| {
        out[i] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try allocator.dupe(u8, tool_call.arguments),
        };
    }
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

fn writeChatRequest(allocator: Allocator, out: *std.ArrayList(u8), model: []const u8, tools_json: []const u8, messages: []const Message, require_tool: bool) !void {
    try out.appendSlice(allocator, "{\"model\":");
    try files.appendJsonString(allocator, out, model);
    try out.print(allocator, ",\"stream\":false,\"max_tokens\":{d},\"messages\":[", .{chat_max_tokens});
    for (messages, 0..) |msg, i| {
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
    try out.appendSlice(allocator, tools_json);
    if (require_tool) try out.appendSlice(allocator, ",\"tool_choice\":\"required\"");
    try out.append(allocator, '}');
}

fn parseAssistantTurn(allocator: Allocator, text: []const u8) !AssistantTurn {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const choices = root.object.get("choices") orelse return error.BadProviderResponse;
    const first = choices.array.items[0];
    const message = first.object.get("message") orelse return error.BadProviderResponse;
    const content_value = message.object.get("content");
    const content = if (content_value) |v| if (v == .null) "" else v.string else "";

    var calls: std.ArrayList(ToolCall) = .empty;
    errdefer {
        for (calls.items) |c| freeCall(allocator, c);
        calls.deinit(allocator);
    }

    if (message.object.get("tool_calls")) |tool_calls| {
        if (tool_calls != .null) {
            for (tool_calls.array.items) |tc| {
                const id = tc.object.get("id").?.string;
                const fun = tc.object.get("function").?;
                const name = fun.object.get("name").?.string;
                const args = fun.object.get("arguments").?.string;
                try calls.append(allocator, .{
                    .id = try allocator.dupe(u8, id),
                    .name = try allocator.dupe(u8, name),
                    .arguments = try allocator.dupe(u8, args),
                });
            }
        }
    }

    return .{
        .text = try cleanText(allocator, content),
        .tool_calls = try calls.toOwnedSlice(allocator),
    };
}
