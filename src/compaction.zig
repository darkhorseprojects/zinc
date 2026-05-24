const std = @import("std");
const config = @import("config.zig");
const graph = @import("graph.zig");
const provider = @import("provider.zig");
const sessions = @import("session.zig");

const Allocator = std.mem.Allocator;
const local_auth_header = "Bearer zinc";

pub fn runGraph(allocator: Allocator, io: std.Io, home: []const u8, session: sessions.Session, graph_path: []const u8) !usize {
    const session_log = try sessions.readLog(allocator, session.path);
    defer allocator.free(session_log);
    const message_count = try sessions.countMessages(allocator, session_log);
    if (message_count == 0) return error.EmptySession;

    const text = try graph.readLinkedText(allocator, graph_path);
    defer allocator.free(text);
    try graph.validateText(text);
    const resource = graph.findSingleAgent(text) orelse return error.InvalidCircuitryGraph;
    const identity = try graph.resourceIdentity(allocator, text, resource);
    defer allocator.free(identity);
    const instructions = try graph.extractResourceInstructions(allocator, text, resource);
    defer allocator.free(instructions);
    const model_id = try config.resolveGraphModelId(allocator, text, home);
    defer allocator.free(model_id);
    const model_alias = try config.readModelValue(allocator, home, model_id, "alias");
    defer allocator.free(model_alias);
    const temperature = try config.readModelF64Default(allocator, home, model_id, "runtime.temperature", 0.5);
    const visible_tokens = try config.readModelUsizeDefault(allocator, home, model_id, "runtime.max_tokens", 1024);

    const runtime = try config.loadRuntimeConfig(allocator, home);
    defer runtime.deinit(allocator);

    const system_prompt = try std.fmt.allocPrint(allocator, "Identity: {s}\nInstructions:\n{s}", .{ identity, instructions });
    defer allocator.free(system_prompt);
    const user_prompt = try std.fmt.allocPrint(allocator,
        \\Compact this Zinc session log. The summary will cover {d} persisted user/assistant messages.
        \\session_log:
        \\{s}
    , .{ message_count, session_log });
    defer allocator.free(user_prompt);

    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(allocator);
    defer provider.freeMessages(allocator, messages.items);
    try provider.appendMessage(allocator, &messages, .{ .role = "system", .content = system_prompt });
    try provider.appendMessage(allocator, &messages, .{ .role = "user", .content = user_prompt });

    const turn = try provider.call(allocator, io, .{
        .base_url = runtime.provider_base_url,
        .authorization = local_auth_header,
        .model = model_alias,
        .temperature = temperature,
        .max_tokens = visible_tokens,
        .reasoning_format = "auto",
        .reasoning_budget_tokens = null,
        .thinking_enabled = false,
        .json_response = true,
        .tools_json = "[]",
        .messages = messages.items,
    });
    defer provider.freeTurn(allocator, turn);
    const clean = try provider.cleanText(allocator, turn.text);
    defer allocator.free(clean);
    const summary = try parseSummary(allocator, clean);
    defer allocator.free(summary);
    try sessions.appendCompaction(allocator, session.path, message_count, summary);
    return message_count;
}

fn parseSummary(allocator: Allocator, text: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadProviderResponse;
    const summary = parsed.value.object.get("summary") orelse return error.BadProviderResponse;
    if (summary != .string or std.mem.trim(u8, summary.string, " \t\r\n").len == 0) return error.BadProviderResponse;
    return allocator.dupe(u8, summary.string);
}
