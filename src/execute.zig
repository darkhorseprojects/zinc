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

pub const Advance = union(enum) {
    advanced: []u8,
    complete: []u8,
    waiting,

    pub fn deinit(self: Advance, allocator: Allocator) void {
        switch (self) {
            .advanced => |path| allocator.free(path),
            .complete => |result| allocator.free(result),
            .waiting => {},
        }
    }
};

pub fn shape(allocator: Allocator, io: std.Io, store: *Substrate, source_path: []const u8, args: []const []const u8, settings: *const config.ConfigSettings) !void {
    const prepared = try prepare(allocator, io, store, source_path, args);
    defer allocator.free(prepared);
    const step = try advance(allocator, io, store, prepared, settings);
    defer step.deinit(allocator);
    switch (step) {
        .complete => |result| {
            if (result.len > 0) {
                try files.writeAllOut(result);
                if (result[result.len - 1] != '\n') try files.writeAllOut("\n");
            }
        },
        .advanced => {},
        .waiting => return error.ExecutionWaiting,
    }
}

pub fn prepare(allocator: Allocator, io: std.Io, store: *Substrate, source_path: []const u8, args: []const []const u8) ![]u8 {
    const abs_path = try absolute(allocator, io, source_path);
    defer allocator.free(abs_path);
    const request = try assemblyRequest(allocator, abs_path, args);
    defer allocator.free(request);
    const result = try std.fmt.allocPrint(allocator, "status: prepared\nsource: {s}\n", .{abs_path});
    defer allocator.free(result);
    const ids = try fragments.putAndChoose(store, assembly_target, request, result, std.Io.Clock.now(.real, io).toSeconds());
    return try allocator.dupe(u8, &ids.fragment);
}

pub fn advance(allocator: Allocator, io: std.Io, store: *Substrate, assembly_fragment: []const u8, settings: *const config.ConfigSettings) !Advance {
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
    const ids = try fragments.putAndChoose(store, assembly_target, prepared.request, result, std.Io.Clock.now(.real, io).toSeconds());
    _ = ids.choice;
    return .{ .complete = try allocator.dupe(u8, result) };
}

fn runShape(allocator: Allocator, io: std.Io, store: *Substrate, source_path: []const u8, args: []const []const u8, settings: *const config.ConfigSettings) ![]u8 {
    const bytes = try files.readLimited(allocator, source_path, 16 * 1024 * 1024);
    defer allocator.free(bytes);

    var loaded = try circuitry.loadText(allocator, bytes);
    defer loaded.deinit();
    var confirmation = try circuitry.confirm(allocator, &loaded);
    defer confirmation.deinit();
    if (!confirmation.ready) {
        try printProblems(confirmation.problems);
        return error.CircuitryShapeNotReady;
    }

    var state = State.init(allocator);
    defer state.deinit();
    try collectInputs(allocator, &state, confirmation.system.takes, args);

    for (confirmation.system.parts) |part| try runPart(allocator, io, store, settings, &state, "", part);
    return try shapeTextResult(allocator, &state, confirmation.system.gives);
}

const State = struct {
    allocator: Allocator,
    values: std.StringHashMap(Typed),

    fn init(allocator: Allocator) State {
        return .{ .allocator = allocator, .values = std.StringHashMap(Typed).init(allocator) };
    }

    fn deinit(self: *State) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.values.deinit();
    }
};

const Typed = struct {
    type_label: ?[]u8,
    text: []u8,

    fn deinit(self: *Typed, allocator: Allocator) void {
        if (self.type_label) |label| allocator.free(label);
        allocator.free(self.text);
    }
};

fn runPart(allocator: Allocator, io: std.Io, store: *Substrate, settings: *const config.ConfigSettings, state: *State, prefix: []const u8, part: circuitry.NormalizedPart) anyerror!void {
    _ = prefix;
    if (part.shape) |shape_ref| return try runShapePart(allocator, io, store, settings, state, shape_ref, part);

    const model_name = part.model orelse settings.defaultModel();
    const preset = settings.modelPreset(model_name) orelse return error.ModelPresetNotFound;
    const adapter_ref = preset.adapter orelse return error.ModelAdapterMissing;
    const request = try adapterRequest(allocator, model_name, preset, state, part);
    defer allocator.free(request);
    const choice_hex = fragments.choice(adapter_ref, request);

    if (try fragments.chosen(store, &choice_hex)) |fragment_row| {
        defer store.freeFragment(fragment_row);
        try applyFragmentResult(allocator, state, part, fragment_row.result);
        return;
    }

    const adapter_path = if (package.parseRef(adapter_ref)) |_| try package.resolveRef(allocator, store, adapter_ref) else |_| try allocator.dupe(u8, adapter_ref);
    defer allocator.free(adapter_path);
    const request_path = try tempFile(allocator, "adapter-request.yaml", request);
    defer allocator.free(request_path);

    const result = try proc.run(allocator, io, &.{ adapter_path, request_path }, null, 64 * 1024 * 1024);
    defer result.deinit(allocator);
    if (result.stderr.len > 0) try files.writeAllErr(result.stderr);
    if (result.code != 0) return error.AdapterFailed;

    try applyFragmentResult(allocator, state, part, result.stdout);
    _ = try fragments.putAndChoose(store, adapter_ref, request, result.stdout, std.Io.Clock.now(.real, io).toSeconds());
}

fn runShapePart(allocator: Allocator, io: std.Io, store: *Substrate, settings: *const config.ConfigSettings, parent: *State, shape_ref: []const u8, part: circuitry.NormalizedPart) anyerror!void {
    const request = try shapeRequest(allocator, parent, shape_ref, part);
    defer allocator.free(request);
    const target = try std.fmt.allocPrint(allocator, "zinc.shape:{s}", .{shape_ref});
    defer allocator.free(target);
    const choice_hex = fragments.choice(target, request);

    if (try fragments.chosen(store, &choice_hex)) |fragment_row| {
        defer store.freeFragment(fragment_row);
        try applyFragmentResult(allocator, parent, part, fragment_row.result);
        return;
    }

    const shape_path = if (package.parseRef(shape_ref)) |_| try package.resolveRef(allocator, store, shape_ref) else |_| try allocator.dupe(u8, shape_ref);
    defer allocator.free(shape_path);
    var loaded = try circuitry.loadFile(io, allocator, shape_path);
    defer loaded.deinit();
    var confirmation = try circuitry.confirm(allocator, &loaded);
    defer confirmation.deinit();
    if (!confirmation.ready) return error.CircuitryShapeNotReady;

    var child = State.init(allocator);
    defer child.deinit();
    try mapChildInputs(allocator, parent, &child, part, confirmation.system.takes);

    for (confirmation.system.parts) |child_part| try runPart(allocator, io, store, settings, &child, "", child_part);
    try mapChildOutputs(allocator, parent, &child, part, confirmation.system.gives);

    const result = try shapeResult(allocator, &child, confirmation.system.gives);
    defer allocator.free(result);
    _ = try fragments.putAndChoose(store, target, request, result, std.Io.Clock.now(.real, io).toSeconds());
}

fn mapChildInputs(allocator: Allocator, parent: *State, child: *State, part: circuitry.NormalizedPart, child_takes: []const circuitry.NormalizedValue) !void {
    for (child_takes) |take| {
        const parent_binding = bindingForLocal(part.takes, bare(take.name)) orelse return error.MissingShapeInputBinding;
        const found = parent.values.get(parent_binding.value) orelse return error.MissingInputValue;
        try child.values.put(try allocator.dupe(u8, take.name), .{ .type_label = if (found.type_label) |label| try allocator.dupe(u8, label) else null, .text = try allocator.dupe(u8, found.text) });
    }
}

fn mapChildOutputs(allocator: Allocator, parent: *State, child: *State, part: circuitry.NormalizedPart, child_gives: []const circuitry.NormalizedValue) !void {
    for (child_gives) |give| {
        const parent_binding = bindingForLocal(part.gives, bare(give.name)) orelse return error.MissingShapeOutputBinding;
        const found = child.values.get(give.name) orelse return error.MissingOutputValue;
        try putTyped(allocator, parent, parent_binding.value, found);
    }
}

fn bindingForLocal(bindings: []const circuitry.NormalizedBinding, local: []const u8) ?circuitry.NormalizedBinding {
    for (bindings) |binding| if (std.mem.eql(u8, binding.local orelse bare(binding.value), local)) return binding;
    return null;
}

fn adapterRequest(allocator: Allocator, model_name: []const u8, preset: config.ModelPreset, state: *State, part: circuitry.NormalizedPart) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "model: {s}\npart: {s}\n", .{ model_name, part.name });
    try out.appendSlice(allocator, "params:\n");
    if (preset.params) |params| try appendYaml(allocator, &out, params, 2);
    try out.appendSlice(allocator, "instruction: |\n");
    var lines = std.mem.splitScalar(u8, part.instructions orelse "", '\n');
    while (lines.next()) |line| try out.print(allocator, "  {s}\n", .{line});
    try out.appendSlice(allocator, "takes:\n");
    for (part.takes) |take| {
        const local = take.local orelse bare(take.value);
        const found = state.values.get(take.value) orelse return error.MissingInputValue;
        try out.print(allocator, "  {s}: |\n", .{local});
        var value_lines = std.mem.splitScalar(u8, found.text, '\n');
        while (value_lines.next()) |line| try out.print(allocator, "    {s}\n", .{line});
    }
    try out.appendSlice(allocator, "gives:\n");
    for (part.gives) |give| try out.print(allocator, "  {s}: {s}\n", .{ give.local orelse bare(give.value), give.type_label orelse "text" });
    return out.toOwnedSlice(allocator);
}

fn shapeRequest(allocator: Allocator, state: *State, shape_ref: []const u8, part: circuitry.NormalizedPart) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "shape: {s}\npart: {s}\ninstruction: |\n", .{ shape_ref, part.name });
    var lines = std.mem.splitScalar(u8, part.instructions orelse "", '\n');
    while (lines.next()) |line| try out.print(allocator, "  {s}\n", .{line});
    try out.appendSlice(allocator, "takes:\n");
    for (part.takes) |take| {
        const found = state.values.get(take.value) orelse return error.MissingInputValue;
        try out.print(allocator, "  {s}: |\n", .{ take.local orelse bare(take.value) });
        var value_lines = std.mem.splitScalar(u8, found.text, '\n');
        while (value_lines.next()) |line| try out.print(allocator, "    {s}\n", .{line});
    }
    return out.toOwnedSlice(allocator);
}

fn applyFragmentResult(allocator: Allocator, state: *State, part: circuitry.NormalizedPart, bytes: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = try serde.yaml.parse(arena.allocator(), bytes);
    try applyAdapterResponse(allocator, state, part, &root);
}

fn applyAdapterResponse(allocator: Allocator, state: *State, part: circuitry.NormalizedPart, root: *const serde.yaml.Value) !void {
    const gives = yamlGet(root, "gives") orelse return error.AdapterResponseMissingGives;
    if (gives.* != .mapping) return error.AdapterResponseMissingGives;
    var it = gives.mapping.iterator();
    while (it.next()) |entry| {
        const system = systemForLocal(part.gives, entry.key_ptr.*) orelse continue;
        const out = try readTypedOutput(entry.value_ptr);
        try putTypedText(allocator, state, system, out.type_label, out.text);
    }
}

const Output = struct { type_label: ?[]const u8, text: []const u8 };

fn readTypedOutput(node: *const serde.yaml.Value) !Output {
    if (node.* == .string) return .{ .type_label = null, .text = node.string };
    if (node.* != .mapping) return error.InvalidAdapterOutput;
    const value_node = yamlGet(node, "value") orelse return error.InvalidAdapterOutput;
    if (value_node.* != .string) return error.InvalidAdapterOutput;
    const type_node = yamlGet(node, "type");
    return .{ .type_label = if (type_node) |t| if (t.* == .string) t.string else null else null, .text = value_node.string };
}

fn collectInputs(allocator: Allocator, state: *State, takes: []const circuitry.NormalizedValue, args: []const []const u8) !void {
    if (args.len != takes.len) return error.MissingRunInput;
    for (takes) |take| {
        const provided = findArg(args, take.name) orelse findArg(args, bare(take.name)) orelse return error.MissingRunInput;
        try putTypedText(allocator, state, take.name, take.type_label, provided);
    }
}

fn putTyped(allocator: Allocator, state: *State, name: []const u8, value: Typed) !void {
    try putTypedText(allocator, state, name, value.type_label, value.text);
}

fn putTypedText(allocator: Allocator, state: *State, name: []const u8, type_label: ?[]const u8, text: []const u8) !void {
    const key = try allocator.dupe(u8, name);
    errdefer allocator.free(key);
    const value = Typed{ .type_label = if (type_label) |label| try allocator.dupe(u8, label) else null, .text = try allocator.dupe(u8, text) };
    if (state.values.fetchRemove(name)) |old| {
        allocator.free(old.key);
        var old_value = old.value;
        old_value.deinit(allocator);
    }
    try state.values.put(key, value);
}

fn shapeResult(allocator: Allocator, state: *State, gives: []const circuitry.NormalizedValue) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "gives:\n");
    for (gives) |give| {
        const found = state.values.get(give.name) orelse return error.MissingOutputValue;
        try out.print(allocator, "  {s}:\n    value: |\n", .{bare(give.name)});
        var lines = std.mem.splitScalar(u8, found.text, '\n');
        while (lines.next()) |line| try out.print(allocator, "      {s}\n", .{line});
        if (found.type_label) |label| try out.print(allocator, "    type: {s}\n", .{label});
    }
    return out.toOwnedSlice(allocator);
}

fn shapeTextResult(allocator: Allocator, state: *State, gives: []const circuitry.NormalizedValue) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (gives) |give| {
        const found = state.values.get(give.name) orelse return error.MissingOutputValue;
        if (out.items.len != 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, found.text);
    }
    return out.toOwnedSlice(allocator);
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
            source.* = line["source: ".len..];
            in_args = false;
        } else if (std.mem.eql(u8, line, "args:")) {
            in_args = true;
        } else if (in_args and std.mem.startsWith(u8, line, "  - ")) {
            try args.append(allocator, line["  - ".len..]);
        }
    }
}

fn findArg(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse continue;
        if (std.mem.eql(u8, arg[0..eq], name)) return arg[eq + 1 ..];
    }
    return null;
}

fn systemForLocal(bindings: []const circuitry.NormalizedBinding, local: []const u8) ?[]const u8 {
    for (bindings) |binding| if (std.mem.eql(u8, binding.local orelse bare(binding.value), local)) return binding.value;
    return null;
}

fn bare(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "$")) name[1..] else name;
}

fn tempFile(allocator: Allocator, name: []const u8, content: []const u8) ![]u8 {
    const path = try layout.tempRunPath(allocator, name);
    try files.write(path, content);
    return path;
}

fn printProblems(problems: []const []const u8) !void {
    try files.writeAllErr("Circuitry shape is not ready.\n");
    for (problems) |problem| {
        try files.writeAllErr("- ");
        try files.writeAllErr(problem);
        try files.writeAllErr("\n");
    }
}

fn appendYaml(allocator: Allocator, out: *std.ArrayList(u8), node: *const serde.yaml.Value, indent: usize) !void {
    if (node.* != .mapping) return;
    var it = node.mapping.iterator();
    while (it.next()) |entry| {
        try out.appendNTimes(allocator, ' ', indent);
        switch (entry.value_ptr.*) {
            .string => |s| try out.print(allocator, "{s}: {s}\n", .{ entry.key_ptr.*, s }),
            .integer => |i| try out.print(allocator, "{s}: {d}\n", .{ entry.key_ptr.*, i }),
            .float => |f| try out.print(allocator, "{s}: {d}\n", .{ entry.key_ptr.*, f }),
            .boolean => |b| try out.print(allocator, "{s}: {s}\n", .{ entry.key_ptr.*, if (b) "true" else "false" }),
            .mapping => {
                try out.print(allocator, "{s}:\n", .{entry.key_ptr.*});
                try appendYaml(allocator, out, entry.value_ptr, indent + 2);
            },
            else => try out.print(allocator, "{s}:\n", .{entry.key_ptr.*}),
        }
    }
}

fn yamlGet(node: *const serde.yaml.Value, key: []const u8) ?*const serde.yaml.Value {
    if (node.* != .mapping) return null;
    return node.mapping.getPtr(key);
}

fn absolute(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
    const cwd_buf = try allocator.alloc(u8, std.fs.max_path_bytes);
    defer allocator.free(cwd_buf);
    const cwd_len = try std.process.currentPath(io, cwd_buf);
    return try std.fs.path.resolve(allocator, &.{ cwd_buf[0..cwd_len], path });
}
