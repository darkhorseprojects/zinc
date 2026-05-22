const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn validateText(text: []const u8) !void {
    try requireContains(text, "circuitry: \"0.2\"");
    try requireContains(text, "resources:");
    try requireContains(text, "  user_turn:");
    try requireContains(text, "    type: text");
    try requireContains(text, "  session_projection:");
    try requireContains(text, "  assistant:");
    try requireContains(text, "    type: agent");
    try requireContains(text, "    inputs: [user_turn, session_projection]");
    try requireContains(text, "    tools:");
    try requireContains(text, "    expect:");
    try requireContains(text, "      response: str");
    try requireContains(text, "      done: bool");
    try requireContains(text, "    instructions: |");
}

pub fn readTools(allocator: Allocator, graph_text: []const u8) ![][]u8 {
    const line = findLineStarting(graph_text, "    tools:") orelse return error.InvalidCircuitryGraph;
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
        const line_start = @intFromPtr(line.ptr) - @intFromPtr(graph_text.ptr);
        var lines = std.mem.splitScalar(u8, graph_text[line_start + line.len ..], '\n');
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
        \\    tools:
        \\      - read
        \\      - bash
    ;
    const tools = try readTools(std.testing.allocator, source);
    defer freeStringList(std.testing.allocator, tools);
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try std.testing.expectEqualStrings("read", tools[0]);
    try std.testing.expectEqualStrings("bash", tools[1]);

    try std.testing.expectError(error.InvalidCircuitryGraph, readTools(std.testing.allocator, "    tools: []"));
}
