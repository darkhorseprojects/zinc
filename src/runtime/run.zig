const std = @import("std");
const Store = @import("store.zig").Store;
const store_mod = @import("store.zig");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const config = @import("../cmd/config.zig");
const pkg_index = @import("../pkg/index.zig");
const path_mod = @import("../path.zig");
const serde = @import("serde");
const circuitry = @import("circuitry");

const Allocator = std.mem.Allocator;

var runtime_store_mutex: std.atomic.Mutex = .unlocked;

fn lockRuntimeStore() void {
    while (!runtime_store_mutex.tryLock()) std.Thread.yield() catch {};
}

fn unlockRuntimeStore() void {
    runtime_store_mutex.unlock();
}

const TypedValue = struct {
    allocator: Allocator,
    type_label: ?[]const u8,
    value: []const u8,

    fn deinit(self: *TypedValue) void {
        if (self.type_label) |label| self.allocator.free(label);
        self.allocator.free(self.value);
    }
};

const ValueDraft = struct {
    name: []const u8,
    type_label: ?[]const u8,
    value: []const u8,
};

const TextDraft = struct {
    path: []const u8,
    role: []const u8,
    payload: []const u8,
};

const PlanBinding = struct {
    local: ?[]const u8,
    value: []const u8,
    type_label: ?[]const u8,
};

const PlanValue = struct {
    name: []const u8,
    type_label: ?[]const u8,
    direction: []const u8,
};

const PlanPart = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8,
    shape: ?[]const u8,
    model: ?[]const u8,
    instructions: ?[]const u8,
    takes: []PlanBinding,
    gives: []PlanBinding,
};

const PlanDoc = struct {
    allocator: Allocator,
    takes: []PlanValue,
    gives: []PlanValue,
    parts: []PlanPart,

    fn deinit(self: *PlanDoc) void {
        for (self.takes) |value| freePlanValue(self.allocator, value);
        self.allocator.free(self.takes);
        for (self.gives) |value| freePlanValue(self.allocator, value);
        self.allocator.free(self.gives);
        for (self.parts) |*part| freePlanPart(self.allocator, part);
        self.allocator.free(self.parts);
    }
};

const RunExecution = struct {
    io: std.Io,
    store: *Store,
    id: []const u8,
    doc_id: []const u8,
    started_at: i64,
    active: bool = true,

    fn start(io: std.Io, store: *Store, id: []const u8, doc_id: []const u8) !RunExecution {
        const started_at = std.Io.Clock.now(.real, io).toSeconds();
        try store.insertRun(.{
            .id = id,
            .doc_id = doc_id,
            .status = "running",
            .started_at = started_at,
            .finished_at = null,
        });
        return .{ .io = io, .store = store, .id = id, .doc_id = doc_id, .started_at = started_at };
    }

    fn finish(self: *RunExecution) !void {
        if (!self.active) return;
        try self.store.insertRun(.{
            .id = self.id,
            .doc_id = self.doc_id,
            .status = "finished",
            .started_at = self.started_at,
            .finished_at = std.Io.Clock.now(.real, self.io).toSeconds(),
        });
        self.active = false;
    }

    fn fail(self: *RunExecution) void {
        if (!self.active) return;
        self.store.insertRun(.{
            .id = self.id,
            .doc_id = self.doc_id,
            .status = "failed",
            .started_at = self.started_at,
            .finished_at = std.Io.Clock.now(.real, self.io).toSeconds(),
        }) catch {};
        self.active = false;
    }
};

const PartResult = struct {
    allocator: Allocator,
    name: []const u8,
    doc_part_id: []const u8,
    outputs: std.ArrayList(ValueDraft) = .empty,
    texts: std.ArrayList(TextDraft) = .empty,

    fn init(allocator: Allocator, name: []const u8, doc_part_id: []const u8) !PartResult {
        return .{ .allocator = allocator, .name = try allocator.dupe(u8, name), .doc_part_id = try allocator.dupe(u8, doc_part_id) };
    }

    fn deinit(self: *PartResult) void {
        self.allocator.free(self.name);
        self.allocator.free(self.doc_part_id);
        for (self.outputs.items) |item| {
            self.allocator.free(item.name);
            if (item.type_label) |label| self.allocator.free(label);
            self.allocator.free(item.value);
        }
        self.outputs.deinit(self.allocator);
        for (self.texts.items) |item| {
            self.allocator.free(item.path);
            self.allocator.free(item.role);
            self.allocator.free(item.payload);
        }
        self.texts.deinit(self.allocator);
    }

    fn addOutput(self: *PartResult, name: []const u8, type_label: ?[]const u8, value: []const u8) !void {
        try self.outputs.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .type_label = if (type_label) |label| try self.allocator.dupe(u8, label) else null,
            .value = try self.allocator.dupe(u8, value),
        });
    }

    fn addText(self: *PartResult, path: []const u8, role: []const u8, payload: []const u8) !void {
        try self.texts.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .role = try self.allocator.dupe(u8, role),
            .payload = try self.allocator.dupe(u8, payload),
        });
    }
};

fn materializeShapeFile(allocator: Allocator, io: std.Io, store: *Store, abs_path: []const u8) ![]u8 {
    const source_bytes = try files.readLimited(allocator, abs_path, 16 * 1024 * 1024);
    defer allocator.free(source_bytes);

    var shape = try circuitry.loadText(allocator, source_bytes);
    defer shape.deinit();
    var confirmation = try circuitry.confirm(allocator, &shape);
    defer confirmation.deinit();
    if (!confirmation.ready) {
        try files.writeAllErr("Error: Circuitry document is not ready to run.\n");
        for (confirmation.problems) |prob| {
            try files.writeAllErr("- ");
            try files.writeAllErr(prob);
            try files.writeAllErr("\n");
        }
        return error.CircuitryShapeNotReady;
    }

    const doc_id = try circuitry.stableDocId(allocator, source_bytes);
    errdefer allocator.free(doc_id);
    lockRuntimeStore();
    errdefer unlockRuntimeStore();
    try store.insertDoc(.{
        .id = doc_id,
        .path = abs_path,
        .name = confirmation.card.name,
        .source_payload = source_bytes,
        .updated_at = std.Io.Clock.now(.real, io).toSeconds(),
    });
    try store.clearDocFacts(doc_id);
    try storeNormalizedDoc(allocator, store, doc_id, &confirmation.system);
    unlockRuntimeStore();
    return doc_id;
}

fn storeNormalizedDoc(allocator: Allocator, store: *Store, doc_id: []const u8, doc: *const circuitry.NormalizedDoc) !void {
    for (doc.takes, 0..) |value, index| try storeDocValue(allocator, store, doc_id, value, index);
    for (doc.gives, 0..) |value, index| try storeDocValue(allocator, store, doc_id, value, index);
    for (doc.parts, 0..) |part, index| {
        const part_path = try path_mod.join(allocator, &.{ "uses", path_mod.valueSegment(part.name) });
        defer allocator.free(part_path);
        const part_id = try scopedDocId(allocator, doc_id, part_path);
        defer allocator.free(part_id);
        try store.insertDocPart(.{ .id = part_id, .doc_id = doc_id, .path = part_path, .order_index = @intCast(index), .name = part.name, .shape = part.shape, .model = part.model, .instructions = part.instructions });
        for (part.takes) |binding| try storeDocBinding(allocator, store, doc_id, part_id, part.name, .takes, binding);
        for (part.gives) |binding| try storeDocBinding(allocator, store, doc_id, part_id, part.name, .gives, binding);
    }
    for (doc.diagnostics, 0..) |diagnostic, index| {
        const id = try std.fmt.allocPrint(allocator, "{s}:diagnostic:{d}", .{ doc_id, index });
        defer allocator.free(id);
        const diag_path = try std.fmt.allocPrint(allocator, "diagnostics/{d}", .{index});
        defer allocator.free(diag_path);
        try store.insertDocDiagnostic(.{ .id = id, .doc_id = doc_id, .path = diag_path, .severity = "error", .kind = diagnostic.kind, .message = diagnostic.message });
    }
}

fn storeDocValue(allocator: Allocator, store: *Store, doc_id: []const u8, value: circuitry.NormalizedValue, order_index: usize) !void {
    const direction = @tagName(value.direction);
    const value_path = try path_mod.valuePath(allocator, direction, value.name);
    defer allocator.free(value_path);
    const id = try scopedDocId(allocator, doc_id, value_path);
    defer allocator.free(id);
    try store.insertDocValue(.{ .id = id, .doc_id = doc_id, .path = value_path, .order_index = @intCast(order_index), .name = value.name, .type_label = value.type_label, .direction = direction });
}

fn storeDocBinding(allocator: Allocator, store: *Store, doc_id: []const u8, part_id: []const u8, part_name: []const u8, side: circuitry.Direction, binding: circuitry.NormalizedBinding) !void {
    const local_or_value = binding.local orelse binding.value;
    const binding_path = try path_mod.join(allocator, &.{ "uses", path_mod.valueSegment(part_name), @tagName(side), path_mod.valueSegment(local_or_value) });
    defer allocator.free(binding_path);
    const id = try scopedDocId(allocator, doc_id, binding_path);
    defer allocator.free(id);
    try store.insertDocBinding(.{ .id = id, .doc_id = doc_id, .path = binding_path, .part_id = part_id, .side = @tagName(side), .local_name = binding.local, .value_name = binding.value, .type_label = binding.type_label });
}

fn scopedDocId(allocator: Allocator, doc_id: []const u8, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ doc_id, key });
}

pub fn runShape(allocator: Allocator, io: std.Io, store: *Store, shape_path: []const u8, args: []const []const u8, settings: *const config.ConfigSettings) !void {
    const abs_path = try std.fs.path.resolve(allocator, &.{shape_path});
    defer allocator.free(abs_path);

    var shape = try circuitry.loadFile(io, allocator, abs_path);
    defer shape.deinit();
    const doc_id = try materializeShapeFile(allocator, io, store, abs_path);
    defer allocator.free(doc_id);
    var plan_doc = try loadPlanDoc(allocator, store, doc_id);
    defer plan_doc.deinit();

    var values = std.StringHashMap(TypedValue).init(allocator);
    defer freeValues(&values);

    var run_settings = settings.*;
    applyShapeRuntime(&run_settings, &shape.root);

    try collectInputs(allocator, &values, plan_doc.takes, args, shape_path);
    const required = try requiredFrontier(allocator, plan_doc.parts, plan_doc.gives);
    defer allocator.free(required);
    const plan_text = try planText(allocator, plan_doc.parts, required);
    defer allocator.free(plan_text);

    var id_buf: [16]u8 = undefined;
    const run_id = try std.fmt.allocPrint(allocator, "run_{s}", .{try randomHex(io, &id_buf)});
    defer allocator.free(run_id);
    var execution = try RunExecution.start(io, store, run_id, doc_id);
    defer execution.fail();
    try files.writeAllOut("Run URI: zinc://runs/");
    try files.writeAllOut(run_id);
    try files.writeAllOut("\n");

    try storeInputValues(allocator, store, run_id, &values, plan_doc.takes);
    try storePlanSteps(allocator, store, run_id, plan_doc.parts, required);
    const plan_id = try textId(allocator, run_id, "plan");
    defer allocator.free(plan_id);
    try store.insertRunText(.{ .id = plan_id, .run_id = run_id, .path = "plan", .role = "plan", .payload = plan_text });
    try files.writeAllOut(plan_text);
    try executePlan(allocator, io, store, run_id, abs_path, &run_settings, &values, plan_doc.parts, required, null);
    try storeOutputs(allocator, store, run_id, &values, plan_doc.gives);

    try execution.finish();

    try files.writeAllOut("\nOutputs:\n");
    for (plan_doc.gives) |give| {
        const found = values.get(give.name) orelse return error.MissingOutputValue;
        try files.writeAllOut(give.name);
        try files.writeAllOut(": ");
        try files.writeAllOut(found.value);
        try files.writeAllOut("\n");
    }
}

fn loadPlanDoc(allocator: Allocator, store: *Store, doc_id: []const u8) !PlanDoc {
    lockRuntimeStore();
    defer unlockRuntimeStore();
    const values = try store.listDocValues(doc_id);
    defer {
        for (values) |row| store.freeDocValue(row);
        allocator.free(values);
    }
    const parts = try store.listDocParts(doc_id);
    defer {
        for (parts) |row| store.freeDocPart(row);
        allocator.free(parts);
    }
    const bindings = try store.listDocBindings(doc_id);
    defer {
        for (bindings) |row| store.freeDocBinding(row);
        allocator.free(bindings);
    }

    var takes: std.ArrayList(PlanValue) = .empty;
    errdefer freePlanValues(allocator, &takes);
    var gives: std.ArrayList(PlanValue) = .empty;
    errdefer freePlanValues(allocator, &gives);
    for (values) |value| {
        const item = try clonePlanValue(allocator, value);
        if (std.mem.eql(u8, value.direction, "takes")) try takes.append(allocator, item) else try gives.append(allocator, item);
    }

    var plan_parts: std.ArrayList(PlanPart) = .empty;
    errdefer {
        for (plan_parts.items) |*part| freePlanPart(allocator, part);
        plan_parts.deinit(allocator);
    }
    for (parts) |part| {
        const part_takes = try bindingsForPart(allocator, bindings, part.id, "takes");
        errdefer freePlanBindings(allocator, part_takes);
        const part_gives = try bindingsForPart(allocator, bindings, part.id, "gives");
        errdefer freePlanBindings(allocator, part_gives);
        try plan_parts.append(allocator, .{
            .id = try allocator.dupe(u8, part.id),
            .name = try allocator.dupe(u8, part.name),
            .path = try allocator.dupe(u8, part.path),
            .shape = if (part.shape) |s| try allocator.dupe(u8, s) else null,
            .model = if (part.model) |m| try allocator.dupe(u8, m) else null,
            .instructions = if (part.instructions) |i| try allocator.dupe(u8, i) else null,
            .takes = part_takes,
            .gives = part_gives,
        });
    }

    return .{
        .allocator = allocator,
        .takes = try takes.toOwnedSlice(allocator),
        .gives = try gives.toOwnedSlice(allocator),
        .parts = try plan_parts.toOwnedSlice(allocator),
    };
}

fn bindingsForPart(allocator: Allocator, bindings: []const store_mod.circuitry_doc_bindings, part_id: []const u8, side: []const u8) ![]PlanBinding {
    var out: std.ArrayList(PlanBinding) = .empty;
    errdefer freePlanBindings(allocator, out.items);
    for (bindings) |binding| {
        if (!std.mem.eql(u8, binding.part_id, part_id) or !std.mem.eql(u8, binding.side, side)) continue;
        try out.append(allocator, .{
            .local = if (binding.local_name) |local| try allocator.dupe(u8, local) else null,
            .value = try allocator.dupe(u8, binding.value_name),
            .type_label = if (binding.type_label) |label| try allocator.dupe(u8, label) else null,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn clonePlanValue(allocator: Allocator, row: store_mod.circuitry_doc_values) !PlanValue {
    return .{
        .name = try allocator.dupe(u8, row.name),
        .type_label = if (row.type_label) |label| try allocator.dupe(u8, label) else null,
        .direction = try allocator.dupe(u8, row.direction),
    };
}

fn freePlanValues(allocator: Allocator, list: *std.ArrayList(PlanValue)) void {
    for (list.items) |item| freePlanValue(allocator, item);
    list.deinit(allocator);
}

fn freePlanValue(allocator: Allocator, value: PlanValue) void {
    allocator.free(value.name);
    if (value.type_label) |label| allocator.free(label);
    allocator.free(value.direction);
}

fn freePlanBindings(allocator: Allocator, bindings: []PlanBinding) void {
    for (bindings) |binding| {
        if (binding.local) |local| allocator.free(local);
        allocator.free(binding.value);
        if (binding.type_label) |label| allocator.free(label);
    }
    allocator.free(bindings);
}

fn freePlanPart(allocator: Allocator, part: *PlanPart) void {
    allocator.free(part.id);
    allocator.free(part.name);
    allocator.free(part.path);
    if (part.shape) |shape_ref| allocator.free(shape_ref);
    if (part.model) |model| allocator.free(model);
    if (part.instructions) |instructions| allocator.free(instructions);
    freePlanBindings(allocator, part.takes);
    freePlanBindings(allocator, part.gives);
}

fn applyShapeRuntime(settings: *config.ConfigSettings, root: *const serde.yaml.Value) void {
    const zinc = yamlGet(root, "zinc") orelse return;
    settings.shape_zinc = zinc;
    const runtime = yamlGet(zinc, "runtime") orelse return;
    if (runtime.* != .mapping) return;
    if (yamlGet(runtime, "parallel")) |parallel| switch (parallel.*) {
        .boolean => |b| settings.runtime_parallel = b,
        else => {},
    };
    if (yamlGet(runtime, "max_parallel")) |max_parallel| switch (max_parallel.*) {
        .integer => |i| settings.runtime_max_parallel = if (i <= 0) 0 else @intCast(i),
        else => {},
    };
}

fn collectInputs(allocator: Allocator, values: *std.StringHashMap(TypedValue), takes: []const PlanValue, args: []const []const u8, shape_path: []const u8) !void {
    try validateInputArgs(takes, args, shape_path);
    for (takes) |take| {
        const raw_name = trimDollar(take.name);
        const provided = findArg(args, take.name) orelse findArg(args, raw_name) orelse unreachable;
        try values.put(try allocator.dupe(u8, take.name), .{
            .allocator = allocator,
            .type_label = if (take.type_label) |label| try allocator.dupe(u8, label) else null,
            .value = try allocator.dupe(u8, provided),
        });
    }
}

fn validateInputArgs(takes: []const PlanValue, args: []const []const u8, shape_path: []const u8) !void {
    for (args, 0..) |arg, index| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse {
            try writeInputHeader(shape_path);
            try files.writeAllErr("\nInvalid input argument:\n  ");
            try files.writeAllErr(arg);
            try files.writeAllErr("\n\nInputs use name=value syntax.\n\n");
            try writeExpectedInputs(takes);
            try writeExample(takes, shape_path);
            return error.InvalidRunInput;
        };
        if (eq == 0) {
            try writeInputHeader(shape_path);
            try files.writeAllErr("\nInvalid input argument:\n  ");
            try files.writeAllErr(arg);
            try files.writeAllErr("\n\nThe input name is empty.\n");
            return error.InvalidRunInput;
        }
        const name = arg[0..eq];
        const expected = expectedInput(takes, name) orelse {
            try writeInputHeader(shape_path);
            try files.writeAllErr("\nUnknown input:\n  ");
            try files.writeAllErr(name);
            try files.writeAllErr("\n\n");
            try writeExpectedInputs(takes);
            try writeExample(takes, shape_path);
            return error.InvalidRunInput;
        };
        try validateInputValue(expected, arg[eq + 1 ..], shape_path, takes);
        for (args[0..index]) |prior| {
            const prior_eq = std.mem.indexOfScalar(u8, prior, '=') orelse continue;
            if (sameInputName(takes, prior[0..prior_eq], name)) {
                try writeInputHeader(shape_path);
                try files.writeAllErr("\nDuplicate input:\n  ");
                try files.writeAllErr(name);
                try files.writeAllErr("\n\nEach input may be provided once.\n\n");
                try writeExpectedInputs(takes);
                return error.InvalidRunInput;
            }
        }
    }

    for (takes) |take| {
        if (findArg(args, take.name) != null or findArg(args, trimDollar(take.name)) != null) continue;
        try writeInputHeader(shape_path);
        try files.writeAllErr("\nMissing required input:\n  ");
        try writeAlignedInput(take, maxInputNameLen(takes));
        try files.writeAllErr("\n\n");
        try writeExpectedInputs(takes);
        try writeExample(takes, shape_path);
        return error.MissingRunInput;
    }
}

fn expectedInput(takes: []const PlanValue, name: []const u8) ?PlanValue {
    for (takes) |take| if (inputNameMatches(take, name)) return take;
    return null;
}

fn validateInputValue(take: PlanValue, value: []const u8, shape_path: []const u8, takes: []const PlanValue) !void {
    const label = take.type_label orelse return;
    if (!std.mem.eql(u8, label, "number")) return;
    _ = std.fmt.parseFloat(f64, value) catch {
        try writeInputHeader(shape_path);
        try files.writeAllErr("\nInvalid input:\n  ");
        try files.writeAllErr(trimDollar(take.name));
        try files.writeAllErr(" = ");
        try files.writeAllErr(value);
        try files.writeAllErr("\n\nExpected:\n  ");
        try writeAlignedInput(take, maxInputNameLen(takes));
        try files.writeAllErr("\n\n");
        try writeExample(takes, shape_path);
        return error.InvalidInputValue;
    };
}

fn sameInputName(takes: []const PlanValue, left: []const u8, right: []const u8) bool {
    for (takes) |take| if (inputNameMatches(take, left) and inputNameMatches(take, right)) return true;
    return false;
}

fn inputNameMatches(take: PlanValue, name: []const u8) bool {
    return std.mem.eql(u8, take.name, name) or std.mem.eql(u8, trimDollar(take.name), name);
}

fn writeInputHeader(shape_path: []const u8) !void {
    try files.writeAllErr("Cannot run ");
    try files.writeAllErr(shape_path);
    try files.writeAllErr("\n");
}

fn writeExpectedInputs(takes: []const PlanValue) !void {
    try files.writeAllErr("This shape expects:\n");
    const width = maxInputNameLen(takes);
    for (takes) |take| {
        try files.writeAllErr("  ");
        try writeAlignedInput(take, width);
        try files.writeAllErr("\n");
    }
}

fn writeAlignedInput(take: PlanValue, width: usize) !void {
    const name = trimDollar(take.name);
    try files.writeAllErr(name);
    var i = name.len;
    while (i < width + 2) : (i += 1) try files.writeAllErr(" ");
    try files.writeAllErr(take.type_label orelse "value");
}

fn maxInputNameLen(takes: []const PlanValue) usize {
    var width: usize = 0;
    for (takes) |take| width = @max(width, trimDollar(take.name).len);
    return width;
}

fn writeExample(takes: []const PlanValue, shape_path: []const u8) !void {
    try files.writeAllErr("\nRun it with:\n  zn run ");
    try files.writeAllErr(shape_path);
    for (takes) |take| {
        try files.writeAllErr(" ");
        try files.writeAllErr(trimDollar(take.name));
        try files.writeAllErr("=");
        try files.writeAllErr(exampleValue(take.type_label));
    }
    try files.writeAllErr("\n");
}

fn exampleValue(type_label: ?[]const u8) []const u8 {
    const label = type_label orelse return "value";
    if (std.mem.eql(u8, label, "number")) return "1";
    if (std.mem.eql(u8, label, "text")) return "text";
    return "value";
}

fn findArg(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            if (std.mem.eql(u8, arg[0..eq], name)) return arg[eq + 1 ..];
        }
    }
    return null;
}

fn planText(allocator: Allocator, uses: []const PlanPart, required: []const bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Plan:\n");
    for (uses, 0..) |entry, index| {
        if (!required[index]) continue;
        try out.appendSlice(allocator, "- ");
        try out.appendSlice(allocator, entry.name);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn requiredFrontier(allocator: Allocator, uses: []const PlanPart, gives: []const PlanValue) ![]bool {
    const required = try allocator.alloc(bool, uses.len);
    @memset(required, false);
    for (gives) |give| try requireValue(uses, required, give.name);
    return required;
}

fn requireValue(uses: []const PlanPart, required: []bool, value_name: []const u8) !void {
    const producer = producerIndex(uses, value_name) orelse return;
    if (required[producer]) return;
    required[producer] = true;
    for (uses[producer].takes) |take| try requireValue(uses, required, take.value);
}

fn producerIndex(uses: []const PlanPart, value_name: []const u8) ?usize {
    for (uses, 0..) |entry, index| {
        for (entry.gives) |give| if (std.mem.eql(u8, give.value, value_name)) return index;
    }
    return null;
}

fn executePlan(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, shape_path: []const u8, settings: *const config.ConfigSettings, values: *std.StringHashMap(TypedValue), uses: []const PlanPart, required: []const bool, trace_prefix: ?[]const u8) anyerror!void {
    var done = try allocator.alloc(bool, uses.len);
    defer allocator.free(done);
    @memset(done, false);

    var needed_count: usize = 0;
    for (required) |is_required| {
        if (is_required) needed_count += 1;
    }

    var done_count: usize = 0;
    while (done_count < needed_count) {
        if (settings.runtime_parallel) {
            const advanced = try executeReadyParallelWave(allocator, io, store, run_id, shape_path, settings, values, uses, required, done, &done_count, trace_prefix);
            if (advanced) continue;
        }

        var progressed = false;
        for (uses, 0..) |entry, index| {
            if (!required[index] or done[index] or !ready(values, entry.takes)) continue;
            try runPart(allocator, io, store, run_id, shape_path, settings, values, entry, trace_prefix);
            done[index] = true;
            done_count += 1;
            progressed = true;
            break;
        }
        if (!progressed) return error.PlanStalled;
    }
}

const WorkerContext = struct {
    io: std.Io,
    run_id: []const u8,
    entry: PlanPart,
    values: *std.StringHashMap(TypedValue),
    store: *Store,
    settings: *const config.ConfigSettings,
    shape_path: []const u8,
    trace_prefix: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    model_preset: ?config.ModelPreset = null,
    adapter_path: ?[]const u8 = null,
    result: ?PartResult = null,
    err: ?anyerror = null,
};

fn executeReadyParallelWave(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, shape_path: []const u8, settings: *const config.ConfigSettings, values: *std.StringHashMap(TypedValue), uses: []const PlanPart, required: []const bool, done: []bool, done_count: *usize, trace_prefix: ?[]const u8) !bool {
    const max_parallel = try maxParallel(settings);
    if (max_parallel < 2) return false;

    var selected: std.ArrayList(usize) = .empty;
    defer selected.deinit(allocator);
    for (uses, 0..) |entry, index| {
        if (selected.items.len >= max_parallel) break;
        if (!required[index] or done[index] or !ready(values, entry.takes) or !parallelSafe(entry)) continue;
        try selected.append(allocator, index);
    }
    if (selected.items.len < 2) return false;

    var contexts = try allocator.alloc(WorkerContext, selected.items.len);
    defer allocator.free(contexts);
    var initialized_count: usize = 0;
    defer {
        for (contexts[0..initialized_count]) |ctx| if (ctx.adapter_path) |path| allocator.free(path);
    }

    var threads = try allocator.alloc(std.Thread, selected.items.len);
    defer allocator.free(threads);
    var spawned_count: usize = 0;
    errdefer {
        for (threads[0..spawned_count]) |thread| thread.join();
    }

    for (selected.items, 0..) |index, worker_index| {
        const entry = uses[index];
        try markPart(allocator, store, run_id, entry.id, entry.name, "running");
        contexts[worker_index] = .{ .io = io, .run_id = run_id, .entry = entry, .values = values, .store = store, .settings = settings, .shape_path = shape_path, .trace_prefix = trace_prefix };
        if (isModelPart(entry)) {
            const model_name = entry.model orelse settings.defaultModel();
            const preset = settings.modelPreset(model_name) orelse return error.ModelPresetNotFound;
            const adapter_ref = preset.adapter orelse return error.ModelAdapterMissing;
            contexts[worker_index].model_name = model_name;
            contexts[worker_index].model_preset = preset;
            contexts[worker_index].adapter_path = try resolveAdapterPath(allocator, store, settings, adapter_ref);
        }
        initialized_count += 1;
        threads[worker_index] = try std.Thread.spawn(.{}, partWorker, .{&contexts[worker_index]});
        spawned_count += 1;
    }

    for (threads[0..spawned_count]) |thread| thread.join();

    for (contexts, 0..) |*ctx, worker_index| {
        if (ctx.err) |err| return err;
        var result = ctx.result orelse return error.PartWorkerMissingResult;
        defer result.deinit();
        try commitPartResult(allocator, store, run_id, values, &result);
        done[selected.items[worker_index]] = true;
        done_count.* += 1;
    }
    return true;
}

fn partWorker(ctx: *WorkerContext) void {
    if (ctx.adapter_path) |adapter_path| {
        const result_name = scopedPath(std.heap.page_allocator, ctx.trace_prefix, ctx.entry.name) catch |err| {
            ctx.err = err;
            return;
        };
        defer std.heap.page_allocator.free(result_name);
        ctx.result = runModelPartResolved(std.heap.page_allocator, ctx.io, ctx.store, ctx.run_id, ctx.model_name.?, ctx.model_preset.?, adapter_path, ctx.values, ctx.entry, result_name) catch |err| {
            ctx.err = err;
            return;
        };
    } else {
        const result_name = scopedPath(std.heap.page_allocator, ctx.trace_prefix, ctx.entry.name) catch |err| {
            ctx.err = err;
            return;
        };
        defer std.heap.page_allocator.free(result_name);
        if (ctx.entry.shape) |shape_ref| {
            ctx.result = runShapeReferenceThread(std.heap.page_allocator, ctx.io, ctx.run_id, ctx.shape_path, ctx.settings, ctx.values, ctx.entry, shape_ref, result_name) catch |err| {
                ctx.err = err;
                return;
            };
        } else {
            ctx.result = runAssignmentPart(std.heap.page_allocator, ctx.values, ctx.entry, result_name) catch |err| {
                ctx.err = err;
                return;
            };
        }
    }
}

fn maxParallel(settings: *const config.ConfigSettings) !usize {
    if (settings.runtime_max_parallel > 0) return settings.runtime_max_parallel;
    return std.Thread.getCpuCount() catch 1;
}

fn parallelSafe(entry: PlanPart) bool {
    if (entry.shape != null or isModelPart(entry)) return true;
    const instructions = entry.instructions orelse return false;
    return hasAssignments(instructions);
}

fn isModelPart(entry: PlanPart) bool {
    return entry.model != null or entry.instructions != null and !hasAssignments(entry.instructions.?);
}

fn ready(values: *std.StringHashMap(TypedValue), takes: []const PlanBinding) bool {
    for (takes) |take| if (!values.contains(take.value)) return false;
    return true;
}

fn runPart(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, shape_path: []const u8, settings: *const config.ConfigSettings, values: *std.StringHashMap(TypedValue), entry: PlanPart, trace_prefix: ?[]const u8) anyerror!void {
    const trace_name = try scopedPath(allocator, trace_prefix, entry.name);
    defer allocator.free(trace_name);
    try markPart(allocator, store, run_id, entry.id, trace_name, "running");

    var result = try executePart(allocator, io, store, run_id, shape_path, settings, values, entry, trace_name);
    defer result.deinit();
    try commitPartResult(allocator, store, run_id, values, &result);
}

fn markPart(allocator: Allocator, store: *Store, run_id: []const u8, doc_part_id: []const u8, name: []const u8, status: []const u8) !void {
    const part_path = try std.fmt.allocPrint(allocator, "parts/{s}", .{name});
    defer allocator.free(part_path);
    const part_id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ run_id, part_path });
    defer allocator.free(part_id);
    lockRuntimeStore();
    defer unlockRuntimeStore();
    try store.insertRunPart(.{ .id = part_id, .run_id = run_id, .path = part_path, .doc_part_id = doc_part_id, .name = path_mod.basename(name), .status = status });
}

fn commitPartResult(allocator: Allocator, store: *Store, run_id: []const u8, values: *std.StringHashMap(TypedValue), result: *const PartResult) !void {
    for (result.texts.items) |text| {
        const id = try textId(allocator, run_id, text.path);
        defer allocator.free(id);
        lockRuntimeStore();
        errdefer unlockRuntimeStore();
        try store.insertRunText(.{ .id = id, .run_id = run_id, .path = text.path, .role = text.role, .payload = text.payload });
        unlockRuntimeStore();
    }
    const producer_part_path = try std.fmt.allocPrint(allocator, "parts/{s}", .{result.name});
    defer allocator.free(producer_part_path);
    for (result.outputs.items) |output| {
        try putText(allocator, values, output.name, output.type_label, output.value);
        try storeRunValue(allocator, store, run_id, output.name, output.type_label, "intermediate", producer_part_path, output.value);
    }
    try markPart(allocator, store, run_id, result.doc_part_id, result.name, "finished");
}

fn executePart(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, shape_path: []const u8, settings: *const config.ConfigSettings, values: *std.StringHashMap(TypedValue), entry: PlanPart, result_name: []const u8) !PartResult {
    if (entry.shape) |shape_ref| return try runShapeReference(allocator, io, store, run_id, shape_path, settings, values, entry, shape_ref, result_name);
    if (isModelPart(entry)) return try runModelPart(allocator, io, store, run_id, settings, values, entry, result_name);
    return try runAssignmentPart(allocator, values, entry, result_name);
}

fn runAssignmentPart(allocator: Allocator, values: *std.StringHashMap(TypedValue), entry: PlanPart, result_name: []const u8) !PartResult {
    var result = try PartResult.init(allocator, result_name, entry.id);
    errdefer result.deinit();
    var locals = std.StringHashMap(f64).init(allocator);
    defer locals.deinit();
    for (entry.takes) |take| {
        const local = take.local orelse continue;
        const value = values.get(take.value) orelse return error.MissingInputValue;
        const number = std.fmt.parseFloat(f64, value.value) catch {
            try files.writeAllErr("error: invalid numeric input for part \"");
            try files.writeAllErr(entry.name);
            try files.writeAllErr("\"\n\ninput: ");
            try files.writeAllErr(trimDollar(take.value));
            try files.writeAllErr("\nexpected: number\nreceived: ");
            try files.writeAllErr(value.value);
            try files.writeAllErr("\n");
            return error.InvalidInputValue;
        };
        try locals.put(local, number);
    }
    try executeAssignments(allocator, &result, &locals, entry);
    return result;
}

fn hasAssignments(instructions: []const u8) bool {
    var lines = std.mem.splitScalar(u8, instructions, '\n');
    while (lines.next()) |line| if (std.mem.indexOfScalar(u8, line, '=') != null) return true;
    return false;
}

fn runShapeReferenceThread(allocator: Allocator, io: std.Io, run_id: []const u8, shape_path: []const u8, settings: *const config.ConfigSettings, parent_values: *std.StringHashMap(TypedValue), entry: PlanPart, shape_ref: []const u8, result_name: []const u8) anyerror!PartResult {
    lockRuntimeStore();
    var store = Store.open(allocator) catch |err| {
        unlockRuntimeStore();
        return err;
    };
    unlockRuntimeStore();
    defer store.close();
    return try runShapeReference(allocator, io, &store, run_id, shape_path, settings, parent_values, entry, shape_ref, result_name);
}

fn runShapeReference(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, shape_path: []const u8, settings: *const config.ConfigSettings, parent_values: *std.StringHashMap(TypedValue), entry: PlanPart, shape_ref: []const u8, result_name: []const u8) anyerror!PartResult {
    const resolved = if (pkg_index.parsePackageRef(shape_ref)) |parsed_ref|
        try pkg_index.resolveRef(allocator, store, shape_ref, settings.packageAlias(parsed_ref.alias))
    else |_|
        try resolveRelative(allocator, shape_path, shape_ref);
    defer allocator.free(resolved);

    const child_doc_id = try materializeShapeFile(allocator, io, store, resolved);
    defer allocator.free(child_doc_id);
    var child_plan = try loadPlanDoc(allocator, store, child_doc_id);
    defer child_plan.deinit();

    var child_values = std.StringHashMap(TypedValue).init(allocator);
    defer freeValues(&child_values);

    for (child_plan.takes) |child_take| {
        const parent_take = parentBindingForLocal(entry.takes, child_take.name) orelse parentBindingForLocal(entry.takes, trimDollar(child_take.name)) orelse return error.MissingInputValue;
        const found = parent_values.get(parent_take.value) orelse return error.MissingInputValue;
        try child_values.put(try allocator.dupe(u8, child_take.name), .{ .allocator = allocator, .type_label = if (found.type_label) |t| try allocator.dupe(u8, t) else if (child_take.type_label) |t| try allocator.dupe(u8, t) else null, .value = try allocator.dupe(u8, found.value) });
    }

    const required = try requiredFrontier(allocator, child_plan.parts, child_plan.gives);
    defer allocator.free(required);
    try executePlan(allocator, io, store, run_id, resolved, settings, &child_values, child_plan.parts, required, result_name);

    var result = try PartResult.init(allocator, result_name, entry.id);
    errdefer result.deinit();
    for (entry.gives) |parent_give| {
        const child_give = childValueForLocal(child_plan.gives, parent_give.local orelse trimDollar(parent_give.value)) orelse return error.MissingOutputValue;
        const found = child_values.get(child_give.name) orelse return error.MissingOutputValue;
        try result.addOutput(parent_give.value, found.type_label orelse child_give.type_label, found.value);
    }
    return result;
}

fn runModelPart(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, settings: *const config.ConfigSettings, values: *std.StringHashMap(TypedValue), entry: PlanPart, result_name: []const u8) !PartResult {
    const model_name = entry.model orelse settings.defaultModel();
    const preset = settings.modelPreset(model_name) orelse return error.ModelPresetNotFound;
    const adapter_ref = preset.adapter orelse return error.ModelAdapterMissing;
    const adapter_path = try resolveAdapterPath(allocator, store, settings, adapter_ref);
    defer allocator.free(adapter_path);
    return try runModelPartResolved(allocator, io, store, run_id, model_name, preset, adapter_path, values, entry, result_name);
}

fn resolveAdapterPath(allocator: Allocator, store: *Store, settings: *const config.ConfigSettings, adapter_ref: []const u8) ![]u8 {
    if (pkg_index.parsePackageRef(adapter_ref)) |parsed_ref|
        return try pkg_index.resolveRef(allocator, store, adapter_ref, settings.packageAlias(parsed_ref.alias))
    else |_|
        return try allocator.dupe(u8, adapter_ref);
}

fn runModelPartResolved(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, model_name: []const u8, preset: config.ModelPreset, adapter_path: []const u8, values: *std.StringHashMap(TypedValue), entry: PlanPart, result_name: []const u8) !PartResult {
    const request = try adapterRequestYaml(allocator, model_name, preset, values, entry);
    defer allocator.free(request);

    const request_sub = try std.fmt.allocPrint(allocator, "runs/{s}/artifacts/{s}-request.yaml", .{ run_id, result_name });
    defer allocator.free(request_sub);
    const request_path = try layout.tempRunPath(allocator, request_sub);
    defer allocator.free(request_path);
    try files.write(request_path, request);
    const request_artifact_path = try std.fmt.allocPrint(allocator, "artifacts/{s}/request", .{result_name});
    defer allocator.free(request_artifact_path);
    try insertRunTextDirect(allocator, store, run_id, request_artifact_path, "artifact", request);

    const argv = [_][]const u8{ adapter_path, request_path };
    const result = try std.process.run(allocator, io, .{ .argv = &argv, .stdout_limit = .limited(10 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const raw_path = try std.fmt.allocPrint(allocator, "artifacts/{s}/response/raw", .{result_name});
    defer allocator.free(raw_path);
    try insertRunTextDirect(allocator, store, run_id, raw_path, "artifact", result.stdout);
    if (result.stderr.len > 0) {
        const stderr_path = try std.fmt.allocPrint(allocator, "artifacts/{s}/response/stderr", .{result_name});
        defer allocator.free(stderr_path);
        try insertRunTextDirect(allocator, store, run_id, stderr_path, "artifact", result.stderr);
    }
    if (result.term != .exited or result.term.exited != 0) return error.AdapterFailed;

    var part_result = try PartResult.init(allocator, result_name, entry.id);
    errdefer part_result.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = try serde.yaml.parse(arena.allocator(), result.stdout);
    try applyAdapterResponse(allocator, &part_result, entry, &root);
    return part_result;
}

fn executeAssignments(allocator: Allocator, result: *PartResult, locals: *std.StringHashMap(f64), entry: PlanPart) !void {
    const instructions = entry.instructions orelse return error.NoExecutableInstructions;
    var completed: usize = 0;
    var lines = std.mem.splitScalar(u8, instructions, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const target = std.mem.trim(u8, line[0..eq], " \t");
        const expression = std.mem.trim(u8, line[eq + 1 ..], " \t");
        var parser = ExpressionParser{ .text = expression, .locals = locals };
        const number = parser.parse() catch |err| {
            try files.writeAllErr("error: invalid assignment expression in part \"");
            try files.writeAllErr(entry.name);
            try files.writeAllErr("\"\n\nline: ");
            try files.writeAllErr(line);
            try files.writeAllErr("\nexpression: ");
            try files.writeAllErr(expression);
            try files.writeAllErr("\nreason: ");
            if (err == error.UnknownVariable) {
                try files.writeAllErr("unknown variable");
                if (parser.unknown_variable) |name| {
                    try files.writeAllErr(" \"");
                    try files.writeAllErr(name);
                    try files.writeAllErr("\"");
                }
            } else {
                try files.writeAllErr(@errorName(err));
            }
            try files.writeAllErr("\n");
            return error.InvalidAssignmentExpression;
        };
        try locals.put(target, number);
        if (systemValueForLocal(entry.gives, target)) |value_name| {
            const rendered = try std.fmt.allocPrint(allocator, "{d:.2}", .{number});
            defer allocator.free(rendered);
            try result.addOutput(value_name, "number", rendered);
        }
        completed += 1;
    }
    if (completed == 0) return error.NoExecutableInstructions;
}

fn systemValueForLocal(gives: []const PlanBinding, local_name: []const u8) ?[]const u8 {
    for (gives) |give| if (give.local) |local| {
        if (std.mem.eql(u8, local, local_name)) return give.value;
    };
    return null;
}

const ExpressionParser = struct {
    text: []const u8,
    index: usize = 0,
    locals: *std.StringHashMap(f64),
    unknown_variable: ?[]const u8 = null,

    fn parse(self: *ExpressionParser) anyerror!f64 {
        const result = try self.expression();
        self.skipSpace();
        if (self.index != self.text.len) return error.InvalidExpression;
        return result;
    }

    fn expression(self: *ExpressionParser) anyerror!f64 {
        var left = try self.term();
        while (true) {
            self.skipSpace();
            if (self.consume('+')) left += try self.term() else if (self.consume('-')) left -= try self.term() else return left;
        }
    }

    fn term(self: *ExpressionParser) anyerror!f64 {
        var left = try self.power();
        while (true) {
            self.skipSpace();
            if (self.consume('*')) left *= try self.power() else if (self.consume('/')) left /= try self.power() else return left;
        }
    }

    fn power(self: *ExpressionParser) anyerror!f64 {
        var left = try self.factor();
        self.skipSpace();
        if (self.consume('^')) left = std.math.pow(f64, left, try self.power());
        return left;
    }

    fn factor(self: *ExpressionParser) anyerror!f64 {
        self.skipSpace();
        if (self.consume('(')) {
            const inner = try self.expression();
            self.skipSpace();
            if (!self.consume(')')) return error.InvalidExpression;
            return inner;
        }
        if (self.consume('-')) return -(try self.factor());
        if (self.peekDigit()) return self.number();
        return self.variable();
    }

    fn number(self: *ExpressionParser) anyerror!f64 {
        const start = self.index;
        while (self.index < self.text.len and (std.ascii.isDigit(self.text[self.index]) or self.text[self.index] == '.')) self.index += 1;
        return try std.fmt.parseFloat(f64, self.text[start..self.index]);
    }

    fn variable(self: *ExpressionParser) anyerror!f64 {
        const start = self.index;
        while (self.index < self.text.len and (std.ascii.isAlphanumeric(self.text[self.index]) or self.text[self.index] == '_' or self.text[self.index] == '$')) self.index += 1;
        if (start == self.index) return error.InvalidExpression;
        const name = self.text[start..self.index];
        return self.locals.get(name) orelse {
            self.unknown_variable = name;
            return error.UnknownVariable;
        };
    }

    fn skipSpace(self: *ExpressionParser) void {
        while (self.index < self.text.len and std.ascii.isWhitespace(self.text[self.index])) self.index += 1;
    }

    fn consume(self: *ExpressionParser, char: u8) bool {
        if (self.index >= self.text.len or self.text[self.index] != char) return false;
        self.index += 1;
        return true;
    }

    fn peekDigit(self: *ExpressionParser) bool {
        return self.index < self.text.len and (std.ascii.isDigit(self.text[self.index]) or self.text[self.index] == '.');
    }
};

fn adapterRequestYaml(allocator: Allocator, model_name: []const u8, preset: config.ModelPreset, values: *std.StringHashMap(TypedValue), entry: PlanPart) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "part: {s}\nmodel: {s}\nparams:\n", .{ entry.name, model_name });
    if (preset.params) |params| try appendYamlMapping(allocator, &out, params, 2);
    try out.appendSlice(allocator, "instructions: |\n");
    var instruction_lines = std.mem.splitScalar(u8, entry.instructions orelse "", '\n');
    while (instruction_lines.next()) |line| try out.print(allocator, "  {s}\n", .{line});
    try out.appendSlice(allocator, "takes:\n");
    for (entry.takes) |take| {
        const local = take.local orelse trimDollar(take.value);
        const found = values.get(take.value) orelse return error.MissingInputValue;
        try out.print(allocator, "  {s}:\n    {s}: |\n", .{ local, found.type_label orelse "value" });
        var value_lines = std.mem.splitScalar(u8, found.value, '\n');
        while (value_lines.next()) |line| try out.print(allocator, "      {s}\n", .{line});
    }
    try out.appendSlice(allocator, "gives:\n");
    for (entry.gives) |give| {
        try out.print(allocator, "  {s}: {s}\n", .{ give.local orelse trimDollar(give.value), give.type_label orelse "text" });
    }
    return out.toOwnedSlice(allocator);
}

fn appendYamlMapping(allocator: Allocator, out: *std.ArrayList(u8), node: *const serde.yaml.Value, indent: usize) !void {
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
                try appendYamlMapping(allocator, out, entry.value_ptr, indent + 2);
            },
            else => try out.print(allocator, "{s}:\n", .{entry.key_ptr.*}),
        }
    }
}

fn applyAdapterResponse(allocator: Allocator, result: *PartResult, entry: PlanPart, root: *const serde.yaml.Value) !void {
    if (root.* != .mapping) return error.InvalidAdapterResponse;
    if (yamlGet(root, "reasoning")) |reasoning| if (reasoning.* == .string and reasoning.string.len > 0) {
        const reasoning_path = try std.fmt.allocPrint(allocator, "reasoning/{s}", .{result.name});
        defer allocator.free(reasoning_path);
        try result.addText(reasoning_path, "reasoning", reasoning.string);
    };
    if (yamlGet(root, "text")) |text| if (text.* == .string and text.string.len > 0) {
        const text_path = try std.fmt.allocPrint(allocator, "artifacts/{s}/text", .{result.name});
        defer allocator.free(text_path);
        try result.addText(text_path, "artifact", text.string);
    };
    const gives = yamlGet(root, "gives") orelse return error.AdapterResponseMissingGives;
    if (gives.* != .mapping) return error.AdapterResponseMissingGives;
    var it = gives.mapping.iterator();
    while (it.next()) |item| {
        const parent = systemValueForLocal(entry.gives, item.key_ptr.*) orelse continue;
        if (item.value_ptr.* == .mapping) {
            const type_node = yamlGet(item.value_ptr, "type");
            const value_node = yamlGet(item.value_ptr, "value") orelse continue;
            if (value_node.* != .string) continue;
            try result.addOutput(parent, if (type_node) |t| if (t.* == .string) t.string else null else null, value_node.string);
        } else if (item.value_ptr.* == .string) {
            const expected = bindingForLocal(entry.gives, item.key_ptr.*).?.type_label;
            try result.addOutput(parent, expected, item.value_ptr.string);
        }
    }
}

fn putText(allocator: Allocator, values: *std.StringHashMap(TypedValue), name: []const u8, type_label: ?[]const u8, text: []const u8) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    if (values.fetchRemove(name)) |old| {
        allocator.free(old.key);
        var old_value = old.value;
        old_value.deinit();
    }
    try values.put(owned_name, .{ .allocator = allocator, .type_label = if (type_label) |t| try allocator.dupe(u8, t) else null, .value = try allocator.dupe(u8, text) });
}

fn putNumber(allocator: Allocator, values: *std.StringHashMap(TypedValue), name: []const u8, number: f64) !void {
    const rendered = try std.fmt.allocPrint(allocator, "{d:.2}", .{number});
    errdefer allocator.free(rendered);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    if (values.fetchRemove(name)) |old| {
        allocator.free(old.key);
        var old_value = old.value;
        old_value.deinit();
    }
    try values.put(owned_name, .{ .allocator = allocator, .type_label = try allocator.dupe(u8, "number"), .value = rendered });
}

fn insertRunTextDirect(allocator: Allocator, store: *Store, run_id: []const u8, path: []const u8, role: []const u8, payload: []const u8) !void {
    const id = try textId(allocator, run_id, path);
    defer allocator.free(id);
    lockRuntimeStore();
    defer unlockRuntimeStore();
    try store.insertRunText(.{ .id = id, .run_id = run_id, .path = path, .role = role, .payload = payload });
}

fn storeInputValues(allocator: Allocator, store: *Store, run_id: []const u8, values: *std.StringHashMap(TypedValue), takes: []const PlanValue) !void {
    for (takes) |take| {
        const found = values.get(take.name) orelse return error.MissingInputValue;
        try storeRunValue(allocator, store, run_id, take.name, found.type_label, "input", null, found.value);
    }
}

fn storeOutputs(allocator: Allocator, store: *Store, run_id: []const u8, values: *std.StringHashMap(TypedValue), gives: []const PlanValue) !void {
    for (gives) |give| {
        const found = values.get(give.name) orelse return error.MissingOutputValue;
        try storeRunValue(allocator, store, run_id, give.name, found.type_label, "output", null, found.value);
    }
}

fn storeRunValue(allocator: Allocator, store: *Store, run_id: []const u8, name: []const u8, type_label: ?[]const u8, origin: []const u8, producer_part_path: ?[]const u8, payload: []const u8) !void {
    const value_path = try path_mod.valuePath(allocator, "values", name);
    defer allocator.free(value_path);
    const id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ run_id, value_path });
    defer allocator.free(id);
    lockRuntimeStore();
    defer unlockRuntimeStore();
    try store.insertRunValue(.{ .id = id, .run_id = run_id, .path = value_path, .name = name, .type_label = type_label, .origin = origin, .producer_part_path = producer_part_path, .payload = payload });
}

fn storePlanSteps(allocator: Allocator, store: *Store, run_id: []const u8, parts: []const PlanPart, required: []const bool) !void {
    for (parts, 0..) |part, index| {
        const step_path = try std.fmt.allocPrint(allocator, "plan/{d}", .{index});
        defer allocator.free(step_path);
        const part_path = try std.fmt.allocPrint(allocator, "parts/{s}", .{part.path["uses/".len..]});
        defer allocator.free(part_path);
        const id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ run_id, step_path });
        defer allocator.free(id);
        try store.insertRunPlanStep(.{ .id = id, .run_id = run_id, .path = step_path, .part_path = part_path, .order_index = @intCast(index), .required = if (required[index]) 1 else 0, .status = if (required[index]) "pending" else "skipped", .reason = null });
    }
}

fn yamlGet(node: *const serde.yaml.Value, key: []const u8) ?*const serde.yaml.Value {
    if (node.* != .mapping) return null;
    var it = node.mapping.iterator();
    while (it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, key)) return entry.value_ptr;
    return null;
}

fn parentBindingForLocal(bindings: []const PlanBinding, local_name: []const u8) ?PlanBinding {
    for (bindings) |binding| {
        if (binding.local) |local| if (std.mem.eql(u8, local, local_name)) return binding;
    }
    return null;
}

fn childValueForLocal(values: []const PlanValue, local_name: []const u8) ?PlanValue {
    for (values) |value| if (std.mem.eql(u8, trimDollar(value.name), local_name)) return value;
    return null;
}

fn bindingForLocal(bindings: []const PlanBinding, local_name: []const u8) ?PlanBinding {
    for (bindings) |binding| {
        if (binding.local) |local| if (std.mem.eql(u8, local, local_name)) return binding;
        if (std.mem.eql(u8, trimDollar(binding.value), local_name)) return binding;
    }
    return null;
}

fn trimDollar(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "$")) name[1..] else name;
}

fn resolveRelative(allocator: Allocator, base_file: []const u8, rel: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(rel)) return try allocator.dupe(u8, rel);
    const dir = std.fs.path.dirname(base_file) orelse ".";
    return try std.fs.path.resolve(allocator, &.{ dir, rel });
}

fn textId(allocator: Allocator, run_id: []const u8, path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ run_id, path });
}

fn scopedPath(allocator: Allocator, prefix: ?[]const u8, name: []const u8) ![]u8 {
    const segment = path_mod.valueSegment(name);
    try path_mod.validateSegment(segment);
    if (prefix) |p| return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ p, segment });
    return try allocator.dupe(u8, segment);
}

fn freeValues(values: *std.StringHashMap(TypedValue)) void {
    var it = values.iterator();
    while (it.next()) |entry| {
        values.allocator.free(entry.key_ptr.*);
        var v = entry.value_ptr.*;
        v.deinit();
    }
    values.deinit();
}

fn randomHex(io: std.Io, buf: []u8) ![]const u8 {
    const ts = std.Io.Clock.now(.real, io).toNanoseconds();
    var prng = std.Random.DefaultPrng.init(@intCast(@as(u96, @bitCast(ts)) & 0xFFFFFFFFFFFFFFFF));
    const alphabet = "0123456789abcdef";
    for (buf) |*c| c.* = alphabet[prng.random().uintLessThan(usize, 16)];
    return buf;
}
