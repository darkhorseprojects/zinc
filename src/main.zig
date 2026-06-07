const std = @import("std");
const app = @import("app.zig");

pub const std_options = std.Options{ .log_level = .err };

pub fn main(init: std.process.Init) !void {
    return app.run(init);
}
