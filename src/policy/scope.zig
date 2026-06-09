const std = @import("std");

pub fn isPathAllowed(raw_path: []const u8, workspace_root: ?[]const u8) bool {
    const root = workspace_root orelse return true;

    if (std.fs.path.isAbsolute(raw_path)) {
        return std.mem.startsWith(u8, raw_path, root);
    }

    var it = std.mem.tokenizeAny(u8, raw_path, "/\\");
    var depth: isize = 0;
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) {
            depth -= 1;
            if (depth < 0) return false;
        } else {
            depth += 1;
        }
    }
    return true;
}

pub fn checkCommandAccess(command: []const u8) struct { writes: bool, outside: bool } {
    var writes = false;
    var outside = false;

    var it = std.mem.tokenizeAny(u8, command, " \t\r\n;&|()<>\"'");
    var is_cmd_head = true;
    while (it.next()) |token| {
        if (std.mem.eql(u8, token, ">") or std.mem.eql(u8, token, ">>")) {
            writes = true;
        }

        if (is_cmd_head) {
            const head = std.fs.path.basename(token);
            if (std.mem.eql(u8, head, "rm") or
                std.mem.eql(u8, head, "mv") or
                std.mem.eql(u8, head, "cp") or
                std.mem.eql(u8, head, "mkdir") or
                std.mem.eql(u8, head, "touch") or
                std.mem.eql(u8, head, "chmod") or
                std.mem.eql(u8, head, "chown") or
                std.mem.eql(u8, head, "rmdir") or
                std.mem.eql(u8, head, "tee") or
                std.mem.eql(u8, head, "dd"))
            {
                writes = true;
            }
            is_cmd_head = false;
        }

        if (std.mem.eql(u8, token, ";") or std.mem.eql(u8, token, "&&") or std.mem.eql(u8, token, "||") or std.mem.eql(u8, token, "|")) {
            is_cmd_head = true;
        }

        if (std.fs.path.isAbsolute(token)) {
            outside = true;
        }
        if (std.mem.indexOf(u8, token, "..") != null) {
            outside = true;
        }
    }

    return .{ .writes = writes, .outside = outside };
}
