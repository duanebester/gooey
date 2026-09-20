const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the gooey-genui module. The parent Gooey build supplies the
    // "gooey" and "gooey-components" imports so all packages share one Gooey
    // module instance and therefore one set of public types.
    _ = b.addModule("gooey-genui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests run from Gooey's parent build, which owns platform linking and
    // injects both modules required by renderer.zig.
    _ = b.step("test", "Run gooey-genui tests (requires parent build)");
}
