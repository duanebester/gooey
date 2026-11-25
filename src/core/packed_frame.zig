const std = @import("std");
const geometry = @import("../geometry/geometry.zig");
const limits_mod = @import("limits.zig");
const reservation = @import("reservation.zig");
const mesh_edges = @import("../platform/mesh_edges.zig");

const assert = std.debug.assert;

pub const Rgba = [4]f32;

pub const Rect = [4]f32;

pub const Quad = extern struct {
    bounds: Rect,
    fill: Rgba,
    border_color: Rgba,
    corners: [4]f32,
    border_widths: [4]f32,
    offset: [2]f32,
    blur: f32,
    _pad: f32 = 0,
};

pub const Sprite = extern struct {
    bounds: Rect,
    uv: [4]f32,
    tint: Rgba,
    secondary: Rgba,
    corners: [4]f32,
    grayscale: f32,
    opacity: f32,
    _pad: [2]f32 = .{ 0, 0 },
};

pub const Mesh = extern struct {
    fill: Rgba,
    first: u32,
    count: u32,
    width: f32,
    edge_first: u32,
};

pub const MeshPoint = geometry.GpuPoint;

/// One custom-shader fill instance. `params_index` selects the instance's slot in the
/// frame's params bytes (stride `PaintLimits.shader_params_bytes_max`); the draw names
/// the shader.
pub const Custom = extern struct {
    bounds: Rect,
    corners: [4]f32,
    opacity: f32,
    params_index: u32,
    _pad: [2]f32 = .{ 0, 0 },
};

pub const EdgeModes = u32;

pub const Pipeline = enum(u8) {
    quad,
    glyph,
    svg,
    image,
    triangles,
    strip_expanded,
    point_instanced,
    custom,

    pub fn kind(self: Pipeline) Kind {
        return switch (self) {
            .quad => .quad,
            .glyph, .svg, .image => .sprite,
            .triangles, .strip_expanded, .point_instanced => .mesh,
            .custom => .custom,
        };
    }
};

pub const Kind = enum { quad, sprite, mesh, custom };

/// Pipelines every renderer builds at init. `.custom` is last and per app: a renderer
/// with Capabilities.custom_shaders builds one pipeline per declared shader instead.
pub const builtin_pipeline_count: u32 = @typeInfo(Pipeline).@"enum".field_names.len - 1;

/// The pipelines a renderer builds the same way for every app, with Pipeline's values.
pub const BuiltinPipeline = enum(u8) {
    quad,
    glyph,
    svg,
    image,
    triangles,
    strip_expanded,
    point_instanced,
};

comptime {
    assert(@backingInt(Pipeline.custom) == builtin_pipeline_count);
    const names = @typeInfo(BuiltinPipeline).@"enum".field_names;
    assert(names.len == builtin_pipeline_count);
    for (names, 0..) |name, index| {
        assert(@backingInt(@field(Pipeline, name)) == index);
    }
}

/// `shader` is the ShaderId (index in `App.shaders`) of a `.custom` draw, else 0.
pub const Draw = extern struct {
    pipeline: Pipeline,
    shader: u8 = 0,
    _pad: [2]u8 = .{ 0, 0 },
    clip: u32,
    first: u32,
    count: u32,
};

pub const clip_none: u32 = 0;
pub const clip_unbounded: Rect = .{ -1e9, -1e9, 2e9, 2e9 };

pub const Pool = enum {
    quads,
    shadows,
    glyphs,
    svgs,
    images,
    triangle_meshes,
    polylines,
    point_clouds,
    customs,

    pub fn limitName(self: Pool) []const u8 {
        return switch (self) {
            .quads => "quad_count_frame_max",
            .shadows => "shadow_count_frame_max",
            .glyphs => "glyph_count_frame_max",
            .svgs => "svg_count_frame_max",
            .images => "image_count_frame_max",
            .triangle_meshes => "path_count_frame_max",
            .polylines => "polyline_count_frame_max",
            .point_clouds => "point_cloud_count_frame_max",
            .customs => "custom_draw_count_frame_max",
        };
    }

    pub fn capacity(self: Pool, paint: *const limits_mod.PaintLimits) u32 {
        switch (self) {
            inline else => |pool| {
                const field = comptime pool.limitName();
                const result: u32 = @field(paint, field);
                assert(result > 0);
                assert(result <= @field(limits_mod.PaintLimits.ceiling, field));
                return result;
            },
        }
    }
};

pub const pool_count = @typeInfo(Pool).@"enum".field_names.len;

pub const Capacity = struct {
    paint: limits_mod.PaintLimits,
    paint_record_count_max: u32,
};

pub const PackedFrame = struct {
    quads: []Quad,
    quad_count: u32,
    sprites: []Sprite,
    sprite_count: u32,
    meshes: []Mesh,
    mesh_count: u32,
    edge_modes: []EdgeModes,
    triangle_count: u32,
    mesh_points: []const MeshPoint,
    customs: []Custom,
    custom_count: u32,
    /// The records frame's params bytes, `params_stride` per slot, set by pack.
    params: []const u8,
    params_stride: u32,
    /// `ShadeInput.time`: seconds from the frame clock, wrapped (shader.timeSeconds).
    shader_time_s: f32,
    clips: []Rect,
    clip_count: u32,
    draws: []Draw,
    draw_count: u32,
    counts: [pool_count]u32,
    limits: limits_mod.PaintLimits,
    frame_number: u64,
    edge_table: mesh_edges.EdgeTable,
    high_water: HighWater,

    const HighWater = struct {
        quads: u32 = 0,
        sprites: u32 = 0,
        meshes: u32 = 0,
        triangles: u32 = 0,
        customs: u32 = 0,
        clips: u32 = 0,
        draws: u32 = 0,
    };

    pub noinline fn initInPlace(self: *PackedFrame, capacity: *const Capacity) !void {
        const paint = &capacity.paint;
        assert(paint.check() == null);
        assert(capacity.paint_record_count_max > 0);
        self.quads = try reservation.reserve(Quad, quadCapacity(paint));
        errdefer reservation.release(Quad, self.quads, 0);
        self.sprites = try reservation.reserve(Sprite, spriteCapacity(paint));
        errdefer reservation.release(Sprite, self.sprites, 0);
        self.meshes = try reservation.reserve(Mesh, meshCapacity(paint));
        errdefer reservation.release(Mesh, self.meshes, 0);
        self.edge_modes = try reservation.reserve(EdgeModes, triangleCapacity(paint));
        errdefer reservation.release(EdgeModes, self.edge_modes, 0);
        self.customs = try reservation.reserve(Custom, paint.custom_draw_count_frame_max);
        errdefer reservation.release(Custom, self.customs, 0);
        self.clips = try reservation.reserve(Rect, capacity.paint_record_count_max + 1);
        errdefer reservation.release(Rect, self.clips, 0);
        self.draws = try reservation.reserve(Draw, capacity.paint_record_count_max);
        errdefer reservation.release(Draw, self.draws, 0);
        self.edge_table = .{};
        try self.edge_table.init(edgeCapacity(paint));
        self.limits = paint.*;
        self.high_water = .{};
        self.quad_count = 0;
        self.sprite_count = 0;
        self.mesh_count = 0;
        self.triangle_count = 0;
        self.custom_count = 0;
        self.params_stride = paint.shader_params_bytes_max;
        self.clip_count = 0;
        self.draw_count = 0;
        self.frame_number = 0;
        self.reset(0, &.{});
        assert(self.draw_count == 0);
        assert(self.clip_count == 1);
    }

    pub fn deinit(self: *PackedFrame) void {
        assert(self.quad_count <= self.quads.len);
        assert(self.clip_count >= 1);
        self.noteHighWater();
        const high = &self.high_water;
        self.edge_table.deinit();
        reservation.release(Draw, self.draws, high.draws);
        reservation.release(Rect, self.clips, high.clips);
        reservation.release(Custom, self.customs, high.customs);
        reservation.release(EdgeModes, self.edge_modes, high.triangles);
        reservation.release(Mesh, self.meshes, high.meshes);
        reservation.release(Sprite, self.sprites, high.sprites);
        reservation.release(Quad, self.quads, high.quads);
        self.* = undefined;
    }

    pub fn reset(self: *PackedFrame, frame_number: u64, mesh_points: []const MeshPoint) void {
        assert(frame_number >= self.frame_number);
        assert(self.clips.len > 0);
        self.noteHighWater();
        self.quad_count = 0;
        self.sprite_count = 0;
        self.mesh_count = 0;
        self.triangle_count = 0;
        self.custom_count = 0;
        self.draw_count = 0;
        self.counts = @splat(0);
        self.mesh_points = mesh_points;
        self.params = &.{};
        self.shader_time_s = 0;
        self.frame_number = frame_number;
        self.clips[clip_none] = clip_unbounded;
        self.clip_count = 1;
    }

    fn noteHighWater(self: *PackedFrame) void {
        assert(self.quad_count <= self.quads.len);
        assert(self.draw_count <= self.draws.len);
        assert(self.clip_count <= self.clips.len);
        const high = &self.high_water;
        high.quads = @max(high.quads, self.quad_count);
        high.sprites = @max(high.sprites, self.sprite_count);
        high.meshes = @max(high.meshes, self.mesh_count);
        high.triangles = @max(high.triangles, self.triangle_count);
        high.customs = @max(high.customs, self.custom_count);
        high.clips = @max(high.clips, self.clip_count);
        high.draws = @max(high.draws, self.draw_count);
    }

    pub fn drawList(self: *const PackedFrame) []const Draw {
        assert(self.draw_count <= self.draws.len);
        assert(self.draw_count <= self.quad_count + self.sprite_count + self.mesh_count +
            self.custom_count);
        return self.draws[0..self.draw_count];
    }

    pub fn quadList(self: *const PackedFrame) []const Quad {
        assert(self.quad_count <= self.quads.len);
        assert(self.quad_count == self.counts[@backingInt(Pool.quads)] +
            self.counts[@backingInt(Pool.shadows)]);
        return self.quads[0..self.quad_count];
    }

    pub fn spriteList(self: *const PackedFrame) []const Sprite {
        assert(self.sprite_count <= self.sprites.len);
        assert(self.sprite_count == self.counts[@backingInt(Pool.glyphs)] +
            self.counts[@backingInt(Pool.svgs)] + self.counts[@backingInt(Pool.images)]);
        return self.sprites[0..self.sprite_count];
    }

    pub fn meshList(self: *const PackedFrame) []const Mesh {
        assert(self.mesh_count <= self.meshes.len);
        assert(self.mesh_count == self.counts[@backingInt(Pool.triangle_meshes)] +
            self.counts[@backingInt(Pool.polylines)] + self.counts[@backingInt(Pool.point_clouds)]);
        return self.meshes[0..self.mesh_count];
    }

    pub fn customList(self: *const PackedFrame) []const Custom {
        assert(self.custom_count <= self.customs.len);
        assert(self.custom_count == self.counts[@backingInt(Pool.customs)]);
        return self.customs[0..self.custom_count];
    }

    /// The params bytes of one custom instance: a whole slot, zero past the shader's
    /// Params.
    pub fn customParams(self: *const PackedFrame, custom: *const Custom) []const u8 {
        assert(self.params_stride > 0);
        const offset = @as(u64, custom.params_index) * self.params_stride;
        assert(offset + self.params_stride <= self.params.len);
        return self.params[@intCast(offset)..][0..self.params_stride];
    }

    pub fn edgeModeList(self: *const PackedFrame) []const EdgeModes {
        assert(self.triangle_count <= self.edge_modes.len);
        if (self.triangle_count > 0) assert(self.counts[@backingInt(Pool.triangle_meshes)] > 0);
        return self.edge_modes[0..self.triangle_count];
    }

    pub fn clipList(self: *const PackedFrame) []const Rect {
        assert(self.clip_count >= 1);
        assert(self.clip_count <= self.clips.len);
        return self.clips[0..self.clip_count];
    }

    pub fn meshPoints(self: *const PackedFrame, mesh: *const Mesh) []const MeshPoint {
        assert(mesh.count > 0);
        assert(mesh.first + mesh.count <= self.mesh_points.len);
        return self.mesh_points[mesh.first..][0..mesh.count];
    }

    pub fn drawRange(
        self: *const PackedFrame,
        draw: *const Draw,
        comptime kind: Kind,
    ) KindSlice(kind) {
        assert(draw.pipeline.kind() == kind);
        assert(draw.count > 0);
        const items = switch (kind) {
            .quad => self.quadList(),
            .sprite => self.spriteList(),
            .mesh => self.meshList(),
            .custom => self.customList(),
        };
        assert(draw.first + draw.count <= items.len);
        return items[draw.first..][0..draw.count];
    }
};

fn KindSlice(comptime kind: Kind) type {
    return switch (kind) {
        .quad => []const Quad,
        .sprite => []const Sprite,
        .mesh => []const Mesh,
        .custom => []const Custom,
    };
}

pub fn quadCapacity(paint: *const limits_mod.PaintLimits) u32 {
    const count = @as(u64, paint.quad_count_frame_max) + paint.shadow_count_frame_max;
    assert(count > 0);
    assert(count <= std.math.maxInt(u32));
    return @intCast(count);
}

pub fn spriteCapacity(paint: *const limits_mod.PaintLimits) u32 {
    const count = @as(u64, paint.glyph_count_frame_max) + paint.svg_count_frame_max +
        paint.image_count_frame_max;
    assert(count > 0);
    assert(count <= std.math.maxInt(u32));
    return @intCast(count);
}

pub fn meshCapacity(paint: *const limits_mod.PaintLimits) u32 {
    const count = @as(u64, paint.path_count_frame_max) + paint.polyline_count_frame_max +
        paint.point_cloud_count_frame_max;
    assert(count > 0);
    assert(count <= std.math.maxInt(u32));
    return @intCast(count);
}

pub fn triangleCapacity(paint: *const limits_mod.PaintLimits) u32 {
    const vertex_count = paint.path_vertex_count_frame_max;
    assert(vertex_count > 0);
    const count = @max(@divFloor(vertex_count, 3), 1);
    if (vertex_count >= 3) assert(count * 3 <= vertex_count);
    return count;
}

pub fn edgeCapacity(paint: *const limits_mod.PaintLimits) u32 {
    const count = @max(paint.path_vertex_count_frame_max, 3);
    assert(count >= 3);
    assert(count >= paint.path_vertex_count_frame_max);
    return count;
}

pub fn paintBytes(paint: *const limits_mod.PaintLimits) u64 {
    var bytes: u64 = 0;
    bytes += @as(u64, quadCapacity(paint)) * @sizeOf(Quad);
    bytes += @as(u64, spriteCapacity(paint)) * @sizeOf(Sprite);
    bytes += @as(u64, meshCapacity(paint)) * @sizeOf(Mesh);
    bytes += @as(u64, triangleCapacity(paint)) * @sizeOf(EdgeModes);
    bytes += mesh_edges.table_bytes(edgeCapacity(paint));
    bytes += @as(u64, paint.custom_draw_count_frame_max) * @sizeOf(Custom);
    assert(bytes > 0);
    return bytes;
}

pub fn meshPointCapacity(paint: *const limits_mod.PaintLimits) u32 {
    const count = @as(u64, paint.path_vertex_count_frame_max) +
        paint.polyline_point_count_frame_max + paint.point_count_frame_max;
    assert(count > 0);
    assert(count <= std.math.maxInt(u32));
    return @intCast(count);
}

comptime {
    assert(@sizeOf(Quad) == 96);
    assert(@sizeOf(Sprite) == 96);
    assert(@sizeOf(Mesh) == 32);
    assert(@sizeOf(Draw) == 16);
    assert(@sizeOf(Custom) == 48);
    assert(@offsetOf(Custom, "params_index") == 36);
    assert(limits_mod.MAX_SHADERS <= std.math.maxInt(@FieldType(Draw, "shader")) + 1);
    assert(@sizeOf(MeshPoint) == 8);
    assert(@offsetOf(Quad, "offset") == 80);
    assert(@offsetOf(Quad, "offset") % 8 == 0);
    assert(@offsetOf(Quad, "blur") == 88);
    assert(@offsetOf(Sprite, "grayscale") == 80);
    assert(@offsetOf(Mesh, "first") == 16);
}
