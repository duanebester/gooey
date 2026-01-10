const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get gooey dependency from parent
    const gooey_dep = b.dependency("gooey", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the gooey-charts module
    const charts_mod = b.addModule("gooey-charts", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gooey", .module = gooey_dep.module("gooey") },
        },
    });

    // Tests - use root_module API for Zig 0.15
    const tests = b.addTest(.{
        .root_module = charts_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run gooey-charts tests");
    test_step.dependOn(&run_tests.step);
}
