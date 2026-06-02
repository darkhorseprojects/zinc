const std = @import("std");
const files = @import("../sys/fs.zig");
const Allocator = std.mem.Allocator;

pub const ToolResult = struct {
    content: []u8,
    is_error: bool,
    metadata_json: ?[]u8 = null,

    pub fn deinit(self: ToolResult, allocator: Allocator) void {
        allocator.free(self.content);
        if (self.metadata_json) |v| allocator.free(v);
    }
};

const ParamKind = enum { string, object };
const Param = struct { name: []const u8, description: []const u8 = "", required: bool = true, kind: ParamKind = .string };
const Tool = struct {
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    params: []const Param,
};

const builtin = [_]Tool{
    .{ .name = "read", .description = "Read a UTF-8 file from the current working directory, or a Zinc runtime URI such as prompt:<id>, session:current, session:last, or sessions:index. Supports :bytes=<start>-<end> for chunking. Use session:current:tools:<id> or session:current:messages:<index> for specific results.", .prompt = "read files and Zinc runtime URIs", .params = &.{.{ .name = "path" }} },
    .{ .name = "write", .description = "Create or overwrite a UTF-8 file.", .prompt = "create or overwrite files", .params = &.{ .{ .name = "path" }, .{ .name = "content" } } },
    .{ .name = "edit", .description = "Replace exact text in a UTF-8 file. The old text must occur exactly once.", .prompt = "replace exact text in files", .params = &.{ .{ .name = "path" }, .{ .name = "oldText" }, .{ .name = "newText" } } },
    .{ .name = "bash", .description = "Run a shell command in the current working directory.", .prompt = "run shell commands in the current working directory", .params = &.{.{ .name = "command" }} },
    .{ .name = "run_graph", .description = "Request execution of a Circuitry graph. The caller must confirm or deny the request before it runs.", .prompt = "request a Circuitry graph run", .params = &.{ .{ .name = "graph" }, .{ .name = "reason" }, .{ .name = "export", .required = false }, .{ .name = "inputs", .required = false, .kind = .object }, .{ .name = "risk", .required = false } } },
};

pub fn contains(name: []const u8) bool {
    return find(name) != null;
}

pub fn promptSnippet(name: []const u8) ![]const u8 {
    return (find(name) orelse return error.UnknownTool).prompt;
}

pub fn schemaJson(allocator: Allocator, names: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (names, 0..) |name, i| {
        const tool = find(name) orelse return error.UnknownTool;
        if (i != 0) try out.append(allocator, ',');
        try writeSchema(allocator, &out, tool);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn validateArguments(allocator: Allocator, name: []const u8, arg_text: []const u8) !void {
    var parsed = try parseArgs(allocator, arg_text);
    defer parsed.deinit();
    const tool = find(name) orelse return error.UnknownTool;
    for (tool.params) |param| try validateParam(parsed.value.object, param);
}

pub fn requireStringArg(args: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = args.get(name) orelse return error.InvalidToolArguments;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

fn validateParam(args: std.json.ObjectMap, param: Param) !void {
    const value = args.get(param.name) orelse {
        if (param.required) return error.InvalidToolArguments;
        return;
    };
    switch (param.kind) {
        .string => if (value != .string) return error.InvalidToolArguments,
        .object => if (value != .object) return error.InvalidToolArguments,
    }
}

pub fn optionalStringArg(args: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = args.get(name) orelse return null;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

fn find(name: []const u8) ?Tool {
    for (builtin) |tool| if (std.mem.eql(u8, tool.name, name)) return tool;
    return null;
}

fn parseArgs(allocator: Allocator, arg_text: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, arg_text, .{}) catch |err| return switch (err) {
        error.OutOfMemory => err,
        else => error.InvalidToolArguments,
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolArguments;
    return parsed;
}

fn writeSchema(allocator: Allocator, out: *std.ArrayList(u8), tool: Tool) !void {
    try out.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":");
    try files.appendJsonString(allocator, out, tool.name);
    try out.appendSlice(allocator, ",\"description\":");
    try files.appendJsonString(allocator, out, tool.description);
    try out.appendSlice(allocator, ",\"parameters\":{\"type\":\"object\",\"properties\":{");
    for (tool.params, 0..) |param, i| {
        if (i != 0) try out.append(allocator, ',');
        try files.appendJsonString(allocator, out, param.name);
        try out.appendSlice(allocator, ":{\"type\":");
        try files.appendJsonString(allocator, out, if (param.kind == .object) "object" else "string");
        if (param.description.len != 0) {
            try out.appendSlice(allocator, ",\"description\":");
            try files.appendJsonString(allocator, out, param.description);
        }
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "},\"required\":[");
    var required_i: usize = 0;
    for (tool.params) |param| {
        if (!param.required) continue;
        if (required_i != 0) try out.append(allocator, ',');
        try files.appendJsonString(allocator, out, param.name);
        required_i += 1;
    }
    try out.appendSlice(allocator, "]}}}");
}

pub fn graphRunRequest(allocator: Allocator, args: std.json.ObjectMap) !ToolResult {
    const graph = try requireStringArg(args, "graph");
    const reason = try requireStringArg(args, "reason");
    const selected_export = try optionalStringArg(args, "export") orelse "";
    const risk = try optionalStringArg(args, "risk") orelse "";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"status\":\"pending_confirmation\",\"message\":");
    const message = try std.fmt.allocPrint(allocator, "Confirm or deny this graph run request: graph={s} export={s}", .{ graph, if (selected_export.len == 0) "<default>" else selected_export });
    defer allocator.free(message);
    try files.appendJsonString(allocator, &out, message);
    try out.appendSlice(allocator, ",\"graph\":");
    try files.appendJsonString(allocator, &out, graph);
    try out.appendSlice(allocator, ",\"export\":");
    try files.appendJsonString(allocator, &out, selected_export);
    try out.appendSlice(allocator, ",\"inputs\":");
    if (args.get("inputs")) |inputs| {
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
        defer out = aw.toArrayList();
        try std.json.Stringify.value(inputs, .{}, &aw.writer);
    } else try out.appendSlice(allocator, "{}");
    try out.appendSlice(allocator, ",\"reason\":");
    try files.appendJsonString(allocator, &out, reason);
    try out.appendSlice(allocator, ",\"risk\":");
    try files.appendJsonString(allocator, &out, risk);
    try out.append(allocator, '}');
    return .{ .content = try out.toOwnedSlice(allocator), .is_error = false };
}
