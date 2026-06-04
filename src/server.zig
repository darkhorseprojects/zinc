const std = @import("std");
const builtin = @import("builtin");
const config = @import("config/mod.zig");
const files = @import("io/fs.zig");
const layout = @import("io/layout.zig");
const graph = @import("graph/mod.zig");

const Allocator = std.mem.Allocator;

pub fn start(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, model_arg: ?[]const u8) !void {
    if (builtin.os.tag != .linux) {
        std.debug.print("error: zn serve is only available on Linux. Use a model with kind: openai for an external OpenAI-compatible endpoint.\n", .{});
        return error.UnsupportedPlatform;
    }
    const pid_path = try layout.statePath(allocator, layout_ctx, "server.pid");
    defer allocator.free(pid_path);
    const model_id = if (model_arg) |m| try allocator.dupe(u8, m) else try config.resolveConfiguredModelId(allocator, io, layout_ctx);
    defer allocator.free(model_id);
    try safeModelId(model_id);
    const profile = try config.loadRuntimeProfile(allocator, io, layout_ctx, model_id);
    defer profile.deinit(allocator);
    if (try livePid(allocator, pid_path)) |pid| {
        try waitReady(allocator, io, profile.provider.base_url, pid);
        return std.debug.print("Zinc server ready: pid {d}, model {s}\n", .{ pid, model_id });
    }
    const server = try ensureEngine(allocator, io, layout_ctx, &profile);
    defer allocator.free(server);
    const model = try ensureModel(allocator, io, layout_ctx, &profile);
    defer allocator.free(model);
    const mmproj = try ensureMmproj(allocator, io, layout_ctx, &profile);
    defer if (mmproj) |path| allocator.free(path);
    const log = try layout.statePath(allocator, layout_ctx, "server.log");
    defer allocator.free(log);
    if (std.fs.path.dirname(log)) |dir| try files.mkdirP(dir);

    const ctx_text = try std.fmt.allocPrint(allocator, "{d}", .{profile.model.loader.fit_ctx});
    defer allocator.free(ctx_text);
    const draft_text = try std.fmt.allocPrint(allocator, "{d}", .{profile.model.loader.draft_tokens});
    defer allocator.free(draft_text);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try serverArgs(allocator, &argv, server, model, mmproj, log, &profile, ctx_text, draft_text);
    const child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    const pid: std.posix.pid_t = @intCast(child.id orelse return error.ServerStartFailed);
    try sleep(io, 250);
    if (!alive(allocator, pid)) return error.ServerStartFailed;
    try waitReady(allocator, io, profile.provider.base_url, pid);
    const pid_text = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    defer allocator.free(pid_text);
    try files.write(pid_path, pid_text);
    try writeServerInfo(allocator, layout_ctx, model_id, &profile, log, mmproj);
    std.debug.print("Zinc server serving {s}: pid {d}, log {s}\n", .{ model_id, pid, log });
}

pub fn stop(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) !void {
    if (builtin.os.tag != .linux) {
        std.debug.print("error: zn stop is only available on Linux because Zinc-managed server processes are Linux-only.\n", .{});
        return error.UnsupportedPlatform;
    }
    const pid_path = try layout.statePath(allocator, layout_ctx, "server.pid");
    defer allocator.free(pid_path);
    const pid = try storedPid(allocator, pid_path) orelse return std.debug.print("Zinc server is not running\n", .{});
    defer remove(pid_path);
    defer removeServerInfo(allocator, layout_ctx);
    if (!alive(allocator, pid)) return std.debug.print("Zinc server was not running\n", .{});
    if (!ours(allocator, pid)) return error.PidIsNotZincServer;
    try std.posix.kill(pid, .TERM);
    if (!waitStopped(allocator, io, pid, 5000)) try std.posix.kill(pid, .KILL);
    if (!waitStopped(allocator, io, pid, 5000)) return error.ServerStopFailed;
    std.debug.print("Zinc server stopped\n", .{});
}

pub fn doctor(allocator: Allocator, io: std.Io, layout_ctx: layout.Context) !void {
    std.debug.print("Zinc doctor\n\n", .{});

    std.debug.print("Zinc\n", .{});
    std.debug.print("  ✓ zn binary\n", .{});
    std.debug.print("  version: 0.4.5\n", .{});

    const config_path = try layout.configPath(allocator, layout_ctx);
    defer allocator.free(config_path);
    const has_config = files.existsPath(config_path);
    std.debug.print("\nConfig\n", .{});
    std.debug.print("  {s} config file: {s}\n", .{ mark(has_config), config_path });

    const model_id = config.resolveConfiguredModelId(allocator, io, layout_ctx) catch null;
    defer if (model_id) |id| allocator.free(id);
    const profile = if (model_id) |id| config.loadRuntimeProfile(allocator, io, layout_ctx, id) catch null else null;
    std.debug.print("  {s} config parses\n", .{mark(profile != null)});

    std.debug.print("\nCircuitry\n", .{});
    std.debug.print("  ✓ native circuitry-zig runtime linked\n", .{});

    std.debug.print("\nFiles\n", .{});
    const global_pkg = try layout.sharePath(allocator, layout_ctx, "packages");
    defer allocator.free(global_pkg);
    std.debug.print("  {s} global package dir writable: {s}\n", .{ mark(writableDir(global_pkg)), global_pkg });
    std.debug.print("  {s} project package dir writable: .zinc/packages\n", .{mark(writableDir(".zinc/packages"))});
    std.debug.print("  {s} sessions dir writable: .zinc/sessions\n", .{mark(writableDir(".zinc/sessions"))});
    const prompt_a = try layout.sharePath(allocator, layout_ctx, "prompts/bash-guide.md");
    defer allocator.free(prompt_a);
    const prompt_b = try layout.sharePath(allocator, layout_ctx, "prompts/circuitry-author.md");
    defer allocator.free(prompt_b);
    std.debug.print("  {s} stock prompt: bash-guide\n", .{mark(files.existsPath(prompt_a))});
    std.debug.print("  {s} stock prompt: circuitry-author\n", .{mark(files.existsPath(prompt_b))});

    if (profile) |p| {
        defer p.deinit(allocator);
        std.debug.print("\nGraphs\n", .{});
        const graph_ok = files.existsPath(p.paths.graph);
        const context_ok = files.existsPath(p.paths.context_graph);
        const compact_ok = files.existsPath(p.paths.compaction_graph);
        std.debug.print("  {s} stock graph: {s}\n", .{ mark(graph_ok), p.paths.graph });
        std.debug.print("  {s} stock graph: {s}\n", .{ mark(context_ok), p.paths.context_graph });
        std.debug.print("  {s} stock graph: {s}\n", .{ mark(compact_ok), p.paths.compaction_graph });
        std.debug.print("  {s} circuitry check: zinc-loop\n", .{mark(graph_ok and graphValid(allocator, io, p.paths.graph))});
        std.debug.print("  {s} circuitry check: zinc-context-recovery\n", .{mark(context_ok and graphValid(allocator, io, p.paths.context_graph))});
        std.debug.print("  {s} circuitry check: zinc-compaction\n", .{mark(compact_ok and graphValid(allocator, io, p.paths.compaction_graph))});

        std.debug.print("\nModel runtime\n", .{});
        std.debug.print("  ✓ model id: {s}\n", .{p.model.id});
        std.debug.print("  ✓ kind: {s}\n", .{modelKindName(p.provider.kind)});
        std.debug.print("  ✓ base URL: {s}\n", .{p.provider.base_url});
        std.debug.print("  ✓ served model: {s}\n", .{p.model.model});
        if (p.provider.api_key_env) |env_name| {
            std.debug.print("  {s} api_key_env {s} present\n", .{ mark(envPresent(allocator, env_name)), env_name });
        } else std.debug.print("  - api_key_env: none\n", .{});
        if (p.provider.kind == .local) {
            std.debug.print("  {s} llama.cpp configured\n", .{mark(std.mem.eql(u8, p.model.loader.engine, "llama.cpp"))});
            std.debug.print("  {s} HF model configured: {s}/{s}\n", .{ mark(p.model.loader.hf_repo.len != 0 and p.model.loader.hf_file.len != 0), p.model.loader.hf_repo, p.model.loader.hf_file });
            std.debug.print("  {s} required command: git\n", .{mark(commandOk(allocator, io, &.{ "git", "--version" }))});
            std.debug.print("  {s} required command: cmake\n", .{mark(commandOk(allocator, io, &.{ "cmake", "--version" }))});
            std.debug.print("  {s} required command: hf\n", .{mark(commandOk(allocator, io, &.{ "hf", "--version" }))});
        }
        const reachable = probe(allocator, io, p.provider.base_url) != 0;
        std.debug.print("  {s} model endpoint reachable\n", .{mark(reachable)});
        if (!reachable and p.provider.kind == .local) std.debug.print("\nFix: run `zn serve` to build/download and start the configured local model server.\n", .{});
    } else {
        std.debug.print("\nFix: create a valid config at {s}, or reinstall Zinc from the latest release.\n", .{config_path});
    }

    const pid_path = try layout.statePath(allocator, layout_ctx, "server.pid");
    defer allocator.free(pid_path);
    if (builtin.os.tag != .linux) {
        std.debug.print("\nServer\n  ✗ Zinc-managed llama-server is Linux-only\n  Fix: select a model with kind: openai for an external OpenAI-compatible endpoint.\n", .{});
    } else if (try livePid(allocator, pid_path)) |pid| std.debug.print("\nServer\n  ✓ Zinc-managed llama-server: pid {d}\n", .{pid}) else std.debug.print("\nServer\n  - Zinc-managed llama-server is not running\n", .{});
}

fn ensureEngine(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, profile: *const config.RuntimeProfile) ![]u8 {
    if (!std.mem.eql(u8, profile.model.loader.engine, "llama.cpp")) return error.UnsupportedEngine;
    const dir = try layout.sharePath(allocator, layout_ctx, "llama.cpp");
    defer allocator.free(dir);
    if (files.exists(dir)) |_| {} else |_| try run(allocator, io, &.{ "git", "clone", profile.model.loader.repo, dir });
    try run(allocator, io, &.{ "git", "-C", dir, "fetch", "origin", profile.model.loader.ref });
    try run(allocator, io, &.{ "git", "-C", dir, "checkout", profile.model.loader.ref });
    if (std.mem.eql(u8, profile.model.loader.ref, "master") or std.mem.eql(u8, profile.model.loader.ref, "main")) try run(allocator, io, &.{ "git", "-C", dir, "pull", "--ff-only", "origin", profile.model.loader.ref });
    const build_dir = try std.fmt.allocPrint(allocator, "{s}/build", .{dir});
    defer allocator.free(build_dir);
    const server = try std.fmt.allocPrint(allocator, "{s}/bin/llama-server", .{build_dir});
    if (files.exists(server)) |_| return server else |_| {}
    errdefer allocator.free(server);
    try run(allocator, io, &.{ "cmake", "-B", build_dir, "-S", dir, "-DCMAKE_BUILD_TYPE=Release", "-DGGML_CUDA=ON", "-DGGML_NATIVE=ON", "-DGGML_CUDA_GRAPHS=ON", "-DGGML_CUDA_FORCE_CUBLAS=OFF", "-DGGML_CUDA_FA_ALL_QUANTS=OFF", "-DLLAMA_CURL=ON", "-DCMAKE_CUDA_ARCHITECTURES=native" });
    try run(allocator, io, &.{ "cmake", "--build", build_dir, "--config", "Release", "--target", "llama-server", "-j", "2" });
    return server;
}

fn ensureModel(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, profile: *const config.RuntimeProfile) ![]u8 {
    return ensureHfFile(allocator, io, layout_ctx, profile.model.loader.hf_repo, profile.model.loader.hf_file);
}

fn ensureMmproj(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, profile: *const config.RuntimeProfile) !?[]u8 {
    if (profile.model.loader.mmproj_file.len == 0) return null;
    return try ensureHfFile(allocator, io, layout_ctx, profile.model.loader.hf_repo, profile.model.loader.mmproj_file);
}

fn ensureHfFile(allocator: Allocator, io: std.Io, layout_ctx: layout.Context, repo: []const u8, filename: []const u8) ![]u8 {
    if (repo.len == 0 or filename.len == 0) return error.InvalidConfigValue;
    const safe = try safeRepo(allocator, repo);
    defer allocator.free(safe);
    const rel = try std.fmt.allocPrint(allocator, "models/{s}", .{safe});
    defer allocator.free(rel);
    const dir = try layout.sharePath(allocator, layout_ctx, rel);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, filename });
    if (files.exists(path)) |_| return path else |_| {}
    errdefer allocator.free(path);
    try files.mkdirP(dir);
    try run(allocator, io, &.{ "hf", "download", repo, filename, "--local-dir", dir });
    if (files.exists(path)) |_| return path else |_| return error.ModelDownloadFailed;
}

fn serverArgs(allocator: Allocator, argv: *std.ArrayList([]const u8), server: []const u8, model: []const u8, mmproj: ?[]const u8, log: []const u8, profile: *const config.RuntimeProfile, ctx_text: []const u8, draft_text: []const u8) !void {
    const l = profile.model.loader;
    try argv.appendSlice(allocator, &.{ server, "-m", model, "--alias", profile.model.model, "--host", "127.0.0.1", "--port", "30000", "--ctx-size", ctx_text, "--parallel", "1", "--flash-attn", "on", "-ctk", l.cache_type_k, "-ctv", l.cache_type_v, "--jinja", "--cache-ram", "0", "--log-colors", "off", "--log-file", log, "--reasoning", if (profile.model.reasoning.enabled) "on" else "off", "--reasoning-format", l.reasoning_format });
    if (mmproj) |path| try argv.appendSlice(allocator, &.{ "--mmproj", path });
    if (std.mem.eql(u8, l.gpu_layers, "fit")) try argv.appendSlice(allocator, &.{ "--fit", "on", "--fit-ctx", ctx_text }) else try argv.appendSlice(allocator, &.{ "--n-gpu-layers", l.gpu_layers });
    if (l.mtp) try argv.appendSlice(allocator, &.{ "--spec-type", "draft-mtp", "--spec-draft-n-max", draft_text });
}

fn writeServerInfo(allocator: Allocator, layout_ctx: layout.Context, model_id: []const u8, profile: *const config.RuntimeProfile, log: []const u8, mmproj: ?[]const u8) !void {
    const path = try layout.statePath(allocator, layout_ctx, "server.info");
    defer allocator.free(path);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.print(allocator, "model_id: {s}\nserved_model: {s}\nlog: {s}\nmtp: {}\n", .{ model_id, profile.model.model, log, profile.model.loader.mtp });
    if (mmproj) |value| try out.print(allocator, "mmproj: {s}\n", .{value});
    try files.write(path, out.items);
}

fn readServerInfo(allocator: Allocator, layout_ctx: layout.Context) ![]u8 {
    const path = try layout.statePath(allocator, layout_ctx, "server.info");
    defer allocator.free(path);
    return files.readLimited(allocator, path, 4096);
}

fn removeServerInfo(allocator: Allocator, layout_ctx: layout.Context) void {
    const path = layout.statePath(allocator, layout_ctx, "server.info") catch return;
    defer allocator.free(path);
    remove(path);
}

fn run(allocator: Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .stderr_limit = .limited(5 * 1024 * 1024), .stdout_limit = .limited(5 * 1024 * 1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("command failed: {s}\n{s}\n{s}\n", .{ argv[0], result.stdout, result.stderr });
        return error.CommandFailed;
    }
}

fn livePid(allocator: Allocator, path: []const u8) !?std.posix.pid_t {
    const pid = try storedPid(allocator, path) orelse return null;
    if (alive(allocator, pid) and ours(allocator, pid)) return pid;
    remove(path);
    return null;
}
fn storedPid(allocator: Allocator, path: []const u8) !?std.posix.pid_t {
    const text = files.readLimited(allocator, path, 64) catch return null;
    defer allocator.free(text);
    return std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}
fn waitReady(allocator: Allocator, io: std.Io, base_url: []const u8, pid: std.posix.pid_t) !void {
    var attempt: usize = 0;
    while (alive(allocator, pid)) : (attempt += 1) {
        const s = probe(allocator, io, base_url);
        if (s >= 200 and s < 300) return;
        if (s >= 400 and s < 500) return error.ServerReadinessFailed;
        if (attempt != 0 and attempt % 10 == 0) std.debug.print("Zinc server still loading model...\n", .{});
        try sleep(io, 1000);
    }
    return error.ServerStartFailed;
}
fn mark(ok: bool) []const u8 {
    return if (ok) "✓" else "✗";
}

fn modelKindName(kind: config.ModelKind) []const u8 {
    return switch (kind) {
        .local => "local",
        .openai => "openai",
    };
}

fn envPresent(allocator: Allocator, name: []const u8) bool {
    _ = allocator;
    return config.envPresent(name);
}

fn graphValid(allocator: Allocator, io: std.Io, path: []const u8) bool {
    const loaded = graph.load(allocator, io, path) catch return false;
    defer loaded.deinit(allocator);
    graph.validate(loaded) catch return false;
    return true;
}

fn commandOk(allocator: Allocator, io: std.Io, argv: []const []const u8) bool {
    const result = std.process.run(allocator, io, .{ .argv = argv, .stdout_limit = .limited(1024), .stderr_limit = .limited(1024) }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn writableDir(path: []const u8) bool {
    files.mkdirP(path) catch return false;
    const probe_path = std.fs.path.join(std.heap.page_allocator, &.{ path, ".zinc-doctor-write-test" }) catch return false;
    defer std.heap.page_allocator.free(probe_path);
    files.write(probe_path, "ok") catch return false;
    var dir = std.Io.Dir.cwd();
    dir.deleteFile(std.Options.debug_io, probe_path) catch {};
    return true;
}

fn probe(allocator: Allocator, io: std.Io, base_url: []const u8) u16 {
    const url = std.fmt.allocPrint(allocator, "{s}/models", .{base_url}) catch return 0;
    defer allocator.free(url);
    var response = std.Io.Writer.Allocating.init(allocator);
    defer response.deinit();
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    const result = client.fetch(.{ .location = .{ .url = url }, .method = .GET, .response_writer = &response.writer }) catch return 0;
    return @intFromEnum(result.status);
}
fn waitStopped(allocator: Allocator, io: std.Io, pid: std.posix.pid_t, ms: usize) bool {
    var waited: usize = 0;
    while (waited < ms) : (waited += 100) {
        sleep(io, 100) catch return false;
        if (!alive(allocator, pid)) return true;
    }
    return !alive(allocator, pid);
}
fn ours(allocator: Allocator, pid: std.posix.pid_t) bool {
    var cmdline: [64 * 1024]u8 = undefined;
    const cmdline_path = std.fmt.allocPrint(allocator, "/proc/{d}/cmdline", .{pid}) catch return false;
    defer allocator.free(cmdline_path);
    if (readProcFile(cmdline_path, &cmdline)) |text| if (std.mem.indexOf(u8, text, "llama-server") != null) return true;

    var comm: [256]u8 = undefined;
    const comm_path = std.fmt.allocPrint(allocator, "/proc/{d}/comm", .{pid}) catch return false;
    defer allocator.free(comm_path);
    const text = readProcFile(comm_path, &comm) orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n"), "llama-server");
}

fn readProcFile(path: []const u8, buffer: []u8) ?[]const u8 {
    var path_z: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_z.len) return null;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const raw_fd = std.os.linux.open(&path_z, .{ .ACCMODE = .RDONLY }, 0);
    if (std.os.linux.errno(raw_fd) != .SUCCESS) return null;
    const fd: i32 = @intCast(raw_fd);
    defer _ = std.os.linux.close(fd);
    const raw_n = std.os.linux.read(fd, buffer.ptr, buffer.len);
    if (std.os.linux.errno(raw_n) != .SUCCESS) return null;
    return buffer[0..raw_n];
}
fn alive(allocator: Allocator, pid: std.posix.pid_t) bool {
    _ = allocator;
    std.posix.kill(pid, @as(std.posix.SIG, @enumFromInt(0))) catch return false;
    return true;
}
fn sleep(io: std.Io, ms: usize) !void {
    try std.Io.sleep(io, .fromMilliseconds(@intCast(ms)), .awake);
}
fn remove(path: []const u8) void {
    var dir = std.Io.Dir.cwd();
    dir.deleteFile(std.Options.debug_io, path) catch {};
}
fn safeModelId(model: []const u8) !void {
    if (model.len == 0) return error.InvalidModelId;
    for (model) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return error.InvalidModelId,
    };
}
fn safeRepo(allocator: Allocator, repo: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, repo);
    for (out) |*c| if (c.* == '/') {
        c.* = '_';
    };
    return out;
}
