const std = @import("std");
const files = @import("../io/fs.zig");
const graph = @import("../graph/mod.zig");
const packages = @import("../packages/mod.zig");
const layout = @import("../io/layout.zig");
const platform = @import("../platform.zig");
const circuitry = @import("circuitry");

const Allocator = std.mem.Allocator;

const default_base_url = "http://127.0.0.1:30000/v1";
const default_authorization = "Bearer zinc";
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
pub const ModelKind = enum { local, openai };

pub const ProviderConfig = struct {
    id: []u8,
    kind: ModelKind,
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
    kind: ModelKind,
    model: []u8,
    base_url: []u8,
    api_key_env: ?[]u8,
    loader: LoaderConfig,
    generation: GenerationConfig,
    reasoning: ReasoningConfig,
    reasoning_request: ?ReasoningRequest,
    reasoning_markers: ?ReasoningMarkers,
    pub fn deinit(self: ModelConfig, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.model);
        allocator.free(self.base_url);
        if (self.api_key_env) |value| allocator.free(value);
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
    documents: []circuitry.Graph,

    fn deinit(self: *Config, allocator: Allocator) void {
        for (self.documents) |*document| document.deinit();
        allocator.free(self.documents);
    }
    fn value(self: Config, path: []const []const u8) ?*const circuitry.value.Value {
        var i = self.documents.len;
        while (i > 0) {
            i -= 1;
            if (findPath(&self.documents[i].root, path)) |v| return v;
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
        switch (found.*) {
            .integer => |val| {
                if (val < 0) return error.InvalidConfigValue;
                return @intCast(val);
            },
            .string => |val| return std.fmt.parseInt(usize, val, 10) catch error.InvalidConfigValue,
            else => return error.InvalidConfigValue,
        }
    }
    fn isizeValue(self: Config, path: []const []const u8, default: isize) !isize {
        const found = self.value(path) orelse return default;
        switch (found.*) {
            .integer => |val| return @intCast(val),
            .string => |val| return std.fmt.parseInt(isize, val, 10) catch error.InvalidConfigValue,
            else => return error.InvalidConfigValue,
        }
    }
    fn f64Value(self: Config, path: []const []const u8, default: f64) !f64 {
        const found = self.value(path) orelse return default;
        switch (found.*) {
            .float => |val| return val,
            .integer => |val| return @floatFromInt(val),
            .string => |val| return std.fmt.parseFloat(f64, val) catch error.InvalidConfigValue,
            else => return error.InvalidConfigValue,
        }
    }
    fn boolValue(self: Config, path: []const []const u8, default: bool) !bool {
        const found = self.value(path) orelse return default;
        if (found.* == .boolean) return found.boolean;
        const raw = scalarText(found) orelse return error.InvalidConfigValue;
        if (std.mem.eql(u8, raw, "true")) return true;
        if (std.mem.eql(u8, raw, "false")) return false;
        return error.InvalidConfigValue;
    }
    fn stringList(self: Config, allocator: Allocator, path: []const []const u8, defaults: []const []const u8) ![][]u8 {
        const found = self.value(path) orelse return dupeList(allocator, defaults);
        if (found.* != .sequence) return error.InvalidConfigValue;
        var out = try allocator.alloc([]u8, found.sequence.len);
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |item| allocator.free(item);
            allocator.free(out);
        }
        for (found.sequence, 0..) |item, i| {
            out[i] = try allocator.dupe(u8, scalarText(&item) orelse return error.InvalidConfigValue);
            initialized += 1;
        }
        return out;
    }
};

pub fn loadRuntimeProfile(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, model_override: ?[]const u8) !RuntimeProfile {
    var cfg = try loadConfig(allocator, io, layout_ctx);
    defer cfg.deinit(allocator);
    const default_model = if (model_override) |id| try allocator.dupe(u8, id) else try cfg.string(allocator, &.{"default_model"}, default_model_id);
    errdefer allocator.free(default_model);
    const paths = try runtimePaths(allocator, layout_ctx, cfg);
    errdefer paths.deinit(allocator);
    const runtime_scope = try parseScope(cfg.value(&.{"scope"}));
    const bash_mode = try parseBashMode(cfg.value(&.{ "tools", "bash" }));
    const provider_max_retries = try cfg.usizeValue(&.{ "runtime", "provider_max_retries" }, 5);
    const tool_max_turns = try cfg.usizeValue(&.{ "runtime", "tool_max_turns" }, 12);
    const compaction_threshold_percent = try cfg.usizeValue(&.{ "runtime", "compaction_threshold_percent" }, 70);
    const compaction_max_tokens = try cfg.usizeValue(&.{ "runtime", "compaction_max_tokens" }, 4096);
    const session_head_messages = try cfg.usizeValue(&.{ "runtime", "session_head_messages" }, 6);
    const session_tail_messages = try cfg.usizeValue(&.{ "runtime", "session_tail_messages" }, 12);
    const replay_truncate_chars = try cfg.usizeValue(&.{ "runtime", "replay_truncate_chars" }, 2048);
    const bash_output_max_bytes = try cfg.usizeValue(&.{ "runtime", "bash_output_max_bytes" }, 50 * 1024);
    const bash_output_max_lines = try cfg.usizeValue(&.{ "runtime", "bash_output_max_lines" }, 2000);
    const bash_capture_max_bytes = try cfg.usizeValue(&.{ "runtime", "bash_capture_max_bytes" }, 64 * 1024 * 1024);
    const file_read_max_bytes = try cfg.usizeValue(&.{ "runtime", "file_read_max_bytes" }, 1024 * 1024);
    const file_range_read_max_bytes = try cfg.usizeValue(&.{ "runtime", "file_range_read_max_bytes" }, 8 * 1024 * 1024);
    const file_edit_max_bytes = try cfg.usizeValue(&.{ "runtime", "file_edit_max_bytes" }, 8 * 1024 * 1024);
    const resource_read_max_bytes = try cfg.usizeValue(&.{ "runtime", "resource_read_max_bytes" }, 32 * 1024 * 1024);
    const input_text_file_max_bytes = try cfg.usizeValue(&.{ "runtime", "input_text_file_max_bytes" }, 8 * 1024 * 1024);
    const input_file_max_bytes = try cfg.usizeValue(&.{ "runtime", "input_file_max_bytes" }, 32 * 1024 * 1024);
    const confirm_commands = try cfg.stringList(allocator, &.{"confirm_commands"}, default_confirm_commands);
    var confirm_commands_owned = true;
    errdefer if (confirm_commands_owned) {
        for (confirm_commands) |command| allocator.free(command);
        allocator.free(confirm_commands);
    };
    const graph_runs = try cfg.string(allocator, &.{ "tools", "graph_runs" }, "ask");
    var graph_runs_owned = true;
    errdefer if (graph_runs_owned) allocator.free(graph_runs);
    const runtime = RuntimeSettings{
        .scope = runtime_scope,
        .bash_mode = bash_mode,
        .confirm_commands = confirm_commands,
        .provider_max_retries = provider_max_retries,
        .tool_max_turns = tool_max_turns,
        .compaction_threshold_percent = compaction_threshold_percent,
        .compaction_max_tokens = compaction_max_tokens,
        .session_head_messages = session_head_messages,
        .session_tail_messages = session_tail_messages,
        .replay_truncate_chars = replay_truncate_chars,
        .bash_output_max_bytes = bash_output_max_bytes,
        .bash_output_max_lines = bash_output_max_lines,
        .bash_capture_max_bytes = bash_capture_max_bytes,
        .file_read_max_bytes = file_read_max_bytes,
        .file_range_read_max_bytes = file_range_read_max_bytes,
        .file_edit_max_bytes = file_edit_max_bytes,
        .resource_read_max_bytes = resource_read_max_bytes,
        .input_text_file_max_bytes = input_text_file_max_bytes,
        .input_file_max_bytes = input_file_max_bytes,
        .graph_runs = graph_runs,
    };
    confirm_commands_owned = false;
    graph_runs_owned = false;
    errdefer runtime.deinit(allocator);
    var model = try loadModel(allocator, cfg, default_model);
    errdefer model.deinit(allocator);
    var provider = try loadProvider(allocator, model);
    errdefer provider.deinit(allocator);
    return .{ .paths = paths, .runtime = runtime, .default_model = default_model, .provider = provider, .model = model };
}

pub fn loadRuntimePaths(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) !RuntimePaths {
    var cfg = try loadConfig(allocator, io, layout_ctx);
    defer cfg.deinit(allocator);
    return runtimePaths(allocator, layout_ctx, cfg);
}

pub fn resolveConfiguredModelId(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) ![]u8 {
    var cfg = try loadConfig(allocator, io, layout_ctx);
    defer cfg.deinit(allocator);
    return cfg.string(allocator, &.{"default_model"}, default_model_id);
}

pub fn resolveGraphModelId(allocator: Allocator, io: std.Io, loaded_graph: graph.Graph, selected_export: ?[]const u8, layout_ctx: layout.Context) ![]u8 {
    if (try graph.graphModel(allocator, loaded_graph, selected_export)) |model| return model;
    return resolveConfiguredModelId(allocator, io, layout_ctx);
}

pub fn readPromptPack(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, name: []const u8) ![]u8 {
    const local = try promptPath(allocator, ".zinc/prompts", name);
    defer allocator.free(local);
    if (files.readLimited(allocator, local, 128 * 1024)) |text| return text else |_| {}

    if (packages.resolvePrompt(allocator, io, layout_ctx, name)) |path| {
        defer allocator.free(path);
        return files.readLimited(allocator, path, 128 * 1024);
    } else |_| {}

    const share_prompt = try promptPath(allocator, "prompts", name);
    defer allocator.free(share_prompt);
    const installed = try layout.sharePath(allocator, layout_ctx, share_prompt);
    defer allocator.free(installed);
    return files.readLimited(allocator, installed, 128 * 1024);
}

fn promptPath(allocator: Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, name, ".md")) return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    return std.fmt.allocPrint(allocator, "{s}/{s}.md", .{ dir, name });
}

pub fn configGet(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, path: []const []const u8) ![]u8 {
    var cfg = try loadConfig(allocator, io, layout_ctx);
    defer cfg.deinit(allocator);
    const value = cfg.value(path) orelse return error.ConfigKeyNotFound;
    return allocator.dupe(u8, scalarText(value) orelse return error.ConfigKeyNotFound);
}

fn parseScope(value: ?*const circuitry.value.Value) !Scope {
    const raw = scalarText(value) orelse return .project;
    if (std.mem.eql(u8, raw, "readonly")) return .readonly;
    if (std.mem.eql(u8, raw, "project")) return .project;
    if (std.mem.eql(u8, raw, "open")) return .open;
    return error.InvalidConfigValue;
}

fn parseBashMode(value: ?*const circuitry.value.Value) !BashMode {
    const raw = scalarText(value) orelse return .build;
    if (std.mem.eql(u8, raw, "inspect")) return .inspect;
    if (std.mem.eql(u8, raw, "build")) return .build;
    if (std.mem.eql(u8, raw, "open")) return .open;
    return error.InvalidConfigValue;
}

fn loadProvider(allocator: Allocator, model: ModelConfig) !ProviderConfig {
    const api_key_env = if (model.api_key_env) |value| try allocator.dupe(u8, value) else null;
    errdefer if (api_key_env) |value| allocator.free(value);
    const authorization = try providerAuthorization(allocator, model.kind, api_key_env);
    errdefer if (authorization) |value| allocator.free(value);
    return .{
        .id = try allocator.dupe(u8, model.id),
        .kind = model.kind,
        .model = try allocator.dupe(u8, model.model),
        .base_url = try allocator.dupe(u8, model.base_url),
        .api_key_env = api_key_env,
        .authorization = authorization,
    };
}

fn providerAuthorization(allocator: Allocator, kind: ModelKind, api_key_env: ?[]const u8) !?[]u8 {
    if (api_key_env) |env_name| {
        const secret = envValue(allocator, env_name) catch |err| switch (err) {
            error.EnvironmentVariableMissing => return null,
            else => return err,
        };
        defer allocator.free(secret);
        return try std.fmt.allocPrint(allocator, "Bearer {s}", .{secret});
    }
    if (kind == .local) return try allocator.dupe(u8, default_authorization);
    return null;
}

fn envValue(allocator: Allocator, name: []const u8) ![]u8 {
    const env = process_env orelse return error.EnvironmentVariableMissing;
    const value = env.get(name) orelse return error.EnvironmentVariableMissing;
    return allocator.dupe(u8, value);
}

fn parseModelKind(text: []const u8) !ModelKind {
    if (std.mem.eql(u8, text, "local")) return .local;
    if (std.mem.eql(u8, text, "openai")) return .openai;
    return error.InvalidConfigValue;
}

fn normalizeBaseUrl(allocator: Allocator, raw: []const u8) ![]u8 {
    var end = raw.len;
    while (end > 0 and raw[end - 1] == '/') end -= 1;
    return allocator.dupe(u8, raw[0..end]);
}

fn loadModel(allocator: Allocator, cfg: Config, id: []const u8) !ModelConfig {
    const kind_text = try cfg.string(allocator, &.{ "models", id, "kind" }, "local");
    defer allocator.free(kind_text);
    const kind = try parseModelKind(kind_text);
    const model_name = try cfg.string(allocator, &.{ "models", id, "model" }, default_served_model);
    errdefer allocator.free(model_name);
    const raw_base_url = switch (kind) {
        .local => try cfg.string(allocator, &.{ "models", id, "base_url" }, default_base_url),
        .openai => try requiredModelFieldString(allocator, cfg, id, "base_url"),
    };
    defer allocator.free(raw_base_url);
    const base_url = try normalizeBaseUrl(allocator, raw_base_url);
    errdefer allocator.free(base_url);
    const api_key_env = try cfg.optionalString(allocator, &.{ "models", id, "api_key_env" });
    errdefer if (api_key_env) |value| allocator.free(value);
    if (kind == .local) try requireLocalModel(cfg, id);
    return .{
        .id = try allocator.dupe(u8, id),
        .kind = kind,
        .model = model_name,
        .base_url = base_url,
        .api_key_env = api_key_env,
        .loader = .{
            .engine = try cfg.string(allocator, &.{ "models", id, "llama_cpp", "engine" }, "llama.cpp"),
            .repo = try cfg.string(allocator, &.{ "models", id, "llama_cpp", "repo" }, "https://github.com/ggml-org/llama.cpp.git"),
            .ref = try cfg.string(allocator, &.{ "models", id, "llama_cpp", "ref" }, "master"),
            .hf_repo = try cfg.string(allocator, &.{ "models", id, "hf", "repo" }, ""),
            .hf_file = try cfg.string(allocator, &.{ "models", id, "hf", "file" }, ""),
            .mmproj_file = try cfg.string(allocator, &.{ "models", id, "hf", "mmproj" }, ""),
            .cache_type_k = try cfg.string(allocator, &.{ "models", id, "llama_cpp", "cache_type_k" }, "q4_0"),
            .cache_type_v = try cfg.string(allocator, &.{ "models", id, "llama_cpp", "cache_type_v" }, "q4_0"),
            .fit_ctx = try cfg.usizeValue(&.{ "models", id, "llama_cpp", "fit_ctx" }, 16384),
            .gpu_layers = try cfg.string(allocator, &.{ "models", id, "llama_cpp", "gpu_layers" }, "all"),
            .draft_tokens = try cfg.usizeValue(&.{ "models", id, "llama_cpp", "draft_tokens" }, 2),
            .reasoning_format = try cfg.string(allocator, &.{ "models", id, "llama_cpp", "reasoning_format" }, "deepseek"),
            .mtp = try cfg.boolValue(&.{ "models", id, "llama_cpp", "mtp" }, true),
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

fn requiredModelFieldString(allocator: Allocator, cfg: Config, id: []const u8, field: []const u8) ![]u8 {
    if (try cfg.optionalString(allocator, &.{ "models", id, field })) |value| return value;
    std.debug.print("Model {s} is kind openai but has no {s}.\n", .{ id, field });
    return error.InvalidConfigValue;
}

fn requireLocalModel(cfg: Config, id: []const u8) !void {
    const engine = scalarText(cfg.value(&.{ "models", id, "llama_cpp", "engine" })) orelse "llama.cpp";
    const hf_repo = scalarText(cfg.value(&.{ "models", id, "hf", "repo" })) orelse @as([]const u8, "");
    const hf_file = scalarText(cfg.value(&.{ "models", id, "hf", "file" })) orelse @as([]const u8, "");
    if (!std.mem.eql(u8, engine, "llama.cpp")) return error.InvalidConfigValue;
    if (hf_repo.len == 0) return error.InvalidConfigValue;
    if (hf_file.len == 0) return error.InvalidConfigValue;
}

fn runtimePaths(allocator: Allocator, layout_ctx: layout.Context, cfg: Config) !RuntimePaths {
    var paths = RuntimePaths{
        .graph = try layout.sharePath(allocator, layout_ctx, "graphs/zinc-loop.circuitry.yaml"),
        .context_graph = try layout.sharePath(allocator, layout_ctx, "graphs/zinc-context-recovery.circuitry.yaml"),
        .compaction_graph = try layout.sharePath(allocator, layout_ctx, "graphs/zinc-compaction.circuitry.yaml"),
    };
    errdefer paths.deinit(allocator);
    if (try cfg.optionalString(allocator, &.{ "paths", "graph" })) |v| {
        allocator.free(paths.graph);
        paths.graph = try expandHome(allocator, layout_ctx, v);
        allocator.free(v);
    }
    if (try cfg.optionalString(allocator, &.{ "paths", "context_graph" })) |v| {
        allocator.free(paths.context_graph);
        paths.context_graph = try expandHome(allocator, layout_ctx, v);
        allocator.free(v);
    }
    if (try cfg.optionalString(allocator, &.{ "paths", "compaction_graph" })) |v| {
        allocator.free(paths.compaction_graph);
        paths.compaction_graph = try expandHome(allocator, layout_ctx, v);
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

fn loadConfig(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) !Config {
    var documents: std.ArrayList(circuitry.Graph) = .empty;
    errdefer {
        for (documents.items) |*document| document.deinit();
        documents.deinit(allocator);
    }

    const global = try layout.configPath(allocator, layout_ctx);
    defer allocator.free(global);
    try loadConfigValue(allocator, io, global, &documents);
    try loadConfigValue(allocator, io, ".zinc/config.yaml", &documents);
    return .{ .documents = try documents.toOwnedSlice(allocator) };
}

fn loadConfigValue(allocator: Allocator, io: std.Io, path: []const u8, documents: *std.ArrayList(circuitry.Graph)) !void {
    if (!files.existsPath(path)) return;
    try documents.append(allocator, try circuitry.loadYamlFile(allocator, io, path));
}

fn findPath(root: *const circuitry.value.Value, path: []const []const u8) ?*const circuitry.value.Value {
    var value = root;
    for (path) |part| {
        if (value.* != .mapping) return null;
        value = value.mapping.getPtr(part) orelse return null;
    }
    return value;
}

fn scalarText(value: ?*const circuitry.value.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v.* == .string) v.string else null;
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

fn expandHome(allocator: Allocator, layout_ctx: layout.Context, value: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, value, "~/")) return platform.path.joinDisplay(allocator, layout_ctx.os, &.{ layout_ctx.dirs.home, value[2..] });
    return allocator.dupe(u8, value);
}

test "model runtime kinds are local or openai only" {
    try std.testing.expectEqual(ModelKind.local, try parseModelKind("local"));
    try std.testing.expectEqual(ModelKind.openai, try parseModelKind("openai"));
    try std.testing.expectError(error.InvalidConfigValue, parseModelKind("openai_compatible"));
}

test "model endpoint base URLs are normalized" {
    const got = try normalizeBaseUrl(std.testing.allocator, "https://example.com/v1///");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("https://example.com/v1", got);
}
