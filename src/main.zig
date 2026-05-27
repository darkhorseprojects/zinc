const std = @import("std");
const cli = @import("cli/main.zig");

pub const std_options = std.Options{ .log_level = .err };

pub fn main(init: std.process.Init) !void {
    return cli.run(init);
}
