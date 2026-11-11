//! The packed frame: what `pack` writes and every `Renderer.draw` reads
//! (contract §8 and §9, phase 5).
//!
//! Four kinds in one draw-ordered stream. Paint records already are that
//! stream (`records.Record`); packing lays them out for a GPU:
//!
//! - `Quad`: SDF fill, border, and blur. A shadow is a quad with `blur > 0`.
//! - `Sprite`: an atlas rectangle with tint, the SVG stroke colour, image
//!   corner radii, grayscale, and opacity. `Draw.pipeline` names the atlas.
//! - `Mesh`: a range of `mesh_points` with a topology and a solid fill.
//!   Triangles carry analytic edge modes in `edge_modes`; polylines and point
//!   clouds stay GPU-expanded.
//! - Clip: push and pop become one clip rectangle per draw (`Draw.clip`).
//!
//! A renderer walks `draws` in order. Each draw names one pipeline, a range of
//! that pipeline's instances, and the clip rectangle every pixel it writes
//! must lie in. Instance layouts are `extern` and 16-byte aligned, so a backend
//! copies each array into its GPU buffer as is and its shaders declare the
//! same structs. Colours are straight (not premultiplied) RGBA as the theme
//! wrote them; positions are logical pixels with the origin at the top left.
//!
//! Storage is reserved once, at the window's budget (`Capacity`), from fresh
//! pages, and nothing grows: `pack` fails fast naming the pool, its capacity,
//! and the frame when the app passes a limit it declared (CLAUDE.md §2).

const std = @import("std");
const geometry = @import("../geometry/geometry.zig");
const limits_mod = @import("limits.zig");
const reservation = @import("reservation.zig");
const mesh_edges = @import("../platform/mesh_edges.zig");

const assert = std.debug.assert;

/// Straight RGBA, each channel in 0..1.
pub const Rgba = [4]f32;

/// A rectangle: x, y, width, height in logical pixels.
pub const Rect = [4]f32;

/// A quad, or a shadow when `blur > 0`.
pub const Quad = extern struct {
    bounds: Rect,
    /// The fill, or the shadow's colour.
    fill: Rgba,
    border_color: Rgba,
    /// Radii: top left, top right, bottom right, bottom left.
    corners: [4]f32,
    /// Widths: top, right, bottom, left. Ignored by shadows.
    border_widths: [4]f32,
    /// Shadow blur radius; 0 draws a plain quad.
    blur: f32,
    /// A shadow's offset from `bounds`.
    offset: [2]f32,
    _pad: f32 = 0,
};

/// One atlas rectangle drawn into `bounds`.
pub const Sprite = extern struct {
    bounds: Rect,
    /// Atlas coordinates in 0..1: left, top, right, bottom.
    uv: [4]f32,
    /// Glyph colour, SVG fill, or image tint.
    tint: Rgba,
    /// SVG stroke colour; transparent for other atlases.
    secondary: Rgba,
    /// Image corner radii: top left, top right, bottom right, bottom left.
    corners: [4]f32,
    /// 0 keeps an image's colours, 1 draws it in grey.
    grayscale: f32,
    opacity: f32,
    _pad: [2]f32 = .{ 0, 0 },
};

/// One mesh: `mesh_points[first..][0..count]` drawn with its draw's topology.
pub const Mesh = extern struct {
    fill: Rgba,
    first: u32,
    count: u32,
    /// `strip_expanded`: the line's full width. `point_instanced`: the radius.
    /// `triangles`: 0.
    width: f32,
    /// `triangles`: the edge modes of this mesh's first triangle are
    /// `edge_modes[edge_first]`, one entry per triangle. Otherwise 0.
    edge_first: u32,
};

/// A mesh point in logical pixels; the records frame's pool, read in place.
pub const MeshPoint = geometry.GpuPoint;

/// How a triangle shader treats each of a triangle's three edges, two bits per
/// edge in order v0→v1, v1→v2, v2→v0 (`mesh_edges.EdgeMode`: 0 interior,
/// 1 fade, 2 underlap). See `mesh_edges.zig` for the anti-aliasing contract.
pub const EdgeModes = u32;

/// What one draw renders. Sprites name their atlas; meshes their topology.
pub const Pipeline = enum(u8) {
    quad,
    glyph,
    svg,
    image,
    triangles,
    strip_expanded,
    point_instanced,

    pub fn kind(self: Pipeline) Kind {
        return switch (self) {
            .quad => .quad,
            .glyph, .svg, .image => .sprite,
            .triangles, .strip_expanded, .point_instanced => .mesh,
        };
    }
};

pub const Kind = enum { quad, sprite, mesh };

/// Instances `first..first + count` of the pipeline's kind (`quads`,
/// `sprites`, or `meshes`), clipped to `clips[clip]`.
pub const Draw = extern struct {
    pipeline: Pipeline,
    _pad: [3]u8 = .{ 0, 0, 0 },
    clip: u32,
    first: u32,
    count: u32,
};

/// `clips[clip_none]`: the unbounded clip, in force outside every clip push.
pub const clip_none: u32 = 0;
pub const clip_unbounded: Rect = .{ -1e9, -1e9, 2e9, 2e9 };

/// Per-kind counts, checked against the scene limits the window reserved.
/// Pools share storage by kind (`quads` holds quads and shadows), but each
/// keeps the limit the app declared for it.
pub const Pool = enum {
    quads,
    shadows,
    glyphs,
    svgs,
    images,
    triangle_meshes,
    polylines,
    point_clouds,

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
        };
    }

    pub fn capacity(self: Pool, scene: *const limits_mod.SceneLimits) u32 {
        return switch (self) {
            .quads => scene.quad_count_frame_max,
            .shadows => scene.shadow_count_frame_max,
            .glyphs => scene.glyph_count_frame_max,
            .svgs => scene.svg_count_frame_max,
            .images => scene.image_count_frame_max,
            .triangle_meshes => scene.path_count_frame_max,
            .polylines => scene.polyline_count_frame_max,
            .point_clouds => scene.point_cloud_count_frame_max,
        };
    }
};

pub const pool_count = @typeInfo(Pool).@"enum".field_names.len;

/// What a packed frame reserves: the window's scene limits (including the
/// debugger's headroom in safe builds) and its paint record bound, which
/// bounds draws and clips because each record starts at most one of each.
pub const Capacity = struct {
    scene: limits_mod.SceneLimits,
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
    /// The records frame's mesh points, borrowed until the frame is drawn.
    mesh_points: []const MeshPoint,
    clips: []Rect,
    clip_count: u32,
    draws: []Draw,
    draw_count: u32,
    /// Per-pool counts of this frame, against `limits`.
    counts: [pool_count]u32,
    limits: limits_mod.SceneLimits,
    /// The tick that built the frame; names the frame in failures.
    frame_number: u64,
    /// Pack's scratch for classifying triangle edges; not renderer input.
    edge_table: mesh_edges.EdgeTable,
    high_water: HighWater,

    const HighWater = struct {
        quads: u32 = 0,
        sprites: u32 = 0,
        meshes: u32 = 0,
        triangles: u32 = 0,
        clips: u32 = 0,
        draws: u32 = 0,
    };

    pub noinline fn initInPlace(self: *PackedFrame, capacity: *const Capacity) !void {
        const scene = &capacity.scene;
        assert(scene.check() == null);
        assert(capacity.paint_record_count_max > 0);
        self.quads = try reservation.reserve(Quad, quadCapacity(scene));
        errdefer reservation.release(Quad, self.quads, 0);
        self.sprites = try reservation.reserve(Sprite, spriteCapacity(scene));
        errdefer reservation.release(Sprite, self.sprites, 0);
        self.meshes = try reservation.reserve(Mesh, meshCapacity(scene));
        errdefer reservation.release(Mesh, self.meshes, 0);
        self.edge_modes = try reservation.reserve(EdgeModes, triangleCapacity(scene));
        errdefer reservation.release(EdgeModes, self.edge_modes, 0);
        self.clips = try reservation.reserve(Rect, capacity.paint_record_count_max + 1);
        errdefer reservation.release(Rect, self.clips, 0);
        self.draws = try reservation.reserve(Draw, capacity.paint_record_count_max);
        errdefer reservation.release(Draw, self.draws, 0);
        self.edge_table = .{};
        try self.edge_table.init(@max(scene.path_vertex_count_frame_max, 3));
        self.limits = scene.*;
        self.high_water = .{};
        self.quad_count = 0;
        self.sprite_count = 0;
        self.mesh_count = 0;
        self.triangle_count = 0;
        self.clip_count = 0;
        self.draw_count = 0;
        self.frame_number = 0;
        self.reset(0, &.{});
        assert(self.draw_count == 0);
        assert(self.clip_count == 1);
    }

    pub fn deinit(self: *PackedFrame) void {
        assert(self.quad_count <= self.quads.len);
        self.noteHighWater();
        const high = &self.high_water;
        self.edge_table.deinit();
        reservation.release(Draw, self.draws, high.draws);
        reservation.release(Rect, self.clips, high.clips);
        reservation.release(EdgeModes, self.edge_modes, high.triangles);
        reservation.release(Mesh, self.meshes, high.meshes);
        reservation.release(Sprite, self.sprites, high.sprites);
        reservation.release(Quad, self.quads, high.quads);
        self.* = undefined;
    }

    /// Empty the frame for tick `frame_number`, borrowing its mesh points.
    /// Earlier contents stay in place but are unreachable: every reader bounds
    /// by the counts.
    pub fn reset(self: *PackedFrame, frame_number: u64, mesh_points: []const MeshPoint) void {
        assert(frame_number >= self.frame_number);
        assert(self.clips.len > 0);
        self.noteHighWater();
        self.quad_count = 0;
        self.sprite_count = 0;
        self.mesh_count = 0;
        self.triangle_count = 0;
        self.draw_count = 0;
        self.counts = @splat(0);
        self.mesh_points = mesh_points;
        self.frame_number = frame_number;
        self.clips[clip_none] = clip_unbounded;
        self.clip_count = 1;
    }

    fn noteHighWater(self: *PackedFrame) void {
        const high = &self.high_water;
        high.quads = @max(high.quads, self.quad_count);
        high.sprites = @max(high.sprites, self.sprite_count);
        high.meshes = @max(high.meshes, self.mesh_count);
        high.triangles = @max(high.triangles, self.triangle_count);
        high.clips = @max(high.clips, self.clip_count);
        high.draws = @max(high.draws, self.draw_count);
    }

    pub fn drawList(self: *const PackedFrame) []const Draw {
        assert(self.draw_count <= self.draws.len);
        return self.draws[0..self.draw_count];
    }

    pub fn quadList(self: *const PackedFrame) []const Quad {
        assert(self.quad_count <= self.quads.len);
        return self.quads[0..self.quad_count];
    }

    pub fn spriteList(self: *const PackedFrame) []const Sprite {
        assert(self.sprite_count <= self.sprites.len);
        return self.sprites[0..self.sprite_count];
    }

    pub fn meshList(self: *const PackedFrame) []const Mesh {
        assert(self.mesh_count <= self.meshes.len);
        return self.meshes[0..self.mesh_count];
    }

    pub fn edgeModeList(self: *const PackedFrame) []const EdgeModes {
        assert(self.triangle_count <= self.edge_modes.len);
        return self.edge_modes[0..self.triangle_count];
    }

    pub fn clipList(self: *const PackedFrame) []const Rect {
        assert(self.clip_count >= 1);
        assert(self.clip_count <= self.clips.len);
        return self.clips[0..self.clip_count];
    }

    /// The points of `mesh`, in place in the records frame.
    pub fn meshPoints(self: *const PackedFrame, mesh: *const Mesh) []const MeshPoint {
        assert(mesh.count > 0);
        assert(mesh.first + mesh.count <= self.mesh_points.len);
        return self.mesh_points[mesh.first..][0..mesh.count];
    }

    /// The instances of `draw`'s kind that it covers.
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
    };
}

/// Quads and shadows share the quad pipeline and its storage.
pub fn quadCapacity(scene: *const limits_mod.SceneLimits) u32 {
    const count = @as(u64, scene.quad_count_frame_max) + scene.shadow_count_frame_max;
    assert(count > 0);
    assert(count <= std.math.maxInt(u32));
    return @intCast(count);
}

pub fn spriteCapacity(scene: *const limits_mod.SceneLimits) u32 {
    const count = @as(u64, scene.glyph_count_frame_max) + scene.svg_count_frame_max +
        scene.image_count_frame_max;
    assert(count > 0);
    assert(count <= std.math.maxInt(u32));
    return @intCast(count);
}

pub fn meshCapacity(scene: *const limits_mod.SceneLimits) u32 {
    const count = @as(u64, scene.path_count_frame_max) + scene.polyline_count_frame_max +
        scene.point_cloud_count_frame_max;
    assert(count <= std.math.maxInt(u32));
    return @max(@as(u32, @intCast(count)), 1);
}

/// Triangle points are bounded by the path vertex budget, three per triangle.
pub fn triangleCapacity(scene: *const limits_mod.SceneLimits) u32 {
    return @max(@divFloor(scene.path_vertex_count_frame_max, 3), 1);
}

/// Points every mesh of a frame may hold: one pool for all three topologies.
pub fn meshPointCapacity(scene: *const limits_mod.SceneLimits) u32 {
    const count = @as(u64, scene.path_vertex_count_frame_max) +
        scene.polyline_point_count_frame_max + scene.point_count_frame_max;
    assert(count <= std.math.maxInt(u32));
    return @intCast(count);
}

comptime {
    // GPU layouts: every field a 4-byte scalar, structs 16-byte multiples.
    assert(@sizeOf(Quad) == 96);
    assert(@sizeOf(Sprite) == 96);
    assert(@sizeOf(Mesh) == 32);
    assert(@sizeOf(Draw) == 16);
    assert(@sizeOf(MeshPoint) == 8);
    assert(@offsetOf(Quad, "blur") == 80);
    assert(@offsetOf(Sprite, "grayscale") == 80);
    assert(@offsetOf(Mesh, "first") == 16);
}
