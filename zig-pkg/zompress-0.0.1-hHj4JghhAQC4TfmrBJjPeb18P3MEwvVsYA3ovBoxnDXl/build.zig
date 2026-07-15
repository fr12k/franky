const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Export the module under the name "zompress" so that dependents
    // can call `zompress_dep.module("zompress")` to import it.
    _ = b.addModule("zompress", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zompress",
        .root_module = lib_mod,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zompress",
        .root_module = exe_mod,
    });

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_bin = b.addTest(.{
        .name = "zompress-tests",
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(test_bin);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    b.installArtifact(lib);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
