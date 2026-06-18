const std = @import("std");

test {
    _ = @import("platform/mod.zig");
    _ = @import("io/fs.zig");
    _ = @import("io/process.zig");
    _ = @import("io/layout.zig");
    _ = @import("substrate.zig");
    _ = @import("package.zig");
    _ = @import("execute.zig");
    _ = @import("update/mod.zig");
    _ = @import("app.zig");
}
