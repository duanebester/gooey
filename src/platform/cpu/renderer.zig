//! CPU scene renderer: draws a finished `Scene` into a caller-owned `Target`.
//!
//! This is the software counterpart of `linux/scene_renderer.zig` and
//! `linux/vk_mesh.zig`. It walks the same `BatchIterator` draw-order stream
//! and draws every primitive kind the Vulkan backend draws: shadows, quads,
//! glyphs, SVG icons, images, paths (solid and gradient), polylines, point
//! clouds, and colored point clouds. There is no kind it skips.
//!
//! The pixels belong to the presenter (a Wayland shared-memory buffer or the
//! fbdev back buffer), so `draw` takes the frame's `Target`. Atlases are read
//! in place from their CPU-side storage; binding them is a pointer store. The
//! renderer itself owns only raster scratch, reserved by `initInPlace` from the
//! application's `ResourceLimits` and never resized (CLAUDE.md §2).
//!
//! The shape follows the kernel contract's §9 `Renderer` (`initInPlace` from
//! limits, `draw` with a viewport and clear color, `capabilities`, `deinit`),
//! so a presenter can wrap it in that contract without changing this file's
//! responsibilities.
//!
//! ## Resource sketch (CLAUDE.md §7)
//!
//! - Memory: the shadow row profile (4 B per framebuffer column) and the mesh
//!   scratch (`mesh.zig`), about 420 KiB at `.standard` limits. The target is
//!   the presenter's (4 B per pixel) and the atlases are the text, SVG, and
//!   image systems' own.
//! - CPU: one clear pass, then one pass per primitive over its clipped
//!   bounding box. Interior spans of quads and shadows are filled with
//!   `@memset` or a single-color blend; only edge and corner pixels evaluate
//!   the distance function, textured quads take one bilinear sample per
//!   covered pixel, and meshes shade each covered pixel once per draw.
//! - Worst case per frame: `width * height * (1 + overdraw)` pixel writes for
//!   the scene's primitive capacities, plus mesh work bounded by the scene's
//!   aggregate geometry budgets, which `draw` claims exactly as the Vulkan
//!   renderer does and which fail fast with the pool name when exceeded. A
//!   1280x800 frame with 3x overdraw is roughly 4 M pixel writes, a few
//!   milliseconds on one desktop core.
//! - GPU, disk, and network: none.

const std = @import("std");
const geometry = @import("../../geometry/geometry.zig");
const limits_mod = @import("../../core/limits.zig");
const scene_mod = @import("../../scene/mod.zig");
const batch_iterator = @import("../../scene/batch_iterator.zig");
const text_atlas_mod = @import("../../text/atlas.zig");
const SvgInstance = @import("../../scene/svg_instance.zig").SvgInstance;
const ImageInstance = @import("../../scene/image_instance.zig").ImageInstance;
const path_mesh = @import("../../scene/path_mesh.zig");
const GradientUniforms = @import("../../scene/gradient_uniforms.zig").GradientUniforms;
pub const raster = @import("raster.zig");
pub const mesh = @import("mesh.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Atlas = text_atlas_mod.Atlas;
const Target = raster.Target;
const GeometryCounts = scene_mod.GeometryCounts;

/// Device scale factors above this are treated as a programmer error. The
/// bound keeps every logical-to-device product finite and well inside `f32`.
pub const scale_factor_max: f32 = 8.0;

/// Per-frame drawing parameters besides the scene and the target.
pub const Viewport = struct {
    /// Device pixels per logical pixel.
    scale_factor: f32,
};

/// What this renderer can do beyond the scene's primitive kinds.
pub const Capabilities = struct {
    /// Custom post-process shader passes. The CPU has no shader runtime.
    post_process: bool,
};

/// The atlases textured primitives sample. A frame whose scene holds glyphs,
/// SVG icons, or images must have the matching atlas bound.
pub const Atlases = struct {
    /// Glyph coverage atlas (grayscale).
    text: ?*const Atlas = null,
    /// SVG fill and stroke coverage atlas (RGBA).
    svg: ?*const Atlas = null,
    /// Image atlas (straight-alpha RGBA).
    image: ?*const Atlas = null,
};

/// Primitives drawn in one frame, for profiling and tests.
pub const RenderStats = struct {
    shadows: u32 = 0,
    quads: u32 = 0,
    glyphs: u32 = 0,
    svgs: u32 = 0,
    images: u32 = 0,
    paths: u32 = 0,
    polylines: u32 = 0,
    point_clouds: u32 = 0,
    colored_point_clouds: u32 = 0,
};

pub const Renderer = struct {
    width_max: u32,
    height_max: u32,
    /// One straight-row shadow color per framebuffer column.
    shadow_profile: []raster.Premul,
    mesh_scratch: mesh.Scratch,
    atlases: Atlases,

    /// Reserve every byte of raster scratch for the budget's largest
    /// framebuffer and largest single mesh draw.
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
        return .{ .post_process = false };
    }

    /// Clear `target` and draw every primitive of `scene` in draw order.
    pub fn draw(
        self: *Renderer,
        target: Target,
        scene: *const scene_mod.Scene,
        viewport: Viewport,
        clear: geometry.Color,
    ) RenderStats {
        assert(viewport.scale_factor > 0);
        assert(viewport.scale_factor <= scale_factor_max);
        assert(target.width <= self.width_max);
        assert(target.height <= self.height_max);
        assert(@as(usize, target.stride) * target.height <= target.pixels.len);
        raster.clear(target, clear);

        var frame = Frame{
            .renderer = self,
            .target = target,
            .scene = scene,
            .scale = viewport.scale_factor,
            .budget = GeometryCounts.from_limits(&scene.limits),
        };
        var iterator = batch_iterator.BatchIterator.init(scene);
        // Each batch is a non-empty run of the scene's arrays, so the batch
        // count is bounded by the scene's total primitive count.
        while (iterator.next()) |batch| {
            assert(batch.len() > 0);
            frame.drawBatch(batch);
        }
        return frame.stats;
    }
};

/// Polygons one mesh draw can produce within the budget: a path's triangles
/// or a polyline's segments, whichever is larger.
fn polygonCountMax(limits: *const scene_mod.SceneLimits) u32 {
    assert(limits.check() == null);
    const index_count_max = @min(path_mesh.MAX_MESH_INDICES, limits.path_index_count_frame_max);
    const triangle_count_max = @divFloor(index_count_max, 3);
    const point_count_max = @min(
        scene_mod.MAX_POLYLINE_POINTS,
        limits.polyline_point_count_frame_max,
    );
    const segment_count_max = point_count_max -| 1;
    const count_max = @max(triangle_count_max, segment_count_max, 1);
    assert(count_max <= scene_mod.MAX_POLYLINE_POINTS);
    return count_max;
}

/// One frame's walk over the scene. Stack-owned by `Renderer.draw`.
const Frame = struct {
    renderer: *Renderer,
    target: Target,
    scene: *const scene_mod.Scene,
    scale: f32,
    budget: GeometryCounts,
    usage: GeometryCounts = .{},
    stats: RenderStats = .{},

    fn drawBatch(self: *Frame, batch: batch_iterator.PrimitiveBatch) void {
        assert(batch.len() > 0);
        assert(self.scale > 0);
        const count: u32 = @intCast(batch.len());
        switch (batch) {
            .shadow => |shadows| for (shadows) |*shadow| {
                const shape = shadowShape(shadow, self.scale);
                raster.drawShadow(self.target, &shape, self.renderer.shadow_profile);
            },
            .quad => |quads| for (quads) |*quad| {
                raster.drawQuad(self.target, &quadShape(quad, self.scale));
            },
            .glyph => |glyphs| {
                const atlas = self.atlasView(self.renderer.atlases.text, "glyph", count);
                for (glyphs) |*glyph| drawGlyph(self.target, glyph, atlas, self.scale);
            },
            .svg => |svgs| {
                const atlas = self.atlasView(self.renderer.atlases.svg, "svg", count);
                for (svgs) |*svg| drawSvg(self.target, svg, atlas, self.scale);
            },
            .image => |images| {
                const atlas = self.atlasView(self.renderer.atlases.image, "image", count);
                for (images) |*image| drawImage(self.target, image, atlas, self.scale);
            },
            .path => |paths| self.drawPaths(paths),
            .polyline => |lines| for (lines) |*line| self.drawPolyline(line),
            .point_cloud => |clouds| for (clouds) |*cloud| self.drawPointCloud(cloud),
            .colored_point_cloud => |clouds| for (clouds) |*cloud| {
                self.drawColoredPointCloud(cloud);
            },
        }
        self.countBatch(batch, count);
    }

    fn countBatch(self: *Frame, batch: batch_iterator.PrimitiveBatch, count: u32) void {
        assert(count > 0);
        assert(count == batch.len());
        const field = switch (batch) {
            .shadow => &self.stats.shadows,
            .quad => &self.stats.quads,
            .glyph => &self.stats.glyphs,
            .svg => &self.stats.svgs,
            .image => &self.stats.images,
            .path => &self.stats.paths,
            .polyline => &self.stats.polylines,
            .point_cloud => &self.stats.point_clouds,
            .colored_point_cloud => &self.stats.colored_point_clouds,
        };
        field.* += count;
    }

    /// The bound atlas for a textured batch. Textured instances exist only
    /// after their system rasterized into its atlas, and the window binds
    /// every atlas before each frame, so a missing one is a programmer error;
    /// drawing the frame without those primitives would hide it.
    fn atlasView(
        self: *const Frame,
        atlas: ?*const Atlas,
        comptime kind: []const u8,
        count: u32,
    ) raster.AtlasView {
        assert(count > 0);
        const bound = atlas orelse std.debug.panic(
            "CPU renderer: {d} {s} instance(s) in frame {d} but no {s} atlas is bound; " ++
                "the window must bind its atlases before rendering.",
            .{ count, kind, self.scene.frame_count_finished, kind },
        );
        const bytes_per_pixel = bound.format.bytesPerPixel();
        assert(bound.data.len >= @as(usize, bound.size) * bound.size * bytes_per_pixel);
        return .{ .data = bound.data, .size = bound.size, .bytes_per_pixel = bytes_per_pixel };
    }

    fn claim(self: *Frame, pool: scene_mod.GeometryPool, requested: usize) void {
        assert(requested <= std.math.maxInt(u32));
        assert(self.budget.counts[@backingInt(pool)] > 0);
        self.usage.claim(&self.budget, .{
            .pool = pool,
            .requested = @intCast(requested),
            .frame = self.scene.frame_count_finished,
        });
    }

    fn drawPaths(self: *Frame, instances: []const scene_mod.PathInstance) void {
        assert(instances.len <= self.scene.limits.path_count_frame_max);
        const all = self.scene.getPathInstances();
        const first = @divExact(
            @intFromPtr(instances.ptr) - @intFromPtr(all.ptr),
            @sizeOf(scene_mod.PathInstance),
        );
        assert(first + instances.len <= all.len);
        const gradients = self.scene.getPathGradients()[first..][0..instances.len];
        for (instances, gradients) |*path, *gradient| {
            const path_mesh_ref = self.scene.getMeshPool().getMesh(path.getMeshRef());
            const indices = path_mesh_ref.indices.constSlice();
            // An empty mesh has no triangles to draw, on the GPU as here.
            if (indices.len == 0) continue;
            assert(indices.len % 3 == 0);
            self.claim(.path_vertices, path_mesh_ref.vertices.len);
            self.claim(.path_indices, indices.len);
            self.drawPath(path, gradient, path_mesh_ref);
        }
    }

    fn drawPath(
        self: *Frame,
        path: *const scene_mod.PathInstance,
        gradient: *const GradientUniforms,
        source: *const path_mesh.PathMesh,
    ) void {
        const scratch = &self.renderer.mesh_scratch;
        const indices = source.indices.constSlice();
        const vertices = source.vertices.constSlice();
        const triangle_count: u32 = @intCast(@divExact(indices.len, 3));
        assert(triangle_count <= scratch.polygons.len);
        var best: ?u32 = null;
        var best_area: f32 = 0;
        for (scratch.polygons[0..triangle_count], 0..) |*polygon, triangle| {
            var x: [3]f32 = undefined;
            var y: [3]f32 = undefined;
            for (indices[triangle * 3 ..][0..3], &x, &y) |index, *vertex_x, *vertex_y| {
                assert(index < vertices.len);
                vertex_x.* = (vertices[index].x * path.scale_x + path.offset_x) * self.scale;
                vertex_y.* = (vertices[index].y * path.scale_y + path.offset_y) * self.scale;
            }
            polygon.* = mesh.Polygon.triangle(x, y);
            const area = @abs((x[1] - x[0]) * (y[2] - y[0]) - (x[2] - x[0]) * (y[1] - y[0]));
            if (area > best_area) {
                best = @intCast(triangle);
                best_area = area;
            }
        }
        // Every triangle is degenerate: the GPU covers no sample either.
        const anchor = best orelse return;
        const fill = self.pathFill(path, gradient, source, anchor) orelse return;
        const clip = deviceRect(
            path.clip_x,
            path.clip_y,
            path.clip_width,
            path.clip_height,
            self.scale,
        );
        mesh.fillPolygons(self.target, scratch, triangle_count, clip, &fill);
    }

    /// The fill `mesh.frag` computes for a path. Null when the solid color is
    /// fully transparent, which the shader discards everywhere.
    fn pathFill(
        self: *const Frame,
        path: *const scene_mod.PathInstance,
        gradient: *const GradientUniforms,
        source: *const path_mesh.PathMesh,
        anchor: u32,
    ) ?mesh.Fill {
        assert(path.gradient_type <= 2);
        assert(anchor * 3 + 3 <= source.indices.len);
        if (path.gradient_type == 0) {
            const color = raster.premulFromStraight(path.fill_color.toColor());
            if (color.a == 0) return null;
            return .{ .solid = color };
        }
        assert(gradient.stop_count >= 2);
        assert(gradient.stop_count <= gradient.stop_offsets.len);
        const polygon = &self.renderer.mesh_scratch.polygons[anchor];
        const corners = source.indices.constSlice()[anchor * 3 ..][0..3];
        var u: [3]f32 = undefined;
        var v: [3]f32 = undefined;
        for (corners, &u, &v) |index, *vertex_u, *vertex_v| {
            vertex_u.* = source.vertices.constSlice()[index].u;
            vertex_v.* = source.vertices.constSlice()[index].v;
        }
        return .{ .gradient = .{
            .uniforms = gradient,
            .kind = path.gradient_type,
            .params = .{ path.grad_param0, path.grad_param1, path.grad_param2, path.grad_param3 },
            .uv = mesh.UvMap.fromTriangle(polygon.x[0..3].*, polygon.y[0..3].*, u, v),
        } };
    }

    /// Independent butt-ended segments, as `strip_expanded.vert` expands them.
    fn drawPolyline(self: *Frame, line: *const scene_mod.Polyline) void {
        line.validate();
        const points = line.getPoints();
        assert(points.len >= 2);
        self.claim(.polyline_points, points.len);
        const scratch = &self.renderer.mesh_scratch;
        const segment_count: u32 = @intCast(points.len - 1);
        assert(segment_count <= scratch.polygons.len);
        const radius = line.width * 0.5;
        for (scratch.polygons[0..segment_count], points[0..segment_count], points[1..]) |
            *polygon,
            start,
            end,
        | {
            polygon.* = segmentPolygon(start, end, radius, self.scale);
        }
        const color = raster.premulFromStraight(line.color.toColor());
        if (color.a == 0) return;
        const clip = deviceRect(
            line.clip_x,
            line.clip_y,
            line.clip_width,
            line.clip_height,
            self.scale,
        );
        mesh.fillPolygons(self.target, scratch, segment_count, clip, &.{ .solid = color });
    }

    fn drawPointCloud(self: *Frame, cloud: *const scene_mod.PointCloud) void {
        cloud.validate();
        const positions = cloud.getPositions();
        self.claim(.points, positions.len);
        const color = raster.premulFromStraight(cloud.color.toColor());
        const clip = deviceRect(
            cloud.clip_x,
            cloud.clip_y,
            cloud.clip_width,
            cloud.clip_height,
            self.scale,
        );
        const radius = cloud.radius * self.scale;
        for (positions) |position| {
            const center = .{ position.x * self.scale, position.y * self.scale };
            mesh.drawPoint(self.target, center, radius, clip, color);
        }
    }

    fn drawColoredPointCloud(self: *Frame, cloud: *const scene_mod.ColoredPointCloud) void {
        cloud.validate();
        const positions = cloud.getPositions();
        const colors = cloud.getColors();
        assert(colors.len == positions.len);
        self.claim(.colored_points, positions.len);
        const clip = deviceRect(
            cloud.clip_x,
            cloud.clip_y,
            cloud.clip_width,
            cloud.clip_height,
            self.scale,
        );
        const radius = cloud.radius * self.scale;
        for (positions, colors) |position, hsla| {
            const center = .{ position.x * self.scale, position.y * self.scale };
            const color = raster.premulFromStraight(hsla.toColor());
            mesh.drawPoint(self.target, center, radius, clip, color);
        }
    }
};

/// One strip segment's quad in device pixels. A segment shorter than the
/// shader's threshold keeps a vertical perpendicular, exactly as on the GPU.
fn segmentPolygon(
    start: scene_mod.Point,
    end: scene_mod.Point,
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
// Logical primitive to device shape
// =============================================================================

fn deviceRect(x: f32, y: f32, width: f32, height: f32, scale: f32) raster.DeviceRect {
    assert(scale > 0);
    assert(!std.math.isNan(x));
    assert(!std.math.isNan(y));
    return .{
        .x = x * scale,
        .y = y * scale,
        .width = @max(width, 0.0) * scale,
        .height = @max(height, 0.0) * scale,
    };
}

fn deviceRadii(corners: scene_mod.Corners, scale: f32) raster.Radii {
    assert(scale > 0);
    assert(!std.math.isNan(corners.top_left));
    return .{
        .top_left = @max(corners.top_left, 0.0) * scale,
        .top_right = @max(corners.top_right, 0.0) * scale,
        .bottom_right = @max(corners.bottom_right, 0.0) * scale,
        .bottom_left = @max(corners.bottom_left, 0.0) * scale,
    };
}

fn quadShape(quad: *const scene_mod.Quad, scale: f32) raster.QuadShape {
    assert(scale > 0);
    assert(quad.bounds_size_width >= 0);
    assert(quad.bounds_size_height >= 0);
    const borders = quad.border_widths;
    return .{
        .bounds = deviceRect(
            quad.bounds_origin_x,
            quad.bounds_origin_y,
            quad.bounds_size_width,
            quad.bounds_size_height,
            scale,
        ),
        .clip = deviceRect(
            quad.clip_origin_x,
            quad.clip_origin_y,
            quad.clip_size_width,
            quad.clip_size_height,
            scale,
        ),
        .radii = deviceRadii(quad.corner_radii, scale),
        .borders = .{
            .top = @max(borders.top, 0.0) * scale,
            .right = @max(borders.right, 0.0) * scale,
            .bottom = @max(borders.bottom, 0.0) * scale,
            .left = @max(borders.left, 0.0) * scale,
        },
        .background = quad.background.toColor(),
        .border_color = quad.border_color.toColor(),
    };
}

fn shadowShape(shadow: *const scene_mod.Shadow, scale: f32) raster.ShadowShape {
    assert(scale > 0);
    assert(shadow.content_size_width >= 0);
    assert(shadow.content_size_height >= 0);
    return .{
        .content = deviceRect(
            shadow.content_origin_x,
            shadow.content_origin_y,
            shadow.content_size_width,
            shadow.content_size_height,
            scale,
        ),
        .offset_x = shadow.offset_x * scale,
        .offset_y = shadow.offset_y * scale,
        .blur = @max(shadow.blur_radius, 0.0) * scale,
        .radii = deviceRadii(shadow.corner_radii, scale),
        .color = shadow.color.toColor(),
    };
}

/// The fields every textured instance shares, gathered by name so glyphs,
/// SVG icons, and images convert through one function.
fn texturedRect(instance: anytype, width: f32, height: f32, scale: f32) raster.TexturedRect {
    assert(scale > 0);
    assert(width >= 0);
    assert(height >= 0);
    return .{
        .bounds = deviceRect(instance.pos_x, instance.pos_y, width, height, scale),
        .clip = deviceRect(
            instance.clip_x,
            instance.clip_y,
            instance.clip_width,
            instance.clip_height,
            scale,
        ),
        .uv_left = instance.uv_left,
        .uv_top = instance.uv_top,
        .uv_right = instance.uv_right,
        .uv_bottom = instance.uv_bottom,
    };
}

fn drawGlyph(
    target: Target,
    glyph: *const scene_mod.GlyphInstance,
    atlas: raster.AtlasView,
    scale: f32,
) void {
    assert(glyph.size_x >= 0);
    assert(glyph.size_y >= 0);
    assert(atlas.bytes_per_pixel == 1);
    const rect = texturedRect(glyph, glyph.size_x, glyph.size_y, scale);
    raster.drawGlyph(target, &rect, atlas, glyph.color.toColor());
}

fn drawSvg(target: Target, svg: *const SvgInstance, atlas: raster.AtlasView, scale: f32) void {
    assert(svg.size_x >= 0);
    assert(svg.size_y >= 0);
    assert(atlas.bytes_per_pixel == 4);
    const rect = texturedRect(svg, svg.size_x, svg.size_y, scale);
    raster.drawSvg(target, &rect, atlas, svg.color.toColor(), svg.stroke_color.toColor());
}

fn drawImage(
    target: Target,
    image: *const ImageInstance,
    atlas: raster.AtlasView,
    scale: f32,
) void {
    assert(image.dest_width >= 0);
    assert(image.dest_height >= 0);
    assert(atlas.bytes_per_pixel == 4);
    const rect = texturedRect(image, image.dest_width, image.dest_height, scale);
    const effects = raster.ImageEffects{
        .tint = image.tint.toColor(),
        .radii = .{
            .top_left = @max(image.corner_tl, 0.0) * scale,
            .top_right = @max(image.corner_tr, 0.0) * scale,
            .bottom_right = @max(image.corner_br, 0.0) * scale,
            .bottom_left = @max(image.corner_bl, 0.0) * scale,
        },
        .grayscale = std.math.clamp(image.grayscale, 0.0, 1.0),
        .opacity = std.math.clamp(image.opacity, 0.0, 1.0),
    };
    raster.drawImage(target, &rect, atlas, &effects);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// A small budget so test renderers reserve kilobytes, not megabytes.
const test_limits = limits_mod.ResourceLimits{
    .scene = scene_mod.SceneLimits.standard,
    .window = .{ .framebuffer_width_max = 16, .framebuffer_height_max = 16 },
    .frame = limits_mod.FrameLimits.nano,
    .atlas = limits_mod.AtlasLimits.standard,
};

const black = geometry.Color.rgba(0, 0, 0, 1);

fn testRenderer() !Renderer {
    var renderer: Renderer = undefined;
    try renderer.initInPlace(testing.allocator, &test_limits);
    return renderer;
}

test "draw scales logical bounds and draws later primitives on top" {
    // Goal: exercise the scene walk end to end. At scale 2 a logical quad at
    // (1, 1) of size 1 covers device pixels 2 and 3 only, and a later quad
    // that overlaps it wins because batches are drawn in insertion order.
    var scene = try scene_mod.Scene.initCapacity(testing.allocator, &test_limits.scene);
    defer scene.deinit();
    try scene.insertQuad(scene_mod.Quad.filled(1, 1, 1, 1, scene_mod.Hsla.red));
    const blue = scene_mod.Hsla.init(2.0 / 3.0, 1, 0.5, 1);
    try scene.insertQuad(scene_mod.Quad.filled(1.5, 1.5, 1, 1, blue));

    var renderer = try testRenderer();
    defer renderer.deinit(testing.allocator);
    var pixels: [6 * 6]u32 = undefined;
    const target = Target{ .pixels = &pixels, .width = 6, .height = 6, .stride = 6 };
    const stats = renderer.draw(target, &scene, .{ .scale_factor = 2 }, black);
    try testing.expectEqual(@as(u32, 2), stats.quads);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(1)[1]);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), target.row(2)[2]);
    try testing.expectEqual(@as(u32, 0xFF00_00FF), target.row(3)[3]);
    try testing.expectEqual(@as(u32, 0xFF00_00FF), target.row(4)[4]);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(5)[5]);
}

test "every mesh kind draws, in place, at the device scale" {
    // Goal: paths, polylines, point clouds, and colored point clouds all
    // reach pixels through the scene walk, none is skipped, and each honors
    // the logical-to-device scale. Each primitive sits in its own quadrant
    // of a 16x16 device target drawn at scale 2.
    var scene = try scene_mod.Scene.initCapacity(testing.allocator, &test_limits.scene);
    defer scene.deinit();
    // Path: logical triangle (0, 0) (3, 0) (0, 3), device (0, 0) (6, 0) (0, 6).
    try scene.insertTriangle(0, 0, 3, 0, 0, 3, scene_mod.Hsla.red);
    // Polyline: logical y = 1.5, width 1, x 4.5 to 8; device y 2 to 4.
    const line_points = [_]scene_mod.Point{ .{ .x = 4.5, .y = 1.5 }, .{ .x = 8, .y = 1.5 } };
    try scene.insertPolyline(scene_mod.Polyline.init(&line_points, 1, scene_mod.Hsla.white));
    // Point cloud: logical (2, 6), radius 1.5; device (4, 12), radius 3.
    const gray = scene_mod.Hsla.init(0, 0, 0.5, 1);
    const cloud_points = [_]scene_mod.Point{.{ .x = 2, .y = 6 }};
    try scene.insertPointCloud(scene_mod.PointCloud.init(&cloud_points, 1.5, gray));
    // Colored point cloud: one red point at logical (6, 6).
    const colored_points = [_]scene_mod.Point{.{ .x = 6, .y = 6 }};
    const colors = [_]scene_mod.Hsla{scene_mod.Hsla.red};
    const colored = scene_mod.ColoredPointCloud.init(&colored_points, &colors, 1.5);
    try scene.insertColoredPointCloud(colored);

    var renderer = try testRenderer();
    defer renderer.deinit(testing.allocator);
    var pixels: [16 * 16]u32 = undefined;
    const target = Target{ .pixels = &pixels, .width = 16, .height = 16, .stride = 16 };
    const stats = renderer.draw(target, &scene, .{ .scale_factor = 2 }, black);
    try testing.expectEqual(@as(u32, 1), stats.paths);
    try testing.expectEqual(@as(u32, 1), stats.polylines);
    try testing.expectEqual(@as(u32, 1), stats.point_clouds);
    try testing.expectEqual(@as(u32, 1), stats.colored_point_clouds);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), target.row(1)[1]);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(5)[5]);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), target.row(2)[12]);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), target.row(3)[12]);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(4)[12]);
    try testing.expectEqual(@as(u32, 0xFF80_8080), target.row(12)[4]);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), target.row(12)[12]);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(15)[8]);
}

test "a translucent polyline blends once where its segments overlap" {
    // Goal: the GPU's per-sample resolve covers each sample of a draw once,
    // so a V-shaped line at half alpha must not darken at its joint. Pixel
    // (3, 3) lies under both segments of (0, 0) (4, 4) (8, 0) at width 2;
    // blending each segment separately would lift its red byte above 128.
    var scene = try scene_mod.Scene.initCapacity(testing.allocator, &test_limits.scene);
    defer scene.deinit();
    const points = [_]scene_mod.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 4, .y = 4 },
        .{ .x = 8, .y = 0 },
    };
    const half_red = scene_mod.Hsla.init(0, 1, 0.5, 0.5);
    try scene.insertPolyline(scene_mod.Polyline.init(&points, 2, half_red));

    var renderer = try testRenderer();
    defer renderer.deinit(testing.allocator);
    var pixels: [8 * 8]u32 = undefined;
    const target = Target{ .pixels = &pixels, .width = 8, .height = 8, .stride = 8 };
    _ = renderer.draw(target, &scene, .{ .scale_factor = 1 }, black);
    try testing.expectEqual(@as(u32, 0xFF80_0000), target.row(3)[3]);
    for (pixels) |pixel| try testing.expect((pixel >> 16) & 0xFF <= 128);
}

test "a gradient path takes its color from the mesh uv at each pixel" {
    // Goal: the uv plane must come from the mesh, not from device position.
    // A logical 8x2 rectangle at x = 4 with a horizontal red-to-blue
    // gradient must be red at its left edge and blue at its right, wherever
    // the path sits on the target.
    var scene = try scene_mod.Scene.initCapacity(testing.allocator, &test_limits.scene);
    defer scene.deinit();
    const Vec2 = @import("../../geometry/vec2.zig").Vec2;
    const corners = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 8, .y = 0 },
        .{ .x = 8, .y = 2 },
        .{ .x = 0, .y = 2 },
    };
    const rectangle = try path_mesh.PathMesh.fromConvexPolygon(&corners);
    var gradient = scene_mod.LinearGradient.init(0, 0, 1, 0);
    _ = gradient.addStop(0, scene_mod.Hsla.red);
    _ = gradient.addStop(1, scene_mod.Hsla.init(2.0 / 3.0, 1, 0.5, 1));
    const reference = try scene.mesh_pool.allocateFrame(rectangle);
    const instance = scene_mod.PathInstance.initWithBufferRanges(
        reference,
        4,
        0,
        scene_mod.Hsla.black,
        0,
        0,
        @intCast(rectangle.indices.len),
    ).withLinearGradient(0, 0, 1, 0, gradient.stop_count);
    try scene.insertPathWithLinearGradient(instance, gradient);

    var renderer = try testRenderer();
    defer renderer.deinit(testing.allocator);
    var pixels: [16 * 2]u32 = undefined;
    const target = Target{ .pixels = &pixels, .width = 16, .height = 2, .stride = 16 };
    _ = renderer.draw(target, &scene, .{ .scale_factor = 1 }, black);
    const left = target.row(0)[4];
    const right = target.row(0)[11];
    try testing.expect((left >> 16) & 0xFF > 200);
    try testing.expect(left & 0xFF < 40);
    try testing.expect(right & 0xFF > 200);
    try testing.expect((right >> 16) & 0xFF < 40);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(0)[3]);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(0)[12]);
}
