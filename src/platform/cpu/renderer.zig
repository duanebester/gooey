const std = @import("std");
const geometry = @import("../../geometry/geometry.zig");
const limits_mod = @import("../../core/limits.zig");
const packed_mod = @import("../../core/packed_frame.zig");
const backend = @import("../../core/backend.zig");
const reservation = @import("../../core/reservation.zig");
pub const raster = @import("raster.zig");
pub const mesh = @import("mesh.zig");

const assert = std.debug.assert;
const Target = raster.Target;
const PackedFrame = packed_mod.PackedFrame;

pub const scale_factor_max: f32 = 8.0;

pub const Viewport = struct {
    scale_factor: f32,
};

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

const AtlasTexture = struct {
    data: []u8,
    size: u32,
    bytes_per_pixel: u8,
    rows_used: u32,

    fn init(size: u32, bytes_per_pixel: u8) !AtlasTexture {
        assert(size > 0);
        assert(bytes_per_pixel == 1 or bytes_per_pixel == 4);
        const byte_count = @as(u64, size) * size * bytes_per_pixel;
        assert(byte_count <= std.math.maxInt(u32));
        const data = try reservation.reserve(u8, @intCast(byte_count));
        return .{ .data = data, .size = size, .bytes_per_pixel = bytes_per_pixel, .rows_used = 0 };
    }

    fn deinit(self: *AtlasTexture) void {
        assert(self.rows_used <= self.size);
        const row_bytes = @as(usize, self.size) * self.bytes_per_pixel;
        reservation.release(u8, self.data, row_bytes * self.rows_used);
        self.* = undefined;
    }

    fn write(self: *AtlasTexture, dirty: backend.RectPx, pixels: []const u8) void {
        assert(dirty.x + dirty.width <= self.size);
        assert(dirty.y + dirty.height <= self.size);
        const source_row_bytes = @as(usize, dirty.width) * self.bytes_per_pixel;
        assert(pixels.len == source_row_bytes * dirty.height);
        const target_row_bytes = @as(usize, self.size) * self.bytes_per_pixel;
        var row: u32 = 0;
        while (row < dirty.height) : (row += 1) {
            const target_start = (@as(usize, dirty.y) + row) * target_row_bytes +
                @as(usize, dirty.x) * self.bytes_per_pixel;
            const source = pixels[@as(usize, row) * source_row_bytes ..][0..source_row_bytes];
            @memcpy(self.data[target_start..][0..source_row_bytes], source);
        }
        self.rows_used = @max(self.rows_used, dirty.y + dirty.height);
    }

    fn view(self: *const AtlasTexture) raster.AtlasView {
        assert(self.data.len == @as(usize, self.size) * self.size * self.bytes_per_pixel);
        assert(self.size > 0);
        return .{ .data = self.data, .size = self.size, .bytes_per_pixel = self.bytes_per_pixel };
    }
};

const AtlasSlot = enum(u8) { glyph, svg, image };

pub const Renderer = struct {
    width_max: u32,
    height_max: u32,
    shadow_profile: []raster.Premul,
    mesh_scratch: mesh.Scratch,
    atlases: [3]AtlasTexture,

    pub fn initInPlace(self: *Renderer, limits: *const backend.RenderLimits) !void {
        assert(limits.window.framebuffer_width_max > 0);
        assert(limits.window.framebuffer_height_max > 0);
        const width_max = limits.window.framebuffer_width_max;
        const height_max = limits.window.framebuffer_height_max;
        const polygon_count_max = polygonCountMax(&limits.paint);

        self.width_max = width_max;
        self.height_max = height_max;
        self.shadow_profile = try reservation.reserve(raster.Premul, width_max);
        errdefer reservation.release(raster.Premul, self.shadow_profile, width_max);
        try self.initMeshScratch(polygon_count_max);
        errdefer self.deinitMeshScratch();
        try self.initAtlases(&limits.atlas);
        assert(self.mesh_scratch.mask.len == width_max);
        assert(self.mesh_scratch.heads.len == height_max);
    }

    fn initMeshScratch(self: *Renderer, polygon_count_max: u32) !void {
        assert(polygon_count_max > 0);
        assert(self.width_max > 0);
        const polygons = try reservation.reserve(mesh.Polygon, polygon_count_max);
        errdefer reservation.release(mesh.Polygon, polygons, polygons.len);

        const next = try reservation.reserve(u32, polygon_count_max);
        errdefer reservation.release(u32, next, next.len);

        const active = try reservation.reserve(u32, polygon_count_max);
        errdefer reservation.release(u32, active, active.len);

        const heads = try reservation.reserve(u32, self.height_max);
        errdefer reservation.release(u32, heads, heads.len);

        const mask = try reservation.reserve(u8, self.width_max);
        self.mesh_scratch = .{
            .polygons = polygons,
            .next = next,
            .active = active,
            .heads = heads,
            .mask = mask,
        };
    }

    fn deinitMeshScratch(self: *Renderer) void {
        const scratch = &self.mesh_scratch;
        assert(scratch.next.len == scratch.polygons.len);
        assert(scratch.active.len == scratch.polygons.len);
        reservation.release(u8, scratch.mask, scratch.mask.len);
        reservation.release(u32, scratch.heads, scratch.heads.len);
        reservation.release(u32, scratch.active, scratch.active.len);
        reservation.release(u32, scratch.next, scratch.next.len);
        reservation.release(mesh.Polygon, scratch.polygons, scratch.polygons.len);
    }

    fn initAtlases(self: *Renderer, limits: *const limits_mod.AtlasLimits) !void {
        assert(limits.text_size > 0);
        assert(limits.image_size > 0);
        const glyph = &self.atlases[@backingInt(AtlasSlot.glyph)];
        glyph.* = try AtlasTexture.init(limits.text_size, 1);
        errdefer glyph.deinit();
        const svg = &self.atlases[@backingInt(AtlasSlot.svg)];
        svg.* = try AtlasTexture.init(limits.svg_size, 4);
        errdefer svg.deinit();
        self.atlases[@backingInt(AtlasSlot.image)] = try AtlasTexture.init(limits.image_size, 4);
    }

    pub fn deinit(self: *Renderer) void {
        assert(self.shadow_profile.len == self.width_max);
        assert(self.mesh_scratch.heads.len == self.height_max);
        for (&self.atlases) |*atlas| atlas.deinit();
        self.deinitMeshScratch();
        reservation.release(raster.Premul, self.shadow_profile, self.shadow_profile.len);
        self.* = undefined;
    }

    pub fn uploadAtlas(
        self: *Renderer,
        kind: backend.AtlasKind,
        dirty: backend.RectPx,
        pixels: []const u8,
    ) void {
        assert(dirty.width > 0);
        assert(dirty.height > 0);
        const slot: AtlasSlot = switch (kind) {
            .glyph => .glyph,
            .svg => .svg,
            .image => .image,
            .glyph_color => std.debug.panic("CPU renderer: no colour glyph atlas; pack emits " ++
                "no glyph_color sprites yet", .{}),
        };
        self.atlases[@backingInt(slot)].write(dirty, pixels);
    }

    pub fn capabilities(self: *const Renderer) backend.Capabilities {
        assert(self.width_max > 0);
        assert(self.height_max > 0);
        return .{ .meshes = true };
    }

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
        for (frame.drawList()) |*packed_draw| walk.drawOne(packed_draw);
        return walk.stats;
    }
};

fn polygonCountMax(limits: *const limits_mod.PaintLimits) u32 {
    assert(limits.check() == null);
    const triangle_points_max = @min(
        limits_mod.MAX_PATH_VERTICES,
        limits.path_vertex_count_frame_max,
    );
    const triangle_count_max = @divFloor(triangle_points_max, 3);
    const segment_count_max = limits.polyline_point_count_frame_max -| 1;
    const count_max = @max(triangle_count_max, segment_count_max, 1);
    assert(count_max >= triangle_count_max);
    assert(count_max <= @max(limits.polyline_point_count_frame_max, triangle_count_max));
    return count_max;
}

const Walk = struct {
    renderer: *Renderer,
    target: Target,
    frame: *const PackedFrame,
    scale: f32,
    stats: RenderStats = .{},

    fn drawOne(self: *Walk, packed_draw: *const packed_mod.Draw) void {
        assert(packed_draw.count > 0);
        assert(packed_draw.clip < self.frame.clip_count);
        const logical_clip = self.frame.clips[packed_draw.clip];
        assert(logical_clip[2] > 0);
        assert(logical_clip[3] > 0);
        const clip = deviceRect(logical_clip, self.scale);
        switch (packed_draw.pipeline.kind()) {
            .quad => for (self.frame.drawRange(packed_draw, .quad)) |*quad| {
                self.drawQuad(quad, clip);
            },
            .sprite => self.drawSprites(packed_draw, clip),
            .mesh => self.drawMeshes(packed_draw, clip),
        }
    }

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
                const atlas = atlases[@backingInt(AtlasSlot.glyph)].view();
                for (sprites) |*sprite| drawGlyph(self.target, sprite, atlas, clip, self.scale);
                self.stats.glyphs += count;
            },
            .svg => {
                const atlas = atlases[@backingInt(AtlasSlot.svg)].view();
                for (sprites) |*sprite| drawSvg(self.target, sprite, atlas, clip, self.scale);
                self.stats.svgs += count;
            },
            .image => {
                const atlas = atlases[@backingInt(AtlasSlot.image)].view();
                for (sprites) |*sprite| drawImage(self.target, sprite, atlas, clip, self.scale);
                self.stats.images += count;
            },
            .quad, .triangles, .strip_expanded, .point_instanced => unreachable,
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
            .quad, .glyph, .svg, .image => unreachable,
        }
    }

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

const testing = std.testing;

const test_limits = backend.RenderLimits{
    .paint = limits_mod.PaintLimits.nano,
    .window = .{ .framebuffer_width_max = 16, .framebuffer_height_max = 16 },
    .frame = limits_mod.FrameLimits.nano,
    .atlas = limits_mod.AtlasLimits.nano,
};

const black = geometry.Color.rgba(0, 0, 0, 1);
const red: packed_mod.Rgba = .{ 1, 0, 0, 1 };
const blue: packed_mod.Rgba = .{ 0, 0, 1, 1 };

fn testRenderer() !Renderer {
    var renderer: Renderer = undefined;
    try renderer.initInPlace(&test_limits);
    return renderer;
}

fn testFrame(frame: *PackedFrame, points: []const packed_mod.MeshPoint) !void {
    try frame.initInPlace(&.{ .paint = test_limits.paint, .paint_record_count_max = 16 });
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
    const pool: packed_mod.Pool = if (quad.blur > 0) .shadows else .quads;
    frame.counts[@backingInt(pool)] += 1;
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
    const pool: packed_mod.Pool = switch (pipeline) {
        .triangles => .triangle_meshes,
        .strip_expanded => .polylines,
        .point_instanced => .point_clouds,
        .quad, .glyph, .svg, .image => unreachable,
    };
    frame.counts[@backingInt(pool)] += 1;
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

fn testMesh(fill: packed_mod.Rgba, first: u32, count: u32, width: f32) packed_mod.Mesh {
    return .{ .fill = fill, .first = first, .count = count, .width = width, .edge_first = 0 };
}

test "draw scales logical bounds and draws later draws on top" {
    var frame: PackedFrame = undefined;
    try testFrame(&frame, &.{});
    defer frame.deinit();
    appendQuad(&frame, testQuad(.{ 1, 1, 1, 1 }, red, 0), packed_mod.clip_none);
    appendQuad(&frame, testQuad(.{ 1.5, 1.5, 1, 1 }, blue, 0), packed_mod.clip_none);

    var renderer = try testRenderer();
    defer renderer.deinit();
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
    const points = [_]packed_mod.MeshPoint{
        .{ .x = 0, .y = 0 },     .{ .x = 3, .y = 0 },   .{ .x = 0, .y = 3 },
        .{ .x = 4.5, .y = 1.5 }, .{ .x = 8, .y = 1.5 }, .{ .x = 2, .y = 6 },
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
    defer renderer.deinit();
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
    defer renderer.deinit();
    var pixels: [8 * 8]u32 = undefined;
    const target = Target{ .pixels = &pixels, .width = 8, .height = 8, .stride = 8 };
    _ = renderer.draw(target, &frame, .{ .scale_factor = 1 }, black);
    try testing.expectEqual(@as(u32, 0xFF80_0000), target.row(3)[3]);
    for (pixels) |pixel| try testing.expect((pixel >> 16) & 0xFF <= 128);
}

test "each draw keeps to its own clip, shadows and meshes included" {
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
    defer renderer.deinit();
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

test "uploadAtlas places rows where sprites sample them" {
    var frame: PackedFrame = undefined;
    try testFrame(&frame, &.{});
    defer frame.deinit();
    var renderer = try testRenderer();
    defer renderer.deinit();
    const block: [16]u8 = @splat(255);
    renderer.uploadAtlas(.glyph, .{ .x = 8, .y = 4, .width = 4, .height = 4 }, &block);

    const texel: f32 = 1.0 / 512.0;
    frame.sprites[0] = .{
        .bounds = .{ 1, 1, 2, 2 },
        .uv = .{ 9 * texel, 5 * texel, 11 * texel, 7 * texel },
        .tint = red,
        .secondary = .{ 0, 0, 0, 0 },
        .corners = @splat(0),
        .grayscale = 0,
        .opacity = 1,
    };
    frame.sprite_count = 1;
    frame.counts[@backingInt(packed_mod.Pool.glyphs)] = 1;
    appendDraw(&frame, .glyph, 0, packed_mod.clip_none);

    var pixels: [4 * 4]u32 = undefined;
    const target = Target{ .pixels = &pixels, .width = 4, .height = 4, .stride = 4 };
    const stats = renderer.draw(target, &frame, .{ .scale_factor = 1 }, black);
    try testing.expectEqual(@as(u32, 1), stats.glyphs);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), target.row(1)[1]);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), target.row(2)[2]);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(0)[0]);
    try testing.expectEqual(@as(u32, 0xFF00_0000), target.row(3)[3]);
}
