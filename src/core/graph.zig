const std = @import("std");
const files = @import("../sys/fs.zig");

const Allocator = std.mem.Allocator;

pub const InputKind = enum { text, file, image };

pub const RuntimeInput = struct {
    id: []u8,
    kind: InputKind,
    value: []u8,
    mime: []u8,

    pub fn deinit(self: RuntimeInput, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.value);
        allocator.free(self.mime);
    }
};

pub const PromptPack = struct {
    id: []u8,
    title: []u8,
    description: []u8,
    content: []u8,
    pub fn deinit(self: PromptPack, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.content);
    }
};

pub const InputSpec = struct {
    id: []u8,
    kind: []u8,
    required: bool,
    pub fn deinit(self: InputSpec, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.kind);
    }
};

pub const EntryAlias = struct {
    name: []u8,
    resource_id: []u8,
    pub fn deinit(self: EntryAlias, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.resource_id);
    }
};

pub const ImageInput = struct {
    id: []u8,
    path: []u8,
    mime: []u8,
    pub fn deinit(self: ImageInput, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
        allocator.free(self.mime);
    }
};

pub const Resource = struct {
    id: []const u8,
    source_file: []const u8,
    value: std.json.Value,
};

pub const Graph = struct {
    json_text: []u8,
    parsed: std.json.Parsed(std.json.Value),
    resources: []Resource,
    inputs: []InputSpec,
    entries: []EntryAlias,
    entry: ?[]u8,

    pub fn deinit(self: Graph, allocator: Allocator) void {
        for (self.inputs) |input| input.deinit(allocator);
        allocator.free(self.inputs);
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
        if (self.entry) |entry| allocator.free(entry);
        allocator.free(self.resources);
        var parsed = self.parsed;
        parsed.deinit();
        allocator.free(self.json_text);
    }
};

pub fn load(allocator: Allocator, io: std.Io, graph_path: []const u8) !Graph {
    const text = try resolveWithCircuitry(allocator, io, graph_path);
    errdefer allocator.free(text);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    errdefer parsed.deinit();
    const root = parsed.value;

    if (root != .object) return error.InvalidCircuitryGraph;
    const graph_value = root;
    const resources_value = objectGet(graph_value, "resources") orelse return error.InvalidCircuitryGraph;
    if (resources_value != .object) return error.InvalidCircuitryGraph;
    const resources_obj = resources_value.object;

    var resources = try allocator.alloc(Resource, resources_obj.count());
    errdefer allocator.free(resources);
    var i: usize = 0;
    var iter = resources_obj.iterator();
    while (iter.next()) |entry| : (i += 1) {
        resources[i] = .{
            .id = entry.key_ptr.*,
            .source_file = graph_path,
            .value = entry.value_ptr.*,
        };
    }

    const inputs = try readInputs(allocator, graph_value);
    errdefer freeInputSpecs(allocator, inputs);
    const entries = try readEntries(allocator, graph_value);
    errdefer freeEntries(allocator, entries);
    const entry_id = if (scalarAt(graph_value, &.{"entry"})) |entry| try allocator.dupe(u8, entry) else null;
    errdefer if (entry_id) |entry| allocator.free(entry);
    return .{ .json_text = text, .parsed = parsed, .resources = resources, .inputs = inputs, .entries = entries, .entry = entry_id };
}

fn resolveWithCircuitry(allocator: Allocator, io: std.Io, graph_path: []const u8) ![]u8 {
    return runCircuitryCommand(allocator, io, &.{ "circuitry", "resolve", graph_path });
}

fn runCircuitryCommand(allocator: Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stderr_limit = .limited(64 * 1024),
        .stdout_limit = .limited(16 * 1024 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("error: circuitry command not found; install @darkhorseprojects/circuitry\n", .{});
            return error.UserError;
        },
        else => return err,
    };
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        std.debug.print("error: failed to resolve graph with circuitry: {s}\n", .{argv[argv.len - 1]});
        if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
        return error.UserError;
    }
    return result.stdout;
}

fn readInputs(allocator: Allocator, graph_value: std.json.Value) ![]InputSpec {
    const inputs = objectGet(graph_value, "inputs") orelse return allocator.alloc(InputSpec, 0);
    if (inputs != .object) return error.InvalidCircuitryGraph;
    const args_obj = inputs.object;
    var out = try allocator.alloc(InputSpec, args_obj.count());
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |arg| arg.deinit(allocator);
        allocator.free(out);
    }
    var iter = args_obj.iterator();
    while (iter.next()) |entry| : (initialized += 1) {
        const value = entry.value_ptr.*;
        out[initialized] = .{
            .id = try allocator.dupe(u8, entry.key_ptr.*),
            .kind = try allocator.dupe(u8, mapScalar(value, "type") orelse "text"),
            .required = mapBool(value, "required") orelse false,
        };
    }
    return out;
}

fn readEntries(allocator: Allocator, graph_value: std.json.Value) ![]EntryAlias {
    const entries = objectGet(graph_value, "entries") orelse return allocator.alloc(EntryAlias, 0);
    if (entries != .object) return error.InvalidCircuitryGraph;
    var out = try allocator.alloc(EntryAlias, entries.object.count());
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |entry| entry.deinit(allocator);
        allocator.free(out);
    }
    var iter = entries.object.iterator();
    while (iter.next()) |entry| : (initialized += 1) {
        out[initialized] = .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .resource_id = try allocator.dupe(u8, scalarText(entry.value_ptr.*) orelse return error.InvalidCircuitryGraph),
        };
    }
    return out;
}

fn freeEntries(allocator: Allocator, entries: []const EntryAlias) void {
    for (entries) |entry| entry.deinit(allocator);
    allocator.free(entries);
}

pub fn validate(graph: Graph) !void {
    if (graph.resources.len == 0) return error.InvalidCircuitryGraph;
}

pub fn readPromptPacks(allocator: Allocator, graph: Graph) ![]PromptPack {
    var packs: std.ArrayList(PromptPack) = .empty;
    errdefer {
        for (packs.items) |pack| pack.deinit(allocator);
        packs.deinit(allocator);
    }
    for (graph.resources) |res| {
        if (!std.mem.eql(u8, resourceType(res) orelse "", "text")) continue;

        if (resourceField(res, "uri")) |uri| {
            if (std.mem.startsWith(u8, uri, "prompt:")) {
                const id = std.mem.trim(u8, uri["prompt:".len..], " \t\r\n");
                if (id.len == 0) continue;
                try packs.append(allocator, .{
                    .id = try allocator.dupe(u8, id),
                    .title = try allocator.dupe(u8, resourceField(res, "label") orelse id),
                    .description = try allocator.dupe(u8, resourceField(res, "description") orelse ""),
                    .content = try std.fmt.allocPrint(allocator, "prompt:{s}", .{id}),
                });
                continue;
            }
        }

        const content = resourceTextValue(allocator, res) catch continue;
        errdefer allocator.free(content);
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "prompt:")) {
            const id = std.mem.trim(u8, trimmed["prompt:".len..], " \t\r\n");
            if (id.len == 0) {
                allocator.free(content);
                continue;
            }
            try packs.append(allocator, .{
                .id = try allocator.dupe(u8, id),
                .title = try allocator.dupe(u8, resourceField(res, "label") orelse id),
                .description = try allocator.dupe(u8, resourceField(res, "description") orelse ""),
                .content = content,
            });
            continue;
        }
        if (!std.mem.startsWith(u8, trimmed, "---\n")) {
            allocator.free(content);
            continue;
        }
        const fm_end = std.mem.indexOf(u8, trimmed[4..], "\n---") orelse {
            allocator.free(content);
            continue;
        };
        const fm = trimmed[4 .. 4 + fm_end];
        const id = frontmatter(fm, "id") orelse {
            allocator.free(content);
            continue;
        };
        try packs.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, frontmatter(fm, "title") orelse resourceField(res, "label") orelse id),
            .description = try allocator.dupe(u8, frontmatter(fm, "description") orelse resourceField(res, "description") orelse ""),
            .content = content,
        });
    }
    return packs.toOwnedSlice(allocator);
}

pub fn freePromptPacks(allocator: Allocator, packs: []const PromptPack) void {
    for (packs) |pack| pack.deinit(allocator);
    allocator.free(packs);
}

pub fn entryResourceId(graph: Graph, override: ?[]const u8) ?[]const u8 {
    if (override) |id| return entryAlias(graph, id) orelse id;
    if (graph.entry) |id| return entryAlias(graph, id) orelse id;
    return null;
}

fn entryAlias(graph: Graph, name: []const u8) ?[]const u8 {
    for (graph.entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.resource_id;
    return null;
}

pub fn resourceIdentity(allocator: Allocator, graph: Graph, id: []const u8) ![]u8 {
    const res = resource(graph, id) orelse return error.InvalidCircuitryGraph;
    return allocator.dupe(u8, resourceField(res, "identity") orelse resourceField(res, "label") orelse id);
}

pub fn readTools(allocator: Allocator, graph: Graph, id: []const u8) ![][]u8 {
    const res = resource(graph, id) orelse return error.InvalidCircuitryGraph;
    return readList(allocator, res, "tools");
}

pub fn readInputSpecs(allocator: Allocator, graph: Graph) ![]InputSpec {
    var out = try allocator.alloc(InputSpec, graph.inputs.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |input| input.deinit(allocator);
        allocator.free(out);
    }
    for (graph.inputs, 0..) |input, i| {
        out[i] = .{ .id = try allocator.dupe(u8, input.id), .kind = try allocator.dupe(u8, input.kind), .required = input.required };
        initialized += 1;
    }
    return out;
}

pub fn freeInputSpecs(allocator: Allocator, inputs: []const InputSpec) void {
    for (inputs) |input| input.deinit(allocator);
    allocator.free(inputs);
}

pub fn readImageInputs(allocator: Allocator, graph: Graph, id: []const u8) ![]ImageInput {
    const res = resource(graph, id) orelse return error.InvalidCircuitryGraph;
    const inputs = try readList(allocator, res, "inputs");
    defer freeStringList(allocator, inputs);
    var out: std.ArrayList(ImageInput) = .empty;
    errdefer {
        for (out.items) |item| item.deinit(allocator);
        out.deinit(allocator);
    }
    for (inputs) |input| {
        const input_res = resource(graph, input) orelse continue;
        if (!std.mem.eql(u8, resourceType(input_res) orelse "", "image")) continue;
        const raw_path = resourceField(input_res, "path") orelse resourceField(input_res, "uri") orelse resourceField(input_res, "value") orelse return error.InvalidCircuitryGraph;
        const resolved = try resolveResourceRef(allocator, std.fs.path.dirname(input_res.source_file) orelse ".", raw_path);
        errdefer allocator.free(resolved);
        try out.append(allocator, .{ .id = try allocator.dupe(u8, input), .path = resolved, .mime = try allocator.dupe(u8, resourceField(input_res, "mimeType") orelse mimeFromPath(raw_path)) });
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeImageInputs(allocator: Allocator, inputs: []const ImageInput) void {
    for (inputs) |input| input.deinit(allocator);
    allocator.free(inputs);
}

pub fn freeStringList(allocator: Allocator, list: []const []u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

pub fn graphModel(allocator: Allocator, graph: Graph) !?[]u8 {
    if (graph.entry) |entry_id| {
        if (resource(graph, entry_id)) |entry_res| {
            if (resourceField(entry_res, "model")) |model| {
                if (!std.mem.eql(u8, model, "inherit")) return try allocator.dupe(u8, model);
            }
        }
    }
    return null;
}

pub fn extractResourceInstructions(allocator: Allocator, graph: Graph, id: []const u8) ![]u8 {
    const res = resource(graph, id) orelse return error.InvalidCircuitryGraph;
    return allocator.dupe(u8, resourceField(res, "instructions") orelse return error.InvalidCircuitryGraph);
}

pub fn resource(graph: Graph, id: []const u8) ?Resource {
    for (graph.resources) |res| if (std.mem.eql(u8, res.id, id)) return res;
    return null;
}

pub fn resourceType(res: Resource) ?[]const u8 {
    return resourceField(res, "type");
}

pub fn resourceField(res: Resource, field: []const u8) ?[]const u8 {
    return mapScalar(res.value, field);
}

pub fn resourceValue(res: Resource, field: []const u8) ?std.json.Value {
    return objectGet(res.value, field);
}

pub fn resolveGraphRef(allocator: Allocator, res: Resource) ![]u8 {
    const raw = resourceField(res, "graph") orelse return error.InvalidCircuitryGraph;
    return resolveResourceRef(allocator, std.fs.path.dirname(res.source_file) orelse ".", raw);
}

pub fn resourceInputMapValue(res: Resource) ?std.json.Value {
    const value = resourceValue(res, "inputs") orelse return null;
    if (value != .object) return null;
    return value;
}

pub fn resourceInputsList(allocator: Allocator, res: Resource) ![][]u8 {
    return readList(allocator, res, "inputs");
}

pub fn resourceTextLiteral(allocator: Allocator, res: Resource) ![]u8 {
    return resourceTextValue(allocator, res);
}

pub fn resourcePath(allocator: Allocator, res: Resource) !?[]u8 {
    const raw = resourceField(res, "path") orelse return null;
    const path = try resolveResourceRef(allocator, std.fs.path.dirname(res.source_file) orelse ".", raw);
    return path;
}

fn resourceTextValue(allocator: Allocator, res: Resource) ![]u8 {
    const value = resourceValue(res, "value") orelse return error.InvalidCircuitryGraph;
    if (value == .string) return allocator.dupe(u8, value.string);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    defer out = aw.toArrayList();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    return out.toOwnedSlice(allocator);
}

fn resourceTextValueContains(res: Resource, needle: []const u8) bool {
    const value = resourceField(res, "value") orelse return false;
    return std.mem.indexOf(u8, value, needle) != null;
}

pub fn readList(allocator: Allocator, res: Resource, field: []const u8) ![][]u8 {
    const found = resourceValue(res, field) orelse return allocator.alloc([]u8, 0);
    if (found == .array) {
        var out = try allocator.alloc([]u8, found.array.items.len);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |item| allocator.free(item);
            allocator.free(out);
        }
        for (found.array.items, 0..) |item, i| {
            out[i] = try allocator.dupe(u8, scalarText(item) orelse return error.InvalidCircuitryGraph);
            initialized += 1;
        }
        return out;
    }
    if (found == .object) {
        var out = try allocator.alloc([]u8, found.object.count());
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |item| allocator.free(item);
            allocator.free(out);
        }
        var iter = found.object.iterator();
        while (iter.next()) |entry| : (initialized += 1) {
            out[initialized] = try allocator.dupe(u8, scalarText(entry.value_ptr.*) orelse return error.InvalidCircuitryGraph);
        }
        return out;
    }
    return error.InvalidCircuitryGraph;
}

pub fn resourceExpectValue(res: Resource) ?std.json.Value {
    return resourceValue(res, "expect");
}

pub fn mimeFromPathPublic(path: []const u8) []const u8 {
    return mimeFromPath(path);
}

fn objectGet(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn scalarAt(value: std.json.Value, path: []const []const u8) ?[]const u8 {
    return scalarText(valueAt(value, path) orelse return null);
}

fn valueAt(value: std.json.Value, path: []const []const u8) ?std.json.Value {
    var v = value;
    for (path) |part| v = objectGet(v, part) orelse return null;
    return v;
}

fn mapScalar(value: std.json.Value, field: []const u8) ?[]const u8 {
    return scalarText(objectGet(value, field) orelse return null);
}

fn scalarText(value: std.json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

fn mapBool(value: std.json.Value, field: []const u8) ?bool {
    const found = objectGet(value, field) orelse return null;
    return if (found == .bool) found.bool else null;
}

fn frontmatter(fm: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t\r"), key)) return unquote(std.mem.trim(u8, line[colon + 1 ..], " \t\r"));
    }
    return null;
}

fn unquote(raw: []const u8) []const u8 {
    if (raw.len >= 2 and ((raw[0] == '"' and raw[raw.len - 1] == '"') or (raw[0] == '\'' and raw[raw.len - 1] == '\''))) return raw[1 .. raw.len - 1];
    return raw;
}

fn mimeFromPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    return "application/octet-stream";
}

fn resolveResourceRef(allocator: Allocator, source_dir: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ source_dir, path });
}
