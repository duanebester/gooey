//! ColoredPointCloud - Instanced circle rendering with per-point colors
//!
//! Like PointCloud, but each point can have a unique color. Ideal for:
//! - Heat maps with color-coded data points
//! - Scatter plots with categorical coloring
//! - Particle systems with varied colors
//! - Canvas demos with many colored dots
//!
//! ## Performance
//! Renders all points in a **single draw call** using GPU instancing.
//! Each point is a quad with SDF circle rendering in the fragment shader.
//! Per-point colors are passed as vertex attributes (not uniforms), enabling
//! true single-draw-call rendering for thousands of differently-colored points.
//!
//! ## Usage
//! ```
//! // Allocate from scene allocator (not stack)
//! const positions = try scene.allocator.alloc(Point, data.len);
//! const colors = try scene.allocator.alloc(Hsla, data.len);
//! for (data, 0..) |d, i| {
//!     positions[i] = .{ .x = scale_x(d.x), .y = scale_y(d.y) };
//!     colors[i] = color_scale(d.value);
//! }
//!
//! // Single draw call for all points with different colors!
//! try scene.insertColoredPointCloud(.{
//!     .positions = positions,
//!     .colors = colors,
//!     .count = @intCast(data.len),
//!     .radius = 4.0,
//! });
//! ```
//!
//! ## Comparison with PointCloud
//! - PointCloud: Uniform color, slightly smaller memory footprint
//! - ColoredPointCloud: Per-point colors, same GPU efficiency

const std = @import("std");
const scene = @import("scene.zig");

// =============================================================================
// Hard Limits (static memory allocation policy per CLAUDE.md)
// =============================================================================

/// Maximum points per colored cloud - prevents infinite loops and bounds GPU buffers
pub const MAX_POINTS_PER_COLORED_CLOUD: u32 = 65536;

/// Maximum point radius in pixels - sanity bound
pub const MAX_POINT_RADIUS: f32 = 1000.0;

// =============================================================================
// ColoredPoint - Position + Color pair for convenience
// =============================================================================

/// A single colored point (position + color).
/// Use this struct when building point arrays for ColoredPointCloud.
pub const ColoredPoint = extern struct {
    x: f32,
    y: f32,
    color: scene.Hsla,
};

// =============================================================================
// ColoredPointCloud - GPU-compatible instance data with per-point colors
// =============================================================================

/// GPU-ready instance data for colored point cloud rendering.
/// Each point has its own position AND color.
///
/// Memory layout is designed for efficient GPU upload:
/// - Positions and colors are separate arrays (structure-of-arrays)
/// - Both arrays should be allocated from the scene's frame allocator
pub const ColoredPointCloud = extern struct {
    // Draw order for z-index interleaving (8 bytes with padding)
    order: scene.DrawOrder = 0,
    _pad0: u32 = 0,

    // Position buffer info (16 bytes)
    positions_ptr: u64 = 0,
    count: u32 = 0,
    _pad1: u32 = 0,

    // Color buffer info (8 bytes)
    colors_ptr: u64 = 0,

    // Point radius in pixels (8 bytes with padding)
    radius: f32 = 4.0,
    _pad2: u32 = 0,

    // Clip bounds (16 bytes)
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    const Self = @This();

    /// Initialize colored point cloud with separate position and color arrays.
    /// Both arrays should be allocated from the scene's frame allocator.
    /// Arrays must have the same length.
    pub fn init(
        positions: []const scene.Point,
        colors: []const scene.Hsla,
        radius: f32,
    ) Self {
        // Assertions at API boundary (per CLAUDE.md: minimum 2 per function)
        std.debug.assert(positions.len >= 1); // Need at least 1 point
        std.debug.assert(positions.len == colors.len); // Same count
        std.debug.assert(positions.len <= MAX_POINTS_PER_COLORED_CLOUD);
        std.debug.assert(radius > 0 and radius <= MAX_POINT_RADIUS);
        std.debug.assert(!std.math.isNan(radius));

        return .{
            .positions_ptr = @intFromPtr(positions.ptr),
            .colors_ptr = @intFromPtr(colors.ptr),
            .count = @intCast(positions.len),
            .radius = radius,
        };
    }

    /// Initialize from an array of ColoredPoint structs.
    /// Positions and colors will be extracted to separate arrays.
    /// The caller must provide pre-allocated output arrays.
    pub fn initFromColoredPoints(
        points: []const ColoredPoint,
        out_positions: []scene.Point,
        out_colors: []scene.Hsla,
        radius: f32,
    ) Self {
        std.debug.assert(points.len >= 1);
        std.debug.assert(points.len <= MAX_POINTS_PER_COLORED_CLOUD);
        std.debug.assert(out_positions.len >= points.len);
        std.debug.assert(out_colors.len >= points.len);

        // Extract positions and colors (AoS to SoA conversion)
        for (points, 0..) |p, i| {
            out_positions[i] = .{ .x = p.x, .y = p.y };
            out_colors[i] = p.color;
        }

        return init(out_positions[0..points.len], out_colors[0..points.len], radius);
    }

    /// Get positions slice from stored pointer
    pub fn getPositions(self: Self) []const scene.Point {
        if (self.count == 0) return &[_]scene.Point{};
        const ptr: [*]const scene.Point = @ptrFromInt(@as(usize, @intCast(self.positions_ptr)));
        return ptr[0..self.count];
    }

    /// Get colors slice from stored pointer
    pub fn getColors(self: Self) []const scene.Hsla {
        if (self.count == 0) return &[_]scene.Hsla{};
        const ptr: [*]const scene.Hsla = @ptrFromInt(@as(usize, @intCast(self.colors_ptr)));
        return ptr[0..self.count];
    }

    /// Set clip bounds from ContentMask
    pub fn withClipBounds(self: Self, clip: scene.ContentMask.ClipBounds) Self {
        var inst = self;
        inst.clip_x = clip.x;
        inst.clip_y = clip.y;
        inst.clip_width = clip.width;
        inst.clip_height = clip.height;
        return inst;
    }

    /// Set clip bounds explicitly
    pub fn withClip(self: Self, x: f32, y: f32, clip_width: f32, clip_height: f32) Self {
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        std.debug.assert(clip_width >= 0 and clip_height >= 0);

        var inst = self;
        inst.clip_x = x;
        inst.clip_y = y;
        inst.clip_width = clip_width;
        inst.clip_height = clip_height;
        return inst;
    }

    /// Set point radius
    pub fn withRadius(self: Self, r: f32) Self {
        std.debug.assert(r > 0 and r <= MAX_POINT_RADIUS);
        std.debug.assert(!std.math.isNan(r));

        var inst = self;
        inst.radius = r;
        return inst;
    }

    /// Validate point cloud invariants (call before rendering)
    /// Per CLAUDE.md: assert the negative space too
    pub fn validate(self: *const Self) void {
        // Valid state assertions
        std.debug.assert(self.count >= 1); // Need at least 1 point
        std.debug.assert(self.count <= MAX_POINTS_PER_COLORED_CLOUD);
        std.debug.assert(self.radius > 0 and self.radius <= MAX_POINT_RADIUS);

        // Pointer validity (if we have points, pointers must be non-null)
        if (self.count > 0) {
            std.debug.assert(self.positions_ptr != 0);
            std.debug.assert(self.colors_ptr != 0);
        }

        // Clip bounds sanity
        std.debug.assert(self.clip_width >= 0 and self.clip_height >= 0);
    }

    /// Calculate the number of vertices needed for GPU rendering.
    /// Each point becomes a quad (4 vertices) for SDF circle rendering.
    pub fn vertexCount(self: Self) u32 {
        return self.count * 4;
    }

    /// Calculate the number of indices needed for GPU rendering.
    /// Each point quad needs 6 indices (2 triangles).
    pub fn indexCount(self: Self) u32 {
        return self.count * 6;
    }

    /// Calculate approximate bounding box of the point cloud.
    /// Includes radius expansion. Returns null if no valid points.
    pub fn bounds(self: Self) ?scene.Bounds {
        if (self.count < 1) return null;

        const positions = self.getPositions();
        var min_x: f32 = positions[0].x;
        var min_y: f32 = positions[0].y;
        var max_x: f32 = positions[0].x;
        var max_y: f32 = positions[0].y;

        for (positions[1..]) |p| {
            min_x = @min(min_x, p.x);
            min_y = @min(min_y, p.y);
            max_x = @max(max_x, p.x);
            max_y = @max(max_y, p.y);
        }

        // Expand by radius for circles
        return .{
            .origin = .{
                .x = min_x - self.radius,
                .y = min_y - self.radius,
            },
            .size = .{
                .width = (max_x - min_x) + self.radius * 2,
                .height = (max_y - min_y) + self.radius * 2,
            },
        };
    }
};

// =============================================================================
// Compile-time Assertions (per CLAUDE.md)
// =============================================================================

comptime {
    // Verify struct size is reasonable and aligned
    // Expected: 8 (order) + 16 (positions) + 8 (colors) + 8 (radius) + 16 (clip) = 56 bytes
    // Aligned to 8 bytes = 56 bytes
    if (@sizeOf(ColoredPointCloud) != 56) {
        @compileError(std.fmt.comptimePrint(
            "ColoredPointCloud must be 56 bytes for GPU alignment, got {}",
            .{@sizeOf(ColoredPointCloud)},
        ));
    }

    // Verify ColoredPoint is tightly packed for efficient arrays
    // Expected: 8 (x, y) + 16 (Hsla) = 24 bytes
    if (@sizeOf(ColoredPoint) != 24) {
        @compileError(std.fmt.comptimePrint(
            "ColoredPoint must be 24 bytes, got {}",
            .{@sizeOf(ColoredPoint)},
        ));
    }
}

// =============================================================================
// Tests
// =============================================================================

test "ColoredPointCloud size is 56 bytes" {
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(ColoredPointCloud));
}

test "ColoredPoint size is 24 bytes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ColoredPoint));
}

test "ColoredPointCloud init and getPositions/getColors" {
    const positions = [_]scene.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 50 },
        .{ .x = 200, .y = 25 },
    };
    const colors = [_]scene.Hsla{
        scene.Hsla.red,
        scene.Hsla.green,
        scene.Hsla.blue,
    };

    const cloud = ColoredPointCloud.init(&positions, &colors, 5.0);

    try std.testing.expectEqual(@as(u32, 3), cloud.count);
    try std.testing.expectEqual(@as(f32, 5.0), cloud.radius);

    const retrieved_pos = cloud.getPositions();
    try std.testing.expectEqual(@as(usize, 3), retrieved_pos.len);
    try std.testing.expectEqual(@as(f32, 100), retrieved_pos[1].x);

    const retrieved_colors = cloud.getColors();
    try std.testing.expectEqual(@as(usize, 3), retrieved_colors.len);
    try std.testing.expectEqual(scene.Hsla.green.h, retrieved_colors[1].h);
}

test "ColoredPointCloud withClip" {
    const positions = [_]scene.Point{.{ .x = 50, .y = 50 }};
    const colors = [_]scene.Hsla{scene.Hsla.white};

    const cloud = ColoredPointCloud.init(&positions, &colors, 4.0)
        .withClip(10, 20, 100, 200);

    try std.testing.expectEqual(@as(f32, 10), cloud.clip_x);
    try std.testing.expectEqual(@as(f32, 20), cloud.clip_y);
    try std.testing.expectEqual(@as(f32, 100), cloud.clip_width);
    try std.testing.expectEqual(@as(f32, 200), cloud.clip_height);
}

test "ColoredPointCloud vertexCount and indexCount" {
    const positions = [_]scene.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 50 },
        .{ .x = 100, .y = 0 },
        .{ .x = 150, .y = 50 },
    };
    const colors = [_]scene.Hsla{
        scene.Hsla.red,
        scene.Hsla.green,
        scene.Hsla.blue,
        scene.Hsla.white,
    };

    const cloud = ColoredPointCloud.init(&positions, &colors, 3.0);

    // 4 points = 16 vertices (4 per point quad)
    try std.testing.expectEqual(@as(u32, 16), cloud.vertexCount());
    // 4 points = 24 indices (6 per point quad)
    try std.testing.expectEqual(@as(u32, 24), cloud.indexCount());
}

test "ColoredPointCloud bounds calculation" {
    const positions = [_]scene.Point{
        .{ .x = 10, .y = 20 },
        .{ .x = 110, .y = 70 },
        .{ .x = 60, .y = 120 },
    };
    const colors = [_]scene.Hsla{
        scene.Hsla.red,
        scene.Hsla.green,
        scene.Hsla.blue,
    };

    const cloud = ColoredPointCloud.init(&positions, &colors, 5.0);
    const b = cloud.bounds() orelse unreachable;

    // min: (10, 20), max: (110, 120), radius: 5
    try std.testing.expectEqual(@as(f32, 5), b.origin.x); // 10 - 5
    try std.testing.expectEqual(@as(f32, 15), b.origin.y); // 20 - 5
    try std.testing.expectEqual(@as(f32, 110), b.size.width); // (110 - 10) + 10
    try std.testing.expectEqual(@as(f32, 110), b.size.height); // (120 - 20) + 10
}

test "ColoredPointCloud validate" {
    const positions = [_]scene.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 100 },
    };
    const colors = [_]scene.Hsla{
        scene.Hsla.red,
        scene.Hsla.blue,
    };

    const cloud = ColoredPointCloud.init(&positions, &colors, 2.5);
    cloud.validate(); // Should not panic
}

test "ColoredPointCloud withRadius" {
    const positions = [_]scene.Point{.{ .x = 0, .y = 0 }};
    const colors = [_]scene.Hsla{scene.Hsla.black};

    const cloud = ColoredPointCloud.init(&positions, &colors, 1.0)
        .withRadius(8.0);

    try std.testing.expectEqual(@as(f32, 8.0), cloud.radius);
}

test "ColoredPoint struct layout" {
    const point = ColoredPoint{
        .x = 10.0,
        .y = 20.0,
        .color = scene.Hsla.red,
    };

    try std.testing.expectEqual(@as(f32, 10.0), point.x);
    try std.testing.expectEqual(@as(f32, 20.0), point.y);
    try std.testing.expectEqual(scene.Hsla.red.h, point.color.h);
}
