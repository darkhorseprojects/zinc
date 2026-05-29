const std = @import("std");
const files = @import("fs.zig");
const sessions = @import("../runtime/session.zig");

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
    .{ .name = "read", .description = "Read a UTF-8 file from the current working directory, or a Zinc runtime URI such as prompt:<id>, session:current, session:last, or sessions:index. Supports :bytes=<start>-<end> for chunking. Use session:current:tools:<id> or session:current:messages:<index> for specific results.", .prompt = "read files and Zinc runtime URIs", .params = &.{.{ .name = "path" }}, .run = runRead },
    .{ .name = "write", .description = "Create or overwrite a UTF-8 file.", .prompt = "create or overwrite files", .params = &.{ .{ .name = "path" }, .{ .name = "content" } }, .run = runWrite },
    .{ .name = "edit", .description = "Replace exact text in a UTF-8 file. The old text must occur exactly once.", .prompt = "replace exact text in files", .params = &.{ .{ .name = "path" }, .{ .name = "oldText" }, .{ .name = "newText" } }, .run = runEdit },
    .{ .name = "bash", .description = "Run a shell command in the current working directory.", .prompt = "run shell commands in the current working directory", .params = &.{.{ .name = "command" }}, .run = runBashTool },
    .{ .name = "run_graph", .description = "Request execution of a Circuitry graph. Zinc records the request for root/user approval instead of silently recursing.", .prompt = "request a Circuitry graph run", .params = &.{ .{ .name = "reason" }, .{ .name = "graph" }, .{ .name = "entry" }, .{ .name = "inputs" }, .{ .name = "risk" } }, .run = runCircuitryRequest },
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
    const path = try requireStringArg(args, "path");

    if (std.mem.indexOf(u8, path, "tools:")) |pos| {
        return try readToolResult(allocator, path, pos);
    }

    if (std.mem.indexOf(u8, path, "messages:")) |pos| {
        return try readMessageResult(allocator, path, pos);
    }

    if (std.mem.indexOf(u8, path, ":bytes=")) |byte_pos| {
        const split = splitByteRange(path, byte_pos);
        return try readWithRange(allocator, split.base_path, split.range);
    }

    return fullRead(allocator, path);
}

const ByteRangeSplit = struct {
    base_path: []const u8,
    range: []const u8,
};

fn splitByteRange(path: []const u8, byte_pos: usize) ByteRangeSplit {
    return .{
        .base_path = path[0..byte_pos],
        .range = path[byte_pos + ":bytes=".len..],
    };
}

fn readWithRange(allocator: Allocator, base_path: []const u8, range_str: []const u8) !ToolResult {
    var start: usize = 0;
    var end: ?usize = null;
    if (std.mem.indexOfScalar(u8, range_str, '-')) |dash_pos| {
        if (dash_pos > 0) {
            start = try std.fmt.parseInt(usize, range_str[0..dash_pos], 10);
        }
        if (dash_pos + 1 < range_str.len) {
            end = try std.fmt.parseInt(usize, range_str[dash_pos + 1..], 10);
        }
    } else {
        start = try std.fmt.parseInt(usize, range_str, 10);
    }

    const full_content = try files.readLimited(allocator, base_path, 8 * 1024 * 1024);
    defer allocator.free(full_content);

    const actual_start = @min(start, full_content.len);
    const actual_end = if (end) |e| @min(e, full_content.len) else full_content.len;
    if (actual_start > actual_end) return error.InvalidByteRange;

    return .{
        .content = try allocator.dupe(u8, full_content[actual_start..actual_end]),
        .is_error = false,
    };
}

fn fullRead(allocator: Allocator, path: []const u8) !ToolResult {
    return .{ .content = try files.readLimited(allocator, path, 1024 * 1024), .is_error = false };
}

fn readToolResult(allocator: Allocator, path: []const u8, tools_pos: usize) !ToolResult {
    var tool_id = path[tools_pos + "tools:".len..];
    var start: usize = 0;
    var end: ?usize = null;
    var has_range = false;

    if (std.mem.indexOf(u8, tool_id, ":bytes=")) |bytes_pos| {
        const range_str = tool_id[bytes_pos + ":bytes=".len..];
        tool_id = tool_id[0..bytes_pos];
        has_range = true;
        if (std.mem.indexOfScalar(u8, range_str, '-')) |dash_pos| {
            if (dash_pos > 0) {
                start = try std.fmt.parseInt(usize, range_str[0..dash_pos], 10);
            }
            if (dash_pos + 1 < range_str.len) {
                end = try std.fmt.parseInt(usize, range_str[dash_pos + 1..], 10);
            }
        } else {
            start = try std.fmt.parseInt(usize, range_str, 10);
        }
    }

    const last_id = try sessions.readLastId(allocator);
    defer allocator.free(last_id);
    const session_path = try std.fmt.allocPrint(allocator, ".zinc/sessions/{s}.jsonl", .{last_id});
    defer allocator.free(session_path);

    const log = try sessions.readParsed(allocator, session_path);
    defer log.deinit(allocator);

    for (log.messages) |message| {
        if (std.mem.eql(u8, message.role, "tool")) {
            if (message.tool_call_id) |tc_id| {
                if (std.mem.eql(u8, tc_id, tool_id)) {
                    var content = message.content;
                    if (has_range) {
                        const actual_start = @min(start, content.len);
                        const actual_end = if (end) |e| @min(e, content.len) else content.len;
                        if (actual_start > actual_end) return error.InvalidByteRange;
                        return .{
                            .content = try allocator.dupe(u8, content[actual_start..actual_end]),
                            .is_error = false,
                        };
                    } else {
                        return .{
                            .content = try allocator.dupe(u8, content),
                            .is_error = false,
                        };
                    }
                }
            }
        }
    }
    return error.ToolResultNotFound;
}

fn readMessageResult(allocator: Allocator, path: []const u8, msg_pos: usize) !ToolResult {
    var msg_id_str = path[msg_pos + "messages:".len..];
    var start: usize = 0;
    var end: ?usize = null;
    var has_range = false;

    if (std.mem.indexOf(u8, msg_id_str, ":bytes=")) |bytes_pos| {
        const range_str = msg_id_str[bytes_pos + ":bytes=".len..];
        msg_id_str = msg_id_str[0..bytes_pos];
        has_range = true;
        if (std.mem.indexOfScalar(u8, range_str, '-')) |dash_pos| {
            if (dash_pos > 0) {
                start = try std.fmt.parseInt(usize, range_str[0..dash_pos], 10);
            }
            if (dash_pos + 1 < range_str.len) {
                end = try std.fmt.parseInt(usize, range_str[dash_pos + 1..], 10);
            }
        } else {
            start = try std.fmt.parseInt(usize, range_str, 10);
        }
    }

    const index = try std.fmt.parseInt(usize, msg_id_str, 10);

    const last_id = try sessions.readLastId(allocator);
    defer allocator.free(last_id);
    const session_path = try std.fmt.allocPrint(allocator, ".zinc/sessions/{s}.jsonl", .{last_id});
    defer allocator.free(session_path);

    const log = try sessions.readParsed(allocator, session_path);
    defer log.deinit(allocator);

    if (index >= log.messages.len) return error.MessageIndexOutOfBounds;
    const message = log.messages[index];
    const content = message.content;

    if (has_range) {
        const actual_start = @min(start, content.len);
        const actual_end = if (end) |e| @min(e, content.len) else content.len;
        if (actual_start > actual_end) return error.InvalidByteRange;
        return .{
            .content = try allocator.dupe(u8, content[actual_start..actual_end]),
            .is_error = false,
        };
    } else {
        return .{
            .content = try allocator.dupe(u8, content),
            .is_error = false,
        };
    }
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
    const entry = try requireStringArg(args, "entry");
    const inputs = try requireStringArg(args, "inputs");
    const risk = try requireStringArg(args, "risk");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"status\":\"pending_approval\",\"message\":");
    const message = try std.fmt.allocPrint(allocator, "Circuitry graph execution requires root/user approval. Run `zn run --graph {s} --entry {s}` from the root-facing Zinc invocation if approved.", .{ graph, entry });
    defer allocator.free(message);
    try files.appendJsonString(allocator, &out, message);
    try out.appendSlice(allocator, ",\"graph\":");
    try files.appendJsonString(allocator, &out, graph);
    try out.appendSlice(allocator, ",\"entry\":");
    try files.appendJsonString(allocator, &out, entry);
    try out.appendSlice(allocator, ",\"inputs\":");
    try files.appendJsonString(allocator, &out, inputs);
    try out.appendSlice(allocator, ",\"reason\":");
    try files.appendJsonString(allocator, &out, reason);
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
