const std = @import("std");
const circuitry = @import("circuitry");
const platform = @import("../platform.zig");

const Allocator = std.mem.Allocator;

pub const Param = struct {
    name: []u8,
    kind: []u8,
    description: []u8,
    required: bool,

    pub fn deinit(self: Param, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.kind);
        allocator.free(self.description);
    }
};

pub const HandlerKind = enum { process, http, mcp };

pub const Handler = union(HandlerKind) {
    process: struct { command: []u8 },
    http: struct { url: []u8, method: []u8 },
    mcp: struct { command: []u8, tool: []u8 },

    pub fn deinit(self: Handler, allocator: Allocator) void {
        switch (self) {
            .process => |h| allocator.free(h.command),
            .http => |h| {
                allocator.free(h.url);
                allocator.free(h.method);
            },
            .mcp => |h| {
                allocator.free(h.command);
                allocator.free(h.tool);
            },
        }
    }
};

pub const Tool = struct {
    name: []u8,
    label: []u8,
    description: []u8,
    prompt: []u8,
    params: []Param,
    handler: Handler,
    package_dir: []u8,

    pub fn deinit(self: Tool, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.label);
        allocator.free(self.description);
        allocator.free(self.prompt);
        for (self.params) |param| param.deinit(allocator);
        allocator.free(self.params);
        self.handler.deinit(allocator);
        allocator.free(self.package_dir);
    }
};

pub const Script = struct {
    name: []u8,
    command: []u8,

    pub fn deinit(self: Script, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
    }
};

pub const InstallSpec = struct {
    input: [][]u8,
    tools: [][]u8,

    pub fn deinit(self: InstallSpec, allocator: Allocator) void {
        freeStringList(allocator, self.input);
        freeStringList(allocator, self.tools);
    }
};

pub const Asset = struct {
    id: []u8,
    path: []u8,

    pub fn deinit(self: Asset, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
    }
};

pub const Manifest = struct {
    name: []u8,
    version: []u8,
    description: []u8,
    graphs: []Asset,
    prompts: []Asset,
    files: []Asset,
    tools: []Tool,
    scripts: []Script,
    install: ?InstallSpec,

    pub fn deinit(self: Manifest, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        freeAssets(allocator, self.graphs);
        freeAssets(allocator, self.prompts);
        freeAssets(allocator, self.files);
        freeTools(allocator, self.tools);
        freeScripts(allocator, self.scripts);
        if (self.install) |spec| spec.deinit(allocator);
    }
};

pub fn loadManifest(allocator: Allocator, io: std.Io, package_dir: []const u8) !Manifest {
    const path = try std.fs.path.join(allocator, &.{ package_dir, "zinc.pkg.yaml" });
    defer allocator.free(path);

    var document = try circuitry.loadYamlFile(allocator, io, path);
    defer document.deinit();
    const root = &document.root;
    if (root.* != .mapping) return error.InvalidPackageManifest;

    const name = scalarAt(root, &.{"name"}) orelse return error.InvalidPackageManifest;
    if (!portableAtom(name)) return error.InvalidPackageManifest;
    const manifest_name = try allocator.dupe(u8, name);
    errdefer allocator.free(manifest_name);
    const version = try allocator.dupe(u8, scalarAt(root, &.{"version"}) orelse "");
    errdefer allocator.free(version);
    const description = try allocator.dupe(u8, scalarAt(root, &.{"description"}) orelse "");
    errdefer allocator.free(description);
    const graphs = try readAssets(allocator, root, &.{ "assets", "graphs" });
    errdefer freeAssets(allocator, graphs);
    const prompts = try readAssets(allocator, root, &.{ "assets", "prompts" });
    errdefer freeAssets(allocator, prompts);
    const file_assets = try readAssets(allocator, root, &.{ "assets", "files" });
    errdefer freeAssets(allocator, file_assets);
    const tools = try readTools(allocator, root, package_dir);
    errdefer freeTools(allocator, tools);
    const scripts = try readScripts(allocator, root);
    errdefer freeScripts(allocator, scripts);
    const install_spec = try readInstall(allocator, root);
    errdefer if (install_spec) |spec| spec.deinit(allocator);
    return .{ .name = manifest_name, .version = version, .description = description, .graphs = graphs, .prompts = prompts, .files = file_assets, .tools = tools, .scripts = scripts, .install = install_spec };
}

fn readAssets(allocator: Allocator, root: *const circuitry.value.Value, path: []const []const u8) ![]Asset {
    const value = valueAt(root, path) orelse return allocator.alloc(Asset, 0);
    if (value.* != .mapping) return allocator.alloc(Asset, 0);
    const obj = value.mapping;
    var out: std.ArrayList(Asset) = .empty;
    errdefer {
        for (out.items) |item| item.deinit(allocator);
        out.deinit(allocator);
    }
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const id = entry.key_ptr.*;
        const raw_path = scalarText(entry.value_ptr) orelse return error.InvalidPackageManifest;
        if (!portableAtom(id) or !portableRelativePath(raw_path)) return error.InvalidPackageManifest;
        try out.append(allocator, .{ .id = try allocator.dupe(u8, id), .path = try allocator.dupe(u8, raw_path) });
    }
    return out.toOwnedSlice(allocator);
}

fn readInstall(allocator: Allocator, root: *const circuitry.value.Value) !?InstallSpec {
    const value = valueAt(root, &.{ "attach", "model" }) orelse
        valueAt(root, &.{ "install", "model" }) orelse return null;
    if (value.* != .mapping) return error.InvalidPackageManifest;
    const input = try readInstallRefs(allocator, value, "input");
    errdefer freeStringList(allocator, input);
    const tools = try readStringListField(allocator, value, "tools");
    errdefer freeStringList(allocator, tools);
    return .{ .input = input, .tools = tools };
}

fn readInstallRefs(allocator: Allocator, root: *const circuitry.value.Value, field: []const u8) ![][]u8 {
    const value = valueAt(root, &.{field}) orelse return allocator.alloc([]u8, 0);
    if (value.* != .sequence) return error.InvalidPackageManifest;
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    for (value.sequence) |*item| {
        const text = scalarText(item) orelse return error.InvalidPackageManifest;
        if (!portableInstallRef(text)) return error.InvalidPackageManifest;
        try out.append(allocator, try allocator.dupe(u8, text));
    }
    return out.toOwnedSlice(allocator);
}

fn readStringListField(allocator: Allocator, root: *const circuitry.value.Value, field: []const u8) ![][]u8 {
    const value = valueAt(root, &.{field}) orelse return allocator.alloc([]u8, 0);
    if (value.* != .sequence) return error.InvalidPackageManifest;
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    for (value.sequence) |*item| {
        const text = scalarText(item) orelse return error.InvalidPackageManifest;
        if (!portableAtom(text)) return error.InvalidPackageManifest;
        try out.append(allocator, try allocator.dupe(u8, text));
    }
    return out.toOwnedSlice(allocator);
}

fn readTools(allocator: Allocator, root: *const circuitry.value.Value, package_dir: []const u8) ![]Tool {
    const value = valueAt(root, &.{"tools"}) orelse return allocator.alloc(Tool, 0);
    if (value.* != .mapping) return error.InvalidPackageManifest;
    var out: std.ArrayList(Tool) = .empty;
    errdefer {
        for (out.items) |tool| tool.deinit(allocator);
        out.deinit(allocator);
    }
    var iter = value.mapping.iterator();
    while (iter.next()) |entry| {
        if (!portableAtom(entry.key_ptr.*) or entry.value_ptr.* != .mapping) return error.InvalidPackageManifest;
        const tool = entry.value_ptr;
        const handler_value = valueAt(tool, &.{"handler"}) orelse return error.InvalidPackageManifest;
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        const label = try allocator.dupe(u8, scalarAt(tool, &.{"label"}) orelse entry.key_ptr.*);
        errdefer allocator.free(label);
        const description = try allocator.dupe(u8, scalarAt(tool, &.{"description"}) orelse "");
        errdefer allocator.free(description);
        const prompt = try allocator.dupe(u8, scalarAt(tool, &.{"prompt"}) orelse scalarAt(tool, &.{"description"}) orelse "package tool");
        errdefer allocator.free(prompt);
        const params = try readParams(allocator, tool);
        errdefer for (params) |param| param.deinit(allocator);
        errdefer allocator.free(params);
        const handler = try readHandler(allocator, handler_value);
        errdefer handler.deinit(allocator);
        const package_dir_copy = try allocator.dupe(u8, package_dir);
        errdefer allocator.free(package_dir_copy);
        try out.append(allocator, .{ .name = name, .label = label, .description = description, .prompt = prompt, .params = params, .handler = handler, .package_dir = package_dir_copy });
    }
    return out.toOwnedSlice(allocator);
}

fn readParams(allocator: Allocator, tool: *const circuitry.value.Value) ![]Param {
    const input = valueAt(tool, &.{"input"}) orelse return allocator.alloc(Param, 0);
    if (input.* != .mapping) return error.InvalidPackageManifest;
    const docs = valueAt(tool, &.{"docs"});
    var out: std.ArrayList(Param) = .empty;
    errdefer {
        for (out.items) |param| param.deinit(allocator);
        out.deinit(allocator);
    }
    var iter = input.mapping.iterator();
    while (iter.next()) |entry| {
        if (!portableAtom(entry.key_ptr.*)) return error.InvalidPackageManifest;
        const parsed = try parseInputSchema(entry.value_ptr);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .kind = try allocator.dupe(u8, parsed.kind),
            .description = try allocator.dupe(u8, if (docs) |d| scalarAt(d, &.{entry.key_ptr.*}) orelse "" else ""),
            .required = parsed.required,
        });
    }
    return out.toOwnedSlice(allocator);
}

const ParsedInput = struct { kind: []const u8, required: bool };

fn parseInputSchema(value: *const circuitry.value.Value) !ParsedInput {
    if (value.* == .string) return .{ .kind = value.string, .required = true };
    const optional = valueAt(value, &.{"optional"}) orelse return error.InvalidPackageManifest;
    if (optional.* != .string) return error.InvalidPackageManifest;
    return .{ .kind = optional.string, .required = false };
}

fn readHandler(allocator: Allocator, value: *const circuitry.value.Value) !Handler {
    if (value.* != .mapping or value.mapping.count() != 1) return error.InvalidPackageManifest;
    var iter = value.mapping.iterator();
    const entry = iter.next().?;
    const kind = entry.key_ptr.*;
    const body = entry.value_ptr;
    if (body.* != .mapping) return error.InvalidPackageManifest;
    if (std.mem.eql(u8, kind, "process")) return .{ .process = .{ .command = try allocator.dupe(u8, platformCommand(body) orelse return error.InvalidPackageManifest) } };
    if (std.mem.eql(u8, kind, "http")) return .{ .http = .{ .url = try allocator.dupe(u8, scalarAt(body, &.{"url"}) orelse return error.InvalidPackageManifest), .method = try allocator.dupe(u8, scalarAt(body, &.{"method"}) orelse "POST") } };
    if (std.mem.eql(u8, kind, "mcp")) return .{ .mcp = .{ .command = try allocator.dupe(u8, platformCommand(body) orelse return error.InvalidPackageManifest), .tool = try allocator.dupe(u8, scalarAt(body, &.{"tool"}) orelse return error.InvalidPackageManifest) } };
    return error.InvalidPackageManifest;
}

fn readScripts(allocator: Allocator, root: *const circuitry.value.Value) ![]Script {
    const value = valueAt(root, &.{"scripts"}) orelse return allocator.alloc(Script, 0);
    if (value.* != .mapping) return error.InvalidPackageManifest;
    var out: std.ArrayList(Script) = .empty;
    errdefer {
        for (out.items) |script| script.deinit(allocator);
        out.deinit(allocator);
    }
    var iter = value.mapping.iterator();
    while (iter.next()) |entry| {
        if (!portableAtom(entry.key_ptr.*)) return error.InvalidPackageManifest;
        try out.append(allocator, .{ .name = try allocator.dupe(u8, entry.key_ptr.*), .command = try allocator.dupe(u8, platformCommand(entry.value_ptr) orelse return error.InvalidPackageManifest) });
    }
    return out.toOwnedSlice(allocator);
}

pub fn platformCommand(value: *const circuitry.value.Value) ?[]const u8 {
    if (value.* == .string) return value.string;
    if (scalarAt(value, &.{"command"})) |command| return command;
    if (scalarAt(value, &.{ "command", @tagName(platform.currentOS()) })) |command| return command;
    return scalarAt(value, &.{@tagName(platform.currentOS())});
}

pub fn portableAtom(raw: []const u8) bool {
    if (raw.len == 0 or std.mem.eql(u8, raw, ".") or std.mem.eql(u8, raw, "..")) return false;
    if (platform.path.hasPathSeparator(raw) or platform.path.isAbsolute(.windows, raw)) return false;
    for (raw) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    return true;
}

pub fn portableRelativePath(raw: []const u8) bool {
    if (raw.len == 0 or std.fs.path.isAbsolute(raw) or platform.path.isAbsolute(.windows, raw)) return false;
    var it = std.mem.tokenizeAny(u8, raw, "/\\");
    var parts: usize = 0;
    while (it.next()) |part| {
        if (!portableAtom(part)) return false;
        parts += 1;
    }
    return parts != 0;
}

pub fn freeAssets(allocator: Allocator, assets: []Asset) void {
    for (assets) |item| item.deinit(allocator);
    allocator.free(assets);
}

pub fn freeTools(allocator: Allocator, tools: []Tool) void {
    for (tools) |tool| tool.deinit(allocator);
    allocator.free(tools);
}

pub fn freeScripts(allocator: Allocator, scripts: []Script) void {
    for (scripts) |script| script.deinit(allocator);
    allocator.free(scripts);
}

pub fn freeStringList(allocator: Allocator, items: []const []u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

pub fn valueAt(value: *const circuitry.value.Value, path: []const []const u8) ?*const circuitry.value.Value {
    var v = value;
    for (path) |part| v = circuitry.value.objectGet(v, part) orelse return null;
    return v;
}

pub fn scalarAt(value: *const circuitry.value.Value, path: []const []const u8) ?[]const u8 {
    return scalarText(valueAt(value, path) orelse return null);
}

pub fn scalarText(value: *const circuitry.value.Value) ?[]const u8 {
    return if (value.* == .string) value.string else null;
}

pub const InstallRefKind = enum { prompt, file };
pub const InstallRef = struct { kind: InstallRefKind, id: []const u8 };

pub fn parseInstallRef(ref: []const u8) !InstallRef {
    if (std.mem.startsWith(u8, ref, "prompt:")) return .{ .kind = .prompt, .id = ref["prompt:".len..] };
    if (std.mem.startsWith(u8, ref, "file:")) return .{ .kind = .file, .id = ref["file:".len..] };
    return error.InvalidPackageManifest;
}

fn portableInstallRef(ref: []const u8) bool {
    const parsed = parseInstallRef(ref) catch return false;
    return portableAtom(parsed.id);
}
