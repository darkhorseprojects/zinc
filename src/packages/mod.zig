const std = @import("std");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const platform = @import("../platform.zig");
const circuitry = @import("circuitry");

const Allocator = std.mem.Allocator;

const meta_file = ".zinc-package.yaml";

pub const Scope = enum { local, global };

pub const InstallOptions = struct {
    scope: Scope = .local,
    replace: bool = false,
};

pub const PackageRef = struct {
    name: []u8,
    scope: Scope,
    path: []u8,

    pub fn deinit(self: PackageRef, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

pub const PackagePlan = struct {
    text: []u8,
    staging: []u8,

    pub fn deinit(self: PackagePlan, allocator: Allocator, io: std.Io) void {
        cleanupPath(io, self.staging);
        allocator.free(self.staging);
        allocator.free(self.text);
    }
};

const Source = struct {
    raw: []const u8,
    kind: enum { directory, git },
    url: []u8,
    subdir: []u8,
    ref: []u8,

    fn deinit(self: Source, allocator: Allocator) void {
        allocator.free(self.url);
        allocator.free(self.subdir);
        allocator.free(self.ref);
    }
};

const AssetKind = enum { graphs, prompts, files };

pub const HandlerKind = enum { graph, process, http, mcp };

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

pub const Handler = union(HandlerKind) {
    graph: struct { graph: []u8, export_name: []u8 },
    process: struct { command: []u8 },
    http: struct { url: []u8, method: []u8 },
    mcp: struct { command: []u8, tool: []u8 },

    pub fn deinit(self: Handler, allocator: Allocator) void {
        switch (self) {
            .graph => |h| {
                allocator.free(h.graph);
                allocator.free(h.export_name);
            },
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

pub const Script = struct {
    name: []u8,
    command: []u8,

    pub fn deinit(self: Script, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
    }
};

const AttachSpec = struct {
    target_kind: []u8,
    resources: [][]u8,
    input: [][]u8,
    tools: [][]u8,

    fn deinit(self: AttachSpec, allocator: Allocator) void {
        allocator.free(self.target_kind);
        freeStringList(allocator, self.resources);
        freeStringList(allocator, self.input);
        freeStringList(allocator, self.tools);
    }
};

const Asset = struct {
    id: []u8,
    path: []u8,

    fn deinit(self: Asset, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
    }
};

const Manifest = struct {
    name: []u8,
    version: []u8,
    description: []u8,
    graphs: []Asset,
    prompts: []Asset,
    files: []Asset,
    tools: []Tool,
    scripts: []Script,
    attach: ?AttachSpec,

    fn deinit(self: Manifest, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        freeAssets(allocator, self.graphs);
        freeAssets(allocator, self.prompts);
        freeAssets(allocator, self.files);
        freeTools(allocator, self.tools);
        freeScripts(allocator, self.scripts);
        if (self.attach) |spec| spec.deinit(allocator);
    }
};

pub fn add(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, source_text: []const u8, options: InstallOptions) !PackageRef {
    var source = try parseSource(allocator, source_text);
    defer source.deinit(allocator);
    const staging = try stageSource(allocator, io, source);
    defer cleanupPath(io, staging);
    defer allocator.free(staging);
    return installStaged(allocator, io, layout_ctx, source, staging, source_text, options);
}

pub fn previewAdd(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, source_text: []const u8, options: InstallOptions) !PackagePlan {
    var source = try parseSource(allocator, source_text);
    defer source.deinit(allocator);
    const staging = try stageSource(allocator, io, source);
    errdefer {
        cleanupPath(io, staging);
        allocator.free(staging);
    }
    const text = try packagePlanText(allocator, io, layout_ctx, source, staging, source_text, options, null);
    return .{ .text = text, .staging = staging };
}

pub fn installPreviewed(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, plan: PackagePlan, source_text: []const u8, options: InstallOptions) !PackageRef {
    var source = try parseSource(allocator, source_text);
    defer source.deinit(allocator);
    return installStaged(allocator, io, layout_ctx, source, plan.staging, source_text, options);
}

pub fn previewUpdate(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, name: []const u8, scope: ?Scope) !PackagePlan {
    var found = try findInstalled(allocator, layout_ctx, name, scope);
    defer found.deinit(allocator);
    const source_text = try readMetadataSource(allocator, found.path);
    defer allocator.free(source_text);
    var source = try parseSource(allocator, source_text);
    defer source.deinit(allocator);
    const staging = try stageSource(allocator, io, source);
    errdefer {
        cleanupPath(io, staging);
        allocator.free(staging);
    }
    const text = try packagePlanText(allocator, io, layout_ctx, source, staging, source_text, .{ .scope = found.scope, .replace = true }, found.path);
    return .{ .text = text, .staging = staging };
}

fn installStaged(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, source: Source, staging: []const u8, source_text: []const u8, options: InstallOptions) !PackageRef {
    const package_dir = try sourcePackageDir(allocator, staging, source.subdir);
    defer allocator.free(package_dir);
    const manifest = try loadManifest(allocator, io, package_dir);
    defer manifest.deinit(allocator);

    const root = try scopeRoot(allocator, layout_ctx, options.scope);
    defer allocator.free(root);
    const destination = try std.fs.path.join(allocator, &.{ root, manifest.name });
    errdefer allocator.free(destination);

    if (files.existsPath(destination)) {
        if (!options.replace) return error.PackageAlreadyAdded;
        try removePath(io, destination);
    }
    try files.mkdirP(root);
    try copyTree(allocator, io, package_dir, destination);
    try writeMetadata(allocator, destination, source_text, options.scope);
    return .{ .name = try allocator.dupe(u8, manifest.name), .scope = options.scope, .path = destination };
}

pub fn remove(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, name: []const u8, scope: ?Scope) !PackageRef {
    const found = try findInstalled(allocator, layout_ctx, name, scope);
    errdefer found.deinit(allocator);
    try removePath(io, found.path);
    return found;
}

pub fn update(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, name: []const u8, scope: ?Scope) !PackageRef {
    var found = try findInstalled(allocator, layout_ctx, name, scope);
    defer found.deinit(allocator);
    const source = try readMetadataSource(allocator, found.path);
    defer allocator.free(source);
    return add(allocator, io, layout_ctx, source, .{ .scope = found.scope, .replace = true });
}

pub fn updateAll(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try updatePackagesInRoot(allocator, io, layout_ctx, &out, .local, ".zinc/packages");
    const global = try scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    try updatePackagesInRoot(allocator, io, layout_ctx, &out, .global, global);
    return out.toOwnedSlice(allocator);
}

pub fn show(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, name: []const u8, scope: ?Scope) ![]u8 {
    const found = try findInstalled(allocator, layout_ctx, name, scope);
    defer found.deinit(allocator);
    const manifest = try loadManifest(allocator, io, found.path);
    defer manifest.deinit(allocator);
    const source = readMetadataSource(allocator, found.path) catch try allocator.dupe(u8, "");
    defer allocator.free(source);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "name: {s}\nscope: {s}\npath: {s}\n", .{ manifest.name, scopeName(found.scope), found.path });
    if (manifest.version.len != 0) try out.print(allocator, "version: {s}\n", .{manifest.version});
    if (manifest.description.len != 0) try out.print(allocator, "description: {s}\n", .{manifest.description});
    if (source.len != 0) try out.print(allocator, "source: {s}\n", .{source});
    try appendAssets(allocator, &out, "graphs", manifest.graphs);
    try appendAssets(allocator, &out, "prompts", manifest.prompts);
    try appendAssets(allocator, &out, "files", manifest.files);
    return out.toOwnedSlice(allocator);
}

fn packagePlanText(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, source: Source, staging: []const u8, source_text: []const u8, options: InstallOptions, current_path: ?[]const u8) ![]u8 {
    const package_dir = try sourcePackageDir(allocator, staging, source.subdir);
    defer allocator.free(package_dir);
    const manifest = try loadManifest(allocator, io, package_dir);
    defer manifest.deinit(allocator);
    const root = try scopeRoot(allocator, layout_ctx, options.scope);
    defer allocator.free(root);
    const destination = try std.fs.path.join(allocator, &.{ root, manifest.name });
    defer allocator.free(destination);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "source: {s}\nname: {s}\n", .{ source_text, manifest.name });
    if (manifest.version.len != 0) try out.print(allocator, "version: {s}\n", .{manifest.version});
    if (manifest.description.len != 0) try out.print(allocator, "description: {s}\n", .{manifest.description});
    try out.print(allocator, "scope: {s}\ntarget: {s}\n", .{ scopeName(options.scope), destination });
    if (current_path) |path| try out.print(allocator, "current: {s}\n", .{path});
    try appendAssets(allocator, &out, "graphs", manifest.graphs);
    try appendAssets(allocator, &out, "prompts", manifest.prompts);
    try appendAssets(allocator, &out, "files", manifest.files);
    try appendTools(allocator, &out, manifest.tools);
    try appendScripts(allocator, &out, manifest.scripts);
    return out.toOwnedSlice(allocator);
}

pub fn listPackages(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendPackageNames(allocator, io, &out, .local, ".zinc/packages");
    const global = try scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    try appendPackageNames(allocator, io, &out, .global, global);
    return out.toOwnedSlice(allocator);
}

pub fn listGraphs(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendGraphDir(allocator, io, &out, "project", "graphs");
    try appendPackageGraphAssets(allocator, io, &out, .local, ".zinc/packages");
    const global = try scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    try appendPackageGraphAssets(allocator, io, &out, .global, global);
    const shared = try layout.sharePath(allocator, layout_ctx, "graphs");
    defer allocator.free(shared);
    try appendGraphDir(allocator, io, &out, "stock", shared);
    return out.toOwnedSlice(allocator);
}

pub fn resolveGraph(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, spec: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(spec)) return allocator.dupe(u8, spec);
    if (files.existsPath(spec)) return allocator.dupe(u8, spec);
    if (try graphInDir(allocator, "graphs", spec)) |path| return path;
    if (try graphAssetInRoot(allocator, io, ".zinc/packages", spec)) |path| return path;
    const global = try scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    if (try graphAssetInRoot(allocator, io, global, spec)) |path| return path;
    const shared_graphs = try layout.sharePath(allocator, layout_ctx, "graphs");
    defer allocator.free(shared_graphs);
    if (try graphInDir(allocator, shared_graphs, spec)) |path| return path;
    return error.GraphNotFound;
}

pub fn resolvePrompt(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, spec: []const u8) ![]u8 {
    if (try assetInRoot(allocator, io, ".zinc/packages", spec, .prompts)) |path| return path;
    const global = try scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    if (try assetInRoot(allocator, io, global, spec, .prompts)) |path| return path;
    return error.PromptNotFound;
}

pub fn resolveAsset(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, spec: []const u8) ![]u8 {
    if (try assetInRoot(allocator, io, ".zinc/packages", spec, .files)) |path| return path;
    const global = try scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    if (try assetInRoot(allocator, io, global, spec, .files)) |path| return path;
    return error.AssetNotFound;
}

pub fn findTool(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, name: []const u8) !?Tool {
    if (try toolInRoot(allocator, io, ".zinc/packages", name)) |tool| return tool;
    const global = try scopeRoot(allocator, layout_ctx, .global);
    defer allocator.free(global);
    return toolInRoot(allocator, io, global, name);
}

pub fn attach(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, package_name: []const u8) ![]u8 {
    var found = try findInstalled(allocator, layout_ctx, package_name, null);
    defer found.deinit(allocator);
    const manifest = try loadManifest(allocator, io, found.path);
    defer manifest.deinit(allocator);
    const spec = manifest.attach orelse return error.PackageHasNoAttach;
    const loop_path = try layout.sharePath(allocator, layout_ctx, "graphs/zinc-loop.circuitry.yaml");
    defer allocator.free(loop_path);
    const model = try selectAttachTarget(allocator, io, loop_path, spec.target_kind);
    defer allocator.free(model);

    var names = try graphAttachmentNames(allocator, io);
    defer freeStringList(allocator, names);
    if (!stringListContains(names, found.name)) {
        const next = try appendString(allocator, names, found.name);
        allocator.free(names);
        names = next;
    }

    var preview: std.ArrayList(u8) = .empty;
    defer preview.deinit(allocator);
    try preview.print(allocator, "Attach package {s}\n\n", .{found.name});
    try preview.print(allocator, "extension graph: .zinc/graphs/zinc-extensions.circuitry.yaml\nloop graph: {s}\nmodel: {s}\n\n", .{ loop_path, model });
    try preview.appendSlice(allocator, "add input:\n");
    for (spec.input) |id| try preview.print(allocator, "  - extensions.{s}\n", .{id});
    try preview.appendSlice(allocator, "add tools:\n");
    for (spec.tools) |tool| try preview.print(allocator, "  - {s}\n", .{tool});
    try confirmApply(preview.items);

    try regenerateAttachments(allocator, io, layout_ctx, names, model);
    try wireLoopGraph(allocator, io, loop_path, model, spec);
    return std.fmt.allocPrint(allocator, "attached {s}\n.zinc/graphs/zinc-extensions.circuitry.yaml\n.zinc/generated/extensions.md\n", .{found.name});
}

pub fn detach(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, package_name: []const u8) ![]u8 {
    const loop_path = try layout.sharePath(allocator, layout_ctx, "graphs/zinc-loop.circuitry.yaml");
    defer allocator.free(loop_path);
    const metadata = try extensionMetadata(allocator, io, package_name);
    defer metadata.deinit(allocator);
    var preview: std.ArrayList(u8) = .empty;
    defer preview.deinit(allocator);
    try preview.print(allocator, "Detach package {s}\n\n", .{package_name});
    try preview.print(allocator, "extension graph: .zinc/graphs/zinc-extensions.circuitry.yaml\nloop graph: {s}\nmodel: {s}\n\n", .{ loop_path, metadata.model });
    try preview.appendSlice(allocator, "remove input:\n");
    for (metadata.input) |id| try preview.print(allocator, "  - extensions.{s}\n", .{id});
    try preview.appendSlice(allocator, "remove tools:\n");
    for (metadata.tools) |tool| try preview.print(allocator, "  - {s}\n", .{tool});
    try confirmApply(preview.items);

    const names = try graphAttachmentNames(allocator, io);
    defer freeStringList(allocator, names);
    const next = try removeString(allocator, names, package_name);
    defer freeStringList(allocator, next);
    try unwireLoopGraph(allocator, io, loop_path, metadata);
    if (next.len == 0) {
        std.Io.Dir.cwd().deleteFile(std.Options.debug_io, ".zinc/graphs/zinc-extensions.circuitry.yaml") catch {};
        std.Io.Dir.cwd().deleteFile(std.Options.debug_io, ".zinc/generated/extensions.md") catch {};
    } else try regenerateAttachments(allocator, io, layout_ctx, next, metadata.model);
    return std.fmt.allocPrint(allocator, "detached {s}\n", .{package_name});
}

pub fn attachments(allocator: Allocator, io: std.Io) ![]u8 {
    const names = try graphAttachmentNames(allocator, io);
    defer freeStringList(allocator, names);
    if (names.len == 0) return allocator.dupe(u8, "no package attachments\n");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (names) |name| try out.print(allocator, "{s}\n", .{name});
    return out.toOwnedSlice(allocator);
}

pub fn execScript(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, package_name: []const u8, script_name: []const u8) ![]u8 {
    var found = try findInstalled(allocator, layout_ctx, package_name, null);
    defer found.deinit(allocator);
    const manifest = try loadManifest(allocator, io, found.path);
    defer manifest.deinit(allocator);
    for (manifest.scripts) |script| if (std.mem.eql(u8, script.name, script_name)) {
        const command = try platform.process.resolveCommand(allocator, io, platform.currentOS(), .{}, script.command, found.path);
        defer allocator.free(command);
        const result = try platform.process.run(allocator, io, &.{command}, found.path, 1024 * 1024);
        defer allocator.free(result.stderr);
        if (result.code != 0) {
            allocator.free(result.stdout);
            return error.PackageScriptFailed;
        }
        return result.stdout;
    };
    return error.PackageScriptNotFound;
}

fn stageSource(allocator: Allocator, io: std.Io, source: Source) ![]u8 {
    switch (source.kind) {
        .directory => return allocator.dupe(u8, source.url),
        .git => {
            try files.mkdirP(".zinc/tmp");
            const base = try tempPath(allocator, io, "zinc-pkg-");
            errdefer allocator.free(base);
            if (source.ref.len == 0) {
                try run(allocator, io, &.{ "git", "clone", "--depth", "1", source.url, base });
            } else {
                try run(allocator, io, &.{ "git", "clone", source.url, base });
                try run(allocator, io, &.{ "git", "-C", base, "checkout", "--detach", source.ref });
            }
            return base;
        },
    }
}

fn sourcePackageDir(allocator: Allocator, root: []const u8, subdir: []const u8) ![]u8 {
    if (subdir.len == 0) return allocator.dupe(u8, root);
    return std.fs.path.join(allocator, &.{ root, subdir });
}

fn parseSource(allocator: Allocator, raw: []const u8) !Source {
    const split = splitRef(raw);
    const body = split.body;
    if (std.mem.startsWith(u8, body, "github:")) return parseGithub(allocator, body["github:".len..], raw, split.ref);
    if (std.mem.startsWith(u8, body, "git+")) return .{ .raw = raw, .kind = .git, .url = try allocator.dupe(u8, body["git+".len..]), .subdir = try allocator.dupe(u8, ""), .ref = try allocator.dupe(u8, split.ref) };
    if (std.mem.endsWith(u8, body, ".git") or std.mem.startsWith(u8, body, "https://github.com/") or std.mem.startsWith(u8, body, "http://github.com/")) return parseGitUrl(allocator, body, raw, split.ref);
    if (split.ref.len != 0) return error.InvalidPackageSource;
    return .{ .raw = raw, .kind = .directory, .url = try allocator.dupe(u8, raw), .subdir = try allocator.dupe(u8, ""), .ref = try allocator.dupe(u8, "") };
}

const RefSplit = struct { body: []const u8, ref: []const u8 };

fn splitRef(raw: []const u8) RefSplit {
    if (std.mem.lastIndexOfScalar(u8, raw, '#')) |idx| return .{ .body = raw[0..idx], .ref = raw[idx + 1 ..] };
    return .{ .body = raw, .ref = "" };
}

fn parseGithub(allocator: Allocator, spec: []const u8, raw: []const u8, ref: []const u8) !Source {
    var parts = std.mem.splitScalar(u8, spec, '/');
    const user = parts.next() orelse return error.InvalidPackageSource;
    const repo = parts.next() orelse return error.InvalidPackageSource;
    if (user.len == 0 or repo.len == 0) return error.InvalidPackageSource;
    var sub: std.ArrayList(u8) = .empty;
    defer sub.deinit(allocator);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (sub.items.len != 0) try sub.append(allocator, '/');
        try sub.appendSlice(allocator, part);
    }
    return .{ .raw = raw, .kind = .git, .url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}.git", .{ user, repo }), .subdir = try sub.toOwnedSlice(allocator), .ref = try allocator.dupe(u8, ref) };
}

fn parseGitUrl(allocator: Allocator, body: []const u8, raw: []const u8, ref: []const u8) !Source {
    const marker = ".git/";
    if (std.mem.indexOf(u8, body, marker)) |idx| {
        return .{ .raw = raw, .kind = .git, .url = try allocator.dupe(u8, body[0 .. idx + 4]), .subdir = try allocator.dupe(u8, body[idx + marker.len ..]), .ref = try allocator.dupe(u8, ref) };
    }
    return .{ .raw = raw, .kind = .git, .url = try allocator.dupe(u8, body), .subdir = try allocator.dupe(u8, ""), .ref = try allocator.dupe(u8, ref) };
}

fn loadManifest(allocator: Allocator, io: std.Io, package_dir: []const u8) !Manifest {
    const path = try std.fs.path.join(allocator, &.{ package_dir, "zinc.pkg.yaml" });
    defer allocator.free(path);

    var document = try circuitry.loadYamlFile(allocator, io, path);
    defer document.deinit();
    const root = &document.root;
    if (root.* != .mapping) return error.InvalidPackageManifest;

    const name = scalarAt(root, &.{"name"}) orelse return error.InvalidPackageManifest;
    if (!portableAtom(name)) return error.InvalidPackageManifest;
    return .{
        .name = try allocator.dupe(u8, name),
        .version = try allocator.dupe(u8, scalarAt(root, &.{"version"}) orelse ""),
        .description = try allocator.dupe(u8, scalarAt(root, &.{"description"}) orelse ""),
        .graphs = try readAssets(allocator, root, &.{ "assets", "graphs" }),
        .prompts = try readAssets(allocator, root, &.{ "assets", "prompts" }),
        .files = try readAssets(allocator, root, &.{ "assets", "files" }),
        .tools = try readTools(allocator, root, package_dir),
        .scripts = try readScripts(allocator, root),
        .attach = try readAttach(allocator, root),
    };
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

const ExtensionMetadata = struct {
    package: []u8,
    model: []u8,
    resources: [][]u8,
    input: [][]u8,
    tools: [][]u8,

    fn deinit(self: ExtensionMetadata, allocator: Allocator) void {
        allocator.free(self.package);
        allocator.free(self.model);
        freeStringList(allocator, self.resources);
        freeStringList(allocator, self.input);
        freeStringList(allocator, self.tools);
    }
};

fn confirmApply(preview: []const u8) !void {
    try files.writeAllErr(preview);
    try files.writeAllErr("\nApply? [y/N] ");
    var buf: [16]u8 = undefined;
    const n = try files.readStdin(&buf);
    if (n == 0) return error.UserCancelled;
    const answer = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (answer.len == 0 or (answer[0] != 'y' and answer[0] != 'Y')) return error.UserCancelled;
}

fn selectAttachTarget(allocator: Allocator, io: std.Io, loop_path: []const u8, kind: []const u8) ![]u8 {
    var graph = try circuitry.loadFile(allocator, io, loop_path);
    defer graph.deinit();
    const matches = try circuitry.query.resourcesByKind(allocator, &graph, kind);
    defer allocator.free(matches);
    if (matches.len == 0) return error.NoCompatibleAttachTarget;
    if (matches.len == 1) return allocator.dupe(u8, matches[0].id);
    try files.writeAllErr("Choose attach target:\n");
    for (matches, 0..) |item, i| {
        const line = try std.fmt.allocPrint(allocator, "  {d}) {s}\n", .{ i + 1, item.id });
        defer allocator.free(line);
        try files.writeAllErr(line);
    }
    try files.writeAllErr("Target number: ");
    var buf: [32]u8 = undefined;
    const n = try files.readStdin(&buf);
    const raw = std.mem.trim(u8, buf[0..n], " \t\r\n");
    const index = try std.fmt.parseInt(usize, raw, 10);
    if (index == 0 or index > matches.len) return error.InvalidAttachTarget;
    return allocator.dupe(u8, matches[index - 1].id);
}

fn extensionMetadata(allocator: Allocator, io: std.Io, package_name: []const u8) !ExtensionMetadata {
    var graph = try circuitry.loadFile(allocator, io, ".zinc/graphs/zinc-extensions.circuitry.yaml");
    defer graph.deinit();
    const resources = graph.resources() orelse return error.PackageNotAttached;
    if (resources.* != .mapping) return error.PackageNotAttached;
    var iter = resources.mapping.iterator();
    while (iter.next()) |entry| {
        const payload = circuitry.query.customResourcePayload(&graph, entry.key_ptr.*, "extension") orelse continue;
        const package = scalarAt(payload, &.{"package"}) orelse continue;
        if (!std.mem.eql(u8, package, package_name)) continue;
        return .{
            .package = try allocator.dupe(u8, package),
            .model = try allocator.dupe(u8, scalarAt(payload, &.{ "bound", "model" }) orelse return error.PackageNotAttached),
            .resources = try readStringListField(allocator, payload, "resources"),
            .input = try readStringListField(allocator, payload, "input"),
            .tools = try readStringListField(allocator, payload, "tools"),
        };
    }
    return error.PackageNotAttached;
}

fn graphAttachmentNames(allocator: Allocator, io: std.Io) ![][]u8 {
    if (!files.existsPath(".zinc/graphs/zinc-extensions.circuitry.yaml")) return allocator.alloc([]u8, 0);
    var graph = try circuitry.loadFile(allocator, io, ".zinc/graphs/zinc-extensions.circuitry.yaml");
    defer graph.deinit();
    const resources = graph.resources() orelse return allocator.alloc([]u8, 0);
    if (resources.* != .mapping) return allocator.alloc([]u8, 0);
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    var iter = resources.mapping.iterator();
    while (iter.next()) |entry| {
        const payload = circuitry.query.customResourcePayload(&graph, entry.key_ptr.*, "extension") orelse continue;
        const package = scalarAt(payload, &.{"package"}) orelse continue;
        if (!stringListContains(out.items, package)) try out.append(allocator, try allocator.dupe(u8, package));
    }
    return out.toOwnedSlice(allocator);
}

fn regenerateAttachments(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, names: []const []u8, model: []const u8) !void {
    try files.mkdirP(".zinc/graphs");
    try files.mkdirP(".zinc/generated");
    var graph_text: std.ArrayList(u8) = .empty;
    errdefer graph_text.deinit(allocator);
    var md: std.ArrayList(u8) = .empty;
    errdefer md.deinit(allocator);
    try graph_text.appendSlice(allocator,
        \\circuitry: "0.5"
        \\title: Zinc package extensions
        \\exports:
        \\  main: extensions_context
        \\resources:
        \\  extensions_context:
        \\    text:
        \\      path: ../generated/extensions.md
        \\
    );
    try md.appendSlice(allocator, "# Zinc package extensions\n\n");
    for (names) |name| {
        var found = try findInstalled(allocator, layout_ctx, name, null);
        defer found.deinit(allocator);
        const manifest = try loadManifest(allocator, io, found.path);
        defer manifest.deinit(allocator);
        try appendExtensionResources(allocator, &graph_text, manifest, model);
        const section = try extensionMarkdown(allocator, manifest);
        defer allocator.free(section);
        try md.appendSlice(allocator, section);
    }
    try files.write(".zinc/graphs/zinc-extensions.circuitry.yaml", graph_text.items);
    try files.write(".zinc/generated/extensions.md", md.items);
    graph_text.deinit(allocator);
    md.deinit(allocator);
}

fn appendExtensionResources(allocator: Allocator, out: *std.ArrayList(u8), manifest: Manifest, model: []const u8) !void {
    const spec = manifest.attach orelse return;
    for (manifest.prompts) |prompt| {
        try out.print(allocator,
            \\  {s}:
            \\    text:
            \\      uri: prompt:{s}
            \\
        , .{ prompt.id, prompt.id });
    }
    try out.print(allocator,
        \\  {s}_extension:
        \\    extension:
        \\      package: {s}
        \\      resources:
        \\
    , .{ manifest.name, manifest.name });
    for (spec.resources) |id| try out.print(allocator, "        - {s}\n", .{id});
    try out.appendSlice(allocator, "      input:\n");
    for (spec.input) |id| try out.print(allocator, "        - {s}\n", .{id});
    try out.appendSlice(allocator, "      tools:\n");
    for (spec.tools) |tool| try out.print(allocator, "        - {s}\n", .{tool});
    try out.print(allocator, "      bound:\n        model: {s}\n", .{model});
}

fn wireLoopGraph(allocator: Allocator, io: std.Io, loop_path: []const u8, model: []const u8, spec: AttachSpec) !void {
    const text = try files.readLimited(allocator, loop_path, 1024 * 1024);
    defer allocator.free(text);
    var edited = try ensureExtensionsImport(allocator, io, text);
    defer allocator.free(edited);
    for (spec.input) |id| {
        const item = try std.fmt.allocPrint(allocator, "extensions.{s}", .{id});
        defer allocator.free(item);
        const next = try ensureModelListItem(allocator, edited, model, "input", item);
        allocator.free(edited);
        edited = next;
    }
    for (spec.tools) |tool| {
        const next = try ensureModelListItem(allocator, edited, model, "tools", tool);
        allocator.free(edited);
        edited = next;
    }
    try files.write(loop_path, edited);
}

fn unwireLoopGraph(allocator: Allocator, io: std.Io, loop_path: []const u8, metadata: ExtensionMetadata) !void {
    _ = io;
    const text = try files.readLimited(allocator, loop_path, 1024 * 1024);
    defer allocator.free(text);
    var edited = try allocator.dupe(u8, text);
    defer allocator.free(edited);
    for (metadata.input) |id| {
        const item = try std.fmt.allocPrint(allocator, "extensions.{s}", .{id});
        defer allocator.free(item);
        const next = try removeModelListItem(allocator, edited, metadata.model, "input", item);
        allocator.free(edited);
        edited = next;
    }
    for (metadata.tools) |tool| {
        const next = try removeModelListItem(allocator, edited, metadata.model, "tools", tool);
        allocator.free(edited);
        edited = next;
    }
    try files.write(loop_path, edited);
}

fn ensureExtensionsImport(allocator: Allocator, io: std.Io, text: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, text, "\n  extensions:") != null) return allocator.dupe(u8, text);
    const cwd = try currentWorkingDirectory(allocator, io);
    defer allocator.free(cwd);
    const import_path = try std.fs.path.join(allocator, &.{ cwd, ".zinc/graphs/zinc-extensions.circuitry.yaml" });
    defer allocator.free(import_path);
    const line = try std.fmt.allocPrint(allocator, "imports:\n  extensions: {s}\n\n", .{import_path});
    defer allocator.free(line);
    if (std.mem.indexOf(u8, text, "\nexports:\n")) |pos| return splice(allocator, text, pos + 1, line);
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ line, text });
}

fn ensureModelListItem(allocator: Allocator, text: []const u8, model: []const u8, field: []const u8, item: []const u8) ![]u8 {
    const field_pos = try modelFieldPosition(allocator, text, model, field);
    const block_end = nextResourcePosition(text, field_pos) orelse text.len;
    if (std.mem.indexOf(u8, text[field_pos..block_end], item) != null) return allocator.dupe(u8, text);
    const header_end = std.mem.indexOfScalarPos(u8, text, field_pos, '\n') orelse return error.AttachTargetFieldNotFound;
    const insert = try std.fmt.allocPrint(allocator, "        - {s}\n", .{item});
    defer allocator.free(insert);
    return splice(allocator, text, header_end + 1, insert);
}

fn removeModelListItem(allocator: Allocator, text: []const u8, model: []const u8, field: []const u8, item: []const u8) ![]u8 {
    const field_pos = modelFieldPosition(allocator, text, model, field) catch return allocator.dupe(u8, text);
    const block_end = nextResourcePosition(text, field_pos) orelse text.len;
    const item_line = try std.fmt.allocPrint(allocator, "        - {s}\n", .{item});
    defer allocator.free(item_line);
    const rel = std.mem.indexOf(u8, text[field_pos..block_end], item_line) orelse return allocator.dupe(u8, text);
    return spliceRemove(allocator, text, field_pos + rel, item_line.len);
}

fn modelFieldPosition(allocator: Allocator, text: []const u8, model: []const u8, field: []const u8) !usize {
    const model_header = try std.fmt.allocPrint(allocator, "  {s}:\n    model:\n", .{model});
    defer allocator.free(model_header);
    const model_pos = std.mem.indexOf(u8, text, model_header) orelse return error.AttachTargetNotFound;
    const model_end = nextResourcePosition(text, model_pos + model_header.len) orelse text.len;
    const field_header = try std.fmt.allocPrint(allocator, "      {s}:\n", .{field});
    defer allocator.free(field_header);
    const rel = std.mem.indexOf(u8, text[model_pos..model_end], field_header) orelse return error.AttachTargetFieldNotFound;
    return model_pos + rel;
}

fn nextResourcePosition(text: []const u8, start: usize) ?usize {
    var pos = start;
    while (std.mem.indexOf(u8, text[pos..], "\n  ")) |rel| {
        pos += rel + 1;
        if (pos + 2 < text.len and text[pos + 2] != ' ') return pos;
        pos += 2;
    }
    return null;
}

fn currentWorkingDirectory(allocator: Allocator, io: std.Io) ![]u8 {
    const cwd_z = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_z);
    return allocator.dupe(u8, cwd_z[0..cwd_z.len]);
}

fn splice(allocator: Allocator, text: []const u8, pos: usize, insert: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text[0..pos]);
    try out.appendSlice(allocator, insert);
    try out.appendSlice(allocator, text[pos..]);
    return out.toOwnedSlice(allocator);
}

fn spliceRemove(allocator: Allocator, text: []const u8, pos: usize, len: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, text[0..pos]);
    try out.appendSlice(allocator, text[pos + len ..]);
    return out.toOwnedSlice(allocator);
}

fn extensionMarkdown(allocator: Allocator, manifest: Manifest) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "## {s}\n\n", .{manifest.name});
    if (manifest.description.len != 0) try out.print(allocator, "{s}\n\n", .{manifest.description});
    if (manifest.tools.len != 0) {
        try out.appendSlice(allocator, "### Tools\n\n");
        for (manifest.tools) |tool| try out.print(allocator, "- `{s}` ({s}): {s}\n", .{ tool.name, @tagName(tool.handler), tool.description });
        try out.append(allocator, '\n');
    }
    if (manifest.graphs.len != 0) {
        try out.appendSlice(allocator, "### Graphs\n\n");
        for (manifest.graphs) |item| try out.print(allocator, "- `{s}`: `{s}`\n", .{ item.id, item.path });
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn readAttach(allocator: Allocator, root: *const circuitry.value.Value) !?AttachSpec {
    const value = valueAt(root, &.{"attach"}) orelse return null;
    if (value.* != .mapping) return error.InvalidPackageManifest;
    const target_kind = scalarAt(value, &.{ "target", "kind" }) orelse return error.InvalidPackageManifest;
    return .{
        .target_kind = try allocator.dupe(u8, target_kind),
        .resources = try readStringListField(allocator, value, "resources"),
        .input = try readStringListField(allocator, value, "input"),
        .tools = try readStringListField(allocator, value, "tools"),
    };
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
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key_ptr.*),
            .label = try allocator.dupe(u8, scalarAt(tool, &.{"label"}) orelse entry.key_ptr.*),
            .description = try allocator.dupe(u8, scalarAt(tool, &.{"description"}) orelse ""),
            .prompt = try allocator.dupe(u8, scalarAt(tool, &.{"prompt"}) orelse scalarAt(tool, &.{"description"}) orelse "package tool"),
            .params = try readParams(allocator, tool),
            .handler = try readHandler(allocator, handler_value),
            .package_dir = try allocator.dupe(u8, package_dir),
        });
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
    if (std.mem.eql(u8, kind, "graph")) return .{ .graph = .{ .graph = try allocator.dupe(u8, scalarAt(body, &.{"graph"}) orelse return error.InvalidPackageManifest), .export_name = try allocator.dupe(u8, scalarAt(body, &.{"export"}) orelse "main") } };
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

fn platformCommand(value: *const circuitry.value.Value) ?[]const u8 {
    if (value.* == .string) return value.string;
    if (scalarAt(value, &.{"command"})) |command| return command;
    if (scalarAt(value, &.{ "command", @tagName(platform.currentOS()) })) |command| return command;
    return scalarAt(value, &.{@tagName(platform.currentOS())});
}

fn findInstalled(allocator: Allocator, layout_ctx: layout.Context, name: []const u8, scope: ?Scope) !PackageRef {
    if (scope) |s| {
        if (try installedAt(allocator, layout_ctx, name, s)) |ref| return ref;
        return error.PackageNotFound;
    }
    const local = try installedAt(allocator, layout_ctx, name, .local);
    const global = try installedAt(allocator, layout_ctx, name, .global);
    if (local != null and global != null) {
        if (local) |l| l.deinit(allocator);
        if (global) |g| g.deinit(allocator);
        return error.PackageScopeRequired;
    }
    if (local) |l| return l;
    if (global) |g| return g;
    return error.PackageNotFound;
}

fn installedAt(allocator: Allocator, layout_ctx: layout.Context, name: []const u8, scope: Scope) !?PackageRef {
    const root = try scopeRoot(allocator, layout_ctx, scope);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, name });
    if (!files.existsPath(path)) {
        allocator.free(path);
        return null;
    }
    return .{ .name = try allocator.dupe(u8, name), .scope = scope, .path = path };
}

fn scopeRoot(allocator: Allocator, layout_ctx: layout.Context, scope: Scope) ![]u8 {
    return switch (scope) {
        .local => allocator.dupe(u8, ".zinc/packages"),
        .global => layout.sharePath(allocator, layout_ctx, "packages"),
    };
}

fn writeMetadata(allocator: Allocator, package_dir: []const u8, source: []const u8, scope: Scope) !void {
    const path = try std.fs.path.join(allocator, &.{ package_dir, meta_file });
    defer allocator.free(path);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.print(allocator, "source: {s}\nscope: {s}\n", .{ source, scopeName(scope) });
    try files.write(path, out.items);
}

fn readMetadataSource(allocator: Allocator, package_dir: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ package_dir, meta_file });
    defer allocator.free(path);
    var parsed = try circuitry.loadYamlFile(allocator, std.Options.debug_io, path);
    defer parsed.deinit();
    const source = scalarAt(&parsed.root, &.{"source"}) orelse return error.InvalidPackageMetadata;
    return allocator.dupe(u8, source);
}

fn graphInDir(allocator: Allocator, dir: []const u8, spec: []const u8) !?[]u8 {
    const names = [_][]const u8{ spec, try std.fmt.allocPrint(allocator, "{s}.circuitry.yaml", .{spec}), try std.fmt.allocPrint(allocator, "{s}.yaml", .{spec}) };
    defer allocator.free(names[1]);
    defer allocator.free(names[2]);
    for (names) |name| {
        const path = try std.fs.path.join(allocator, &.{ dir, name });
        if (files.existsPath(path)) return path;
        allocator.free(path);
    }
    return null;
}

fn graphAssetInRoot(allocator: Allocator, io: std.Io, root_path: []const u8, spec: []const u8) !?[]u8 {
    return assetInRoot(allocator, io, root_path, spec, .graphs);
}

fn assetInRoot(allocator: Allocator, io: std.Io, root_path: []const u8, spec: []const u8, kind: AssetKind) !?[]u8 {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return null;
    defer root.close(io);
    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const package_dir = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(package_dir);
        const manifest = loadManifest(allocator, io, package_dir) catch continue;
        defer manifest.deinit(allocator);
        const assets = assetsFor(manifest, kind);
        for (assets) |item| {
            if (std.mem.eql(u8, item.id, spec)) {
                const path = try std.fs.path.join(allocator, &.{ package_dir, item.path });
                return path;
            }
        }
    }
    return null;
}

fn toolInRoot(allocator: Allocator, io: std.Io, root_path: []const u8, name: []const u8) !?Tool {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return null;
    defer root.close(io);
    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const package_dir = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(package_dir);
        const manifest = loadManifest(allocator, io, package_dir) catch continue;
        defer manifest.deinit(allocator);
        for (manifest.tools) |tool| if (std.mem.eql(u8, tool.name, name)) return try cloneTool(allocator, tool);
    }
    return null;
}

fn cloneTool(allocator: Allocator, tool: Tool) !Tool {
    var params = try allocator.alloc(Param, tool.params.len);
    var initialized: usize = 0;
    errdefer {
        for (params[0..initialized]) |param| param.deinit(allocator);
        allocator.free(params);
    }
    for (tool.params, 0..) |param, i| {
        params[i] = .{ .name = try allocator.dupe(u8, param.name), .kind = try allocator.dupe(u8, param.kind), .description = try allocator.dupe(u8, param.description), .required = param.required };
        initialized += 1;
    }
    return .{
        .name = try allocator.dupe(u8, tool.name),
        .label = try allocator.dupe(u8, tool.label),
        .description = try allocator.dupe(u8, tool.description),
        .prompt = try allocator.dupe(u8, tool.prompt),
        .params = params,
        .handler = try cloneHandler(allocator, tool.handler),
        .package_dir = try allocator.dupe(u8, tool.package_dir),
    };
}

fn cloneHandler(allocator: Allocator, handler: Handler) !Handler {
    return switch (handler) {
        .graph => |h| .{ .graph = .{ .graph = try allocator.dupe(u8, h.graph), .export_name = try allocator.dupe(u8, h.export_name) } },
        .process => |h| .{ .process = .{ .command = try allocator.dupe(u8, h.command) } },
        .http => |h| .{ .http = .{ .url = try allocator.dupe(u8, h.url), .method = try allocator.dupe(u8, h.method) } },
        .mcp => |h| .{ .mcp = .{ .command = try allocator.dupe(u8, h.command), .tool = try allocator.dupe(u8, h.tool) } },
    };
}

fn appendPackageNames(allocator: Allocator, io: std.Io, out: *std.ArrayList(u8), scope: Scope, root_path: []const u8) !void {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer root.close(io);
    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const package_dir = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(package_dir);
        const manifest = loadManifest(allocator, io, package_dir) catch continue;
        defer manifest.deinit(allocator);
        try out.print(allocator, "{s}: {s}", .{ scopeName(scope), manifest.name });
        if (manifest.version.len != 0) try out.print(allocator, "@{s}", .{manifest.version});
        try out.print(allocator, "  {s}\n", .{package_dir});
    }
}

fn appendPackageGraphAssets(allocator: Allocator, io: std.Io, out: *std.ArrayList(u8), scope: Scope, root_path: []const u8) !void {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer root.close(io);
    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const package_dir = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(package_dir);
        const manifest = loadManifest(allocator, io, package_dir) catch continue;
        defer manifest.deinit(allocator);
        for (manifest.graphs) |item| try out.print(allocator, "{s} package {s}: {s} -> {s}/{s}\n", .{ scopeName(scope), manifest.name, item.id, package_dir, item.path });
    }
}

fn updatePackagesInRoot(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, out: *std.ArrayList(u8), scope: Scope, root_path: []const u8) !void {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return;
    defer root.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    for (names.items) |name| {
        var package = try update(allocator, io, layout_ctx, name, scope);
        defer package.deinit(allocator);
        try out.print(allocator, "updated {s}: {s}\n", .{ scopeName(package.scope), package.name });
    }
}

fn appendGraphDir(allocator: Allocator, io: std.Io, out: *std.ArrayList(u8), scope: []const u8, dir_path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml") and !std.mem.endsWith(u8, entry.name, ".yml")) continue;
        try out.print(allocator, "{s}: {s}/{s}\n", .{ scope, dir_path, entry.name });
    }
}

fn appendAssets(allocator: Allocator, out: *std.ArrayList(u8), label: []const u8, assets: []const Asset) !void {
    if (assets.len == 0) return;
    try out.print(allocator, "{s}:\n", .{label});
    for (assets) |item| try out.print(allocator, "  {s}: {s}\n", .{ item.id, item.path });
}

fn appendTools(allocator: Allocator, out: *std.ArrayList(u8), tools: []const Tool) !void {
    if (tools.len == 0) return;
    try out.appendSlice(allocator, "tools:\n");
    for (tools) |tool| try out.print(allocator, "  {s}: {s}\n", .{ tool.name, @tagName(tool.handler) });
}

fn appendScripts(allocator: Allocator, out: *std.ArrayList(u8), scripts: []const Script) !void {
    if (scripts.len == 0) return;
    try out.appendSlice(allocator, "scripts:\n");
    for (scripts) |script| try out.print(allocator, "  {s}: {s}\n", .{ script.name, script.command });
}

fn assetsFor(manifest: Manifest, kind: AssetKind) []const Asset {
    return switch (kind) {
        .graphs => manifest.graphs,
        .prompts => manifest.prompts,
        .files => manifest.files,
    };
}

fn freeAssets(allocator: Allocator, assets: []Asset) void {
    for (assets) |item| item.deinit(allocator);
    allocator.free(assets);
}

fn freeTools(allocator: Allocator, tools: []Tool) void {
    for (tools) |tool| tool.deinit(allocator);
    allocator.free(tools);
}

fn freeScripts(allocator: Allocator, scripts: []Script) void {
    for (scripts) |script| script.deinit(allocator);
    allocator.free(scripts);
}

fn valueAt(value: *const circuitry.value.Value, path: []const []const u8) ?*const circuitry.value.Value {
    var v = value;
    for (path) |part| v = circuitry.value.objectGet(v, part) orelse return null;
    return v;
}

fn scalarAt(value: *const circuitry.value.Value, path: []const []const u8) ?[]const u8 {
    return scalarText(valueAt(value, path) orelse return null);
}

fn scalarText(value: *const circuitry.value.Value) ?[]const u8 {
    return if (value.* == .string) value.string else null;
}

fn boolAt(value: *const circuitry.value.Value, path: []const []const u8) ?bool {
    const found = valueAt(value, path) orelse return null;
    return if (found.* == .boolean) found.boolean else null;
}

fn stringListContains(items: []const []u8, needle: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn appendString(allocator: Allocator, items: []const []u8, value: []const u8) ![][]u8 {
    var out = try allocator.alloc([]u8, items.len + 1);
    errdefer allocator.free(out);
    for (items, 0..) |item, i| out[i] = item;
    out[items.len] = try allocator.dupe(u8, value);
    return out;
}

fn removeString(allocator: Allocator, items: []const []u8, value: []const u8) ![][]u8 {
    var count: usize = 0;
    for (items) |item| {
        if (!std.mem.eql(u8, item, value)) count += 1;
    }
    var out = try allocator.alloc([]u8, count);
    var i: usize = 0;
    for (items) |item| if (!std.mem.eql(u8, item, value)) {
        out[i] = try allocator.dupe(u8, item);
        i += 1;
    };
    return out;
}

fn freeStringList(allocator: Allocator, items: []const []u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn scopeName(scope: Scope) []const u8 {
    return switch (scope) {
        .local => "local",
        .global => "global",
    };
}

fn tempPath(allocator: Allocator, io: std.Io, prefix: []const u8) ![]u8 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    return std.fmt.allocPrint(allocator, ".zinc/tmp/{s}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ prefix, bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7] });
}

fn portableAtom(raw: []const u8) bool {
    if (raw.len == 0 or std.mem.eql(u8, raw, ".") or std.mem.eql(u8, raw, "..")) return false;
    if (platform.path.hasPathSeparator(raw) or platform.path.isAbsolute(.windows, raw)) return false;
    for (raw) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    return true;
}

fn portableRelativePath(raw: []const u8) bool {
    if (raw.len == 0 or std.fs.path.isAbsolute(raw) or platform.path.isAbsolute(.windows, raw)) return false;
    var it = std.mem.tokenizeAny(u8, raw, "/\\");
    var parts: usize = 0;
    while (it.next()) |part| {
        if (!portableAtom(part)) return false;
        parts += 1;
    }
    return parts != 0;
}

fn copyTree(allocator: Allocator, io: std.Io, source: []const u8, destination: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true }) catch return error.PackageSourceNotDirectory;
    defer dir.close(io);
    try files.mkdirP(destination);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        const source_path = try std.fs.path.join(allocator, &.{ source, entry.name });
        defer allocator.free(source_path);
        const dest_path = try std.fs.path.join(allocator, &.{ destination, entry.name });
        defer allocator.free(dest_path);
        switch (entry.kind) {
            .file => try std.Io.Dir.copyFile(std.Io.Dir.cwd(), source_path, std.Io.Dir.cwd(), dest_path, io, .{ .make_path = true, .replace = true }),
            .directory => try copyTree(allocator, io, source_path, dest_path),
            else => return error.UnsupportedPackageEntry,
        }
    }
}

fn removePath(io: std.Io, path: []const u8) !void {
    var dir = std.Io.Dir.cwd();
    try dir.deleteTree(io, path);
}

fn cleanupPath(io: std.Io, path: []const u8) void {
    if (std.mem.startsWith(u8, path, ".zinc/tmp/zinc-pkg-")) removePath(io, path) catch {};
}

fn run(allocator: Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("command failed: {s}\n{s}\n", .{ argv[0], result.stderr });
        return error.PackageCommandFailed;
    }
}
