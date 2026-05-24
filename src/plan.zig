const std = @import("std");
const files = @import("files.zig");
const tool_registry = @import("tool_registry.zig");

const Allocator = std.mem.Allocator;

pub const PromptPack = struct {
    id: []u8,
    title: []u8,
    description: []u8,
    content: []u8,

    fn deinit(self: PromptPack, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.content);
    }
};

pub const Plan = struct {
    prompt: []u8,
    focused_recovery_prompt: []u8,
    focused_recovery_tools: [][]u8,
    focused_recovery_tools_json: []u8,
    model_id: []u8,
    model_alias: []u8,
    temperature: f64,
    max_tokens: ?usize,
    context_tokens: usize,
    tool_format: []u8,
    reasoning_format: []u8,
    reasoning_tokens: isize,
    tools: [][]u8,
    tools_json: []u8,
    prompts: []PromptPack,

    pub fn deinit(self: Plan, allocator: Allocator) void {
        allocator.free(self.prompt);
        allocator.free(self.focused_recovery_prompt);
        for (self.focused_recovery_tools) |tool| allocator.free(tool);
        allocator.free(self.focused_recovery_tools);
        allocator.free(self.focused_recovery_tools_json);
        allocator.free(self.model_id);
        allocator.free(self.model_alias);
        allocator.free(self.tool_format);
        allocator.free(self.reasoning_format);
        for (self.tools) |tool| allocator.free(tool);
        allocator.free(self.tools);
        allocator.free(self.tools_json);
        for (self.prompts) |prompt| prompt.deinit(allocator);
        allocator.free(self.prompts);
    }

    pub fn allowsTool(self: Plan, name: []const u8) bool {
        for (self.tools) |tool| if (std.mem.eql(u8, tool, name)) return true;
        return false;
    }

    pub fn promptContent(self: Plan, id: []const u8) ?[]const u8 {
        for (self.prompts) |prompt| if (std.mem.eql(u8, prompt.id, id)) return prompt.content;
        return null;
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
    const tool_names = try readToolNames(allocator, tools_value);
    errdefer freeToolNames(allocator, tool_names);
    const tools_json = try buildToolsJson(allocator, tool_names);
    const focused_tools_value = root.get("focused_recovery_tools") orelse return error.BadRuntimePlan;
    const focused_tool_names = try readToolNames(allocator, focused_tools_value);
    errdefer freeToolNames(allocator, focused_tool_names);
    const focused_tools_json = try buildToolsJson(allocator, focused_tool_names);
    const prompts_value = root.get("prompts") orelse return error.BadRuntimePlan;
    const prompts = try readPrompts(allocator, prompts_value);
    errdefer {
        for (prompts) |prompt| prompt.deinit(allocator);
        allocator.free(prompts);
    }
    return .{
        .prompt = try allocator.dupe(u8, (root.get("prompt") orelse return error.BadRuntimePlan).string),
        .focused_recovery_prompt = try allocator.dupe(u8, (root.get("focused_recovery_prompt") orelse return error.BadRuntimePlan).string),
        .focused_recovery_tools = focused_tool_names,
        .focused_recovery_tools_json = focused_tools_json,
        .model_id = try allocator.dupe(u8, (model_object.get("id") orelse return error.BadRuntimePlan).string),
        .model_alias = try allocator.dupe(u8, (model_object.get("alias") orelse return error.BadRuntimePlan).string),
        .temperature = try readF64(model_object.get("temperature") orelse return error.BadRuntimePlan),
        .max_tokens = try readOptionalUsize(model_object.get("max_tokens") orelse return error.BadRuntimePlan),
        .context_tokens = try readUsize(model_object.get("context_tokens") orelse return error.BadRuntimePlan),
        .tool_format = try allocator.dupe(u8, (model_object.get("tool_format") orelse return error.BadRuntimePlan).string),
        .reasoning_format = try allocator.dupe(u8, (model_object.get("reasoning_format") orelse return error.BadRuntimePlan).string),
        .reasoning_tokens = try readIsize(model_object.get("reasoning_tokens") orelse return error.BadRuntimePlan),
        .tools = tool_names,
        .tools_json = tools_json,
        .prompts = prompts,
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

fn readUsize(value: std.json.Value) !usize {
    return switch (value) {
        .integer => |v| if (v >= 0) @intCast(v) else error.BadRuntimePlan,
        else => error.BadRuntimePlan,
    };
}

fn readIsize(value: std.json.Value) !isize {
    return switch (value) {
        .integer => |v| @intCast(v),
        else => error.BadRuntimePlan,
    };
}

fn readToolNames(allocator: Allocator, value: std.json.Value) ![][]u8 {
    if (value != .array) return error.BadRuntimePlan;
    var out = try allocator.alloc([]u8, value.array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |tool| allocator.free(tool);
        allocator.free(out);
    }
    for (value.array.items, 0..) |tool, i| {
        if (tool != .string) return error.BadRuntimePlan;
        out[i] = try allocator.dupe(u8, tool.string);
        initialized += 1;
    }
    return out;
}

fn freeToolNames(allocator: Allocator, tools: [][]u8) void {
    for (tools) |tool| allocator.free(tool);
    allocator.free(tools);
}

fn readPrompts(allocator: Allocator, value: std.json.Value) ![]PromptPack {
    if (value != .array) return error.BadRuntimePlan;
    var out = try allocator.alloc(PromptPack, value.array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |prompt| prompt.deinit(allocator);
        allocator.free(out);
    }
    for (value.array.items, 0..) |item, i| {
        if (item != .object) return error.BadRuntimePlan;
        out[i] = .{
            .id = try allocator.dupe(u8, readString(item.object, "id")),
            .title = try allocator.dupe(u8, readString(item.object, "title")),
            .description = try allocator.dupe(u8, readString(item.object, "description")),
            .content = try allocator.dupe(u8, readString(item.object, "content")),
        };
        initialized += 1;
    }
    return out;
}

fn readString(object: std.json.ObjectMap, field: []const u8) []const u8 {
    const value = object.get(field) orelse return "";
    if (value != .string) return "";
    return value.string;
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
