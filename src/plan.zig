const std = @import("std");
const files = @import("files.zig");
const tool_registry = @import("tool_registry.zig");

const Allocator = std.mem.Allocator;

pub const Plan = struct {
    prompt: []u8,
    context_prompt: []u8,
    model_id: []u8,
    model_alias: []u8,
    temperature: f64,
    max_tokens: ?usize,
    tool_format: []u8,
    reasoning_effort: []u8,
    reasoning_format: []u8,
    tool_reasoning: bool,
    tools: [][]u8,
    tools_json: []u8,

    pub fn deinit(self: Plan, allocator: Allocator) void {
        allocator.free(self.prompt);
        allocator.free(self.context_prompt);
        allocator.free(self.model_id);
        allocator.free(self.model_alias);
        allocator.free(self.tool_format);
        allocator.free(self.reasoning_effort);
        allocator.free(self.reasoning_format);
        for (self.tools) |tool| allocator.free(tool);
        allocator.free(self.tools);
        allocator.free(self.tools_json);
    }

    pub fn allowsTool(self: Plan, name: []const u8) bool {
        for (self.tools) |tool| if (std.mem.eql(u8, tool, name)) return true;
        return false;
    }
};

pub fn load(allocator: Allocator, path: []const u8) !Plan {
    const text = try files.readLimited(allocator, path, 128 * 1024);
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const model = root.get("model") orelse return error.BadRuntimePlan;
    const model_object = model.object;
    const tools_value = root.get("tools") orelse return error.BadRuntimePlan;
    var tool_names = try allocator.alloc([]u8, tools_value.array.items.len);
    errdefer allocator.free(tool_names);
    for (tools_value.array.items, 0..) |tool, i| tool_names[i] = try allocator.dupe(u8, tool.string);
    const tools_json = try buildToolsJson(allocator, tool_names);
    return .{
        .prompt = try allocator.dupe(u8, (root.get("prompt") orelse return error.BadRuntimePlan).string),
        .context_prompt = try allocator.dupe(u8, (root.get("context_prompt") orelse return error.BadRuntimePlan).string),
        .model_id = try allocator.dupe(u8, (model_object.get("id") orelse return error.BadRuntimePlan).string),
        .model_alias = try allocator.dupe(u8, (model_object.get("alias") orelse return error.BadRuntimePlan).string),
        .temperature = try readF64(model_object.get("temperature") orelse return error.BadRuntimePlan),
        .max_tokens = try readOptionalUsize(model_object.get("max_tokens") orelse return error.BadRuntimePlan),
        .tool_format = try allocator.dupe(u8, (model_object.get("tool_format") orelse return error.BadRuntimePlan).string),
        .reasoning_effort = try allocator.dupe(u8, (model_object.get("reasoning_effort") orelse return error.BadRuntimePlan).string),
        .reasoning_format = try allocator.dupe(u8, (model_object.get("reasoning_format") orelse return error.BadRuntimePlan).string),
        .tool_reasoning = try readBool(model_object.get("tool_reasoning") orelse return error.BadRuntimePlan),
        .tools = tool_names,
        .tools_json = tools_json,
    };
}

fn readF64(value: std.json.Value) !f64 {
    return switch (value) {
        .float => value.float,
        .integer => @floatFromInt(value.integer),
        else => error.BadRuntimePlan,
    };
}

fn readOptionalUsize(value: std.json.Value) !?usize {
    return switch (value) {
        .null => null,
        .integer => |v| if (v >= 0) @intCast(v) else error.BadRuntimePlan,
        else => error.BadRuntimePlan,
    };
}

fn readBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => value.bool,
        else => error.BadRuntimePlan,
    };
}

pub fn buildToolsJson(allocator: Allocator, tools: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (tools, 0..) |tool_name, i| {
        const tool = tool_registry.find(tool_name) orelse return error.UnknownTool;
        if (i != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, tool.schema);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}
