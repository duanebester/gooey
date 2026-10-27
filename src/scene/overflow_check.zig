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
//! - `vulkan-instances`: sizes the Vulkan renderer's instance buffers from the
//!   same budget, fills the shared quad + shadow primitive buffer exactly with a
//!   quad batch and a shadow batch (as `drawScene` does), and claims one more.
//!   Linux only; it needs no GPU because the capacity check is pure.
//! - `cpu-atlas`: draws a frame holding one glyph through the CPU renderer with
//!   no glyph atlas bound, which must panic rather than drop the glyph. Linux.

const std = @import("std");
const builtin = @import("builtin");
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
    .path_vertex_count_frame_max = 7,
    .path_index_count_frame_max = 11,
    .polyline_point_count_frame_max = 13,
    .point_count_frame_max = 17,
    .colored_point_count_frame_max = 19,
    .clip_depth_max = 4,
};

const Mode = enum {
    scene,
    @"vulkan-instances",
    triangles,
    strip_expanded,
    points,
    colored_points,
    @"geometry-path_vertices",
    @"geometry-path_indices",
    @"geometry-polyline_points",
    @"geometry-points",
    @"geometry-colored_points",
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
        .scene => try overflowScene(init.gpa),
        .@"vulkan-instances" => overflowVulkanInstances(),
        .triangles, .strip_expanded, .points, .colored_points => overflow_vulkan_mesh(mode),
        .@"cpu-atlas" => try cpuMissingAtlas(init.gpa),
        else => overflow_geometry(mode),
    }
    std.debug.print("unreachable: {s} accepted a claim past its budget\n", .{@tagName(mode)});
}

fn overflowScene(gpa: std.mem.Allocator) !void {
    var scene = try Scene.initCapacity(gpa, &overflow_limits);
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
}

fn overflowVulkanInstances() void {
    if (builtin.os.tag == .linux) {
        const vk_types = gooey.platform.linux.vk_renderer.vk_types;
        const capacity = vk_types.InstanceCapacity.fromSceneLimits(&overflow_limits);
        const quad_count = overflow_limits.quad_count_frame_max;
        const shadow_count = overflow_limits.shadow_count_frame_max;
        const frame: u64 = 1;
        std.debug.assert(capacity.primitive_count_max == quad_count + shadow_count);

        // A quad batch then a shadow batch exactly fill the shared primitive buffer.
        capacity.reserve(.primitives, 0, quad_count, frame);
        capacity.reserve(.primitives, quad_count, shadow_count, frame);
        std.debug.assert(!capacity.fits(.primitives, quad_count + shadow_count, 1));

        // One past the budget: must panic inside `reserve`.
        capacity.reserve(.primitives, quad_count + shadow_count, 1, frame);
    } else {
        std.debug.panic("vulkan-instances mode exists only on Linux", .{});
    }
}

fn cpuMissingAtlas(gpa: std.mem.Allocator) !void {
    if (builtin.os.tag == .linux) {
        const cpu = gooey.platform.linux.cpu;
        const limits = gooey.ResourceLimits{
            .scene = overflow_limits,
            .window = .{ .framebuffer_width_max = 8, .framebuffer_height_max = 8 },
        };
        var scene = try Scene.initCapacity(gpa, &limits.scene);
        defer scene.deinit();
        scene.finish();
        scene.clear();
        const glyph = gooey.scene.GlyphInstance.init(0, 0, 4, 4, 0, 0, 1, 1, Hsla.black);
        try scene.insertGlyph(glyph);

        var renderer: cpu.Renderer = undefined;
        try renderer.initInPlace(gpa, &limits);
        defer renderer.deinit(gpa);
        var pixels: [8 * 8]u32 = undefined;
        const target = cpu.raster.Target{ .pixels = &pixels, .width = 8, .height = 8, .stride = 8 };
        const clear = gooey.core.geometry.Color.rgba(0, 0, 0, 1);
        // No atlas is bound: must panic inside `draw`.
        _ = renderer.draw(target, &scene, .{ .scale_factor = 1 }, clear);
    } else {
        std.debug.panic("cpu-atlas mode exists only on Linux", .{});
    }
}

fn overflow_vulkan_mesh(mode: Mode) void {
    // Fill every slot, including the last valid one, before the extra claim.
    // Distinct capacities catch accidental sharing of the two point draw pools.
    if (builtin.os.tag == .linux) {
        const types = gooey.platform.linux.vk_renderer.vk_types;
        var limits = overflow_limits;
        limits.path_count_frame_max = 1;
        limits.polyline_count_frame_max = 2;
        limits.point_cloud_count_frame_max = 3;
        const capacity = types.MeshCapacity.from_scene_limits(&limits);
        const pool = std.meta.stringToEnum(types.MeshPool, @tagName(mode)).?;
        const count = capacity.counts[@backingInt(pool)];
        std.debug.assert(count >= 1);
        std.debug.assert(count <= 4);
        for (0..count) |index| capacity.reserve(pool, @intCast(index), 7);
        capacity.reserve(pool, count, 7);
    } else {
        std.debug.panic("Vulkan mesh overflow checks exist only on Linux", .{});
    }
}

fn overflow_geometry(mode: Mode) void {
    // Two claims fill each aggregate exactly; the next element must abort even
    // though the draw count is still below its independently configured limit.
    const name = @tagName(mode)["geometry-".len..];
    const pool = std.meta.stringToEnum(gooey.scene.GeometryPool, name).?;
    const budget = gooey.scene.GeometryCounts.from_limits(&overflow_limits);
    const capacity = budget.counts[@backingInt(pool)];
    std.debug.assert(capacity >= 7);
    std.debug.assert(capacity <= 19);
    var usage = gooey.scene.GeometryCounts{};
    usage.claim(&budget, .{ .pool = pool, .requested = capacity - 2, .frame = 7 });
    usage.claim(&budget, .{ .pool = pool, .requested = 2, .frame = 7 });
    usage.claim(&budget, .{ .pool = pool, .requested = 1, .frame = 7 });
}
