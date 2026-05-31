//! ColoredPointCloud - instanced circle rendering with per-point colors.
//!
//! Like PointCloud, but each point carries its own color (heat maps, categorical
//! scatter plots, particles). Colors ride as vertex attributes rather than
//! uniforms, so thousands of differently-colored SDF circles still render in a
//! single instanced draw call — same GPU efficiency as PointCloud, slightly
//! larger footprint.

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

/// A single colored point (position + color), for building point arrays.
pub const ColoredPoint = extern struct {
    x: f32,
    y: f32,
    color: scene.Hsla,
};

// =============================================================================
// ColoredPointCloud - GPU-compatible instance data with per-point colors
// =============================================================================

/// GPU-ready instance data: positions and colors are kept as separate
/// structure-of-arrays buffers (both from the scene frame allocator) for
/// efficient GPU upload.
pub const ColoredPointCloud = extern struct {
    order: scene.DrawOrder = 0,
    _pad0: u32 = 0,

    positions_ptr: u64 = 0,
    count: u32 = 0,
    _pad1: u32 = 0,

    colors_ptr: u64 = 0,

    radius: f32 = 4.0,
    _pad2: u32 = 0,

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
        std.debug.assert(positions.len >= 1);
        std.debug.assert(positions.len == colors.len);
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

    /// Validate invariants before rendering (asserts the negative space too).
    pub fn validate(self: *const Self) void {
        std.debug.assert(self.count >= 1);
        std.debug.assert(self.count <= MAX_POINTS_PER_COLORED_CLOUD);
        std.debug.assert(self.radius > 0 and self.radius <= MAX_POINT_RADIUS);
        if (self.count > 0) {
            std.debug.assert(self.positions_ptr != 0);
            std.debug.assert(self.colors_ptr != 0);
        }
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
