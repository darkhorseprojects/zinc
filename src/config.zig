const std = @import("std");
const files = @import("files.zig");
const graph = @import("graph.zig");
const layout = @import("layout.zig");

const Allocator = std.mem.Allocator;

const default_provider_base_url = "http://127.0.0.1:30000/v1";
const default_max_retries = 5;

pub const RuntimeConfig = struct {
    provider_base_url: []u8,
    max_retries: usize,

    pub fn deinit(self: RuntimeConfig, allocator: Allocator) void {
        allocator.free(self.provider_base_url);
    }
};

pub const RuntimePaths = struct {
    graph: []u8,
    compiled_plan: []u8,

    pub fn deinit(self: RuntimePaths, allocator: Allocator) void {
        allocator.free(self.graph);
        allocator.free(self.compiled_plan);
    }
};

pub fn loadRuntimeConfig(allocator: Allocator, home: []const u8) !RuntimeConfig {
    return .{
        .provider_base_url = try readStringDefault(allocator, home, "provider_base_url", default_provider_base_url),
        .max_retries = try readUsizeDefault(allocator, home, "max_retries", default_max_retries),
    };
}

pub fn loadRuntimePaths(allocator: Allocator, home: []const u8) !RuntimePaths {
    var paths = RuntimePaths{
        .graph = try layout.sharePath(allocator, home, "graphs/zinc-loop.circuitry.yaml"),
        .compiled_plan = try layout.sharePath(allocator, home, "compiled/plan.json"),
    };
    errdefer paths.deinit(allocator);

    const global_config = try layout.configPath(allocator, home);
    defer allocator.free(global_config);
    try applyPathConfig(allocator, &paths, global_config);
    if (files.exists("graphs/zinc-loop.circuitry.yaml")) |_| {
        allocator.free(paths.graph);
        allocator.free(paths.compiled_plan);
        paths.graph = try allocator.dupe(u8, "graphs/zinc-loop.circuitry.yaml");
        paths.compiled_plan = try allocator.dupe(u8, ".zinc/compiled/plan.json");
    } else |_| {}
    try applyPathConfig(allocator, &paths, "zinc.toml");
    try applyPathConfig(allocator, &paths, ".zinc/config.toml");
    return paths;
}

fn applyPathConfig(allocator: Allocator, paths: *RuntimePaths, config_path: []const u8) !void {
    if (try readScalarPath(allocator, config_path, "graph")) |value| {
        allocator.free(paths.graph);
        paths.graph = value;
    }
    if (try readScalarPath(allocator, config_path, "compiled_plan")) |value| {
        allocator.free(paths.compiled_plan);
        paths.compiled_plan = value;
    }
}

pub fn resolveConfiguredModelId(allocator: Allocator, home: []const u8) ![]u8 {
    const runtime_paths = try loadRuntimePaths(allocator, home);
    defer runtime_paths.deinit(allocator);
    const graph_text = try files.readLimited(allocator, runtime_paths.graph, 1024 * 1024);
    defer allocator.free(graph_text);
    return resolveGraphModelId(allocator, graph_text, home);
}

pub fn readPromptPack(allocator: Allocator, home: []const u8, name: []const u8) ![]u8 {
    const local = try std.fmt.allocPrint(allocator, "prompts/{s}", .{name});
    defer allocator.free(local);
    if (files.readLimited(allocator, local, 128 * 1024)) |text| return text else |_| {}
    const installed_tail = try std.fmt.allocPrint(allocator, "prompts/{s}", .{name});
    defer allocator.free(installed_tail);
    const installed = try layout.sharePath(allocator, home, installed_tail);
    defer allocator.free(installed);
    return files.readLimited(allocator, installed, 128 * 1024);
}

pub fn resolveGraphModelId(allocator: Allocator, graph_text: []const u8, home: []const u8) ![]u8 {
    const agent_model = graph.readScalar(allocator, graph_text, "    model:") catch null;
    if (agent_model) |model| {
        if (!std.mem.eql(u8, model, "inherit")) return model;
        allocator.free(model);
    }

    const runtime_model = graph.readScalar(allocator, graph_text, "  model:") catch null;
    if (runtime_model) |model| {
        if (!std.mem.eql(u8, model, "inherit")) return model;
        allocator.free(model);
    }

    return readConfigScalar(allocator, home, "default_model") catch error.UnknownModel;
}

pub fn readModelValue(allocator: Allocator, home: []const u8, model_id: []const u8, key: []const u8) ![]u8 {
    if (try readModelPath(allocator, ".zinc/config.toml", model_id, key)) |value| return value;
    if (try readModelPath(allocator, "zinc.toml", model_id, key)) |value| return value;
    const global_config = try layout.configPath(allocator, home);
    defer allocator.free(global_config);
    if (try readModelPath(allocator, global_config, model_id, key)) |value| return value;
    return error.ModelConfigKeyNotFound;
}

pub fn readStringDefault(allocator: Allocator, home: []const u8, key: []const u8, default_value: []const u8) ![]u8 {
    return readConfigScalar(allocator, home, key) catch |err| switch (err) {
        error.ConfigKeyNotFound => try allocator.dupe(u8, default_value),
        else => err,
    };
}

pub fn readUsizeDefault(allocator: Allocator, home: []const u8, key: []const u8, default_value: usize) !usize {
    const raw = readConfigScalar(allocator, home, key) catch |err| switch (err) {
        error.ConfigKeyNotFound => return default_value,
        else => return err,
    };
    defer allocator.free(raw);
    return std.fmt.parseInt(usize, raw, 10) catch error.InvalidConfigValue;
}

fn readConfigScalar(allocator: Allocator, home: []const u8, key: []const u8) ![]u8 {
    if (try readScalarPath(allocator, ".zinc/config.toml", key)) |value| return value;
    if (try readScalarPath(allocator, "zinc.toml", key)) |value| return value;
    const global_config = try layout.configPath(allocator, home);
    defer allocator.free(global_config);
    if (try readScalarPath(allocator, global_config, key)) |value| return value;
    return error.ConfigKeyNotFound;
}

fn readScalarPath(allocator: Allocator, path: []const u8, key: []const u8) !?[]u8 {
    const text = files.readLimited(allocator, path, 64 * 1024) catch return null;
    defer allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const lhs = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, lhs, key)) continue;
        var rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (rhs.len >= 2 and rhs[0] == '"' and rhs[rhs.len - 1] == '"') rhs = rhs[1 .. rhs.len - 1];
        return try allocator.dupe(u8, rhs);
    }
    return null;
}

fn readModelPath(allocator: Allocator, path: []const u8, model_id: []const u8, key: []const u8) !?[]u8 {
    const text = files.readLimited(allocator, path, 128 * 1024) catch return null;
    defer allocator.free(text);
    const section_name = try std.fmt.allocPrint(allocator, "models.{s}", .{model_id});
    defer allocator.free(section_name);
    var active = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            active = std.mem.eql(u8, line[1 .. line.len - 1], section_name);
            continue;
        }
        if (!active) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const lhs = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, lhs, key)) continue;
        var rhs = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (rhs.len >= 2 and rhs[0] == '"' and rhs[rhs.len - 1] == '"') rhs = rhs[1 .. rhs.len - 1];
        return try allocator.dupe(u8, rhs);
    }
    return null;
}

test "model config reads repo model table" {
    const alias = try readModelValue(std.testing.allocator, "/tmp/home", "gemma-heretic", "alias");
    defer std.testing.allocator.free(alias);
    try std.testing.expectEqualStrings("gemma-4-96e-a4b-heretic-tq", alias);
}
