const std = @import("std");
const serde = @import("serde");
const circuitry = @import("circuitry");
const Substrate = @import("substrate.zig").Store;
const fragments = @import("fragment.zig");
const package = @import("package.zig");
const config = @import("cmd/config.zig");
const files = @import("io/fs.zig");
const layout = @import("io/layout.zig");
const proc = @import("io/process.zig");

const Allocator = std.mem.Allocator;
const assembly_target = "zinc.assembly";

pub fn shape(allocator: Allocator, io: std.Io, store: *Substrate, source_path: []const u8, args: []const []const u8, settings: *const config.ConfigSettings) !void {
    const prepared = try prepare(allocator, io, store, source_path, args);
    defer allocator.free(prepared);
    const result = try advance(allocator, io, store, prepared, settings);
    defer allocator.free(result);
    if (result.len > 0) {
        try files.writeAllOut(result);
        if (result[result.len - 1] != '\n') try files.writeAllOut("\n");
    }
}

pub fn prepare(allocator: Allocator, io: std.Io, store: *Substrate, source_path: []const u8, args: []const []const u8) ![]u8 {
    const abs_path = try absolute(allocator, io, source_path);
    defer allocator.free(abs_path);
    const request = try assemblyRequest(allocator, abs_path, args);
    defer allocator.free(request);
    const result = try std.fmt.allocPrint(allocator, "source: {s}\n", .{abs_path});
    defer allocator.free(result);
    const ids = try fragments.putAndHead(store, assembly_target, request, result, std.Io.Clock.now(.real, io).toSeconds());
    return try allocator.dupe(u8, &ids.fragment);
}

pub fn advance(allocator: Allocator, io: std.Io, store: *Substrate, assembly_fragment: []const u8, settings: *const config.ConfigSettings) ![]u8 {
    const prepared = (try store.getFragment(assembly_fragment)) orelse return error.AssemblyFragmentNotFound;
    defer store.freeFragment(prepared);
    if (!std.mem.eql(u8, prepared.target, assembly_target)) return error.NotAssemblyFragment;

    var source: ?[]const u8 = null;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    try parseAssemblyRequest(allocator, prepared.request, &source, &args);
    const source_path = source orelse return error.AssemblyRequestMissingSource;

    const result = try runShape(allocator, io, store, source_path, args.items, settings);
    defer allocator.free(result);
    _ = try fragments.putAndHead(store, assembly_target, prepared.request, result, std.Io.Clock.now(.real, io).toSeconds());
    return try allocator.dupe(u8, result);
}

fn runShape(allocator: Allocator, io: std.Io, store: *Substrate, source_path: []const u8, args: []const []const u8, settings: *const config.ConfigSettings) ![]u8 {
    const bytes = try files.readLimited(allocator, source_path, 16 * 1024 * 1024);
    defer allocator.free(bytes);

    var loaded = try circuitry.loadText(allocator, bytes);
    defer loaded.deinit();
    var confirmation = try circuitry.confirm(allocator, &loaded);
    defer confirmation.deinit();
    if (!confirmation.confirmed) {
        try printProblems(confirmation.problems);
        return error.CircuitryShapeNotReady;
    }

    _ = try fragments.put(store, "circuitry.confirm", bytes, bytes, std.Io.Clock.now(.real, io).toSeconds());

    var state = State.init(allocator);
    defer state.deinit();
    try collectInputs(allocator, &state, confirmation.shape.takes, args);

    for (confirmation.shape.uses) |part| {
        const part_yaml = try partMaterial(allocator, part);
        defer allocator.free(part_yaml);
        try runPart(allocator, io, store, settings, &state, part, part_yaml);
    }
    return try shapeTextResult(allocator, &state, confirmation.shape.gives);
}

const State = struct {
    allocator: Allocator,
    values: std.StringHashMap([]u8),

    fn init(allocator: Allocator) State {
        return .{ .allocator = allocator, .values = std.StringHashMap([]u8).init(allocator) };
    }

    fn deinit(self: *State) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.values.deinit();
    }
};

fn runPart(allocator: Allocator, io: std.Io, store: *Substrate, settings: *const config.ConfigSettings, state: *State, part: circuitry.Use, part_yaml: []const u8) anyerror!void {
    if (part.shape) |shape_ref| return try runShapePart(allocator, io, store, settings, state, shape_ref, part, part_yaml);

    const run_ref = part.run orelse settings.defaultRun();
    const request = try packageRequest(allocator, run_ref, part, part_yaml, state);
    defer allocator.free(request);
    const head_hex = fragments.head(run_ref, request);

    if (try fragments.headFragment(store, &head_hex)) |fragment_row| {
        defer store.freeFragment(fragment_row);
        try applyResult(allocator, state, part, fragment_row.result);
        return;
    }

    const program_path = if (package.parseRef(run_ref)) |_| try package.resolveRef(allocator, store, run_ref) else |_| try allocator.dupe(u8, run_ref);
    defer allocator.free(program_path);
    const request_path = try tempFile(allocator, "package-request.yaml", request);
    defer allocator.free(request_path);

    const result = try proc.run(allocator, io, &.{ program_path, request_path }, null, 64 * 1024 * 1024);
    defer result.deinit(allocator);
    if (result.stderr.len > 0) try files.writeAllErr(result.stderr);
    if (result.code != 0) return error.PackageRunFailed;

    try applyResult(allocator, state, part, result.stdout);
    _ = try fragments.putAndHead(store, run_ref, request, result.stdout, std.Io.Clock.now(.real, io).toSeconds());
}

fn runShapePart(allocator: Allocator, io: std.Io, store: *Substrate, settings: *const config.ConfigSettings, parent: *State, shape_ref: []const u8, part: circuitry.Use, part_yaml: []const u8) anyerror!void {
    const request = try shapeRequest(allocator, parent, shape_ref, part, part_yaml);
    defer allocator.free(request);
    const target = try std.fmt.allocPrint(allocator, "zinc.shape:{s}", .{shape_ref});
    defer allocator.free(target);
    const head_hex = fragments.head(target, request);

    if (try fragments.headFragment(store, &head_hex)) |fragment_row| {
        defer store.freeFragment(fragment_row);
        try applyResult(allocator, parent, part, fragment_row.result);
        return;
    }

    const shape_path = if (package.parseRef(shape_ref)) |_| try package.resolveRef(allocator, store, shape_ref) else |_| try allocator.dupe(u8, shape_ref);
    defer allocator.free(shape_path);
    var loaded = try circuitry.loadFile(io, allocator, shape_path);
    defer loaded.deinit();
    var confirmation = try circuitry.confirm(allocator, &loaded);
    defer confirmation.deinit();
    if (!confirmation.confirmed) return error.CircuitryShapeNotReady;

    var child = State.init(allocator);
    defer child.deinit();
    try mapChildInputs(allocator, parent, &child, part, confirmation.shape.takes);

    for (confirmation.shape.uses) |child_part| {
        const child_yaml = try partMaterial(allocator, child_part);
        defer allocator.free(child_yaml);
        try runPart(allocator, io, store, settings, &child, child_part, child_yaml);
    }
    try mapChildOutputs(allocator, parent, &child, part, confirmation.shape.gives);

    const result = try shapeResult(allocator, &child, confirmation.shape.gives);
    defer allocator.free(result);
    _ = try fragments.putAndHead(store, target, request, result, std.Io.Clock.now(.real, io).toSeconds());
}

fn mapChildInputs(allocator: Allocator, parent: *State, child: *State, part: circuitry.Use, child_takes: []const circuitry.Variable) !void {
    for (child_takes) |take| {
        const parent_name = inputFor(part, take.name) orelse return error.MissingShapeInput;
        const found = parent.values.get(parent_name) orelse return error.MissingInputValue;
        try child.values.put(try allocator.dupe(u8, take.name), try allocator.dupe(u8, found));
    }
}

fn mapChildOutputs(allocator: Allocator, parent: *State, child: *State, part: circuitry.Use, child_gives: []const circuitry.Variable) !void {
    for (child_gives) |give| {
        const parent_name = outputFor(part, give.name) orelse return error.MissingShapeOutput;
        const found = child.values.get(give.name) orelse return error.MissingOutputValue;
        try putValue(allocator, parent, parent_name, found);
    }
}

fn inputFor(part: circuitry.Use, visible: []const u8) ?[]const u8 {
    for (part.takes) |ref| if (std.mem.eql(u8, ref.visible orelse return null, visible)) return ref.local;
    return null;
}

fn outputFor(part: circuitry.Use, visible: []const u8) ?[]const u8 {
    for (part.gives) |ref| if (std.mem.eql(u8, ref.visible orelse return null, visible)) return ref.local;
    return null;
}

fn packageRequest(allocator: Allocator, run_ref: []const u8, part: circuitry.Use, part_yaml: []const u8, state: *State) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "run: {s}\npart: {s}\npart_yaml: |\n", .{ run_ref, part.name });
    try appendIndented(allocator, &out, part_yaml, 2);
    try out.appendSlice(allocator, "takes:\n");
    for (part.takes) |take| {
        const found = state.values.get(take.visible orelse return error.MissingInputValue) orelse return error.MissingInputValue;
        try out.print(allocator, "  {s}: |\n", .{take.local});
        try appendIndented(allocator, &out, found, 4);
    }
    try out.appendSlice(allocator, "gives:\n");
    for (part.gives) |give| try out.print(allocator, "  {s}: |\n", .{give.local});
    return out.toOwnedSlice(allocator);
}

fn shapeRequest(allocator: Allocator, state: *State, shape_ref: []const u8, part: circuitry.Use, part_yaml: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "shape: {s}\npart: {s}\npart_yaml: |\n", .{ shape_ref, part.name });
    try appendIndented(allocator, &out, part_yaml, 2);
    try out.appendSlice(allocator, "takes:\n");
    for (part.takes) |take| {
        const found = state.values.get(take.visible orelse return error.MissingInputValue) orelse return error.MissingInputValue;
        try out.print(allocator, "  {s}: |\n", .{take.local});
        try appendIndented(allocator, &out, found, 4);
    }
    return out.toOwnedSlice(allocator);
}

fn applyResult(allocator: Allocator, state: *State, part: circuitry.Use, bytes: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = try serde.yaml.parse(arena.allocator(), bytes);
    const gives = yamlGet(&root, "gives") orelse return error.PackageResponseMissingGives;
    if (gives.* != .mapping) return error.PackageResponseMissingGives;
    var it = gives.mapping.iterator();
    while (it.next()) |entry| {
        const system = outputFor(part, entry.key_ptr.*) orelse continue;
        if (entry.value_ptr.* != .string) return error.InvalidPackageOutput;
        try putValue(allocator, state, system, entry.value_ptr.string);
    }
}

fn collectInputs(allocator: Allocator, state: *State, takes: []const circuitry.Variable, args: []const []const u8) !void {
    if (args.len != takes.len) return error.MissingRunInput;
    for (takes) |take| {
        const provided = findArg(args, take.name) orelse findArg(args, bare(take.name)) orelse return error.MissingRunInput;
        try putValue(allocator, state, take.name, provided);
    }
}

fn putValue(allocator: Allocator, state: *State, name: []const u8, text: []const u8) !void {
    const key = try allocator.dupe(u8, name);
    errdefer allocator.free(key);
    const value = try allocator.dupe(u8, text);
    errdefer allocator.free(value);
    if (state.values.fetchRemove(name)) |old| {
        allocator.free(old.key);
        allocator.free(old.value);
    }
    try state.values.put(key, value);
}

fn shapeResult(allocator: Allocator, state: *State, gives: []const circuitry.Variable) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "gives:\n");
    for (gives) |give| {
        const found = state.values.get(give.name) orelse return error.MissingOutputValue;
        try out.print(allocator, "  {s}: |\n", .{bare(give.name)});
        try appendIndented(allocator, &out, found, 4);
    }
    return out.toOwnedSlice(allocator);
}

fn shapeTextResult(allocator: Allocator, state: *State, gives: []const circuitry.Variable) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (gives) |give| {
        const found = state.values.get(give.name) orelse return error.MissingOutputValue;
        if (out.items.len != 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, found);
    }
    return out.toOwnedSlice(allocator);
}

fn partMaterial(allocator: Allocator, part: circuitry.Use) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (part.shape) |shape_ref| try out.print(allocator, "shape: {s}\n", .{shape_ref});
    if (part.run) |run_ref| try out.print(allocator, "run: {s}\n", .{run_ref});
    try out.appendSlice(allocator, "takes:\n");
    for (part.takes) |take| try out.print(allocator, "  {s}: {s}\n", .{ take.local, take.visible orelse take.local });
    try out.appendSlice(allocator, "does: |\n");
    if (part.instructions) |instructions| {
        try appendIndented(allocator, &out, instructions, 2);
    } else {
        try out.appendSlice(allocator, "  \n");
    }
    try out.appendSlice(allocator, "gives:\n");
    for (part.gives) |give| try out.print(allocator, "  {s}: {s}\n", .{ give.local, give.visible orelse give.local });
    for (part.fields) |field| {
        try out.print(allocator, "{s}: ", .{field.name});
        try appendYamlValue(allocator, &out, field.value);
    }
    return out.toOwnedSlice(allocator);
}

fn appendIndented(allocator: Allocator, out: *std.ArrayList(u8), text: []const u8, spaces: usize) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        try out.appendNTimes(allocator, ' ', spaces);
        try out.appendSlice(allocator, line);
    }
    try out.append(allocator, '\n');
}

fn appendYamlValue(allocator: Allocator, out: *std.ArrayList(u8), value: *const serde.yaml.Value) !void {
    switch (value.*) {
        .string => |s| try out.print(allocator, "{s}\n", .{s}),
        .sequence => |items| {
            try out.appendSlice(allocator, "[");
            for (items, 0..) |item, i| {
                if (i != 0) try out.appendSlice(allocator, ", ");
                try appendYamlInline(allocator, out, &item);
            }
            try out.appendSlice(allocator, "]\n");
        },
        .mapping => |*map| {
            try out.appendSlice(allocator, "{");
            var it = map.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.appendSlice(allocator, ", ");
                first = false;
                try out.print(allocator, "{s}: ", .{entry.key_ptr.*});
                try appendYamlInline(allocator, out, entry.value_ptr);
            }
            try out.appendSlice(allocator, "}\n");
        },
        else => try out.appendSlice(allocator, "null\n"),
    }
}

fn appendYamlInline(allocator: Allocator, out: *std.ArrayList(u8), value: *const serde.yaml.Value) !void {
    switch (value.*) {
        .string => |s| try out.print(allocator, "{s}", .{s}),
        else => try out.appendSlice(allocator, "..."),
    }
}

fn assemblyRequest(allocator: Allocator, source_path: []const u8, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "source: {s}\nargs:\n", .{source_path});
    for (args) |arg| try out.print(allocator, "  - {s}\n", .{arg});
    return out.toOwnedSlice(allocator);
}

fn parseAssemblyRequest(allocator: Allocator, request: []const u8, source: *?[]const u8, args: *std.ArrayList([]const u8)) !void {
    var in_args = false;
    var lines = std.mem.splitScalar(u8, request, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "source: ")) {
            source.* = try allocator.dupe(u8, line["source: ".len..]);
            in_args = false;
        } else if (std.mem.eql(u8, line, "args:")) {
            in_args = true;
        } else if (in_args and std.mem.startsWith(u8, line, "  - ")) {
            try args.append(allocator, try allocator.dupe(u8, line["  - ".len..]));
        }
    }
}

fn findArg(args: []const []const u8, name: []const u8) ?[]const u8 {
    const wanted = std.fmt.allocPrint(std.heap.page_allocator, "{s}=", .{name}) catch return null;
    defer std.heap.page_allocator.free(wanted);
    for (args) |arg| if (std.mem.eql(u8, arg, wanted) or std.mem.eql(u8, arg, name)) return arg;
    return null;
}

fn tempFile(allocator: Allocator, name: []const u8, bytes: []const u8) ![]u8 {
    const dir = try layout.globalPath(allocator, "tmp");
    defer allocator.free(dir);
    try files.mkdirP(dir);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(bytes);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const suffix = std.fmt.bytesToHex(digest, .lower);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.yaml", .{ dir, name, suffix[0..16] });
    try files.write(path, bytes);
    return path;
}

fn yamlGet(node: *const serde.yaml.Value, key: []const u8) ?*const serde.yaml.Value {
    if (node.* != .mapping) return null;
    var it = node.mapping.iterator();
    while (it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, key)) return entry.value_ptr;
    return null;
}

fn bare(name: []const u8) []const u8 {
    return if (name.len > 0 and name[0] == '$') name[1..] else name;
}

fn absolute(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
    const cwd_buf = try allocator.alloc(u8, std.fs.max_path_bytes);
    defer allocator.free(cwd_buf);
    const cwd_len = try std.process.currentPath(io, cwd_buf);
    return try std.fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
}

fn printProblems(problems: []const []const u8) !void {
    for (problems) |problem| {
        try files.writeAllErr("fix: ");
        try files.writeAllErr(problem);
        try files.writeAllErr("\n");
    }
}
