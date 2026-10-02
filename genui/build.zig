const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gooey_dependency = b.dependency("gooey", .{
        .target = target,
        .optimize = optimize,
    });
    const module = b.addModule("gooey-genui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("gooey", gooey_dependency.module("gooey"));
    module.addImport("gooey-components", gooey_dependency.module("gooey-components"));

    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run gooey-genui tests");
    test_step.dependOn(&run_tests.step);
}
