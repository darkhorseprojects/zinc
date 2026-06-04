const std = @import("std");
const circuitry = @import("circuitry");

const Allocator = std.mem.Allocator;
const Value = circuitry.graph.Value;
const Module = circuitry.resolver.Module;

pub const InputKind = enum { text, file, image };

pub const RuntimeInput = struct {
    id: []u8,
    kind: InputKind,
    value: []u8,
    content_type: []u8,

    pub fn deinit(self: RuntimeInput, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.value);
        allocator.free(self.content_type);
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

pub const ExportTarget = struct {
    name: []u8,
    resource_id: []u8,

    pub fn deinit(self: ExportTarget, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.resource_id);
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

pub const Resource = struct {
    id: []u8,
    source_file: []const u8,
    scope_prefix: []u8,
    modules: []const Module,
    value: *const Value,

    pub fn deinit(self: Resource, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.scope_prefix);
    }
};

pub const Graph = struct {
    resolved: circuitry.ResolvedGraph,
    resources: []Resource,
    inputs: []InputSpec,
    exports: []ExportTarget,
    default_export_name: ?[]u8,
    default_export_target: ?[]u8,

    pub fn deinit(self: Graph, allocator: Allocator) void {
        for (self.inputs) |input| input.deinit(allocator);
        allocator.free(self.inputs);
        for (self.exports) |export_target| export_target.deinit(allocator);
        allocator.free(self.exports);
        if (self.default_export_name) |name| allocator.free(name);
        if (self.default_export_target) |target| allocator.free(target);
        for (self.resources) |res| res.deinit(allocator);
        allocator.free(self.resources);
        var resolved = self.resolved;
        resolved.deinit();
    }
};

pub fn load(allocator: Allocator, io: std.Io, graph_path: []const u8) !Graph {
    const loaded = try circuitry.loadFile(allocator, io, graph_path);
    var resolved = try circuitry.resolve(allocator, io, loaded, .{});
    errdefer resolved.deinit();

    var resource_list: std.ArrayList(Resource) = .empty;
    errdefer {
        for (resource_list.items) |res| res.deinit(allocator);
        resource_list.deinit(allocator);
    }
    try appendGraphResources(allocator, &resource_list, &resolved.graph, resolved.graph.path, "", resolved.modules);
    try appendModuleResources(allocator, &resource_list, "", resolved.modules);
    const resources = try resource_list.toOwnedSlice(allocator);
    errdefer {
        for (resources) |res| res.deinit(allocator);
        allocator.free(resources);
    }

    const exports = try readExports(allocator, &resolved.graph);
    errdefer freeExports(allocator, exports);
    const default_export_name = try defaultExportName(allocator, &resolved.graph);
    errdefer if (default_export_name) |name| allocator.free(name);
    const default_export_target = if (default_export_name) |name| try exportTargetByName(allocator, &resolved.graph, name) else null;
    errdefer if (default_export_target) |id| allocator.free(id);
    const inputs = if (default_export_name) |name| try readInputsForExportName(allocator, &resolved, name) else try allocator.alloc(InputSpec, 0);
    errdefer freeInputSpecs(allocator, inputs);

    return .{ .resolved = resolved, .resources = resources, .inputs = inputs, .exports = exports, .default_export_name = default_export_name, .default_export_target = default_export_target };
}

pub fn validate(graph: Graph) !void {
    if (graph.resources.len == 0) return error.InvalidCircuitryGraph;
}

pub fn inspectText(allocator: Allocator, graph: Graph) ![]u8 {
    return circuitry.inspect.render(allocator, &graph.resolved.graph);
}

pub fn exportTargetResourceId(graph: Graph, selected_export: ?[]const u8) ?[]const u8 {
    if (selected_export) |name| return exportTarget(graph, name) orelse name;
    return graph.default_export_target;
}

pub fn resource(graph: Graph, id: []const u8) ?Resource {
    for (graph.resources) |res| if (std.mem.eql(u8, res.id, id)) return res;
    return null;
}

pub fn resourceType(res: Resource) ?[]const u8 {
    return circuitry.resource.kindName(res.value);
}

pub fn resourceField(res: Resource, field: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, field, "label") or std.mem.eql(u8, field, "description")) return stringAt(res.value, field);
    return stringAt(body(res) orelse return null, field);
}

pub fn resourceValue(res: Resource, field: []const u8) ?*const Value {
    return valueAt(body(res) orelse return null, field);
}

pub fn resourceInputMapValue(res: Resource) ?*const Value {
    return resourceValue(res, "input");
}

pub fn resourceSchemaValue(res: Resource) ?*const Value {
    return resourceValue(res, "schema");
}

pub fn resourceInputsList(allocator: Allocator, res: Resource) ![][]u8 {
    return readList(allocator, res, "input");
}

pub fn readTools(allocator: Allocator, graph: Graph, id: []const u8) ![][]u8 {
    return readList(allocator, resource(graph, id) orelse return error.InvalidCircuitryGraph, "tools");
}

pub fn resourceIdentity(allocator: Allocator, graph: Graph, id: []const u8) ![]u8 {
    const res = resource(graph, id) orelse return error.InvalidCircuitryGraph;
    return allocator.dupe(u8, resourceField(res, "identity") orelse resourceField(res, "label") orelse id);
}

pub fn extractResourceInstructions(allocator: Allocator, graph: Graph, id: []const u8) ![]u8 {
    const res = resource(graph, id) orelse return error.InvalidCircuitryGraph;
    return allocator.dupe(u8, resourceField(res, "instructions") orelse "");
}

pub fn resolveGraphRef(allocator: Allocator, res: Resource) ![]u8 {
    const raw = resourceField(res, "graph") orelse return error.InvalidCircuitryGraph;
    return resolvePath(allocator, res.source_file, raw);
}

pub fn resourcePath(allocator: Allocator, res: Resource) !?[]u8 {
    const raw = sourceString(res, "path") orelse return null;
    return try resolvePath(allocator, res.source_file, raw);
}

pub fn resourceTextLiteral(allocator: Allocator, res: Resource) ![]u8 {
    const b = body(res) orelse return error.InvalidCircuitryGraph;
    if (b.* == .string) return allocator.dupe(u8, b.string);
    const value = valueAt(b, "value") orelse return error.InvalidCircuitryGraph;
    if (value.* == .string) return allocator.dupe(u8, value.string);
    return circuitry.value.writeJsonLike(allocator, value);
}

pub fn qualifyDependency(allocator: Allocator, res: Resource, raw: []const u8) ![]u8 {
    if (circuitry.resource.isRuntimeInputRef(raw)) return allocator.dupe(u8, raw);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ res.scope_prefix, raw });
}

pub fn readList(allocator: Allocator, res: Resource, field: []const u8) ![][]u8 {
    const value = resourceValue(res, field) orelse return allocator.alloc([]u8, 0);
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    try appendStringList(allocator, &out, value);
    return out.toOwnedSlice(allocator);
}

pub fn hasInput(graph: Graph, id: []const u8) bool {
    for (graph.inputs) |input| if (std.mem.eql(u8, input.id, id)) return true;
    return false;
}

pub fn hasInputForExport(allocator: Allocator, graph: Graph, selected_export: ?[]const u8, id: []const u8) !bool {
    const inputs = try readInputSpecsForExport(allocator, graph, selected_export);
    defer freeInputSpecs(allocator, inputs);
    for (inputs) |input| if (std.mem.eql(u8, input.id, id)) return true;
    return false;
}

pub fn readInputSpecs(allocator: Allocator, graph: Graph) ![]InputSpec {
    return cloneInputSpecs(allocator, graph.inputs);
}

pub fn readInputSpecsForExport(allocator: Allocator, graph: Graph, selected_export: ?[]const u8) ![]InputSpec {
    const name = exportName(graph, selected_export) orelse return allocator.alloc(InputSpec, 0);
    return readInputsForExportName(allocator, &graph.resolved, name);
}

pub fn readPromptPacks(allocator: Allocator, graph: Graph) ![]PromptPack {
    var packs: std.ArrayList(PromptPack) = .empty;
    errdefer {
        for (packs.items) |pack| pack.deinit(allocator);
        packs.deinit(allocator);
    }
    for (graph.resources) |res| {
        if (!std.mem.eql(u8, resourceType(res) orelse "", "text")) continue;
        const uri = sourceString(res, "uri") orelse continue;
        if (!std.mem.startsWith(u8, uri, "prompt:")) continue;
        const id = std.mem.trim(u8, uri["prompt:".len..], " \t\r\n");
        if (id.len == 0) continue;
        try packs.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .title = try allocator.dupe(u8, resourceField(res, "label") orelse id),
            .description = try allocator.dupe(u8, resourceField(res, "description") orelse ""),
            .content = try std.fmt.allocPrint(allocator, "prompt:{s}", .{id}),
        });
    }
    return packs.toOwnedSlice(allocator);
}

pub fn graphModel(allocator: Allocator, graph: Graph, selected_export: ?[]const u8) !?[]u8 {
    const id = exportTargetResourceId(graph, selected_export) orelse return null;
    const res = resource(graph, id) orelse return null;
    const model_id = resourceField(res, "using") orelse return null;
    if (std.mem.eql(u8, model_id, "inherit")) return null;
    return try allocator.dupe(u8, model_id);
}

pub fn freeInputSpecs(allocator: Allocator, inputs: []const InputSpec) void {
    for (inputs) |input| input.deinit(allocator);
    allocator.free(inputs);
}

pub fn freePromptPacks(allocator: Allocator, packs: []const PromptPack) void {
    for (packs) |pack| pack.deinit(allocator);
    allocator.free(packs);
}

pub fn freeStringList(allocator: Allocator, list: []const []u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn appendGraphResources(allocator: Allocator, out: *std.ArrayList(Resource), graph: *const circuitry.Graph, source_file: []const u8, scope_prefix: []const u8, modules: []const Module) !void {
    const resources = graph.resources() orelse return;
    if (resources.* != .mapping) return error.InvalidCircuitryGraph;
    var iter = resources.mapping.iterator();
    while (iter.next()) |entry| {
        try out.append(allocator, .{
            .id = try std.fmt.allocPrint(allocator, "{s}{s}", .{ scope_prefix, entry.key_ptr.* }),
            .source_file = source_file,
            .scope_prefix = try allocator.dupe(u8, scope_prefix),
            .modules = modules,
            .value = entry.value_ptr,
        });
    }
}

fn appendModuleResources(allocator: Allocator, out: *std.ArrayList(Resource), parent_prefix: []const u8, modules: []const Module) !void {
    for (modules) |*module| {
        const prefix = try std.fmt.allocPrint(allocator, "{s}{s}.", .{ parent_prefix, module.alias });
        defer allocator.free(prefix);
        try appendGraphResources(allocator, out, &module.graph, module.path, prefix, module.modules);
        try appendModuleResources(allocator, out, prefix, module.modules);
    }
}

fn readInputsForExportName(allocator: Allocator, resolved: *const circuitry.ResolvedGraph, export_name: []const u8) ![]InputSpec {
    const names = try circuitry.requiredInputs(allocator, resolved, export_name);
    defer circuitry.validation.freeStrings(allocator, names);
    var out = try allocator.alloc(InputSpec, names.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |input| input.deinit(allocator);
        allocator.free(out);
    }
    for (names, 0..) |name, i| {
        out[i] = .{ .id = try allocator.dupe(u8, name), .kind = try allocator.dupe(u8, exportInputKind(&resolved.graph, export_name, name) orelse return error.InvalidCircuitryGraph), .required = true };
        initialized += 1;
    }
    return out;
}

fn readExports(allocator: Allocator, graph: *const circuitry.Graph) ![]ExportTarget {
    const exports = graph.exports() orelse return allocator.alloc(ExportTarget, 0);
    if (exports.* != .mapping) return error.InvalidCircuitryGraph;
    var out = try allocator.alloc(ExportTarget, exports.mapping.count());
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |target| target.deinit(allocator);
        allocator.free(out);
    }
    var iter = exports.mapping.iterator();
    while (iter.next()) |item| : (initialized += 1) {
        const spec = circuitry.exports.get(exports, item.key_ptr.*) orelse return error.InvalidCircuitryGraph;
        out[initialized] = .{ .name = try allocator.dupe(u8, item.key_ptr.*), .resource_id = try allocator.dupe(u8, spec.run) };
    }
    return out;
}

fn defaultExportName(allocator: Allocator, graph: *const circuitry.Graph) !?[]u8 {
    const exports = graph.exports() orelse return null;
    if (exports.* != .mapping) return error.InvalidCircuitryGraph;
    if (circuitry.exports.get(exports, "main") != null) return try allocator.dupe(u8, "main");
    if (exports.mapping.count() != 1) return null;
    var iter = exports.mapping.iterator();
    const only = iter.next() orelse return null;
    return try allocator.dupe(u8, only.key_ptr.*);
}

fn exportTargetByName(allocator: Allocator, graph: *const circuitry.Graph, name: []const u8) !?[]u8 {
    const exports = graph.exports() orelse return null;
    if (exports.* != .mapping) return error.InvalidCircuitryGraph;
    const spec = circuitry.exports.get(exports, name) orelse return null;
    return try allocator.dupe(u8, spec.run);
}

fn exportTarget(graph: Graph, name: []const u8) ?[]const u8 {
    for (graph.exports) |target| if (std.mem.eql(u8, target.name, name)) return target.resource_id;
    return null;
}

fn exportName(graph: Graph, selected_export: ?[]const u8) ?[]const u8 {
    if (selected_export) |name| if (exportTarget(graph, name) != null) return name else return null;
    return graph.default_export_name;
}

fn exportInputKind(graph: *const circuitry.Graph, export_name: []const u8, input_name: []const u8) ?[]const u8 {
    const spec = circuitry.getExport(graph, export_name) orelse return null;
    const input = spec.input orelse return null;
    if (input.* != .mapping) return null;
    const value = input.mapping.getPtr(input_name) orelse return null;
    return if (value.* == .string) value.string else null;
}

fn cloneInputSpecs(allocator: Allocator, inputs: []const InputSpec) ![]InputSpec {
    var out = try allocator.alloc(InputSpec, inputs.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |input| input.deinit(allocator);
        allocator.free(out);
    }
    for (inputs, 0..) |input, i| {
        out[i] = .{ .id = try allocator.dupe(u8, input.id), .kind = try allocator.dupe(u8, input.kind), .required = input.required };
        initialized += 1;
    }
    return out;
}

fn body(res: Resource) ?*const Value {
    return circuitry.resource.body(res.value);
}

fn valueAt(value: *const Value, field: []const u8) ?*const Value {
    if (value.* != .mapping) return null;
    return value.mapping.getPtr(field);
}

fn stringAt(value: *const Value, field: []const u8) ?[]const u8 {
    const found = valueAt(value, field) orelse return null;
    return if (found.* == .string) found.string else null;
}

fn sourceString(res: Resource, field: []const u8) ?[]const u8 {
    const b = body(res) orelse return null;
    if (b.* == .string and std.mem.eql(u8, field, "path")) return b.string;
    return stringAt(b, field);
}

fn appendStringList(allocator: Allocator, out: *std.ArrayList([]u8), value: *const Value) !void {
    if (value.* != .sequence) return error.InvalidCircuitryGraph;
    for (value.sequence) |*item| {
        if (item.* == .sequence) try appendStringList(allocator, out, item) else if (item.* == .string) try out.append(allocator, try allocator.dupe(u8, item.string)) else return error.InvalidCircuitryGraph;
    }
}

fn resolvePath(allocator: Allocator, source_file: []const u8, raw: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(raw)) return allocator.dupe(u8, raw);
    return std.fs.path.join(allocator, &.{ std.fs.path.dirname(source_file) orelse ".", raw });
}

fn freeExports(allocator: Allocator, exports: []const ExportTarget) void {
    for (exports) |target| target.deinit(allocator);
    allocator.free(exports);
}
