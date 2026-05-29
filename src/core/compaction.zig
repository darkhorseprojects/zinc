const std = @import("std");
const config = @import("../runtime/config.zig");
const graph = @import("graph.zig");
const provider = @import("../runtime/provider.zig");
const sessions = @import("../runtime/session.zig");

const Allocator = std.mem.Allocator;

pub fn validateGraph(allocator: Allocator, io: std.Io, graph_path: []const u8) !void {
    const loaded_graph = try graph.load(allocator, io, graph_path);
    defer loaded_graph.deinit(allocator);
    try graph.validate(loaded_graph);
    const resource = graph.entryResourceId(loaded_graph, null) orelse return error.InvalidCircuitryGraph;
    const identity = try graph.resourceIdentity(allocator, loaded_graph, resource);
    defer allocator.free(identity);
    const instructions = try graph.extractResourceInstructions(allocator, loaded_graph, resource);
    defer allocator.free(instructions);
}

pub fn runGraph(allocator: Allocator, io: std.Io, home: []const u8, session: sessions.Session, graph_path: []const u8) !usize {
    const profile = try config.loadRuntimeProfile(allocator, io, home, null);
    defer profile.deinit(allocator);
    const session_log = try sessions.readParsed(allocator, session.path);
    defer session_log.deinit(allocator);
    const message_count = session_log.messageCount();
    if (message_count == 0) return error.EmptySession;

    const transcript = try session_log.transcript(allocator);
    defer allocator.free(transcript);
    const loaded_graph = try graph.load(allocator, io, graph_path);
    defer loaded_graph.deinit(allocator);
    try graph.validate(loaded_graph);
    const resource = graph.entryResourceId(loaded_graph, null) orelse return error.InvalidCircuitryGraph;
    const identity = try graph.resourceIdentity(allocator, loaded_graph, resource);
    defer allocator.free(identity);
    const instructions = try graph.extractResourceInstructions(allocator, loaded_graph, resource);
    defer allocator.free(instructions);

    const system_prompt = try std.fmt.allocPrint(allocator, "Identity: {s}\nInstructions:\n{s}", .{ identity, instructions });
    defer allocator.free(system_prompt);
    const user_prompt = try std.fmt.allocPrint(allocator,
        \\Compact this Zinc semantic transcript. The summary will cover {d} persisted messages.
        \\transcript:
        \\{s}
    , .{ message_count, transcript });
    defer allocator.free(user_prompt);

    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(allocator);
    defer provider.freeMessages(allocator, messages.items);
    try provider.appendMessage(allocator, &messages, .{ .role = "system", .content = system_prompt });
    try provider.appendMessage(allocator, &messages, .{ .role = "user", .content = user_prompt });

    const compaction_reasoning = profile.runtime.compaction_reasoning_tokens;
    const turn = try provider.call(allocator, io, .{
        .profile = &profile,
        .max_tokens = profile.runtime.compaction_max_tokens,
        .reasoning_budget_tokens = if (!profile.model.reasoning.enabled or compaction_reasoning < 0) null else @intCast(compaction_reasoning),
        .json_response = false,
        .tools_json = "[]",
        .messages = messages.items,
    });
    defer provider.freeTurn(allocator, turn);
    const clean = try provider.cleanText(allocator, turn.text, &profile);
    defer allocator.free(clean);
    const summary = try parseSummary(allocator, clean);
    defer allocator.free(summary);
    try sessions.appendCompaction(allocator, session.path, message_count, summary);
    return message_count;
}

fn parseSummary(allocator: Allocator, text: []const u8) ![]u8 {
    const start = std.mem.indexOfScalar(u8, text, '{') orelse return error.BadProviderResponse;
    const end = std.mem.lastIndexOfScalar(u8, text, '}') orelse return error.BadProviderResponse;
    if (end <= start) return error.BadProviderResponse;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text[start .. end + 1], .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadProviderResponse;
    const summary = parsed.value.object.get("summary") orelse return error.BadProviderResponse;
    if (summary != .string or std.mem.trim(u8, summary.string, " \t\r\n").len == 0) return error.BadProviderResponse;
    return allocator.dupe(u8, summary.string);
}
