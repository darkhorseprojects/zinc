const std = @import("std");
const serde = @import("serde");
const circuitry = @import("circuitry");
const files = @import("io/fs.zig");
const package = @import("package.zig");
const proc = @import("io/process.zig");
const exec_io = @import("execute/io.zig");
const config = @import("cmd/config.zig");
const Substrate = @import("substrate.zig").Store;

const Allocator = std.mem.Allocator;

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    output: []const u8,
    events: []const u8,

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

pub fn runShape(allocator: Allocator, io: std.Io, store: *Substrate, settings: *const config.ConfigSettings, shape: circuitry.Shape, args: []const []const u8) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var state = State.init(aa);
    for (shape.inputs) |take| if (findArg(args, take.name)) |arg_value| try state.set(bare(take.name), arg_value);

    var events = std.ArrayList([]const u8).empty;
    errdefer events.deinit(aa);
    const root_preserve = preserveField(shape.fields);
    const run_id = try runId(aa, shape.name);
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
        for (jobs) |*job| {
            if (job.err) |err| return err;
            const result = job.result orelse return error.PackageRunMissing;
            if (result.stderr.len > 0) try files.writeAllErr(result.stderr);

            const local = try exec_io.selectFields(aa, job.entry.outputs, result.stdout);
            defer exec_io.freeLocal(local, aa);
            try applyLocal(&state, job.entry.outputs, local);
            const outputs_yaml = try exec_io.outputsYaml(aa, job.entry.outputs, local);
            const preserve = preserveField(job.entry.fields) orelse root_preserve orelse false;
            try store.recordEvent(run_id, advance, job.entry.path, job.surface, job.request, result.stdout, outputs_yaml, preserve, settings.packetLimit(surfacePackage(job.surface)));
            try events.append(aa, try aa.dupe(u8, job.entry.path));
            completed[job.index] = true;
            finished += 1;
        }
    }

    const output = try exec_io.shapeTextResult(aa, &state, shape.outputs);
    const event_bytes = try exec_io.eventsYaml(aa, events.items);
    return .{ .arena = arena, .output = output, .events = event_bytes };
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

fn markdownFrontMatter(allocator: Allocator, bytes: []const u8) ![]const u8 {
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

fn runId(allocator: Allocator, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}", .{name});
}
