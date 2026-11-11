//! The 0.3.1 `Scene` filled from a packed frame, for the renderers that do
//! not draw the packed frame yet (Vulkan, WebGPU, and the CPU renderer).
//!
//! Phase 5 moves one backend at a time onto the `Renderer` contract; until a
//! backend moves, its host calls `fillScene` before drawing. The result is the
//! scene 0.3.1's pack wrote from the same records: clips intersect from the
//! scene's own root, shadows stay unclipped, and quads outside their clip are
//! culled again by the scene. Phase 6 deletes this file with the scene.
//!
//! Performance sketch (CLAUDE.md §7): one pass over the draws and one scene
//! insert per instance, the work 0.3.1's pack did; triangle meshes copy their
//! points into the scene's frame meshes once more.

const std = @import("std");
const packed_mod = @import("packed_frame.zig");
const scene_mod = @import("../scene/mod.zig");

const assert = std.debug.assert;

const PackedFrame = packed_mod.PackedFrame;
const Scene = scene_mod.Scene;
const Hsla = scene_mod.Hsla;

/// Viewport in logical pixels, as the scene records it.
pub const Viewport = struct { width: f32, height: f32 };

pub fn fillScene(source: *const PackedFrame, scene: *Scene, viewport: Viewport) void {
    assert(viewport.width >= 0);
    assert(source.clip_count >= 1);
    scene.clear();
    scene.viewport_width = viewport.width;
    scene.viewport_height = viewport.height;
    scene.frame_count_finished = source.frame_number -| 1;
    for (source.drawList()) |*draw| {
        setClip(scene, source, draw.clip);
        switch (draw.pipeline.kind()) {
            .quad => for (source.drawRange(draw, .quad)) |*quad| insertQuad(scene, quad),
            .sprite => for (source.drawRange(draw, .sprite)) |*sprite| {
                insertSprite(scene, draw.pipeline, sprite);
            },
            .mesh => for (source.drawRange(draw, .mesh)) |*mesh| {
                insertMesh(scene, source, draw.pipeline, mesh);
            },
        }
    }
    setClip(scene, source, packed_mod.clip_none);
    scene.finish();
    assert(!scene.hasActiveClip());
}

/// Make `clip` the scene's only clip. The scene intersects it with its own
/// root, as 0.3.1's pack did with every push.
fn setClip(scene: *Scene, source: *const PackedFrame, clip: u32) void {
    assert(clip < source.clip_count);
    while (scene.hasActiveClip()) scene.popClip();
    if (clip == packed_mod.clip_none) return;
    const rect = source.clips[clip];
    scene.pushClip(.{ .x = rect[0], .y = rect[1], .width = rect[2], .height = rect[3] }) catch |err|
        failed(source, err);
    assert(scene.hasActiveClip());
}

fn hsla(color: packed_mod.Rgba) Hsla {
    return Hsla.fromColor(.{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] });
}

fn corners(radii: [4]f32) scene_mod.Corners {
    return .{
        .top_left = radii[0],
        .top_right = radii[1],
        .bottom_right = radii[2],
        .bottom_left = radii[3],
    };
}

fn insertQuad(scene: *Scene, quad: *const packed_mod.Quad) void {
    assert(quad.blur >= 0);
    const b = quad.bounds;
    if (quad.blur > 0) {
        scene.insertShadow(.{
            .content_origin_x = b[0],
            .content_origin_y = b[1],
            .content_size_width = b[2],
            .content_size_height = b[3],
            .blur_radius = quad.blur,
            .color = hsla(quad.fill),
            .offset_x = quad.offset[0],
            .offset_y = quad.offset[1],
            .corner_radii = corners(quad.corners),
        }) catch |err| std.debug.panic("pack_legacy: {t}", .{err});
        return;
    }
    const w = quad.border_widths;
    const legacy = scene_mod.Quad{
        .bounds_origin_x = b[0],
        .bounds_origin_y = b[1],
        .bounds_size_width = b[2],
        .bounds_size_height = b[3],
        .background = hsla(quad.fill),
        .border_color = hsla(quad.border_color),
        .corner_radii = corners(quad.corners),
        .border_widths = .{ .top = w[0], .right = w[1], .bottom = w[2], .left = w[3] },
    };
    const inserted = if (scene.hasActiveClip())
        scene.insertQuadClipped(legacy)
    else
        scene.insertQuad(legacy);
    inserted catch |err| std.debug.panic("pack_legacy: {t}", .{err});
}

fn insertSprite(
    scene: *Scene,
    pipeline: packed_mod.Pipeline,
    sprite: *const packed_mod.Sprite,
) void {
    const b = sprite.bounds;
    const uv = sprite.uv;
    assert(b[2] >= 0);
    switch (pipeline) {
        .glyph => {
            const glyph = scene_mod.GlyphInstance.init(
                b[0],
                b[1],
                b[2],
                b[3],
                uv[0],
                uv[1],
                uv[2],
                uv[3],
                hsla(sprite.tint),
            );
            const inserted = if (scene.hasActiveClip())
                scene.insertGlyphClipped(glyph)
            else
                scene.insertGlyph(glyph);
            inserted catch |err| std.debug.panic("pack_legacy: {t}", .{err});
        },
        .svg => {
            const instance = scene_mod.SvgInstance.init(
                b[0],
                b[1],
                b[2],
                b[3],
                uv[0],
                uv[1],
                uv[2],
                uv[3],
                hsla(sprite.tint),
                hsla(sprite.secondary),
            );
            scene.insertSvgClipped(instance) catch |err| {
                std.debug.panic("pack_legacy: {t}", .{err});
            };
        },
        .image => {
            const c = sprite.corners;
            const instance = scene_mod.ImageInstance.init(
                b[0],
                b[1],
                b[2],
                b[3],
                uv[0],
                uv[1],
                uv[2],
                uv[3],
            ).withTint(hsla(sprite.tint))
                .withOpacity(sprite.opacity)
                .withGrayscale(sprite.grayscale)
                .withCornerRadii(c[0], c[1], c[2], c[3]);
            scene.insertImageClipped(instance) catch |err| {
                std.debug.panic("pack_legacy: {t}", .{err});
            };
        },
        .quad, .triangles, .strip_expanded, .point_instanced => unreachable,
    }
}

/// A triangle mesh becomes one 0.3.1 path; polylines and point clouds point
/// the scene at the records frame's points, which stay put until the draw.
fn insertMesh(
    scene: *Scene,
    source: *const PackedFrame,
    pipeline: packed_mod.Pipeline,
    mesh: *const packed_mod.Mesh,
) void {
    const points = source.meshPoints(mesh);
    const color = hsla(mesh.fill);
    assert(points.len > 0);
    switch (pipeline) {
        .triangles => {
            var path = scene_mod.PathMesh.init();
            fillPathMesh(&path, points);
            scene.insertPathWithMesh(path, 0, 0, color) catch |err| failed(source, err);
        },
        .strip_expanded => {
            const line = scene_mod.Polyline.init(points, mesh.width, color);
            scene.insertPolylineClipped(line) catch |err| failed(source, err);
        },
        .point_instanced => {
            const cloud = scene_mod.PointCloud.init(points, mesh.width, color);
            scene.insertPointCloudClipped(cloud) catch |err| failed(source, err);
        },
        .quad, .glyph, .svg, .image => unreachable,
    }
}

/// One vertex per point and one index per vertex, with UVs across the bounds
/// as the 0.3.1 triangle inserts set them.
fn fillPathMesh(path: *scene_mod.PathMesh, points: []const packed_mod.MeshPoint) void {
    assert(points.len % 3 == 0);
    assert(points.len <= scene_mod.MAX_MESH_VERTICES);
    var min_x = points[0].x;
    var min_y = points[0].y;
    var max_x = points[0].x;
    var max_y = points[0].y;
    for (points) |point| {
        min_x = @min(min_x, point.x);
        min_y = @min(min_y, point.y);
        max_x = @max(max_x, point.x);
        max_y = @max(max_y, point.y);
    }
    const width = if (max_x > min_x) max_x - min_x else 1;
    const height = if (max_y > min_y) max_y - min_y else 1;
    for (points, 0..) |point, index| {
        const u = (point.x - min_x) / width;
        const v = (point.y - min_y) / height;
        path.vertices.appendAssumeCapacity(scene_mod.PathVertex.withUV(point.x, point.y, u, v));
        path.indices.appendAssumeCapacity(@intCast(index));
    }
    path.bounds = scene_mod.Bounds.init(min_x, min_y, width, height);
}

fn failed(source: *const PackedFrame, err: anyerror) noreturn {
    std.debug.panic("pack_legacy failed in frame {d}: {t}", .{ source.frame_number, err });
}
