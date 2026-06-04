const std = @import("std");
const model = @import("../model/mod.zig");
const approval = @import("../tools/approval.zig");
const ctxmod = @import("context.zig");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const config = @import("../config/mod.zig");
const graph = @import("mod.zig");
const packages = @import("../packages/mod.zig");
const platform = @import("../platform.zig");
const provider = @import("../model/provider.zig");
const runtime_tools = @import("../tools/schema.zig");
const sessions = @import("../session/mod.zig");
const tool_exec = @import("../tools/mod.zig");
const uri = @import("../io/uri.zig");

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

pub fn contentTypeFromPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    return "application/octet-stream";
}

pub fn resolve(ctx: *RunContext, id: []const u8) anyerror!ResolvedValue {
    if (runtimeInputName(id)) |name| return resolveBoundInput(ctx, name);
    const res = graph.resource(ctx.graph.*, id) orelse return error.InvalidCircuitryGraph;
    const kind = graph.resourceType(res) orelse return error.InvalidCircuitryGraph;
    if (std.mem.eql(u8, kind, "text") or std.mem.eql(u8, kind, "data") or std.mem.eql(u8, kind, "file")) return resolveText(ctx, res);
    if (std.mem.eql(u8, kind, "run")) return resolveRun(ctx, res);
    if (std.mem.eql(u8, kind, "model")) return resolveModel(ctx, id, res);
    return error.UnsupportedResourceType;
}

pub fn runChildGraph(ctx: *RunContext, graph_path: []const u8, selected_export: ?[]const u8, inputs: []const BoundInput) !ResolvedValue {
    const child_graph = try graph.load(ctx.allocator, ctx.io, graph_path);
    defer child_graph.deinit(ctx.allocator);
    try graph.validate(child_graph);
    const target = graph.exportTargetResourceId(child_graph, selected_export) orelse return error.InvalidCircuitryGraph;
    var child_ctx = RunContext{ .allocator = ctx.allocator, .io = ctx.io, .layout_ctx = ctx.layout_ctx, .home = ctx.home, .profile = ctx.profile, .graph_path = graph_path, .graph = &child_graph, .session = ctx.session, .log = ctx.log, .inputs = inputs, .frame = ctx.frame.child(target), .bash_allowances = ctx.bash_allowances };
    return resolve(&child_ctx, target);
}

fn resolveBoundInput(ctx: *RunContext, name: []const u8) !ResolvedValue {
    const input = findBoundInput(ctx.inputs, name) orelse return error.MissingRequiredGraphInput;
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
        if (input_map.* != .mapping) return error.InvalidCircuitryGraph;
        var iter = input_map.mapping.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.InvalidCircuitryGraph;
            const parent_id = try graph.qualifyDependency(ctx.allocator, res, entry.value_ptr.string);
            defer ctx.allocator.free(parent_id);
            const parent_value = try resolve(ctx, parent_id);
            defer parent_value.deinit(ctx.allocator);
            try child_inputs.append(ctx.allocator, .{ .id = try ctx.allocator.dupe(u8, entry.key_ptr.*), .kind = .text, .value = try ctx.allocator.dupe(u8, parent_value.text), .content_type = try ctx.allocator.dupe(u8, "text/plain") });
        }
    }
    defer freeBoundInputs(ctx.allocator, child_inputs.items);
    return runChildGraph(ctx, child_path, graph.resourceField(res, "export"), child_inputs.items);
}

fn resolveModel(ctx: *RunContext, id: []const u8, res: graph.Resource) !ResolvedValue {
    if (graph.resourceField(res, "using")) |model_id| if (!std.mem.eql(u8, model_id, ctx.profile.model.id)) {
        var profile = try config.loadRuntimeProfile(ctx.allocator, ctx.io, ctx.layout_ctx, model_id);
        defer profile.deinit(ctx.allocator);
        var model_ctx = ctx.*;
        model_ctx.profile = &profile;
        return resolveModelWithProfile(&model_ctx, id, res);
    };
    return resolveModelWithProfile(ctx, id, res);
}

fn resolveModelWithProfile(ctx: *RunContext, id: []const u8, res: graph.Resource) !ResolvedValue {
    const identity = try graph.resourceIdentity(ctx.allocator, ctx.graph.*, id);
    defer ctx.allocator.free(identity);
    const instructions = try graph.extractResourceInstructions(ctx.allocator, ctx.graph.*, id);
    defer ctx.allocator.free(instructions);
    const tool_names = try graph.readTools(ctx.allocator, ctx.graph.*, id);
    defer graph.freeStringList(ctx.allocator, tool_names);
    for (tool_names) |tool| {
        if (runtime_tools.contains(tool)) continue;
        if (try packages.findTool(ctx.allocator, ctx.io, ctx.layout_ctx, tool)) |package_tool| {
            package_tool.deinit(ctx.allocator);
            continue;
        }
        std.debug.print("error: unknown Zinc tool declared by active model: {s}\n", .{tool});
        return error.UserError;
    }
    const tools_json = try providerToolsJson(ctx, tool_names);
    defer ctx.allocator.free(tools_json);

    var system: std.ArrayList(u8) = .empty;
    defer system.deinit(ctx.allocator);
    try system.print(ctx.allocator, "Identity: {s}\n\n{s}", .{ identity, instructions });
    try appendToolPromptSections(ctx, &system, tool_names);
    if (hasTool(tool_names, "read")) {
        const catalog = try runtimeUriCatalog(ctx.allocator);
        defer ctx.allocator.free(catalog);
        try system.print(ctx.allocator, "\n\n{s}", .{catalog});
    }

    const inputs = try graph.resourceInputsList(ctx.allocator, res);
    defer graph.freeStringList(ctx.allocator, inputs);
    var model_inputs = try collectModelInputs(ctx, res, inputs);
    defer model_inputs.deinit(ctx.allocator);

    var messages: std.ArrayList(provider.Message) = .empty;
    defer messages.deinit(ctx.allocator);
    defer provider.freeMessages(ctx.allocator, messages.items);
    try provider.appendMessage(ctx.allocator, &messages, .{ .role = "system", .content = system.items });

    const is_root = ctx.frame.isInteractiveTarget(id);
    if (is_root) try ctx.log.appendReplayMessages(ctx.allocator, &messages, "", ctx.profile.runtime.session_head_messages, ctx.profile.runtime.session_tail_messages, ctx.profile.runtime.replay_truncate_chars);

    const user_content = try modelUserContent(ctx.allocator, model_inputs.items.items);
    defer ctx.allocator.free(user_content);
    try provider.appendMessage(ctx.allocator, &messages, .{ .role = "user", .content = user_content, .parts = model_inputs.parts.items });
    if (is_root) {
        const session_content = sessionUserContent(ctx, user_content);
        try sessions.appendUserMessage(ctx.allocator, ctx.session.path, session_content);
        try sessions.rememberLast(ctx.session);
    }

    const reasoning_effort = ctx.profile.reasoningEffort();
    const schema_value = graph.resourceSchemaValue(res);
    const wants_json = schema_value != null;
    const spec = model.Spec{ .label = id, .system = system.items, .tools = tool_names, .tools_json = tools_json, .json = wants_json, .schema = schema_value, .runtime_reads = true };
    const result = try model.run(ctx, &messages, spec, reasoning_effort, executeTool);
    errdefer result.deinit(ctx.allocator);
    if (schema_value) |schema| try model.validateJsonSchema(ctx.allocator, schema, result.text) else if (wants_json) try model.validateJson(ctx.allocator, result.text);
    if (is_root) try sessions.appendAssistantText(ctx.allocator, ctx.session.path, ctx.profile.model.id, std.mem.trim(u8, result.text, " \t\r\n"), result.reasoning);
    if (result.reasoning) |value| ctx.allocator.free(value);
    return .{ .text = result.text };
}

fn executeTool(ctx: *RunContext, read_ctx: uri.Context, spec: model.Spec, call: provider.ToolCall) !runtime_tools.ToolResult {
    if (!hasTool(spec.tools, call.name)) return tool_exec.toolError(ctx.allocator, call, "UnknownTool", "no such tool is available");
    if (std.mem.eql(u8, call.name, "run_graph")) return executeRunGraph(ctx, call) catch |err| switch (err) {
        error.OutOfMemory, error.GraphRunDeniedByUser => err,
        else => tool_exec.toolError(ctx.allocator, call, @errorName(err), "graph run request failed"),
    };
    if (!runtime_tools.contains(call.name)) return executePackageTool(ctx, call) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => tool_exec.toolError(ctx.allocator, call, @errorName(err), "package tool execution failed"),
    };
    return tool_exec.execute(ctx, read_ctx, spec, call) catch |err| switch (err) {
        error.ToolNotHandled => tool_exec.toolError(ctx.allocator, call, "UnknownTool", "no such tool is available"),
        error.OutOfMemory => err,
        else => tool_exec.toolError(ctx.allocator, call, @errorName(err), "tool execution failed"),
    };
}

pub fn callPackageTool(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, name: []const u8, arguments: []const u8) !runtime_tools.ToolResult {
    const model_id = try config.resolveConfiguredModelId(allocator, io, layout_ctx);
    defer allocator.free(model_id);
    const profile = try config.loadRuntimeProfile(allocator, io, layout_ctx, model_id);
    defer profile.deinit(allocator);
    const loaded_graph = try graph.load(allocator, io, profile.paths.graph);
    defer loaded_graph.deinit(allocator);
    const session = try sessions.open(allocator, null, false);
    defer session.deinit(allocator);
    var log = try sessions.readParsed(allocator, session.path);
    defer log.deinit(allocator);
    var bash_allowances: ctxmod.BashAllowances = .empty;
    defer bash_allowances.deinit(allocator);
    var ctx = RunContext{ .allocator = allocator, .io = io, .layout_ctx = layout_ctx, .home = layout_ctx.dirs.home, .profile = &profile, .graph_path = profile.paths.graph, .graph = &loaded_graph, .session = session, .log = &log, .inputs = &.{}, .frame = .maintenance(name), .bash_allowances = &bash_allowances };
    return executePackageTool(&ctx, .{ .id = "pkg-call", .name = name, .arguments = arguments });
}

fn executePackageTool(ctx: *RunContext, call: provider.ToolCall) !runtime_tools.ToolResult {
    var tool = (try packages.findTool(ctx.allocator, ctx.io, ctx.layout_ctx, call.name)) orelse return error.UnknownTool;
    defer tool.deinit(ctx.allocator);
    try runtime_tools.validatePackageArguments(ctx.allocator, tool, call.arguments);
    return switch (tool.handler) {
        .process => |h| executeProcessTool(ctx, tool, h.command, call.arguments),
        .http => |h| executeHttpTool(ctx, h.url, h.method, call.arguments),
        .mcp => |h| executeMcpTool(ctx, tool, h.command, h.tool, call.arguments),
    };
}

fn executeProcessTool(ctx: *RunContext, tool: packages.Tool, command: []const u8, arguments: []const u8) !runtime_tools.ToolResult {
    const resolved = try platform.process.resolveCommand(ctx.allocator, ctx.io, platform.currentOS(), .{}, command, tool.package_dir);
    defer ctx.allocator.free(resolved);
    const result = try runWithInput(ctx.allocator, ctx.io, &.{resolved}, .{ .path = tool.package_dir }, arguments, 1024 * 1024);
    defer ctx.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        ctx.allocator.free(result.stdout);
        return .{ .content = try ctx.allocator.dupe(u8, result.stderr), .is_error = true };
    }
    return .{ .content = result.stdout, .is_error = false };
}

fn executeHttpTool(ctx: *RunContext, url: []const u8, method: []const u8, arguments: []const u8) !runtime_tools.ToolResult {
    var response = std.Io.Writer.Allocating.init(ctx.allocator);
    defer response.deinit();
    var client = std.http.Client{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();
    const headers = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};
    const result = try client.fetch(.{ .location = .{ .url = url }, .method = if (std.mem.eql(u8, method, "GET")) .GET else .POST, .payload = if (std.mem.eql(u8, method, "GET")) null else arguments, .extra_headers = &headers, .response_writer = &response.writer });
    return .{ .content = try ctx.allocator.dupe(u8, response.written()), .is_error = @intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300 };
}

fn executeMcpTool(ctx: *RunContext, tool: packages.Tool, command: []const u8, mcp_tool: []const u8, arguments: []const u8) !runtime_tools.ToolResult {
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(ctx.allocator);
    try input.appendSlice(ctx.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"zinc\",\"version\":\"0.4.2\"}}}\n");
    try input.appendSlice(ctx.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n");
    try input.appendSlice(ctx.allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":");
    try appendJsonString(ctx.allocator, &input, mcp_tool);
    try input.appendSlice(ctx.allocator, ",\"arguments\":");
    try input.appendSlice(ctx.allocator, arguments);
    try input.appendSlice(ctx.allocator, "}}\n");
    const resolved = try platform.process.resolveCommand(ctx.allocator, ctx.io, platform.currentOS(), .{}, command, tool.package_dir);
    defer ctx.allocator.free(resolved);
    const result = try runWithInput(ctx.allocator, ctx.io, &.{resolved}, .{ .path = tool.package_dir }, input.items, 1024 * 1024);
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.McpToolFailed;
    const response = try findJsonRpcResponse(ctx.allocator, result.stdout, 2);
    return .{ .content = response, .is_error = false };
}

fn appendJsonString(allocator: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    try std.json.Stringify.value(text, .{}, &aw.writer);
}

fn findJsonRpcResponse(allocator: Allocator, text: []const u8, id: i64) ![]u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const found_id = parsed.value.object.get("id") orelse continue;
        if (found_id != .integer or found_id.integer != id) continue;
        if (parsed.value.object.get("error") != null) return error.McpToolFailed;
        return allocator.dupe(u8, line);
    }
    return error.McpToolFailed;
}

fn runWithInput(allocator: Allocator, io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd, stdin: []const u8, limit: usize) !std.process.RunResult {
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = cwd, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(io);
    try child.stdin.?.writeStreamingAll(io, stdin);
    child.stdin.?.close(io);
    child.stdin = null;

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(allocator, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();
    const stdout_reader = multi.reader(0);
    const stderr_reader = multi.reader(1);
    while (multi.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > limit or stderr_reader.buffered().len > limit) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi.checkAnyError();
    const term = try child.wait(io);
    return .{ .term = term, .stdout = try multi.toOwnedSlice(0), .stderr = try multi.toOwnedSlice(1) };
}

fn executeRunGraph(ctx: *RunContext, call: provider.ToolCall) !runtime_tools.ToolResult {
    const decision = try approval.decide(ctx.profile.runtime.graph_runs);
    if (decision == .deny) return approval.denied(ctx.allocator);

    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, call.arguments, .{});
    defer parsed.deinit();
    const args = parsed.value.object;
    const graph_spec = try runtime_tools.requireStringArg(args, "graph");
    const graph_path = try packages.resolveGraph(ctx.allocator, ctx.io, ctx.layout_ctx, graph_spec);
    defer ctx.allocator.free(graph_path);
    const selected_export = try runtime_tools.optionalStringArg(args, "export");
    const child_graph = try graph.load(ctx.allocator, ctx.io, graph_path);
    defer child_graph.deinit(ctx.allocator);
    try graph.validate(child_graph);
    const target = graph.exportTargetResourceId(child_graph, selected_export) orelse return error.InvalidCircuitryGraph;
    const child_inputs = try inputsFromToolObject(ctx.allocator, child_graph, selected_export, args.get("inputs"));
    defer freeBoundInputs(ctx.allocator, child_inputs);

    if (decision == .ask and !try approval.prompt(ctx.allocator, call)) return error.GraphRunDeniedByUser;

    const result = try runChildGraph(ctx, graph_path, selected_export, child_inputs);
    defer result.deinit(ctx.allocator);
    return .{ .content = try approval.resultJson(ctx.allocator, graph_path, target, result.text), .is_error = false };
}

pub fn bindInputs(allocator: Allocator, loaded_graph: graph.Graph, selected_export: ?[]const u8, user_prompt: []const u8, runtime_inputs: []const graph.RuntimeInput) ![]BoundInput {
    const input_specs = try graph.readInputSpecsForExport(allocator, loaded_graph, selected_export);
    defer graph.freeInputSpecs(allocator, input_specs);
    var out: std.ArrayList(BoundInput) = .empty;
    errdefer {
        for (out.items) |input| input.deinit(allocator);
        out.deinit(allocator);
    }
    for (runtime_inputs) |input| {
        const spec = inputSpec(input_specs, input.id) orelse return error.UnknownGraphInput;
        if (!kindMatches(spec.kind, input.kind)) return error.GraphInputTypeMismatch;
        try out.append(allocator, try cloneRuntimeInput(allocator, input));
    }
    if (user_prompt.len != 0) if (inputSpec(input_specs, "user_turn")) |spec| if (!hasBoundInput(out.items, "user_turn")) {
        if (!kindMatches(spec.kind, .text)) return error.GraphInputTypeMismatch;
        try out.append(allocator, .{ .id = try allocator.dupe(u8, "user_turn"), .kind = .text, .value = try allocator.dupe(u8, user_prompt), .content_type = try allocator.dupe(u8, "text/plain") });
    };
    for (input_specs) |spec| if (spec.required and !hasBoundInput(out.items, spec.id)) return error.MissingRequiredGraphInput;
    return out.toOwnedSlice(allocator);
}

pub fn freeBoundInputs(allocator: Allocator, inputs: []const BoundInput) void {
    for (inputs) |input| input.deinit(allocator);
    allocator.free(inputs);
}

fn inputsFromToolObject(allocator: Allocator, loaded_graph: graph.Graph, selected_export: ?[]const u8, maybe_inputs: ?std.json.Value) ![]BoundInput {
    const value = maybe_inputs orelse return bindInputs(allocator, loaded_graph, selected_export, "", &.{});
    if (value != .object) return error.InvalidToolArguments;
    var runtime_inputs: std.ArrayList(graph.RuntimeInput) = .empty;
    defer runtime_inputs.deinit(allocator);
    errdefer for (runtime_inputs.items) |input| input.deinit(allocator);
    var iter = value.object.iterator();
    while (iter.next()) |entry| {
        const text = try jsonInputText(allocator, entry.value_ptr.*);
        errdefer allocator.free(text);
        try runtime_inputs.append(allocator, .{ .id = try allocator.dupe(u8, entry.key_ptr.*), .kind = .text, .value = text, .content_type = try allocator.dupe(u8, "text/plain") });
    }
    const bound = try bindInputs(allocator, loaded_graph, selected_export, "", runtime_inputs.items);
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
    return .{ .id = try allocator.dupe(u8, input.id), .kind = input.kind, .value = try allocator.dupe(u8, input.value), .content_type = try allocator.dupe(u8, input.content_type) };
}
fn runtimeInputName(raw: []const u8) ?[]const u8 {
    return if (raw.len > 1 and raw[0] == '$') raw[1..] else null;
}

fn inputSpec(input_specs: []const graph.InputSpec, id: []const u8) ?graph.InputSpec {
    for (input_specs) |input| if (std.mem.eql(u8, input.id, id)) return input;
    return null;
}
fn kindMatches(spec: []const u8, kind: graph.InputKind) bool {
    return switch (kind) {
        .text => std.mem.eql(u8, spec, "text") or std.mem.eql(u8, spec, "string"),
        .file => std.mem.eql(u8, spec, "file"),
        .image => std.mem.eql(u8, spec, "image") or std.mem.eql(u8, spec, "text") or std.mem.eql(u8, spec, "string"),
    };
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
        .context = .{ .layout_ctx = ctx.layout_ctx, .session_id = ctx.session.id, .session_path = ctx.session.path, .session_dir = std.fs.path.dirname(ctx.session.path) orelse ".zinc/sessions", .session_log = ctx.log.raw, .session_head_messages = ctx.profile.runtime.session_head_messages, .session_tail_messages = ctx.profile.runtime.session_tail_messages, .replay_truncate_chars = ctx.profile.runtime.replay_truncate_chars, .inputs = inputs },
        .inputs = inputs,
    };
}

fn sessionUserContent(ctx: *RunContext, fallback: []const u8) []const u8 {
    if (findBoundInput(ctx.inputs, "user_turn")) |input| return input.value;
    return fallback;
}

const ModelInputText = struct {
    id: []u8,
    text: []u8,

    fn deinit(self: ModelInputText, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.text);
    }
};

const ModelInputs = struct {
    items: std.ArrayList(ModelInputText) = .empty,
    parts: std.ArrayList(ModelPart) = .empty,

    fn deinit(self: *ModelInputs, allocator: Allocator) void {
        for (self.items.items) |item| item.deinit(allocator);
        self.items.deinit(allocator);
        for (self.parts.items) |part| part.deinit(allocator);
        self.parts.deinit(allocator);
    }
};

fn collectModelInputs(ctx: *RunContext, res: graph.Resource, inputs: []const []u8) !ModelInputs {
    var out = ModelInputs{};
    errdefer out.deinit(ctx.allocator);
    for (inputs) |input_id| {
        if (runtimeInputName(input_id)) |name| if (findBoundInput(ctx.inputs, name)) |input| {
            if (input.kind == .image) {
                try out.items.append(ctx.allocator, .{ .id = try ctx.allocator.dupe(u8, input_id), .text = try std.fmt.allocPrint(ctx.allocator, "[image attached: {s}]", .{input.value}) });
                try out.parts.append(ctx.allocator, .{ .image_url = try imageDataUrl(ctx, input) });
                continue;
            }
        };
        const scoped_id = try graph.qualifyDependency(ctx.allocator, res, input_id);
        defer ctx.allocator.free(scoped_id);
        const value = try resolve(ctx, scoped_id);
        try out.items.append(ctx.allocator, .{ .id = try ctx.allocator.dupe(u8, input_id), .text = value.text });
    }
    return out;
}

fn imageDataUrl(ctx: *RunContext, input: BoundInput) ![]u8 {
    if (std.mem.startsWith(u8, input.value, "data:") or std.mem.startsWith(u8, input.value, "http://") or std.mem.startsWith(u8, input.value, "https://")) return ctx.allocator.dupe(u8, input.value);
    const bytes = try files.readLimited(ctx.allocator, input.value, ctx.profile.runtime.input_file_max_bytes);
    defer ctx.allocator.free(bytes);
    const encoded = try ctx.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    defer ctx.allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return std.fmt.allocPrint(ctx.allocator, "data:{s};base64,{s}", .{ input.content_type, encoded });
}

fn modelUserContent(allocator: Allocator, inputs: []const ModelInputText) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (inputs) |input| {
        if (out.items.len != 0) try out.appendSlice(allocator, "\n\n");
        try out.print(allocator, "input {s}:\n{s}", .{ input.id, input.text });
    }
    return out.toOwnedSlice(allocator);
}

fn providerToolsJson(ctx: *RunContext, tool_names: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.append(ctx.allocator, '[');
    for (tool_names, 0..) |tool, i| {
        if (i != 0) try out.append(ctx.allocator, ',');
        if (runtime_tools.contains(tool)) {
            const one = try runtime_tools.providerToolsJson(ctx.allocator, &.{tool});
            defer ctx.allocator.free(one);
            try out.appendSlice(ctx.allocator, one[1 .. one.len - 1]);
        } else if (try packages.findTool(ctx.allocator, ctx.io, ctx.layout_ctx, tool)) |package_tool| {
            defer package_tool.deinit(ctx.allocator);
            try runtime_tools.appendPackageProviderTool(ctx.allocator, &out, package_tool);
        } else return error.UnknownTool;
    }
    try out.append(ctx.allocator, ']');
    return out.toOwnedSlice(ctx.allocator);
}

fn appendToolPromptSections(ctx: *RunContext, prompt: *std.ArrayList(u8), tool_names: []const []const u8) !void {
    if (tool_names.len == 0) return;
    try prompt.appendSlice(ctx.allocator, "\n\nTools");
    for (tool_names) |tool| {
        const snippet = if (runtime_tools.contains(tool)) runtime_tools.promptSnippet(tool) catch "available tool" else blk: {
            if (try packages.findTool(ctx.allocator, ctx.io, ctx.layout_ctx, tool)) |package_tool| {
                defer package_tool.deinit(ctx.allocator);
                break :blk package_tool.prompt;
            }
            break :blk "package tool";
        };
        try prompt.print(ctx.allocator, "\n\n- {s}: {s}", .{ tool, snippet });
    }
}
fn hasTool(tool_names: []const []const u8, name: []const u8) bool {
    for (tool_names) |tool| if (std.mem.eql(u8, tool, name)) return true;
    return false;
}

fn runtimeUriCatalog(allocator: Allocator) ![]u8 {
    return allocator.dupe(u8, "Runtime reads\n\n- session:current: current session transcript with tool calls and tool results\n- session:last: current session id and path\n- sessions:index: session file index with latest user turns\n- sessions:dir: session directory\n- input:<id>: content for bound graph inputs");
}
