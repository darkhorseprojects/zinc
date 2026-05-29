const std = @import("std");
const files = @import("../sys/fs.zig");
const tools = @import("../sys/process.zig");

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

pub const InputKind = enum { text, file, image };

pub const InputSpec = struct {
    id: []u8,
    kind: InputKind,
    required: bool,

    pub fn deinit(self: InputSpec, allocator: Allocator) void {
        allocator.free(self.id);
    }
};

pub const RuntimeInput = struct {
    id: []u8,
    kind: InputKind,
    value: []u8,
    mime: []u8,

    pub fn deinit(self: RuntimeInput, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.value);
        allocator.free(self.mime);
    }
};

pub const ImageInput = struct {
    id: []u8,
    path: []u8,
    mime: []u8,

    pub fn deinit(self: ImageInput, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
        allocator.free(self.mime);
    }
};

pub const Plan = struct {
    graph_path: []u8,
    entry: []u8,
    prompt: []u8,
    focused_recovery_prompt: []u8,
    focused_recovery_tools: [][]u8,
    focused_recovery_tools_json: []u8,
    model_id: []u8,
    model_alias: []u8,
    temperature: f64,
    max_tokens: ?usize,
    context_tokens: usize,
    reasoning_tokens: isize,
    tools: [][]u8,
    tools_json: []u8,
    prompts: []PromptPack,
    inputs: []InputSpec,
    image_inputs: []ImageInput,

    pub fn deinit(self: Plan, allocator: Allocator) void {
        allocator.free(self.graph_path);
        allocator.free(self.entry);
        allocator.free(self.prompt);
        allocator.free(self.focused_recovery_prompt);
        for (self.focused_recovery_tools) |tool| allocator.free(tool);
        allocator.free(self.focused_recovery_tools);
        allocator.free(self.focused_recovery_tools_json);
        allocator.free(self.model_id);
        allocator.free(self.model_alias);

        for (self.tools) |tool| allocator.free(tool);
        allocator.free(self.tools);
        allocator.free(self.tools_json);
        for (self.prompts) |prompt| prompt.deinit(allocator);
        allocator.free(self.prompts);
        for (self.inputs) |input| input.deinit(allocator);
        allocator.free(self.inputs);
        for (self.image_inputs) |image| image.deinit(allocator);
        allocator.free(self.image_inputs);
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
    return loadFromSlice(allocator, text);
}

pub fn loadFromSlice(allocator: Allocator, text: []const u8) !Plan {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const model = root.get("model") orelse return error.BadRuntimePlan;
    const model_object = model.object;
    const tools_value = root.get("tools") orelse return error.BadRuntimePlan;
    const tool_names = try readToolNames(allocator, tools_value);
    errdefer freeToolNames(allocator, tool_names);
    const tools_json = try buildToolsJson(allocator, tool_names);
    const focused_tool_names = if (root.get("focused_recovery_tools")) |value| try readToolNames(allocator, value) else try allocator.alloc([]u8, 0);
    errdefer freeToolNames(allocator, focused_tool_names);
    const focused_tools_json = try buildToolsJson(allocator, focused_tool_names);
    const prompts_value = root.get("prompts") orelse return error.BadRuntimePlan;
    const prompts = try readPrompts(allocator, prompts_value);
    errdefer {
        for (prompts) |prompt| prompt.deinit(allocator);
        allocator.free(prompts);
    }
    const inputs = if (root.get("inputs")) |value| try readInputSpecs(allocator, value) else try allocator.alloc(InputSpec, 0);
    errdefer {
        for (inputs) |input| input.deinit(allocator);
        allocator.free(inputs);
    }
    const image_inputs = if (root.get("image_inputs")) |value| try readImageInputs(allocator, value) else try allocator.alloc(ImageInput, 0);
    errdefer {
        for (image_inputs) |image| image.deinit(allocator);
        allocator.free(image_inputs);
    }
    return .{
        .graph_path = try allocator.dupe(u8, if (root.get("graph_path")) |value| value.string else ""),
        .entry = try allocator.dupe(u8, if (root.get("entry")) |value| value.string else ""),
        .prompt = try allocator.dupe(u8, (root.get("prompt") orelse return error.BadRuntimePlan).string),
        .focused_recovery_prompt = try allocator.dupe(u8, if (root.get("focused_recovery_prompt")) |value| value.string else ""),
        .focused_recovery_tools = focused_tool_names,
        .focused_recovery_tools_json = focused_tools_json,
        .model_id = try allocator.dupe(u8, (model_object.get("id") orelse return error.BadRuntimePlan).string),
        .model_alias = try allocator.dupe(u8, (model_object.get("alias") orelse return error.BadRuntimePlan).string),
        .temperature = try readF64(model_object.get("temperature") orelse return error.BadRuntimePlan),
        .max_tokens = try readOptionalUsize(model_object.get("max_tokens") orelse return error.BadRuntimePlan),
        .context_tokens = try readUsize(model_object.get("context_tokens") orelse return error.BadRuntimePlan),
        .reasoning_tokens = try readIsize(model_object.get("reasoning_tokens") orelse return error.BadRuntimePlan),
        .tools = tool_names,
        .tools_json = tools_json,
        .prompts = prompts,
        .inputs = inputs,
        .image_inputs = image_inputs,
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

fn freeToolNames(allocator: Allocator, tool_names: [][]u8) void {
    for (tool_names) |tool| allocator.free(tool);
    allocator.free(tool_names);
}

pub fn inputKindName(kind: InputKind) []const u8 {
    return switch (kind) {
        .text => "text",
        .file => "file",
        .image => "image",
    };
}

pub fn parseInputKind(raw: []const u8) !InputKind {
    if (std.mem.eql(u8, raw, "text")) return .text;
    if (std.mem.eql(u8, raw, "file")) return .file;
    if (std.mem.eql(u8, raw, "image")) return .image;
    return error.BadRuntimePlan;
}

fn readInputSpecs(allocator: Allocator, value: std.json.Value) ![]InputSpec {
    if (value != .array) return error.BadRuntimePlan;
    var out = try allocator.alloc(InputSpec, value.array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |input| input.deinit(allocator);
        allocator.free(out);
    }
    for (value.array.items, 0..) |item, i| {
        if (item != .object) return error.BadRuntimePlan;
        out[i] = .{
            .id = try allocator.dupe(u8, readString(item.object, "id")),
            .kind = try parseInputKind(readString(item.object, "type")),
            .required = readBool(item.object, "required"),
        };
        initialized += 1;
    }
    return out;
}

fn readImageInputs(allocator: Allocator, value: std.json.Value) ![]ImageInput {
    if (value != .array) return error.BadRuntimePlan;
    var out = try allocator.alloc(ImageInput, value.array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |image| image.deinit(allocator);
        allocator.free(out);
    }
    for (value.array.items, 0..) |item, i| {
        if (item != .object) return error.BadRuntimePlan;
        out[i] = .{
            .id = try allocator.dupe(u8, readString(item.object, "id")),
            .path = try allocator.dupe(u8, readString(item.object, "path")),
            .mime = try allocator.dupe(u8, readString(item.object, "mime")),
        };
        initialized += 1;
    }
    return out;
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

fn readBool(object: std.json.ObjectMap, field: []const u8) bool {
    const value = object.get(field) orelse return false;
    return if (value == .bool) value.bool else false;
}

pub fn buildToolsJson(allocator: Allocator, tool_names: []const []const u8) ![]u8 {
    return tools.schemaJson(allocator, tool_names);
}
