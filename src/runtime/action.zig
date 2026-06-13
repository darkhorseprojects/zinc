const std = @import("std");
const Store = @import("store.zig").Store;
const actions_table = @import("store.zig").actions;
const mode = @import("../policy/mode.zig");
const scope = @import("../policy/scope.zig");
const approval = @import("../policy/approval.zig");
const proc = @import("../io/process.zig");
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub const PatternList = []const []const u8;

pub const ModeConfig = struct {
    default: mode.Decision,
    allow: PatternList,
    confirm: PatternList,
};

pub const builtin_modes = struct {
    pub const inspect = ModeConfig{
        .default = .deny,
        .allow = &.{ "pwd", "ls", "cat", "rg", "git status", "git diff", "git log" },
        .confirm = &.{},
    };

    pub const build = ModeConfig{
        .default = .confirm,
        .allow = &.{
            "pwd",       "ls",             "cat",      "rg",            "git status", "git diff", "git log",
            "zig build", "zig build test", "npm test", "npm run build",
        },
        .confirm = &.{ "npm install", "rm", "chmod" },
    };

    pub const open = ModeConfig{
        .default = .confirm,
        .allow = &.{"*"},
        .confirm = &.{},
    };
};

pub fn execute(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, seq: i64, command: []const u8, active_mode_name: []const u8) !void {
    const active_mode = if (std.mem.eql(u8, active_mode_name, "inspect"))
        builtin_modes.inspect
    else if (std.mem.eql(u8, active_mode_name, "open"))
        builtin_modes.open
    else
        builtin_modes.build;

    // 1. Determine decision from pattern matching
    var decision = active_mode.default;
    for (active_mode.allow) |pat| {
        if (mode.matchPattern(command, pat)) {
            decision = .allow;
            break;
        }
    }
    for (active_mode.confirm) |pat| {
        if (mode.matchPattern(command, pat)) {
            decision = .confirm;
            break;
        }
    }

    // 2. Resolve approval
    var app_decision: approval.Decision = .allow;
    if (decision == .confirm) {
        app_decision = try approval.checkOrPrompt(allocator, io, store, run_id, command);
    } else if (decision == .deny) {
        try files.writeAllErr("Permission denied: Command blocked by active mode policy.\n");
        app_decision = .deny;
    }

    const action_id = try randomId(allocator, io, "act");
    defer allocator.free(action_id);

    const cwd_buf = try allocator.alloc(u8, std.fs.max_path_bytes);
    defer allocator.free(cwd_buf);

    const cwd_len = std.process.currentPath(io, cwd_buf) catch 0;
    const cwd = if (cwd_len > 0) cwd_buf[0..cwd_len] else ".";

    if (app_decision == .deny) {
        // Record denied action
        const action_path = try std.fmt.allocPrint(allocator, "actions/{d}", .{seq});
        defer allocator.free(action_path);
        try store.insertAction(actions_table{
            .id = action_id,
            .run_id = run_id,
            .path = action_path,
            .seq = seq,
            .action = command,
            .cwd = cwd,
            .status = "denied",
            .approval = if (decision == .confirm) "confirm_deny" else "policy_deny",
            .metadata_json = "{}",
        });
        return error.ActionDenied;
    }

    // 3. Execute
    const preview_bytes = 51200;
    const preview_lines = 2000;
    const capture_bytes = 67108864;

    const res = try proc.runShell(allocator, io, command, null, preview_bytes, capture_bytes, run_id);
    defer res.deinit(allocator);

    const summary = try proc.shellSummary(allocator, command, res, preview_bytes, preview_lines, run_id, seq);
    defer allocator.free(summary);

    const metadata = try proc.shellMetadata(allocator, command, res);
    defer allocator.free(metadata);

    // Print summary to terminal
    try files.writeAllOut(summary);
    try files.writeAllOut("\n");

    const action_path = try std.fmt.allocPrint(allocator, "actions/{d}", .{seq});
    defer allocator.free(action_path);

    // 4. Record action in database
    try store.insertAction(actions_table{
        .id = action_id,
        .run_id = run_id,
        .path = action_path,
        .seq = seq,
        .action = command,
        .cwd = cwd,
        .status = if (res.code == 0) "success" else "failure",
        .approval = if (decision == .confirm) "confirm_allow" else "policy_allow",
        .metadata_json = metadata,
    });
    const stdout_id = try outputId(allocator, action_id, "stdout");
    defer allocator.free(stdout_id);
    const stdout_path = try outputPath(allocator, seq, "stdout");
    defer allocator.free(stdout_path);
    try store.insertActionOutput(.{ .id = stdout_id, .action_id = action_id, .run_id = run_id, .path = stdout_path, .stream = "stdout", .payload = res.stdout, .bytes = @intCast(res.stdout.len), .truncated = if (res.truncated) 1 else 0 });
    const stderr_id = try outputId(allocator, action_id, "stderr");
    defer allocator.free(stderr_id);
    const stderr_path = try outputPath(allocator, seq, "stderr");
    defer allocator.free(stderr_path);
    try store.insertActionOutput(.{ .id = stderr_id, .action_id = action_id, .run_id = run_id, .path = stderr_path, .stream = "stderr", .payload = res.stderr, .bytes = @intCast(res.stderr.len), .truncated = if (res.truncated) 1 else 0 });
}

fn outputId(allocator: Allocator, action_id: []const u8, stream: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ action_id, stream });
}

fn outputPath(allocator: Allocator, seq: i64, stream: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "actions/{d}/{s}", .{ seq, stream });
}

fn randomId(allocator: Allocator, io: std.Io, prefix: []const u8) ![]u8 {
    const ts = std.Io.Clock.now(.real, io).toNanoseconds();
    var prng = std.Random.DefaultPrng.init(@intCast(@as(u96, @bitCast(ts)) & 0xFFFFFFFFFFFFFFFF));
    const alphabet = "0123456789abcdef";
    var rand_buf: [16]u8 = undefined;
    for (&rand_buf) |*c| {
        c.* = alphabet[prng.random().uintLessThan(usize, 16)];
    }
    return try std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, rand_buf });
}
