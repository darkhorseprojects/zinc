const std = @import("std");
const serde = @import("serde");
const circuitry = @import("circuitry");
const files = @import("io/fs.zig");
const config_cmd = @import("cmd/config.zig");
const package = @import("package.zig");
const proc = @import("io/process.zig");
const exec_io = @import("execute/io.zig");
const Substrate = @import("substrate.zig").Store;

const Allocator = std.mem.Allocator;

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    output: []const u8,
    events: []const u8,

    pub fn deinit(self: *const Result) void { self.arena.deinit(); }
};

pub fn runShape(allocator: Allocator, io: std.Io, store: *Substrate, shape: circuitry.Shape, args: []const []const u8) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var state = State.init(aa);
    for (shape.inputs) |take| if (findArg(args, take.name)) |arg_value| try state.set(bare(take.name), arg_value);

    var events = std.ArrayList([]const u8).empty;
    errdefer events.deinit(aa);
    const root_preserve = preserveField(shape.fields);
    const run_id = try runId(aa, shape.name);
    var advance: usize = 0;
    for (shape.entries) |entry| {
        try runEntry(aa, io, store, &state, &events, run_id, &advance, root_preserve, entry);
    }

    const output = try exec_io.shapeTextResult(aa, &state, shape.outputs);
    const event_bytes = try exec_io.eventsYaml(aa, events.items);
    return .{ .arena = arena, .output = output, .events = event_bytes };
}

pub fn readShape(allocator: Allocator, path: []const u8) ![]const u8 { return try files.readLimited(allocator, path, 10 * 1024 * 1024); }
pub fn parseShape(allocator: Allocator, bytes: []const u8) !circuitry.Shape { return try circuitry.parse(allocator, bytes); }
pub fn writeResult(result: Result) !void { try files.writeAllOut(result.output); }

const State = struct {
    allocator: Allocator,
    values: std.StringHashMap([]const u8),

    fn init(allocator: Allocator) State { return .{ .allocator = allocator, .values = std.StringHashMap([]const u8).init(allocator) }; }
    pub fn get(self: *State, name: []const u8) ?[]const u8 { return self.values.get(bare(name)); }
    fn set(self: *State, visible: []const u8, value: []const u8) !void {
        const key = bare(visible);
        const copy = try self.allocator.dupe(u8, value);
        if (self.values.fetchRemove(key)) |old| self.allocator.free(old.value);
        try self.values.put(key, copy);
    }
};

fn runEntry(allocator: Allocator, io: std.Io, store: *Substrate, state: *State, events: *std.ArrayList([]const u8), run_id: []const u8, advance: *usize, root_preserve: ?bool, entry: circuitry.Entry) anyerror!void {
    if (entry.file) |file_ref| {
        const path = if (std.mem.startsWith(u8, file_ref, "./")) try absolute(allocator, io, file_ref) else try package.resolve(allocator, store, "$root", file_ref);
        defer allocator.free(path);
        const bytes = try files.readLimited(allocator, path, 10 * 1024 * 1024);
        defer allocator.free(bytes);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const nested = try circuitry.parse(arena.allocator(), bytes);
        var nested_state = State.init(allocator);
        for (entry.inputs) |take| {
            const visible = take.visible orelse take.local;
            const input_value = state.get(visible) orelse return error.MissingStepInput;
            try nested_state.set(take.local, input_value);
        }
        var nested_events = std.ArrayList([]const u8).empty;
        defer nested_events.deinit(allocator);
        const nested_run = try runId(allocator, nested.name);
        defer allocator.free(nested_run);
        var nested_advance: usize = 0;
        const nested_preserve = preserveField(nested.fields);
        for (nested.entries) |nested_entry| try runEntry(allocator, io, store, &nested_state, &nested_events, nested_run, &nested_advance, nested_preserve, nested_entry);
        for (entry.outputs) |give| {
            const output_value = nested_state.get(give.local) orelse return error.MissingStepOutput;
            try state.set(give.visible orelse give.local, output_value);
        }
        return;
    }

    const surface = hostField(entry.fields, "surface") orelse (try defaultSurface(allocator, io));
    defer if (hostField(entry.fields, "surface") == null) allocator.free(surface);
    var manifest = try loadManifest(allocator, store, surface);
    defer manifest.deinit();
    const request = try surfaceRequest(allocator, surface, entry, state);
    defer allocator.free(request);
    const invocation = manifest.surfaceEntry(manifestName(surface)) orelse return error.SurfaceNotFound;
    var resolved = try invocation.resolve(manifest.root_path);
    defer resolved.deinit();

    const result = try proc.runWithInput(allocator, io, resolved.argv, request, resolved.cwd, resolved.env, resolved.timeout, 64 * 1024 * 1024);
    defer result.deinit(allocator);
    if (result.stderr.len > 0) try files.writeAllErr(result.stderr);

    const local = try exec_io.selectFields(allocator, entry.outputs, result.stdout);
    defer exec_io.freeLocal(local, allocator);
    try applyLocal(state, entry.outputs, local);
    const outputs_yaml = try exec_io.outputsYaml(allocator, entry.outputs, local);
    defer allocator.free(outputs_yaml);
    const preserve = preserveField(entry.fields) orelse root_preserve orelse false;
    advance.* += 1;
    try store.recordEvent(run_id, advance.*, entry.path, surface, request, result.stdout, outputs_yaml, preserve);
    try events.append(allocator, try allocator.dupe(u8, entry.path));
}

fn surfaceRequest(allocator: Allocator, surface: []const u8, entry: circuitry.Entry, state: *State) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "surface: {s}\n", .{surface});
    for (entry.fields) |field| {
        if (std.mem.eql(u8, field.name, "surface") or std.mem.eql(u8, field.name, "preserve")) continue;
        try appendHostField(allocator, &out, state, field.name, field.value);
    }
    try out.appendSlice(allocator, "in:\n");
    for (entry.inputs) |take| {
        const input_value = state.get(bare(take.visible orelse take.local)) orelse return error.MissingStepInput;
        try out.print(allocator, "  {s}: ", .{take.local});
        try exec_io.appendYamlInline(allocator, &out, &.{ .string = input_value });
        try out.appendSlice(allocator, "\n");
    }
    try out.appendSlice(allocator, "out:\n");
    for (entry.outputs) |give| {
        try out.print(allocator, "  {s}: ", .{give.local});
        try exec_io.appendYamlInline(allocator, &out, &.{ .string = give.visible orelse give.local });
        try out.appendSlice(allocator, "\n");
    }
    return out.toOwnedSlice(allocator);
}

fn applyLocal(state: *State, outputs: []const circuitry.Binding, local: []const exec_io.LocalOutput) !void {
    for (outputs) |give| {
        const wanted = bare(give.local);
        const output_value = findLocal(local, wanted) orelse return error.InvalidPackageOutput;
        try state.set(give.visible orelse give.local, output_value);
    }
}

fn findLocal(local: []const exec_io.LocalOutput, name: []const u8) ?[]const u8 { for (local) |item| if (std.mem.eql(u8, item.name, name)) return item.value; return null; }

fn loadManifest(allocator: Allocator, store: *Substrate, surface: []const u8) !package.Manifest {
    const ref = try package.parseRef(surface);
    const pkg = (try store.getPackage(ref.alias)) orelse return error.PackageNotInstalled;
    defer store.freePackage(pkg);
    return package.Manifest.open(allocator, pkg.root);
}

fn manifestName(surface: []const u8) []const u8 { const dot = std.mem.indexOfScalar(u8, surface, '.') orelse return surface; return surface[dot + 1 ..]; }

fn hostField(fields: []const circuitry.HostField, key: []const u8) ?[]const u8 {
    for (fields) |field| if (std.mem.eql(u8, field.name, key)) return exec_io.scalarText(field.value);
    return null;
}

fn preserveField(fields: []const circuitry.HostField) ?bool {
    for (fields) |field| if (std.mem.eql(u8, field.name, "preserve")) return switch (field.value.*) { .boolean => |b| b, else => null };
    return null;
}

fn defaultSurface(allocator: Allocator, io: std.Io) ![]const u8 { _ = io; var settings = try config_cmd.loadSettings(allocator); defer settings.deinit(); return try allocator.dupe(u8, settings.defaultSurface()); }

fn appendHostField(allocator: Allocator, out: *std.ArrayList(u8), state: *State, key: []const u8, value: *const serde.yaml.Value) !void {
    if (value.* == .string) if (state.get(bare(value.string))) |resolved| {
        try out.print(allocator, "{s}: ", .{key});
        try exec_io.appendYamlInline(allocator, out, &.{ .string = resolved });
        try out.appendSlice(allocator, "\n");
        return;
    };
    try out.print(allocator, "{s}: ", .{key});
    try exec_io.appendYamlInline(allocator, out, value);
    try out.appendSlice(allocator, "\n");
}

fn bare(name: []const u8) []const u8 { return if (name.len > 0 and name[0] == '$') name[1..] else name; }

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

fn runId(allocator: Allocator, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}", .{name});
}
