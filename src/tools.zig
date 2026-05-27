const std = @import("std");
const files = @import("files.zig");

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

const Param = struct { name: []const u8, description: []const u8 = "" };
const Tool = struct {
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    params: []const Param,
    run: *const fn (Allocator, std.Io, std.json.ObjectMap) anyerror!ToolResult,
};

const builtin = [_]Tool{
    .{ .name = "read", .description = "Read a UTF-8 file from the current working directory, or a Zinc runtime URI such as prompt:<id>, session:current, session:last, or sessions:index.", .prompt = "read files and Zinc runtime URIs", .params = &.{.{ .name = "path" }}, .run = runRead },
    .{ .name = "write", .description = "Create or overwrite a UTF-8 file.", .prompt = "create or overwrite files", .params = &.{ .{ .name = "path" }, .{ .name = "content" } }, .run = runWrite },
    .{ .name = "edit", .description = "Replace exact text in a UTF-8 file. The old text must occur exactly once.", .prompt = "replace exact text in files", .params = &.{ .{ .name = "path" }, .{ .name = "oldText" }, .{ .name = "newText" } }, .run = runEdit },
    .{ .name = "bash", .description = "Run a shell command in the current working directory.", .prompt = "run shell commands in the current working directory", .params = &.{.{ .name = "command" }}, .run = runBashTool },
    .{ .name = "request_circuitry_run", .description = "Request root/user approval to run another Circuitry graph. Does not execute recursively by itself.", .prompt = "request approval to run another Circuitry graph", .params = &.{ .{ .name = "reason" }, .{ .name = "graph" }, .{ .name = "expected_result" }, .{ .name = "risk" } }, .run = runCircuitryRequest },
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
    for (tool.params) |param| _ = try requireStringArg(parsed.value.object, param.name);
}

pub fn executeResult(allocator: Allocator, io: std.Io, name: []const u8, arg_text: []const u8) !ToolResult {
    var parsed = try parseArgs(allocator, arg_text);
    defer parsed.deinit();
    const tool = find(name) orelse return error.UnknownTool;
    for (tool.params) |param| _ = try requireStringArg(parsed.value.object, param.name);
    return tool.run(allocator, io, parsed.value.object);
}

pub fn requireStringArg(args: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = args.get(name) orelse return error.InvalidToolArguments;
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
        try out.appendSlice(allocator, ":{\"type\":\"string\"");
        if (param.description.len != 0) {
            try out.appendSlice(allocator, ",\"description\":");
            try files.appendJsonString(allocator, out, param.description);
        }
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "},\"required\":[");
    for (tool.params, 0..) |param, i| {
        if (i != 0) try out.append(allocator, ',');
        try files.appendJsonString(allocator, out, param.name);
    }
    try out.appendSlice(allocator, "]}}}");
}

fn runRead(allocator: Allocator, _: std.Io, args: std.json.ObjectMap) !ToolResult {
    return .{ .content = try files.readLimited(allocator, try requireStringArg(args, "path"), 1024 * 1024), .is_error = false };
}

fn runWrite(allocator: Allocator, _: std.Io, args: std.json.ObjectMap) !ToolResult {
    const path = try requireStringArg(args, "path");
    try files.write(path, try requireStringArg(args, "content"));
    return .{ .content = try std.fmt.allocPrint(allocator, "wrote {s}", .{path}), .is_error = false };
}

fn runEdit(allocator: Allocator, _: std.Io, args: std.json.ObjectMap) !ToolResult {
    const path = try requireStringArg(args, "path");
    try files.edit(allocator, path, try requireStringArg(args, "oldText"), try requireStringArg(args, "newText"));
    return .{ .content = try std.fmt.allocPrint(allocator, "edited {s}", .{path}), .is_error = false };
}

fn runBashTool(allocator: Allocator, io: std.Io, args: std.json.ObjectMap) !ToolResult {
    return runBash(allocator, io, try requireStringArg(args, "command"));
}

fn runCircuitryRequest(allocator: Allocator, _: std.Io, args: std.json.ObjectMap) !ToolResult {
    const graph = try requireStringArg(args, "graph");
    const reason = try requireStringArg(args, "reason");
    const expected = try requireStringArg(args, "expected_result");
    const risk = try requireStringArg(args, "risk");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"status\":\"pending_approval\",\"message\":");
    const message = try std.fmt.allocPrint(allocator, "Circuitry graph execution requires root/user approval. Run `zn {s}` or `zn run {s}` from the root-facing Zinc invocation if approved.", .{ graph, graph });
    defer allocator.free(message);
    try files.appendJsonString(allocator, &out, message);
    try out.appendSlice(allocator, ",\"graph\":");
    try files.appendJsonString(allocator, &out, graph);
    try out.appendSlice(allocator, ",\"reason\":");
    try files.appendJsonString(allocator, &out, reason);
    try out.appendSlice(allocator, ",\"expected_result\":");
    try files.appendJsonString(allocator, &out, expected);
    try out.appendSlice(allocator, ",\"risk\":");
    try files.appendJsonString(allocator, &out, risk);
    try out.append(allocator, '}');
    return .{ .content = try out.toOwnedSlice(allocator), .is_error = false };
}

fn runBash(allocator: Allocator, io: std.Io, command: []const u8) !ToolResult {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "sh", "-lc", command } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    var metadata: std.ArrayList(u8) = .empty;
    errdefer metadata.deinit(allocator);
    try metadata.appendSlice(allocator, "{\"command\":");
    try files.appendJsonString(allocator, &metadata, command);
    try metadata.print(allocator, ",\"exit\":{d},\"stdout\":", .{code});
    try files.appendJsonString(allocator, &metadata, result.stdout);
    try metadata.appendSlice(allocator, ",\"stderr\":");
    try files.appendJsonString(allocator, &metadata, result.stderr);
    try metadata.appendSlice(allocator, ",\"is_error\":");
    try metadata.appendSlice(allocator, if (code == 0) "false}" else "true}");
    return .{
        .content = try std.fmt.allocPrint(allocator, "exit={d}\nstdout:\n{s}\nstderr:\n{s}", .{ code, result.stdout, result.stderr }),
        .is_error = code != 0,
        .metadata_json = try metadata.toOwnedSlice(allocator),
    };
}
