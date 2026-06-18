const std = @import("std");
const serde = @import("serde");
const circuitry = @import("circuitry");
const files = @import("io/fs.zig");
const layout = @import("io/layout.zig");
const config_cmd = @import("cmd/config.zig");
const package = @import("package.zig");
const proc = @import("io/process.zig");
const exec_io = @import("execute/io.zig");
const Substrate = @import("substrate.zig").Store;

const Allocator = std.mem.Allocator;

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    output: []const u8,
    lineage: []const u8,

    pub fn deinit(self: *const Result) void {
        self.arena.deinit();
    }
};

pub fn runShape(allocator: Allocator, io: std.Io, store: *Substrate, shape: circuitry.Shape, args: []const []const u8) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var state = State.init(aa);
    for (shape.inputs) |take| {
        if (findArg(args, take.name)) |value| try state.set(bare(take.name), value);
    }

    var lineage = std.ArrayList([]const u8).empty;
    errdefer lineage.deinit(aa);

    if (shape.text.len > 0) {
        const root_inputs = try variablesToRefs(aa, shape.inputs);
        const root_outputs = try variablesToRefs(aa, shape.outputs);
        const root = circuitry.Step{
            .allocator = aa,
            .name = "$root",
            .file = null,
            .text = shape.text,
            .instructions = null,
            .inputs = root_inputs,
            .outputs = root_outputs,
            .fields = shape.fields,
        };
        try runStep(aa, io, store, &state, &lineage, root);
    }

    for (shape.steps) |use| try runStep(aa, io, store, &state, &lineage, use);

    const output = try exec_io.shapeTextResult(aa, &state, shape.outputs);
    const lineage_bytes = try exec_io.lineageYaml(aa, lineage.items);
    return .{ .arena = arena, .output = output, .lineage = lineage_bytes };
}

fn variablesToRefs(allocator: Allocator, items: []const circuitry.Variable) ![]circuitry.Binding {
    var out = std.ArrayList(circuitry.Binding).empty;
    errdefer out.deinit(allocator);
    for (items) |item| try out.append(allocator, .{ .local = try allocator.dupe(u8, item.name), .visible = try allocator.dupe(u8, item.name) });
    return out.toOwnedSlice(allocator);
}

pub fn readShape(allocator: Allocator, path: []const u8) ![]const u8 {
    return try files.readLimited(allocator, path, 10 * 1024 * 1024);
}

pub fn parseShape(allocator: Allocator, bytes: []const u8) !circuitry.Shape {
    return try circuitry.parse(allocator, bytes);
}

pub fn writeResult(result: Result) !void {
    try files.writeAllOut(result.output);
}

const State = struct {
    allocator: Allocator,
    values: std.StringHashMap([]const u8),

    fn init(allocator: Allocator) State {
        return .{ .allocator = allocator, .values = std.StringHashMap([]const u8).init(allocator) };
    }

    pub fn get(self: *State, name: []const u8) ?[]const u8 {
        return self.values.get(bare(name));
    }

    fn set(self: *State, visible: []const u8, value: []const u8) !void {
        const key = bare(visible);
        const copy = try self.allocator.dupe(u8, value);
        if (self.values.fetchRemove(key)) |old| self.allocator.free(old.value);
        try self.values.put(key, copy);
    }

    fn deinit(self: *State) void {
        var it = self.values.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.values.deinit();
    }
};

fn runStep(allocator: Allocator, io: std.Io, store: *Substrate, state: *State, lineage: *std.ArrayList([]const u8), use: circuitry.Step) anyerror!void {
    if (use.file) |file_ref| {
        const path = if (std.mem.startsWith(u8, file_ref, "./"))
            try absolute(allocator, io, file_ref)
        else
            try package.resolve(allocator, store, "$root", file_ref);
        defer allocator.free(path);
        const bytes = try files.readLimited(allocator, path, 10 * 1024 * 1024);
        defer allocator.free(bytes);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const nested = try circuitry.parse(arena.allocator(), bytes);
        var nested_state = State.init(allocator);
        defer nested_state.deinit();
        for (use.inputs) |take| {
            const visible = take.visible orelse take.local;
            const value = state.get(visible) orelse return error.MissingStepInput;
            try nested_state.set(take.local, value);
        }
        try runShapeInto(allocator, io, store, nested, &nested_state);
        for (use.outputs) |give| {
            const value = nested_state.get(give.local) orelse return error.MissingStepOutput;
            try state.set(give.visible orelse give.local, value);
        }
        return;
    }

    const surface = hostField(use.fields, "surface") orelse (try defaultSurface(allocator, io));
    var manifest = try loadManifest(allocator, store, surface);
    defer manifest.deinit();
    const request = try surfaceRequest(allocator, surface, use, state);
    const invocation = manifest.surfaceEntry(manifestName(surface)) orelse return error.SurfaceNotFound;
    var resolved = try invocation.resolve(manifest.root_path);
    defer resolved.deinit();

    const result = try proc.runWithInput(allocator, io, resolved.argv, request, resolved.cwd, resolved.env, resolved.timeout, 64 * 1024 * 1024);
    defer result.deinit(allocator);
    if (result.stderr.len > 0) try files.writeAllErr(result.stderr);

    const local = exec_io.selectResponse(allocator, invocation.response, use.outputs, result.stdout) catch |err| return err;
    defer exec_io.freeLocal(local, allocator);
    applyLocal(allocator, state, use.outputs, local) catch |err| return err;

    const node_key = try exec_io.shapeKey(allocator, use);
    const node = try store.advance("shape", node_key, null, request, result.stdout);
    try lineage.append(allocator, node);
}

fn runShapeInto(allocator: Allocator, io: std.Io, store: *Substrate, shape: circuitry.Shape, state: *State) anyerror!void {
    var lineage = std.ArrayList([]const u8).empty;
    defer lineage.deinit(allocator);

    if (shape.text.len > 0) {
        const root_inputs = try variablesToRefs(allocator, shape.inputs);
        const root_outputs = try variablesToRefs(allocator, shape.outputs);
        const root = circuitry.Step{
            .allocator = allocator,
            .name = "$root",
            .file = null,
            .text = shape.text,
            .instructions = null,
            .inputs = root_inputs,
            .outputs = root_outputs,
            .fields = shape.fields,
        };
        try runStep(allocator, io, store, state, &lineage, root);
    }

    for (shape.steps) |use| try runStep(allocator, io, store, state, &lineage, use);
}

fn surfaceRequest(allocator: Allocator, surface: []const u8, use: circuitry.Step, state: *State) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "surface: {s}\n", .{surface});
    for (use.fields) |field| {
        if (std.mem.eql(u8, field.name, "surface")) continue;
        try appendHostField(allocator, &out, state, field.name, field.value);
    }
    try out.appendSlice(allocator, "text: |\n");
    try exec_io.appendIndentedLines(allocator, &out, use.text);
    try out.appendSlice(allocator, "in:\n");
    for (use.inputs) |take| {
        const value = state.get(bare(take.visible orelse take.local)) orelse return error.MissingStepInput;
        try out.print(allocator, "  {s}: ", .{take.local});
        try exec_io.appendYamlInline(allocator, &out, &.{ .string = value });
        try out.appendSlice(allocator, "\n");
    }
    try out.appendSlice(allocator, "out:\n");
    for (use.outputs) |give| {
        try out.print(allocator, "  {s}: ", .{give.local});
        try exec_io.appendYamlInline(allocator, &out, &.{ .string = give.visible orelse give.local });
        try out.appendSlice(allocator, "\n");
    }
    return out.toOwnedSlice(allocator);
}
fn applyLocal(allocator: Allocator, state: *State, outputs: []const circuitry.Binding, local: []const exec_io.LocalOutput) !void {
    _ = allocator;
    for (outputs) |give| {
        const wanted = bare(give.local);
        const value = findLocal(local, wanted) orelse return error.InvalidPackageOutput;
        try state.set(give.visible orelse give.local, value);
    }
}

fn findLocal(local: []const exec_io.LocalOutput, name: []const u8) ?[]const u8 {
    for (local) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
    return null;
}

fn loadManifest(allocator: Allocator, store: *Substrate, surface: []const u8) !package.Manifest {
    const ref = try package.parseRef(surface);
    const pkg = (try store.getPackage(ref.alias)) orelse return error.PackageNotInstalled;
    defer store.freePackage(pkg);
    return package.Manifest.open(allocator, pkg.root);
}

fn manifestName(surface: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, surface, '.') orelse return surface;
    return surface[dot + 1 ..];
}

fn hostField(fields: []const circuitry.HostField, key: []const u8) ?[]const u8 {
    for (fields) |field| if (std.mem.eql(u8, field.name, key)) return exec_io.scalarText(field.value);
    return null;
}

fn defaultSurface(allocator: Allocator, io: std.Io) ![]const u8 {
    _ = io;
    var settings = try config_cmd.loadSettings(allocator);
    defer settings.deinit();
    return try allocator.dupe(u8, settings.defaultSurface());
}

fn appendHostField(allocator: Allocator, out: *std.ArrayList(u8), state: *State, key: []const u8, value: *const serde.yaml.Value) !void {
    if (value.* == .string) {
        if (state.get(bare(value.string))) |resolved| {
            try out.print(allocator, "{s}: ", .{key});
            try exec_io.appendYamlInline(allocator, out, &.{ .string = resolved });
            try out.appendSlice(allocator, "\n");
            return;
        }
    }
    try out.print(allocator, "{s}: ", .{key});
    try exec_io.appendYamlInline(allocator, out, value);
    try out.appendSlice(allocator, "\n");
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

fn findArg(args: []const []const u8, name: []const u8) ?[]const u8 {
    const bare_name = bare(name);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, bare_name)) return arg;
        if (std.mem.startsWith(u8, arg, bare_name) and arg.len > bare_name.len and arg[bare_name.len] == '=') return arg[bare_name.len + 1 ..];
    }
    return null;
}

fn printProblems(problems: []const []const u8) !void {
    for (problems) |problem| {
        try files.writeAllErr("fix: ");
        try files.writeAllErr(problem);
        try files.writeAllErr("\n");
    }
}
