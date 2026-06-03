const std = @import("std");
const config = @import("../config/mod.zig");
const engine = @import("../graph/engine.zig");
const files = @import("../io/fs.zig");
const graph = @import("../graph/mod.zig");
const layout = @import("../io/layout.zig");
const packages = @import("../packages/mod.zig");
const resource = @import("../graph/resource.zig");
const sessions = @import("../session/mod.zig");

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
        \\  zn clean [--local|--global] [--yes] [sessions | logs | packages | state | all]
        \\  zn serve [model-id]
        \\  zn stop
        \\  zn doctor
        \\  zn config get <path>
        \\  zn compact [--dry-run] [--session id|--continue] [graph]
        \\  zn update [--ref tag-or-commit] [--skip-packages] [--skip-zinc]
        \\  zn [--session id|--continue] <prompt>
        \\  zn run [graph|--graph id|path] [--export id] [--input name=value] [--text name=value|@file] [--file name=path] [--image name=path] [--session id|--continue] <prompt>
        \\  zn graph list
        \\  zn graph show <graph>
        \\  zn pkg list
        \\  zn pkg add [--local|--global] [--replace] [--yes] <source>
        \\  zn pkg remove [--local|--global] [--yes] <name>
        \\  zn pkg update [--local|--global] [--yes] <name|--all>
        \\  zn pkg show [--local|--global] <name>
        \\  zn pkg exec <package> <script>
        \\  zn pkg attach <package>
        \\  zn pkg detach <package>
        \\  zn pkg attachments
        \\  zn pkg call <tool> <json-arguments>
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
    if (parsed_args.graph_path == null and parsed_args.prompt_parts.items.len != 0) {
        if (packages.resolveGraph(allocator, io, home, parsed_args.prompt_parts.items[0])) |path| {
            allocator.free(path);
            parsed_args.graph_path = parsed_args.prompt_parts.orderedRemove(0);
        } else |err| switch (err) {
            error.GraphNotFound => {},
            else => return err,
        }
    }
    const resolved_graph = if (parsed_args.graph_path) |spec| packages.resolveGraph(allocator, io, home, spec) catch |err| switch (err) {
        error.GraphNotFound => return fail("graph not found: {s}", .{spec}),
        else => return err,
    } else try allocator.dupe(u8, runtime_paths.graph);
    defer allocator.free(resolved_graph);
    const prompt = try std.mem.join(allocator, " ", parsed_args.prompt_parts.items);
    defer allocator.free(prompt);
    try engine.runGraph(allocator, io, home, resolved_graph, parsed_args.selected_export, prompt, parsed_args.resume_id, parsed_args.continue_last, parsed_args.inputs.items);
}

const RunArgs = struct {
    prompt_parts: std.ArrayList([]const u8),
    inputs: std.ArrayList(graph.RuntimeInput),
    graph_path: ?[]const u8 = null,
    selected_export: ?[]const u8 = null,
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
        if (std.mem.startsWith(u8, arg, "--graph=")) {
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
    try inputs.append(allocator, .{ .id = try allocator.dupe(u8, id), .kind = kind, .value = try allocator.dupe(u8, value), .content_type = try allocator.dupe(u8, if (kind == .image or kind == .file) resource.contentTypeFromPath(value) else "text/plain") });
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

pub fn graphShow(allocator: Allocator, io: std.Io, home: []const u8, spec: []const u8) !void {
    const path = packages.resolveGraph(allocator, io, home, spec) catch |err| switch (err) {
        error.GraphNotFound => return fail("graph not found: {s}", .{spec}),
        else => return err,
    };
    defer allocator.free(path);
    const loaded_graph = try graph.load(allocator, io, path);
    defer loaded_graph.deinit(allocator);
    try printGraph(allocator, spec, path, loaded_graph);
}
pub fn packageList(allocator: Allocator, io: std.Io, home: []const u8) !void {
    const text = try packages.listPackages(allocator, io, home);
    defer allocator.free(text);
    if (text.len == 0) std.debug.print("no packages found\n", .{}) else std.debug.print("{s}", .{text});
}
pub fn packageAdd(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    const parsed = try parsePackageArgs(args, true);
    const source = parsed.value orelse return error.MissingPackageSource;
    const options = packages.InstallOptions{ .scope = parsed.scope orelse .local, .replace = parsed.replace };
    const plan = try packages.previewAdd(allocator, io, home, source, options);
    defer plan.deinit(allocator, io);
    std.debug.print("Install Zinc package\n\n{s}\n", .{plan.text});
    if (!parsed.yes) try confirmOrFail("Install?");
    var package = try packages.installPreviewed(allocator, io, home, plan, source, options);
    defer package.deinit(allocator);
    std.debug.print("added {s}: {s}\n", .{ scopeName(package.scope), package.path });
}
pub fn packageRemove(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    const parsed = try parsePackageArgs(args, false);
    const name = parsed.value orelse return error.MissingPackageName;
    const text = try packages.show(allocator, io, home, name, parsed.scope);
    defer allocator.free(text);
    std.debug.print("Remove Zinc package\n\n{s}\n", .{text});
    if (!parsed.yes) try confirmOrFail("Remove?");
    var package = try packages.remove(allocator, io, home, name, parsed.scope);
    defer package.deinit(allocator);
    std.debug.print("removed {s}: {s}\n", .{ scopeName(package.scope), package.name });
}
pub fn packageUpdate(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    const parsed = try parsePackageArgs(args, false);
    const name = parsed.value orelse return error.MissingPackageName;
    if (std.mem.eql(u8, name, "--all")) {
        const text = try packages.listPackages(allocator, io, home);
        defer allocator.free(text);
        std.debug.print("Update all Zinc packages\n\n{s}\n", .{if (text.len == 0) "no packages found\n" else text});
        if (!parsed.yes) try confirmOrFail("Update all?");
        const updated = try packages.updateAll(allocator, io, home);
        defer allocator.free(updated);
        std.debug.print("{s}", .{updated});
        return;
    }
    const plan = try packages.previewUpdate(allocator, io, home, name, parsed.scope);
    defer plan.deinit(allocator, io);
    std.debug.print("Update Zinc package\n\n{s}\n", .{plan.text});
    if (!parsed.yes) try confirmOrFail("Update?");
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

pub fn packageExec(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    if (args.len < 2) return error.MissingPackageScript;
    const out = try packages.execScript(allocator, io, home, args[0], args[1]);
    defer allocator.free(out);
    std.debug.print("{s}", .{out});
}

pub fn packageAttach(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    if (args.len != 1) return error.MissingPackageName;
    const out = try packages.attach(allocator, io, home, args[0]);
    defer allocator.free(out);
    std.debug.print("{s}", .{out});
}

pub fn packageDetach(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    if (args.len != 1) return error.MissingPackageName;
    const out = try packages.detach(allocator, io, home, args[0]);
    defer allocator.free(out);
    std.debug.print("{s}", .{out});
}

pub fn packageAttachments(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    _ = home;
    if (args.len != 0) return error.TooManyArguments;
    const out = try packages.attachments(allocator, io);
    defer allocator.free(out);
    std.debug.print("{s}", .{out});
}

pub fn packageCall(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    if (args.len != 2) return error.InvalidToolArguments;
    const result = try resource.callPackageTool(allocator, io, home, args[0], args[1]);
    defer result.deinit(allocator);
    try files.writeAllOut(result.content);
    try files.writeAllOut("\n");
    if (result.is_error) return error.UserError;
}

const zinc_repo_url = "https://github.com/darkhorseprojects/zinc.git";

pub fn updateFromArgs(allocator: Allocator, io: std.Io, home: []const u8, args: []const []const u8) !void {
    var ref: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--ref")) {
            i += 1;
            if (i >= args.len) return fail("missing value after --ref", .{});
            ref = args[i];
            continue;
        }
        return fail("unknown update argument: {s}", .{args[i]});
    }

    const target = ref orelse "main";
    const source_dir = try layout.sharePath(allocator, home, "source/zinc");
    defer allocator.free(source_dir);
    const git_dir = try std.fs.path.join(allocator, &.{ source_dir, ".git" });
    defer allocator.free(git_dir);

    if (!files.existsPath(git_dir)) {
        if (std.fs.path.dirname(source_dir)) |parent| try files.mkdirP(parent);
        try runCommand(allocator, io, &.{ "git", "clone", zinc_repo_url, source_dir }, "failed to download Zinc from git");
    }

    try runCommand(allocator, io, &.{ "git", "-C", source_dir, "fetch", "--tags", "origin" }, "failed to fetch Zinc updates");
    if (std.mem.eql(u8, target, "main") or std.mem.eql(u8, target, "master")) {
        try runCommand(allocator, io, &.{ "git", "-C", source_dir, "checkout", target }, "failed to checkout Zinc update branch");
        try runCommand(allocator, io, &.{ "git", "-C", source_dir, "pull", "--ff-only", "origin", target }, "failed to update Zinc checkout");
    } else {
        try runCommand(allocator, io, &.{ "git", "-C", source_dir, "fetch", "origin", target }, "failed to fetch requested Zinc ref");
        try runCommand(allocator, io, &.{ "git", "-C", source_dir, "checkout", "--detach", "FETCH_HEAD" }, "failed to checkout requested Zinc ref");
    }

    const installer = try std.fs.path.join(allocator, &.{ source_dir, "scripts", "install-linux.sh" });
    defer allocator.free(installer);
    try runCommand(allocator, io, &.{installer}, "failed to install Zinc update");
    std.debug.print("updated Zinc from {s} ({s})\n", .{ zinc_repo_url, target });
}

fn runCommand(allocator: Allocator, io: std.Io, argv: []const []const u8, context: []const u8) !void {
    const result = std.process.run(allocator, io, .{ .argv = argv, .stderr_limit = .limited(5 * 1024 * 1024), .stdout_limit = .limited(5 * 1024 * 1024) }) catch |err| switch (err) {
        error.FileNotFound => return fail("required command not found: {s}", .{argv[0]}),
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
    if (std.mem.indexOf(u8, result.stderr, "Authentication failed") != null or std.mem.indexOf(u8, result.stderr, "Repository not found") != null) {
        std.debug.print("Could not fetch Zinc repository. Check your internet connection, git installation, or repository URL: {s}\n", .{zinc_repo_url});
    }
    if (result.stdout.len != 0) std.debug.print("{s}", .{result.stdout});
    if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
    return error.UserError;
}

const PackageArgs = struct { scope: ?packages.Scope = null, replace: bool = false, yes: bool = false, value: ?[]const u8 = null };
fn parsePackageArgs(args: []const []const u8, allow_replace: bool) !PackageArgs {
    var parsed = PackageArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--local")) {
            if (parsed.scope != null) return error.ConflictingScopeFlags;
            parsed.scope = .local;
        } else if (std.mem.eql(u8, arg, "--global")) {
            if (parsed.scope != null) return error.ConflictingScopeFlags;
            parsed.scope = .global;
        } else if (std.mem.eql(u8, arg, "--replace") and allow_replace) parsed.replace = true else if (std.mem.eql(u8, arg, "--yes")) parsed.yes = true else if (parsed.value == null) parsed.value = arg else return error.TooManyArguments;
    }
    return parsed;
}
fn scopeName(scope: packages.Scope) []const u8 {
    return switch (scope) {
        .local => "local",
        .global => "global",
    };
}

fn confirmOrFail(prompt: []const u8) !void {
    try files.writeAllErr(prompt);
    try files.writeAllErr(" [y/N] ");
    var buf: [16]u8 = undefined;
    const n = try files.readStdin(&buf);
    if (n == 0) return fail("confirmation required", .{});
    const answer = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (answer.len == 1 and (answer[0] == 'y' or answer[0] == 'Y')) return;
    if (answer.len == 1 and (answer[0] == 'n' or answer[0] == 'N')) return fail("cancelled", .{});
    return fail("answer y or n", .{});
}

fn printGraph(allocator: Allocator, spec: []const u8, path: []const u8, loaded: graph.Graph) !void {
    std.debug.print("graph: {s}\npath: {s}\n\n", .{ spec, path });
    const text = try graph.inspectText(allocator, loaded);
    defer allocator.free(text);
    std.debug.print("{s}", .{text});
}

fn joinTemp(allocator: Allocator, items: []const []u8) ![]u8 {
    return std.mem.join(allocator, ",", items);
}

fn valueSummary(value: std.json.Value) []const u8 {
    return switch (value) {
        .string => |text| if (text.len > 40) text[0..40] else text,
        else => "<literal>",
    };
}

fn jsonText(allocator: Allocator, value: std.json.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    try std.json.Stringify.value(value, .{}, &aw.writer);
    out = aw.toArrayList();
    return out.toOwnedSlice(allocator);
}

fn objectAt(value: std.json.Value, path: []const []const u8) ?std.json.ObjectMap {
    const found = valueAt(value, path) orelse return null;
    return if (found == .object) found.object else null;
}

fn scalarAt(value: std.json.Value, path: []const []const u8) ?[]const u8 {
    const found = valueAt(value, path) orelse return null;
    return if (found == .string) found.string else null;
}

fn valueAt(value: std.json.Value, path: []const []const u8) ?std.json.Value {
    var current = value;
    for (path) |part| {
        if (current != .object) return null;
        current = current.object.get(part) orelse return null;
    }
    return current;
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

pub fn clean(allocator: Allocator, io: std.Io, home: []const u8, scope: packages.Scope, target_str: []const u8, yes: bool) !void {
    const Target = enum { sessions, logs, packages, state, all };
    const target = std.meta.stringToEnum(Target, target_str) orelse return error.InvalidCleanTarget;
    std.debug.print("Clean Zinc artifacts\n\nscope: {s}\ntarget: {s}\n", .{ @tagName(scope), @tagName(target) });
    if (!yes) try confirmOrFail("Continue?");
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
