const std = @import("std");
const Store = @import("store.zig").Store;
const store_mod = @import("store.zig");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const config = @import("../cmd/config.zig");
const pkg_index = @import("../pkg/index.zig");
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
    kind: []const u8,
    name: []const u8,
    text: []const u8,
};

const PartResult = struct {
    allocator: Allocator,
    name: []const u8,
    outputs: std.ArrayList(ValueDraft) = .empty,
    texts: std.ArrayList(TextDraft) = .empty,

    fn init(allocator: Allocator, name: []const u8) !PartResult {
        return .{ .allocator = allocator, .name = try allocator.dupe(u8, name) };
    }

    fn deinit(self: *PartResult) void {
        self.allocator.free(self.name);
        for (self.outputs.items) |item| {
            self.allocator.free(item.name);
            if (item.type_label) |label| self.allocator.free(label);
            self.allocator.free(item.value);
        }
        self.outputs.deinit(self.allocator);
        for (self.texts.items) |item| {
            self.allocator.free(item.kind);
            self.allocator.free(item.name);
            self.allocator.free(item.text);
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

    fn addText(self: *PartResult, kind: []const u8, name: []const u8, text: []const u8) !void {
        try self.texts.append(self.allocator, .{
            .kind = try self.allocator.dupe(u8, kind),
            .name = try self.allocator.dupe(u8, name),
            .text = try self.allocator.dupe(u8, text),
        });
    }
};

pub fn runShape(allocator: Allocator, io: std.Io, store: *Store, shape_path: []const u8, args: []const []const u8, settings: *const config.ConfigSettings) !void {
    const abs_path = try std.fs.path.resolve(allocator, &.{shape_path});
    defer allocator.free(abs_path);

    var shape = try circuitry.loadFile(io, allocator, abs_path);
    defer shape.deinit();

    var confirmation = try circuitry.confirm(allocator, &shape);
    defer confirmation.deinit();

    if (!confirmation.ready) {
        try files.writeAllErr("Error: Circuitry system is not ready to run.\n");
        for (confirmation.problems) |prob| {
            try files.writeAllErr("- ");
            try files.writeAllErr(prob);
            try files.writeAllErr("\n");
        }
        return error.CircuitryShapeNotReady;
    }

    const source_bytes = try files.readLimited(allocator, abs_path, 16 * 1024 * 1024);
    defer allocator.free(source_bytes);

    var id_buf: [16]u8 = undefined;
    const doc_id = try std.fmt.allocPrint(allocator, "doc_{s}", .{try randomHex(io, &id_buf)});
    defer allocator.free(doc_id);
    const run_id = try std.fmt.allocPrint(allocator, "run_{s}", .{try randomHex(io, &id_buf)});
    defer allocator.free(run_id);

    try store.insertDoc(.{
        .id = doc_id,
        .path = abs_path,
        .name = confirmation.card.name,
        .source = source_bytes,
        .updated_at = std.Io.Clock.now(.real, io).toSeconds(),
    });
    try store.insertRun(.{
        .id = run_id,
        .doc_id = doc_id,
        .status = "running",
        .started_at = std.Io.Clock.now(.real, io).toSeconds(),
        .finished_at = null,
    });
    try files.writeAllOut("Run URI: zinc://run/");
    try files.writeAllOut(run_id);
    try files.writeAllOut("\n");

    var values = std.StringHashMap(TypedValue).init(allocator);
    defer freeValues(&values);

    var run_settings = settings.*;
    applyShapeRuntime(&run_settings, &shape.root);

    try collectInputs(allocator, &values, confirmation.system.takes, args);
    const required = try requiredFrontier(allocator, confirmation.system.uses, confirmation.system.gives);
    defer allocator.free(required);
    const plan_text = try planText(allocator, confirmation.system.uses, required);
    defer allocator.free(plan_text);
    try files.writeAllOut(plan_text);
    const plan_id = try textId(allocator, run_id, "plan", "plan");
    defer allocator.free(plan_id);
    try store.insertRunText(.{ .id = plan_id, .run_id = run_id, .kind = "plan", .name = "plan", .text = plan_text });
    try executePlan(allocator, io, store, run_id, abs_path, &run_settings, &values, confirmation.system.uses, required, null);
    try storeOutputs(allocator, store, run_id, &values, confirmation.system.gives);

    try store.insertRun(.{
        .id = run_id,
        .doc_id = doc_id,
        .status = "finished",
        .started_at = null,
        .finished_at = std.Io.Clock.now(.real, io).toSeconds(),
    });

    try files.writeAllOut("\nOutputs:\n");
    for (confirmation.system.gives) |give| {
        const found = values.get(give.value) orelse return error.MissingOutputValue;
        try files.writeAllOut(give.value);
        try files.writeAllOut(": ");
        try files.writeAllOut(found.value);
        try files.writeAllOut("\n");
    }
    try files.writeAllOut("Run URI: zinc://run/");
    try files.writeAllOut(run_id);
    try files.writeAllOut("\n");
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

fn collectInputs(allocator: Allocator, values: *std.StringHashMap(TypedValue), takes: []const circuitry.ValueBinding, args: []const []const u8) !void {
    for (takes) |take| {
        const raw_name = if (std.mem.startsWith(u8, take.value, "$")) take.value[1..] else take.value;
        const provided = findArg(args, take.value) orelse findArg(args, raw_name) orelse return error.MissingInput;
        try values.put(try allocator.dupe(u8, take.value), .{
            .allocator = allocator,
            .type_label = if (take.type_label) |label| try allocator.dupe(u8, label) else null,
            .value = try allocator.dupe(u8, provided),
        });
    }
}

fn findArg(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args) |arg| {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            if (std.mem.eql(u8, arg[0..eq], name)) return arg[eq + 1 ..];
        }
    }
    return null;
}

fn planText(allocator: Allocator, uses: []const circuitry.UseEntry, required: []const bool) ![]u8 {
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

fn requiredFrontier(allocator: Allocator, uses: []const circuitry.UseEntry, gives: []const circuitry.ValueBinding) ![]bool {
    const required = try allocator.alloc(bool, uses.len);
    @memset(required, false);
    for (gives) |give| try requireValue(uses, required, give.value);
    return required;
}

fn requireValue(uses: []const circuitry.UseEntry, required: []bool, value_name: []const u8) !void {
    const producer = producerIndex(uses, value_name) orelse return;
    if (required[producer]) return;
    required[producer] = true;
    for (uses[producer].takes) |take| try requireValue(uses, required, take.value);
}

fn producerIndex(uses: []const circuitry.UseEntry, value_name: []const u8) ?usize {
    for (uses, 0..) |entry, index| {
        for (entry.gives) |give| if (std.mem.eql(u8, give.value, value_name)) return index;
    }
    return null;
}

fn executePlan(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, shape_path: []const u8, settings: *const config.ConfigSettings, values: *std.StringHashMap(TypedValue), uses: []const circuitry.UseEntry, required: []const bool, trace_prefix: ?[]const u8) anyerror!void {
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
    entry: circuitry.UseEntry,
    values: *std.StringHashMap(TypedValue),
    settings: *const config.ConfigSettings,
    shape_path: []const u8,
    trace_prefix: ?[]const u8 = null,
    model_name: ?[]const u8 = null,
    model_preset: ?config.ModelPreset = null,
    adapter_path: ?[]const u8 = null,
    result: ?PartResult = null,
    err: ?anyerror = null,
};

fn executeReadyParallelWave(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, shape_path: []const u8, settings: *const config.ConfigSettings, values: *std.StringHashMap(TypedValue), uses: []const circuitry.UseEntry, required: []const bool, done: []bool, done_count: *usize, trace_prefix: ?[]const u8) !bool {
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
        try markPart(allocator, store, run_id, entry.name, "running");
        contexts[worker_index] = .{ .io = io, .run_id = run_id, .entry = entry, .values = values, .settings = settings, .shape_path = shape_path, .trace_prefix = trace_prefix };
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
        const result_name = scopedName(std.heap.page_allocator, ctx.trace_prefix, ctx.entry.name) catch |err| {
            ctx.err = err;
            return;
        };
        defer std.heap.page_allocator.free(result_name);
        ctx.result = runModelPartResolved(std.heap.page_allocator, ctx.io, ctx.run_id, ctx.model_name.?, ctx.model_preset.?, adapter_path, ctx.values, ctx.entry, result_name) catch |err| {
            ctx.err = err;
            return;
        };
    } else {
        const result_name = scopedName(std.heap.page_allocator, ctx.trace_prefix, ctx.entry.name) catch |err| {
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

fn parallelSafe(entry: circuitry.UseEntry) bool {
    if (entry.shape != null or isModelPart(entry)) return true;
    const instructions = entry.instructions orelse return false;
    return hasAssignments(instructions);
}

fn isModelPart(entry: circuitry.UseEntry) bool {
    return entry.model != null or entry.instructions != null and !hasAssignments(entry.instructions.?);
}

fn ready(values: *std.StringHashMap(TypedValue), takes: []const circuitry.ValueBinding) bool {
    for (takes) |take| if (!values.contains(take.value)) return false;
    return true;
}

fn runPart(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, shape_path: []const u8, settings: *const config.ConfigSettings, values: *std.StringHashMap(TypedValue), entry: circuitry.UseEntry, trace_prefix: ?[]const u8) anyerror!void {
    const trace_name = try scopedName(allocator, trace_prefix, entry.name);
    defer allocator.free(trace_name);
    try markPart(allocator, store, run_id, trace_name, "running");

    var result = try executePart(allocator, io, store, run_id, shape_path, settings, values, entry, trace_name);
    defer result.deinit();
    try commitPartResult(allocator, store, run_id, values, &result);
}

fn markPart(allocator: Allocator, store: *Store, run_id: []const u8, name: []const u8, status: []const u8) !void {
    const part_id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ run_id, name });
    defer allocator.free(part_id);
    lockRuntimeStore();
    defer unlockRuntimeStore();
    try store.insertRunPart(.{ .id = part_id, .run_id = run_id, .name = name, .status = status });
}

fn commitPartResult(allocator: Allocator, store: *Store, run_id: []const u8, values: *std.StringHashMap(TypedValue), result: *const PartResult) !void {
    for (result.texts.items) |text| {
        const id = try textId(allocator, run_id, text.kind, text.name);
        defer allocator.free(id);
        lockRuntimeStore();
        errdefer unlockRuntimeStore();
        try store.insertRunText(.{ .id = id, .run_id = run_id, .kind = text.kind, .name = text.name, .text = text.text });
        unlockRuntimeStore();
    }
    for (result.outputs.items) |output| try putText(allocator, values, output.name, output.type_label, output.value);
    try markPart(allocator, store, run_id, result.name, "finished");
}

fn executePart(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, shape_path: []const u8, settings: *const config.ConfigSettings, values: *std.StringHashMap(TypedValue), entry: circuitry.UseEntry, result_name: []const u8) !PartResult {
    if (entry.shape) |shape_ref| return try runShapeReference(allocator, io, store, run_id, shape_path, settings, values, entry, shape_ref, result_name);
    if (isModelPart(entry)) return try runModelPart(allocator, io, store, run_id, settings, values, entry, result_name);
    return try runAssignmentPart(allocator, values, entry, result_name);
}

fn runAssignmentPart(allocator: Allocator, values: *std.StringHashMap(TypedValue), entry: circuitry.UseEntry, result_name: []const u8) !PartResult {
    var result = try PartResult.init(allocator, result_name);
    errdefer result.deinit();
    var locals = std.StringHashMap(f64).init(allocator);
    defer locals.deinit();
    for (entry.takes) |take| {
        const local = take.local orelse continue;
        const value = values.get(take.value) orelse return error.MissingInputValue;
        try locals.put(local, try std.fmt.parseFloat(f64, value.value));
    }
    try executeAssignments(allocator, &result, &locals, entry);
    return result;
}

fn hasAssignments(instructions: []const u8) bool {
    var lines = std.mem.splitScalar(u8, instructions, '\n');
    while (lines.next()) |line| if (std.mem.indexOfScalar(u8, line, '=') != null) return true;
    return false;
}

fn runShapeReferenceThread(allocator: Allocator, io: std.Io, run_id: []const u8, shape_path: []const u8, settings: *const config.ConfigSettings, parent_values: *std.StringHashMap(TypedValue), entry: circuitry.UseEntry, shape_ref: []const u8, result_name: []const u8) anyerror!PartResult {
    lockRuntimeStore();
    var store = Store.open(allocator) catch |err| {
        unlockRuntimeStore();
        return err;
    };
    unlockRuntimeStore();
    defer store.close();
    return try runShapeReference(allocator, io, &store, run_id, shape_path, settings, parent_values, entry, shape_ref, result_name);
}

fn runShapeReference(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, shape_path: []const u8, settings: *const config.ConfigSettings, parent_values: *std.StringHashMap(TypedValue), entry: circuitry.UseEntry, shape_ref: []const u8, result_name: []const u8) anyerror!PartResult {
    const resolved = if (std.mem.startsWith(u8, shape_ref, "@")) blk: {
        const parsed_ref = try pkg_index.parsePackageRef(shape_ref);
        break :blk try pkg_index.resolveRef(allocator, store, shape_ref, settings.packageAlias(parsed_ref.alias));
    } else try resolveRelative(allocator, shape_path, shape_ref);
    defer allocator.free(resolved);

    var child = try circuitry.loadFile(io, allocator, resolved);
    defer child.deinit();
    var confirmation = try circuitry.confirm(allocator, &child);
    defer confirmation.deinit();
    if (!confirmation.ready) return error.CircuitryShapeNotReady;

    var child_values = std.StringHashMap(TypedValue).init(allocator);
    defer freeValues(&child_values);

    for (confirmation.system.takes) |child_take| {
        const parent_take = parentBindingForLocal(entry.takes, child_take.value) orelse parentBindingForLocal(entry.takes, trimDollar(child_take.value)) orelse return error.MissingInputValue;
        const found = parent_values.get(parent_take.value) orelse return error.MissingInputValue;
        try child_values.put(try allocator.dupe(u8, child_take.value), .{ .allocator = allocator, .type_label = if (found.type_label) |t| try allocator.dupe(u8, t) else null, .value = try allocator.dupe(u8, found.value) });
    }

    const required = try requiredFrontier(allocator, confirmation.system.uses, confirmation.system.gives);
    defer allocator.free(required);
    try executePlan(allocator, io, store, run_id, resolved, settings, &child_values, confirmation.system.uses, required, result_name);

    var result = try PartResult.init(allocator, result_name);
    errdefer result.deinit();
    for (entry.gives) |parent_give| {
        const child_give = childBindingForLocal(confirmation.system.gives, parent_give.local orelse trimDollar(parent_give.value)) orelse return error.MissingOutputValue;
        const found = child_values.get(child_give.value) orelse return error.MissingOutputValue;
        try result.addOutput(parent_give.value, found.type_label orelse child_give.type_label, found.value);
    }
    return result;
}

fn runModelPart(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, settings: *const config.ConfigSettings, values: *std.StringHashMap(TypedValue), entry: circuitry.UseEntry, result_name: []const u8) !PartResult {
    const model_name = entry.model orelse settings.defaultModel();
    const preset = settings.modelPreset(model_name) orelse return error.ModelPresetNotFound;
    const adapter_ref = preset.adapter orelse return error.ModelAdapterMissing;
    const adapter_path = try resolveAdapterPath(allocator, store, settings, adapter_ref);
    defer allocator.free(adapter_path);
    return try runModelPartResolved(allocator, io, run_id, model_name, preset, adapter_path, values, entry, result_name);
}

fn resolveAdapterPath(allocator: Allocator, store: *Store, settings: *const config.ConfigSettings, adapter_ref: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, adapter_ref, "@")) {
        const parsed_ref = try pkg_index.parsePackageRef(adapter_ref);
        return try pkg_index.resolveRef(allocator, store, adapter_ref, settings.packageAlias(parsed_ref.alias));
    }
    return try allocator.dupe(u8, adapter_ref);
}

fn runModelPartResolved(allocator: Allocator, io: std.Io, run_id: []const u8, model_name: []const u8, preset: config.ModelPreset, adapter_path: []const u8, values: *std.StringHashMap(TypedValue), entry: circuitry.UseEntry, result_name: []const u8) !PartResult {
    const request = try adapterRequestYaml(allocator, model_name, preset, values, entry);
    defer allocator.free(request);

    const request_sub = try std.fmt.allocPrint(allocator, "runs/{s}/artifacts/{s}-request.yaml", .{ run_id, result_name });
    defer allocator.free(request_sub);
    const request_path = try layout.tempRunPath(allocator, request_sub);
    defer allocator.free(request_path);
    try files.write(request_path, request);
    const argv = [_][]const u8{ adapter_path, request_path };
    const result = try std.process.run(allocator, io, .{ .argv = &argv, .stdout_limit = .limited(10 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.AdapterFailed;

    var part_result = try PartResult.init(allocator, result_name);
    errdefer part_result.deinit();
    const raw_name = try std.fmt.allocPrint(allocator, "{s}-raw", .{result_name});
    defer allocator.free(raw_name);
    try part_result.addText("artifact", raw_name, result.stdout);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = try serde.yaml.parse(arena.allocator(), result.stdout);
    try applyAdapterResponse(allocator, &part_result, entry, &root);
    return part_result;
}

fn executeAssignments(allocator: Allocator, result: *PartResult, locals: *std.StringHashMap(f64), entry: circuitry.UseEntry) !void {
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
        const number = try parser.parse();
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

fn systemValueForLocal(gives: []const circuitry.ValueBinding, local_name: []const u8) ?[]const u8 {
    for (gives) |give| if (give.local) |local| {
        if (std.mem.eql(u8, local, local_name)) return give.value;
    };
    return null;
}

const ExpressionParser = struct {
    text: []const u8,
    index: usize = 0,
    locals: *std.StringHashMap(f64),

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
        return self.locals.get(name) orelse error.UnknownVariable;
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

fn adapterRequestYaml(allocator: Allocator, model_name: []const u8, preset: config.ModelPreset, values: *std.StringHashMap(TypedValue), entry: circuitry.UseEntry) ![]u8 {
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
        try out.print(allocator, "  {s}:\n    type: {s}\n    value: |\n", .{ local, found.type_label orelse "value" });
        var value_lines = std.mem.splitScalar(u8, found.value, '\n');
        while (value_lines.next()) |line| try out.print(allocator, "      {s}\n", .{line});
    }
    try out.appendSlice(allocator, "gives:\n");
    for (entry.gives) |give| {
        try out.print(allocator, "  {s}:\n    type: {s}\n", .{ give.local orelse trimDollar(give.value), give.type_label orelse "text" });
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

fn applyAdapterResponse(allocator: Allocator, result: *PartResult, entry: circuitry.UseEntry, root: *const serde.yaml.Value) !void {
    _ = allocator;
    if (root.* != .mapping) return error.InvalidAdapterResponse;
    if (yamlGet(root, "reasoning")) |reasoning| if (reasoning.* == .string and reasoning.string.len > 0) try result.addText("reasoning", result.name, reasoning.string);
    if (yamlGet(root, "text")) |text| if (text.* == .string and text.string.len > 0) try result.addText("artifact", result.name, text.string);
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
            try result.addOutput(parent, "text", item.value_ptr.string);
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

fn storeOutputs(allocator: Allocator, store: *Store, run_id: []const u8, values: *std.StringHashMap(TypedValue), gives: []const circuitry.ValueBinding) !void {
    for (gives) |give| {
        const found = values.get(give.value) orelse return error.MissingOutputValue;
        const id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ run_id, give.value });
        defer allocator.free(id);
        try store.insertRunValue(.{ .id = id, .run_id = run_id, .name = give.value, .type_label = found.type_label, .value = found.value });
    }
}

fn yamlGet(node: *const serde.yaml.Value, key: []const u8) ?*const serde.yaml.Value {
    if (node.* != .mapping) return null;
    var it = node.mapping.iterator();
    while (it.next()) |entry| if (std.mem.eql(u8, entry.key_ptr.*, key)) return entry.value_ptr;
    return null;
}

fn parentBindingForLocal(bindings: []const circuitry.ValueBinding, local_name: []const u8) ?circuitry.ValueBinding {
    for (bindings) |binding| {
        if (binding.local) |local| if (std.mem.eql(u8, local, local_name)) return binding;
    }
    return null;
}

fn childBindingForLocal(bindings: []const circuitry.ValueBinding, local_name: []const u8) ?circuitry.ValueBinding {
    for (bindings) |binding| {
        if (std.mem.eql(u8, trimDollar(binding.value), local_name)) return binding;
        if (binding.local) |local| if (std.mem.eql(u8, local, local_name)) return binding;
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

fn textId(allocator: Allocator, run_id: []const u8, kind: []const u8, name: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ run_id, kind, name });
}

fn scopedName(allocator: Allocator, prefix: ?[]const u8, name: []const u8) ![]u8 {
    if (prefix) |p| return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ p, name });
    return try allocator.dupe(u8, name);
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
