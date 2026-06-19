const std = @import("std");
const serde = @import("serde");
const circuitry = @import("circuitry");
const files = @import("io/fs.zig");
const package = @import("package.zig");
const proc = @import("io/process.zig");
const exec_io = @import("execute/io.zig");
const config = @import("cmd/config.zig");
const substrate = @import("substrate.zig");
const Substrate = substrate.Store;

const Allocator = std.mem.Allocator;

pub const RunTarget = union(enum) {
    fresh,
    in_run: []const u8,
    from_step: []const u8,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    output: []const u8,
    report: []const u8,

    pub fn deinit(self: *const Result) void { self.arena.deinit(); }
};

const EntryJob = struct {
    index: usize,
    entry: circuitry.Entry,
    surface: []const u8,
    request: []const u8,
    resolved: package.ResolvedInvocation,
    result: ?proc.Result = null,
    err: ?anyerror = null,

    fn deinit(self: *EntryJob) void {
        self.resolved.deinit();
        if (self.result) |result| result.deinit(std.heap.page_allocator);
    }
};

pub fn runShape(allocator: Allocator, io: std.Io, store: *Substrate, settings: *const config.ConfigSettings, shape: circuitry.Shape, args: []const []const u8, target: RunTarget) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var state = State.init(aa);
    for (shape.inputs) |take| if (findArg(args, take.name)) |arg_value| try state.set(bare(take.name), arg_value);

    var steps = std.ArrayList([]const u8).empty;
    errdefer steps.deinit(aa);
    const run_id = switch (target) {
        .fresh => blk: {
            const run_meta = try runMeta(aa, shape.name);
            break :blk try store.createRun(run_meta);
        },
        .in_run => |id| try allocator.dupe(u8, id),
        .from_step => |step| try store.stepRun(step),
    };
    defer allocator.free(run_id);
    const parent_step = switch (target) {
        .from_step => |step| step,
        else => null,
    };
    const parallel = @max(settings.runtimeParallel(), 1);
    const completed = try aa.alloc(bool, shape.entries.len);
    for (completed) |*done| done.* = false;

    var finished: usize = 0;
    var advance: usize = 0;
    while (finished < shape.entries.len) {
        var selected = std.ArrayList(usize).empty;
        defer selected.deinit(aa);
        for (shape.entries, 0..) |entry, index| {
            if (completed[index] or !entryReady(&state, entry)) continue;
            try selected.append(aa, index);
            if (selected.items.len == parallel) break;
        }
        if (selected.items.len == 0) return error.MissingStepInput;

        const jobs = try aa.alloc(EntryJob, selected.items.len);
        var prepared: usize = 0;
        var jobs_deferred = false;
        errdefer if (!jobs_deferred) for (jobs[0..prepared]) |*job| job.deinit();
        for (selected.items, 0..) |entry_index, job_index| {
            jobs[job_index] = try prepareEntry(aa, store, &state, entry_index, shape.entries[entry_index]);
            prepared += 1;
        }
        jobs_deferred = true;
        defer for (jobs) |*job| job.deinit();

        if (jobs.len == 1) {
            runJob(&jobs[0], io);
        } else {
            const threads = try aa.alloc(std.Thread, jobs.len);
            for (jobs, 0..) |*job, index| threads[index] = try std.Thread.spawn(.{}, runJob, .{ job, io });
            for (threads) |thread| thread.join();
        }

        advance += 1;
        var packets = std.ArrayList(substrate.StepPacket).empty;
        defer packets.deinit(aa);
        var calls = std.ArrayList(u8).empty;
        defer calls.deinit(aa);
        if (parent_step) |parent| {
            try calls.print(aa, "parent: zinc://steps/{s}\nadvance: {d}\ncalls:\n", .{ parent, advance });
        } else {
            try calls.print(aa, "parent: null\nadvance: {d}\ncalls:\n", .{advance});
        }
        for (jobs) |*job| {
            if (job.err) |err| return err;
            const result = job.result orelse return error.PackageRunMissing;
            if (result.stderr.len > 0) try files.writeAllErr(result.stderr);

            const local = try exec_io.selectFields(aa, job.entry.outputs, result.stdout);
            defer exec_io.freeLocal(local, aa);
            try applyLocal(&state, job.entry.outputs, local);
            const outputs_yaml = try exec_io.outputsYaml(aa, job.entry.outputs, local);
            const request_packet = try store.packetId(job.request);
            defer allocator.free(request_packet);
            const response_packet = try store.packetId(result.stdout);
            defer allocator.free(response_packet);
            try packets.append(aa, .{ .id = try aa.dupe(u8, request_packet), .bytes = job.request });
            try packets.append(aa, .{ .id = try aa.dupe(u8, response_packet), .bytes = result.stdout });
            try calls.print(aa,
                "  - path: {s}\n    surface: {s}\n    request: zinc://packets/{s}\n    response: zinc://packets/{s}\n    out: |\n",
                .{ job.entry.path, job.surface, request_packet, response_packet },
            );
            try exec_io.appendIndentedBy(aa, &calls, outputs_yaml, 6);
            completed[job.index] = true;
            finished += 1;
        }
        const step_id = try store.recordStep(run_id, parent_step, calls.items, packets.items);
        defer allocator.free(step_id);
        try steps.append(aa, try aa.dupe(u8, step_id));
    }

    const output = try exec_io.shapeTextResult(aa, &state, shape.outputs);
    const report = try exec_io.stepsYaml(aa, run_id, steps.items);
    return .{ .arena = arena, .output = output, .report = report };
}

pub fn readShape(allocator: Allocator, path: []const u8) ![]const u8 {
    const bytes = try files.readLimited(allocator, path, 10 * 1024 * 1024);
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".markdown")) {
        defer allocator.free(bytes);
        return try markdownFrontMatter(allocator, bytes);
    }
    return bytes;
}

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

fn entryReady(state: *State, entry: circuitry.Entry) bool {
    for (entry.inputs) |take| {
        if (state.get(bare(take.visible orelse take.local)) == null) return false;
    }
    return true;
}

fn prepareEntry(allocator: Allocator, store: *Substrate, state: *State, index: usize, entry: circuitry.Entry) !EntryJob {
    const surface = hostField(entry.fields, "surface") orelse return error.SurfaceMissing;
    var manifest = try loadManifest(allocator, store, surface);
    defer manifest.deinit();
    const request = try surfaceRequest(allocator, surface, entry, state);
    const invocation = manifest.surfaceEntry(manifestName(surface)) orelse return error.SurfaceNotFound;
    const resolved = try invocation.resolve(manifest.root_path);
    return .{ .index = index, .entry = entry, .surface = surface, .request = request, .resolved = resolved };
}

fn runJob(job: *EntryJob, io: std.Io) void {
    job.result = proc.runWithInput(std.heap.page_allocator, io, job.resolved.argv, job.request, job.resolved.cwd, job.resolved.env, job.resolved.timeout, 64 * 1024 * 1024) catch |err| {
        job.err = err;
        return;
    };
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
fn surfacePackage(surface: []const u8) []const u8 { const dot = std.mem.indexOfScalar(u8, surface, '.') orelse return surface; return surface[0..dot]; }

fn hostField(fields: []const circuitry.HostField, key: []const u8) ?[]const u8 {
    for (fields) |field| if (std.mem.eql(u8, field.name, key)) return exec_io.scalarText(field.value);
    return null;
}

fn preserveField(fields: []const circuitry.HostField) ?bool {
    for (fields) |field| if (std.mem.eql(u8, field.name, "preserve")) return switch (field.value.*) { .boolean => |b| b, else => null };
    return null;
}

fn appendHostField(allocator: Allocator, out: *std.ArrayList(u8), state: *State, key: []const u8, value: *const serde.yaml.Value) !void {
    try out.print(allocator, "{s}: ", .{key});
    try appendResolvedYamlInline(allocator, out, state, value);
    try out.appendSlice(allocator, "\n");
}

fn appendResolvedYamlInline(allocator: Allocator, out: *std.ArrayList(u8), state: *State, value: *const serde.yaml.Value) !void {
    switch (value.*) {
        .string => |s| {
            if (isVariableRef(s)) if (state.get(s)) |resolved| {
                try exec_io.appendYamlInline(allocator, out, &.{ .string = resolved });
                return;
            };
            try exec_io.appendYamlInline(allocator, out, value);
        },
        .sequence => |items| {
            try out.appendSlice(allocator, "[");
            for (items, 0..) |item, i| {
                if (i != 0) try out.appendSlice(allocator, ", ");
                try appendResolvedYamlInline(allocator, out, state, &item);
            }
            try out.appendSlice(allocator, "]");
        },
        .mapping => |*entries| {
            try out.appendSlice(allocator, "{");
            var first = true;
            var it = entries.iterator();
            while (it.next()) |entry| {
                if (!first) try out.appendSlice(allocator, ", ");
                first = false;
                try out.print(allocator, "{s}: ", .{entry.key_ptr.*});
                try appendResolvedYamlInline(allocator, out, state, entry.value_ptr);
            }
            try out.appendSlice(allocator, "}");
        },
        else => try exec_io.appendYamlInline(allocator, out, value),
    }
}

fn isVariableRef(value: []const u8) bool { return value.len > 1 and value[0] == '$'; }

pub fn markdownFrontMatter(allocator: Allocator, bytes: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, bytes, "---\n") and !std.mem.startsWith(u8, bytes, "---\r\n")) return error.MarkdownFrontMatterMissing;
    const start: usize = if (std.mem.startsWith(u8, bytes, "---\r\n")) 5 else 4;
    var line_start = start;
    while (line_start <= bytes.len) {
        const line_end = std.mem.indexOfScalarPos(u8, bytes, line_start, '\n') orelse bytes.len;
        const line = std.mem.trim(u8, bytes[line_start..line_end], "\r");
        if (std.mem.eql(u8, line, "---")) return try allocator.dupe(u8, bytes[start..line_start]);
        if (line_end == bytes.len) break;
        line_start = line_end + 1;
    }
    return error.MarkdownFrontMatterMissing;
}

fn bare(name: []const u8) []const u8 { return if (name.len > 0 and name[0] == '$') name[1..] else name; }

fn findArg(args: []const []const u8, name: []const u8) ?[]const u8 {
    const bare_name = bare(name);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, bare_name)) return arg;
        if (std.mem.startsWith(u8, arg, bare_name) and arg.len > bare_name.len and arg[bare_name.len] == '=') return arg[bare_name.len + 1 ..];
    }
    return null;
}

fn runMeta(allocator: Allocator, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "name: {s}\n", .{name});
}
