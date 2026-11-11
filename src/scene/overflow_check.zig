//! Child-process check for fail-fast pool overflow (CLAUDE.md §2, §24).
//!
//! A full pool panics, and a panic cannot be caught inside a test, so the `test`
//! build step runs this program and asserts that it aborts with the documented
//! message: pool name, configured capacity, count in use, requested count, and
//! frame. Each mode fills one pool exactly, verifies the last valid claim, then
//! claims one past the budget and must never reach the end of `main`.
//!
//! Modes (first argument; default `scene`):
//! - `scene`: fills the scene's quad pool, finishes one frame so the reported
//!   frame number is non-trivial, and inserts one more quad. Every OS.
//! - `scene-<profile>`: the same at a named rung (`nano` through `ceiling`), so
//!   every profile's quad capacity is exact: 256 at `nano` up to 65,536.
//! - `instances-<pool>`: fills a renderer's glyph, SVG or image instance budget
//!   (`gooey.internals.scene.InstanceCounts`; Metal claimed it until it moved to the
//!   packed frame in phase 5, and phase 6 deletes it) with two batches and claims one
//!   more. Every OS.
//! - `cpu-atlas`: draws a frame holding one glyph through the CPU renderer with
//!   no glyph atlas bound, which must panic rather than drop the glyph. Linux.

const std = @import("std");
const builtin = @import("builtin");
const gooey = @import("gooey");

const Scene = gooey.internals.scene.Scene;
const Quad = gooey.internals.scene.Quad;
const Hsla = gooey.internals.scene.Hsla;

/// Every pool holds 4 primitives except glyphs, which must hold one shaped run.
const overflow_limits: gooey.internals.scene.SceneLimits = .{
    .quad_count_frame_max = 4,
    .shadow_count_frame_max = 4,
    .glyph_count_frame_max = gooey.internals.limits.MAX_GLYPHS_PER_RUN,
    .svg_count_frame_max = 4,
    .image_count_frame_max = 4,
    .path_count_frame_max = 4,
    .polyline_count_frame_max = 4,
    .point_cloud_count_frame_max = 4,
    .colored_point_cloud_count_frame_max = 4,
    .path_vertex_count_frame_max = 7,
    .path_index_count_frame_max = 11,
    .polyline_point_count_frame_max = 13,
    .point_count_frame_max = 17,
    .colored_point_count_frame_max = 19,
    .clip_depth_max = 4,
};

const Mode = enum {
    scene,
    @"scene-nano",
    @"scene-small",
    @"scene-standard",
    @"scene-large",
    @"scene-ceiling",
    @"geometry-path_vertices",
    @"geometry-path_indices",
    @"geometry-polyline_points",
    @"geometry-points",
    @"geometry-colored_points",
    @"instances-glyphs",
    @"instances-svgs",
    @"instances-images",
    @"cpu-atlas",
};

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    std.debug.assert(args.len >= 1);
    std.debug.assert(args.len <= 2);

    const mode: Mode = if (args.len == 2)
        std.meta.stringToEnum(Mode, std.mem.span(args[1])) orelse return error.UnknownMode
    else
        .scene;
    switch (mode) {
        .scene => try overflowScene(init.gpa, &overflow_limits),
        inline .@"scene-nano",
        .@"scene-small",
        .@"scene-standard",
        .@"scene-large",
        .@"scene-ceiling",
        => |profile| {
            const name = comptime @tagName(profile)["scene-".len..];
            try overflowScene(init.gpa, &@field(gooey.ResourceLimits, name).scene);
        },
        .@"cpu-atlas" => try cpuMissingAtlas(init.gpa),
        .@"instances-glyphs", .@"instances-svgs", .@"instances-images" => overflow_instances(mode),
        else => overflow_geometry(mode),
    }
    std.debug.print("unreachable: {s} accepted a claim past its budget\n", .{@tagName(mode)});
}

fn overflowScene(gpa: std.mem.Allocator, limits: *const gooey.internals.scene.SceneLimits) !void {
    var scene = try Scene.initCapacity(gpa, limits);
    defer scene.deinit();

    scene.finish();
    scene.clear();

    var count: u32 = 0;
    while (count < limits.quad_count_frame_max) : (count += 1) {
        try scene.insertQuad(Quad.filled(0, 0, 10, 10, Hsla.red));
    }
    std.debug.assert(scene.quads.items.len == limits.quad_count_frame_max);

    // One past the budget: must panic inside `insertQuad`.
    try scene.insertQuad(Quad.filled(0, 0, 10, 10, Hsla.red));
}

fn cpuMissingAtlas(gpa: std.mem.Allocator) !void {
    if (builtin.os.tag == .linux) {
        const cpu = gooey.internals.platform.linux.cpu;
        const limits = gooey.ResourceLimits{
            .scene = overflow_limits,
            .window = .{ .framebuffer_width_max = 8, .framebuffer_height_max = 8 },
            .frame = gooey.ResourceLimits.nano.frame,
            .atlas = gooey.ResourceLimits.standard.atlas,
            .build = gooey.ResourceLimits.nano.build,
            .records = gooey.ResourceLimits.nano.records,
            .retained = gooey.ResourceLimits.nano.retained,
            .events = gooey.ResourceLimits.nano.events,
            .text = gooey.ResourceLimits.nano.text,
            .entities = gooey.ResourceLimits.nano.entities,
        };
        var scene = try Scene.initCapacity(gpa, &limits.scene);
        defer scene.deinit();
        scene.finish();
        scene.clear();
        const glyph = gooey.internals.scene.GlyphInstance.init(0, 0, 4, 4, 0, 0, 1, 1, Hsla.black);
        try scene.insertGlyph(glyph);

        var renderer: cpu.Renderer = undefined;
        try renderer.initInPlace(gpa, &limits);
        defer renderer.deinit(gpa);
        var pixels: [8 * 8]u32 = undefined;
        const target = cpu.raster.Target{ .pixels = &pixels, .width = 8, .height = 8, .stride = 8 };
        const clear = gooey.internals.geometry.Color.rgba(0, 0, 0, 1);
        // No atlas is bound: must panic inside `draw`.
        _ = renderer.draw(target, &scene, .{ .scale_factor = 1 }, clear);
    } else {
        std.debug.panic("cpu-atlas mode exists only on Linux", .{});
    }
}

fn overflow_geometry(mode: Mode) void {
    // Two claims fill each aggregate exactly; the next element must abort even
    // though the draw count is still below its independently configured limit.
    const name = @tagName(mode)["geometry-".len..];
    const pool = std.meta.stringToEnum(gooey.internals.scene.GeometryPool, name).?;
    const budget = gooey.internals.scene.GeometryCounts.from_limits(&overflow_limits);
    const capacity = budget.counts[@backingInt(pool)];
    std.debug.assert(capacity >= 7);
    std.debug.assert(capacity <= 19);
    var usage = gooey.internals.scene.GeometryCounts{};
    usage.claim(&budget, .{ .pool = pool, .requested = capacity - 2, .frame = 7 });
    usage.claim(&budget, .{ .pool = pool, .requested = 2, .frame = 7 });
    usage.claim(&budget, .{ .pool = pool, .requested = 1, .frame = 7 });
}

fn overflow_instances(mode: Mode) void {
    // Two batches fill a renderer instance buffer sized from the scene budget
    // exactly, as two draw batches in one frame would; one more instance aborts.
    const name = @tagName(mode)["instances-".len..];
    const pool = std.meta.stringToEnum(gooey.internals.scene.InstancePool, name).?;
    const budget = gooey.internals.scene.InstanceCounts.from_limits(&overflow_limits);
    const capacity = budget.counts[@backingInt(pool)];
    std.debug.assert(capacity >= 4);
    std.debug.assert(capacity <= gooey.internals.limits.MAX_GLYPHS_PER_RUN);
    var usage = gooey.internals.scene.InstanceCounts{};
    const first = usage.claim(&budget, .{ .pool = pool, .requested = capacity - 1, .frame = 7 });
    const last = usage.claim(&budget, .{ .pool = pool, .requested = 1, .frame = 7 });
    std.debug.assert(first == 0);
    std.debug.assert(last == capacity - 1);
    _ = usage.claim(&budget, .{ .pool = pool, .requested = 1, .frame = 7 });
}
