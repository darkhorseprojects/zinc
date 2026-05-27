const std = @import("std");
const config = @import("runtime/config.zig");
const files = @import("files.zig");
const layout = @import("layout.zig");

const Allocator = std.mem.Allocator;
const root = ".local/share/zinc";

pub fn start(allocator: Allocator, io: std.Io, home: []const u8, model_arg: ?[]const u8) !void {
    const pid_path = try layout.statePath(allocator, home, "server.pid");
    defer allocator.free(pid_path);
    const model_id = if (model_arg) |m| try allocator.dupe(u8, m) else try config.resolveConfiguredModelId(allocator, io, home);
    defer allocator.free(model_id);
    try safeModelId(model_id);
    const profile = try config.loadRuntimeProfile(allocator, io, home, model_id);
    defer profile.deinit(allocator);
    if (try livePid(allocator, pid_path)) |pid| {
        try waitReady(allocator, io, profile.provider.base_url, pid);
        return std.debug.print("Zinc server ready: pid {d}, model {s}\n", .{ pid, model_id });
    }
    const server = try ensureEngine(allocator, io, home, &profile);
    defer allocator.free(server);
    const model = try ensureModel(allocator, io, home, &profile);
    defer allocator.free(model);
    const mmproj = try ensureMmproj(allocator, io, home, &profile);
    defer if (mmproj) |path| allocator.free(path);
    const log = try layout.statePath(allocator, home, "server.log");
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
    sleep(250);
    if (!alive(allocator, pid)) return error.ServerStartFailed;
    try waitReady(allocator, io, profile.provider.base_url, pid);
    const pid_text = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    defer allocator.free(pid_text);
    try files.write(pid_path, pid_text);
    try writeServerInfo(allocator, home, model_id, &profile, log, mmproj);
    std.debug.print("Zinc server serving {s}: pid {d}, log {s}\n", .{ model_id, pid, log });
}

pub fn stop(allocator: Allocator, home: []const u8) !void {
    const pid_path = try layout.statePath(allocator, home, "server.pid");
    defer allocator.free(pid_path);
    const pid = try storedPid(allocator, pid_path) orelse return std.debug.print("Zinc server is not running\n", .{});
    defer remove(pid_path);
    defer removeServerInfo(allocator, home);
    if (!alive(allocator, pid)) return std.debug.print("Zinc server was not running\n", .{});
    if (!ours(allocator, pid)) return error.PidIsNotZincServer;
    try std.posix.kill(pid, .TERM);
    if (!waitStopped(allocator, pid, 5000)) try std.posix.kill(pid, .KILL);
    if (!waitStopped(allocator, pid, 5000)) return error.ServerStopFailed;
    std.debug.print("Zinc server stopped\n", .{});
}

pub fn status(allocator: Allocator, home: []const u8) !void {
    const pid_path = try layout.statePath(allocator, home, "server.pid");
    defer allocator.free(pid_path);
    if (try livePid(allocator, pid_path)) |pid| {
        if (readServerInfo(allocator, home)) |info| {
            defer allocator.free(info);
            std.debug.print("Zinc server running: pid {d}\n{s}", .{ pid, info });
        } else |_| std.debug.print("Zinc server running: pid {d}\n", .{pid});
    } else std.debug.print("Zinc server stopped\n", .{});
}

fn ensureEngine(allocator: Allocator, io: std.Io, home: []const u8, profile: *const config.RuntimeProfile) ![]u8 {
    if (!std.mem.eql(u8, profile.model.loader.engine, "llama.cpp")) return error.UnsupportedEngine;
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}/llama.cpp", .{ home, root });
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

fn ensureModel(allocator: Allocator, io: std.Io, home: []const u8, profile: *const config.RuntimeProfile) ![]u8 {
    return ensureHfFile(allocator, io, home, profile.model.loader.hf_repo, profile.model.loader.hf_file);
}

fn ensureMmproj(allocator: Allocator, io: std.Io, home: []const u8, profile: *const config.RuntimeProfile) !?[]u8 {
    if (profile.model.loader.mmproj_file.len == 0) return null;
    return try ensureHfFile(allocator, io, home, profile.model.loader.hf_repo, profile.model.loader.mmproj_file);
}

fn ensureHfFile(allocator: Allocator, io: std.Io, home: []const u8, repo: []const u8, filename: []const u8) ![]u8 {
    if (repo.len == 0 or filename.len == 0) return error.InvalidConfigValue;
    const safe = try safeRepo(allocator, repo);
    defer allocator.free(safe);
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}/models/{s}", .{ home, root, safe });
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

fn writeServerInfo(allocator: Allocator, home: []const u8, model_id: []const u8, profile: *const config.RuntimeProfile, log: []const u8, mmproj: ?[]const u8) !void {
    const path = try layout.statePath(allocator, home, "server.info");
    defer allocator.free(path);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.print(allocator, "model_id: {s}\nserved_model: {s}\nlog: {s}\nmtp: {}\n", .{ model_id, profile.model.model, log, profile.model.loader.mtp });
    if (mmproj) |value| try out.print(allocator, "mmproj: {s}\n", .{value});
    try files.write(path, out.items);
}

fn readServerInfo(allocator: Allocator, home: []const u8) ![]u8 {
    const path = try layout.statePath(allocator, home, "server.info");
    defer allocator.free(path);
    return files.readLimited(allocator, path, 4096);
}

fn removeServerInfo(allocator: Allocator, home: []const u8) void {
    const path = layout.statePath(allocator, home, "server.info") catch return;
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
        sleep(1000);
    }
    return error.ServerStartFailed;
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
fn waitStopped(allocator: Allocator, pid: std.posix.pid_t, ms: usize) bool {
    var waited: usize = 0;
    while (waited < ms) : (waited += 100) {
        sleep(100);
        if (!alive(allocator, pid)) return true;
    }
    return !alive(allocator, pid);
}
fn ours(allocator: Allocator, pid: std.posix.pid_t) bool {
    const p = std.fmt.allocPrint(allocator, "/proc/{d}/cmdline", .{pid}) catch return false;
    defer allocator.free(p);
    const c = files.readLimited(allocator, p, 4096) catch return false;
    defer allocator.free(c);
    return std.mem.indexOf(u8, c, "llama-server") != null;
}
fn alive(allocator: Allocator, pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @as(std.posix.SIG, @enumFromInt(0))) catch return false;
    const p = std.fmt.allocPrint(allocator, "/proc/{d}/stat", .{pid}) catch return true;
    defer allocator.free(p);
    const stat = files.readLimited(allocator, p, 512) catch return true;
    defer allocator.free(stat);
    const r = std.mem.trim(u8, stat[(std.mem.lastIndexOfScalar(u8, stat, ')') orelse return true) + 1 ..], " ");
    return r.len == 0 or r[0] != 'Z';
}
fn sleep(ms: usize) void {
    var req = std.os.linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    while (true) {
        var left: std.os.linux.timespec = undefined;
        const errno = std.os.linux.errno(std.os.linux.nanosleep(&req, &left));
        if (errno == .SUCCESS or errno != .INTR) return;
        req = left;
    }
}
fn remove(path: []const u8) void {
    var b: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len >= b.len) return;
    @memcpy(b[0..path.len], path);
    b[path.len] = 0;
    _ = std.os.linux.unlink(&b);
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
