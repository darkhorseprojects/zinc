const std = @import("std");
const files = @import("../sys/fs.zig");
const provider = @import("../runtime/provider.zig");
const runtime_tools = @import("../runtime/tools.zig");

const Allocator = std.mem.Allocator;

pub const Decision = enum { deny, ask, allow };

pub fn decide(policy: []const u8) !Decision {
    if (std.mem.eql(u8, policy, "deny")) return .deny;
    if (std.mem.eql(u8, policy, "ask")) return .ask;
    if (std.mem.eql(u8, policy, "allow-local") or std.mem.eql(u8, policy, "allow")) return .allow;
    return error.InvalidConfigValue;
}

pub fn denied(allocator: Allocator) !runtime_tools.ToolResult {
    return .{ .content = try jsonStatus(allocator, "denied", "graph runs are denied by runtime.graph_run_policy"), .is_error = false };
}

pub fn prompt(allocator: Allocator, call: provider.ToolCall) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, call.arguments, .{});
    defer parsed.deinit();
    const args = parsed.value.object;
    const graph = try runtime_tools.requireStringArg(args, "graph");
    const reason = try runtime_tools.requireStringArg(args, "reason");
    const entry = try runtime_tools.optionalStringArg(args, "entry") orelse "<default>";
    const risk = try runtime_tools.optionalStringArg(args, "risk") orelse "";
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.print(allocator, "\nZinc wants to run a Circuitry graph\n\ngraph: {s}\nentry: {s}\nreason: {s}\n", .{ graph, entry, reason });
    if (risk.len != 0) try text.print(allocator, "risk: {s}\n", .{risk});
    if (args.get("inputs")) |inputs| {
        try text.appendSlice(allocator, "inputs: ");
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &text);
        defer text = aw.toArrayList();
        try std.json.Stringify.value(inputs, .{}, &aw.writer);
        try aw.writer.writeByte('\n');
    }
    try text.appendSlice(allocator, "\nApprove? [y/N] ");
    _ = try files.linuxWrite(2, text.items);
    var buf: [16]u8 = undefined;
    const n = std.os.linux.read(0, &buf, buf.len);
    if (std.os.linux.errno(n) != .SUCCESS or n == 0) return false;
    const answer = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return answer.len != 0 and (answer[0] == 'y' or answer[0] == 'Y');
}

pub fn pending(allocator: Allocator, call: provider.ToolCall) !runtime_tools.ToolResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, call.arguments, .{});
    defer parsed.deinit();
    return runtime_tools.graphRunRequest(allocator, parsed.value.object);
}

pub fn resultJson(allocator: Allocator, graph_path: []const u8, entry: []const u8, output: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"status\":\"ok\",\"graph\":");
    try files.appendJsonString(allocator, &out, graph_path);
    try out.appendSlice(allocator, ",\"entry\":");
    try files.appendJsonString(allocator, &out, entry);
    try out.appendSlice(allocator, ",\"output\":");
    try files.appendJsonString(allocator, &out, output);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn jsonStatus(allocator: Allocator, status: []const u8, message: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"status\":");
    try files.appendJsonString(allocator, &out, status);
    try out.appendSlice(allocator, ",\"message\":");
    try files.appendJsonString(allocator, &out, message);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}
