const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the gooey-charts module
    // Note: When used as a dependency, the parent build.zig should provide
    // the "gooey" import via addImport() after getting this module.
    _ = b.addModule("gooey-charts", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests are run from the parent build.zig which provides the gooey module.
    // Standalone testing is not supported since this package depends on gooey.
    const test_step = b.step("test", "Run gooey-charts tests (requires parent build)");
    _ = test_step;
}
