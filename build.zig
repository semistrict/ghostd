const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 15) {
        @panic("ghostd requires Zig 0.15.2; run `sh scripts/zig-015.sh build` or put Zig 0.15.x first on PATH");
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.lazyDependency("ghostty", .{})) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "ghostd",
        .root_module = exe_mod,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const run_step = b.step("run", "Run ghostd");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
