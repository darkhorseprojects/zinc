const std = @import("std");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;

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
    args: []InputSpec,
    runtime_model: ?[]u8,
    agent_model: ?[]u8,

    pub fn deinit(self: Graph, allocator: Allocator) void {
        for (self.args) |arg| arg.deinit(allocator);
        allocator.free(self.args);
        if (self.runtime_model) |model| allocator.free(model);
        if (self.agent_model) |model| allocator.free(model);
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
    const graph_value = objectGet(root, "graph") orelse root;
    const resources_value = objectGet(graph_value, "resources") orelse return error.InvalidCircuitryGraph;
    if (resources_value != .object) return error.InvalidCircuitryGraph;
    const resources_obj = resources_value.object;

    var resources = try allocator.alloc(Resource, resources_obj.count());
    errdefer allocator.free(resources);
    var i: usize = 0;
    var iter = resources_obj.iterator();
    while (iter.next()) |entry| : (i += 1) {
        const origins = objectGet(root, "origins");
        const origin_value = if (origins) |value| if (value == .object) value.object.get(entry.key_ptr.*) else null else null;
        resources[i] = .{
            .id = entry.key_ptr.*,
            .source_file = if (origin_value) |value| scalarText(value) orelse graph_path else graph_path,
            .value = entry.value_ptr.*,
        };
    }

    const args = try readArgs(allocator, graph_value);
    errdefer freeInputSpecs(allocator, args);
    const runtime_model = if (scalarAt(graph_value, &.{ "runtime", "model" })) |model| try allocator.dupe(u8, model) else null;
    errdefer if (runtime_model) |model| allocator.free(model);
    const agent_model = try firstAgentModel(allocator, resources);
    errdefer if (agent_model) |model| allocator.free(model);

    return .{ .json_text = text, .parsed = parsed, .resources = resources, .args = args, .runtime_model = runtime_model, .agent_model = agent_model };
}

fn parseWithCircuitry(allocator: Allocator, io: std.Io, graph_path: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "circuitry", "parse", graph_path }, .stderr_limit = .limited(64 * 1024), .stdout_limit = .limited(16 * 1024 * 1024) });
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("circuitry parse failed:\n{s}\n", .{result.stderr});
        allocator.free(result.stdout);
        return error.CircuitryParseFailed;
    }
    return result.stdout;
}

fn readArgs(allocator: Allocator, graph_value: std.json.Value) ![]InputSpec {
    const args = objectGet(graph_value, "args") orelse return allocator.alloc(InputSpec, 0);
    if (args != .object) return error.InvalidCircuitryGraph;
    const args_obj = args.object;
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

fn firstAgentModel(allocator: Allocator, resources: []const Resource) !?[]u8 {
    for (resources) |res| {
        if (!std.mem.eql(u8, resourceType(res) orelse "", "agent")) continue;
        if (resourceField(res, "model")) |model| return try allocator.dupe(u8, model);
    }
    return null;
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
        const content = resourceTextValue(allocator, res) catch continue;
        errdefer allocator.free(content);
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
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
            .description = try allocator.dupe(u8, frontmatter(fm, "description") orelse ""),
            .content = content,
        });
    }
    return packs.toOwnedSlice(allocator);
}

pub fn freePromptPacks(allocator: Allocator, packs: []const PromptPack) void {
    for (packs) |pack| pack.deinit(allocator);
    allocator.free(packs);
}

pub fn findAgentWithTools(graph: Graph) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (graph.resources) |res| {
        if (std.mem.eql(u8, resourceType(res) orelse "", "agent") and resourceValue(res, "tools") != null) found = res.id;
    }
    return found;
}

pub fn findFirstAgentInput(allocator: Allocator, graph: Graph, id: []const u8) !?[]u8 {
    const res = resource(graph, id) orelse return error.InvalidCircuitryGraph;
    const inputs = try readList(allocator, res, "inputs");
    defer freeStringList(allocator, inputs);
    for (inputs) |input| if (resource(graph, input)) |candidate| if (std.mem.eql(u8, resourceType(candidate) orelse "", "agent")) return try allocator.dupe(u8, input);
    return null;
}

pub fn findSingleAgent(graph: Graph) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (graph.resources) |res| if (std.mem.eql(u8, resourceType(res) orelse "", "agent")) {
        if (found != null) return null;
        found = res.id;
    };
    return found;
}

pub fn resourceIdentity(allocator: Allocator, graph: Graph, id: []const u8) ![]u8 {
    const res = resource(graph, id) orelse return error.InvalidCircuitryGraph;
    return allocator.dupe(u8, resourceField(res, "identity") orelse resourceField(res, "label") orelse id);
}

pub fn readTools(allocator: Allocator, graph: Graph, id: []const u8) ![][]u8 {
    const res = resource(graph, id) orelse return error.InvalidCircuitryGraph;
    const items = try readList(allocator, res, "tools");
    if (items.len == 0) return error.InvalidCircuitryGraph;
    return items;
}

pub fn readInputSpecs(allocator: Allocator, graph: Graph) ![]InputSpec {
    var out = try allocator.alloc(InputSpec, graph.args.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |input| input.deinit(allocator);
        allocator.free(out);
    }
    for (graph.args, 0..) |input, i| {
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

pub fn wantsCircuitryPrompt(graph: Graph, _: []const []u8) bool {
    for (graph.resources) |res| if (std.mem.eql(u8, res.id, "prompt_circuitry_author")) return true;
    for (graph.resources) |res| if (resourceTextValueContains(res, "circuitry-author")) return true;
    return false;
}

pub fn graphModel(allocator: Allocator, graph: Graph) !?[]u8 {
    if (graph.agent_model) |model| if (!std.mem.eql(u8, model, "inherit")) return try allocator.dupe(u8, model);
    if (graph.runtime_model) |model| if (!std.mem.eql(u8, model, "inherit")) return try allocator.dupe(u8, model);
    return null;
}

pub fn extractResourceInstructions(allocator: Allocator, graph: Graph, id: []const u8) ![]u8 {
    const res = resource(graph, id) orelse return error.InvalidCircuitryGraph;
    return allocator.dupe(u8, resourceField(res, "instructions") orelse return error.InvalidCircuitryGraph);
}

fn resource(graph: Graph, id: []const u8) ?Resource {
    for (graph.resources) |res| if (std.mem.eql(u8, res.id, id)) return res;
    return null;
}

fn resourceType(res: Resource) ?[]const u8 {
    return resourceField(res, "type");
}

fn resourceField(res: Resource, field: []const u8) ?[]const u8 {
    return mapScalar(res.value, field);
}

fn resourceValue(res: Resource, field: []const u8) ?std.json.Value {
    return objectGet(res.value, field);
}

fn resourceTextValue(allocator: Allocator, res: Resource) ![]u8 {
    return allocator.dupe(u8, resourceField(res, "value") orelse return error.InvalidCircuitryGraph);
}

fn resourceTextValueContains(res: Resource, needle: []const u8) bool {
    const value = resourceField(res, "value") orelse return false;
    return std.mem.indexOf(u8, value, needle) != null;
}

fn readList(allocator: Allocator, res: Resource, field: []const u8) ![][]u8 {
    const found = resourceValue(res, field) orelse return allocator.alloc([]u8, 0);
    if (found != .array) return error.InvalidCircuitryGraph;
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
