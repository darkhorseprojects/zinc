const std = @import("std");
const app = @import("app.zig");
const files = @import("io/fs.zig");

pub fn main(init: std.process.Init) void {
    app.run(init) catch |err| {
        if (!isReported(err)) {
            files.writeAllErr("error: ") catch {};
            files.writeAllErr(@errorName(err)) catch {};
            files.writeAllErr("\n") catch {};
        }
        std.process.exit(1);
    };
}

fn isReported(err: anyerror) bool {
    return switch (err) {
        error.InvalidUsage,
        error.InvalidRunInput,
        error.MissingRunInput,
        error.InvalidInputValue,
        error.InvalidAssignmentExpression,
        error.CircuitryShapeNotReady,
        => true,
        else => false,
    };
}
