const std = @import("std");
const files = @import("../sys/fs.zig");

const Allocator = std.mem.Allocator;

pub const ToolResult = struct {
    content: []u8,
    is_error: bool,

    pub fn deinit(self: ToolResult, allocator: Allocator) void {
        allocator.free(self.content);
    }
};

pub fn contains(name: []const u8) bool {
    return find(name) != null;
}

pub fn schemaJson(allocator: Allocator, names: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '[');
    for (names, 0..) |name, i| {
        if (i != 0) try out.append(allocator, ',');
        try writeSchema(allocator, &out, name);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn validateAndExecute(allocator: Allocator, io: std.Io, name: []const u8, args: []const u8, resolve_uri: ?fn (Allocator, []const u8) anyerror!?[]u8) !ToolResult {
    if (!contains(name)) return error.UnknownTool;

    const parsed = try parseArgs(allocator, args);
    defer parsed.deinit();

    if (std.mem.eql(u8, name, "read")) return executeRead(allocator, io, parsed.value.object, resolve_uri);
    if (std.mem.eql(u8, name, "write")) return executeWrite(allocator, io, parsed.value.object);
    if (std.mem.eql(u8, name, "edit")) return executeEdit(allocator, io, parsed.value.object);
    if (std.mem.eql(u8, name, "bash")) return executeBash(allocator, io, parsed.value.object);
    if (std.mem.eql(u8, name, "run_graph")) return executeRunGraph(allocator, io, parsed.value.object);

    return error.UnknownTool;
}

fn allTools() []const []const u8 {
    return &.{ "read", "write", "edit", "bash", "run_graph" };
}

fn find(name: []const u8) ?[]const u8 {
    for (allTools()) |tool| {
        if (std.mem.eql(u8, tool, name)) return tool;
    }
    return null;
}

fn writeSchema(allocator: Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    // Simplified JSON schema for tools
    if (std.mem.eql(u8, name, "read")) {
        try out.appendSlice(allocator,
            \\{"type":"function","function":{"name":"read","description":"Read a file or runtime URI","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}
        );
    } else if (std.mem.eql(u8, name, "write")) {
        try out.appendSlice(allocator,
            \\{"type":"function","function":{"name":"write","description":"Write file contents","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}
        );
    } else if (std.mem.eql(u8, name, "edit")) {
        try out.appendSlice(allocator,
            \\{"type":"function","function":{"name":"edit","description":"Replace exact text","parameters":{"type":"object","properties":{"path":{"type":"string"},"oldText":{"type":"string"},"newText":{"type":"string"}},"required":["path","oldText","newText"]}}
        );
    } else if (std.mem.eql(u8, name, "bash")) {
        try out.appendSlice(allocator,
            \\{"type":"function","function":{"name":"bash","description":"Execute shell command","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}
        );
    } else if (std.mem.eql(u8, name, "run_graph")) {
        try out.appendSlice(allocator,
            \\{"type":"function","function":{"name":"run_graph","description":"Request graph execution","parameters":{"type":"object","properties":{"graph":{"type":"string"},"entry":{"type":"string"},"inputs":{"type":"object"},"reason":{"type":"string"},"risk":{"type":"string"}},"required":["graph","reason"]}}
        );
    }
}

fn parseArgs(allocator: Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => return error.InvalidToolArguments,
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolArguments;
    return parsed;
}

fn objectGetString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingArgument;
    if (value != .string) return error.InvalidArgumentType;
    return value.string;
}

fn executeRead(allocator: Allocator, _io: std.Io, args: std.json.ObjectMap, resolve_uri: ?fn (Allocator, []const u8) anyerror!?[]u8) !ToolResult {
    _ = _io;
    const path = try objectGetString(args, "path");

    // Try runtime URI resolution first
    if (resolve_uri) |resolver| {
        if (try resolver(allocator, path)) |content| {
            return ToolResult{ .content = content, .is_error = false };
        }
    }

    return executeReadFile(allocator, path);
}

fn executeReadFile(allocator: Allocator, path: []const u8) !ToolResult {
    return ToolResult{ .content = try files.readLimited(allocator, path, 1024 * 1024), .is_error = false };
}

fn executeWrite(allocator: Allocator, io: std.Io, args: std.json.ObjectMap) !ToolResult {
    _ = io;
    const path = try objectGetString(args, "path");
    const content = try objectGetString(args, "content");
    try files.write(path, content);
    return ToolResult{ .content = try std.fmt.allocPrint(allocator, "wrote {s}", .{path}), .is_error = false };
}

fn executeEdit(allocator: Allocator, io: std.Io, args: std.json.ObjectMap) !ToolResult {
    _ = io;
    const path = try objectGetString(args, "path");
    const old_text = try objectGetString(args, "oldText");
    const new_text = try objectGetString(args, "newText");
    try files.edit(allocator, path, old_text, new_text);
    return ToolResult{ .content = try std.fmt.allocPrint(allocator, "edited {s}", .{path}), .is_error = false };
}

fn executeBash(allocator: Allocator, io: std.Io, args: std.json.ObjectMap) !ToolResult {
    const command = try objectGetString(args, "command");
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "sh", "-lc", command } });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };

    return ToolResult{
        .content = try std.fmt.allocPrint(allocator, "exit={d}\nstdout:\n{s}\nstderr:\n{s}", .{ code, result.stdout, result.stderr }),
        .is_error = code != 0,
    };
}

fn executeRunGraph(allocator: Allocator, io: std.Io, args: std.json.ObjectMap) !ToolResult {
    _ = io;
    const graph = try objectGetString(args, "graph");
    const reason = try objectGetString(args, "reason");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"status\":\"pending_approval\",\"graph\":");
    try files.appendJsonString(allocator, &out, graph);
    try out.appendSlice(allocator, ",\"reason\":");
    try files.appendJsonString(allocator, &out, reason);
    try out.append(allocator, '}');

    return ToolResult{ .content = try out.toOwnedSlice(allocator), .is_error = false };
}
