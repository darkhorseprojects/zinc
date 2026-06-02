const std = @import("std");
const files = @import("../sys/fs.zig");
const graph = @import("../core/graph.zig");
const packages = @import("../core/packages.zig");
const layout = @import("../sys/layout.zig");
const circuitry = @import("circuitry");

const Allocator = std.mem.Allocator;

const default_base_url = "http://127.0.0.1:30000/v1";
const default_provider_id = "local";
const default_provider_kind = "local";
const default_authorization = "Bearer zinc";
const openai_base_url = "https://api.openai.com/v1";
const default_model_id = "qwen-heretic-mtp";
const default_served_model = "qwen3.6-27b-heretic-mtp-q3_k_s";
const default_confirm_commands = &.{ "rm", "rmdir", "sudo", "su", "chmod", "chown", "dd", "mkfs", "mount", "umount", "kill", "pkill", "shutdown", "reboot" };

var process_env: ?*std.process.Environ.Map = null;

pub fn setEnvironmentMap(env: *std.process.Environ.Map) void {
    process_env = env;
}

pub fn envPresent(name: []const u8) bool {
    const env = process_env orelse return false;
    return env.get(name) != null;
}

pub const RuntimePaths = struct {
    graph: []u8,
    context_graph: []u8,
    compaction_graph: []u8,
    pub fn deinit(self: RuntimePaths, allocator: Allocator) void {
        allocator.free(self.graph);
        allocator.free(self.context_graph);
        allocator.free(self.compaction_graph);
    }
};

pub const Scope = enum { readonly, project, open };
pub const BashMode = enum { inspect, build, open };

pub const RuntimeSettings = struct {
    scope: Scope,
    bash_mode: BashMode,
    confirm_commands: [][]u8,
    provider_max_retries: usize,
    tool_max_turns: usize,
    compaction_threshold_percent: usize,
    compaction_max_tokens: usize,
    session_head_messages: usize,
    session_tail_messages: usize,
    replay_truncate_chars: usize,
    bash_output_max_bytes: usize,
    bash_output_max_lines: usize,
    bash_capture_max_bytes: usize,
    file_read_max_bytes: usize,
    file_range_read_max_bytes: usize,
    file_edit_max_bytes: usize,
    resource_read_max_bytes: usize,
    input_text_file_max_bytes: usize,
    input_file_max_bytes: usize,
    graph_runs: []u8,

    pub fn deinit(self: RuntimeSettings, allocator: Allocator) void {
        for (self.confirm_commands) |command| allocator.free(command);
        allocator.free(self.confirm_commands);
        allocator.free(self.graph_runs);
    }
};
pub const ProviderKind = enum { local, openai, openai_compatible };

pub const ProviderConfig = struct {
    id: []u8,
    kind: ProviderKind,
    model: []u8,
    base_url: []u8,
    api_key_env: ?[]u8,
    authorization: ?[]u8,
    pub fn deinit(self: ProviderConfig, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.model);
        allocator.free(self.base_url);
        if (self.api_key_env) |value| allocator.free(value);
        if (self.authorization) |value| allocator.free(value);
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
        self.runtime.deinit(allocator);
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
    const runtime = RuntimeSettings{
        .scope = try parseScope(cfg.value(&.{"scope"})),
        .bash_mode = try parseBashMode(cfg.value(&.{ "tools", "bash" })),
        .confirm_commands = try cfg.stringList(allocator, &.{"confirm_commands"}, default_confirm_commands),
        .provider_max_retries = try cfg.usizeValue(&.{ "runtime", "provider_max_retries" }, 5),
        .tool_max_turns = try cfg.usizeValue(&.{ "runtime", "tool_max_turns" }, 12),
        .compaction_threshold_percent = try cfg.usizeValue(&.{ "runtime", "compaction_threshold_percent" }, 70),
        .compaction_max_tokens = try cfg.usizeValue(&.{ "runtime", "compaction_max_tokens" }, 4096),
        .session_head_messages = try cfg.usizeValue(&.{ "runtime", "session_head_messages" }, 6),
        .session_tail_messages = try cfg.usizeValue(&.{ "runtime", "session_tail_messages" }, 12),
        .replay_truncate_chars = try cfg.usizeValue(&.{ "runtime", "replay_truncate_chars" }, 2048),
        .bash_output_max_bytes = try cfg.usizeValue(&.{ "runtime", "bash_output_max_bytes" }, 50 * 1024),
        .bash_output_max_lines = try cfg.usizeValue(&.{ "runtime", "bash_output_max_lines" }, 2000),
        .bash_capture_max_bytes = try cfg.usizeValue(&.{ "runtime", "bash_capture_max_bytes" }, 64 * 1024 * 1024),
        .file_read_max_bytes = try cfg.usizeValue(&.{ "runtime", "file_read_max_bytes" }, 1024 * 1024),
        .file_range_read_max_bytes = try cfg.usizeValue(&.{ "runtime", "file_range_read_max_bytes" }, 8 * 1024 * 1024),
        .file_edit_max_bytes = try cfg.usizeValue(&.{ "runtime", "file_edit_max_bytes" }, 8 * 1024 * 1024),
        .resource_read_max_bytes = try cfg.usizeValue(&.{ "runtime", "resource_read_max_bytes" }, 32 * 1024 * 1024),
        .input_text_file_max_bytes = try cfg.usizeValue(&.{ "runtime", "input_text_file_max_bytes" }, 8 * 1024 * 1024),
        .input_file_max_bytes = try cfg.usizeValue(&.{ "runtime", "input_file_max_bytes" }, 32 * 1024 * 1024),
        .graph_runs = try cfg.string(allocator, &.{ "tools", "graph_runs" }, "ask"),
    };
    var provider = try loadProvider(allocator, cfg, default_model);
    errdefer provider.deinit(allocator);
    var model = try loadModel(allocator, cfg, default_model);
    errdefer model.deinit(allocator);
    if (provider.model.len != 0) {
        allocator.free(model.model);
        model.model = try allocator.dupe(u8, provider.model);
    }
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

pub fn resolveGraphModelId(allocator: Allocator, io: std.Io, loaded_graph: graph.Graph, selected_export: ?[]const u8, home: []const u8) ![]u8 {
    if (try graph.graphModel(allocator, loaded_graph, selected_export)) |model| return model;
    return resolveConfiguredModelId(allocator, io, home);
}

pub fn readPromptPack(allocator: Allocator, io: std.Io, home: []const u8, name: []const u8) ![]u8 {
    const local = try promptPath(allocator, ".zinc/prompts", name);
    defer allocator.free(local);
    if (files.readLimited(allocator, local, 128 * 1024)) |text| return text else |_| {}

    if (packages.resolvePrompt(allocator, io, home, name)) |path| {
        defer allocator.free(path);
        return files.readLimited(allocator, path, 128 * 1024);
    } else |_| {}

    const share_prompt = try promptPath(allocator, "prompts", name);
    defer allocator.free(share_prompt);
    const installed = try layout.sharePath(allocator, home, share_prompt);
    defer allocator.free(installed);
    return files.readLimited(allocator, installed, 128 * 1024);
}

fn promptPath(allocator: Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, name, ".md")) return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    return std.fmt.allocPrint(allocator, "{s}/{s}.md", .{ dir, name });
}

pub fn configGet(allocator: Allocator, io: std.Io, home: []const u8, path: []const []const u8) ![]u8 {
    var cfg = try loadConfig(allocator, io, home);
    defer cfg.deinit(allocator);
    const value = cfg.value(path) orelse return error.ConfigKeyNotFound;
    return allocator.dupe(u8, scalarText(value) orelse return error.ConfigKeyNotFound);
}

fn parseScope(value: ?std.json.Value) !Scope {
    const raw = scalarText(value) orelse return .project;
    if (std.mem.eql(u8, raw, "readonly")) return .readonly;
    if (std.mem.eql(u8, raw, "project")) return .project;
    if (std.mem.eql(u8, raw, "open")) return .open;
    return error.InvalidConfigValue;
}

fn parseBashMode(value: ?std.json.Value) !BashMode {
    const raw = scalarText(value) orelse return .build;
    if (std.mem.eql(u8, raw, "inspect")) return .inspect;
    if (std.mem.eql(u8, raw, "build")) return .build;
    if (std.mem.eql(u8, raw, "open")) return .open;
    return error.InvalidConfigValue;
}

fn loadProvider(allocator: Allocator, cfg: Config, model_id: []const u8) !ProviderConfig {
    const provider_id = try selectedProviderId(allocator, cfg, model_id);
    errdefer allocator.free(provider_id);
    const kind_text = try providerFieldString(allocator, cfg, provider_id, "kind", if (std.mem.eql(u8, provider_id, "openai")) "openai" else default_provider_kind);
    defer allocator.free(kind_text);
    const kind = try parseProviderKind(kind_text);
    const raw_model = if (try cfg.optionalString(allocator, &.{ "model_bindings", model_id, "model" })) |binding_model| binding_model else try providerFieldString(allocator, cfg, provider_id, "model", "");
    errdefer allocator.free(raw_model);
    const raw_base = switch (kind) {
        .openai => try providerFieldString(allocator, cfg, provider_id, "base_url", openai_base_url),
        .local => try providerFieldString(allocator, cfg, provider_id, "base_url", default_base_url),
        .openai_compatible => try requiredProviderFieldString(allocator, cfg, provider_id, "base_url"),
    };
    defer allocator.free(raw_base);
    const base_url = try normalizeBaseUrl(allocator, raw_base);
    errdefer allocator.free(base_url);
    const api_key_env = try optionalProviderFieldString(allocator, cfg, provider_id, "api_key_env");
    errdefer if (api_key_env) |value| allocator.free(value);
    const authorization = try providerAuthorization(allocator, cfg, provider_id, kind, api_key_env);
    errdefer if (authorization) |value| allocator.free(value);
    return .{ .id = provider_id, .kind = kind, .model = raw_model, .base_url = base_url, .api_key_env = api_key_env, .authorization = authorization };
}

fn selectedProviderId(allocator: Allocator, cfg: Config, model_id: []const u8) ![]u8 {
    if (try cfg.optionalString(allocator, &.{ "model_bindings", model_id, "provider" })) |provider| return provider;
    if (try cfg.optionalString(allocator, &.{ "providers", "default" })) |provider| return provider;
    if (cfg.value(&.{"providers"}) != null) return allocator.dupe(u8, default_provider_id);
    return allocator.dupe(u8, default_provider_id);
}

fn providerFieldString(allocator: Allocator, cfg: Config, provider_id: []const u8, field: []const u8, default: []const u8) ![]u8 {
    if (try cfg.optionalString(allocator, &.{ "providers", provider_id, field })) |value| return value;
    if (try cfg.optionalString(allocator, &.{ "provider", field })) |value| return value;
    return allocator.dupe(u8, default);
}

fn requiredProviderFieldString(allocator: Allocator, cfg: Config, provider_id: []const u8, field: []const u8) ![]u8 {
    if (try optionalProviderFieldString(allocator, cfg, provider_id, field)) |value| return value;
    std.debug.print("Provider {s} is kind openai_compatible but has no {s}.\n", .{ provider_id, field });
    return error.InvalidConfigValue;
}

fn optionalProviderFieldString(allocator: Allocator, cfg: Config, provider_id: []const u8, field: []const u8) !?[]u8 {
    if (try cfg.optionalString(allocator, &.{ "providers", provider_id, field })) |value| return value;
    if (try cfg.optionalString(allocator, &.{ "provider", field })) |value| return value;
    return null;
}

fn providerAuthorization(allocator: Allocator, cfg: Config, provider_id: []const u8, kind: ProviderKind, api_key_env: ?[]const u8) !?[]u8 {
    if (api_key_env) |env_name| {
        const secret = envValue(allocator, env_name) catch |err| switch (err) {
            error.EnvironmentVariableMissing => {
                if (kind == .openai) {
                    std.debug.print("Provider {s} is missing API key.\n\nExpected environment variable:\n  {s}\n\nFix:\n  export {s}=...\n", .{ provider_id, env_name, env_name });
                    return error.MissingProviderApiKey;
                }
                return null;
            },
            else => return err,
        };
        defer allocator.free(secret);
        const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{secret});
        return authorization;
    }
    if (kind == .openai) {
        std.debug.print("Provider {s} is missing API key.\n\nExpected environment variable:\n  OPENAI_API_KEY\n\nFix:\n  export OPENAI_API_KEY=...\n", .{provider_id});
        return error.MissingProviderApiKey;
    }
    if (try cfg.optionalString(allocator, &.{ "provider", "authorization" })) |legacy| return legacy;
    if (kind == .local) {
        const authorization = try allocator.dupe(u8, default_authorization);
        return authorization;
    }
    return null;
}

fn envValue(allocator: Allocator, name: []const u8) ![]u8 {
    const env = process_env orelse return error.EnvironmentVariableMissing;
    const value = env.get(name) orelse return error.EnvironmentVariableMissing;
    return allocator.dupe(u8, value);
}

fn parseProviderKind(text: []const u8) !ProviderKind {
    if (std.mem.eql(u8, text, "local")) return .local;
    if (std.mem.eql(u8, text, "openai")) return .openai;
    if (std.mem.eql(u8, text, "openai_compatible")) return .openai_compatible;
    return error.InvalidConfigValue;
}

fn normalizeBaseUrl(allocator: Allocator, raw: []const u8) ![]u8 {
    var end = raw.len;
    while (end > 0 and raw[end - 1] == '/') end -= 1;
    return allocator.dupe(u8, raw[0..end]);
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
            .fit_ctx = try cfg.usizeValue(&.{ "models", id, "loader", "fit_ctx" }, 16384),
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
    var paths = RuntimePaths{
        .graph = try layout.sharePath(allocator, home, "graphs/zinc-loop.circuitry.yaml"),
        .context_graph = try layout.sharePath(allocator, home, "graphs/zinc-context-recovery.circuitry.yaml"),
        .compaction_graph = try layout.sharePath(allocator, home, "graphs/zinc-compaction.circuitry.yaml"),
    };
    errdefer paths.deinit(allocator);
    if (try cfg.optionalString(allocator, &.{ "paths", "graph" })) |v| {
        allocator.free(paths.graph);
        paths.graph = try expandHome(allocator, home, v);
        allocator.free(v);
    }
    if (try cfg.optionalString(allocator, &.{ "paths", "context_graph" })) |v| {
        allocator.free(paths.context_graph);
        paths.context_graph = try expandHome(allocator, home, v);
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

    var document = try circuitry.loadYamlFile(allocator, io, path);
    defer document.deinit();
    const json = try circuitry.value.writeJsonLike(allocator, &document.root);
    defer allocator.free(json);

    var p = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    errdefer p.deinit();
    try json_texts.append(allocator, try allocator.dupe(u8, json));
    try parsed.append(allocator, p);
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
