const std = @import("std");
const root = @import("../root.zig");
const sys = root.sys;
const core = root.core;
const runtime = root.runtime;

const compaction = core.compaction;
const config = runtime.config;
const engine = core.engine;
const files = sys.fs;
const graph = core.graph;
const layout = sys.layout;
const packages = core.packages;
const plan = core.plan;
const resource = core.resource;
const sessions = runtime.session;
const tools = sys.process;
const trace = sys.trace;

const Allocator = std.mem.Allocator;

pub fn usage() void {
    std.debug.print(
        \\zn - Zinc, a tiny Circuitry-native runtime
        \\
        \\usage:
        \\  zn check [graph]
        \\  zn compile [graph] [compiled-plan]
        \\  zn clean [--local|--global] [compiled | plan | sessions | logs | packages | state | all]
        \\  zn serve [model-id]
        \\  zn stop
        \\  zn status
        \\  zn config get <path>
        \\  zn compact [--dry-run] [--session id|--continue] [graph]
        \\  zn update [--ref tag-or-commit] [--skip-packages] [--skip-zinc]
        \\  zn [--session id|--continue] <prompt>
        \\  zn run [--graph id|path] [--input name=value] [--text name=value|@file] [--file name=path] [--image name=path] [--session id|--continue] <prompt>
        \\  zn graph list
        \\  zn pkg list
        \\  zn pkg add [--local|--global] [--replace] <source>
        \\  zn pkg remove [--local|--global] <name>
        \\  zn pkg update [--local|--global] <name>
        \\  zn pkg show [--local|--global] <name>
        \\  zn session-dir
        \\
    , .{});
}

pub fn validate(allocator: Allocator, io: std.Io, home: []const u8, path_arg: ?[]const u8) !void {
    const runtime_paths = try config.loadRuntimePaths(allocator, io, home);
    defer runtime_paths.deinit(allocator);
    const path = if (path_arg) |spec| try packages.resolveGraph(allocator, io, home, spec) else try allocator.dupe(u8, runtime_paths.graph);
    defer allocator.free(path);
    try validateGraphFile(allocator, io, path);
    std.debug.print("ok: {s}\n", .{path});
}

pub fn compile(allocator: Allocator, io: std.Io, home: []const u8, graph_arg: ?[]const u8, out_arg: ?[]const u8) !void {
    const runtime_paths = try config.loadRuntimePaths(allocator, io, home);
    defer runtime_paths.deinit(allocator);
    const graph_path = if (graph_arg) |spec| try packages.resolveGraph(allocator, io, home, spec) else try allocator.dupe(u8, runtime_paths.graph);
    defer allocator.free(graph_path);
    const out = out_arg orelse runtime_paths.compiled_plan;
    try compileLoopGraphFile(allocator, io, graph_path, out, home);
    std.debug.print("compiled: {s} -> {s}\n", .{ graph_path, out });
}

pub fn runFromArgs(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    const run_span = trace.span("run");
    defer run_span.end("command", "args={d}", .{args.len});
    trace.event("command", "start", "args={d}", .{args.len});

    var parsed_args = try parseRunArgs(allocator, args);
    defer parsed_args.deinit(allocator);
    if (parsed_args.prompt_parts.items.len == 0 and parsed_args.inputs.items.len == 0) return usage();

    const runtime_paths_span = trace.span("runtime_paths");
    const runtime_paths = try config.loadRuntimePaths(allocator, io, home);
    runtime_paths_span.end("config", "graph={s}", .{runtime_paths.graph});
    defer runtime_paths.deinit(allocator);
    const resolved_graph = if (parsed_args.graph_path) |spec| try packages.resolveGraph(allocator, io, home, spec) else try allocator.dupe(u8, runtime_paths.graph);
    defer allocator.free(resolved_graph);
    try compileLoopGraphFile(allocator, io, resolved_graph, runtime_paths.compiled_plan, home);

    const prompt = try std.mem.join(allocator, " ", parsed_args.prompt_parts.items);
    defer allocator.free(prompt);
    try engine.run(allocator, io, home, prompt, parsed_args.resume_id, parsed_args.continue_last, runtime_paths.compiled_plan, parsed_args.inputs.items);
}

const RunArgs = struct {
    prompt_parts: std.ArrayList([]const u8),
    inputs: std.ArrayList(plan.RuntimeInput),
    graph_path: ?[]const u8 = null,
    resume_id: ?[]const u8 = null,
    continue_last: bool = false,

    fn deinit(self: *RunArgs, allocator: Allocator) void {
        self.prompt_parts.deinit(allocator);
        for (self.inputs.items) |input| input.deinit(allocator);
        self.inputs.deinit(allocator);
    }
};

fn parseRunArgs(allocator: Allocator, args: []const []const u8) !RunArgs {
    var parsed = RunArgs{ .prompt_parts = .empty, .inputs = .empty };
    errdefer parsed.deinit(allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--continue")) {
            if (parsed.resume_id != null) return error.ConflictingSessionFlags;
            parsed.continue_last = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--session")) {
            if (parsed.continue_last or parsed.resume_id != null) return error.ConflictingSessionFlags;
            i += 1;
            if (i >= args.len) return error.MissingSessionId;
            parsed.resume_id = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--graph")) {
            i += 1;
            if (i >= args.len) return error.MissingGraphPath;
            parsed.graph_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "--text") or std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "--image")) {
            const kind = inputFlagKind(arg);
            i += 1;
            if (i >= args.len) return error.MissingRunInput;
            try appendInputArg(allocator, &parsed.inputs, kind, args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--graph=")) {
            parsed.graph_path = arg["--graph=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--input=") or std.mem.startsWith(u8, arg, "--text=") or std.mem.startsWith(u8, arg, "--file=") or std.mem.startsWith(u8, arg, "--image=")) {
            const eq = std.mem.indexOfScalar(u8, arg, '=') orelse unreachable;
            try appendInputArg(allocator, &parsed.inputs, inputFlagKind(arg[0..eq]), arg[eq + 1 ..]);
            continue;
        }
        if (parsed.graph_path == null and looksLikeGraphPath(arg)) {
            parsed.graph_path = arg;
            continue;
        }
        try parsed.prompt_parts.append(allocator, arg);
    }
    return parsed;
}

fn inputFlagKind(flag: []const u8) plan.InputKind {
    if (std.mem.eql(u8, flag, "--file")) return .file;
    if (std.mem.eql(u8, flag, "--image")) return .image;
    return .text;
}

fn appendInputArg(allocator: Allocator, inputs: *std.ArrayList(plan.RuntimeInput), kind: plan.InputKind, raw: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidRunInput;
    const id = raw[0..eq];
    const value = raw[eq + 1 ..];
    if (id.len == 0 or value.len == 0) return error.InvalidRunInput;
    try inputs.append(allocator, .{
        .id = try allocator.dupe(u8, id),
        .kind = kind,
        .value = try allocator.dupe(u8, value),
        .mime = try allocator.dupe(u8, if (kind == .image or kind == .file) resource.mimeFromPath(value) else "text/plain"),
    });
}

fn looksLikeGraphPath(arg: []const u8) bool {
    if (std.mem.endsWith(u8, arg, ".circuitry.yaml") or std.mem.endsWith(u8, arg, ".circuitry.yml")) return true;
    if (std.mem.endsWith(u8, arg, ".yaml") or std.mem.endsWith(u8, arg, ".yml")) {
        files.exists(arg) catch return false;
        return true;
    }
    return false;
}

pub fn compactFromArgs(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    var resume_id: ?[]const u8 = null;
    var continue_last = true;
    var dry_run = false;
    const runtime_paths = try config.loadRuntimePaths(allocator, io, home);
    defer runtime_paths.deinit(allocator);
    var graph_path: []const u8 = runtime_paths.compaction_graph;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
            continue;
        }
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

    if (dry_run) {
        try compaction.validateGraph(allocator, io, graph_path);
        std.debug.print("ok: compaction graph {s}\n", .{graph_path});
        return;
    }

    const session = try sessions.open(allocator, resume_id, continue_last);
    defer session.deinit(allocator);
    const message_count = try compaction.runGraph(allocator, io, home, session, graph_path);
    try sessions.rememberLast(session);
    std.debug.print("compacted {d} messages in session {s}\n", .{ message_count, session.id });
}

pub fn printSessionDir(_: Allocator) !void {
    try files.mkdirP(".zinc/sessions");
    std.debug.print(".zinc/sessions\n", .{});
}

pub fn graphList(allocator: Allocator, io: std.Io, home: []const u8) !void {
    const text = try packages.listGraphs(allocator, io, home);
    defer allocator.free(text);
    if (text.len == 0) std.debug.print("no graphs found\n", .{}) else std.debug.print("{s}", .{text});
}

pub fn packageList(allocator: Allocator, io: std.Io, home: []const u8) !void {
    const text = try packages.listPackages(allocator, io, home);
    defer allocator.free(text);
    if (text.len == 0) std.debug.print("no packages found\n", .{}) else std.debug.print("{s}", .{text});
}

pub fn packageAdd(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    const parsed = try parsePackageArgs(args, true);
    const source = parsed.value orelse return error.MissingPackageSource;
    var package = try packages.add(allocator, io, home, source, .{ .scope = parsed.scope orelse .local, .replace = parsed.replace });
    defer package.deinit(allocator);
    std.debug.print("added {s}: {s}\n", .{ scopeName(package.scope), package.path });
}

pub fn packageRemove(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    const parsed = try parsePackageArgs(args, false);
    const name = parsed.value orelse return error.MissingPackageName;
    var package = try packages.remove(allocator, io, home, name, parsed.scope);
    defer package.deinit(allocator);
    std.debug.print("removed {s}: {s}\n", .{ scopeName(package.scope), package.name });
}

pub fn packageUpdate(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    const parsed = try parsePackageArgs(args, false);
    const name = parsed.value orelse return error.MissingPackageName;
    var package = try packages.update(allocator, io, home, name, parsed.scope);
    defer package.deinit(allocator);
    std.debug.print("updated {s}: {s}\n", .{ scopeName(package.scope), package.path });
}

pub fn packageShow(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    const parsed = try parsePackageArgs(args, false);
    const name = parsed.value orelse return error.MissingPackageName;
    const text = try packages.show(allocator, io, home, name, parsed.scope);
    defer allocator.free(text);
    std.debug.print("{s}", .{text});
}

pub fn updateFromArgs(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    const parsed = try parseUpdateArgs(args);
    if (!parsed.skip_packages) {
        const package_log = try packages.updateAll(allocator, io, home);
        defer allocator.free(package_log);
        if (package_log.len == 0) std.debug.print("no packages installed\n", .{}) else std.debug.print("{s}", .{package_log});
    }
    if (!parsed.skip_zinc) try updateZinc(allocator, io, home, parsed.ref);
}

const UpdateArgs = struct { ref: ?[]const u8 = null, skip_packages: bool = false, skip_zinc: bool = false };

fn parseUpdateArgs(args: []const []const u8) !UpdateArgs {
    var parsed: UpdateArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--skip-packages")) {
            parsed.skip_packages = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-zinc")) {
            parsed.skip_zinc = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--ref")) {
            i += 1;
            if (i >= args.len) return error.MissingUpdateRef;
            parsed.ref = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ref=")) {
            parsed.ref = arg["--ref=".len..];
            continue;
        }
        return error.InvalidUpdateFlag;
    }
    if (parsed.skip_packages and parsed.skip_zinc) return error.NothingToUpdate;
    return parsed;
}

fn updateZinc(allocator: Allocator, io: std.Io, home: []const u8, ref: ?[]const u8) !void {
    const source_dir = try layout.sharePath(allocator, home, "source");
    defer allocator.free(source_dir);
    try files.mkdirP(std.fs.path.dirname(source_dir) orelse return error.InvalidUpdatePath);
    if (!files.existsPath(source_dir)) {
        try runCommand(allocator, io, &.{ "git", "clone", "https://github.com/darkhorseprojects/zinc.git", source_dir });
    } else {
        try runCommand(allocator, io, &.{ "git", "-C", source_dir, "fetch", "origin" });
    }
    if (ref) |r| {
        try runCommand(allocator, io, &.{ "git", "-C", source_dir, "checkout", "--detach", r });
    } else {
        try runCommand(allocator, io, &.{ "git", "-C", source_dir, "reset", "--hard", "origin/main" });
    }
    const installer = try std.fs.path.join(allocator, &.{ source_dir, "scripts/install-linux.sh" });
    defer allocator.free(installer);
    try runCommand(allocator, io, &.{installer});
    std.debug.print("updated zinc: {s}\n", .{source_dir});
}

fn runCommand(allocator: Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stderr_limit = .limited(256 * 1024),
        .stdout_limit = .limited(256 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("command failed: {s}\n{s}\n", .{ argv[0], result.stderr });
        return error.UpdateCommandFailed;
    }
}

const PackageArgs = struct { scope: ?packages.Scope = null, replace: bool = false, value: ?[]const u8 = null };

fn parsePackageArgs(args: []const []const u8, allow_replace: bool) !PackageArgs {
    var parsed: PackageArgs = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--local")) {
            parsed.scope = .local;
            continue;
        }
        if (std.mem.eql(u8, arg, "--global")) {
            parsed.scope = .global;
            continue;
        }
        if (std.mem.eql(u8, arg, "--replace")) {
            if (!allow_replace) return error.InvalidPackageFlag;
            parsed.replace = true;
            continue;
        }
        if (parsed.value != null) return error.TooManyPackageArguments;
        parsed.value = arg;
    }
    return parsed;
}

fn scopeName(scope: packages.Scope) []const u8 {
    return switch (scope) {
        .local => "local",
        .global => "global",
    };
}

pub fn configGet(allocator: Allocator, io: std.Io, home: []const u8, dotted_path: []const u8) !void {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var iter = std.mem.splitScalar(u8, dotted_path, '.');
    while (iter.next()) |part| if (part.len != 0) try parts.append(allocator, part);
    const value = try config.configGet(allocator, io, home, parts.items);
    defer allocator.free(value);
    std.debug.print("{s}\n", .{value});
}

fn resolvePromptPackContent(allocator: Allocator, io: std.Io, home: []const u8, pack: graph.PromptPack) ![]u8 {
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
    return config.readPromptPack(allocator, home, filename) catch |err| switch (err) {
        error.FileNotFound, error.ReadFailed => blk: {
            const package_prompt = try packages.resolvePrompt(allocator, io, home, id);
            defer allocator.free(package_prompt);
            break :blk try files.readLimited(allocator, package_prompt, 128 * 1024);
        },
        else => err,
    };
}

fn validateGraphFile(allocator: Allocator, io: std.Io, path: []const u8) !void {
    const loaded_graph = try graph.load(allocator, io, path);
    defer loaded_graph.deinit(allocator);
    try graph.validate(loaded_graph);
}

fn resolveGraphPath(allocator: Allocator, io: std.Io, home: []const u8, graph_path: []const u8, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "asset:")) return packages.resolveAsset(allocator, io, home, path["asset:".len..]);
    if (std.fs.path.isAbsolute(path) or std.mem.startsWith(u8, path, "data:") or std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ std.fs.path.dirname(graph_path) orelse ".", path });
}

fn appendToolPromptSections(allocator: Allocator, prompt: *std.ArrayList(u8), tool_names: []const []const u8) !void {
    if (tool_names.len == 0) return;
    try prompt.appendSlice(allocator, "\n\nTools");
    for (tool_names) |tool_name| {
        try prompt.print(allocator, "\n\n- {s}: {s}", .{ tool_name, try tools.promptSnippet(tool_name) });
    }
}

fn compileLoopGraphFile(allocator: Allocator, io: std.Io, graph_path: []const u8, out_path: []const u8, home: []const u8) !void {
    const compile_span = trace.span("compile_graph");
    defer compile_span.end("compile", "graph={s} out={s}", .{ graph_path, out_path });

    const loaded_graph = try graph.load(allocator, io, graph_path);
    defer loaded_graph.deinit(allocator);
    try graph.validate(loaded_graph);

    const assistant_resource = graph.findAgentWithTools(loaded_graph) orelse return error.InvalidCircuitryGraph;
    const assistant_identity = try graph.resourceIdentity(allocator, loaded_graph, assistant_resource);
    defer allocator.free(assistant_identity);
    const instructions = try graph.extractResourceInstructions(allocator, loaded_graph, assistant_resource);
    defer allocator.free(instructions);
    const focused_recovery_resource = try graph.findFirstAgentInput(allocator, loaded_graph, assistant_resource) orelse return error.InvalidCircuitryGraph;
    defer allocator.free(focused_recovery_resource);
    const focused_recovery_identity = try graph.resourceIdentity(allocator, loaded_graph, focused_recovery_resource);
    defer allocator.free(focused_recovery_identity);
    const focused_recovery_instructions = try graph.extractResourceInstructions(allocator, loaded_graph, focused_recovery_resource);
    defer allocator.free(focused_recovery_instructions);
    const focused_recovery_tools = try graph.readTools(allocator, loaded_graph, focused_recovery_resource);
    defer graph.freeStringList(allocator, focused_recovery_tools);
    for (focused_recovery_tools) |tool| if (!tools.contains(tool)) return error.UnknownTool;
    const model_id = try config.resolveGraphModelId(allocator, io, loaded_graph, home);
    defer allocator.free(model_id);
    const profile = try config.loadRuntimeProfile(allocator, io, home, model_id);
    defer profile.deinit(allocator);
    const model_alias = profile.model.model;
    const model_temperature = profile.model.generation.temperature;
    const tool_names = try graph.readTools(allocator, loaded_graph, assistant_resource);
    defer graph.freeStringList(allocator, tool_names);
    for (tool_names) |tool| if (!tools.contains(tool)) return error.UnknownTool;
    const reasoning_tokens = try profile.reasoningTokens(true);
    const request_token_limit = profile.requestTokenLimit(reasoning_tokens);

    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(allocator);
    try prompt.print(allocator,
        \\Identity: {s}
        \\
        \\{s}
    , .{ assistant_identity, instructions });
    try appendToolPromptSections(allocator, &prompt, tool_names);
    if (graph.wantsCircuitryPrompt(loaded_graph, tool_names)) {
        const pack = try config.readPromptPack(allocator, home, "circuitry-author.md");
        defer allocator.free(pack);
        try prompt.print(allocator, "\n\nCircuitry authoring knowledge:\n{s}", .{pack});
    }

    const prompt_packs = try graph.readPromptPacks(allocator, loaded_graph);
    defer graph.freePromptPacks(allocator, prompt_packs);
    const input_specs = try graph.readInputSpecs(allocator, loaded_graph);
    defer graph.freeInputSpecs(allocator, input_specs);
    const image_inputs = try graph.readImageInputs(allocator, loaded_graph, assistant_resource);
    defer graph.freeImageInputs(allocator, image_inputs);
    if (prompt_packs.len != 0) {
        try prompt.appendSlice(allocator, "\n\nPrompt packs");
        for (prompt_packs) |pack| try prompt.print(allocator, "\n\n- prompt:{s}: {s} — {s}", .{ pack.id, pack.title, pack.description });
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
    const context_tokens = profile.model.loader.fit_ctx;
    try compiled.print(allocator, ",\"temperature\":{d},\"max_tokens\":", .{model_temperature});
    if (request_token_limit) |max_tokens| try compiled.print(allocator, "{d}", .{max_tokens}) else try compiled.appendSlice(allocator, "null");
    try compiled.print(allocator, ",\"context_tokens\":{d}", .{context_tokens});
    try compiled.print(allocator, ",\"reasoning_tokens\":{d}", .{reasoning_tokens});
    try compiled.appendSlice(allocator, "},\"tools\":[");
    for (tool_names, 0..) |tool, i| {
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
    try compiled.appendSlice(allocator, ",\"inputs\":[");
    for (input_specs, 0..) |input, i| {
        if (i != 0) try compiled.append(allocator, ',');
        try compiled.appendSlice(allocator, "{\"id\":");
        try files.appendJsonString(allocator, &compiled, input.id);
        try compiled.appendSlice(allocator, ",\"type\":");
        try files.appendJsonString(allocator, &compiled, input.kind);
        try compiled.appendSlice(allocator, ",\"required\":");
        try compiled.appendSlice(allocator, if (input.required) "true" else "false");
        try compiled.append(allocator, '}');
    }
    try compiled.appendSlice(allocator, "],\"prompts\":[");
    for (prompt_packs, 0..) |pack, i| {
        if (i != 0) try compiled.append(allocator, ',');
        try compiled.appendSlice(allocator, "{\"id\":");
        try files.appendJsonString(allocator, &compiled, pack.id);
        try compiled.appendSlice(allocator, ",\"title\":");
        try files.appendJsonString(allocator, &compiled, pack.title);
        try compiled.appendSlice(allocator, ",\"description\":");
        try files.appendJsonString(allocator, &compiled, pack.description);
        const content = try resolvePromptPackContent(allocator, io, home, pack);
        defer allocator.free(content);
        try compiled.appendSlice(allocator, ",\"content\":");
        try files.appendJsonString(allocator, &compiled, content);
        try compiled.append(allocator, '}');
    }
    try compiled.appendSlice(allocator, "],\"image_inputs\":[");
    for (image_inputs, 0..) |image, i| {
        if (i != 0) try compiled.append(allocator, ',');
        try compiled.appendSlice(allocator, "{\"id\":");
        try files.appendJsonString(allocator, &compiled, image.id);
        const image_path = try resolveGraphPath(allocator, io, home, graph_path, image.path);
        defer allocator.free(image_path);
        try compiled.appendSlice(allocator, ",\"path\":");
        try files.appendJsonString(allocator, &compiled, image_path);
        try compiled.appendSlice(allocator, ",\"mime\":");
        try files.appendJsonString(allocator, &compiled, image.mime);
        try compiled.append(allocator, '}');
    }
    try compiled.appendSlice(allocator, "],\"expect\":{\"response\":\"str\"}}");
    try files.write(out_path, compiled.items);
}

pub fn clean(allocator: Allocator, io: std.Io, home: []const u8, scope: packages.Scope, target_str: []const u8) !void {
    const Target = enum { compiled, plan, sessions, logs, packages, state, all };
    const target = std.meta.stringToEnum(Target, target_str) orelse return error.InvalidCleanTarget;

    var dir = std.Io.Dir.cwd();

    switch (scope) {
        .local => {
            // Clean local compiled / plan
            if (target == .compiled or target == .plan or target == .all) {
                const runtime_paths = config.loadRuntimePaths(allocator, io, home) catch null;
                defer if (runtime_paths) |rp| rp.deinit(allocator);
                if (runtime_paths) |rp| {
                    if (std.fs.path.dirname(rp.compiled_plan)) |compiled_dir| {
                        dir.deleteTree(io, compiled_dir) catch |err| if (err != error.FileNotFound) return err;
                    }
                } else {
                    dir.deleteTree(io, ".zinc/compiled") catch |err| if (err != error.FileNotFound) return err;
                }
            }

            // Clean local sessions
            if (target == .sessions or target == .all) {
                dir.deleteTree(io, ".zinc/sessions") catch |err| if (err != error.FileNotFound) return err;
            }

            // Clean local logs
            if (target == .logs or target == .all) {
                dir.deleteTree(io, ".zinc/logs") catch |err| if (err != error.FileNotFound) return err;
            }

            // Clean local packages
            if (target == .packages or target == .all) {
                dir.deleteTree(io, ".zinc/packages") catch |err| if (err != error.FileNotFound) return err;
            }
        },
        .global => {
            // Clean global packages
            if (target == .packages or target == .all) {
                const global_pkgs = try layout.sharePath(allocator, home, "packages");
                defer allocator.free(global_pkgs);
                dir.deleteTree(io, global_pkgs) catch |err| if (err != error.FileNotFound) return err;
            }

            // Clean global state (PID, daemon logs, info)
            if (target == .state or target == .all) {
                const global_state = try layout.statePath(allocator, home, "");
                defer allocator.free(global_state);
                dir.deleteTree(io, global_state) catch |err| if (err != error.FileNotFound) return err;
            }
        },
    }

    std.debug.print("cleaned {s} {s} artifacts\n", .{ @tagName(scope), @tagName(target) });
}
