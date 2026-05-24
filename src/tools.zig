const std = @import("std");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;

pub fn execute(allocator: Allocator, io: std.Io, name: []const u8, arg_text: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, arg_text, .{}) catch |err| return switch (err) {
        error.OutOfMemory => err,
        else => error.InvalidToolArguments,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolArguments;
    const args = parsed.value.object;
    if (std.mem.eql(u8, name, "read")) {
        const path = try requireStringArg(args, "path");
        return files.readLimited(allocator, path, 1024 * 1024);
    }
    if (std.mem.eql(u8, name, "write")) {
        const path = try requireStringArg(args, "path");
        const content = try requireStringArg(args, "content");
        try files.write(path, content);
        return std.fmt.allocPrint(allocator, "wrote {s}", .{path});
    }
    if (std.mem.eql(u8, name, "edit")) {
        const path = try requireStringArg(args, "path");
        const old = try requireStringArg(args, "oldText");
        const new = try requireStringArg(args, "newText");
        try files.edit(allocator, path, old, new);
        return std.fmt.allocPrint(allocator, "edited {s}", .{path});
    }
    if (std.mem.eql(u8, name, "bash")) return runBash(allocator, io, try requireStringArg(args, "command"));
    if (std.mem.eql(u8, name, "request_circuitry_run")) return requestCircuitryRun(allocator, args);
    return error.UnknownTool;
}

pub fn validateArguments(allocator: Allocator, name: []const u8, arg_text: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, arg_text, .{}) catch |err| return switch (err) {
        error.OutOfMemory => err,
        else => error.InvalidToolArguments,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolArguments;
    const args = parsed.value.object;
    if (std.mem.eql(u8, name, "read")) {
        _ = try requireStringArg(args, "path");
        return;
    }
    if (std.mem.eql(u8, name, "write")) {
        _ = try requireStringArg(args, "path");
        _ = try requireStringArg(args, "content");
        return;
    }
    if (std.mem.eql(u8, name, "edit")) {
        _ = try requireStringArg(args, "path");
        _ = try requireStringArg(args, "oldText");
        _ = try requireStringArg(args, "newText");
        return;
    }
    if (std.mem.eql(u8, name, "bash")) {
        _ = try requireStringArg(args, "command");
        return;
    }
    if (std.mem.eql(u8, name, "request_circuitry_run")) {
        _ = try requireStringArg(args, "graph");
        _ = try requireStringArg(args, "reason");
        _ = try requireStringArg(args, "expected_result");
        _ = try requireStringArg(args, "risk");
        return;
    }
    return error.UnknownTool;
}

pub fn requireStringArg(args: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = args.get(name) orelse return error.InvalidToolArguments;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

fn requestCircuitryRun(allocator: Allocator, args: std.json.ObjectMap) ![]u8 {
    const graph = try requireStringArg(args, "graph");
    const reason = try requireStringArg(args, "reason");
    const expected = try requireStringArg(args, "expected_result");
    const risk = try requireStringArg(args, "risk");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"status\":\"pending_approval\",\"message\":");
    const message = try std.fmt.allocPrint(allocator, "Circuitry graph execution requires root/user approval. Run `zn {s}` or `zn run {s}` from the root-facing Zinc invocation if approved.", .{ graph, graph });
    defer allocator.free(message);
    try files.appendJsonString(allocator, &out, message);
    try out.appendSlice(allocator, ",\"graph\":");
    try files.appendJsonString(allocator, &out, graph);
    try out.appendSlice(allocator, ",\"reason\":");
    try files.appendJsonString(allocator, &out, reason);
    try out.appendSlice(allocator, ",\"expected_result\":");
    try files.appendJsonString(allocator, &out, expected);
    try out.appendSlice(allocator, ",\"risk\":");
    try files.appendJsonString(allocator, &out, risk);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn runBash(allocator: Allocator, io: std.Io, command: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "sh", "-lc", command } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    return std.fmt.allocPrint(allocator, "exit={d}\nstdout:\n{s}\nstderr:\n{s}", .{ code, result.stdout, result.stderr });
}

test "tool arguments require declared string fields" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"path\":\"src/main.zig\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("src/main.zig", try requireStringArg(parsed.value.object, "path"));
    try std.testing.expectError(error.InvalidToolArguments, requireStringArg(parsed.value.object, "missing"));
}

test "invalid tool json maps to tool argument error" {
    try std.testing.expectError(error.InvalidToolArguments, validateArguments(std.testing.allocator, "bash", "{\"command\":\"unterminated"));
}
