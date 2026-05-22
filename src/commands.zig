const std = @import("std");
const config = @import("config.zig");
const engine = @import("engine.zig");
const files = @import("files.zig");
const graph = @import("graph.zig");
const plan = @import("plan.zig");
const sessions = @import("session.zig");
const tool_registry = @import("tool_registry.zig");

const Allocator = std.mem.Allocator;

pub fn usage() void {
    std.debug.print(
        \\zn - Zinc, a tiny Circuitry-native runtime
        \\
        \\usage:
        \\  zn validate [graph]
        \\  zn compile [graph] [compiled-plan]
        \\  zn up [model-id]
        \\  zn down
        \\  zn clean [compiled|sessions|all|build|global [state|build|all]] [--yes]
        \\  zn [--session id|--continue] <prompt>
        \\  zn run [--session id|--continue] <prompt>
        \\  zn session-dir
        \\
    , .{});
}

pub fn validate(allocator: Allocator, home: []const u8, path_arg: ?[]const u8) !void {
    const runtime_paths = try config.loadRuntimePaths(allocator, home);
    defer runtime_paths.deinit(allocator);
    const path = path_arg orelse runtime_paths.graph;
    try validateGraphFile(allocator, path);
    std.debug.print("ok: {s}\n", .{path});
}

pub fn compile(allocator: Allocator, home: []const u8, graph_arg: ?[]const u8, out_arg: ?[]const u8) !void {
    const runtime_paths = try config.loadRuntimePaths(allocator, home);
    defer runtime_paths.deinit(allocator);
    const graph_path = graph_arg orelse runtime_paths.graph;
    const out = out_arg orelse runtime_paths.compiled_plan;
    try compileGraphFile(allocator, graph_path, out, home);
    std.debug.print("compiled: {s} -> {s}\n", .{ graph_path, out });
}

pub fn runFromArgs(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    var prompt_parts: std.ArrayList([]const u8) = .empty;
    defer prompt_parts.deinit(allocator);

    var resume_id: ?[]const u8 = null;
    var continue_last = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--continue")) {
            if (resume_id != null) return error.ConflictingSessionFlags;
            continue_last = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--session")) {
            if (continue_last or resume_id != null) return error.ConflictingSessionFlags;
            i += 1;
            if (i >= args.len) return error.MissingSessionId;
            resume_id = args[i];
            continue;
        }
        try prompt_parts.append(allocator, arg);
    }
    if (prompt_parts.items.len == 0) return usage();

    if (isCircuitryPath(prompt_parts.items[0])) {
        const graph_path = prompt_parts.items[0];
        const plan_path = ".zinc/compiled/ad-hoc-plan.json";
        try compileGraphFile(allocator, graph_path, plan_path, home);
        const prompt = try graphInvocationPrompt(allocator, graph_path, prompt_parts.items[1..]);
        defer allocator.free(prompt);
        try engine.run(allocator, io, home, prompt, resume_id, continue_last, plan_path);
        return;
    }

    const runtime_paths = try config.loadRuntimePaths(allocator, home);
    defer runtime_paths.deinit(allocator);
    try compileGraphFile(allocator, runtime_paths.graph, runtime_paths.compiled_plan, home);

    const prompt = try std.mem.join(allocator, " ", prompt_parts.items);
    defer allocator.free(prompt);
    try engine.run(allocator, io, home, prompt, resume_id, continue_last, runtime_paths.compiled_plan);
}

pub fn printSessionDir(allocator: Allocator) !void {
    const dir = try sessions.ensureDir(allocator);
    defer allocator.free(dir);
    std.debug.print("{s}\n", .{dir});
}

fn graphInvocationPrompt(allocator: Allocator, graph_path: []const u8, args: []const []const u8) ![]u8 {
    var inputs: std.ArrayList([]const u8) = .empty;
    defer inputs.deinit(allocator);
    var text_parts: std.ArrayList([]const u8) = .empty;
    defer text_parts.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            i += 1;
            if (i >= args.len) return error.MissingGraphInput;
            try inputs.append(allocator, args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--input=")) {
            try inputs.append(allocator, arg["--input=".len..]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--inputs-json")) {
            i += 1;
            if (i >= args.len) return error.MissingGraphInput;
            try inputs.append(allocator, args[i]);
            continue;
        }
        try text_parts.append(allocator, arg);
    }

    const user_text = if (text_parts.items.len == 0) "run this Circuitry graph" else try std.mem.join(allocator, " ", text_parts.items);
    defer if (text_parts.items.len != 0) allocator.free(user_text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "Run Circuitry graph: {s}\n", .{graph_path});
    if (inputs.items.len != 0) {
        try out.appendSlice(allocator, "Runtime inputs supplied on CLI:\n");
        for (inputs.items) |input| try out.print(allocator, "- {s}\n", .{input});
    }
    try out.print(allocator, "User request:\n{s}", .{user_text});
    return out.toOwnedSlice(allocator);
}

fn isCircuitryPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".circuitry.yaml") or
        std.mem.endsWith(u8, path, ".circuitry.yml") or
        std.mem.endsWith(u8, path, ".circuitry.json");
}

fn validateGraphFile(allocator: Allocator, path: []const u8) !void {
    const text = try graph.readLinkedText(allocator, path);
    defer allocator.free(text);
    try graph.validateText(text);
}

fn compileGraphFile(allocator: Allocator, graph_path: []const u8, out_path: []const u8, home: []const u8) !void {
    const text = try graph.readLinkedText(allocator, graph_path);
    defer allocator.free(text);
    try graph.validateText(text);

    const context_instructions = try graph.extractResourceInstructions(allocator, text, "recovered_context");
    defer allocator.free(context_instructions);
    const instructions = try graph.extractResourceInstructions(allocator, text, "assistant");
    defer allocator.free(instructions);
    const model_id = try config.resolveGraphModelId(allocator, text, home);
    defer allocator.free(model_id);
    const model_alias = try config.readModelValue(allocator, home, model_id, "alias");
    defer allocator.free(model_alias);
    const model_repo = try config.readModelValue(allocator, home, model_id, "hf_repo");
    defer allocator.free(model_repo);
    const tools = try graph.readTools(allocator, text, "assistant");
    defer graph.freeStringList(allocator, tools);
    for (tools) |tool| if (!tool_registry.contains(tool)) return error.UnknownTool;

    var context_prompt: std.ArrayList(u8) = .empty;
    defer context_prompt.deinit(allocator);
    try context_prompt.print(allocator,
        \\Identity: Context recovery
        \\Instructions:
        \\{s}
        \\
        \\Expected output:
        \\Return ONLY valid JSON matching: {{"summary": str, "relevant_facts": [str], "uncertainty": [str]}}
    , .{context_instructions});

    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(allocator);
    try prompt.print(allocator,
        \\Identity: Zinc
        \\Instructions:
        \\{s}
        \\
        \\Expected output:
        \\Return ONLY valid JSON matching: {{"response": str, "done": bool}}
    , .{instructions});
    if (graph.wantsCircuitryPrompt(text, tools)) {
        const pack = try config.readPromptPack(allocator, home, "circuitry-author.md");
        defer allocator.free(pack);
        try prompt.print(allocator, "\n\nCircuitry authoring knowledge:\n{s}", .{pack});
    }

    var compiled: std.ArrayList(u8) = .empty;
    defer compiled.deinit(allocator);
    try compiled.appendSlice(allocator, "{\"version\":1,\"model\":{\"id\":");
    try files.appendJsonString(allocator, &compiled, model_id);
    try compiled.appendSlice(allocator, ",\"alias\":");
    try files.appendJsonString(allocator, &compiled, model_alias);
    try compiled.appendSlice(allocator, "},\"tools\":[");
    for (tools, 0..) |tool, i| {
        if (i != 0) try compiled.append(allocator, ',');
        try files.appendJsonString(allocator, &compiled, tool);
    }
    try compiled.appendSlice(allocator, "],\"context_prompt\":");
    try files.appendJsonString(allocator, &compiled, context_prompt.items);
    try compiled.appendSlice(allocator, ",\"prompt\":");
    try files.appendJsonString(allocator, &compiled, prompt.items);
    try compiled.appendSlice(allocator, ",\"expect\":{\"response\":\"str\",\"done\":\"bool\"},\"session_log\":{\"source_dir\":\".zinc/sessions\",\"max_bytes\":65536}}\n");
    try files.write(out_path, compiled.items);
}
