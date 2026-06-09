const std = @import("std");

pub const Decision = enum { allow, confirm, deny };

pub fn matchPattern(command: []const u8, pattern: []const u8) bool {
    const cmd = std.mem.trim(u8, command, " \t\r\n");
    const pat = std.mem.trim(u8, pattern, " \t\r\n");

    if (std.mem.eql(u8, pat, "*")) return true;

    // Glob prefix matching, e.g. "npm run *" -> matches if command starts with "npm run "
    if (std.mem.endsWith(u8, pat, "*")) {
        const prefix = pat[0 .. pat.len - 1];
        return std.mem.startsWith(u8, cmd, prefix);
    }

    // Prefix match for multi-word patterns like "git status"
    if (std.mem.indexOfScalar(u8, pat, ' ') != null) {
        if (std.mem.eql(u8, cmd, pat)) return true;
        if (std.mem.startsWith(u8, cmd, pat) and cmd.len > pat.len) {
            const next_char = cmd[pat.len];
            return next_char == ' ' or next_char == '\t';
        }
        return false;
    }

    // Command head match
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n;&|()");
    if (it.next()) |head| {
        const base_head = std.fs.path.basename(head);
        return std.mem.eql(u8, base_head, pat) or std.mem.eql(u8, head, pat);
    }
    return false;
}
