const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Automatically detect and set sysroot on macOS hosts for macOS targets if not specified
    if (target.result.os.tag == .macos and b.sysroot == null) {
        if (std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result)) |sdk| {
            b.sysroot = sdk;
        }
    }

    const is_linux = target.result.os.tag == .linux;

    const serde_dep = b.dependency("serde", .{ .target = target, .optimize = optimize });
    const circuitry_dep = b.createModule(.{
        .root_source_file = b.path("../circuitry-zig/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    circuitry_dep.addImport("serde", serde_dep.module("serde"));
    const limbo_dep = b.createModule(.{
        .root_source_file = b.path("../limbo-zig/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    limbo_dep.addIncludePath(b.path("../limbo-zig/include"));
    const limbo_lib = b.path("../limbo-zig/lib/x86_64-linux/libturso_sqlite3.a");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("circuitry", circuitry_dep);
    exe_mod.addImport("limbo", limbo_dep);
    exe_mod.addImport("serde", serde_dep.module("serde"));

    const exe = b.addExecutable(.{
        .name = "zn",
        .root_module = exe_mod,
    });
    exe.root_module.addObjectFile(limbo_lib);
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("unwind", .{});
    if (is_linux) {
        exe.use_llvm = true;
        exe.use_lld = true;
    } else if (target.result.os.tag == .windows) {
        exe.bundle_compiler_rt = false;
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zn");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("circuitry", circuitry_dep);
    test_mod.addImport("limbo", limbo_dep);
    test_mod.addImport("serde", serde_dep.module("serde"));
    const tests = b.addTest(.{ .root_module = test_mod });
    tests.root_module.addObjectFile(limbo_lib);
    tests.root_module.link_libc = true;
    tests.root_module.linkSystemLibrary("unwind", .{});
    if (is_linux) {
        tests.use_llvm = true;
        tests.use_lld = true;
    } else if (target.result.os.tag == .windows) {
        tests.bundle_compiler_rt = false;
    }
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
