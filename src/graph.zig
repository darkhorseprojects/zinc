const std = @import("std");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;

const Import = struct {
    path: []u8,
    resource: []u8,
    alias: []u8,

    fn deinit(self: Import, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.resource);
        allocator.free(self.alias);
    }

    fn localName(self: Import) []const u8 {
        return if (self.alias.len == 0) self.resource else self.alias;
    }
};

pub fn validateText(text: []const u8) !void {
    try requireContains(text, "circuitry: \"0.3\"");
    try requireContains(text, "resources:");
}

pub fn readLinkedText(allocator: Allocator, graph_path: []const u8) ![]u8 {
    var stack: std.ArrayList([]u8) = .empty;
    defer {
        for (stack.items) |item| allocator.free(item);
        stack.deinit(allocator);
    }
    return readLinkedTextStack(allocator, graph_path, &stack);
}

fn readLinkedTextStack(allocator: Allocator, graph_path: []const u8, stack: *std.ArrayList([]u8)) anyerror![]u8 {
    const canonical = try absolutePath(allocator, graph_path);
    errdefer allocator.free(canonical);
    for (stack.items) |ancestor| if (std.mem.eql(u8, ancestor, canonical)) return error.CircuitryGraphImportCycle;
    try stack.append(allocator, canonical);
    defer allocator.free(stack.pop().?);

    const text = try files.readLimited(allocator, canonical, 1024 * 1024);
    defer allocator.free(text);

    const imports = try readImports(allocator, canonical, text);
    defer freeImports(allocator, imports);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (imports) |import| {
        const imported = try expandImport(allocator, import, imports, stack);
        defer allocator.free(imported);
        try out.appendSlice(allocator, imported);
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, text);
    return out.toOwnedSlice(allocator);
}

fn readImports(allocator: Allocator, graph_path: []const u8, text: []const u8) ![]Import {
    const imports_line = findLineStarting(text, "imports:") orelse return allocator.alloc(Import, 0);
    const start = @intFromPtr(imports_line.ptr) - @intFromPtr(text.ptr) + imports_line.len;
    var lines = std.mem.splitScalar(u8, text[start..], '\n');
    var imports: std.ArrayList(Import) = .empty;
    errdefer {
        for (imports.items) |import| import.deinit(allocator);
        imports.deinit(allocator);
    }

    var current: std.ArrayList([]const u8) = .empty;
    defer current.deinit(allocator);
    while (lines.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "- ")) {
            if (current.items.len != 0) {
                try imports.append(allocator, try parseImport(allocator, graph_path, current.items));
                current.clearRetainingCapacity();
            }
            try current.append(allocator, trimmed[2..]);
            continue;
        }
        if (current.items.len != 0 and std.mem.startsWith(u8, raw, "    ")) {
            try current.append(allocator, trimmed);
            continue;
        }
        break;
    }
    if (current.items.len != 0) try imports.append(allocator, try parseImport(allocator, graph_path, current.items));
    return imports.toOwnedSlice(allocator);
}

fn parseImport(allocator: Allocator, graph_path: []const u8, lines: []const []const u8) !Import {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    for (lines, 0..) |line, i| {
        if (i != 0) try joined.append(allocator, ' ');
        try joined.appendSlice(allocator, line);
    }

    const rel_path = parseImportField(joined.items, "path:") orelse return error.InvalidCircuitryGraph;
    const resource = parseImportField(joined.items, "resource:") orelse return error.InvalidCircuitryGraph;
    const alias = parseImportField(joined.items, "as:") orelse "";
    const path = try joinRelative(allocator, graph_path, rel_path);
    errdefer allocator.free(path);
    const resource_name = try allocator.dupe(u8, resource);
    errdefer allocator.free(resource_name);
    const alias_name = try allocator.dupe(u8, alias);
    return .{ .path = path, .resource = resource_name, .alias = alias_name };
}

fn parseImportField(text: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, key) orelse return null;
    var rest = std.mem.trim(u8, text[start + key.len ..], " \t\r");
    if (rest.len == 0) return null;
    if (rest[0] == '"' or rest[0] == '\'') {
        const quote = rest[0];
        rest = rest[1..];
        const end = std.mem.indexOfScalar(u8, rest, quote) orelse return null;
        return rest[0..end];
    }
    const end = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse rest.len;
    return rest[0..end];
}

fn expandImport(allocator: Allocator, import: Import, siblings: []const Import, stack: *std.ArrayList([]u8)) ![]u8 {
    const text = try readLinkedTextStack(allocator, import.path, stack);
    defer allocator.free(text);
    const block = resourceBlock(text, import.resource) orelse return error.ImportedResourceNotFound;
    const body = block[(std.mem.indexOfScalar(u8, block, '\n') orelse return error.InvalidCircuitryGraph) + 1 ..];
    const rewritten = try rewriteImportedResource(allocator, body, import, siblings);
    defer allocator.free(rewritten);
    return std.fmt.allocPrint(allocator, "  {s}:\n{s}", .{ import.localName(), rewritten });
}

fn rewriteImportedResource(allocator: Allocator, body: []const u8, import: Import, siblings: []const Import) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "inputs: [")) {
            try writeRewrittenInputs(allocator, &out, line, import, siblings);
        } else {
            try out.print(allocator, "{s}\n", .{line});
        }
    }
    return out.toOwnedSlice(allocator);
}

fn writeRewrittenInputs(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8, source: Import, imports: []const Import) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    const close = std.mem.lastIndexOfScalar(u8, trimmed, ']') orelse return error.InvalidCircuitryGraph;
    const indent_len = countLeadingSpaces(line);
    try out.appendSlice(allocator, line[0..indent_len]);
    try out.appendSlice(allocator, "inputs: [");
    var parts = std.mem.splitScalar(u8, trimmed["inputs: [".len..close], ',');
    var first = true;
    while (parts.next()) |part| {
        const input = std.mem.trim(u8, part, " \t\r\"'");
        if (input.len == 0) continue;
        if (!first) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, aliasFor(source, imports, input));
        first = false;
    }
    try out.appendSlice(allocator, "]\n");
}

fn aliasFor(source: Import, imports: []const Import, input: []const u8) []const u8 {
    for (imports) |import| {
        if (std.mem.eql(u8, import.path, source.path) and std.mem.eql(u8, import.resource, input)) return import.localName();
    }
    return input;
}

fn freeImports(allocator: Allocator, imports: []const Import) void {
    for (imports) |import| import.deinit(allocator);
    allocator.free(imports);
}

pub fn findResourceByIdentity(text: []const u8, identity: []const u8) ?[]const u8 {
    var current: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (resourceNameFromLine(line)) |name| {
            current = name;
            continue;
        }
        if (current) |name| {
            if (identityFromLine(line)) |found| {
                if (std.mem.eql(u8, found, identity)) return name;
            }
        }
    }
    return null;
}

fn resourceNameFromLine(line: []const u8) ?[]const u8 {
    if (line.len < 4 or !std.mem.startsWith(u8, line, "  ") or line[2] == ' ') return null;
    if (line[line.len - 1] != ':') return null;
    return line[2 .. line.len - 1];
}

fn identityFromLine(line: []const u8) ?[]const u8 {
    const prefix = "    identity:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var value = std.mem.trim(u8, line[prefix.len..], " \t\r");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    return value;
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
    _ = tools;
    return std.mem.indexOf(u8, graph_text, "circuitry-author") != null;
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

test "graph imports rewrite sibling aliases in inputs" {
    const text = try readLinkedText(std.testing.allocator, "graphs/zinc-loop.circuitry.yaml");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "  raw_session_log:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  ctx_recovery:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    inputs: [raw_session_log]\n") != null);
}
