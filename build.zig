const std = @import("std");

fn tursoSdkLib(b: *std.Build) std.Build.LazyPath {
    const cargo_cmd = b.addSystemCommand(&.{ "cargo", "build", "--release", "-p", "turso_sdk_kit" });
    cargo_cmd.setCwd(b.path("../limbo-zig/third_party/limbo"));

    const wf = b.addWriteFiles();
    wf.step.dependOn(&cargo_cmd.step);
    return wf.addCopyFile(b.path("../limbo-zig/third_party/limbo/target/release/libturso_sdk_kit.a"), "libturso_sdk_kit.a");
}

fn linkLimboSupport(mod: *std.Build.Module, b: *std.Build, sdk_lib: std.Build.LazyPath) void {
    mod.addIncludePath(b.path("../limbo-zig/src"));
    mod.addIncludePath(b.path("../limbo-zig/third_party/limbo/sdk-kit"));
    mod.addCSourceFile(.{ .file = b.path("../limbo-zig/src/turso_shim.c"), .flags = &.{}, .language = .c });
    mod.addObjectFile(sdk_lib);
    mod.link_libc = true;
    mod.linkSystemLibrary("pthread", .{});
    mod.linkSystemLibrary("dl", .{});
    mod.linkSystemLibrary("m", .{});
    mod.linkSystemLibrary("unwind", .{});
}

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
    const limbo_dep = b.createModule(.{ .root_source_file = b.path("../limbo-zig/src/lib.zig"), .target = target, .optimize = optimize });
    const sdk_lib = tursoSdkLib(b);

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
    linkLimboSupport(exe.root_module, b, sdk_lib);
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
    linkLimboSupport(tests.root_module, b, sdk_lib);
    if (is_linux) {
        tests.use_llvm = true;
        tests.use_lld = true;
    } else if (target.result.os.tag == .windows) {
        tests.bundle_compiler_rt = false;
    }
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
