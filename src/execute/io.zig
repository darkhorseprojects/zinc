const std = @import("std");
const serde = @import("serde");
const circuitry = @import("circuitry");
const package = @import("../package.zig");

const Allocator = std.mem.Allocator;

pub const LocalOutput = struct { name: []const u8, value: []const u8 };

pub fn interpretOutput(allocator: Allocator, gives: package.Gives, requested: []const circuitry.VariableRef, stdout: []const u8) ![]LocalOutput {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const root = try serde.yaml.parse(aa, stdout);

    var out = std.ArrayList(LocalOutput).empty;
    errdefer {
        for (out.items) |item| {
            allocator.free(item.name);
            allocator.free(item.value);
        }
        out.deinit(allocator);
    }

    for (requested) |request| {
        const local = bare(request.local);
        const selector = switch (gives) {
            .dynamic => |root_path| try childPath(aa, root_path, local),
            .mapping => |mappings| findMapping(mappings, local) orelse return error.InvalidPackageOutput,
        };
        const value = try selectPath(aa, &root, selector);
        try out.append(allocator, .{ .name = try allocator.dupe(u8, local), .value = try yamlScalarText(allocator, value) });
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeLocal(local: []LocalOutput, allocator: Allocator) void {
    for (local) |item| {
        allocator.free(item.name);
        allocator.free(item.value);
    }
    allocator.free(local);
}

pub fn shapeTextResult(allocator: Allocator, state: anytype, gives: []const circuitry.Variable) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (gives) |give| {
        const value = state.get(give.name) orelse return error.MissingUseOutput;
        try out.print(allocator, "{s}: |\n", .{give.name});
        try appendIndented(allocator, &out, value);
    }
    return out.toOwnedSlice(allocator);
}

pub fn lineageYaml(allocator: Allocator, nodes: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "lineage:\n");
    for (nodes) |node| try out.print(allocator, "  - {s}\n", .{node});
    return out.toOwnedSlice(allocator);
}

pub fn shapeKey(allocator: Allocator, use: circuitry.Use) ![]const u8 {
    const joined = try joinInstructions(allocator, use.does) orelse "";
    return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ use.name, joined });
}

fn joinInstructions(allocator: Allocator, lines: [][]const u8) !?[]const u8 {
    if (lines.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (lines, 0..) |line, i| {
        if (i != 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, line);
    }
    const text = try out.toOwnedSlice(allocator);
    return text;
}

pub fn appendIndentedLines(allocator: Allocator, out: *std.ArrayList(u8), lines: [][]const u8) !void {
    for (lines, 0..) |line, i| {
        if (i != 0) try out.append(allocator, '\n');
        try appendIndented(allocator, out, line);
    }
}

pub fn appendIndented(allocator: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    var it = std.mem.splitScalar(u8, value, '\n');
    while (it.next()) |line| try out.print(allocator, "    {s}\n", .{line});
}

pub fn appendYamlEntry(allocator: Allocator, out: *std.ArrayList(u8), key: []const u8, value: *const serde.yaml.Value) !void {
    try out.print(allocator, "  {s}: ", .{key});
    try appendYamlInline(allocator, out, value);
    try out.appendSlice(allocator, "\n");
}

pub fn appendYamlInline(allocator: Allocator, out: *std.ArrayList(u8), value: *const serde.yaml.Value) !void {
    switch (value.*) {
        .string => |s| {
            const escaped = try escapeYamlString(allocator, s);
            defer allocator.free(escaped);
            try out.print(allocator, "\"{s}\"", .{escaped});
        },
        .integer => |i| try out.print(allocator, "{d}", .{i}),
        .float => |f| try out.print(allocator, "{d}", .{f}),
        .boolean => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .sequence => |items| {
            try out.appendSlice(allocator, "[");
            for (items, 0..) |item, i| {
                if (i != 0) try out.appendSlice(allocator, ", ");
                try appendYamlInline(allocator, out, &item);
            }
            try out.appendSlice(allocator, "]");
        },
        .mapping => |*entries| {
            try out.appendSlice(allocator, "{");
            var first = true;
            var it = entries.iterator();
            while (it.next()) |entry| {
                if (!first) try out.appendSlice(allocator, ", ");
                first = false;
                try out.print(allocator, "{s}: ", .{entry.key_ptr.*});
                try appendYamlInline(allocator, out, entry.value_ptr);
            }
            try out.appendSlice(allocator, "}");
        },
        else => try out.appendSlice(allocator, "..."),
    }
}

pub fn scalarText(value: *const serde.yaml.Value) ?[]const u8 {
    return switch (value.*) {
        .string => |s| s,
        .integer => unreachable,
        .float => unreachable,
        .boolean => unreachable,
        else => null,
    };
}

pub fn yamlScalarText(allocator: Allocator, value: *const serde.yaml.Value) ![]u8 {
    return switch (value.*) {
        .string => try allocator.dupe(u8, value.string),
        .integer => try std.fmt.allocPrint(allocator, "{d}", .{value.integer}),
        .float => try std.fmt.allocPrint(allocator, "{d}", .{value.float}),
        .boolean => try allocator.dupe(u8, if (value.boolean) "true" else "false"),
        else => error.InvalidPackageOutput,
    };
}

fn escapeYamlString(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |ch| switch (ch) {
        '\'' => try out.appendSlice(allocator, "\\'"),
        '"' => try out.appendSlice(allocator, "\\\""),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => try out.append(allocator, ch),
    };
    return out.toOwnedSlice(allocator);
}

pub fn selectPathText(allocator: Allocator, context: []const u8, path: [][]const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = try serde.yaml.parse(arena.allocator(), context);
    const value = try selectPath(arena.allocator(), &root, path);
    return try yamlScalarText(allocator, value);
}

fn findMapping(mappings: []const package.OutputMapping, local: []const u8) ?[][]const u8 {
    for (mappings) |mapping| if (std.mem.eql(u8, mapping.local, local)) return mapping.selector;
    return null;
}

fn childPath(allocator: Allocator, root: [][]const u8, child: []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, root.len + 1);
    @memcpy(out[0..root.len], root);
    out[root.len] = child;
    return out;
}

fn bare(name: []const u8) []const u8 {
    return if (name.len > 0 and name[0] == '$') name[1..] else name;
}

fn selectPath(allocator: Allocator, root: *const serde.yaml.Value, path: [][]const u8) !*const serde.yaml.Value {
    _ = allocator;
    var current = root;
    for (path) |segment| {
        if (current.* != .mapping) return error.InvalidContextSelection;
        current = valueField(current, segment) orelse return error.InvalidContextSelection;
    }
    return current;
}

fn valueField(node: *const serde.yaml.Value, key: []const u8) ?*const serde.yaml.Value {
    if (node.* != .mapping) return null;
    var it = node.mapping.iterator();
    while (it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, key)) return entry.value_ptr;
    return null;
}
