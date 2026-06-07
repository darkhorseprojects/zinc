const std = @import("std");
const config = @import("../config/mod.zig");
const resource = @import("../graph/resource.zig");
const transport = @import("transport.zig");

const Allocator = std.mem.Allocator;

pub const Request = struct {
    profile: *const config.RuntimeProfile,
    reasoning_effort: ?[]const u8,
    json_response: bool = false,
    tools_json: []const u8,
    messages: []const Message,
};

pub const Message = struct {
    role: []const u8,
    content: []const u8,
    model: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    name: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    parts: []const resource.ModelPart = &.{},
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const AssistantTurn = struct {
    text: []const u8,
    reasoning: ?[]const u8 = null,
    prompt_tokens: ?usize = null,
    tool_calls: []ToolCall,
};

pub const call = transport.call;

pub fn appendMessage(allocator: Allocator, messages: *std.ArrayList(Message), message: Message) !void {
    const role = try allocator.dupe(u8, message.role);
    errdefer allocator.free(role);
    const content = try allocator.dupe(u8, message.content);
    errdefer allocator.free(content);
    const model = if (message.model) |v| try allocator.dupe(u8, v) else null;
    errdefer if (model) |v| allocator.free(v);
    const reasoning = if (message.reasoning) |v| try allocator.dupe(u8, v) else null;
    errdefer if (reasoning) |v| allocator.free(v);
    const name = if (message.name) |v| try allocator.dupe(u8, v) else null;
    errdefer if (name) |v| allocator.free(v);
    const tool_call_id = if (message.tool_call_id) |v| try allocator.dupe(u8, v) else null;
    errdefer if (tool_call_id) |v| allocator.free(v);
    const tool_calls = try cloneToolCalls(allocator, message.tool_calls);
    errdefer {
        for (tool_calls) |tool_call| freeCall(allocator, tool_call);
        if (tool_calls.len != 0) allocator.free(tool_calls);
    }
    const parts = try cloneParts(allocator, message.parts);
    errdefer {
        for (parts) |part| part.deinit(allocator);
        if (parts.len != 0) allocator.free(parts);
    }
    try messages.append(allocator, .{ .role = role, .content = content, .model = model, .reasoning = reasoning, .name = name, .tool_call_id = tool_call_id, .tool_calls = tool_calls, .parts = parts });
}

pub fn freeMessages(allocator: Allocator, messages: []Message) void {
    for (messages) |message| freeMessage(allocator, message);
}

pub fn freeTurn(allocator: Allocator, turn: AssistantTurn) void {
    allocator.free(turn.text);
    if (turn.reasoning) |value| allocator.free(value);
    for (turn.tool_calls) |tool_call| freeCall(allocator, tool_call);
    allocator.free(turn.tool_calls);
}

pub fn cleanText(allocator: Allocator, raw: []const u8, profile: *const config.RuntimeProfile) ![]u8 {
    _ = profile;
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, text, "```")) {
        const after_open = std.mem.indexOfScalar(u8, text, '\n') orelse return allocator.dupe(u8, text);
        text = std.mem.trim(u8, text[after_open + 1 ..], " \t\r\n");
        if (std.mem.endsWith(u8, text, "```")) text = std.mem.trim(u8, text[0 .. text.len - 3], " \t\r\n");
    }
    return allocator.dupe(u8, text);
}

fn cloneParts(allocator: Allocator, parts: []const resource.ModelPart) ![]resource.ModelPart {
    if (parts.len == 0) return &.{};
    const out = try allocator.alloc(resource.ModelPart, parts.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |part| part.deinit(allocator);
        allocator.free(out);
    }
    for (parts, 0..) |part, i| {
        out[i] = switch (part) {
            .text => |text| .{ .text = try allocator.dupe(u8, text) },
            .image_url => |url| .{ .image_url = try allocator.dupe(u8, url) },
        };
        initialized += 1;
    }
    return out;
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
    if (message.model) |v| allocator.free(v);
    if (message.reasoning) |v| allocator.free(v);
    if (message.name) |v| allocator.free(v);
    if (message.tool_call_id) |v| allocator.free(v);
    for (message.tool_calls) |tool_call| freeCall(allocator, tool_call);
    if (message.tool_calls.len != 0) allocator.free(message.tool_calls);
    for (message.parts) |part| part.deinit(allocator);
    if (message.parts.len != 0) allocator.free(message.parts);
}

fn freeCall(allocator: Allocator, tool_call: ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    allocator.free(tool_call.arguments);
}
