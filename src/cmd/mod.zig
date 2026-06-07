const std = @import("std");
const files = @import("../io/fs.zig");
const graph_mod = @import("../graph/mod.zig");
const packages = @import("../pkg/mod.zig");

const Allocator = std.mem.Allocator;

pub const run = @import("run.zig");
pub const graph = @import("graph.zig");
pub const pkg = @import("pkg.zig");
pub const runtime = @import("runtime.zig");
pub const config = @import("config.zig");

pub fn fail(comptime fmt: []const u8, args: anytype) error{UserError}!void {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    return error.UserError;
}

pub fn usage() void {
    std.debug.print(
        \\zn - Zinc, a tiny Circuitry-native runtime
        \\
        \\usage:
        \\  zn check [graph]
        \\  zn clean [--local|--global] [--yes] [runtime | packages | generated | config | all]
        \\  zn doctor
        \\  zn config get <path>
        \\  zn compact [--dry-run] [--session id|--continue] [graph]
        \\  zn update [--ref version]
        \\  zn [--default] [--model id] [--session id|--continue] <prompt>
        \\  zn run [--default] [--model id] [graph|--graph id|path] [--export id] [--input name=value] [--text name=value|@file] [--file name=path] [--image name=path] [--session id|--continue] <prompt>
        \\  zn graph list
        \\  zn graph show <graph>
        \\  zn pkg list
        \\  zn pkg add [--local|--global] [--replace] [--yes] [--model id] <source>
        \\  zn pkg remove [--local|--global] [--yes] [--model id] <name>
        \\  zn pkg update [--local|--global] [--yes] <name|--all>
        \\  zn pkg show [--local|--global] <name>
        \\  zn pkg exec <package> <script>
        \\  zn pkg call <tool> <json-arguments>
        \\  zn db path|tables|schema|query <sql>
        \\  zn session list|show <id>|tree [id]|events <id>|branch --at <event-id> --name <name>|checkout <branch>
        \\  zn event tail|show <id>|payload <id>|logs <id>
        \\  zn logs tail|current|for-event <id>|for-run <id>
        \\
    , .{});
}

pub fn confirmOrFail(prompt: []const u8) !void {
    try files.writeAllErr(prompt);
    try files.writeAllErr(" [y/N] ");
    var buf: [16]u8 = undefined;
    const n = try files.readStdin(&buf);
    if (n == 0) return fail("confirmation required", .{});
    const answer = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (answer.len == 1 and (answer[0] == 'y' or answer[0] == 'Y')) return;
    if (answer.len == 1 and (answer[0] == 'n' or answer[0] == 'N')) return fail("cancelled", .{});
    return fail("answer y or n", .{});
}

pub fn scopeName(scope: packages.Scope) []const u8 {
    return switch (scope) {
        .local => "local",
        .global => "global",
    };
}

pub fn looksLikeGraphPath(arg: []const u8) bool {
    if (std.mem.indexOfAny(u8, arg, " \t\r\n") != null) return false;
    if (!std.mem.endsWith(u8, arg, ".circuitry.yaml") and !std.mem.endsWith(u8, arg, ".circuitry.yml") and !std.mem.endsWith(u8, arg, ".yaml") and !std.mem.endsWith(u8, arg, ".yml")) return false;
    files.exists(arg) catch return false;
    return true;
}

pub fn validateGraphFile(allocator: Allocator, io: std.Io, path: []const u8) !void {
    const loaded_graph = try graph_mod.load(allocator, io, path);
    defer loaded_graph.deinit(allocator);
    try graph_mod.validate(loaded_graph);
}

pub fn printGraph(allocator: Allocator, spec: []const u8, path: []const u8, loaded: graph_mod.Graph) !void {
    std.debug.print("graph: {s}\npath: {s}\n\n", .{ spec, path });
    const text = try graph_mod.inspectText(allocator, loaded);
    defer allocator.free(text);
    std.debug.print("{s}", .{text});
}

pub fn joinTemp(allocator: Allocator, items: []const []u8) ![]u8 {
    return std.mem.join(allocator, ",", items);
}

pub fn valueSummary(value: std.json.Value) []const u8 {
    return switch (value) {
        .string => |text| if (text.len > 40) text[0..40] else text,
        else => "<literal>",
    };
}

pub fn jsonText(allocator: Allocator, value: std.json.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    try std.json.Stringify.value(value, .{}, &aw.writer);
    out = aw.toArrayList();
    return out.toOwnedSlice(allocator);
}

pub fn objectAt(value: std.json.Value, path: []const []const u8) ?std.json.ObjectMap {
    const found = valueAt(value, path) orelse return null;
    return if (found == .object) found.object else null;
}

pub fn scalarAt(value: std.json.Value, path: []const []const u8) ?[]const u8 {
    const found = valueAt(value, path) orelse return null;
    return if (found == .string) found.string else null;
}

pub fn valueAt(value: std.json.Value, path: []const []const u8) ?std.json.Value {
    var current = value;
    for (path) |part| {
        if (current != .object) return null;
        current = current.object.get(part) orelse return null;
    }
    return current;
}
