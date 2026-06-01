const std = @import("std");
const files = @import("../sys/fs.zig");
const layout = @import("../sys/layout.zig");

const Allocator = std.mem.Allocator;

const meta_file = ".zinc-package.json";

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

const ExportKind = enum { graphs, prompts, assets };

const Export = struct {
    id: []u8,
    path: []u8,

    fn deinit(self: Export, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
    }
};

const Manifest = struct {
    name: []u8,
    version: []u8,
    description: []u8,
    graphs: []Export,
    prompts: []Export,
    assets: []Export,

    fn deinit(self: Manifest, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        freeExports(allocator, self.graphs);
        freeExports(allocator, self.prompts);
        freeExports(allocator, self.assets);
    }
};

pub fn add(allocator: Allocator, io: std.Io, home: []const u8, source_text: []const u8, options: InstallOptions) !PackageRef {
    var source = try parseSource(allocator, source_text);
    defer source.deinit(allocator);
    const staging = try stageSource(allocator, io, source);
    defer cleanupPath(io, staging);
    defer allocator.free(staging);
    return installStaged(allocator, io, home, source, staging, source_text, options);
}

pub fn previewAdd(allocator: Allocator, io: std.Io, home: []const u8, source_text: []const u8, options: InstallOptions) !PackagePlan {
    var source = try parseSource(allocator, source_text);
    defer source.deinit(allocator);
    const staging = try stageSource(allocator, io, source);
    errdefer {
        cleanupPath(io, staging);
        allocator.free(staging);
    }
    const text = try packagePlanText(allocator, io, home, source, staging, source_text, options, null);
    return .{ .text = text, .staging = staging };
}

pub fn installPreviewed(allocator: Allocator, io: std.Io, home: []const u8, plan: PackagePlan, source_text: []const u8, options: InstallOptions) !PackageRef {
    var source = try parseSource(allocator, source_text);
    defer source.deinit(allocator);
    return installStaged(allocator, io, home, source, plan.staging, source_text, options);
}

pub fn previewUpdate(allocator: Allocator, io: std.Io, home: []const u8, name: []const u8, scope: ?Scope) !PackagePlan {
    var found = try findInstalled(allocator, home, name, scope);
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
    const text = try packagePlanText(allocator, io, home, source, staging, source_text, .{ .scope = found.scope, .replace = true }, found.path);
    return .{ .text = text, .staging = staging };
}

fn installStaged(allocator: Allocator, io: std.Io, home: []const u8, source: Source, staging: []const u8, source_text: []const u8, options: InstallOptions) !PackageRef {
    const package_dir = try sourcePackageDir(allocator, staging, source.subdir);
    defer allocator.free(package_dir);
    const manifest = try loadManifest(allocator, io, package_dir);
    defer manifest.deinit(allocator);

    const root = try scopeRoot(allocator, home, options.scope);
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

pub fn remove(allocator: Allocator, io: std.Io, home: []const u8, name: []const u8, scope: ?Scope) !PackageRef {
    const found = try findInstalled(allocator, home, name, scope);
    errdefer found.deinit(allocator);
    try removePath(io, found.path);
    return found;
}

pub fn update(allocator: Allocator, io: std.Io, home: []const u8, name: []const u8, scope: ?Scope) !PackageRef {
    var found = try findInstalled(allocator, home, name, scope);
    defer found.deinit(allocator);
    const source = try readMetadataSource(allocator, found.path);
    defer allocator.free(source);
    return add(allocator, io, home, source, .{ .scope = found.scope, .replace = true });
}

pub fn updateAll(allocator: Allocator, io: std.Io, home: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try updatePackagesInRoot(allocator, io, home, &out, .local, ".zinc/packages");
    const global = try scopeRoot(allocator, home, .global);
    defer allocator.free(global);
    try updatePackagesInRoot(allocator, io, home, &out, .global, global);
    return out.toOwnedSlice(allocator);
}

pub fn show(allocator: Allocator, io: std.Io, home: []const u8, name: []const u8, scope: ?Scope) ![]u8 {
    const found = try findInstalled(allocator, home, name, scope);
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
    try appendExports(allocator, &out, "graphs", manifest.graphs);
    try appendExports(allocator, &out, "prompts", manifest.prompts);
    try appendExports(allocator, &out, "assets", manifest.assets);
    return out.toOwnedSlice(allocator);
}

fn packagePlanText(allocator: Allocator, io: std.Io, home: []const u8, source: Source, staging: []const u8, source_text: []const u8, options: InstallOptions, current_path: ?[]const u8) ![]u8 {
    const package_dir = try sourcePackageDir(allocator, staging, source.subdir);
    defer allocator.free(package_dir);
    const manifest = try loadManifest(allocator, io, package_dir);
    defer manifest.deinit(allocator);
    const root = try scopeRoot(allocator, home, options.scope);
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
    try appendExports(allocator, &out, "graphs", manifest.graphs);
    try appendExports(allocator, &out, "prompts", manifest.prompts);
    try appendExports(allocator, &out, "assets", manifest.assets);
    return out.toOwnedSlice(allocator);
}

pub fn listPackages(allocator: Allocator, io: std.Io, home: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendPackageNames(allocator, io, &out, .local, ".zinc/packages");
    const global = try scopeRoot(allocator, home, .global);
    defer allocator.free(global);
    try appendPackageNames(allocator, io, &out, .global, global);
    return out.toOwnedSlice(allocator);
}

pub fn listGraphs(allocator: Allocator, io: std.Io, home: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendGraphDir(allocator, io, &out, "project", "graphs");
    try appendPackageGraphExports(allocator, io, &out, .local, ".zinc/packages");
    const global = try scopeRoot(allocator, home, .global);
    defer allocator.free(global);
    try appendPackageGraphExports(allocator, io, &out, .global, global);
    const shared = try layout.sharePath(allocator, home, "graphs");
    defer allocator.free(shared);
    try appendGraphDir(allocator, io, &out, "stock", shared);
    return out.toOwnedSlice(allocator);
}

pub fn resolveGraph(allocator: Allocator, io: std.Io, home: []const u8, spec: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(spec)) return allocator.dupe(u8, spec);
    if (files.existsPath(spec)) return allocator.dupe(u8, spec);
    if (try graphInDir(allocator, "graphs", spec)) |path| return path;
    if (try graphExportInRoot(allocator, io, ".zinc/packages", spec)) |path| return path;
    const global = try scopeRoot(allocator, home, .global);
    defer allocator.free(global);
    if (try graphExportInRoot(allocator, io, global, spec)) |path| return path;
    const shared_graphs = try layout.sharePath(allocator, home, "graphs");
    defer allocator.free(shared_graphs);
    if (try graphInDir(allocator, shared_graphs, spec)) |path| return path;
    return error.GraphNotFound;
}

pub fn resolvePrompt(allocator: Allocator, io: std.Io, home: []const u8, spec: []const u8) ![]u8 {
    if (try exportInRoot(allocator, io, ".zinc/packages", spec, .prompts)) |path| return path;
    const global = try scopeRoot(allocator, home, .global);
    defer allocator.free(global);
    if (try exportInRoot(allocator, io, global, spec, .prompts)) |path| return path;
    return error.PromptNotFound;
}

pub fn resolveAsset(allocator: Allocator, io: std.Io, home: []const u8, spec: []const u8) ![]u8 {
    if (try exportInRoot(allocator, io, ".zinc/packages", spec, .assets)) |path| return path;
    const global = try scopeRoot(allocator, home, .global);
    defer allocator.free(global);
    if (try exportInRoot(allocator, io, global, spec, .assets)) |path| return path;
    return error.AssetNotFound;
}

fn stageSource(allocator: Allocator, io: std.Io, source: Source) ![]u8 {
    switch (source.kind) {
        .directory => return allocator.dupe(u8, source.url),
        .git => {
            const base = try tempPath(allocator, "zinc-pkg-");
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

    const cache_path = blk: {
        if (std.mem.endsWith(u8, path, ".yaml")) {
            break :blk try std.fmt.allocPrint(allocator, "{s}.json", .{path[0 .. path.len - ".yaml".len]});
        } else if (std.mem.endsWith(u8, path, ".yml")) {
            break :blk try std.fmt.allocPrint(allocator, "{s}.json", .{path[0 .. path.len - ".yml".len]});
        } else {
            break :blk try std.fmt.allocPrint(allocator, "{s}.json", .{path});
        }
    };
    defer allocator.free(cache_path);

    var cache_valid = false;
    if (files.existsPath(cache_path)) {
        var dir = std.Io.Dir.cwd();
        const yaml_stat = dir.statFile(io, path, .{}) catch null;
        const cache_stat = dir.statFile(io, cache_path, .{}) catch null;
        if (yaml_stat != null and cache_stat != null) {
            if (cache_stat.?.mtime.nanoseconds >= yaml_stat.?.mtime.nanoseconds) {
                cache_valid = true;
            }
        }
    }

    const json = if (cache_valid)
        try files.readLimited(allocator, cache_path, 16 * 1024 * 1024)
    else blk: {
        const fresh_json = try parseYamlFileToJSON(allocator, io, path);
        errdefer allocator.free(fresh_json);
        files.write(cache_path, fresh_json) catch {};
        break :blk fresh_json;
    };
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidPackageManifest;

    return .{
        .name = try allocator.dupe(u8, scalarAt(root, &.{"name"}) orelse return error.InvalidPackageManifest),
        .version = try allocator.dupe(u8, scalarAt(root, &.{"version"}) orelse ""),
        .description = try allocator.dupe(u8, scalarAt(root, &.{"description"}) orelse ""),
        .graphs = try readExports(allocator, root, &.{ "exports", "graphs" }),
        .prompts = try readExports(allocator, root, &.{ "exports", "prompts" }),
        .assets = try readExports(allocator, root, &.{ "exports", "assets" }),
    };
}

fn parseYamlFileToJSON(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "circuitry", "parse", path },
        .stderr_limit = .limited(64 * 1024),
        .stdout_limit = .limited(16 * 1024 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("error: 'circuitry' command not found. Please ensure circuitry is installed and in your PATH.\n", .{});
            std.debug.print("To install circuitry, run:\n  npm install -g @darkhorseprojects/circuitry\n\n", .{});
            return error.CircuitryNotFound;
        },
        else => return err,
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (result.term != .exited or result.term.exited != 0) {
        return error.PackageCommandFailed;
    }
    return allocator.dupe(u8, result.stdout);
}

fn readExports(allocator: Allocator, root: std.json.Value, path: []const []const u8) ![]Export {
    const value = valueAt(root, path) orelse return allocator.alloc(Export, 0);
    if (value != .object) return allocator.alloc(Export, 0);
    const obj = value.object;
    var out: std.ArrayList(Export) = .empty;
    errdefer {
        freeExports(allocator, out.items);
        out.deinit(allocator);
    }
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const id = entry.key_ptr.*;
        const raw_path = scalarText(entry.value_ptr.*) orelse return error.InvalidPackageManifest;
        try out.append(allocator, .{ .id = try allocator.dupe(u8, id), .path = try allocator.dupe(u8, raw_path) });
    }
    return out.toOwnedSlice(allocator);
}

fn findInstalled(allocator: Allocator, home: []const u8, name: []const u8, scope: ?Scope) !PackageRef {
    if (scope) |s| {
        if (try installedAt(allocator, home, name, s)) |ref| return ref;
        return error.PackageNotFound;
    }
    const local = try installedAt(allocator, home, name, .local);
    const global = try installedAt(allocator, home, name, .global);
    if (local != null and global != null) {
        if (local) |l| l.deinit(allocator);
        if (global) |g| g.deinit(allocator);
        return error.PackageScopeRequired;
    }
    if (local) |l| return l;
    if (global) |g| return g;
    return error.PackageNotFound;
}

fn installedAt(allocator: Allocator, home: []const u8, name: []const u8, scope: Scope) !?PackageRef {
    const root = try scopeRoot(allocator, home, scope);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, name });
    if (!files.existsPath(path)) {
        allocator.free(path);
        return null;
    }
    return .{ .name = try allocator.dupe(u8, name), .scope = scope, .path = path };
}

fn scopeRoot(allocator: Allocator, home: []const u8, scope: Scope) ![]u8 {
    return switch (scope) {
        .local => allocator.dupe(u8, ".zinc/packages"),
        .global => layout.sharePath(allocator, home, "packages"),
    };
}

fn writeMetadata(allocator: Allocator, package_dir: []const u8, source: []const u8, scope: Scope) !void {
    const path = try std.fs.path.join(allocator, &.{ package_dir, meta_file });
    defer allocator.free(path);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"source\":");
    try files.appendJsonString(allocator, &out, source);
    try out.appendSlice(allocator, ",\"scope\":");
    try files.appendJsonString(allocator, &out, scopeName(scope));
    try out.appendSlice(allocator, "}\n");
    try files.write(path, out.items);
}

fn readMetadataSource(allocator: Allocator, package_dir: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ package_dir, meta_file });
    defer allocator.free(path);
    const text = try files.readLimited(allocator, path, 16 * 1024);
    defer allocator.free(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPackageMetadata;
    const source = parsed.value.object.get("source") orelse return error.InvalidPackageMetadata;
    if (source != .string) return error.InvalidPackageMetadata;
    return allocator.dupe(u8, source.string);
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

fn graphExportInRoot(allocator: Allocator, io: std.Io, root_path: []const u8, spec: []const u8) !?[]u8 {
    return exportInRoot(allocator, io, root_path, spec, .graphs);
}

fn exportInRoot(allocator: Allocator, io: std.Io, root_path: []const u8, spec: []const u8, kind: ExportKind) !?[]u8 {
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return null;
    defer root.close(io);
    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const package_dir = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(package_dir);
        const manifest = loadManifest(allocator, io, package_dir) catch continue;
        defer manifest.deinit(allocator);
        const exports = exportsFor(manifest, kind);
        for (exports) |item| {
            if (std.mem.eql(u8, item.id, spec)) {
                const path = try std.fs.path.join(allocator, &.{ package_dir, item.path });
                return path;
            }
        }
    }
    return null;
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

fn appendPackageGraphExports(allocator: Allocator, io: std.Io, out: *std.ArrayList(u8), scope: Scope, root_path: []const u8) !void {
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

fn updatePackagesInRoot(allocator: Allocator, io: std.Io, home: []const u8, out: *std.ArrayList(u8), scope: Scope, root_path: []const u8) !void {
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
        var package = try update(allocator, io, home, name, scope);
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

fn appendExports(allocator: Allocator, out: *std.ArrayList(u8), label: []const u8, exports: []const Export) !void {
    if (exports.len == 0) return;
    try out.print(allocator, "{s}:\n", .{label});
    for (exports) |item| try out.print(allocator, "  {s}: {s}\n", .{ item.id, item.path });
}

fn exportsFor(manifest: Manifest, kind: ExportKind) []const Export {
    return switch (kind) {
        .graphs => manifest.graphs,
        .prompts => manifest.prompts,
        .assets => manifest.assets,
    };
}

fn freeExports(allocator: Allocator, exports: []Export) void {
    for (exports) |item| item.deinit(allocator);
    allocator.free(exports);
}

fn valueAt(value: std.json.Value, path: []const []const u8) ?std.json.Value {
    var v = value;
    for (path) |part| v = objectGet(v, part) orelse return null;
    return v;
}

fn objectGet(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn scalarAt(value: std.json.Value, path: []const []const u8) ?[]const u8 {
    return scalarText(valueAt(value, path) orelse return null);
}

fn scalarText(value: std.json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

fn scopeName(scope: Scope) []const u8 {
    return switch (scope) {
        .local => "local",
        .global => "global",
    };
}

fn tempPath(allocator: Allocator, prefix: []const u8) ![]u8 {
    var bytes: [8]u8 = undefined;
    const rc = std.os.linux.getrandom(&bytes, bytes.len, 0);
    const err = std.os.linux.errno(rc);
    if (err != .SUCCESS or rc != bytes.len) return error.RandomFailed;
    return std.fmt.allocPrint(allocator, "/tmp/{s}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ prefix, bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7] });
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
            .file => {
                const bytes = try files.readLimited(allocator, source_path, 128 * 1024 * 1024);
                defer allocator.free(bytes);
                try files.write(dest_path, bytes);
            },
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
    if (std.mem.startsWith(u8, path, "/tmp/zinc-pkg-")) removePath(io, path) catch {};
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
