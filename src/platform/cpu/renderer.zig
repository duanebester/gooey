//! CPU renderer: draws a packed frame (`core/packed_frame.zig`) into a
//! caller-owned `Target`.
//!
//! The software counterpart of the Vulkan renderer: it walks the frame's
//! draws in order and draws every pipeline the GPU renderers draw (quads and
//! shadows, glyph, SVG and image sprites, triangle meshes, polylines, and
//! point clouds). There is no pipeline it skips. Each draw writes only the
//! pixels whose centres lie inside its clip rectangle, edges included
//! (contract §9), shadows too.
//!
//! The pixels belong to the presenter (a Wayland shared-memory buffer or the
//! fbdev back buffer), so `draw` takes the frame's `Target`. Atlases are read
//! in place from their CPU-side storage; binding them is a pointer store. The
//! renderer itself owns only raster scratch, reserved by `initInPlace` from the
//! application's `ResourceLimits` and never resized (CLAUDE.md §2).
//!
//! ## Resource sketch (CLAUDE.md §7)
//!
//! - Memory: the shadow row profile (4 B per framebuffer column) and the mesh
//!   scratch (`mesh.zig`), about 420 KiB at `.standard` limits. The target is
//!   the presenter's (4 B per pixel) and the atlases are the text, SVG, and
//!   image systems' own.
//! - CPU: one clear pass, then one pass per instance over its clipped
//!   bounding box. Interior spans of quads and shadows are filled with
//!   `@memset` or a single-color blend; only edge and corner pixels evaluate
//!   the distance function, sprites take one bilinear sample per covered
//!   pixel, and meshes shade each covered pixel once per mesh.
//! - Worst case per frame: `width * height * (1 + overdraw)` pixel writes for
//!   the packed frame's instance capacities, plus mesh work bounded by the
//!   scene's mesh point budgets, which the frame build enforces. A 1280x800
//!   frame with 3x overdraw is roughly 4 M pixel writes, a few milliseconds
//!   on one desktop core.
//! - GPU, disk, and network: none.

const std = @import("std");
const geometry = @import("../../geometry/geometry.zig");
const limits_mod = @import("../../core/limits.zig");
const packed_mod = @import("../../core/packed_frame.zig");
const scene_mod = @import("../../scene/mod.zig");
const text_atlas_mod = @import("../../text/atlas.zig");
pub const raster = @import("raster.zig");
pub const mesh = @import("mesh.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Atlas = text_atlas_mod.Atlas;
const Target = raster.Target;
const PackedFrame = packed_mod.PackedFrame;

/// Device scale factors above this are treated as a programmer error. The
/// bound keeps every logical-to-device product finite and well inside `f32`.
pub const scale_factor_max: f32 = 8.0;

/// Per-frame drawing parameters besides the frame and the target.
pub const Viewport = struct {
    /// Device pixels per logical pixel.
    scale_factor: f32,
};

/// What this renderer can do beyond quads and sprites.
pub const Capabilities = struct {
    /// Triangle meshes, polylines, and point clouds, drawn by `mesh.zig`.
    meshes: bool,
};

/// The atlases sprites sample. A frame holding glyph, SVG, or image sprites
/// must have the matching atlas bound.
pub const Atlases = struct {
    /// Glyph coverage atlas (grayscale).
    text: ?*const Atlas = null,
    /// SVG fill and stroke coverage atlas (RGBA).
    svg: ?*const Atlas = null,
    /// Image atlas (straight-alpha RGBA).
    image: ?*const Atlas = null,
};

/// Instances drawn in one frame, for profiling and tests.
pub const RenderStats = struct {
    shadows: u32 = 0,
    quads: u32 = 0,
    glyphs: u32 = 0,
    svgs: u32 = 0,
    images: u32 = 0,
    triangle_meshes: u32 = 0,
    polylines: u32 = 0,
    point_clouds: u32 = 0,
};

pub const Renderer = struct {
    width_max: u32,
    height_max: u32,
    /// One straight-row shadow color per framebuffer column.
    shadow_profile: []raster.Premul,
    mesh_scratch: mesh.Scratch,
    atlases: Atlases,

    /// Reserve every byte of raster scratch for the budget's largest
    /// framebuffer and largest single mesh.
    pub fn initInPlace(
        self: *Renderer,
        gpa: Allocator,
        limits: *const limits_mod.ResourceLimits,
    ) !void {
        assert(limits.check() == null);
        const width_max = limits.window.framebuffer_width_max;
        const height_max = limits.window.framebuffer_height_max;
        const polygon_count_max = polygonCountMax(&limits.scene);

        const shadow_profile = try gpa.alloc(raster.Premul, width_max);
        errdefer gpa.free(shadow_profile);

        const polygons = try gpa.alloc(mesh.Polygon, polygon_count_max);
        errdefer gpa.free(polygons);

        const next = try gpa.alloc(u32, polygon_count_max);
        errdefer gpa.free(next);

        const active = try gpa.alloc(u32, polygon_count_max);
        errdefer gpa.free(active);

        const heads = try gpa.alloc(u32, height_max);
        errdefer gpa.free(heads);

        const mask = try gpa.alloc(u8, width_max);
        errdefer gpa.free(mask);

        @memset(mask, 0);
        self.* = .{
            .width_max = width_max,
            .height_max = height_max,
            .shadow_profile = shadow_profile,
            .mesh_scratch = .{
                .polygons = polygons,
                .next = next,
                .active = active,
                .heads = heads,
                .mask = mask,
            },
            .atlases = .{},
        };
        assert(self.mesh_scratch.mask.len == width_max);
        assert(self.mesh_scratch.heads.len == height_max);
    }

    pub fn deinit(self: *Renderer, gpa: Allocator) void {
        assert(self.shadow_profile.len == self.width_max);
        assert(self.mesh_scratch.heads.len == self.height_max);
        gpa.free(self.mesh_scratch.mask);
        gpa.free(self.mesh_scratch.heads);
        gpa.free(self.mesh_scratch.active);
        gpa.free(self.mesh_scratch.next);
        gpa.free(self.mesh_scratch.polygons);
        gpa.free(self.shadow_profile);
        self.* = undefined;
    }

    /// Publish the atlases the next frames sample. They are read in place,
    /// so there is nothing to upload.
    pub fn bindAtlases(self: *Renderer, atlases: Atlases) void {
        if (atlases.text) |atlas| assert(atlas.format == .grayscale);
        if (atlases.svg) |atlas| assert(atlas.format == .rgba);
        if (atlases.image) |atlas| assert(atlas.format == .rgba);
        self.atlases = atlases;
    }

    pub fn capabilities(self: *const Renderer) Capabilities {
        assert(self.width_max > 0);
        assert(self.height_max > 0);
        return .{ .meshes = true };
    }

    /// Clear `target` and draw every draw of `frame` in order.
    pub fn draw(
        self: *Renderer,
        target: Target,
        frame: *const PackedFrame,
        viewport: Viewport,
        clear: geometry.Color,
    ) RenderStats {
        assert(viewport.scale_factor > 0);
        assert(viewport.scale_factor <= scale_factor_max);
        assert(target.width <= self.width_max);
        assert(target.height <= self.height_max);
        assert(@as(usize, target.stride) * target.height <= target.pixels.len);
        raster.clear(target, clear);

        var walk = Walk{
            .renderer = self,
            .target = target,
            .frame = frame,
            .scale = viewport.scale_factor,
        };
        // One iteration per draw; the draw list is bounded by the paint records.
        for (frame.drawList()) |*packed_draw| walk.drawOne(packed_draw);
        return walk.stats;
    }
};

/// Polygons one mesh can produce within the budget: a triangle mesh's
/// triangles or a polyline's segments, whichever is larger. The frame build
/// caps each by its per-mesh ceiling and by the frame's point budget.
fn polygonCountMax(limits: *const limits_mod.SceneLimits) u32 {
    assert(limits.check() == null);
    const triangle_points_max = @min(
        scene_mod.MAX_MESH_VERTICES,
        limits.path_vertex_count_frame_max,
    );
    const triangle_count_max = @divFloor(triangle_points_max, 3);
    const polyline_points_max = @min(
        scene_mod.MAX_POLYLINE_POINTS,
        limits.polyline_point_count_frame_max,
    );
    const segment_count_max = polyline_points_max -| 1;
    const count_max = @max(triangle_count_max, segment_count_max, 1);
    assert(count_max <= @max(scene_mod.MAX_POLYLINE_POINTS, scene_mod.MAX_MESH_VERTICES));
    return count_max;
}

/// One frame's walk over the draws. Stack-owned by `Renderer.draw`.
const Walk = struct {
    renderer: *Renderer,
    target: Target,
    frame: *const PackedFrame,
    scale: f32,
    stats: RenderStats = .{},

    fn drawOne(self: *Walk, packed_draw: *const packed_mod.Draw) void {
        assert(packed_draw.count > 0);
        assert(packed_draw.clip < self.frame.clip_count);
        const clip = deviceRect(self.frame.clips[packed_draw.clip], self.scale);
        switch (packed_draw.pipeline.kind()) {
            .quad => for (self.frame.drawRange(packed_draw, .quad)) |*quad| {
                self.drawQuad(quad, clip);
            },
            .sprite => self.drawSprites(packed_draw, clip),
            .mesh => self.drawMeshes(packed_draw, clip),
        }
    }

    /// A quad, or a shadow when it is blurred.
    fn drawQuad(self: *Walk, quad: *const packed_mod.Quad, clip: raster.DeviceRect) void {
        assert(quad.blur >= 0);
        assert(quad.bounds[2] >= 0);
        if (quad.blur > 0) {
            const shape = shadowShape(quad, clip, self.scale);
            raster.drawShadow(self.target, &shape, self.renderer.shadow_profile);
            self.stats.shadows += 1;
        } else {
            raster.drawQuad(self.target, &quadShape(quad, clip, self.scale));
            self.stats.quads += 1;
        }
    }

    fn drawSprites(self: *Walk, packed_draw: *const packed_mod.Draw, clip: raster.DeviceRect) void {
        const sprites = self.frame.drawRange(packed_draw, .sprite);
        const count = packed_draw.count;
        assert(sprites.len == count);
        const atlases = &self.renderer.atlases;
        switch (packed_draw.pipeline) {
            .glyph => {
                const atlas = self.atlasView(atlases.text, "glyph", count);
                for (sprites) |*sprite| drawGlyph(self.target, sprite, atlas, clip, self.scale);
                self.stats.glyphs += count;
            },
            .svg => {
                const atlas = self.atlasView(atlases.svg, "svg", count);
                for (sprites) |*sprite| drawSvg(self.target, sprite, atlas, clip, self.scale);
                self.stats.svgs += count;
            },
            .image => {
                const atlas = self.atlasView(atlases.image, "image", count);
                for (sprites) |*sprite| drawImage(self.target, sprite, atlas, clip, self.scale);
                self.stats.images += count;
            },
            .quad, .triangles, .strip_expanded, .point_instanced => unreachable, // A sprite draw.
        }
    }

    fn drawMeshes(self: *Walk, packed_draw: *const packed_mod.Draw, clip: raster.DeviceRect) void {
        const meshes = self.frame.drawRange(packed_draw, .mesh);
        const count = packed_draw.count;
        assert(meshes.len == count);
        switch (packed_draw.pipeline) {
            .triangles => {
                for (meshes) |*instance| self.drawTriangles(instance, clip);
                self.stats.triangle_meshes += count;
            },
            .strip_expanded => {
                for (meshes) |*instance| self.drawPolyline(instance, clip);
                self.stats.polylines += count;
            },
            .point_instanced => {
                for (meshes) |*instance| self.drawPointCloud(instance, clip);
                self.stats.point_clouds += count;
            },
            .quad, .glyph, .svg, .image => unreachable, // A mesh draw.
        }
    }

    /// The bound atlas for a sprite draw. Sprites exist only after their
    /// system rasterized into its atlas, and the window binds every atlas
    /// before each frame, so a missing one is a programmer error; drawing the
    /// frame without those sprites would hide it.
    fn atlasView(
        self: *const Walk,
        atlas: ?*const Atlas,
        comptime kind: []const u8,
        count: u32,
    ) raster.AtlasView {
        assert(count > 0);
        const bound = atlas orelse std.debug.panic(
            "CPU renderer: {d} {s} instance(s) in frame {d} but no {s} atlas is bound; " ++
                "the window must bind its atlases before rendering.",
            .{ count, kind, self.frame.frame_number, kind },
        );
        const bytes_per_pixel = bound.format.bytesPerPixel();
        assert(bound.data.len >= @as(usize, bound.size) * bound.size * bytes_per_pixel);
        return .{ .data = bound.data, .size = bound.size, .bytes_per_pixel = bytes_per_pixel };
    }

    /// A triangle list in one solid colour. The triangles of one mesh cover
    /// each sample once, so a shared edge never blends twice.
    fn drawTriangles(self: *Walk, instance: *const packed_mod.Mesh, clip: raster.DeviceRect) void {
        const points = self.frame.meshPoints(instance);
        const scratch = &self.renderer.mesh_scratch;
        const triangle_count: u32 = @intCast(@divExact(points.len, 3));
        assert(triangle_count <= scratch.polygons.len);
        const scale = self.scale;
        for (scratch.polygons[0..triangle_count], 0..) |*polygon, triangle| {
            const corners = points[triangle * 3 ..][0..3];
            polygon.* = mesh.Polygon.triangle(
                .{ corners[0].x * scale, corners[1].x * scale, corners[2].x * scale },
                .{ corners[0].y * scale, corners[1].y * scale, corners[2].y * scale },
            );
        }
        const color = raster.premulFromStraight(straight(instance.fill));
        mesh.fillPolygons(self.target, scratch, triangle_count, clip, color);
    }

    /// Independent butt-ended segments, as `strip_expanded.vert` expands them.
    fn drawPolyline(self: *Walk, instance: *const packed_mod.Mesh, clip: raster.DeviceRect) void {
        assert(instance.width > 0);
        const points = self.frame.meshPoints(instance);
        assert(points.len >= 2);
        const scratch = &self.renderer.mesh_scratch;
        const segment_count: u32 = @intCast(points.len - 1);
        assert(segment_count <= scratch.polygons.len);
        const radius = instance.width * 0.5;
        for (scratch.polygons[0..segment_count], points[0..segment_count], points[1..]) |
            *polygon,
            start,
            end,
        | {
            polygon.* = segmentPolygon(start, end, radius, self.scale);
        }
        const color = raster.premulFromStraight(straight(instance.fill));
        mesh.fillPolygons(self.target, scratch, segment_count, clip, color);
    }

    /// Points of `instance.width` logical pixels radius, each its own circle.
    fn drawPointCloud(self: *Walk, instance: *const packed_mod.Mesh, clip: raster.DeviceRect) void {
        assert(instance.width > 0);
        const points = self.frame.meshPoints(instance);
        assert(points.len >= 1);
        const color = raster.premulFromStraight(straight(instance.fill));
        const radius = instance.width * self.scale;
        for (points) |point| {
            const center = .{ point.x * self.scale, point.y * self.scale };
            mesh.drawPoint(self.target, center, radius, clip, color);
        }
    }
};

/// One strip segment's quad in device pixels. A segment shorter than the
/// shader's threshold keeps a vertical perpendicular, exactly as on the GPU.
fn segmentPolygon(
    start: packed_mod.MeshPoint,
    end: packed_mod.MeshPoint,
    radius: f32,
    scale: f32,
) mesh.Polygon {
    assert(radius > 0);
    assert(scale > 0);
    const direction_x = end.x - start.x;
    const direction_y = end.y - start.y;
    const distance = @sqrt(direction_x * direction_x + direction_y * direction_y);
    var normal_x: f32 = 0;
    var normal_y: f32 = radius;
    if (distance > 0.0001) {
        normal_x = -direction_y / distance * radius;
        normal_y = direction_x / distance * radius;
    }
    return mesh.Polygon.quad(.{
        (start.x - normal_x) * scale,
        (end.x - normal_x) * scale,
        (end.x + normal_x) * scale,
        (start.x + normal_x) * scale,
    }, .{
        (start.y - normal_y) * scale,
        (end.y - normal_y) * scale,
        (end.y + normal_y) * scale,
        (start.y + normal_y) * scale,
    });
}

// =============================================================================
// Packed instance to device shape
// =============================================================================

/// A logical rectangle (x, y, width, height) in device pixels.
fn deviceRect(rect: packed_mod.Rect, scale: f32) raster.DeviceRect {
    assert(scale > 0);
    assert(!std.math.isNan(rect[0]));
    assert(!std.math.isNan(rect[1]));
    return .{
        .x = rect[0] * scale,
        .y = rect[1] * scale,
        .width = @max(rect[2], 0.0) * scale,
        .height = @max(rect[3], 0.0) * scale,
    };
}

/// Radii in packed order (top left, top right, bottom right, bottom left).
fn deviceRadii(corners: [4]f32, scale: f32) raster.Radii {
    assert(scale > 0);
    assert(!std.math.isNan(corners[0]));
    return .{
        .top_left = @max(corners[0], 0.0) * scale,
        .top_right = @max(corners[1], 0.0) * scale,
        .bottom_right = @max(corners[2], 0.0) * scale,
        .bottom_left = @max(corners[3], 0.0) * scale,
    };
}

fn straight(rgba: packed_mod.Rgba) geometry.Color {
    assert(!std.math.isNan(rgba[3]));
    assert(rgba[3] >= 0);
    return .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
}

fn quadShape(
    quad: *const packed_mod.Quad,
    clip: raster.DeviceRect,
    scale: f32,
) raster.QuadShape {
    assert(scale > 0);
    assert(quad.blur == 0);
    const widths = quad.border_widths;
    return .{
        .bounds = deviceRect(quad.bounds, scale),
        .clip = clip,
        .radii = deviceRadii(quad.corners, scale),
        .borders = .{
            .top = @max(widths[0], 0.0) * scale,
            .right = @max(widths[1], 0.0) * scale,
            .bottom = @max(widths[2], 0.0) * scale,
            .left = @max(widths[3], 0.0) * scale,
        },
        .background = straight(quad.fill),
        .border_color = straight(quad.border_color),
    };
}

fn shadowShape(
    quad: *const packed_mod.Quad,
    clip: raster.DeviceRect,
    scale: f32,
) raster.ShadowShape {
    assert(scale > 0);
    assert(quad.blur > 0);
    return .{
        .content = deviceRect(quad.bounds, scale),
        .clip = clip,
        .offset_x = quad.offset[0] * scale,
        .offset_y = quad.offset[1] * scale,
        .blur = quad.blur * scale,
        .radii = deviceRadii(quad.corners, scale),
        .color = straight(quad.fill),
    };
}

fn texturedRect(
    sprite: *const packed_mod.Sprite,
    clip: raster.DeviceRect,
    scale: f32,
) raster.TexturedRect {
    assert(scale > 0);
    assert(sprite.bounds[2] >= 0);
    assert(sprite.bounds[3] >= 0);
    return .{
        .bounds = deviceRect(sprite.bounds, scale),
        .clip = clip,
        .uv_left = sprite.uv[0],
        .uv_top = sprite.uv[1],
        .uv_right = sprite.uv[2],
        .uv_bottom = sprite.uv[3],
    };
}

fn drawGlyph(
    target: Target,
    sprite: *const packed_mod.Sprite,
    atlas: raster.AtlasView,
    clip: raster.DeviceRect,
    scale: f32,
) void {
    assert(atlas.bytes_per_pixel == 1);
    assert(scale > 0);
    const rect = texturedRect(sprite, clip, scale);
    raster.drawGlyph(target, &rect, atlas, straight(sprite.tint));
}

fn drawSvg(
    target: Target,
    sprite: *const packed_mod.Sprite,
    atlas: raster.AtlasView,
    clip: raster.DeviceRect,
    scale: f32,
) void {
    assert(atlas.bytes_per_pixel == 4);
    assert(scale > 0);
    const rect = texturedRect(sprite, clip, scale);
    raster.drawSvg(target, &rect, atlas, straight(sprite.tint), straight(sprite.secondary));
}

fn drawImage(
    target: Target,
    sprite: *const packed_mod.Sprite,
    atlas: raster.AtlasView,
    clip: raster.DeviceRect,
    scale: f32,
) void {
    assert(atlas.bytes_per_pixel == 4);
    assert(scale > 0);
    const rect = texturedRect(sprite, clip, scale);
    const effects = raster.ImageEffects{
        .tint = straight(sprite.tint),
        .radii = deviceRadii(sprite.corners, scale),
        .grayscale = std.math.clamp(sprite.grayscale, 0.0, 1.0),
        .opacity = std.math.clamp(sprite.opacity, 0.0, 1.0),
    };
    raster.drawImage(target, &rect, atlas, &effects);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// A small budget so test renderers reserve kilobytes, not megabytes.
const test_limits = limits_mod.ResourceLimits{
    .scene = limits_mod.SceneLimits.nano,
    .window = .{ .framebuffer_width_max = 16, .framebuffer_height_max = 16 },
    .frame = limits_mod.FrameLimits.nano,
    .atlas = limits_mod.AtlasLimits.standard,
    .build = limits_mod.BuildLimits.nano,
    .records = limits_mod.RecordLimits.nano,
    .retained = limits_mod.RetainedLimits.nano,
    .events = limits_mod.EventLimits.nano,
    .text = limits_mod.TextLimits.nano,
    .entities = limits_mod.EntityLimits.nano,
};

const black = geometry.Color.rgba(0, 0, 0, 1);
const red: packed_mod.Rgba = .{ 1, 0, 0, 1 };
const blue: packed_mod.Rgba = .{ 0, 0, 1, 1 };

fn testRenderer() !Renderer {
    var renderer: Renderer = undefined;
    try renderer.initInPlace(testing.allocator, &test_limits);
    return renderer;
}

/// A packed frame for frame 1 borrowing `points`, filled by the helpers
/// below the way `pack` fills it: one draw per instance, in call order.
fn testFrame(frame: *PackedFrame, points: []const packed_mod.MeshPoint) !void {
    try frame.initInPlace(&.{ .scene = test_limits.scene, .paint_record_count_max = 16 });
    frame.reset(1, points);
}

fn appendClip(frame: *PackedFrame, rect: packed_mod.Rect) u32 {
    assert(frame.clip_count < frame.clips.len);
    frame.clips[frame.clip_count] = rect;
    frame.clip_count += 1;
    return frame.clip_count - 1;
}

fn appendDraw(frame: *PackedFrame, pipeline: packed_mod.Pipeline, first: u32, clip: u32) void {
    assert(frame.draw_count < frame.draws.len);
    assert(clip < frame.clip_count);
    frame.draws[frame.draw_count] = .{
        .pipeline = pipeline,
        .clip = clip,
        .first = first,
        .count = 1,
    };
    frame.draw_count += 1;
}

fn appendQuad(frame: *PackedFrame, quad: packed_mod.Quad, clip: u32) void {
    frame.quads[frame.quad_count] = quad;
    appendDraw(frame, .quad, frame.quad_count, clip);
    frame.quad_count += 1;
}

fn appendMesh(
    frame: *PackedFrame,
    pipeline: packed_mod.Pipeline,
    instance: packed_mod.Mesh,
    clip: u32,
) void {
    assert(pipeline.kind() == .mesh);
    frame.meshes[frame.mesh_count] = instance;
    appendDraw(frame, pipeline, frame.mesh_count, clip);
    frame.mesh_count += 1;
}

fn testQuad(bounds: packed_mod.Rect, fill: packed_mod.Rgba, blur: f32) packed_mod.Quad {
    return .{
        .bounds = bounds,
        .fill = fill,
        .border_color = .{ 0, 0, 0, 0 },
        .corners = @splat(0),
        .border_widths = @splat(0),
        .blur = blur,
        .offset = .{ 0, 0 },
    };
}

/// A mesh of `count` points from `first`; triangle edge modes are unused here.
fn testMesh(fill: packed_mod.Rgba, first: u32, count: u32, width: f32) packed_mod.Mesh {
    return .{ .fill = fill, .first = first, .count = count, .width = width, .edge_first = 0 };
}

test "draw scales logical bounds and draws later draws on top" {
    // Goal: exercise the draw walk end to end. At scale 2 a logical quad at
    // (1, 1) of size 1 covers device pixels 2 and 3 only, and a later quad
    // that overlaps it wins because draws are drawn in order.
    var frame: PackedFrame = undefined;
    try testFrame(&frame, &.{});
    defer frame.deinit();
    appendQuad(&frame, testQuad(.{ 1, 1, 1, 1 }, red, 0), packed_mod.clip_none);
    appendQuad(&frame, testQuad(.{ 1.5, 1.5, 1, 1 }, blue, 0), packed_mod.clip_none);

    var renderer = try testRenderer();
    defer renderer.deinit(testing.allocator);
    var pixels: [6 * 6]u32 = undefined;
    const target = Target{ .pixels = &pixels, .width = 6, .height = 6, .stride = 6 };
    const stats = renderer.draw(target, &frame, .{ .scale_factor = 2 }, black);
    try testing.expectEqual(@as(u32, 2), stats.quads);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(1)[1]);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), target.row(2)[2]);
    try testing.expectEqual(@as(u32, 0xFF00_00FF), target.row(3)[3]);
    try testing.expectEqual(@as(u32, 0xFF00_00FF), target.row(4)[4]);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(5)[5]);
}

test "every mesh pipeline draws, in place, at the device scale" {
    // Goal: triangles, polylines, and point clouds all reach pixels through
    // the draw walk, none is skipped, and each honors the logical-to-device
    // scale and its mesh's point range. Each sits in its own quadrant of a
    // 16x16 device target drawn at scale 2.
    const points = [_]packed_mod.MeshPoint{
        // Triangle: logical (0, 0) (3, 0) (0, 3), device (0, 0) (6, 0) (0, 6).
        .{ .x = 0, .y = 0 },     .{ .x = 3, .y = 0 },   .{ .x = 0, .y = 3 },
        // Polyline: logical y = 1.5, width 1, x 4.5 to 8; device y 2 to 4.
        .{ .x = 4.5, .y = 1.5 }, .{ .x = 8, .y = 1.5 },
        // Point cloud: logical (2, 6), radius 1.5; device (4, 12), radius 3.
        .{ .x = 2, .y = 6 },
    };
    var frame: PackedFrame = undefined;
    try testFrame(&frame, &points);
    defer frame.deinit();
    const none = packed_mod.clip_none;
    const white: packed_mod.Rgba = .{ 1, 1, 1, 1 };
    const gray: packed_mod.Rgba = .{ 0.5, 0.5, 0.5, 1 };
    appendMesh(&frame, .triangles, testMesh(red, 0, 3, 0), none);
    appendMesh(&frame, .strip_expanded, testMesh(white, 3, 2, 1), none);
    appendMesh(&frame, .point_instanced, testMesh(gray, 5, 1, 1.5), none);

    var renderer = try testRenderer();
    defer renderer.deinit(testing.allocator);
    var pixels: [16 * 16]u32 = undefined;
    const target = Target{ .pixels = &pixels, .width = 16, .height = 16, .stride = 16 };
    const stats = renderer.draw(target, &frame, .{ .scale_factor = 2 }, black);
    try testing.expectEqual(@as(u32, 1), stats.triangle_meshes);
    try testing.expectEqual(@as(u32, 1), stats.polylines);
    try testing.expectEqual(@as(u32, 1), stats.point_clouds);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), target.row(1)[1]);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(5)[5]);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), target.row(2)[12]);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), target.row(3)[12]);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(4)[12]);
    try testing.expectEqual(@as(u32, 0xFF80_8080), target.row(12)[4]);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(12)[12]);
}

test "a translucent polyline blends once where its segments overlap" {
    // Goal: the GPU's per-sample resolve covers each sample of a draw once,
    // so a V-shaped line at half alpha must not darken at its joint. Pixel
    // (3, 3) lies under both segments of (0, 0) (4, 4) (8, 0) at width 2;
    // blending each segment separately would lift its red byte above 128.
    const points = [_]packed_mod.MeshPoint{
        .{ .x = 0, .y = 0 },
        .{ .x = 4, .y = 4 },
        .{ .x = 8, .y = 0 },
    };
    var frame: PackedFrame = undefined;
    try testFrame(&frame, &points);
    defer frame.deinit();
    const half_red: packed_mod.Rgba = .{ 1, 0, 0, 0.5 };
    const line = testMesh(half_red, 0, 3, 2);
    appendMesh(&frame, .strip_expanded, line, packed_mod.clip_none);

    var renderer = try testRenderer();
    defer renderer.deinit(testing.allocator);
    var pixels: [8 * 8]u32 = undefined;
    const target = Target{ .pixels = &pixels, .width = 8, .height = 8, .stride = 8 };
    _ = renderer.draw(target, &frame, .{ .scale_factor = 1 }, black);
    try testing.expectEqual(@as(u32, 0xFF80_0000), target.row(3)[3]);
    for (pixels) |pixel| try testing.expect((pixel >> 16) & 0xFF <= 128);
}

test "each draw keeps to its own clip, shadows and meshes included" {
    // Goal: the contract's clip rule reaches every pipeline through
    // `Draw.clip`, including shadows, which 0.3.1 never clipped. A blurred
    // shadow and a triangle both span the whole 8x4 target; the shadow's clip
    // is logical x [0, 2] and the triangle's x [6, 8] at scale 1, so pixels
    // 2..5 of every row keep the clear colour, and pixel 1 (centre 1.5,
    // inside) and pixel 6 (centre 6.5, inside) are drawn. A wrong clip index
    // or an unclipped shadow fails.
    const points = [_]packed_mod.MeshPoint{
        .{ .x = -4, .y = -4 }, .{ .x = 20, .y = -4 }, .{ .x = -4, .y = 20 },
    };
    var frame: PackedFrame = undefined;
    try testFrame(&frame, &points);
    defer frame.deinit();
    const left = appendClip(&frame, .{ 0, 0, 2, 4 });
    const right = appendClip(&frame, .{ 6, 0, 2, 4 });
    appendQuad(&frame, testQuad(.{ -2, -2, 12, 8 }, red, 1), left);
    appendMesh(&frame, .triangles, testMesh(blue, 0, 3, 0), right);

    var renderer = try testRenderer();
    defer renderer.deinit(testing.allocator);
    var pixels: [8 * 4]u32 = undefined;
    const target = Target{ .pixels = &pixels, .width = 8, .height = 4, .stride = 8 };
    const stats = renderer.draw(target, &frame, .{ .scale_factor = 1 }, black);
    try testing.expectEqual(@as(u32, 1), stats.shadows);
    try testing.expectEqual(@as(u32, 0), stats.quads);
    var y: u32 = 0;
    while (y < 4) : (y += 1) {
        const row = target.row(y);
        try testing.expect((row[1] >> 16) & 0xFF > 0);
        for (row[2..6]) |pixel| try testing.expectEqual(@as(u32, 0xFF00_0000), pixel);
        try testing.expectEqual(@as(u32, 0xFF00_00FF), row[6]);
        try testing.expectEqual(@as(u32, 0xFF00_00FF), row[7]);
    }
}
