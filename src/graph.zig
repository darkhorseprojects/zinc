const std = @import("std");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;

pub const PromptPack = struct {
    id: []u8,
    title: []u8,
    description: []u8,
    content: []u8,

    pub fn deinit(self: PromptPack, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.content);
    }
};

pub fn validateText(text: []const u8) !void {
    try requireContains(text, "circuitry: \"0.2.99\"");
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

    const links = try readLinks(allocator, canonical, text);
    defer freeStringList(allocator, links);
    if (links.len == 0) return allocator.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, textBeforeResources(text));
    try out.appendSlice(allocator, "resources:\n");
    for (links) |link| {
        const linked = try readLinkedTextStack(allocator, link, stack);
        defer allocator.free(linked);
        try out.appendSlice(allocator, resourcesBody(linked) orelse return error.InvalidCircuitryGraph);
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, resourcesBody(text) orelse return error.InvalidCircuitryGraph);
    return out.toOwnedSlice(allocator);
}

fn readLinks(allocator: Allocator, graph_path: []const u8, text: []const u8) ![][]u8 {
    const links_line = findLineStarting(text, "links:") orelse return allocator.alloc([]u8, 0);
    const start = @intFromPtr(links_line.ptr) - @intFromPtr(text.ptr) + links_line.len;
    var links: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, links.items);
    var lines = std.mem.splitScalar(u8, text[start..], '\n');
    while (lines.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        if (!std.mem.startsWith(u8, trimmed, "- ")) break;
        const rel = parseLinkPath(trimmed[2..]) orelse return error.InvalidCircuitryGraph;
        try links.append(allocator, try joinRelative(allocator, graph_path, rel));
    }
    return links.toOwnedSlice(allocator);
}

fn parseLinkPath(text: []const u8) ?[]const u8 {
    var rest = std.mem.trim(u8, text, " \t\r");
    if (std.mem.startsWith(u8, rest, "path:")) rest = std.mem.trim(u8, rest["path:".len..], " \t\r");
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

fn textBeforeResources(text: []const u8) []const u8 {
    const resources = findLineStarting(text, "resources:") orelse return text;
    return text[0 .. @intFromPtr(resources.ptr) - @intFromPtr(text.ptr)];
}

fn resourcesBody(text: []const u8) ?[]const u8 {
    const resources = findLineStarting(text, "resources:") orelse return null;
    const start = @intFromPtr(resources.ptr) - @intFromPtr(text.ptr) + resources.len;
    return text[start..];
}

pub fn readPromptPacks(allocator: Allocator, text: []const u8) ![]PromptPack {
    var packs: std.ArrayList(PromptPack) = .empty;
    errdefer {
        for (packs.items) |pack| pack.deinit(allocator);
        packs.deinit(allocator);
    }

    var cursor: usize = 0;
    while (cursor < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, cursor, '\n') orelse text.len;
        const line = text[cursor..line_end];
        if (resourceNameFromLine(line)) |name| {
            if (resourceBlock(text[cursor..], name)) |relative_block| {
                const block = relative_block;
                if (blockResourceType(block)) |typ| {
                    if (std.mem.eql(u8, typ, "text")) {
                        if (extractTextValue(allocator, block)) |content| {
                            errdefer allocator.free(content);
                            if (parsePromptPack(allocator, block, content)) |pack| {
                                try packs.append(allocator, pack);
                            } else |_| {}
                        } else |_| {}
                    }
                }
            }
        }
        cursor = if (line_end == text.len) text.len else line_end + 1;
    }
    return packs.toOwnedSlice(allocator);
}

fn parsePromptPack(allocator: Allocator, block: []const u8, content: []u8) !PromptPack {
    if (!std.mem.startsWith(u8, std.mem.trim(u8, content, " \t\r\n"), "---\n")) return error.NotPromptPack;
    const trimmed_left = std.mem.trim(u8, content, " \t\r\n");
    const rest = trimmed_left[4..];
    const end = std.mem.indexOf(u8, rest, "\n---") orelse return error.NotPromptPack;
    const frontmatter = rest[0..end];
    const id_raw = frontmatterValue(frontmatter, "id") orelse return error.NotPromptPack;
    const desc_raw = frontmatterValue(frontmatter, "description") orelse "";
    const title_raw = frontmatterValue(frontmatter, "title") orelse labelValue(block) orelse id_raw;
    return .{
        .id = try allocator.dupe(u8, id_raw),
        .title = try allocator.dupe(u8, title_raw),
        .description = try allocator.dupe(u8, desc_raw),
        .content = content,
    };
}

fn frontmatterValue(frontmatter: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const lhs = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.mem.eql(u8, lhs, key)) continue;
        var rhs = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (rhs.len >= 2 and ((rhs[0] == '"' and rhs[rhs.len - 1] == '"') or (rhs[0] == '\'' and rhs[rhs.len - 1] == '\''))) rhs = rhs[1 .. rhs.len - 1];
        return rhs;
    }
    return null;
}

fn labelValue(block: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "label:")) continue;
        var value = std.mem.trim(u8, trimmed["label:".len..], " \t\r");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        return value;
    }
    return null;
}

fn extractTextValue(allocator: Allocator, block: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, block, "    value: |\n") != null) return extractIndentedBlock(allocator, block, "    value: |\n", 6);
    const line = findLineStarting(block, "    value:") orelse return error.InvalidCircuitryGraph;
    var value = std.mem.trim(u8, line["    value:".len..], " \t\r");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    return allocator.dupe(u8, value);
}

fn blockResourceType(block: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "type:")) continue;
        var value = std.mem.trim(u8, trimmed["type:".len..], " \t\r");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        return value;
    }
    return null;
}

pub fn freePromptPacks(allocator: Allocator, packs: []const PromptPack) void {
    for (packs) |pack| pack.deinit(allocator);
    allocator.free(packs);
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

pub fn findAgentWithTools(text: []const u8) ?[]const u8 {
    var current: ?[]const u8 = null;
    var in_agent = false;
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (resourceNameFromLine(line)) |name| {
            current = name;
            in_agent = false;
            continue;
        }
        if (current == null) continue;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "type: agent")) in_agent = true;
        if (in_agent and std.mem.startsWith(u8, trimmed, "tools:")) found = current.?;
    }
    return found;
}

pub fn findFirstAgentInput(allocator: Allocator, graph_text: []const u8, resource_id: []const u8) !?[]u8 {
    const inputs = try readInputs(allocator, graph_text, resource_id);
    defer freeStringList(allocator, inputs);
    for (inputs) |input| {
        if (resourceType(graph_text, input)) |typ| {
            if (std.mem.eql(u8, typ, "agent")) return try allocator.dupe(u8, input);
        }
    }
    return null;
}

pub fn findSingleAgent(text: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var current: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (resourceNameFromLine(line)) |name| {
            current = name;
            continue;
        }
        if (current) |name| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.eql(u8, trimmed, "type: agent")) {
                if (found != null) return null;
                found = name;
            }
        }
    }
    return found;
}

pub fn resourceIdentity(allocator: Allocator, text: []const u8, resource_id: []const u8) ![]u8 {
    const block = resourceBlock(text, resource_id) orelse return error.InvalidCircuitryGraph;
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        if (identityFromLine(line)) |identity| return allocator.dupe(u8, identity);
    }
    return allocator.dupe(u8, resource_id);
}

fn resourceType(text: []const u8, resource_id: []const u8) ?[]const u8 {
    const block = resourceBlock(text, resource_id) orelse return null;
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "type:")) continue;
        var value = std.mem.trim(u8, trimmed["type:".len..], " \t\r");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        return value;
    }
    return null;
}

pub fn readInputs(allocator: Allocator, graph_text: []const u8, resource_id: []const u8) ![][]u8 {
    const block = resourceBlock(graph_text, resource_id) orelse return error.InvalidCircuitryGraph;
    const line = findLineStarting(block, "    inputs:") orelse return allocator.alloc([]u8, 0);
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    const tail = std.mem.trim(u8, line["    inputs:".len..], " \t\r");
    if (!std.mem.startsWith(u8, tail, "[")) return error.InvalidCircuitryGraph;
    const end = std.mem.lastIndexOfScalar(u8, tail, ']') orelse return error.InvalidCircuitryGraph;
    var parts = std.mem.splitScalar(u8, tail[1..end], ',');
    while (parts.next()) |part| {
        const input = std.mem.trim(u8, part, " \t\r\"'");
        if (input.len != 0) try out.append(allocator, try allocator.dupe(u8, input));
    }
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

test "graph links merge resources" {
    const text = try readLinkedText(std.testing.allocator, "graphs/zinc-loop.circuitry.yaml");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "  assembled_context:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "  focused_recovery:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    inputs: [assembled_context, user_turn]\n") != null);
}
