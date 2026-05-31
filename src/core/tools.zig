const std = @import("std");
const ctxmod = @import("context.zig");
const files = @import("../sys/fs.zig");
const process = @import("../sys/process.zig");
const provider = @import("../runtime/provider.zig");
const runtime_tools = @import("../runtime/tools.zig");
const sessions = @import("../runtime/session.zig");
const uri = @import("../runtime/uri.zig");
const agent = @import("agent.zig");

const Allocator = std.mem.Allocator;

pub fn execute(ctx: *ctxmod.RunContext, read_ctx: uri.Context, spec: agent.Spec, call: provider.ToolCall) !runtime_tools.ToolResult {
    if (!hasTool(spec.tools, call.name)) {
        const message = try std.fmt.allocPrint(ctx.allocator, "tool `{s}` was requested but not declared by the active graph resource", .{call.name});
        defer ctx.allocator.free(message);
        return toolError(ctx.allocator, call, "ToolNotDeclared", message);
    }
    runtime_tools.validateArguments(ctx.allocator, call.name, call.arguments) catch |err| return switch (err) {
        error.OutOfMemory => err,
        else => toolError(ctx.allocator, call, @errorName(err), "tool arguments did not match the required JSON schema"),
    };
    if (spec.runtime_reads and std.mem.eql(u8, call.name, "read")) return executeRead(ctx, read_ctx, call) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => toolError(ctx.allocator, call, @errorName(err), "read failed"),
    };
    if (std.mem.eql(u8, call.name, "bash")) return executeBash(ctx, call) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => toolError(ctx.allocator, call, @errorName(err), "bash execution failed"),
    };
    if (std.mem.eql(u8, call.name, "write") or std.mem.eql(u8, call.name, "edit")) {
        if (try staleWriteError(ctx, call)) |err_result| return err_result;
        return executeWriteEdit(ctx, call) catch |err| switch (err) {
            error.OutOfMemory => err,
            else => toolError(ctx.allocator, call, @errorName(err), "file mutation failed"),
        };
    }
    return error.ToolNotHandled;
}

pub fn toolError(allocator: Allocator, call: provider.ToolCall, name: []const u8, message: []const u8) !runtime_tools.ToolResult {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":false,\"tool\":");
    try files.appendJsonString(allocator, &out, call.name);
    try out.appendSlice(allocator, ",\"error\":");
    try files.appendJsonString(allocator, &out, name);
    try out.appendSlice(allocator, ",\"message\":");
    try files.appendJsonString(allocator, &out, message);
    try out.appendSlice(allocator, ",\"arguments\":");
    try files.appendJsonString(allocator, &out, call.arguments);
    try out.append(allocator, '}');
    return .{ .content = try out.toOwnedSlice(allocator), .is_error = true };
}

fn executeRead(ctx: *ctxmod.RunContext, read_ctx: uri.Context, call: provider.ToolCall) !runtime_tools.ToolResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, call.arguments, .{});
    defer parsed.deinit();
    const path = try runtime_tools.requireStringArg(parsed.value.object, "path");
    if (try uri.resolve(ctx.allocator, ctx.io, read_ctx, path)) |content| return .{ .content = content, .is_error = false };
    if (looksLikeRuntimeUri(path)) {
        const message = try std.fmt.allocPrint(ctx.allocator, "unsupported Zinc URI: {s}", .{path});
        defer ctx.allocator.free(message);
        return toolError(ctx.allocator, call, "UnsupportedZincUri", message);
    }
    if (std.mem.indexOf(u8, path, ":bytes=")) |byte_pos| {
        const base_path = path[0..byte_pos];
        const range = path[byte_pos + ":bytes=".len ..];
        const content = try files.readLimited(ctx.allocator, base_path, ctx.profile.runtime.file_range_read_max_bytes);
        defer ctx.allocator.free(content);
        const bounds = try parseByteRange(range);
        const start = @min(bounds.start, content.len);
        const end = if (bounds.end) |e| @min(e, content.len) else content.len;
        if (start > end) return error.InvalidByteRange;
        return .{ .content = try ctx.allocator.dupe(u8, content[start..end]), .is_error = false };
    }
    return .{ .content = try files.readLimited(ctx.allocator, path, ctx.profile.runtime.file_read_max_bytes), .is_error = false };
}

const ByteRange = struct { start: usize, end: ?usize };

fn parseByteRange(raw: []const u8) !ByteRange {
    var start: usize = 0;
    var end: ?usize = null;
    if (std.mem.indexOfScalar(u8, raw, '-')) |dash| {
        if (dash > 0) start = try std.fmt.parseInt(usize, raw[0..dash], 10);
        if (dash + 1 < raw.len) end = try std.fmt.parseInt(usize, raw[dash + 1 ..], 10);
    } else start = try std.fmt.parseInt(usize, raw, 10);
    return .{ .start = start, .end = end };
}

fn executeWriteEdit(ctx: *ctxmod.RunContext, call: provider.ToolCall) !runtime_tools.ToolResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, call.arguments, .{});
    defer parsed.deinit();
    const path = try runtime_tools.requireStringArg(parsed.value.object, "path");
    if (std.mem.eql(u8, call.name, "write")) {
        try files.write(path, try runtime_tools.requireStringArg(parsed.value.object, "content"));
        return .{ .content = try std.fmt.allocPrint(ctx.allocator, "wrote {s}", .{path}), .is_error = false };
    }
    try files.editLimited(ctx.allocator, path, try runtime_tools.requireStringArg(parsed.value.object, "oldText"), try runtime_tools.requireStringArg(parsed.value.object, "newText"), ctx.profile.runtime.file_edit_max_bytes);
    return .{ .content = try std.fmt.allocPrint(ctx.allocator, "edited {s}", .{path}), .is_error = false };
}

fn executeBash(ctx: *ctxmod.RunContext, call: provider.ToolCall) !runtime_tools.ToolResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, call.arguments, .{});
    defer parsed.deinit();
    const command = try runtime_tools.requireStringArg(parsed.value.object, "command");
    if (commandRunsZincGraph(command)) return .{ .content = try ctx.allocator.dupe(u8, "graph runs from agent bash are blocked; use run_graph so Zinc can apply graph_run_policy approval"), .is_error = true };
    const result = try process.runShell(ctx.allocator, ctx.io, command, ctx.profile.runtime.bash_output_max_bytes, ctx.profile.runtime.bash_capture_max_bytes);
    defer result.deinit(ctx.allocator);
    return .{
        .content = try process.shellSummary(ctx.allocator, command, result, ctx.profile.runtime.bash_output_max_bytes, ctx.profile.runtime.bash_output_max_lines),
        .is_error = result.code != 0,
        .metadata_json = try process.shellMetadata(ctx.allocator, command, result),
    };
}

fn looksLikeRuntimeUri(path: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, path, ':') orelse return false;
    if (colon == 0) return false;
    return std.mem.indexOfAny(u8, path[0..colon], "/\\") == null;
}

fn commandRunsZincGraph(command: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, command, " \t\r\n;&|()<>\"'");
    var previous_was_zinc = false;
    while (it.next()) |token| {
        const base = std.fs.path.basename(token);
        if (previous_was_zinc and std.mem.eql(u8, token, "run")) return true;
        previous_was_zinc = std.mem.eql(u8, base, "zn") or std.mem.eql(u8, base, "zinc");
    }
    return false;
}

fn staleWriteError(ctx: *ctxmod.RunContext, call: provider.ToolCall) !?runtime_tools.ToolResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, call.arguments, .{});
    defer parsed.deinit();
    const path = try runtime_tools.requireStringArg(parsed.value.object, "path");
    const read_content = latestReadContentForPath(ctx.allocator, ctx.log.messages, path) orelse return .{ .content = try std.fmt.allocPrint(ctx.allocator, "{s} rejected: read the current file before editing path={s}", .{ call.name, path }), .is_error = true };
    defer ctx.allocator.free(read_content);
    const current = files.readLimited(ctx.allocator, path, ctx.profile.runtime.file_read_max_bytes) catch |err| switch (err) {
        error.FileNotFound => try ctx.allocator.dupe(u8, ""),
        else => return err,
    };
    defer ctx.allocator.free(current);
    if (!std.mem.eql(u8, read_content, current)) return .{ .content = try std.fmt.allocPrint(ctx.allocator, "file changed since Zinc last read it; read it again before editing: {s}", .{path}), .is_error = true };
    return null;
}

fn latestReadContentForPath(allocator: Allocator, messages: []const sessions.Message, path: []const u8) ?[]u8 {
    var latest_id: ?[]const u8 = null;
    for (messages) |message| {
        if (!std.mem.eql(u8, message.role, "assistant")) continue;
        for (message.tool_calls) |call| {
            if (!std.mem.eql(u8, call.name, "read")) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, call.arguments, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const raw_path = parsed.value.object.get("path") orelse continue;
            if (raw_path != .string or !std.mem.eql(u8, raw_path.string, path)) continue;
            if (std.mem.indexOf(u8, path, ":bytes=") != null) continue;
            latest_id = call.id;
        }
    }
    const id = latest_id orelse return null;
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        const message = messages[i];
        if (!std.mem.eql(u8, message.role, "tool")) continue;
        if (message.name == null or !std.mem.eql(u8, message.name.?, "read")) continue;
        if (message.tool_call_id) |call_id| if (std.mem.eql(u8, call_id, id)) return allocator.dupe(u8, message.content) catch null;
    }
    return null;
}

fn hasTool(available: []const []const u8, name: []const u8) bool {
    for (available) |tool| if (std.mem.eql(u8, tool, name)) return true;
    return false;
}
