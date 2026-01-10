//! Polyline - Efficient connected line segments for charts
//!
//! Designed for data visualization where thousands of connected points
//! need to be rendered efficiently. Uses line-strip rendering on GPU:
//! upload N points, get N-1 line segments with a single draw call.
//!
//! Unlike the general-purpose Path primitive (~67KB per path), Polyline
//! is lightweight: points are allocated from the scene's frame allocator,
//! not the stack, and no tessellation is required.
//!
//! ## Usage
//! ```
//! // Allocate points from scene allocator
//! const points = try scene.allocator.alloc(Point, data.len);
//! for (data, 0..) |d, i| {
//!     points[i] = .{ .x = scale_x(d.x), .y = scale_y(d.y) };
//! }
//!
//! // Single draw call for entire line
//! try scene.insertPolyline(.{
//!     .points = points,
//!     .point_count = @intCast(data.len),
//!     .width = 2.0,
//!     .color = Hsla.blue,
//! });
//! ```
//!
//! ## Performance vs Path
//! - Path: 67KB stack allocation + O(n²) tessellation per primitive
//! - Polyline: Zero stack overhead, GPU line-strip expansion

const std = @import("std");
const scene = @import("scene.zig");

// =============================================================================
// Hard Limits (static memory allocation policy per CLAUDE.md)
// =============================================================================

/// Maximum points per polyline - prevents infinite loops and bounds GPU buffers
pub const MAX_POLYLINE_POINTS: u32 = 8192;

/// Maximum line width in pixels - sanity bound
pub const MAX_LINE_WIDTH: f32 = 1000.0;

// =============================================================================
// Polyline - GPU-compatible instance data
// =============================================================================

/// GPU-ready instance data for polyline rendering.
/// Layout aligned for Metal/WebGPU compatibility.
///
/// The polyline shader expands each segment to a quad independently.
/// For typical chart use cases (thin lines, noisy data), this is acceptable.
/// A join_style option could be added later if miter/bevel/round joins are needed.
pub const Polyline = extern struct {
    // Draw order for z-index interleaving (8 bytes with padding)
    order: scene.DrawOrder = 0,
    _pad0: u32 = 0,

    // Point buffer info - stored as u64 for pointer, plus count (16 bytes)
    // Note: For GPU upload, renderer will copy points to vertex buffer
    points_ptr: u64 = 0, // Pointer stored as u64 for extern struct compatibility
    point_count: u32 = 0,
    _pad1: u32 = 0,

    // Line width in pixels (8 bytes with padding)
    width: f32 = 1.0,
    _pad2: u32 = 0,

    // Line color - must be at 16-byte aligned offset for Metal float4 (16 bytes)
    color: scene.Hsla = scene.Hsla.black,

    // Clip bounds (16 bytes)
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    const Self = @This();

    /// Initialize polyline with points slice and style.
    /// Points should be allocated from the scene's frame allocator.
    pub fn init(
        points: []const scene.Point,
        width: f32,
        color: scene.Hsla,
    ) Self {
        // Assertions at API boundary (per CLAUDE.md: minimum 2 per function)
        std.debug.assert(points.len >= 2); // Need at least 2 points for a line
        std.debug.assert(points.len <= MAX_POLYLINE_POINTS);
        std.debug.assert(width > 0 and width <= MAX_LINE_WIDTH);
        std.debug.assert(!std.math.isNan(width));

        return .{
            .points_ptr = @intFromPtr(points.ptr),
            .point_count = @intCast(points.len),
            .width = width,
            .color = color,
        };
    }

    /// Get points slice from stored pointer
    pub fn getPoints(self: Self) []const scene.Point {
        if (self.point_count == 0) return &[_]scene.Point{};
        const ptr: [*]const scene.Point = @ptrFromInt(@as(usize, @intCast(self.points_ptr)));
        return ptr[0..self.point_count];
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

    /// Set line width
    pub fn withWidth(self: Self, w: f32) Self {
        std.debug.assert(w > 0 and w <= MAX_LINE_WIDTH);
        std.debug.assert(!std.math.isNan(w));

        var inst = self;
        inst.width = w;
        return inst;
    }

    /// Set line color
    pub fn withColor(self: Self, c: scene.Hsla) Self {
        var inst = self;
        inst.color = c;
        return inst;
    }

    /// Validate polyline invariants (call before rendering)
    /// Per CLAUDE.md: assert the negative space too
    pub fn validate(self: *const Self) void {
        // Valid state assertions
        std.debug.assert(self.point_count >= 2); // Need at least 2 points for a line
        std.debug.assert(self.point_count <= MAX_POLYLINE_POINTS);
        std.debug.assert(self.width > 0 and self.width <= MAX_LINE_WIDTH);

        // Pointer validity (if we have points, pointer must be non-null)
        if (self.point_count > 0) {
            std.debug.assert(self.points_ptr != 0);
        }

        // Clip bounds sanity
        std.debug.assert(self.clip_width >= 0 and self.clip_height >= 0);
    }

    /// Calculate the number of vertices needed for GPU rendering.
    /// Each line segment becomes a quad (4 vertices), so N points = (N-1) * 4 vertices.
    pub fn vertexCount(self: Self) u32 {
        if (self.point_count < 2) return 0;
        return (self.point_count - 1) * 4;
    }

    /// Calculate the number of indices needed for GPU rendering.
    /// Each quad needs 6 indices (2 triangles).
    pub fn indexCount(self: Self) u32 {
        if (self.point_count < 2) return 0;
        return (self.point_count - 1) * 6;
    }

    /// Calculate approximate bounding box of the polyline.
    /// Includes line width expansion. Returns null if no valid points.
    pub fn bounds(self: Self) ?scene.Bounds {
        if (self.point_count < 2) return null;

        const pts = self.getPoints();
        var min_x: f32 = pts[0].x;
        var min_y: f32 = pts[0].y;
        var max_x: f32 = pts[0].x;
        var max_y: f32 = pts[0].y;

        for (pts[1..]) |p| {
            min_x = @min(min_x, p.x);
            min_y = @min(min_y, p.y);
            max_x = @max(max_x, p.x);
            max_y = @max(max_y, p.y);
        }

        // Expand by half line width for stroke
        const half_width = self.width * 0.5;
        return .{
            .origin = .{
                .x = min_x - half_width,
                .y = min_y - half_width,
            },
            .size = .{
                .width = (max_x - min_x) + self.width,
                .height = (max_y - min_y) + self.width,
            },
        };
    }
};

// =============================================================================
// Compile-time Assertions (per CLAUDE.md)
// =============================================================================

comptime {
    // Verify struct size is reasonable and aligned
    // Expected: 8 (order) + 16 (points) + 8 (width) + 16 (color) + 16 (clip) = 64 bytes
    if (@sizeOf(Polyline) != 64) {
        @compileError(std.fmt.comptimePrint(
            "Polyline must be 64 bytes for GPU alignment, got {}",
            .{@sizeOf(Polyline)},
        ));
    }

    // Verify color is at 16-byte aligned offset for Metal float4
    if (@offsetOf(Polyline, "color") != 32) {
        @compileError(std.fmt.comptimePrint(
            "Polyline.color must be at offset 32 for Metal float4 alignment, got {}",
            .{@offsetOf(Polyline, "color")},
        ));
    }

    // Verify clip bounds follow color at expected offset
    if (@offsetOf(Polyline, "clip_x") != 48) {
        @compileError(std.fmt.comptimePrint(
            "Polyline.clip_x must be at offset 48, got {}",
            .{@offsetOf(Polyline, "clip_x")},
        ));
    }
}

// =============================================================================
// Tests
// =============================================================================

test "Polyline size is 64 bytes" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Polyline));
}

test "Polyline color alignment" {
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Polyline, "color"));
}

test "Polyline init and getPoints" {
    const points = [_]scene.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 50 },
        .{ .x = 200, .y = 25 },
    };

    const polyline = Polyline.init(&points, 2.0, scene.Hsla.red);

    try std.testing.expectEqual(@as(u32, 3), polyline.point_count);
    try std.testing.expectEqual(@as(f32, 2.0), polyline.width);

    const retrieved = polyline.getPoints();
    try std.testing.expectEqual(@as(usize, 3), retrieved.len);
    try std.testing.expectEqual(@as(f32, 100), retrieved[1].x);
    try std.testing.expectEqual(@as(f32, 50), retrieved[1].y);
}

test "Polyline withClip" {
    const points = [_]scene.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 100 },
    };

    const polyline = Polyline.init(&points, 1.0, scene.Hsla.black)
        .withClip(10, 20, 100, 200);

    try std.testing.expectEqual(@as(f32, 10), polyline.clip_x);
    try std.testing.expectEqual(@as(f32, 20), polyline.clip_y);
    try std.testing.expectEqual(@as(f32, 100), polyline.clip_width);
    try std.testing.expectEqual(@as(f32, 200), polyline.clip_height);
}

test "Polyline vertexCount and indexCount" {
    const points = [_]scene.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 50 },
        .{ .x = 100, .y = 0 },
        .{ .x = 150, .y = 50 },
    };

    const polyline = Polyline.init(&points, 2.0, scene.Hsla.blue);

    // 4 points = 3 segments = 12 vertices (4 per segment)
    try std.testing.expectEqual(@as(u32, 12), polyline.vertexCount());
    // 4 points = 3 segments = 18 indices (6 per segment)
    try std.testing.expectEqual(@as(u32, 18), polyline.indexCount());
}

test "Polyline bounds calculation" {
    const points = [_]scene.Point{
        .{ .x = 10, .y = 20 },
        .{ .x = 110, .y = 70 },
        .{ .x = 60, .y = 120 },
    };

    const polyline = Polyline.init(&points, 4.0, scene.Hsla.green);
    const b = polyline.bounds() orelse unreachable;

    // min: (10, 20), max: (110, 120), width: 4 -> half_width: 2
    try std.testing.expectEqual(@as(f32, 8), b.origin.x); // 10 - 2
    try std.testing.expectEqual(@as(f32, 18), b.origin.y); // 20 - 2
    try std.testing.expectEqual(@as(f32, 104), b.size.width); // (110 - 10) + 4
    try std.testing.expectEqual(@as(f32, 104), b.size.height); // (120 - 20) + 4
}

test "Polyline validate" {
    const points = [_]scene.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 100 },
        .{ .x = 200, .y = 50 },
    };

    const polyline = Polyline.init(&points, 2.5, scene.Hsla.white);
    polyline.validate(); // Should not panic
}

test "Polyline withWidth" {
    const points = [_]scene.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 100 },
    };

    const polyline = Polyline.init(&points, 1.0, scene.Hsla.black)
        .withWidth(5.0);

    try std.testing.expectEqual(@as(f32, 5.0), polyline.width);
}

test "Polyline withColor" {
    const points = [_]scene.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 100 },
    };

    const polyline = Polyline.init(&points, 1.0, scene.Hsla.black)
        .withColor(scene.Hsla.red);

    try std.testing.expectEqual(scene.Hsla.red.h, polyline.color.h);
    try std.testing.expectEqual(scene.Hsla.red.s, polyline.color.s);
    try std.testing.expectEqual(scene.Hsla.red.l, polyline.color.l);
}
