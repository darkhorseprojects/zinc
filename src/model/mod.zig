const std = @import("std");
const circuitry = @import("circuitry");
const ctxmod = @import("../graph/context.zig");
const provider = @import("provider.zig");
const sessions = @import("../session/mod.zig");
const runtime_tools = @import("../tools/schema.zig");
const uri = @import("../io/uri.zig");
const trace = @import("../io/trace.zig");

const Allocator = std.mem.Allocator;
const provider_retry_delay_ms: usize = 1000;

pub const Spec = struct {
    label: []const u8,
    system: []const u8,
    tools: []const []const u8,
    tools_json: []const u8,
    json: bool = false,
    schema: ?*const circuitry.value.Value = null,
    runtime_reads: bool = false,
};

pub const ExecuteTool = *const fn (*ctxmod.RunContext, uri.Context, Spec, provider.ToolCall) anyerror!runtime_tools.ToolResult;

pub fn run(ctx: *ctxmod.RunContext, messages: *std.ArrayList(provider.Message), spec: Spec, max_tokens: ?usize, reasoning: ?usize, execute_tool: ExecuteTool) ![]u8 {
    var retries: usize = 0;
    var last_parsed_size: usize = ctx.log.raw.len;
    while (true) {
        if (ctx.frame.isInteractiveTarget(spec.label)) {
            var dir = std.Io.Dir.cwd();
            if (dir.statFile(ctx.io, ctx.session.path, .{})) |stat| {
                if (stat.size != last_parsed_size) {
                    ctx.log.deinit(ctx.allocator);
                    ctx.log.* = try sessions.readParsed(ctx.allocator, ctx.session.path);
                    last_parsed_size = ctx.log.raw.len;
                }
            } else |_| {}
        }
        const session_path = if (ctx.frame.isInteractiveTarget(spec.label)) ctx.session.path else null;
        const turn = try callProvider(ctx.allocator, ctx.io, session_path, ctx.profile.runtime.provider_max_retries, spec.label, .{ .profile = ctx.profile, .max_tokens = max_tokens, .reasoning_budget_tokens = reasoning, .json_response = spec.json, .tools_json = spec.tools_json, .messages = messages.items });
        defer provider.freeTurn(ctx.allocator, turn);
        if (turn.tool_calls.len == 0) {
            const clean = try provider.cleanText(ctx.allocator, turn.text, ctx.profile);
            errdefer ctx.allocator.free(clean);
            if (std.mem.trim(u8, clean, " \t\r\n").len == 0 and retries < ctx.profile.runtime.tool_max_turns) {
                ctx.allocator.free(clean);
                retries += 1;
                try provider.appendMessage(ctx.allocator, messages, .{ .role = "assistant", .content = turn.text });
                try provider.appendMessage(ctx.allocator, messages, .{ .role = "user", .content = "Return a non-empty final response for this turn." });
                continue;
            }
            if (spec.schema) |schema| if (!isValidSchemaJson(ctx.allocator, schema, clean) and retries < ctx.profile.runtime.tool_max_turns) {
                ctx.allocator.free(clean);
                retries += 1;
                try provider.appendMessage(ctx.allocator, messages, .{ .role = "assistant", .content = turn.text });
                try provider.appendMessage(ctx.allocator, messages, .{ .role = "user", .content = "Return only valid JSON matching the requested Circuitry schema. Do not include markdown or prose." });
                continue;
            };
            if (spec.json and !isValidJson(ctx.allocator, clean) and retries < ctx.profile.runtime.tool_max_turns) {
                ctx.allocator.free(clean);
                retries += 1;
                try provider.appendMessage(ctx.allocator, messages, .{ .role = "assistant", .content = turn.text });
                try provider.appendMessage(ctx.allocator, messages, .{ .role = "user", .content = "Return only valid JSON matching the requested schema. Do not include markdown or prose." });
                continue;
            }
            return clean;
        }
        try provider.appendMessage(ctx.allocator, messages, .{ .role = "assistant", .content = turn.text, .tool_calls = turn.tool_calls });
        if (ctx.frame.isInteractiveTarget(spec.label)) try sessions.appendAssistantToolCalls(ctx.allocator, ctx.session.path, turn.text, turn.tool_calls);
        const read_ctx = try runtimeReadContext(ctx);
        defer read_ctx.deinit(ctx.allocator);
        for (turn.tool_calls) |call| {
            const result = try execute_tool(ctx, read_ctx.context, spec, call);
            defer result.deinit(ctx.allocator);
            if (ctx.frame.isInteractiveTarget(spec.label)) try sessions.appendToolResult(ctx.allocator, ctx.session.path, call, result);
            if (result.is_error) {
                if (retries >= ctx.profile.runtime.tool_max_turns) return finalToolFailure(ctx, messages, spec, result.content, max_tokens, reasoning);
                retries += 1;
            } else retries = 0;
            const max_preview = ctx.profile.runtime.replay_truncate_chars;
            if (max_preview != 0 and result.content.len > max_preview) {
                const preview = result.content[0..max_preview];
                const content = try std.fmt.allocPrint(ctx.allocator, "{s}... [truncated, {d} chars - use session:current:tools:{s} for full]", .{ preview, result.content.len, call.id });
                defer ctx.allocator.free(content);
                try provider.appendMessage(ctx.allocator, messages, .{ .role = "tool", .content = content, .name = call.name, .tool_call_id = call.id });
            } else try provider.appendMessage(ctx.allocator, messages, .{ .role = "tool", .content = result.content, .name = call.name, .tool_call_id = call.id });
        }
    }
}

pub fn validateJson(allocator: Allocator, text: []const u8) !void {
    if (!isValidJson(allocator, text)) return error.InvalidModelJson;
}

pub fn validateJsonSchema(allocator: Allocator, schema: *const circuitry.value.Value, text: []const u8) !void {
    if (!isValidSchemaJson(allocator, schema, text)) return error.InvalidModelJson;
}

fn finalToolFailure(ctx: *ctxmod.RunContext, messages: *std.ArrayList(provider.Message), spec: Spec, last_failure: []const u8, max_tokens: ?usize, reasoning: ?usize) ![]u8 {
    const instruction = try std.fmt.allocPrint(ctx.allocator, "Tool attempts reached runtime.tool_max_turns={d}. Stop calling tools. Explain what failed, what was learned, and what the user can try next. Include the relevant command/result details from the failed tool results. Last failure:\n{s}", .{ ctx.profile.runtime.tool_max_turns, last_failure });
    defer ctx.allocator.free(instruction);
    try provider.appendMessage(ctx.allocator, messages, .{ .role = "user", .content = instruction });
    const turn = callProvider(ctx.allocator, ctx.io, null, ctx.profile.runtime.provider_max_retries, spec.label, .{ .profile = ctx.profile, .max_tokens = max_tokens, .reasoning_budget_tokens = reasoning, .json_response = false, .tools_json = "[]", .messages = messages.items }) catch {
        return std.fmt.allocPrint(ctx.allocator, "I couldn't complete the tool workflow.\n\nLast failing tool result:\n{s}", .{last_failure});
    };
    defer provider.freeTurn(ctx.allocator, turn);
    if (turn.tool_calls.len != 0) return std.fmt.allocPrint(ctx.allocator, "I couldn't complete the tool workflow.\n\nLast failing tool result:\n{s}", .{last_failure});
    const clean = provider.cleanText(ctx.allocator, turn.text, ctx.profile) catch return std.fmt.allocPrint(ctx.allocator, "I couldn't complete the tool workflow.\n\nLast failing tool result:\n{s}", .{last_failure});
    if (std.mem.trim(u8, clean, " \t\r\n").len == 0) {
        ctx.allocator.free(clean);
        return std.fmt.allocPrint(ctx.allocator, "I couldn't complete the tool workflow.\n\nLast failing tool result:\n{s}", .{last_failure});
    }
    return clean;
}

fn callProvider(allocator: Allocator, io: std.Io, session_path: ?[]const u8, provider_max_retries: usize, label: []const u8, request: provider.Request) !provider.AssistantTurn {
    var attempts: usize = 0;
    while (true) {
        const span = trace.span("provider_call");
        trace.event("llm", "request", "label={s} attempt={d} messages={d} chars={d} tools={d}", .{ label, attempts + 1, request.messages.len, messageChars(request.messages), request.tools_json.len });
        const turn = provider.call(allocator, io, request) catch |err| {
            span.end("llm", "label={s} attempt={d} error={s}", .{ label, attempts + 1, @errorName(err) });
            if (err == error.ProviderLoadingModel) {
                if (session_path) |path| try sessions.appendProviderError(allocator, path, "provider loading");
                sleepMillis(provider_retry_delay_ms);
                continue;
            }
            if (!isTransient(err) or attempts >= provider_max_retries) return err;
            attempts += 1;
            if (session_path) |path| try sessions.appendProviderError(allocator, path, "provider retry");
            continue;
        };
        span.end("llm", "label={s} attempt={d} text_chars={d} tool_calls={d}", .{ label, attempts + 1, turn.text.len, turn.tool_calls.len });
        return turn;
    }
}

fn runtimeReadContext(ctx: *ctxmod.RunContext) !ctxmod.RuntimeReadContext {
    const inputs = try ctx.allocator.alloc(uri.Input, ctx.inputs.len);
    for (ctx.inputs, 0..) |input, i| inputs[i] = .{ .id = input.id, .value = input.value };
    return .{
        .context = .{ .layout_ctx = ctx.layout_ctx, .session_id = ctx.session.id, .session_path = ctx.session.path, .session_dir = std.fs.path.dirname(ctx.session.path) orelse ".zinc/sessions", .session_log = ctx.log.raw, .session_head_messages = ctx.profile.runtime.session_head_messages, .session_tail_messages = ctx.profile.runtime.session_tail_messages, .replay_truncate_chars = ctx.profile.runtime.replay_truncate_chars, .inputs = inputs },
        .inputs = inputs,
    };
}

fn messageChars(messages: []const provider.Message) usize {
    var n: usize = 0;
    for (messages) |m| {
        n += m.role.len + m.content.len;
        for (m.parts) |part| switch (part) {
            .text => |text| n += text.len,
            .image_url => |url| n += url.len,
        };
    }
    return n;
}

fn isTransient(err: anyerror) bool {
    return switch (err) {
        error.ProviderRequestFailed, error.ProviderLoadingModel, error.ConnectionRefused, error.ConnectionResetByPeer, error.BrokenPipe, error.BadProviderResponse => true,
        else => false,
    };
}

fn sleepMillis(ms: usize) void {
    std.Io.sleep(std.Options.debug_io, .{ .nanoseconds = @as(i96, @intCast(ms)) * std.time.ns_per_ms }, .awake) catch return;
}

fn isValidSchemaJson(allocator: Allocator, schema: *const circuitry.value.Value, text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return false;
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const converted = jsonToCircuitryValue(arena.allocator(), parsed.value) catch return false;
    return circuitry.schema.validateValue(allocator, schema, &converted) catch false;
}

fn jsonToCircuitryValue(allocator: Allocator, value: std.json.Value) !circuitry.value.Value {
    return switch (value) {
        .null => .{ .null_val = {} },
        .bool => |v| .{ .boolean = v },
        .integer => |v| .{ .integer = v },
        .float => |v| .{ .float = v },
        .number_string => |v| .{ .string = try allocator.dupe(u8, v) },
        .string => |v| .{ .string = try allocator.dupe(u8, v) },
        .array => |arr| blk: {
            const items = try allocator.alloc(circuitry.value.Value, arr.items.len);
            for (arr.items, 0..) |item, i| items[i] = try jsonToCircuitryValue(allocator, item);
            break :blk .{ .sequence = items };
        },
        .object => |obj| blk: {
            var map: circuitry.value.Mapping = .{};
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const converted = try jsonToCircuitryValue(allocator, entry.value_ptr.*);
                try map.put(allocator, key, converted);
            }
            break :blk .{ .mapping = map };
        },
    };
}

fn isValidJson(allocator: Allocator, text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return false;
    parsed.deinit();
    return true;
}
