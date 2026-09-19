const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the gooey-genui module. As with gooey-charts, consumers of this
    // sub-package provide the "gooey" import from the parent Gooey dependency.
    _ = b.addModule("gooey-genui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests run from Gooey's parent build, which owns platform linking and
    // injects the gooey module required by renderer.zig.
    _ = b.step("test", "Run gooey-genui tests (requires parent build)");
}
