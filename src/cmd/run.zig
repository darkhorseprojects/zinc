const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config/mod.zig");
const engine = @import("../graph/engine.zig");
const files = @import("../io/fs.zig");
const graph = @import("../graph/mod.zig");
const packages = @import("../pkg/mod.zig");
const resource = @import("../graph/resource.zig");
const cmd = @import("mod.zig");

const Allocator = std.mem.Allocator;

pub fn runFromArgs(allocator: Allocator, io: std.Io, layout_ctx: @import("../io/layout.zig").Context, args: []const []const u8) !void {
    var parsed_args = try parseRunArgs(allocator, args);
    defer parsed_args.deinit(allocator);
    if (parsed_args.prompt_parts.items.len == 0 and parsed_args.inputs.items.len == 0 and parsed_args.graph_path == null) return cmd.usage();

    const runtime_paths = try config.loadRuntimePaths(allocator, io, layout_ctx);
    defer runtime_paths.deinit(allocator);
    if (parsed_args.graph_path == null and !parsed_args.use_default and parsed_args.prompt_parts.items.len != 0) {
        if (packages.resolveGraph(allocator, io, layout_ctx, parsed_args.prompt_parts.items[0])) |path| {
            allocator.free(path);
            parsed_args.graph_path = parsed_args.prompt_parts.orderedRemove(0);
        } else |err| switch (err) {
            error.GraphNotFound => {},
            else => return err,
        }
    }
    const resolved_graph = if (parsed_args.graph_path) |spec| packages.resolveGraph(allocator, io, layout_ctx, spec) catch |err| switch (err) {
        error.GraphNotFound => return cmd.fail("graph not found: {s}", .{spec}),
        else => return err,
    } else if (parsed_args.use_default) try allocator.dupe(u8, runtime_paths.graph) else try defaultGraphPath(allocator, runtime_paths.graph);
    defer allocator.free(resolved_graph);
    const prompt = try std.mem.join(allocator, " ", parsed_args.prompt_parts.items);
    defer allocator.free(prompt);
    try engine.runGraph(allocator, io, layout_ctx, resolved_graph, parsed_args.selected_export, parsed_args.model_id, prompt, parsed_args.resume_id, parsed_args.continue_last, parsed_args.inputs.items, .{ .reach = parsed_args.recovery_reach, .graph = parsed_args.recovery_graph });
}

const RunArgs = struct {
    prompt_parts: std.ArrayList([]const u8),
    inputs: std.ArrayList(graph.RuntimeInput),
    graph_path: ?[]const u8 = null,
    selected_export: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    resume_id: ?[]const u8 = null,
    continue_last: bool = false,
    use_default: bool = false,
    recovery_reach: ?[]const u8 = null,
    recovery_graph: ?[]const u8 = null,

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
        if (std.mem.eql(u8, arg, "--fresh")) {
            parsed.recovery_reach = "none";
            continue;
        }
        if (std.mem.eql(u8, arg, "--recover")) {
            parsed.recovery_reach = null;
            continue;
        }
        if (std.mem.eql(u8, arg, "--session-recover")) {
            parsed.recovery_reach = "session";
            continue;
        }
        if (std.mem.eql(u8, arg, "--root-recover")) {
            parsed.recovery_reach = "root";
            continue;
        }
        if (std.mem.eql(u8, arg, "--all-recover")) {
            parsed.recovery_reach = "all";
            continue;
        }
        if (std.mem.eql(u8, arg, "--recovery")) {
            i += 1;
            if (i >= args.len) return error.MissingRecoveryReach;
            try validateRecoveryReach(args[i]);
            parsed.recovery_reach = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--recovery-graph")) {
            i += 1;
            if (i >= args.len) return error.MissingRecoveryGraph;
            parsed.recovery_graph = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--default")) {
            if (parsed.graph_path != null) return error.ConflictingGraphFlags;
            parsed.use_default = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) return error.MissingModelId;
            parsed.model_id = args[i];
            continue;
        }
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
            if (parsed.use_default) return error.ConflictingGraphFlags;
            parsed.graph_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--export")) {
            i += 1;
            if (i >= args.len) return error.MissingExport;
            parsed.selected_export = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "--text") or std.mem.eql(u8, arg, "--file") or std.mem.eql(u8, arg, "--image")) {
            const kind = inputFlagKind(arg);
            i += 1;
            if (i >= args.len) return error.MissingRunInput;
            try appendInputArg(allocator, &parsed.inputs, kind, args[i]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--recovery=")) {
            try validateRecoveryReach(arg["--recovery=".len..]);
            parsed.recovery_reach = arg["--recovery=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--recovery-graph=")) {
            parsed.recovery_graph = arg["--recovery-graph=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--model=")) {
            parsed.model_id = arg["--model=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--graph=")) {
            if (parsed.use_default) return error.ConflictingGraphFlags;
            parsed.graph_path = arg["--graph=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--export=")) {
            parsed.selected_export = arg["--export=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--input=") or std.mem.startsWith(u8, arg, "--text=") or std.mem.startsWith(u8, arg, "--file=") or std.mem.startsWith(u8, arg, "--image=")) {
            const eq = std.mem.indexOfScalar(u8, arg, '=') orelse unreachable;
            try appendInputArg(allocator, &parsed.inputs, inputFlagKind(arg[0..eq]), arg[eq + 1 ..]);
            continue;
        }
        if (parsed.graph_path == null and !parsed.use_default and cmd.looksLikeGraphPath(arg)) {
            parsed.graph_path = arg;
            continue;
        }
        try parsed.prompt_parts.append(allocator, arg);
    }
    return parsed;
}

fn validateRecoveryReach(reach: []const u8) !void {
    if (std.mem.eql(u8, reach, "none")) return;
    if (std.mem.eql(u8, reach, "session")) return;
    if (std.mem.eql(u8, reach, "project")) return;
    if (std.mem.eql(u8, reach, "root")) return;
    if (std.mem.eql(u8, reach, "all")) return;
    return error.InvalidRecoveryReach;
}

fn defaultGraphPath(allocator: Allocator, stock_graph: []const u8) ![]u8 {
    const project_graph = ".zinc/graphs/zinc-loop.circuitry.yaml";
    if (files.existsPath(project_graph)) return allocator.dupe(u8, project_graph);
    return allocator.dupe(u8, stock_graph);
}

fn inputFlagKind(flag: []const u8) graph.InputKind {
    if (std.mem.eql(u8, flag, "--file")) return .file;
    if (std.mem.eql(u8, flag, "--image")) return .image;
    return .text;
}

fn appendInputArg(allocator: Allocator, inputs: *std.ArrayList(graph.RuntimeInput), kind: graph.InputKind, raw: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidRunInput;
    const id = raw[0..eq];
    const value = raw[eq + 1 ..];
    if (id.len == 0 or value.len == 0) return error.InvalidRunInput;
    try inputs.append(allocator, .{ .id = try allocator.dupe(u8, id), .kind = kind, .value = try allocator.dupe(u8, value), .content_type = try allocator.dupe(u8, if (kind == .image or kind == .file) resource.contentTypeFromPath(value) else "text/plain") });
}

pub fn compactFromArgs(allocator: Allocator, io: std.Io, layout_ctx: @import("../io/layout.zig").Context, args: []const []const u8) !void {
    var resume_id: ?[]const u8 = null;
    var continue_last = true;
    var dry_run = false;
    const runtime_paths = try config.loadRuntimePaths(allocator, io, layout_ctx);
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
        try cmd.validateGraphFile(allocator, io, graph_path);
        std.debug.print("ok: compaction graph {s}\n", .{graph_path});
        return;
    }
    try engine.compactSession(allocator, io, layout_ctx, graph_path, resume_id, continue_last);
}

const unix_installer_url = "https://raw.githubusercontent.com/darkhorseprojects/zinc/main/scripts/install-unix.sh";
const windows_installer_url = "https://raw.githubusercontent.com/darkhorseprojects/zinc/main/scripts/install-windows.ps1";

pub fn updateFromArgs(allocator: Allocator, io: std.Io, layout_ctx: @import("../io/layout.zig").Context, args: []const []const u8) !void {
    _ = layout_ctx;
    var ref: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--ref")) {
            i += 1;
            if (i >= args.len) return cmd.fail("missing value after --ref", .{});
            ref = args[i];
            continue;
        }
        return cmd.fail("unknown update argument: {s}", .{args[i]});
    }

    const target = ref orelse "latest";
    switch (builtin.os.tag) {
        .linux, .macos => try runCommand(allocator, io, &.{
            "sh",
            "-c",
            "curl -fsSL \"$0\" | sh -s -- --version \"$1\"",
            unix_installer_url,
            target,
        }, "failed to install Zinc update"),
        .windows => try runCommand(allocator, io, &.{
            "powershell",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            "$script = Join-Path $env:TEMP 'install-zinc.ps1'; Invoke-WebRequest -Uri $args[0] -OutFile $script; & $script -Version $args[1]",
            windows_installer_url,
            target,
        }, "failed to install Zinc update"),
        else => return cmd.fail("unsupported update platform: {s}", .{@tagName(builtin.os.tag)}),
    }
    std.debug.print("updated Zinc release ({s})\n", .{target});
}

fn runCommand(allocator: Allocator, io: std.Io, argv: []const []const u8, context: []const u8) !void {
    const result = std.process.run(allocator, io, .{ .argv = argv, .stderr_limit = .limited(5 * 1024 * 1024), .stdout_limit = .limited(5 * 1024 * 1024) }) catch |err| switch (err) {
        error.FileNotFound => return cmd.fail("required command not found: {s}", .{argv[0]}),
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) {
        if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
        if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
        return;
    }
    std.debug.print("error: {s}\n", .{context});
    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
    return error.UserError;
}
