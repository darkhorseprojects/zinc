const std = @import("std");
const files = @import("../sys/fs.zig");
const graph = @import("../core/graph.zig");
const layout = @import("../sys/layout.zig");

const Allocator = std.mem.Allocator;

const default_base_url = "http://127.0.0.1:30000/v1";
const default_authorization = "Bearer zinc";
const default_model_id = "qwen-heretic-mtp";
const default_served_model = "qwen3.6-27b-heretic-mtp-q3_k_s";

pub const RuntimePaths = struct {
    graph: []u8,
    compaction_graph: []u8,
    pub fn deinit(self: RuntimePaths, allocator: Allocator) void {
        allocator.free(self.graph);
        allocator.free(self.compaction_graph);
    }
};

pub const RuntimeSettings = struct { max_retries: usize, compaction_threshold_percent: usize, compaction_max_tokens: usize, compaction_reasoning_tokens: isize };
pub const ProviderConfig = struct {
    base_url: []u8,
    authorization: []u8,
    pub fn deinit(self: ProviderConfig, allocator: Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.authorization);
    }
};
pub const GenerationConfig = struct { temperature: f64, max_tokens: usize };
pub const ReasoningBudgets = struct {
    off: isize,
    low: isize,
    medium: isize,
    high: isize,
    extra_high: isize,
    pub fn get(self: ReasoningBudgets, name: []const u8) !isize {
        if (std.mem.eql(u8, name, "off")) return self.off;
        if (std.mem.eql(u8, name, "low")) return self.low;
        if (std.mem.eql(u8, name, "medium")) return self.medium;
        if (std.mem.eql(u8, name, "high")) return self.high;
        if (std.mem.eql(u8, name, "extra_high") or std.mem.eql(u8, name, "extra-high")) return self.extra_high;
        return error.InvalidConfigValue;
    }
};
pub const ReasoningConfig = struct {
    enabled: bool,
    effort: []u8,
    budgets: ReasoningBudgets,
    pub fn deinit(self: ReasoningConfig, allocator: Allocator) void {
        allocator.free(self.effort);
    }
};
pub const LoaderConfig = struct {
    engine: []u8,
    repo: []u8,
    ref: []u8,
    hf_repo: []u8,
    hf_file: []u8,
    mmproj_file: []u8,
    cache_type_k: []u8,
    cache_type_v: []u8,
    fit_ctx: usize,
    gpu_layers: []u8,
    draft_tokens: usize,
    reasoning_format: []u8,
    mtp: bool,
    pub fn deinit(self: LoaderConfig, allocator: Allocator) void {
        allocator.free(self.engine);
        allocator.free(self.repo);
        allocator.free(self.ref);
        allocator.free(self.hf_repo);
        allocator.free(self.hf_file);
        allocator.free(self.mmproj_file);
        allocator.free(self.cache_type_k);
        allocator.free(self.cache_type_v);
        allocator.free(self.gpu_layers);
        allocator.free(self.reasoning_format);
    }
};
pub const ReasoningRequest = struct {
    kind: []u8,
    path: []u8,
    pub fn deinit(self: ReasoningRequest, allocator: Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.path);
    }
};
pub const ReasoningMarkers = struct {
    starts: [][]u8,
    end: []u8,
    pub fn deinit(self: ReasoningMarkers, allocator: Allocator) void {
        for (self.starts) |item| allocator.free(item);
        allocator.free(self.starts);
        allocator.free(self.end);
    }
};
pub const ModelConfig = struct {
    id: []u8,
    model: []u8,
    loader: LoaderConfig,
    generation: GenerationConfig,
    reasoning: ReasoningConfig,
    reasoning_request: ?ReasoningRequest,
    reasoning_markers: ?ReasoningMarkers,
    pub fn deinit(self: ModelConfig, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.model);
        self.loader.deinit(allocator);
        self.reasoning.deinit(allocator);
        if (self.reasoning_request) |v| v.deinit(allocator);
        if (self.reasoning_markers) |v| v.deinit(allocator);
    }
};
pub const RuntimeProfile = struct {
    paths: RuntimePaths,
    runtime: RuntimeSettings,
    default_model: []u8,
    provider: ProviderConfig,
    model: ModelConfig,
    pub fn deinit(self: RuntimeProfile, allocator: Allocator) void {
        self.paths.deinit(allocator);
        allocator.free(self.default_model);
        self.provider.deinit(allocator);
        self.model.deinit(allocator);
    }
    pub fn reasoningTokens(self: RuntimeProfile, allow_with_tools: bool) !isize {
        if (!self.model.reasoning.enabled or !allow_with_tools) return 0;
        return self.model.reasoning.budgets.get(self.model.reasoning.effort);
    }
    pub fn requestTokenLimit(self: RuntimeProfile, reasoning_tokens: isize) ?usize {
        if (reasoning_tokens < 0) return null;
        return self.model.generation.max_tokens + @as(usize, @intCast(reasoning_tokens));
    }
};

const Config = struct {
    json_texts: [][]u8,
    parsed: []std.json.Parsed(std.json.Value),

    fn deinit(self: *Config, allocator: Allocator) void {
        for (self.json_texts) |text| allocator.free(text);
        allocator.free(self.json_texts);
        for (self.parsed) |*p| p.deinit();
        allocator.free(self.parsed);
    }
    fn value(self: Config, path: []const []const u8) ?std.json.Value {
        var i = self.parsed.len;
        while (i > 0) {
            i -= 1;
            if (findPath(self.parsed[i].value, path)) |v| return v;
        }
        return null;
    }
    fn string(self: Config, allocator: Allocator, path: []const []const u8, default: []const u8) ![]u8 {
        return allocator.dupe(u8, scalarText(self.value(path)) orelse default);
    }
    fn optionalString(self: Config, allocator: Allocator, path: []const []const u8) !?[]u8 {
        const raw = scalarText(self.value(path)) orelse return null;
        return try allocator.dupe(u8, raw);
    }
    fn usizeValue(self: Config, path: []const []const u8, default: usize) !usize {
        const found = self.value(path) orelse return default;
        switch (found) {
            .integer => |val| {
                if (val < 0) return error.InvalidConfigValue;
                return @intCast(val);
            },
            .string => |val| {
                return std.fmt.parseInt(usize, val, 10) catch error.InvalidConfigValue;
            },
            else => return error.InvalidConfigValue,
        }
    }
    fn isizeValue(self: Config, path: []const []const u8, default: isize) !isize {
        const found = self.value(path) orelse return default;
        switch (found) {
            .integer => |val| {
                return @intCast(val);
            },
            .string => |val| {
                return std.fmt.parseInt(isize, val, 10) catch error.InvalidConfigValue;
            },
            else => return error.InvalidConfigValue,
        }
    }
    fn f64Value(self: Config, path: []const []const u8, default: f64) !f64 {
        const found = self.value(path) orelse return default;
        switch (found) {
            .float => |val| {
                return val;
            },
            .integer => |val| {
                return @floatFromInt(val);
            },
            .string => |val| {
                return std.fmt.parseFloat(f64, val) catch error.InvalidConfigValue;
            },
            else => return error.InvalidConfigValue,
        }
    }
    fn boolValue(self: Config, path: []const []const u8, default: bool) !bool {
        const found = self.value(path) orelse return default;
        if (found == .bool) return found.bool;
        const raw = scalarText(found) orelse return error.InvalidConfigValue;
        if (std.mem.eql(u8, raw, "true")) return true;
        if (std.mem.eql(u8, raw, "false")) return false;
        return error.InvalidConfigValue;
    }
    fn stringList(self: Config, allocator: Allocator, path: []const []const u8, defaults: []const []const u8) ![][]u8 {
        const found = self.value(path) orelse return dupeList(allocator, defaults);
        if (found != .array) return error.InvalidConfigValue;
        var out = try allocator.alloc([]u8, found.array.items.len);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |item| allocator.free(item);
            allocator.free(out);
        }
        for (found.array.items, 0..) |item, i| {
            out[i] = try allocator.dupe(u8, scalarText(item) orelse return error.InvalidConfigValue);
            initialized += 1;
        }
        return out;
    }
};

pub fn loadRuntimeProfile(allocator: Allocator, io: std.Io, home: []const u8, model_override: ?[]const u8) !RuntimeProfile {
    var cfg = try loadConfig(allocator, io, home);
    defer cfg.deinit(allocator);
    const default_model = if (model_override) |id| try allocator.dupe(u8, id) else try cfg.string(allocator, &.{"default_model"}, default_model_id);
    errdefer allocator.free(default_model);
    const paths = try runtimePaths(allocator, home, cfg);
    errdefer paths.deinit(allocator);
    const runtime = RuntimeSettings{ .max_retries = try cfg.usizeValue(&.{ "runtime", "max_retries" }, 5), .compaction_threshold_percent = try cfg.usizeValue(&.{ "runtime", "compaction_threshold_percent" }, 70), .compaction_max_tokens = try cfg.usizeValue(&.{ "runtime", "compaction_max_tokens" }, 4096), .compaction_reasoning_tokens = try cfg.isizeValue(&.{ "runtime", "compaction_reasoning_tokens" }, 1024) };
    const provider = try loadProvider(allocator, cfg);
    errdefer provider.deinit(allocator);
    const model = try loadModel(allocator, cfg, default_model);
    errdefer model.deinit(allocator);
    return .{ .paths = paths, .runtime = runtime, .default_model = default_model, .provider = provider, .model = model };
}

pub fn loadRuntimePaths(allocator: Allocator, io: std.Io, home: []const u8) !RuntimePaths {
    var cfg = try loadConfig(allocator, io, home);
    defer cfg.deinit(allocator);
    return runtimePaths(allocator, home, cfg);
}

pub fn resolveConfiguredModelId(allocator: Allocator, io: std.Io, home: []const u8) ![]u8 {
    var cfg = try loadConfig(allocator, io, home);
    defer cfg.deinit(allocator);
    return cfg.string(allocator, &.{"default_model"}, default_model_id);
}

pub fn resolveGraphModelId(allocator: Allocator, io: std.Io, loaded_graph: graph.Graph, home: []const u8) ![]u8 {
    if (try graph.graphModel(allocator, loaded_graph)) |model| return model;
    return resolveConfiguredModelId(allocator, io, home);
}

pub fn readPromptPack(allocator: Allocator, home: []const u8, name: []const u8) ![]u8 {
    const local = try std.fmt.allocPrint(allocator, ".zinc/prompts/{s}", .{name});
    defer allocator.free(local);
    if (files.readLimited(allocator, local, 128 * 1024)) |text| return text else |_| {}
    const tail = try std.fmt.allocPrint(allocator, "prompts/{s}", .{name});
    defer allocator.free(tail);
    const installed = try layout.sharePath(allocator, home, tail);
    defer allocator.free(installed);
    return files.readLimited(allocator, installed, 128 * 1024);
}

pub fn configGet(allocator: Allocator, io: std.Io, home: []const u8, path: []const []const u8) ![]u8 {
    var cfg = try loadConfig(allocator, io, home);
    defer cfg.deinit(allocator);
    const value = cfg.value(path) orelse return error.ConfigKeyNotFound;
    return allocator.dupe(u8, scalarText(value) orelse return error.ConfigKeyNotFound);
}

fn loadProvider(allocator: Allocator, cfg: Config) !ProviderConfig {
    return .{ .base_url = try cfg.string(allocator, &.{ "provider", "base_url" }, default_base_url), .authorization = try cfg.string(allocator, &.{ "provider", "authorization" }, default_authorization) };
}

fn loadModel(allocator: Allocator, cfg: Config, id: []const u8) !ModelConfig {
    return .{
        .id = try allocator.dupe(u8, id),
        .model = try cfg.string(allocator, &.{ "models", id, "model" }, default_served_model),
        .loader = .{
            .engine = try cfg.string(allocator, &.{ "models", id, "loader", "engine" }, "llama.cpp"),
            .repo = try cfg.string(allocator, &.{ "models", id, "loader", "repo" }, "https://github.com/ggml-org/llama.cpp.git"),
            .ref = try cfg.string(allocator, &.{ "models", id, "loader", "ref" }, "master"),
            .hf_repo = try cfg.string(allocator, &.{ "models", id, "loader", "hf_repo" }, ""),
            .hf_file = try cfg.string(allocator, &.{ "models", id, "loader", "hf_file" }, ""),
            .mmproj_file = try cfg.string(allocator, &.{ "models", id, "loader", "mmproj_file" }, ""),
            .cache_type_k = try cfg.string(allocator, &.{ "models", id, "loader", "cache_type_k" }, "q4_0"),
            .cache_type_v = try cfg.string(allocator, &.{ "models", id, "loader", "cache_type_v" }, "q4_0"),
            .fit_ctx = try cfg.usizeValue(&.{ "models", id, "loader", "fit_ctx" }, 8192),
            .gpu_layers = try cfg.string(allocator, &.{ "models", id, "loader", "gpu_layers" }, "all"),
            .draft_tokens = try cfg.usizeValue(&.{ "models", id, "loader", "draft_tokens" }, 2),
            .reasoning_format = try cfg.string(allocator, &.{ "models", id, "loader", "reasoning_format" }, "deepseek"),
            .mtp = try cfg.boolValue(&.{ "models", id, "loader", "mtp" }, true),
        },
        .generation = .{ .temperature = try cfg.f64Value(&.{ "models", id, "generation", "temperature" }, 0.6), .max_tokens = try cfg.usizeValue(&.{ "models", id, "generation", "max_tokens" }, 1024) },
        .reasoning = .{
            .enabled = try cfg.boolValue(&.{ "models", id, "reasoning", "enabled" }, true),
            .effort = try cfg.string(allocator, &.{ "models", id, "reasoning", "effort" }, "low"),
            .budgets = .{
                .off = try cfg.isizeValue(&.{ "models", id, "reasoning", "budgets", "off" }, 0),
                .low = try cfg.isizeValue(&.{ "models", id, "reasoning", "budgets", "low" }, 256),
                .medium = try cfg.isizeValue(&.{ "models", id, "reasoning", "budgets", "medium" }, 1024),
                .high = try cfg.isizeValue(&.{ "models", id, "reasoning", "budgets", "high" }, 4096),
                .extra_high = try cfg.isizeValue(&.{ "models", id, "reasoning", "budgets", "extra_high" }, -1),
            },
        },
        .reasoning_request = try reasoningRequest(allocator, cfg, id),
        .reasoning_markers = try reasoningMarkers(allocator, cfg, id),
    };
}

fn runtimePaths(allocator: Allocator, home: []const u8, cfg: Config) !RuntimePaths {
    var paths = RuntimePaths{ .graph = try allocator.dupe(u8, "stock/graphs/zinc-loop.circuitry.yaml"), .compaction_graph = try allocator.dupe(u8, "stock/graphs/zinc-compaction.circuitry.yaml") };
    errdefer paths.deinit(allocator);

    // Check for user-local overrides in .zinc/
    if (files.existsPath(".zinc/graphs/zinc-loop.circuitry.yaml")) {
        allocator.free(paths.graph);
        paths.graph = try allocator.dupe(u8, ".zinc/graphs/zinc-loop.circuitry.yaml");
    }
    if (files.existsPath(".zinc/graphs/zinc-compaction.circuitry.yaml")) {
        allocator.free(paths.compaction_graph);
        paths.compaction_graph = try allocator.dupe(u8, ".zinc/graphs/zinc-compaction.circuitry.yaml");
    }

    if (try cfg.optionalString(allocator, &.{ "paths", "graph" })) |v| {
        allocator.free(paths.graph);
        paths.graph = try expandHome(allocator, home, v);
        allocator.free(v);
    }
    if (try cfg.optionalString(allocator, &.{ "paths", "compaction_graph" })) |v| {
        allocator.free(paths.compaction_graph);
        paths.compaction_graph = try expandHome(allocator, home, v);
        allocator.free(v);
    }
    return paths;
}

fn reasoningRequest(allocator: Allocator, cfg: Config, id: []const u8) !?ReasoningRequest {
    const kind = try cfg.optionalString(allocator, &.{ "models", id, "protocol", "reasoning", "request", "kind" }) orelse return null;
    errdefer allocator.free(kind);
    return .{ .kind = kind, .path = try cfg.string(allocator, &.{ "models", id, "protocol", "reasoning", "request", "path" }, "enable_thinking") };
}

fn reasoningMarkers(allocator: Allocator, cfg: Config, id: []const u8) !?ReasoningMarkers {
    const end = try cfg.optionalString(allocator, &.{ "models", id, "protocol", "reasoning", "content_markers", "end" }) orelse return null;
    errdefer allocator.free(end);
    return .{ .starts = try cfg.stringList(allocator, &.{ "models", id, "protocol", "reasoning", "content_markers", "starts" }, &.{}), .end = end };
}

fn loadConfig(allocator: Allocator, io: std.Io, home: []const u8) !Config {
    var json_texts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (json_texts.items) |text| allocator.free(text);
        json_texts.deinit(allocator);
    }
    var parsed: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;
    errdefer {
        for (parsed.items) |*p| p.deinit();
        parsed.deinit(allocator);
    }

    const global = try layout.configPath(allocator, home);
    defer allocator.free(global);
    try loadConfigValue(allocator, io, global, &json_texts, &parsed);
    try loadConfigValue(allocator, io, ".zinc/config.yaml", &json_texts, &parsed);
    return .{ .json_texts = try json_texts.toOwnedSlice(allocator), .parsed = try parsed.toOwnedSlice(allocator) };
}

fn loadConfigValue(allocator: Allocator, io: std.Io, path: []const u8, json_texts: *std.ArrayList([]u8), parsed: *std.ArrayList(std.json.Parsed(std.json.Value))) !void {
    if (!files.existsPath(path)) return;

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

    var p = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    errdefer p.deinit();
    try json_texts.append(allocator, try allocator.dupe(u8, json));
    try parsed.append(allocator, p);
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
        std.debug.print("circuitry YAML parse failed for config:\n{s}\n", .{result.stderr});
        return error.CircuitryParseFailed;
    }
    return allocator.dupe(u8, result.stdout);
}

fn findPath(root: std.json.Value, path: []const []const u8) ?std.json.Value {
    var value = root;
    for (path) |part| {
        if (value != .object) return null;
        value = value.object.get(part) orelse return null;
    }
    return value;
}

fn scalarText(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

fn dupeList(allocator: Allocator, defaults: []const []const u8) ![][]u8 {
    var out = try allocator.alloc([]u8, defaults.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (defaults, 0..) |item, i| {
        out[i] = try allocator.dupe(u8, item);
        initialized += 1;
    }
    return out;
}

fn expandHome(allocator: Allocator, home: []const u8, value: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, value, "~/")) return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, value[2..] });
    return allocator.dupe(u8, value);
}
