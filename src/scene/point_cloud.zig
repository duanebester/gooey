//! PointCloud - instanced circle/marker rendering for charts.
//!
//! Renders thousands of uniform circles (scatter plots, markers) in a single
//! instanced draw call: upload N center positions, the fragment shader draws
//! each as an SDF circle. Unlike per-circle Path (~67KB stack each), positions
//! come from the scene frame allocator with zero stack overhead and no
//! tessellation. All points share one radius and color.

const std = @import("std");
const scene = @import("scene.zig");

// =============================================================================
// Hard Limits (static memory allocation policy per CLAUDE.md)
// =============================================================================

/// Maximum points per cloud - prevents infinite loops and bounds GPU buffers
pub const MAX_POINTS_PER_CLOUD: u32 = 65536;

/// Maximum point radius in pixels - sanity bound
pub const MAX_POINT_RADIUS: f32 = 1000.0;

// =============================================================================
// PointCloud - GPU-compatible instance data
// =============================================================================

/// GPU-ready instance data for point cloud rendering (Metal/WebGPU layout).
/// Per-point attributes (bubble charts, heatmaps) would need extensions; for
/// per-point colors use ColoredPointCloud.
pub const PointCloud = extern struct {
    order: scene.DrawOrder = 0,
    _pad0: u32 = 0,

    // Pointer stored as u64 for extern-struct compatibility; the renderer copies
    // positions into a vertex buffer at upload.
    positions_ptr: u64 = 0,
    count: u32 = 0,
    _pad1: u32 = 0,

    radius: f32 = 4.0,
    _pad2: u32 = 0,

    // color must sit at a 16-byte aligned offset for Metal float4.
    color: scene.Hsla = scene.Hsla.black,

    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    const Self = @This();

    /// Initialize point cloud with positions slice and style.
    /// Positions should be allocated from the scene's frame allocator.
    pub fn init(
        positions: []const scene.Point,
        radius: f32,
        color: scene.Hsla,
    ) Self {
        std.debug.assert(positions.len >= 1);
        std.debug.assert(positions.len <= MAX_POINTS_PER_CLOUD);
        std.debug.assert(radius > 0 and radius <= MAX_POINT_RADIUS);
        std.debug.assert(!std.math.isNan(radius));

        return .{
            .positions_ptr = @intFromPtr(positions.ptr),
            .count = @intCast(positions.len),
            .radius = radius,
            .color = color,
        };
    }

    /// Get positions slice from stored pointer
    pub fn getPositions(self: Self) []const scene.Point {
        if (self.count == 0) return &[_]scene.Point{};
        const ptr: [*]const scene.Point = @ptrFromInt(@as(usize, @intCast(self.positions_ptr)));
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

    /// Set point color
    pub fn withColor(self: Self, c: scene.Hsla) Self {
        var inst = self;
        inst.color = c;
        return inst;
    }

    /// Validate invariants before rendering (asserts the negative space too).
    pub fn validate(self: *const Self) void {
        std.debug.assert(self.count >= 1);
        std.debug.assert(self.count <= MAX_POINTS_PER_CLOUD);
        std.debug.assert(self.radius > 0 and self.radius <= MAX_POINT_RADIUS);
        if (self.count > 0) std.debug.assert(self.positions_ptr != 0);
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
    // Expected: 8 (order) + 16 (positions) + 8 (radius) + 16 (color) + 16 (clip) = 64 bytes
    if (@sizeOf(PointCloud) != 64) {
        @compileError(std.fmt.comptimePrint(
            "PointCloud must be 64 bytes for GPU alignment, got {}",
            .{@sizeOf(PointCloud)},
        ));
    }

    // Verify color is at 16-byte aligned offset for Metal float4
    if (@offsetOf(PointCloud, "color") != 32) {
        @compileError(std.fmt.comptimePrint(
            "PointCloud.color must be at offset 32 for Metal float4 alignment, got {}",
            .{@offsetOf(PointCloud, "color")},
        ));
    }

    // Verify clip bounds follow color at expected offset
    if (@offsetOf(PointCloud, "clip_x") != 48) {
        @compileError(std.fmt.comptimePrint(
            "PointCloud.clip_x must be at offset 48, got {}",
            .{@offsetOf(PointCloud, "clip_x")},
        ));
    }
}

// =============================================================================
// Tests
// =============================================================================

test "PointCloud size is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(PointCloud));
}

test "PointCloud color alignment" {
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(PointCloud, "color"));
}

test "PointCloud init and getPositions" {
    const positions = [_]scene.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 50 },
        .{ .x = 200, .y = 25 },
    };

    const cloud = PointCloud.init(&positions, 5.0, scene.Hsla.red);

    try std.testing.expectEqual(@as(u32, 3), cloud.count);
    try std.testing.expectEqual(@as(f32, 5.0), cloud.radius);

    const retrieved = cloud.getPositions();
    try std.testing.expectEqual(@as(usize, 3), retrieved.len);
    try std.testing.expectEqual(@as(f32, 100), retrieved[1].x);
    try std.testing.expectEqual(@as(f32, 50), retrieved[1].y);
}

test "PointCloud withClip" {
    const positions = [_]scene.Point{
        .{ .x = 50, .y = 50 },
    };

    const cloud = PointCloud.init(&positions, 4.0, scene.Hsla.black)
        .withClip(10, 20, 100, 200);

    try std.testing.expectEqual(@as(f32, 10), cloud.clip_x);
    try std.testing.expectEqual(@as(f32, 20), cloud.clip_y);
    try std.testing.expectEqual(@as(f32, 100), cloud.clip_width);
    try std.testing.expectEqual(@as(f32, 200), cloud.clip_height);
}

test "PointCloud vertexCount and indexCount" {
    const positions = [_]scene.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 50 },
        .{ .x = 100, .y = 0 },
        .{ .x = 150, .y = 50 },
    };

    const cloud = PointCloud.init(&positions, 3.0, scene.Hsla.blue);

    // 4 points = 16 vertices (4 per point quad)
    try std.testing.expectEqual(@as(u32, 16), cloud.vertexCount());
    // 4 points = 24 indices (6 per point quad)
    try std.testing.expectEqual(@as(u32, 24), cloud.indexCount());
}

test "PointCloud bounds calculation" {
    const positions = [_]scene.Point{
        .{ .x = 10, .y = 20 },
        .{ .x = 110, .y = 70 },
        .{ .x = 60, .y = 120 },
    };

    const cloud = PointCloud.init(&positions, 5.0, scene.Hsla.green);
    const b = cloud.bounds() orelse unreachable;

    // min: (10, 20), max: (110, 120), radius: 5
    try std.testing.expectEqual(@as(f32, 5), b.origin.x); // 10 - 5
    try std.testing.expectEqual(@as(f32, 15), b.origin.y); // 20 - 5
    try std.testing.expectEqual(@as(f32, 110), b.size.width); // (110 - 10) + 10
    try std.testing.expectEqual(@as(f32, 110), b.size.height); // (120 - 20) + 10
}

test "PointCloud validate" {
    const positions = [_]scene.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 100 },
        .{ .x = 200, .y = 50 },
    };

    const cloud = PointCloud.init(&positions, 2.5, scene.Hsla.white);
    cloud.validate(); // Should not panic
}

test "PointCloud withRadius" {
    const positions = [_]scene.Point{
        .{ .x = 0, .y = 0 },
    };

    const cloud = PointCloud.init(&positions, 1.0, scene.Hsla.black)
        .withRadius(8.0);

    try std.testing.expectEqual(@as(f32, 8.0), cloud.radius);
}

test "PointCloud withColor" {
    const positions = [_]scene.Point{
        .{ .x = 0, .y = 0 },
    };

    const cloud = PointCloud.init(&positions, 4.0, scene.Hsla.black)
        .withColor(scene.Hsla.red);

    try std.testing.expectEqual(scene.Hsla.red.h, cloud.color.h);
    try std.testing.expectEqual(scene.Hsla.red.s, cloud.color.s);
    try std.testing.expectEqual(scene.Hsla.red.l, cloud.color.l);
}

test "PointCloud single point" {
    const positions = [_]scene.Point{
        .{ .x = 50, .y = 75 },
    };

    const cloud = PointCloud.init(&positions, 10.0, scene.Hsla.blue);

    try std.testing.expectEqual(@as(u32, 1), cloud.count);
    try std.testing.expectEqual(@as(u32, 4), cloud.vertexCount());
    try std.testing.expectEqual(@as(u32, 6), cloud.indexCount());

    const b = cloud.bounds() orelse unreachable;
    try std.testing.expectEqual(@as(f32, 40), b.origin.x); // 50 - 10
    try std.testing.expectEqual(@as(f32, 65), b.origin.y); // 75 - 10
    try std.testing.expectEqual(@as(f32, 20), b.size.width); // 0 + 20
    try std.testing.expectEqual(@as(f32, 20), b.size.height); // 0 + 20
}
