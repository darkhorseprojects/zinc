const std = @import("std");
const root = @import("../root.zig");
const sys = root.sys;
const core = root.core;
const runtime = root.runtime;

const config = runtime.config;
const engine = core.engine;
const files = sys.fs;
const graph = core.graph;
const layout = sys.layout;
const packages = core.packages;
const resource = core.resource;
const sessions = runtime.session;

const Allocator = std.mem.Allocator;

fn fail(comptime fmt: []const u8, args: anytype) error{UserError}!void {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    return error.UserError;
}

pub fn usage() void {
    std.debug.print(
        \\zn - Zinc, a tiny Circuitry-native runtime
        \\
        \\usage:
        \\  zn check [graph]
        \\  zn clean [--local|--global] [sessions | logs | packages | state | all]
        \\  zn serve [model-id]
        \\  zn stop
        \\  zn status
        \\  zn config get <path>
        \\  zn compact [--dry-run] [--session id|--continue] [graph]
        \\  zn update [--ref tag-or-commit] [--skip-packages] [--skip-zinc]
        \\  zn [--session id|--continue] <prompt>
        \\  zn run [graph|--graph id|path] [--entry id] [--input name=value] [--text name=value|@file] [--file name=path] [--image name=path] [--session id|--continue] <prompt>
        \\  zn graph list
        \\  zn pkg list
        \\  zn pkg add [--local|--global] [--replace] <source>
        \\  zn pkg remove [--local|--global] <name>
        \\  zn pkg update [--local|--global] [name]
        \\  zn pkg show [--local|--global] <name>
        \\  zn session-dir
        \\
    , .{});
}

pub fn validate(allocator: Allocator, io: std.Io, home: []const u8, path_arg: ?[]const u8) !void {
    const runtime_paths = try config.loadRuntimePaths(allocator, io, home);
    defer runtime_paths.deinit(allocator);
    const path = if (path_arg) |spec| packages.resolveGraph(allocator, io, home, spec) catch |err| switch (err) {
        error.GraphNotFound => return fail("graph not found: {s}", .{spec}),
        else => return err,
    } else try allocator.dupe(u8, runtime_paths.graph);
    defer allocator.free(path);
    try validateGraphFile(allocator, io, path);
    std.debug.print("ok: {s}\n", .{path});
}

pub fn runFromArgs(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    var parsed_args = try parseRunArgs(allocator, args);
    defer parsed_args.deinit(allocator);
    if (parsed_args.prompt_parts.items.len == 0 and parsed_args.inputs.items.len == 0 and parsed_args.graph_path == null) return usage();

    const runtime_paths = try config.loadRuntimePaths(allocator, io, home);
    defer runtime_paths.deinit(allocator);
    const resolved_graph = if (parsed_args.graph_path) |spec| packages.resolveGraph(allocator, io, home, spec) catch |err| switch (err) {
        error.GraphNotFound => return fail("graph not found: {s}", .{spec}),
        else => return err,
    } else try allocator.dupe(u8, runtime_paths.graph);
    defer allocator.free(resolved_graph);
    const prompt = try std.mem.join(allocator, " ", parsed_args.prompt_parts.items);
    defer allocator.free(prompt);
    try engine.runGraph(allocator, io, home, resolved_graph, parsed_args.entry, prompt, parsed_args.resume_id, parsed_args.continue_last, parsed_args.inputs.items);
}

const RunArgs = struct {
    prompt_parts: std.ArrayList([]const u8),
    inputs: std.ArrayList(graph.RuntimeInput),
    graph_path: ?[]const u8 = null,
    entry: ?[]const u8 = null,
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
        if (std.mem.eql(u8, arg, "--entry")) {
            i += 1;
            if (i >= args.len) return error.MissingEntry;
            parsed.entry = args[i];
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
        if (std.mem.startsWith(u8, arg, "--entry=")) {
            parsed.entry = arg["--entry=".len..];
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
    try inputs.append(allocator, .{ .id = try allocator.dupe(u8, id), .kind = kind, .value = try allocator.dupe(u8, value), .mime = try allocator.dupe(u8, if (kind == .image or kind == .file) resource.mimeFromPath(value) else "text/plain") });
}

fn looksLikeGraphPath(arg: []const u8) bool {
    if (std.mem.indexOfAny(u8, arg, " \t\r\n") != null) return false;
    if (!std.mem.endsWith(u8, arg, ".circuitry.yaml") and !std.mem.endsWith(u8, arg, ".circuitry.yml") and !std.mem.endsWith(u8, arg, ".yaml") and !std.mem.endsWith(u8, arg, ".yml")) return false;
    files.exists(arg) catch return false;
    return true;
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
        try validateGraphFile(allocator, io, graph_path);
        std.debug.print("ok: compaction graph {s}\n", .{graph_path});
        return;
    }
    try engine.compactSession(allocator, io, home, graph_path, resume_id, continue_last);
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
    if (parsed.value) |name| {
        var package = try packages.update(allocator, io, home, name, parsed.scope);
        defer package.deinit(allocator);
        std.debug.print("updated {s}: {s}\n", .{ scopeName(package.scope), package.path });
    } else {
        const text = try packages.updateAll(allocator, io, home);
        defer allocator.free(text);
        std.debug.print("{s}", .{text});
    }
}
pub fn packageShow(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    const parsed = try parsePackageArgs(args, false);
    const name = parsed.value orelse return error.MissingPackageName;
    const text = try packages.show(allocator, io, home, name, parsed.scope);
    defer allocator.free(text);
    std.debug.print("{s}", .{text});
}

pub fn updateFromArgs(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    _ = home;
    var ref: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--ref")) {
            i += 1;
            if (i >= args.len) return error.MissingRef;
            ref = args[i];
        }
    }
    const target = ref orelse "main";
    try runCommand(allocator, io, &.{ "git", "pull", "origin", target });
}

fn runCommand(allocator: Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
    if (result.term != .exited or result.term.exited != 0) return error.CommandFailed;
}

const PackageArgs = struct { scope: ?packages.Scope = null, replace: bool = false, value: ?[]const u8 = null };
fn parsePackageArgs(args: []const []const u8, allow_replace: bool) !PackageArgs {
    var parsed = PackageArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--local")) parsed.scope = .local else if (std.mem.eql(u8, arg, "--global")) parsed.scope = .global else if (std.mem.eql(u8, arg, "--replace") and allow_replace) parsed.replace = true else if (parsed.value == null) parsed.value = arg else return error.TooManyArguments;
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
    var split = std.mem.splitScalar(u8, dotted_path, '.');
    while (split.next()) |part| try parts.append(allocator, part);
    const value = try config.configGet(allocator, io, home, parts.items);
    defer allocator.free(value);
    std.debug.print("{s}\n", .{value});
}

fn validateGraphFile(allocator: Allocator, io: std.Io, path: []const u8) !void {
    const loaded_graph = try graph.load(allocator, io, path);
    defer loaded_graph.deinit(allocator);
    try graph.validate(loaded_graph);
}

pub fn clean(allocator: Allocator, io: std.Io, home: []const u8, scope: packages.Scope, target_str: []const u8) !void {
    const Target = enum { sessions, logs, packages, state, all };
    const target = std.meta.stringToEnum(Target, target_str) orelse return error.InvalidCleanTarget;
    var dir = std.Io.Dir.cwd();
    switch (scope) {
        .local => {
            if (target == .sessions or target == .all) dir.deleteTree(io, ".zinc/sessions") catch |err| if (err != error.FileNotFound) return err;
            if (target == .logs or target == .all) dir.deleteTree(io, ".zinc/logs") catch |err| if (err != error.FileNotFound) return err;
            if (target == .packages or target == .all) dir.deleteTree(io, ".zinc/packages") catch |err| if (err != error.FileNotFound) return err;
        },
        .global => {
            if (target == .packages or target == .all) {
                const global_pkgs = try layout.sharePath(allocator, home, "packages");
                defer allocator.free(global_pkgs);
                dir.deleteTree(io, global_pkgs) catch |err| if (err != error.FileNotFound) return err;
            }
            if (target == .state or target == .all) {
                const global_state = try layout.statePath(allocator, home, "");
                defer allocator.free(global_state);
                dir.deleteTree(io, global_state) catch |err| if (err != error.FileNotFound) return err;
            }
        },
    }
    std.debug.print("cleaned {s} {s} artifacts\n", .{ @tagName(scope), @tagName(target) });
}
