const std = @import("std");
const config = @import("config.zig");
const graph = @import("../core/graph.zig");
const sessions = @import("session.zig");
const provider = @import("provider.zig");
const tools = @import("tools.zig");
const trace = @import("../sys/trace.zig");

const Allocator = std.mem.Allocator;

pub fn runGraph(allocator: Allocator, io: std.Io, home: []const u8, graph_path: []const u8, entry_override: ?[]const u8) !void {
    const run_span = trace.span("run_graph");
    defer run_span.end("engine", "graph={s}", .{graph_path});

    const profile = try config.loadRuntimeProfile(allocator, io, home, null);
    defer profile.deinit(allocator);

    const loaded_graph = try graph.load(allocator, io, graph_path);
    defer loaded_graph.deinit(allocator);
    try graph.validate(loaded_graph);

    const entry = graph.entryResourceId(loaded_graph, entry_override) orelse return error.NoEntryResource;

    // Get identity and instructions
    const identity = try graph.resourceIdentity(allocator, loaded_graph, entry);
    defer allocator.free(identity);

    const instructions = try graph.extractResourceInstructions(allocator, loaded_graph, entry);
    defer allocator.free(instructions);

    // Get tools
    const tool_names = try graph.readTools(allocator, loaded_graph, entry);
    defer graph.freeStringList(allocator, tool_names);

    // Build tools JSON schema
    const tools_json = try tools.schemaJson(allocator, tool_names);
    defer allocator.free(tools_json);

    // For now, just run a simple agent turn
    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(allocator);

    try provider.appendMessage(allocator, &messages, .{
        .role = "system",
        .content = try std.fmt.allocPrint(allocator, "Identity: {s}\n{s}", .{ identity, instructions }),
    });

    const turn = try provider.call(allocator, io, .{
        .profile = &profile,
        .max_tokens = profile.model.generation.max_tokens,
        .reasoning_budget_tokens = null,
        .tools_json = tools_json,
        .messages = messages.items,
    });
    defer provider.freeTurn(allocator, turn);

    const clean = try provider.cleanText(allocator, turn.text, &profile);
    defer allocator.free(clean);

    std.debug.print("{s}\n", .{clean});
}
