const std = @import("std");
const app = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    return app.run(init);
}
