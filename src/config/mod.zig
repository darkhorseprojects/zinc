const std = @import("std");
const files = @import("../io/fs.zig");
const graph = @import("../graph/mod.zig");
const packages = @import("../packages/mod.zig");
const layout = @import("../io/layout.zig");
const platform = @import("../platform.zig");
const circuitry = @import("circuitry");

const Allocator = std.mem.Allocator;

const default_chars_per_token: usize = 4;
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
    session_head_messages: usize,
    session_tail_messages: usize,
    session_context_truncate_chars: usize,
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
pub const ProviderConfig = struct {
    id: []u8,
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
pub const ReasoningConfig = struct {
    enabled: bool,
    effort: []u8,
    pub fn deinit(self: ReasoningConfig, allocator: Allocator) void {
        allocator.free(self.effort);
    }
};
pub const ModelConfig = struct {
    id: []u8,
    model: []u8,
    base_url: []u8,
    api_key_env: ?[]u8,
    context_window: usize,
    chars_per_token: usize,
    temperature: f64,
    reasoning: ReasoningConfig,
    pub fn deinit(self: ModelConfig, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.model);
        allocator.free(self.base_url);
        if (self.api_key_env) |value| allocator.free(value);
        self.reasoning.deinit(allocator);
    }
};
pub const RecoverySettings = struct {
    graph: []u8,
    reach: []u8,
    budget_chars: usize,

    pub fn deinit(self: RecoverySettings, allocator: Allocator) void {
        allocator.free(self.graph);
        allocator.free(self.reach);
    }
};

pub const RuntimeProfile = struct {
    paths: RuntimePaths,
    runtime: RuntimeSettings,
    recovery: RecoverySettings,
    default_model: []u8,
    provider: ProviderConfig,
    model: ModelConfig,
    pub fn deinit(self: RuntimeProfile, allocator: Allocator) void {
        self.paths.deinit(allocator);
        self.runtime.deinit(allocator);
        self.recovery.deinit(allocator);
        allocator.free(self.default_model);
        self.provider.deinit(allocator);
        self.model.deinit(allocator);
    }

    pub fn reasoningEffort(self: RuntimeProfile) ?[]const u8 {
        if (!self.model.reasoning.enabled) return null;
        return self.model.reasoning.effort;
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
    fn requiredString(self: Config, allocator: Allocator, path: []const []const u8) ![]u8 {
        const raw = scalarText(self.value(path)) orelse return error.ModelNotConfigured;
        return try allocator.dupe(u8, raw);
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
    const default_model = if (model_override) |id| try allocator.dupe(u8, id) else try cfg.requiredString(allocator, &.{"default_model"});
    errdefer allocator.free(default_model);
    const paths = try runtimePaths(allocator, layout_ctx, cfg);
    errdefer paths.deinit(allocator);
    const runtime_scope = try parseScope(cfg.value(&.{"scope"}));
    const bash_mode = try parseBashMode(cfg.value(&.{ "tools", "bash" }));
    const provider_max_retries = try cfg.usizeValue(&.{ "runtime", "provider_max_retries" }, 5);
    const tool_max_turns = try cfg.usizeValue(&.{ "runtime", "tool_max_turns" }, 12);
    const compaction_threshold_percent = try cfg.usizeValue(&.{ "runtime", "compaction_threshold_percent" }, 70);
    const session_head_messages = try cfg.usizeValue(&.{ "runtime", "session_head_messages" }, 6);
    const session_tail_messages = try cfg.usizeValue(&.{ "runtime", "session_tail_messages" }, 12);
    const session_context_truncate_chars = try cfg.usizeValue(&.{ "runtime", "session_context_truncate_chars" }, 2048);
    const bash_output_max_bytes = try cfg.usizeValue(&.{ "runtime", "bash_output_max_bytes" }, 50 * 1024);
    const bash_output_max_lines = try cfg.usizeValue(&.{ "runtime", "bash_output_max_lines" }, 2000);
    const bash_capture_max_bytes = try cfg.usizeValue(&.{ "runtime", "bash_capture_max_bytes" }, 64 * 1024 * 1024);
    const file_read_max_bytes = try cfg.usizeValue(&.{ "runtime", "file_read_max_bytes" }, 1024 * 1024);
    const file_range_read_max_bytes = try cfg.usizeValue(&.{ "runtime", "file_range_read_max_bytes" }, 8 * 1024 * 1024);
    const file_edit_max_bytes = try cfg.usizeValue(&.{ "runtime", "file_edit_max_bytes" }, 8 * 1024 * 1024);
    const resource_read_max_bytes = try cfg.usizeValue(&.{ "runtime", "resource_read_max_bytes" }, 32 * 1024 * 1024);
    const input_text_file_max_bytes = try cfg.usizeValue(&.{ "runtime", "input_text_file_max_bytes" }, 8 * 1024 * 1024);
    const input_file_max_bytes = try cfg.usizeValue(&.{ "runtime", "input_file_max_bytes" }, 32 * 1024 * 1024);
    const recovery_graph = try recoveryGraphPath(allocator, layout_ctx, cfg);
    errdefer allocator.free(recovery_graph);
    const recovery_reach = try cfg.string(allocator, &.{ "recovery", "reach" }, "project");
    errdefer allocator.free(recovery_reach);
    try validateRecoveryReach(recovery_reach);
    const recovery_budget_chars = try cfg.usizeValue(&.{ "recovery", "budget_chars" }, 12000);
    const recovery = RecoverySettings{ .graph = recovery_graph, .reach = recovery_reach, .budget_chars = recovery_budget_chars };
    errdefer recovery.deinit(allocator);
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
        .session_head_messages = session_head_messages,
        .session_tail_messages = session_tail_messages,
        .session_context_truncate_chars = session_context_truncate_chars,
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
    return .{ .paths = paths, .runtime = runtime, .recovery = recovery, .default_model = default_model, .provider = provider, .model = model };
}

pub fn loadRuntimePaths(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) !RuntimePaths {
    var cfg = try loadConfig(allocator, io, layout_ctx);
    defer cfg.deinit(allocator);
    return runtimePaths(allocator, layout_ctx, cfg);
}

pub fn resolveConfiguredModelId(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) ![]u8 {
    var cfg = try loadConfig(allocator, io, layout_ctx);
    defer cfg.deinit(allocator);
    return cfg.requiredString(allocator, &.{"default_model"});
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
    const authorization = try providerAuthorization(allocator, api_key_env);
    errdefer if (authorization) |value| allocator.free(value);
    return .{
        .id = try allocator.dupe(u8, model.id),
        .model = try allocator.dupe(u8, model.model),
        .base_url = try allocator.dupe(u8, model.base_url),
        .api_key_env = api_key_env,
        .authorization = authorization,
    };
}

fn providerAuthorization(allocator: Allocator, api_key_env: ?[]const u8) !?[]u8 {
    const env_name = api_key_env orelse return null;
    const secret = envValue(allocator, env_name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return null,
        else => return err,
    };
    defer allocator.free(secret);
    return try std.fmt.allocPrint(allocator, "Bearer {s}", .{secret});
}

fn envValue(allocator: Allocator, name: []const u8) ![]u8 {
    const env = process_env orelse return error.EnvironmentVariableMissing;
    const value = env.get(name) orelse return error.EnvironmentVariableMissing;
    return allocator.dupe(u8, value);
}

fn normalizeBaseUrl(allocator: Allocator, raw: []const u8) ![]u8 {
    var end = raw.len;
    while (end > 0 and raw[end - 1] == '/') end -= 1;
    return allocator.dupe(u8, raw[0..end]);
}

fn loadModel(allocator: Allocator, cfg: Config, id: []const u8) !ModelConfig {
    if (cfg.value(&.{ "models", id }) == null) return error.UnknownModel;
    const model_name = try cfg.requiredString(allocator, &.{ "models", id, "model" });
    errdefer allocator.free(model_name);
    const raw_base_url = try cfg.requiredString(allocator, &.{ "models", id, "base_url" });
    defer allocator.free(raw_base_url);
    const base_url = try normalizeBaseUrl(allocator, raw_base_url);
    errdefer allocator.free(base_url);
    const api_key_env = try cfg.optionalString(allocator, &.{ "models", id, "api_key_env" });
    errdefer if (api_key_env) |value| allocator.free(value);
    const context_window = try cfg.usizeValue(&.{ "models", id, "context_window" }, 0);
    if (context_window == 0) return error.InvalidConfigValue;
    const chars_per_token = try cfg.usizeValue(&.{ "models", id, "chars_per_token" }, default_chars_per_token);
    if (chars_per_token == 0) return error.InvalidConfigValue;
    return .{
        .id = try allocator.dupe(u8, id),
        .model = model_name,
        .base_url = base_url,
        .api_key_env = api_key_env,
        .context_window = context_window,
        .chars_per_token = chars_per_token,
        .temperature = try cfg.f64Value(&.{ "models", id, "temperature" }, 0.6),
        .reasoning = .{
            .enabled = try cfg.boolValue(&.{ "models", id, "reasoning", "enabled" }, false),
            .effort = try cfg.string(allocator, &.{ "models", id, "reasoning", "effort" }, "low"),
        },
    };
}

fn validateRecoveryReach(reach: []const u8) !void {
    if (std.mem.eql(u8, reach, "none")) return;
    if (std.mem.eql(u8, reach, "session")) return;
    if (std.mem.eql(u8, reach, "project")) return;
    if (std.mem.eql(u8, reach, "root")) return;
    if (std.mem.eql(u8, reach, "all")) return;
    return error.InvalidConfigValue;
}

fn recoveryGraphPath(allocator: Allocator, layout_ctx: layout.Context, cfg: Config) ![]u8 {
    const raw = try cfg.optionalString(allocator, &.{ "recovery", "graph" }) orelse return layout.sharePath(allocator, layout_ctx, "graphs/zinc-context-recovery.circuitry.yaml");
    defer allocator.free(raw);
    if (std.mem.indexOfAny(u8, raw, "/\\") == null and !std.mem.endsWith(u8, raw, ".yaml") and !std.mem.endsWith(u8, raw, ".yml")) {
        const rel = try std.fmt.allocPrint(allocator, "graphs/{s}.circuitry.yaml", .{raw});
        defer allocator.free(rel);
        return layout.sharePath(allocator, layout_ctx, rel);
    }
    return expandHome(allocator, layout_ctx, raw);
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

test "model endpoint base URLs are normalized" {
    const got = try normalizeBaseUrl(std.testing.allocator, "https://example.com/v1///");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("https://example.com/v1", got);
}
