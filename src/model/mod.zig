const std = @import("std");
const circuitry = @import("circuitry");
const ctxmod = @import("../graph/context.zig");
const provider = @import("../provider/mod.zig");
const sessions = @import("../runtime/session.zig");
const runtime_tools = @import("../tools/schema.zig");
const uri = @import("../io/uri.zig");
const runtime = @import("../runtime/mod.zig");

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

pub const Result = struct {
    text: []u8,
    reasoning: ?[]u8 = null,

    pub fn deinit(self: Result, allocator: Allocator) void {
        allocator.free(self.text);
        if (self.reasoning) |value| allocator.free(value);
    }
};

pub fn run(ctx: *ctxmod.RunContext, messages: *std.ArrayList(provider.Message), spec: Spec, reasoning_effort: ?[]const u8, execute_tool: ExecuteTool) !Result {
    var retries: usize = 0;
    while (true) {
        const record_session = ctx.frame.isInteractiveTarget(spec.label);
        const turn = try callProvider(ctx, if (record_session) ctx.session else null, spec.label, .{ .profile = ctx.profile, .reasoning_effort = reasoning_effort, .json_response = spec.json, .tools_json = spec.tools_json, .messages = messages.items });
        defer provider.freeTurn(ctx.allocator, turn);
        if (turn.tool_calls.len == 0) {
            const clean = try provider.cleanText(ctx.allocator, turn.text, ctx.profile);
            errdefer ctx.allocator.free(clean);
            if (std.mem.trim(u8, clean, " \t\r\n").len == 0 and retries < ctx.profile.runtime.tool_max_turns) {
                ctx.allocator.free(clean);
                retries += 1;
                try provider.appendMessage(ctx.allocator, messages, .{ .role = "assistant", .content = turn.text, .reasoning = turn.reasoning });
                try provider.appendMessage(ctx.allocator, messages, .{ .role = "user", .content = "Return a non-empty final response for this turn." });
                continue;
            }
            if (spec.schema) |schema| if (!isValidSchemaJson(ctx.allocator, schema, clean) and retries < ctx.profile.runtime.tool_max_turns) {
                ctx.allocator.free(clean);
                retries += 1;
                try provider.appendMessage(ctx.allocator, messages, .{ .role = "assistant", .content = turn.text, .reasoning = turn.reasoning });
                try provider.appendMessage(ctx.allocator, messages, .{ .role = "user", .content = "Return only valid JSON matching the requested Circuitry schema. Do not include markdown or prose." });
                continue;
            };
            if (spec.json and !isValidJson(ctx.allocator, clean) and retries < ctx.profile.runtime.tool_max_turns) {
                ctx.allocator.free(clean);
                retries += 1;
                try provider.appendMessage(ctx.allocator, messages, .{ .role = "assistant", .content = turn.text, .reasoning = turn.reasoning });
                try provider.appendMessage(ctx.allocator, messages, .{ .role = "user", .content = "Return only valid JSON matching the requested schema. Do not include markdown or prose." });
                continue;
            }
            return .{ .text = clean, .reasoning = if (turn.reasoning) |value| try ctx.allocator.dupe(u8, value) else null };
        }
        try provider.appendMessage(ctx.allocator, messages, .{ .role = "assistant", .content = turn.text, .reasoning = turn.reasoning, .tool_calls = turn.tool_calls });
        if (record_session) try sessions.appendAssistantToolCalls(ctx.allocator, ctx.layout_ctx, ctx.session, ctx.profile.model.id, turn.text, turn.reasoning, turn.tool_calls);
        const read_ctx = try runtimeReadContext(ctx);
        defer read_ctx.deinit(ctx.allocator);
        for (turn.tool_calls) |call| {
            var tool_store = try runtime.Store.open(ctx.allocator, ctx.layout_ctx, runtime.scope.default());
            defer tool_store.close();
            const called_event = if (record_session) try tool_store.appendEvent(.{ .session_id = ctx.session.id, .type = runtime.events.tool_called, .summary = call.name, .payload_json = call.arguments }) else null;
            defer if (called_event) |id| ctx.allocator.free(id);
            const result = try execute_tool(ctx, read_ctx.context, spec, call);
            defer result.deinit(ctx.allocator);
            if (record_session) {
                try sessions.appendToolResult(ctx.allocator, ctx.layout_ctx, ctx.session, call, result);
                const event_type = if (result.is_error) runtime.events.tool_failed else runtime.events.tool_finished;
                const event_id = try tool_store.appendEvent(.{ .session_id = ctx.session.id, .type = event_type, .summary = call.name, .payload_json = result.metadata_json orelse "{}" });
                defer ctx.allocator.free(event_id);
                try tool_store.writeLog(.{ .run_id = ctx.run_id, .session_id = ctx.session.id, .event_id = event_id, .level = if (result.is_error) "error" else "info", .component = "tool", .message = call.name });
            }
            if (result.is_error) {
                if (retries >= ctx.profile.runtime.tool_max_turns) return finalToolFailure(ctx, messages, spec, result.content, reasoning_effort);
                retries += 1;
            } else retries = 0;
            const max_preview = ctx.profile.runtime.session_context_truncate_chars;
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

fn finalToolFailure(ctx: *ctxmod.RunContext, messages: *std.ArrayList(provider.Message), spec: Spec, last_failure: []const u8, reasoning_effort: ?[]const u8) !Result {
    const fallback = "I couldn't complete the tool workflow.\n\nLast failing tool result:\n{s}";
    const instruction = try std.fmt.allocPrint(ctx.allocator, "Tool attempts reached runtime.tool_max_turns={d}. Stop calling tools. Explain what failed, what was learned, and what the user can try next. Include the relevant command/result details from the failed tool results. Last failure:\n{s}", .{ ctx.profile.runtime.tool_max_turns, last_failure });
    defer ctx.allocator.free(instruction);
    try provider.appendMessage(ctx.allocator, messages, .{ .role = "user", .content = instruction });
    const turn = callProvider(ctx, null, spec.label, .{ .profile = ctx.profile, .reasoning_effort = reasoning_effort, .json_response = false, .tools_json = "[]", .messages = messages.items }) catch {
        return .{ .text = try std.fmt.allocPrint(ctx.allocator, fallback, .{last_failure}) };
    };
    defer provider.freeTurn(ctx.allocator, turn);
    if (turn.tool_calls.len != 0) return .{ .text = try std.fmt.allocPrint(ctx.allocator, fallback, .{last_failure}) };
    const clean = provider.cleanText(ctx.allocator, turn.text, ctx.profile) catch return .{ .text = try std.fmt.allocPrint(ctx.allocator, fallback, .{last_failure}) };
    if (std.mem.trim(u8, clean, " \t\r\n").len == 0) {
        ctx.allocator.free(clean);
        return .{ .text = try std.fmt.allocPrint(ctx.allocator, fallback, .{last_failure}) };
    }
    return .{ .text = clean, .reasoning = if (turn.reasoning) |value| try ctx.allocator.dupe(u8, value) else null };
}

fn callProvider(ctx: *ctxmod.RunContext, session: ?sessions.Session, label: []const u8, request: provider.Request) !provider.AssistantTurn {
    var attempts: usize = 0;
    while (true) {
        var store = try runtime.Store.open(ctx.allocator, ctx.layout_ctx, runtime.scope.default());
        defer store.close();
        const requested = if (session) |s| try store.appendEvent(.{ .session_id = s.id, .type = runtime.events.model_requested, .summary = label, .payload_json = "{}" }) else null;
        defer if (requested) |id| ctx.allocator.free(id);
        const turn = provider.call(ctx.allocator, ctx.io, request) catch |err| {
            if (session) |s| {
                const failed = try store.appendEvent(.{ .session_id = s.id, .type = runtime.events.model_failed, .summary = @errorName(err), .payload_json = "{}" });
                defer ctx.allocator.free(failed);
                try store.writeLog(.{ .run_id = ctx.run_id, .session_id = s.id, .event_id = failed, .level = "error", .component = "model", .message = @errorName(err) });
            }
            if (err == error.ProviderLoadingModel) {
                if (session) |s| try sessions.appendProviderError(ctx.allocator, ctx.layout_ctx, s, "provider loading");
                sleepMillis(provider_retry_delay_ms);
                continue;
            }
            if (!isTransient(err) or attempts >= ctx.profile.runtime.provider_max_retries) return err;
            attempts += 1;
            if (session) |s| try sessions.appendProviderError(ctx.allocator, ctx.layout_ctx, s, "provider retry");
            continue;
        };
        if (session) |s| {
            const responded = try store.appendEvent(.{ .session_id = s.id, .type = runtime.events.model_responded, .summary = label, .payload_json = "{}" });
            defer ctx.allocator.free(responded);
            try store.writeLog(.{ .run_id = ctx.run_id, .session_id = s.id, .event_id = responded, .component = "model", .message = "provider response" });
            if (turn.prompt_tokens) |tokens| try sessions.appendProviderUsage(ctx.allocator, ctx.layout_ctx, s, request.profile.model.id, tokens);
        }
        return turn;
    }
}

fn runtimeReadContext(ctx: *ctxmod.RunContext) !ctxmod.RuntimeReadContext {
    const inputs = try ctx.allocator.alloc(uri.Input, ctx.inputs.len);
    for (ctx.inputs, 0..) |input, i| inputs[i] = .{ .id = input.id, .value = input.value };
    return .{
        .context = .{ .layout_ctx = ctx.layout_ctx, .session_id = ctx.session.id, .session_head_messages = ctx.profile.runtime.session_head_messages, .session_tail_messages = ctx.profile.runtime.session_tail_messages, .session_context_truncate_chars = ctx.profile.runtime.session_context_truncate_chars, .inputs = inputs },
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
