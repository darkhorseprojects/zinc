const std = @import("std");
const ctxmod = @import("../graph/context.zig");
const config = @import("../config/mod.zig");
const files = @import("../io/fs.zig");
const platform = @import("../platform.zig");
const process = @import("../io/process.zig");
const provider = @import("../provider/mod.zig");
const runtime_tools = @import("schema.zig");
const sessions = @import("../runtime/session.zig");
const uri = @import("../io/uri.zig");
const model = @import("../model/mod.zig");

const Allocator = std.mem.Allocator;
pub fn execute(ctx: *ctxmod.RunContext, read_ctx: uri.Context, spec: model.Spec, call: provider.ToolCall) !runtime_tools.ToolResult {
    if (!hasTool(spec.tools, call.name)) return toolError(ctx.allocator, call, "UnknownTool", "no such tool is available");
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
        if (ctx.profile.runtime.scope == .readonly) return toolError(ctx.allocator, call, "ScopeDenied", "file writes and edits are denied by scope: readonly");
        var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, call.arguments, .{});
        defer parsed.deinit();
        const path = try runtime_tools.requireStringArg(parsed.value.object, "path");
        if (!try pathAllowed(ctx.allocator, path, ctx.profile.runtime.scope)) return toolError(ctx.allocator, call, "ScopeDenied", "path is outside project scope");
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
    if (!try pathAllowed(ctx.allocator, path, ctx.profile.runtime.scope)) return toolError(ctx.allocator, call, "ScopeDenied", "path is outside project scope");
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
    if (commandRunsZincGraph(command)) return .{ .content = try ctx.allocator.dupe(u8, "graph runs from model bash are blocked; use run_graph so Zinc can apply tools.graph_runs approval"), .is_error = true };
    const head = commandHead(command) orelse return toolError(ctx.allocator, call, "BashDenied", "empty shell command");
    if (!try bashAllowed(ctx, command, head)) return toolError(ctx.allocator, call, "BashDenied", "shell command denied by tools.bash policy");
    if (ctx.profile.runtime.scope == .readonly and obviouslyWrites(command, head)) return toolError(ctx.allocator, call, "ScopeDenied", "command rejected by scope: readonly");
    if (ctx.profile.runtime.scope == .project and obviousOutsidePath(command)) return toolError(ctx.allocator, call, "ScopeDenied", "command has an obvious path outside project scope");
    const cwd: ?[]const u8 = if (ctx.profile.runtime.scope == .open) null else ".";
    const result = try process.runShell(ctx.allocator, ctx.io, command, cwd, ctx.profile.runtime.bash_output_max_bytes, ctx.profile.runtime.bash_capture_max_bytes);
    defer result.deinit(ctx.allocator);
    return .{
        .content = try process.shellSummary(ctx.allocator, command, result, ctx.profile.runtime.bash_output_max_bytes, ctx.profile.runtime.bash_output_max_lines),
        .is_error = result.code != 0,
        .metadata_json = try process.shellMetadata(ctx.allocator, command, result),
    };
}

fn bashAllowed(ctx: *ctxmod.RunContext, command: []const u8, head: []const u8) !bool {
    if (ctx.profile.runtime.bash_mode == .open) return true;
    if (hasHead(ctx.profile.runtime.confirm_commands, head)) return try confirmCommand(ctx, command, head);
    if (ctx.profile.runtime.bash_mode == .build) return true;
    return platform.shell.classify(platform.currentOS(), command) == .inspect;
}

fn confirmCommand(ctx: *ctxmod.RunContext, command: []const u8, head: []const u8) !bool {
    for (ctx.bash_allowances.items) |*allowance| {
        if (std.mem.eql(u8, allowance.head, head) and allowance.remaining > 0) {
            allowance.remaining -= 1;
            return true;
        }
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(ctx.allocator);
    try text.print(ctx.allocator, "\nConfirm shell command\n\n{s}\n\nMatched command: {s}\n\n[y] allow once\n[a] allow 3 total for {s}\n[b] allow 5 total for {s}\n[n] deny\n", .{ command, head, head, head });
    try files.writeAllErr(text.items);
    var buf: [16]u8 = undefined;
    const n = try files.readStdin(&buf);
    if (n == 0) return false;
    const answer = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (answer.len == 0) return false;
    if (answer[0] == 'y' or answer[0] == 'Y') return true;
    if (answer[0] == 'a' or answer[0] == 'A') return addAllowance(ctx, head, 2);
    if (answer[0] == 'b' or answer[0] == 'B') return addAllowance(ctx, head, 4);
    return false;
}

fn addAllowance(ctx: *ctxmod.RunContext, head: []const u8, future: usize) !bool {
    try ctx.bash_allowances.append(ctx.allocator, .{ .head = try ctx.allocator.dupe(u8, head), .remaining = future });
    return true;
}

fn commandHead(command: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return null;
    var end: usize = 0;
    while (end < trimmed.len and std.mem.indexOfScalar(u8, " \t\r\n;&|()<>\"'", trimmed[end]) == null) end += 1;
    if (end == 0) return null;
    return std.fs.path.basename(trimmed[0..end]);
}

fn hasHead(list: []const []const u8, head: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, head)) return true;
    return false;
}

fn pathAllowed(allocator: Allocator, raw_path: []const u8, scope: config.Scope) !bool {
    _ = allocator;
    if (scope == .open) return true;
    if (std.fs.path.isAbsolute(raw_path) or platform.path.isAbsolute(.windows, raw_path)) return false;
    var it = std.mem.tokenizeAny(u8, raw_path, "/\\");
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn obviouslyWrites(command: []const u8, head: []const u8) bool {
    _ = command;
    return hasHead(&.{ "rm", "rmdir", "mv", "cp", "touch", "mkdir", "tee", "dd", "chmod", "chown", "mkfs", "mount", "umount", "kill", "pkill", "shutdown", "reboot" }, head);
}

fn obviousOutsidePath(command: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, command, " \t\r\n;&|()<>\"'");
    while (it.next()) |token| {
        if (std.fs.path.isAbsolute(token) or platform.path.isAbsolute(.windows, token)) return true;
        if (std.mem.eql(u8, token, "..")) return true;
        var parts = std.mem.tokenizeAny(u8, token, "/\\");
        while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
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
    const current = files.readLimited(ctx.allocator, path, ctx.profile.runtime.file_read_max_bytes) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (current) |content| ctx.allocator.free(content);

    const read_snapshot = try latestReadSnapshotForPath(ctx.allocator, ctx.log.messages, path);
    defer read_snapshot.deinit(ctx.allocator);

    if (read_snapshot == .none) {
        if (std.mem.eql(u8, call.name, "write") and current == null) return null;
        return .{ .content = try std.fmt.allocPrint(ctx.allocator, "{s} rejected: read the current file before editing path={s}", .{ call.name, path }), .is_error = true };
    }
    if (read_snapshot == .missing) {
        if (std.mem.eql(u8, call.name, "write") and current == null) return null;
        return .{ .content = try std.fmt.allocPrint(ctx.allocator, "file changed since Zinc last read it; read it again before editing: {s}", .{path}), .is_error = true };
    }
    if (current == null or !std.mem.eql(u8, read_snapshot.content, current.?)) return .{ .content = try std.fmt.allocPrint(ctx.allocator, "file changed since Zinc last read it; read it again before editing: {s}", .{path}), .is_error = true };
    return null;
}

const ReadSnapshot = union(enum) {
    none,
    missing,
    content: []u8,

    fn deinit(self: ReadSnapshot, allocator: Allocator) void {
        if (self == .content) allocator.free(self.content);
    }
};

fn latestReadSnapshotForPath(allocator: Allocator, messages: []const sessions.Message, path: []const u8) !ReadSnapshot {
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
    const id = latest_id orelse return .none;
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        const message = messages[i];
        if (!std.mem.eql(u8, message.role, "tool")) continue;
        if (message.name == null or !std.mem.eql(u8, message.name.?, "read")) continue;
        if (message.tool_call_id) |call_id| if (std.mem.eql(u8, call_id, id)) {
            if (try readToolFailure(allocator, message.content, "FileNotFound")) return .missing;
            return .{ .content = try allocator.dupe(u8, message.content) };
        };
    }
    return .none;
}

fn readToolFailure(allocator: Allocator, content: []const u8, expected: []const u8) !bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const ok = parsed.value.object.get("ok") orelse return false;
    if (ok != .bool or ok.bool) return false;
    const err = parsed.value.object.get("error") orelse return false;
    return err == .string and std.mem.eql(u8, err.string, expected);
}

fn hasTool(available: []const []const u8, name: []const u8) bool {
    for (available) |tool| if (std.mem.eql(u8, tool, name)) return true;
    return false;
}
