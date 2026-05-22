const std = @import("std");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;

pub fn validateText(text: []const u8) !void {
    try requireContains(text, "circuitry: \"0.2.99\"");
    try requireContains(text, "resources:");
    try requireContains(text, "  user_turn:");
    try requireContains(text, "    type: text");
    try requireContains(text, "  session_log:");
    try requireContains(text, "  recovered_context:");
    try requireContains(text, "    inputs: [user_turn, session_log]");
    try requireContains(text, "  assistant:");
    try requireContains(text, "    type: agent");
    try requireContains(text, "    inputs: [user_turn, recovered_context]");
    try requireContains(text, "    tools:");
    try requireContains(text, "    expect:");
    try requireContains(text, "      response: str");
    try requireContains(text, "      done: bool");
    try requireContains(text, "    instructions: |");
}

pub fn readLinkedText(allocator: Allocator, graph_path: []const u8) anyerror![]u8 {
    return readLinkedTextStack(allocator, graph_path, &.{});
}

fn readLinkedTextStack(allocator: Allocator, graph_path: []const u8, stack: []const []const u8) anyerror![]u8 {
    const canonical = try absolutePath(allocator, graph_path);
    defer allocator.free(canonical);
    for (stack) |ancestor| if (std.mem.eql(u8, ancestor, canonical)) return error.CircuitryGraphLinkCycle;

    var next_stack = try allocator.alloc([]const u8, stack.len + 1);
    defer allocator.free(next_stack);
    @memcpy(next_stack[0..stack.len], stack);
    next_stack[stack.len] = canonical;

    const text = try files.readLimited(allocator, canonical, 1024 * 1024);
    errdefer allocator.free(text);
    const linked = try readLinks(allocator, canonical, text, next_stack);
    defer freeStringList(allocator, linked);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (linked) |linked_text| {
        try out.appendSlice(allocator, linked_text);
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, text);
    allocator.free(text);
    return out.toOwnedSlice(allocator);
}

pub fn readTools(allocator: Allocator, graph_text: []const u8, resource_id: []const u8) ![][]u8 {
    const block = resourceBlock(graph_text, resource_id) orelse return error.InvalidCircuitryGraph;
    const line = findLineStarting(block, "    tools:") orelse return error.InvalidCircuitryGraph;
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    const tail = std.mem.trim(u8, line["    tools:".len..], " \t\r");
    if (std.mem.startsWith(u8, tail, "[")) {
        const end = std.mem.lastIndexOfScalar(u8, tail, ']') orelse return error.InvalidCircuitryGraph;
        var parts = std.mem.splitScalar(u8, tail[1..end], ',');
        while (parts.next()) |part| {
            const tool = std.mem.trim(u8, part, " \t\r\"'");
            if (tool.len != 0) try out.append(allocator, try allocator.dupe(u8, tool));
        }
    } else {
        const line_start = @intFromPtr(line.ptr) - @intFromPtr(block.ptr);
        var lines = std.mem.splitScalar(u8, block[line_start + line.len ..], '\n');
        while (lines.next()) |raw| {
            if (raw.len == 0) continue;
            if (!std.mem.startsWith(u8, raw, "      - ")) break;
            const tool = std.mem.trim(u8, raw[8..], " \t\r\"'");
            try out.append(allocator, try allocator.dupe(u8, tool));
        }
    }
    if (out.items.len == 0) return error.InvalidCircuitryGraph;
    return out.toOwnedSlice(allocator);
}

pub fn freeStringList(allocator: Allocator, list: []const []u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

pub fn wantsCircuitryPrompt(graph_text: []const u8, tools: []const []u8) bool {
    if (std.mem.indexOf(u8, graph_text, "circuitry-author") != null) return true;
    for (tools) |tool| {
        if (std.mem.startsWith(u8, tool, "circuitry_")) return true;
        if (std.mem.eql(u8, tool, "request_circuitry_run")) return true;
    }
    return false;
}

pub fn readScalar(allocator: Allocator, text: []const u8, key: []const u8) ![]u8 {
    const line = findLineStarting(text, key) orelse return error.InvalidCircuitryGraph;
    var value = std.mem.trim(u8, line[key.len..], " \t\r");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    return allocator.dupe(u8, value);
}

pub fn readUsize(text: []const u8, key: []const u8) !usize {
    const line = findLineStarting(text, key) orelse return error.InvalidCircuitryGraph;
    const value = std.mem.trim(u8, line[key.len..], " \t\r");
    return std.fmt.parseInt(usize, value, 10);
}

pub fn extractResourceInstructions(allocator: Allocator, text: []const u8, resource_id: []const u8) ![]u8 {
    const block = resourceBlock(text, resource_id) orelse return error.InvalidCircuitryGraph;
    return extractIndentedBlock(allocator, block, "    instructions: |\n", 6);
}

pub fn extractIndentedBlock(allocator: Allocator, text: []const u8, marker: []const u8, indent: usize) ![]u8 {
    const start = (std.mem.indexOf(u8, text, marker) orelse return error.InvalidCircuitryGraph) + marker.len;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text[start..], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            try out.append(allocator, '\n');
            continue;
        }
        const spaces = countLeadingSpaces(line);
        if (spaces < indent) break;
        try out.appendSlice(allocator, line[indent..]);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn readLinks(allocator: Allocator, graph_path: []const u8, text: []const u8, stack: []const []const u8) anyerror![][]u8 {
    const line = findLineStarting(text, "links:") orelse return allocator.alloc([]u8, 0);
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    const line_start = @intFromPtr(line.ptr) - @intFromPtr(text.ptr);
    var lines = std.mem.splitScalar(u8, text[line_start + line.len ..], '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        if (!std.mem.startsWith(u8, raw, "  - ")) break;
        const rel = std.mem.trim(u8, raw[4..], " \t\r\"'");
        if (rel.len == 0 or std.mem.indexOfScalar(u8, rel, ':') != null) return error.InvalidCircuitryGraph;
        const path = try joinRelative(allocator, graph_path, rel);
        defer allocator.free(path);
        const linked = try readLinkedTextStack(allocator, path, stack);
        try out.append(allocator, linked);
    }
    return out.toOwnedSlice(allocator);
}

fn absolutePath(allocator: Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    var buf: [4096]u8 = undefined;
    const rc = std.os.linux.getcwd(&buf, buf.len);
    const errno = std.os.linux.errno(rc);
    if (errno != .SUCCESS) return error.CurrentDirectoryUnavailable;
    var cwd = buf[0..rc];
    if (std.mem.indexOfScalar(u8, cwd, 0)) |zero| cwd = cwd[0..zero];
    return std.fs.path.join(allocator, &.{ cwd, path });
}

fn joinRelative(allocator: Allocator, from_file: []const u8, rel: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(rel)) return allocator.dupe(u8, rel);
    const dir = std.fs.path.dirname(from_file) orelse ".";
    return std.fs.path.join(allocator, &.{ dir, rel });
}

fn resourceBlock(text: []const u8, resource_id: []const u8) ?[]const u8 {
    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buf, "  {s}:\n", .{resource_id}) catch return null;
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    const body_start = start + marker.len;
    var cursor = body_start;
    while (cursor < text.len) {
        const line_start = cursor;
        const next = std.mem.indexOfScalarPos(u8, text, cursor, '\n') orelse text.len;
        const line = text[line_start..next];
        if (line.len >= 3 and std.mem.startsWith(u8, line, "  ") and line[2] != ' ') return text[start..line_start];
        cursor = if (next == text.len) text.len else next + 1;
    }
    return text[start..];
}

fn findLineStarting(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, key)) return line;
    }
    return null;
}

fn countLeadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

fn requireContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) return error.InvalidCircuitryGraph;
}

test "graph tool reader accepts block tools and rejects empty tools" {
    const source =
        \\  assistant:
        \\    type: agent
        \\    tools:
        \\      - read
        \\      - bash
    ;
    const tools = try readTools(std.testing.allocator, source, "assistant");
    defer freeStringList(std.testing.allocator, tools);
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try std.testing.expectEqualStrings("read", tools[0]);
    try std.testing.expectEqualStrings("bash", tools[1]);

    try std.testing.expectError(error.InvalidCircuitryGraph, readTools(std.testing.allocator, "    tools: []", "assistant"));
}
