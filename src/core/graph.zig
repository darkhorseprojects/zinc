const std = @import("std");
const files = @import("../sys/fs.zig");

const Allocator = std.mem.Allocator;

pub const InputSpec = struct {
    id: []u8,
    kind: []u8,
    required: bool,
    pub fn deinit(self: InputSpec, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.kind);
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
    entry: ?[]u8,

    pub fn deinit(self: Graph, allocator: Allocator) void {
        for (self.inputs) |input| input.deinit(allocator);
        allocator.free(self.inputs);
        if (self.entry) |entry| allocator.free(entry);
        allocator.free(self.resources);
        var parsed = self.parsed;
        parsed.deinit();
        allocator.free(self.json_text);
    }
};

pub fn load(allocator: Allocator, io: std.Io, graph_path: []const u8) !Graph {
    const text = try parseWithCircuitry(allocator, io, graph_path);
    errdefer allocator.free(text);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    errdefer parsed.deinit();
    const root = parsed.value;

    if (root != .object) return error.InvalidCircuitryGraph;
    const resources_value = root.object.get("resources") orelse return error.InvalidCircuitryGraph;
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

    const inputs = try readInputs(allocator, root);
    errdefer freeInputSpecs(allocator, inputs);
    const entry_id_raw = scalarAt(root, &.{"entry"});
    var entry_id: ?[]u8 = null;
    if (entry_id_raw) |raw| {
        entry_id = try allocator.dupe(u8, raw);
    }
    return .{ .json_text = text, .parsed = parsed, .resources = resources, .inputs = inputs, .entry = entry_id };
}

fn parseWithCircuitry(allocator: Allocator, io: std.Io, graph_path: []const u8) ![]u8 {
    return runCircuitryCommand(allocator, io, &.{ "circuitry", "resolve", graph_path });
}

fn runCircuitryCommand(allocator: Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stderr_limit = .limited(64 * 1024),
        .stdout_limit = .limited(16 * 1024 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("error: 'circuitry' command not found. Install with: npm install -g @darkhorseprojects/circuitry\n", .{});
            return error.CircuitryNotFound;
        },
        else => return err,
    };
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.CircuitryCommandFailed;
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

pub fn validate(graph: Graph) !void {
    if (graph.resources.len == 0) return error.InvalidCircuitryGraph;
}

pub fn entryResourceId(graph: Graph, override: ?[]const u8) ?[]const u8 {
    if (override) |id| return id;
    return graph.entry;
}

pub fn resourceIdentity(allocator: Allocator, graph: Graph, id: []const u8) ![]u8 {
    const res = resource(graph, id) orelse return error.InvalidCircuitryGraph;
    return allocator.dupe(u8, resourceField(res, "identity") orelse resourceField(res, "label") orelse id);
}

pub fn readTools(allocator: Allocator, graph: Graph, id: []const u8) ![][]u8 {
    const res = resource(graph, id) orelse return error.InvalidCircuitryGraph;
    const items = try readList(allocator, res, "tools");
    // Empty tools list is valid - agents can run without tools
    return items;
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

pub fn resourceExpectValue(res: Resource) ?std.json.Value {
    return resourceValue(res, "expect");
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

// Load graph from already-resolved JSON (doesn't call circuitry)
pub fn loadFromSlice(allocator: Allocator, json_text: []const u8) !Graph {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    errdefer parsed.deinit();
    const root = parsed.value;

    if (root != .object) return error.InvalidCircuitryGraph;
    const resources_value = root.object.get("resources") orelse return error.InvalidCircuitryGraph;
    if (resources_value != .object) return error.InvalidCircuitryGraph;
    const resources_obj = resources_value.object;

    var resources = try allocator.alloc(Resource, resources_obj.count());
    errdefer allocator.free(resources);
    var i: usize = 0;
    var iter = resources_obj.iterator();
    while (iter.next()) |entry| : (i += 1) {
        resources[i] = .{
            .id = entry.key_ptr.*,
            .source_file = "",
            .value = entry.value_ptr.*,
        };
    }

    const inputs = try readInputs(allocator, root);
    errdefer freeInputSpecs(allocator, inputs);
    const entry_id = scalarAt(root, &.{"entry"}) orelse null;
    errdefer if (entry_id) |entry| allocator.free(entry);
    return .{ .json_text = try allocator.dupe(u8, json_text), .parsed = parsed, .resources = resources, .inputs = inputs, .entry = entry_id };
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
