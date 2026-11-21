const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // When used as a dependency, the parent build.zig provides the "gooey"
    // import.
    _ = b.addModule("gooey-charts", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests run from the parent build.zig, which provides the gooey module.
    const test_step = b.step("test", "Run gooey-charts tests (requires parent build)");
    _ = test_step;
}
