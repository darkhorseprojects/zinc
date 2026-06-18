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
    for (shape.takes) |take| {
        if (findArg(args, take.name)) |value| try state.set(bare(take.name), value);
    }

    var lineage = std.ArrayList([]const u8).empty;
    errdefer lineage.deinit(aa);

    if (shape.does.len > 0) {
        const root_takes = try variablesToRefs(aa, shape.takes);
        const root_gives = try variablesToRefs(aa, shape.gives);
        const root = circuitry.Use{
            .allocator = aa,
            .name = "$root",
            .shape = null,
            .does = shape.does,
            .instructions = null,
            .takes = root_takes,
            .gives = root_gives,
            .fields = shape.fields,
        };
        try runUse(aa, io, store, &state, &lineage, root);
    }

    for (shape.uses) |use| try runUse(aa, io, store, &state, &lineage, use);

    const output = try exec_io.shapeTextResult(aa, &state, shape.gives);
    const lineage_bytes = try exec_io.lineageYaml(aa, lineage.items);
    return .{ .arena = arena, .output = output, .lineage = lineage_bytes };
}

fn variablesToRefs(allocator: Allocator, items: []const circuitry.Variable) ![]circuitry.VariableRef {
    var out = std.ArrayList(circuitry.VariableRef).empty;
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

fn runUse(allocator: Allocator, io: std.Io, store: *Substrate, state: *State, lineage: *std.ArrayList([]const u8), use: circuitry.Use) anyerror!void {
    if (use.shape) |shape_ref| {
        const path = if (std.mem.startsWith(u8, shape_ref, "./"))
            try absolute(allocator, io, shape_ref)
        else
            try package.resolve(allocator, store, "$root", shape_ref);
        defer allocator.free(path);
        const bytes = try files.readLimited(allocator, path, 10 * 1024 * 1024);
        defer allocator.free(bytes);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const nested = try circuitry.parse(arena.allocator(), bytes);
        var nested_state = State.init(allocator);
        defer nested_state.deinit();
        for (use.takes) |take| {
            const visible = take.visible orelse take.local;
            const value = state.get(visible) orelse return error.MissingUseInput;
            try nested_state.set(take.local, value);
        }
        try runShapeInto(allocator, io, store, nested, &nested_state);
        for (use.gives) |give| {
            const value = nested_state.get(give.local) orelse return error.MissingUseOutput;
            try state.set(give.visible orelse give.local, value);
        }
        return;
    }

    const software = hostField(use.fields, "software") orelse (try defaultSoftware(allocator, io));
    var manifest = try loadManifest(allocator, store, software);
    defer manifest.deinit();
    const request = try packageRequest(allocator, software, use, state);
    const invocation = manifest.softwareEntry(manifestName(software)) orelse return error.SoftwareNotFound;
    var resolved = try invocation.resolve(manifest.root_path);
    defer resolved.deinit();

    const result = try proc.runWithInput(allocator, io, resolved.argv, request, resolved.cwd, resolved.env, resolved.timeout, 64 * 1024 * 1024);
    defer result.deinit(allocator);
    if (result.stderr.len > 0) try files.writeAllErr(result.stderr);

    const local = exec_io.interpretOutput(allocator, invocation.gives, use.gives, result.stdout) catch |err| return err;
    defer exec_io.freeLocal(local, allocator);
    applyLocal(allocator, state, use.gives, local) catch |err| return err;

    const node_key = try exec_io.shapeKey(allocator, use);
    const node = try store.advance("shape", node_key, null, request, result.stdout);
    try lineage.append(allocator, node);
}

fn runShapeInto(allocator: Allocator, io: std.Io, store: *Substrate, shape: circuitry.Shape, state: *State) anyerror!void {
    var lineage = std.ArrayList([]const u8).empty;
    defer lineage.deinit(allocator);

    if (shape.does.len > 0) {
        const root_takes = try variablesToRefs(allocator, shape.takes);
        const root_gives = try variablesToRefs(allocator, shape.gives);
        const root = circuitry.Use{
            .allocator = allocator,
            .name = "$root",
            .shape = null,
            .does = shape.does,
            .instructions = null,
            .takes = root_takes,
            .gives = root_gives,
            .fields = shape.fields,
        };
        try runUse(allocator, io, store, state, &lineage, root);
    }

    for (shape.uses) |use| try runUse(allocator, io, store, state, &lineage, use);
}

fn packageRequest(allocator: Allocator, software: []const u8, use: circuitry.Use, state: *State) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "software: {s}\n", .{software});
    for (use.fields) |field| {
        if (std.mem.eql(u8, field.name, "software")) continue;
        try appendHostField(allocator, &out, state, field.name, field.value);
    }
    try out.appendSlice(allocator, "does: |\n");
    try exec_io.appendIndentedLines(allocator, &out, use.does);
    try out.appendSlice(allocator, "takes:\n");
    for (use.takes) |take| {
        const value = state.get(bare(take.visible orelse take.local)) orelse return error.MissingUseInput;
        try out.print(allocator, "  {s}: ", .{take.local});
        try exec_io.appendYamlInline(allocator, &out, &.{ .string = value });
        try out.appendSlice(allocator, "\n");
    }
    try out.appendSlice(allocator, "gives:\n");
    for (use.gives) |give| {
        try out.print(allocator, "  {s}: ", .{give.local});
        try exec_io.appendYamlInline(allocator, &out, &.{ .string = give.visible orelse give.local });
        try out.appendSlice(allocator, "\n");
    }
    return out.toOwnedSlice(allocator);
}
fn applyLocal(allocator: Allocator, state: *State, gives: []const circuitry.VariableRef, local: []const exec_io.LocalOutput) !void {
    _ = allocator;
    for (gives) |give| {
        const wanted = bare(give.local);
        const value = findLocal(local, wanted) orelse return error.InvalidPackageOutput;
        try state.set(give.visible orelse give.local, value);
    }
}

fn findLocal(local: []const exec_io.LocalOutput, name: []const u8) ?[]const u8 {
    for (local) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
    return null;
}

fn loadManifest(allocator: Allocator, store: *Substrate, software: []const u8) !package.Manifest {
    const ref = try package.parseRef(software);
    const pkg = (try store.getPackage(ref.alias)) orelse return error.PackageNotInstalled;
    defer store.freePackage(pkg);
    return package.Manifest.open(allocator, pkg.root);
}

fn manifestName(software: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, software, '.') orelse return software;
    return software[dot + 1 ..];
}

fn hostField(fields: []const circuitry.HostField, key: []const u8) ?[]const u8 {
    for (fields) |field| if (std.mem.eql(u8, field.name, key)) return exec_io.scalarText(field.value);
    return null;
}

fn defaultSoftware(allocator: Allocator, io: std.Io) ![]const u8 {
    _ = io;
    var settings = try config_cmd.loadSettings(allocator);
    defer settings.deinit();
    return try allocator.dupe(u8, settings.defaultSoftware());
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
