const std = @import("std");
const serde = @import("serde");
const circuitry = @import("circuitry");

const Allocator = std.mem.Allocator;

pub const LocalOutput = struct { name: []const u8, value: []const u8 };

pub fn selectFields(allocator: Allocator, requested: []const circuitry.Binding, stdout: []const u8) ![]LocalOutput {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = try serde.yaml.parse(arena.allocator(), stdout);

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
        const value = valueField(&root, local) orelse return error.InvalidPackageOutput;
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

pub fn shapeTextResult(allocator: Allocator, state: anytype, outputs: []const circuitry.Variable) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (outputs) |give| {
        const value = state.get(give.name) orelse return error.MissingStepOutput;
        try out.print(allocator, "{s}: |\n", .{give.name});
        try appendIndented(allocator, &out, value);
    }
    return out.toOwnedSlice(allocator);
}

pub fn eventsYaml(allocator: Allocator, events: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "events:\n");
    for (events) |event| try out.print(allocator, "  - {s}\n", .{event});
    return out.toOwnedSlice(allocator);
}

pub fn outputsYaml(allocator: Allocator, outputs: []const circuitry.Binding, local: []const LocalOutput) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (outputs) |give| {
        const name = bare(give.local);
        for (local) |item| {
            if (std.mem.eql(u8, item.name, name)) {
                try out.print(allocator, "{s}: |\n", .{name});
                try appendIndented(allocator, &out, item.value);
                break;
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn entryKey(allocator: Allocator, entry: circuitry.Entry) ![]const u8 { return try allocator.dupe(u8, entry.path); }

pub fn appendIndented(allocator: Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    var it = std.mem.splitScalar(u8, value, '\n');
    while (it.next()) |line| try out.print(allocator, "    {s}\n", .{line});
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
    return switch (value.*) { .string => |s| s, else => null };
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

fn bare(name: []const u8) []const u8 { return if (name.len > 0 and name[0] == '$') name[1..] else name; }

fn valueField(node: *const serde.yaml.Value, key: []const u8) ?*const serde.yaml.Value {
    if (node.* != .mapping) return null;
    var it = node.mapping.iterator();
    while (it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, key)) return entry.value_ptr;
    return null;
}
