//! Child-process check for the scene's fail-fast overflow (CLAUDE.md §2, §24).
//!
//! A full scene pool panics, and a panic cannot be caught inside a test, so the
//! `test` build step runs this program and asserts that it aborts with the
//! documented message: pool name, configured capacity, count in use, requested
//! count, and frame. It fills the quad pool exactly, finishes one frame so the
//! reported frame number is non-trivial, inserts one quad past the budget, and
//! must never reach the end of `main`.

const std = @import("std");
const gooey = @import("gooey");

const Scene = gooey.scene.Scene;
const Quad = gooey.scene.Quad;
const Hsla = gooey.scene.Hsla;

/// Every pool holds 4 primitives except glyphs, which must hold one shaped run.
const overflow_limits: gooey.scene.SceneLimits = .{
    .quad_count_frame_max = 4,
    .shadow_count_frame_max = 4,
    .glyph_count_frame_max = gooey.core.limits.MAX_GLYPHS_PER_RUN,
    .svg_count_frame_max = 4,
    .image_count_frame_max = 4,
    .path_count_frame_max = 4,
    .polyline_count_frame_max = 4,
    .point_cloud_count_frame_max = 4,
    .colored_point_cloud_count_frame_max = 4,
    .clip_depth_max = 4,
};

pub fn main(init: std.process.Init) !void {
    var scene = try Scene.initCapacity(init.gpa, &overflow_limits);
    defer scene.deinit();

    scene.finish();
    scene.clear();

    var count: u32 = 0;
    while (count < overflow_limits.quad_count_frame_max) : (count += 1) {
        try scene.insertQuad(Quad.filled(0, 0, 10, 10, Hsla.red));
    }
    std.debug.assert(scene.quads.items.len == overflow_limits.quad_count_frame_max);

    // One past the budget: must panic inside `insertQuad`.
    try scene.insertQuad(Quad.filled(0, 0, 10, 10, Hsla.red));
    std.debug.print("unreachable: scene accepted a quad past its budget\n", .{});
}
