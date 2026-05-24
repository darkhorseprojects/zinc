const std = @import("std");
const compaction = @import("compaction.zig");
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
        \\  zn compact [--session id|--continue] [graph]
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

pub fn compactFromArgs(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    var resume_id: ?[]const u8 = null;
    var continue_last = true;
    const default_graph_path = try config.readStringDefault(allocator, home, "compaction_graph", "graphs/zinc-compaction.circuitry.yaml");
    defer allocator.free(default_graph_path);
    var graph_path: []const u8 = default_graph_path;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--continue")) {
            if (resume_id != null) return error.ConflictingSessionFlags;
            continue_last = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--session")) {
            if (resume_id != null) return error.ConflictingSessionFlags;
            i += 1;
            if (i >= args.len) return error.MissingSessionId;
            resume_id = args[i];
            continue_last = false;
            continue;
        }
        graph_path = arg;
    }

    const session = try sessions.open(allocator, resume_id, continue_last);
    defer session.deinit(allocator);
    const message_count = try compaction.runGraph(allocator, io, home, session, graph_path);
    try sessions.rememberLast(session);
    std.debug.print("compacted {d} messages in session {s}\n", .{ message_count, session.id });
}

pub fn printSessionDir(allocator: Allocator) !void {
    const dir = try sessions.ensureDir(allocator);
    defer allocator.free(dir);
    std.debug.print("{s}\n", .{dir});
}

fn resolvePromptPackContent(allocator: Allocator, home: []const u8, pack: graph.PromptPack) ![]u8 {
    const trimmed = std.mem.trim(u8, pack.content, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "---\n")) return allocator.dupe(u8, pack.content);
    const rest = trimmed[4..];
    const end = std.mem.indexOf(u8, rest, "\n---") orelse return allocator.dupe(u8, pack.content);
    const body = std.mem.trim(u8, rest[end + "\n---".len ..], " \t\r\n");
    if (!std.mem.startsWith(u8, body, "prompt:")) return allocator.dupe(u8, pack.content);
    const id = std.mem.trim(u8, body["prompt:".len..], " \t\r\n");
    if (id.len == 0) return allocator.dupe(u8, pack.content);
    const filename = try std.fmt.allocPrint(allocator, "{s}.md", .{id});
    defer allocator.free(filename);
    return config.readPromptPack(allocator, home, filename);
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

fn validateToolFormat(format: []const u8) !void {
    if (std.mem.eql(u8, format, "openai")) return;
    if (std.mem.eql(u8, format, "gemma-native")) return;
    return error.InvalidConfigValue;
}

fn validateReasoningEffort(effort: []const u8) !void {
    if (std.mem.eql(u8, effort, "off")) return;
    if (std.mem.eql(u8, effort, "low")) return;
    if (std.mem.eql(u8, effort, "medium")) return;
    if (std.mem.eql(u8, effort, "high")) return;
    if (std.mem.eql(u8, effort, "extra-high")) return;
    return error.InvalidConfigValue;
}

fn validateReasoningFormat(format: []const u8) !void {
    if (std.mem.eql(u8, format, "auto")) return;
    if (std.mem.eql(u8, format, "deepseek")) return;
    if (std.mem.eql(u8, format, "deepseek-legacy")) return;
    if (std.mem.eql(u8, format, "none")) return;
    return error.InvalidConfigValue;
}

fn defaultReasoningBudget(effort: []const u8) !isize {
    if (std.mem.eql(u8, effort, "off")) return 0;
    if (std.mem.eql(u8, effort, "low")) return 256;
    if (std.mem.eql(u8, effort, "medium")) return 1024;
    if (std.mem.eql(u8, effort, "high")) return 4096;
    if (std.mem.eql(u8, effort, "extra-high")) return -1;
    return error.InvalidConfigValue;
}

fn requestTokenLimit(visible_tokens: usize, thought_tokens: isize) !?usize {
    if (thought_tokens < 0) return null;
    return visible_tokens + @as(usize, @intCast(thought_tokens));
}

fn compileGraphFile(allocator: Allocator, graph_path: []const u8, out_path: []const u8, home: []const u8) !void {
    const text = try graph.readLinkedText(allocator, graph_path);
    defer allocator.free(text);
    try graph.validateText(text);

    const assistant_resource = graph.findAgentWithTools(text) orelse return error.InvalidCircuitryGraph;
    const assistant_identity = try graph.resourceIdentity(allocator, text, assistant_resource);
    defer allocator.free(assistant_identity);
    const instructions = try graph.extractResourceInstructions(allocator, text, assistant_resource);
    defer allocator.free(instructions);
    const focused_recovery_resource = try graph.findFirstAgentInput(allocator, text, assistant_resource) orelse return error.InvalidCircuitryGraph;
    defer allocator.free(focused_recovery_resource);
    const focused_recovery_identity = try graph.resourceIdentity(allocator, text, focused_recovery_resource);
    defer allocator.free(focused_recovery_identity);
    const focused_recovery_instructions = try graph.extractResourceInstructions(allocator, text, focused_recovery_resource);
    defer allocator.free(focused_recovery_instructions);
    const focused_recovery_tools = try graph.readTools(allocator, text, focused_recovery_resource);
    defer graph.freeStringList(allocator, focused_recovery_tools);
    for (focused_recovery_tools) |tool| if (!tool_registry.contains(tool)) return error.UnknownTool;
    const model_id = try config.resolveGraphModelId(allocator, text, home);
    defer allocator.free(model_id);
    const model_alias = try config.readModelValue(allocator, home, model_id, "alias");
    defer allocator.free(model_alias);
    const model_temperature = try config.readModelF64Default(allocator, home, model_id, "runtime.temperature", 0.5);
    const visible_tokens = try config.readModelUsizeDefault(allocator, home, model_id, "runtime.max_tokens", 1024);
    const tool_format = try config.readModelStringDefault(allocator, home, model_id, "runtime.tool_format", "openai");
    defer allocator.free(tool_format);
    try validateToolFormat(tool_format);
    const reasoning_effort = try config.readModelStringDefault(allocator, home, model_id, "runtime.reasoning_effort", "off");
    defer allocator.free(reasoning_effort);
    try validateReasoningEffort(reasoning_effort);
    const reasoning_format = try config.readModelStringDefault(allocator, home, model_id, "runtime.reasoning_format", "auto");
    defer allocator.free(reasoning_format);
    try validateReasoningFormat(reasoning_format);
    const budget_key = try std.fmt.allocPrint(allocator, "runtime.budgets.{s}", .{reasoning_effort});
    defer allocator.free(budget_key);
    const thought_tokens = try config.readModelIsizeDefault(allocator, home, model_id, budget_key, try defaultReasoningBudget(reasoning_effort));
    const request_token_limit = try requestTokenLimit(visible_tokens, thought_tokens);
    const tool_reasoning = try config.readModelBoolDefault(allocator, home, model_id, "runtime.tool_reasoning", false);
    const tools = try graph.readTools(allocator, text, assistant_resource);
    defer graph.freeStringList(allocator, tools);
    for (tools) |tool| if (!tool_registry.contains(tool)) return error.UnknownTool;
    const reasoning_tokens = if (!std.mem.eql(u8, reasoning_effort, "off") and (tools.len == 0 or tool_reasoning)) thought_tokens else 0;

    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(allocator);
    try prompt.print(allocator,
        \\Identity: {s}
        \\Instructions:
        \\{s}
        \\
        \\Output:
        \\Answer naturally in plain text. Use tool calls instead of guessing when current state matters.
    , .{ assistant_identity, instructions });
    if (graph.wantsCircuitryPrompt(text, tools)) {
        const pack = try config.readPromptPack(allocator, home, "circuitry-author.md");
        defer allocator.free(pack);
        try prompt.print(allocator, "\n\nCircuitry authoring knowledge:\n{s}", .{pack});
    }

    const prompt_packs = try graph.readPromptPacks(allocator, text);
    defer graph.freePromptPacks(allocator, prompt_packs);
    if (prompt_packs.len != 0) {
        try prompt.appendSlice(allocator, "\n\nAvailable prompt packs. These are optional runtime guides; load one only when useful by calling read with path `prompt:<id>`.");
        for (prompt_packs) |pack| try prompt.print(allocator, "\n- {s}: {s} — {s} (load: read {{\"path\":\"prompt:{s}\"}})", .{ pack.id, pack.title, pack.description, pack.id });
    }

    var focused_recovery_prompt: std.ArrayList(u8) = .empty;
    defer focused_recovery_prompt.deinit(allocator);
    try focused_recovery_prompt.print(allocator,
        \\Identity: {s}
        \\Instructions:
        \\{s}
    , .{ focused_recovery_identity, focused_recovery_instructions });

    var compiled: std.ArrayList(u8) = .empty;
    defer compiled.deinit(allocator);
    try compiled.appendSlice(allocator, "{\"version\":1,\"model\":{\"id\":");
    try files.appendJsonString(allocator, &compiled, model_id);
    try compiled.appendSlice(allocator, ",\"alias\":");
    try files.appendJsonString(allocator, &compiled, model_alias);
    const context_tokens = try config.readModelUsizeDefault(allocator, home, model_id, "fit_ctx", visible_tokens);
    try compiled.print(allocator, ",\"temperature\":{d},\"max_tokens\":", .{model_temperature});
    if (request_token_limit) |max_tokens| try compiled.print(allocator, "{d}", .{max_tokens}) else try compiled.appendSlice(allocator, "null");
    try compiled.print(allocator, ",\"context_tokens\":{d}", .{context_tokens});
    try compiled.appendSlice(allocator, ",\"tool_format\":");
    try files.appendJsonString(allocator, &compiled, tool_format);
    try compiled.appendSlice(allocator, ",\"reasoning_format\":");
    try files.appendJsonString(allocator, &compiled, reasoning_format);
    try compiled.print(allocator, ",\"reasoning_tokens\":{d}", .{reasoning_tokens});
    try compiled.appendSlice(allocator, "},\"tools\":[");
    for (tools, 0..) |tool, i| {
        if (i != 0) try compiled.append(allocator, ',');
        try files.appendJsonString(allocator, &compiled, tool);
    }
    try compiled.appendSlice(allocator, "],\"focused_recovery_tools\":[");
    for (focused_recovery_tools, 0..) |tool, i| {
        if (i != 0) try compiled.append(allocator, ',');
        try files.appendJsonString(allocator, &compiled, tool);
    }
    try compiled.appendSlice(allocator, "],\"prompt\":");
    try files.appendJsonString(allocator, &compiled, prompt.items);
    try compiled.appendSlice(allocator, ",\"focused_recovery_prompt\":");
    try files.appendJsonString(allocator, &compiled, focused_recovery_prompt.items);
    try compiled.appendSlice(allocator, ",\"prompts\":[");
    for (prompt_packs, 0..) |pack, i| {
        if (i != 0) try compiled.append(allocator, ',');
        try compiled.appendSlice(allocator, "{\"id\":");
        try files.appendJsonString(allocator, &compiled, pack.id);
        try compiled.appendSlice(allocator, ",\"title\":");
        try files.appendJsonString(allocator, &compiled, pack.title);
        try compiled.appendSlice(allocator, ",\"description\":");
        try files.appendJsonString(allocator, &compiled, pack.description);
        const content = try resolvePromptPackContent(allocator, home, pack);
        defer allocator.free(content);
        try compiled.appendSlice(allocator, ",\"content\":");
        try files.appendJsonString(allocator, &compiled, content);
        try compiled.append(allocator, '}');
    }
    try compiled.appendSlice(allocator, "],\"expect\":{\"response\":\"str\"}}");
    try files.write(out_path, compiled.items);
}
