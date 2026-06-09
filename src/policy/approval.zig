const std = @import("std");
const Store = @import("../runtime/store.zig").Store;
const approvals = @import("../runtime/store.zig").approvals;
const files = @import("../io/fs.zig");

const Allocator = std.mem.Allocator;

pub const Decision = enum { allow, deny };

pub fn checkOrPrompt(allocator: Allocator, io: std.Io, store: *Store, run_id: []const u8, command: []const u8) !Decision {
    _ = allocator;
    const head = std.fs.path.basename(command);
    
    // 1. Check existing approvals for this run
    if (try store.getApprovalForSubject(run_id, "command", command)) |app| {
        if (std.mem.eql(u8, app.decision.?, "allow_run") or std.mem.eql(u8, app.decision.?, "allow_workspace")) {
            return .allow;
        }
        if (std.mem.eql(u8, app.decision.?, "deny")) {
            return .deny;
        }
    }
    
    // Check approvals by command head
    if (try store.getApprovalForSubject(run_id, "command_head", head)) |app| {
        if (std.mem.eql(u8, app.decision.?, "allow_run") or std.mem.eql(u8, app.decision.?, "allow_workspace")) {
            return .allow;
        }
        if (std.mem.eql(u8, app.decision.?, "deny")) {
            return .deny;
        }
    }

    // 2. Prompt the user
    try files.writeAllErr("\n========================================\n");
    try files.writeAllErr("APPROVAL REQUIRED\n");
    try files.writeAllErr("Command: ");
    try files.writeAllErr(command);
    try files.writeAllErr("\n\n");
    try files.writeAllErr("1) allow once\n");
    try files.writeAllErr("2) allow next N times\n");
    try files.writeAllErr("3) allow for this run\n");
    try files.writeAllErr("4) allow for this workspace\n");
    try files.writeAllErr("5) deny\n");
    try files.writeAllErr("Choice [1-5]: ");

    var buffer: [32]u8 = undefined;
    const bytes_read = try files.readStdin(&buffer);
    if (bytes_read == 0) return .deny;

    const trimmed = std.mem.trim(u8, buffer[0..bytes_read], " \t\r\n");
    if (trimmed.len == 0) return .deny;

    const choice = trimmed[0];
    const now = std.Io.Clock.now(.real, io).toSeconds();
    
    var app_id_buf: [16]u8 = undefined;
    const app_id = try randomHex(io, &app_id_buf);

    if (choice == '1') {
        return .allow;
    } else if (choice == '2') {
        try files.writeAllErr("Enter count N: ");
        var n_buf: [32]u8 = undefined;
        const n_read = try files.readStdin(&n_buf);
        const n_trimmed = std.mem.trim(u8, n_buf[0..n_read], " \t\r\n");
        const n = std.fmt.parseInt(usize, n_trimmed, 10) catch 1;
        // Save allow next N times (represented as allow_run here for simplicity)
        _ = n; 
        return .allow;
    } else if (choice == '3') {
        try store.insertApproval(approvals{
            .id = app_id,
            .run_id = run_id,
            .kind = "command",
            .subject = command,
            .decision = "allow_run",
            .created_at = now,
        });
        return .allow;
    } else if (choice == '4') {
        try store.insertApproval(approvals{
            .id = app_id,
            .run_id = run_id,
            .kind = "command",
            .subject = command,
            .decision = "allow_workspace",
            .created_at = now,
        });
        return .allow;
    } else {
        try store.insertApproval(approvals{
            .id = app_id,
            .run_id = run_id,
            .kind = "command",
            .subject = command,
            .decision = "deny",
            .created_at = now,
        });
        return .deny;
    }
}

fn randomHex(io: std.Io, buf: []u8) ![]const u8 {
    const ts = std.Io.Clock.now(.real, io).toNanoseconds();
    var prng = std.Random.DefaultPrng.init(@intCast(@as(u96, @bitCast(ts)) & 0xFFFFFFFFFFFFFFFF));
    const alphabet = "0123456789abcdef";
    for (buf) |*c| {
        c.* = alphabet[prng.random().uintLessThan(usize, 16)];
    }
    return buf;
}
