const std = @import("std");
const config = @import("../config/mod.zig");
const files = @import("../io/fs.zig");
const resource = @import("../graph/resource.zig");
const provider = @import("mod.zig");

const Allocator = std.mem.Allocator;
const Request = provider.Request;
const Message = provider.Message;
const ToolCall = provider.ToolCall;
const AssistantTurn = provider.AssistantTurn;

const error_preview_chars: usize = 1200;

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

    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });
    if (request.profile.provider.authorization) |authorization| try headers.append(allocator, .{ .name = "authorization", .value = authorization });
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body.items,
        .extra_headers = headers.items,
        .response_writer = &response.writer,
    }) catch |err| switch (err) {
        error.ConnectionRefused => {
            std.debug.print("error: model endpoint refused connection: {s}\n", .{request.profile.provider.base_url});
            std.debug.print("start an OpenAI-compatible endpoint, or set the selected model endpoint in your Zinc config.\n", .{});
            return error.UserError;
        },
        else => return err,
    };
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        const response_body = response.written();
        if (result.status == .service_unavailable and std.mem.indexOf(u8, response_body, "Loading model") != null) return error.ProviderLoadingModel;
        const preview = response_body[0..@min(response_body.len, error_preview_chars)];
        std.debug.print("OpenAI-compatible model endpoint {s} request failed.\n\nBase URL:\n  {s}\n\nEndpoint:\n  /chat/completions\n\nStatus:\n  {d}\n\nHint:\n  check that the server exposes an OpenAI-compatible /v1/chat/completions endpoint.\n\n{s}\n", .{ request.profile.provider.id, request.profile.provider.base_url, @intFromEnum(result.status), preview });
        if (@intFromEnum(result.status) >= 400 and @intFromEnum(result.status) < 500 and result.status != .too_many_requests) return error.ProviderInvalidRequest;
        return error.ProviderRequestFailed;
    }
    return parseAssistantTurn(allocator, response.written(), request.profile);
}

fn writeChatRequest(allocator: Allocator, out: *std.ArrayList(u8), request: Request) !void {
    const profile = request.profile;
    try out.appendSlice(allocator, "{\"model\":");
    try files.appendJsonString(allocator, out, profile.model.model);
    try out.print(allocator, ",\"temperature\":{d},\"stream\":false", .{profile.model.temperature});
    try writeReasoningRequest(allocator, out, request.reasoning_effort);
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

fn writeReasoningRequest(allocator: Allocator, out: *std.ArrayList(u8), reasoning_effort: ?[]const u8) !void {
    const effort = reasoning_effort orelse return;
    try out.appendSlice(allocator, ",\"reasoning_effort\":");
    try files.appendJsonString(allocator, out, effort);
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
    const reasoning = try readReasoningContent(message);
    const prompt_tokens = readPromptTokens(parsed.value);
    var calls = try readToolCalls(allocator, message);
    errdefer {
        for (calls.items) |c| freeCall(allocator, c);
        calls.deinit(allocator);
    }
    return .{
        .text = if (calls.items.len == 0) try provider.cleanText(allocator, content, profile) else try allocator.dupe(u8, ""),
        .reasoning = if (reasoning.len == 0) null else try allocator.dupe(u8, reasoning),
        .prompt_tokens = prompt_tokens,
        .tool_calls = try calls.toOwnedSlice(allocator),
    };
}

fn readMessageContent(message: std.json.Value) ![]const u8 {
    return readOptionalStringField(message, "content");
}

fn readPromptTokens(root: std.json.Value) ?usize {
    const usage = objectField(root, "usage") orelse return null;
    return integerField(usage, "prompt_tokens") orelse integerField(usage, "input_tokens");
}

fn objectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(field);
}

fn integerField(value: std.json.Value, field: []const u8) ?usize {
    const field_value = objectField(value, field) orelse return null;
    return switch (field_value) {
        .integer => |v| if (v >= 0) @intCast(v) else null,
        .float => |v| if (v >= 0) @intFromFloat(v) else null,
        .string => |v| std.fmt.parseInt(usize, v, 10) catch null,
        else => null,
    };
}

fn readReasoningContent(message: std.json.Value) ![]const u8 {
    const content = try readOptionalStringField(message, "reasoning_content");
    if (content.len != 0) return content;
    return readOptionalStringField(message, "reasoning");
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
    if (msg.parts.len == 0) return files.appendJsonString(allocator, out, msg.content);
    try out.appendSlice(allocator, "[");
    var wrote_any = false;
    if (msg.content.len != 0) {
        try out.appendSlice(allocator, "{\"type\":\"text\",\"text\":");
        try files.appendJsonString(allocator, out, msg.content);
        try out.append(allocator, '}');
        wrote_any = true;
    }
    for (msg.parts) |part| {
        if (wrote_any) try out.append(allocator, ',');
        switch (part) {
            .text => |text| {
                try out.appendSlice(allocator, "{\"type\":\"text\",\"text\":");
                try files.appendJsonString(allocator, out, text);
                try out.append(allocator, '}');
            },
            .image_url => |url| {
                try out.appendSlice(allocator, "{\"type\":\"image_url\",\"image_url\":{\"url\":");
                try files.appendJsonString(allocator, out, url);
                try out.appendSlice(allocator, "}}");
            },
        }
        wrote_any = true;
    }
    try out.append(allocator, ']');
}

fn freeCall(allocator: Allocator, tool_call: ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    allocator.free(tool_call.arguments);
}
