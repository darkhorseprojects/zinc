const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});

    const circuitry_dep = b.dependency("circuitry", .{ .target = target, .optimize = optimize });
    const sqlite_dep = b.dependency("sqlite", .{ .target = target, .optimize = optimize });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("circuitry", circuitry_dep.module("circuitry"));
    exe_mod.addImport("sqlite", sqlite_dep.module("sqlite"));

    const exe = b.addExecutable(.{
        .name = "zn",
        .root_module = exe_mod,
    });

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
    test_mod.addImport("circuitry", circuitry_dep.module("circuitry"));
    test_mod.addImport("sqlite", sqlite_dep.module("sqlite"));
    const tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
