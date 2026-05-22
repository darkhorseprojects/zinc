const std = @import("std");

pub const ToolSpec = struct {
    name: []const u8,
    schema: []const u8,
};

pub const builtin = [_]ToolSpec{
    .{ .name = "read", .schema = "{\"type\":\"function\",\"function\":{\"name\":\"read\",\"description\":\"Read a UTF-8 file from the current working directory.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}}" },
    .{ .name = "write", .schema = "{\"type\":\"function\",\"function\":{\"name\":\"write\",\"description\":\"Create or overwrite a UTF-8 file.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}}}" },
    .{ .name = "edit", .schema = "{\"type\":\"function\",\"function\":{\"name\":\"edit\",\"description\":\"Replace exact text in a UTF-8 file. The old text must occur exactly once.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"oldText\":{\"type\":\"string\"},\"newText\":{\"type\":\"string\"}},\"required\":[\"path\",\"oldText\",\"newText\"]}}}" },
    .{ .name = "bash", .schema = "{\"type\":\"function\",\"function\":{\"name\":\"bash\",\"description\":\"Run a shell command in the current working directory.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}}}" },
    .{ .name = "request_circuitry_run", .schema = "{\"type\":\"function\",\"function\":{\"name\":\"request_circuitry_run\",\"description\":\"Request root/user approval to run another Circuitry graph. Does not execute recursively by itself.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"reason\":{\"type\":\"string\"},\"graph\":{\"type\":\"string\"},\"inputs\":{\"type\":\"object\"},\"expected_result\":{\"type\":\"string\"},\"risk\":{\"type\":\"string\"}},\"required\":[\"reason\",\"graph\",\"expected_result\",\"risk\"]}}}" },
};

pub fn find(name: []const u8) ?ToolSpec {
    for (builtin) |tool| if (std.mem.eql(u8, tool.name, name)) return tool;
    return null;
}

pub fn contains(name: []const u8) bool {
    return find(name) != null;
}

test "registry owns builtin tool names" {
    try std.testing.expect(contains("read"));
    try std.testing.expect(contains("request_circuitry_run"));
    try std.testing.expect(!contains("circuitry_run"));
}
