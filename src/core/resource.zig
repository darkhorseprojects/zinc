const std = @import("std");
const agent = @import("agent.zig");
const approval = @import("approval.zig");
const ctxmod = @import("context.zig");
const files = @import("../sys/fs.zig");
const graph = @import("graph.zig");
const packages = @import("packages.zig");
const provider = @import("../runtime/provider.zig");
const runtime_tools = @import("../runtime/tools.zig");
const sessions = @import("../runtime/session.zig");
const tool_exec = @import("tools.zig");
const uri = @import("../runtime/uri.zig");

const Allocator = std.mem.Allocator;

pub const BoundInput = ctxmod.BoundInput;
pub const ResolvedValue = ctxmod.ResolvedValue;
pub const RunContext = ctxmod.RunContext;

pub const ModelPart = union(enum) {
    text: []u8,
    image_url: []u8,

    pub fn deinit(self: ModelPart, allocator: Allocator) void {
        switch (self) {
            .text => |text| allocator.free(text),
            .image_url => |url| allocator.free(url),
        }
    }
};

pub fn mimeFromPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    return "application/octet-stream";
}

pub fn resolve(ctx: *RunContext, id: []const u8) anyerror!ResolvedValue {
    const res = graph.resource(ctx.graph.*, id) orelse return error.InvalidCircuitryGraph;
    const kind = graph.resourceType(res) orelse return error.InvalidCircuitryGraph;
    if (std.mem.eql(u8, kind, "input")) return resolveInput(ctx, res);
    if (std.mem.eql(u8, kind, "text") or std.mem.eql(u8, kind, "data")) return resolveText(ctx, res);
    if (std.mem.eql(u8, kind, "run")) return resolveRun(ctx, res);
    if (std.mem.eql(u8, kind, "agent")) return resolveAgent(ctx, id, res);
    return error.UnsupportedResourceType;
}

pub fn runChildGraph(ctx: *RunContext, graph_path: []const u8, entry_override: ?[]const u8, inputs: []const BoundInput) !ResolvedValue {
    const child_graph = try graph.load(ctx.allocator, ctx.io, graph_path);
    defer child_graph.deinit(ctx.allocator);
    try graph.validate(child_graph);
    const child_entry = graph.entryResourceId(child_graph, entry_override) orelse return error.InvalidCircuitryGraph;
    var child_ctx = RunContext{ .allocator = ctx.allocator, .io = ctx.io, .home = ctx.home, .profile = ctx.profile, .graph_path = graph_path, .graph = &child_graph, .session = ctx.session, .log = ctx.log, .inputs = inputs, .frame = ctx.frame.child(child_entry), .bash_allowances = ctx.bash_allowances };
    return resolve(&child_ctx, child_entry);
}

fn resolveInput(ctx: *RunContext, res: graph.Resource) !ResolvedValue {
    const from = graph.resourceField(res, "from") orelse return error.InvalidCircuitryGraph;
    const input = findBoundInput(ctx.inputs, from) orelse return error.MissingRequiredGraphInput;
    return .{ .text = try readInputValue(ctx, input) };
}

fn resolveText(ctx: *RunContext, res: graph.Resource) !ResolvedValue {
    if (graph.resourceField(res, "uri")) |raw_uri| {
        const read_ctx = try runtimeReadContext(ctx);
        defer read_ctx.deinit(ctx.allocator);
        const maybe = try uri.resolve(ctx.allocator, ctx.io, read_ctx.context, raw_uri);
        if (maybe) |text| return .{ .text = text };
        std.debug.print("error: unsupported Zinc URI: {s}\n", .{raw_uri});
        return error.UserError;
    }
    if (try graph.resourcePath(ctx.allocator, res)) |path| {
        defer ctx.allocator.free(path);
        return .{ .text = try files.readLimited(ctx.allocator, path, ctx.profile.runtime.resource_read_max_bytes) };
    }
    return .{ .text = try graph.resourceTextLiteral(ctx.allocator, res) };
}

fn resolveRun(ctx: *RunContext, res: graph.Resource) !ResolvedValue {
    const child_path = try graph.resolveGraphRef(ctx.allocator, res);
    defer ctx.allocator.free(child_path);

    var child_inputs: std.ArrayList(BoundInput) = .empty;
    errdefer freeBoundInputs(ctx.allocator, child_inputs.items);
    if (graph.resourceInputMapValue(res)) |input_map| {
        var iter = input_map.object.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.InvalidCircuitryGraph;
            const parent_value = try resolve(ctx, entry.value_ptr.string);
            defer parent_value.deinit(ctx.allocator);
            try child_inputs.append(ctx.allocator, .{ .id = try ctx.allocator.dupe(u8, entry.key_ptr.*), .kind = .text, .value = try ctx.allocator.dupe(u8, parent_value.text), .mime = try ctx.allocator.dupe(u8, "text/plain") });
        }
    }
    defer freeBoundInputs(ctx.allocator, child_inputs.items);
    return runChildGraph(ctx, child_path, graph.resourceField(res, "entry"), child_inputs.items);
}

fn resolveAgent(ctx: *RunContext, id: []const u8, res: graph.Resource) !ResolvedValue {
    const identity = try graph.resourceIdentity(ctx.allocator, ctx.graph.*, id);
    defer ctx.allocator.free(identity);
    const instructions = try graph.extractResourceInstructions(ctx.allocator, ctx.graph.*, id);
    defer ctx.allocator.free(instructions);
    const tool_names = try graph.readTools(ctx.allocator, ctx.graph.*, id);
    defer graph.freeStringList(ctx.allocator, tool_names);
    for (tool_names) |tool| {
        if (!runtime_tools.contains(tool)) {
            std.debug.print("error: unsupported Zinc tool declared by graph: {s}\n", .{tool});
            return error.UserError;
        }
    }
    const tools_json = try runtime_tools.schemaJson(ctx.allocator, tool_names);
    defer ctx.allocator.free(tools_json);

    var system: std.ArrayList(u8) = .empty;
    defer system.deinit(ctx.allocator);
    try system.print(ctx.allocator, "Identity: {s}\n\n{s}", .{ identity, instructions });
    try appendToolPromptSections(ctx.allocator, &system, tool_names);
    const catalog = try runtimeUriCatalog(ctx.allocator);
    defer ctx.allocator.free(catalog);
    try system.print(ctx.allocator, "\n\n{s}", .{catalog});

    const inputs = try graph.resourceInputsList(ctx.allocator, res);
    defer graph.freeStringList(ctx.allocator, inputs);
    var input_texts: std.ArrayList([]u8) = .empty;
    defer {
        for (input_texts.items) |text| ctx.allocator.free(text);
        input_texts.deinit(ctx.allocator);
    }
    for (inputs) |input_id| {
        const value = try resolve(ctx, input_id);
        try input_texts.append(ctx.allocator, value.text);
    }

    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(ctx.allocator);
    defer provider.freeMessages(ctx.allocator, messages.items);
    try provider.appendMessage(ctx.allocator, &messages, .{ .role = "system", .content = system.items });

    const is_root = ctx.frame.isInteractiveEntry(id);
    if (is_root) try ctx.log.appendReplayMessages(ctx.allocator, &messages, "", ctx.profile.runtime.session_head_messages, ctx.profile.runtime.session_tail_messages, ctx.profile.runtime.replay_truncate_chars);

    const user_content = try agentUserContent(ctx.allocator, inputs, input_texts.items);
    defer ctx.allocator.free(user_content);
    try provider.appendMessage(ctx.allocator, &messages, .{ .role = "user", .content = user_content });
    if (is_root) {
        const session_content = sessionUserContent(ctx, user_content);
        try sessions.appendUserMessage(ctx.allocator, ctx.session.path, session_content);
        try sessions.rememberLast(ctx.session);
    }

    const reasoning = try reasoningTokens(ctx.*);
    const max_tokens = maxTokens(ctx.*, reasoning);
    const wants_json = graph.resourceOutputValue(res) != null;
    const spec = agent.Spec{ .label = id, .system = system.items, .tools = tool_names, .tools_json = tools_json, .json = wants_json, .runtime_reads = true };
    const text = try agent.run(ctx, &messages, spec, max_tokens, reasoningBudget(reasoning), executeTool);
    errdefer ctx.allocator.free(text);
    if (wants_json) try agent.validateJson(ctx.allocator, text);
    if (is_root) try sessions.appendAssistantText(ctx.allocator, ctx.session.path, std.mem.trim(u8, text, " \t\r\n"));
    return .{ .text = text };
}

fn executeTool(ctx: *RunContext, read_ctx: uri.Context, spec: agent.Spec, call: provider.ToolCall) !runtime_tools.ToolResult {
    if (std.mem.eql(u8, call.name, "run_graph")) return executeRunGraph(ctx, call) catch |err| switch (err) {
        error.OutOfMemory, error.GraphRunDeniedByUser => err,
        else => tool_exec.toolError(ctx.allocator, call, @errorName(err), "graph run request failed"),
    };
    return tool_exec.execute(ctx, read_ctx, spec, call) catch |err| switch (err) {
        error.ToolNotHandled => tool_exec.toolError(ctx.allocator, call, "ToolNotExecutable", "tool has no runtime execution path"),
        error.OutOfMemory => err,
        else => tool_exec.toolError(ctx.allocator, call, @errorName(err), "tool execution failed"),
    };
}

fn executeRunGraph(ctx: *RunContext, call: provider.ToolCall) !runtime_tools.ToolResult {
    const decision = try approval.decide(ctx.profile.runtime.graph_runs);
    if (decision == .deny) return approval.denied(ctx.allocator);

    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, call.arguments, .{});
    defer parsed.deinit();
    const args = parsed.value.object;
    const graph_spec = try runtime_tools.requireStringArg(args, "graph");
    const graph_path = try packages.resolveGraph(ctx.allocator, ctx.io, ctx.home, graph_spec);
    defer ctx.allocator.free(graph_path);
    const entry_override = try runtime_tools.optionalStringArg(args, "entry");
    const child_graph = try graph.load(ctx.allocator, ctx.io, graph_path);
    defer child_graph.deinit(ctx.allocator);
    try graph.validate(child_graph);
    const child_entry = graph.entryResourceId(child_graph, entry_override) orelse return error.InvalidCircuitryGraph;
    const child_inputs = try inputsFromToolObject(ctx.allocator, child_graph, args.get("inputs"));
    defer freeBoundInputs(ctx.allocator, child_inputs);

    if (decision == .ask and !try approval.prompt(ctx.allocator, call)) return error.GraphRunDeniedByUser;

    const result = try runChildGraph(ctx, graph_path, entry_override, child_inputs);
    defer result.deinit(ctx.allocator);
    return .{ .content = try approval.resultJson(ctx.allocator, graph_path, child_entry, result.text), .is_error = false };
}

pub fn bindInputs(allocator: Allocator, loaded_graph: graph.Graph, user_prompt: []const u8, runtime_inputs: []const graph.RuntimeInput) ![]BoundInput {
    var out: std.ArrayList(BoundInput) = .empty;
    errdefer {
        for (out.items) |input| input.deinit(allocator);
        out.deinit(allocator);
    }
    for (runtime_inputs) |input| {
        const spec = inputSpec(loaded_graph, input.id) orelse return error.UnknownGraphInput;
        if (!kindMatches(spec.kind, input.kind)) return error.GraphInputTypeMismatch;
        try out.append(allocator, try cloneRuntimeInput(allocator, input));
    }
    if (user_prompt.len != 0) if (inputSpec(loaded_graph, "user_turn")) |spec| if (!hasBoundInput(out.items, "user_turn")) {
        if (!std.mem.eql(u8, spec.kind, "text")) return error.GraphInputTypeMismatch;
        try out.append(allocator, .{ .id = try allocator.dupe(u8, "user_turn"), .kind = .text, .value = try allocator.dupe(u8, user_prompt), .mime = try allocator.dupe(u8, "text/plain") });
    };
    for (loaded_graph.inputs) |spec| if (spec.required and !hasBoundInput(out.items, spec.id)) return error.MissingRequiredGraphInput;
    return out.toOwnedSlice(allocator);
}

pub fn freeBoundInputs(allocator: Allocator, inputs: []const BoundInput) void {
    for (inputs) |input| input.deinit(allocator);
    allocator.free(inputs);
}

fn inputsFromToolObject(allocator: Allocator, loaded_graph: graph.Graph, maybe_inputs: ?std.json.Value) ![]BoundInput {
    const value = maybe_inputs orelse return bindInputs(allocator, loaded_graph, "", &.{});
    if (value != .object) return error.InvalidToolArguments;
    var runtime_inputs: std.ArrayList(graph.RuntimeInput) = .empty;
    defer runtime_inputs.deinit(allocator);
    errdefer for (runtime_inputs.items) |input| input.deinit(allocator);
    var iter = value.object.iterator();
    while (iter.next()) |entry| {
        const text = try jsonInputText(allocator, entry.value_ptr.*);
        errdefer allocator.free(text);
        try runtime_inputs.append(allocator, .{ .id = try allocator.dupe(u8, entry.key_ptr.*), .kind = .text, .value = text, .mime = try allocator.dupe(u8, "text/plain") });
    }
    const bound = try bindInputs(allocator, loaded_graph, "", runtime_inputs.items);
    for (runtime_inputs.items) |input| input.deinit(allocator);
    return bound;
}

fn jsonInputText(allocator: Allocator, value: std.json.Value) ![]u8 {
    if (value == .string) return allocator.dupe(u8, value.string);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    defer out = aw.toArrayList();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    return out.toOwnedSlice(allocator);
}

fn cloneRuntimeInput(allocator: Allocator, input: graph.RuntimeInput) !BoundInput {
    return .{ .id = try allocator.dupe(u8, input.id), .kind = input.kind, .value = try allocator.dupe(u8, input.value), .mime = try allocator.dupe(u8, input.mime) };
}
fn inputSpec(loaded_graph: graph.Graph, id: []const u8) ?graph.InputSpec {
    for (loaded_graph.inputs) |input| if (std.mem.eql(u8, input.id, id)) return input;
    return null;
}
fn kindMatches(spec: []const u8, kind: graph.InputKind) bool {
    return std.mem.eql(u8, spec, switch (kind) {
        .text => "text",
        .file => "file",
        .image => "image",
    });
}
fn hasBoundInput(inputs: []const BoundInput, id: []const u8) bool {
    for (inputs) |input| if (std.mem.eql(u8, input.id, id)) return true;
    return false;
}
fn findBoundInput(inputs: []const BoundInput, id: []const u8) ?BoundInput {
    for (inputs) |input| if (std.mem.eql(u8, input.id, id)) return input;
    return null;
}
fn readInputValue(ctx: *RunContext, input: BoundInput) ![]u8 {
    if (input.kind == .text and std.mem.startsWith(u8, input.value, "@")) return files.readLimited(ctx.allocator, input.value[1..], ctx.profile.runtime.input_text_file_max_bytes);
    if (input.kind == .text) return ctx.allocator.dupe(u8, input.value);
    if (input.kind == .file) return files.readLimited(ctx.allocator, input.value, ctx.profile.runtime.input_file_max_bytes);
    return error.GraphInputNotReadable;
}

fn runtimeReadContext(ctx: *RunContext) !ctxmod.RuntimeReadContext {
    const inputs = try ctx.allocator.alloc(uri.Input, ctx.inputs.len);
    for (ctx.inputs, 0..) |input, i| inputs[i] = .{ .id = input.id, .value = input.value };
    return .{
        .context = .{ .home = ctx.home, .session_id = ctx.session.id, .session_path = ctx.session.path, .session_dir = std.fs.path.dirname(ctx.session.path) orelse ".zinc/sessions", .session_log = ctx.log.raw, .session_head_messages = ctx.profile.runtime.session_head_messages, .session_tail_messages = ctx.profile.runtime.session_tail_messages, .replay_truncate_chars = ctx.profile.runtime.replay_truncate_chars, .inputs = inputs },
        .inputs = inputs,
    };
}

fn sessionUserContent(ctx: *RunContext, fallback: []const u8) []const u8 {
    if (findBoundInput(ctx.inputs, "user_turn")) |input| return input.value;
    return fallback;
}

fn agentUserContent(allocator: Allocator, input_ids: []const []u8, input_texts: []const []u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input_texts, 0..) |text, i| {
        if (out.items.len != 0) try out.appendSlice(allocator, "\n\n");
        try out.print(allocator, "input {s}:\n{s}", .{ input_ids[i], text });
    }
    return out.toOwnedSlice(allocator);
}

fn reasoningTokens(ctx: RunContext) !isize {
    return switch (ctx.frame.kind) {
        .maintenance, .interactive, .graph_run => ctx.profile.reasoningTokens(true),
    };
}

fn maxTokens(ctx: RunContext, reasoning: isize) ?usize {
    return switch (ctx.frame.kind) {
        .maintenance => ctx.profile.runtime.compaction_max_tokens,
        .interactive, .graph_run => ctx.profile.requestTokenLimit(reasoning),
    };
}

fn appendToolPromptSections(allocator: Allocator, prompt: *std.ArrayList(u8), tool_names: []const []const u8) !void {
    if (tool_names.len == 0) return;
    try prompt.appendSlice(allocator, "\n\nTools");
    for (tool_names) |tool| try prompt.print(allocator, "\n\n- {s}: {s}", .{ tool, runtime_tools.promptSnippet(tool) catch "available tool" });
}
fn runtimeUriCatalog(allocator: Allocator) ![]u8 {
    return allocator.dupe(u8, "Runtime reads\n\n- session:current: current session transcript with tool calls and tool results\n- session:last: current session id and path\n- sessions:index: session file index with latest user turns\n- sessions:dir: session directory\n- input:<id>: content for bound graph inputs");
}
fn reasoningBudget(tokens: isize) ?usize {
    return if (tokens < 0) null else @intCast(tokens);
}
