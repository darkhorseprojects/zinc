const std = @import("std");
const Store = @import("store.zig").Store;
const circuitry_docs = @import("store.zig").circuitry_docs;
const runs = @import("store.zig").runs;
const action = @import("action.zig");
const files = @import("../io/fs.zig");
const layout = @import("../io/layout.zig");
const circuitry = @import("circuitry");

const Allocator = std.mem.Allocator;
const io_opt = std.Options.debug_io;

pub fn runShape(allocator: Allocator, io: std.Io, store: *Store, shape_path: []const u8, args: []const []const u8, active_mode: []const u8) !void {
    const abs_path = try std.fs.path.resolve(allocator, &.{shape_path});
    defer allocator.free(abs_path);

    var shape = try circuitry.loadFile(io, allocator, abs_path);
    defer shape.deinit();

    var confirmation = try circuitry.confirm(allocator, &shape);
    defer confirmation.deinit();

    if (!confirmation.ready) {
        try files.writeAllErr("Error: Circuitry shape is not ready to run.\n");
        for (confirmation.problems) |prob| {
            try files.writeAllErr("- ");
            try files.writeAllErr(prob);
            try files.writeAllErr("\n");
        }
        return error.CircuitryShapeNotReady;
    }

    const card = confirmation.card;

    // Load file source
    const source_bytes = try files.readLimited(allocator, abs_path, 16 * 1024 * 1024);
    defer allocator.free(source_bytes);

    // 1. Generate doc ID and save live source
    var id_buf: [16]u8 = undefined;
    const doc_id = try std.fmt.allocPrint(allocator, "doc_{s}", .{try randomHex(io, &id_buf)});
    defer allocator.free(doc_id);

    try store.insertDoc(circuitry_docs{
        .id = doc_id,
        .path = abs_path,
        .name = card.name,
        .source = source_bytes,
        .updated_at = std.Io.Clock.now(.real, io).toSeconds(),
    });

    // 2. Resolve takes (inputs)
    var takes_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = takes_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        takes_map.deinit();
    }

    for (card.takes) |take_name| {
        // Check if provided in CLI args, e.g. query="hello"
        var value: ?[]const u8 = null;
        const eq_prefix = try std.fmt.allocPrint(allocator, "{s}=", .{take_name});
        defer allocator.free(eq_prefix);

        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, eq_prefix)) {
                value = arg[eq_prefix.len..];
                break;
            }
        }

        if (value) |val| {
            try takes_map.put(take_name, try allocator.dupe(u8, val));
        } else {
            // Prompt user
            try files.writeAllOut("Input value for `");
            try files.writeAllOut(take_name);
            try files.writeAllOut("`: ");
            var prompt_buf: [4096]u8 = undefined;
            const bytes_read = try files.readStdin(&prompt_buf);
            const trimmed = std.mem.trim(u8, prompt_buf[0..bytes_read], " \t\r\n");
            try takes_map.put(take_name, try allocator.dupe(u8, trimmed));
        }
    }

    // 3. Record run started
    const run_id = try std.fmt.allocPrint(allocator, "run_{s}", .{try randomHex(io, &id_buf)});
    defer allocator.free(run_id);

    try store.insertRun(runs{
        .id = run_id,
        .doc_id = doc_id,
        .status = "running",
        .started_at = std.Io.Clock.now(.real, io).toSeconds(),
        .finished_at = null,
    });

    // 4. Print Runtime Guidance
    try files.writeAllOut("\n========================================\n");
    try files.writeAllOut("Runtime Guidance:\n");
    
    // Check if stock/prompts/runtime.md exists
    const guidance_path = "stock/prompts/runtime.md";
    if (files.existsPath(guidance_path)) {
        const text = try files.readLimited(allocator, guidance_path, 1024 * 1024);
        defer allocator.free(text);
        try files.writeAllOut(text);
    } else {
        try files.writeAllOut(
            \\You are inside a Zinc run.
            \\
            \\Use the local environment through Zinc.
            \\
            \\Prefer the least action needed.
            \\
            \\Inspect before changing.
            \\Read only what is needed.
            \\Use small actions before large actions.
            \\Expect approval when an action exceeds policy.
            \\
            \\Large outputs may be truncated. Full captures are available as zinc:// refs.
            \\
        );
    }
    try files.writeAllOut("\n========================================\n");

    // Print Action description (does)
    try files.writeAllOut("Action steps (does):\n");
    for (card.does) |step| {
        try files.writeAllOut("- ");
        try files.writeAllOut(step);
        try files.writeAllOut("\n");
    }
    try files.writeAllOut("\nStarting governed REPL shell. Type 'exit' to finish.\n\n");

    // 5. Governed shell REPL loop
    var seq: i64 = 1;
    var command_buf: [8192]u8 = undefined;
    while (true) {
        try files.writeAllOut("zn(");
        try files.writeAllOut(card.name);
        try files.writeAllOut(")> ");

        const n = try files.readStdin(&command_buf);
        if (n == 0) break; // EOF

        const cmd = std.mem.trim(u8, command_buf[0..n], " \t\r\n");
        if (cmd.len == 0) continue;
        if (std.mem.eql(u8, cmd, "exit")) break;

        action.execute(allocator, io, store, run_id, seq, cmd, active_mode) catch |err| {
            if (err == error.ActionDenied) {
                try files.writeAllErr("Action denied by policy.\n");
            } else {
                try files.writeAllErr("Command execution failed: ");
                try files.writeAllErr(@errorName(err));
                try files.writeAllErr("\n");
            }
        };
        seq += 1;
    }

    // 6. Settle gives (outputs)
    var gives_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = gives_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        gives_map.deinit();
    }

    if (card.gives.len > 0) {
        try files.writeAllOut("\nResolving outputs (gives):\n");
        for (card.gives) |gives_name| {
            try files.writeAllOut("Output value for `");
            try files.writeAllOut(gives_name);
            try files.writeAllOut("`: ");
            var prompt_buf: [4096]u8 = undefined;
            const bytes_read = try files.readStdin(&prompt_buf);
            const trimmed = std.mem.trim(u8, prompt_buf[0..bytes_read], " \t\r\n");
            try gives_map.put(gives_name, try allocator.dupe(u8, trimmed));
        }
    }

    // 7. Record run finished
    try store.insertRun(runs{
        .id = run_id,
        .doc_id = doc_id,
        .status = "finished",
        .started_at = null,
        .finished_at = std.Io.Clock.now(.real, io).toSeconds(),
    });

    // 8. Return outputs
    try files.writeAllOut("\n========================================\n");
    try files.writeAllOut("Run finished. Outputs:\n");
    var it = gives_map.iterator();
    while (it.next()) |entry| {
        try files.writeAllOut(entry.key_ptr.*);
        try files.writeAllOut(": ");
        try files.writeAllOut(entry.value_ptr.*);
        try files.writeAllOut("\n");
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
