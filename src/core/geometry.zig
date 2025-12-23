//! Core geometry types for the UI framework
//!
//! This module provides generic, reusable geometry primitives for application logic.
//! These types use comptime type parameters for flexibility.
//!
//! For GPU rendering, see the extern struct types in `scene.zig` which have
//! proper Metal alignment. Use the `toGpu*()` methods to convert.
//!
//! Type Hierarchy:
//! ==============
//! - geometry.zig: Generic types for app logic (Point(T), Size(T), etc.)
//! - scene.zig: GPU-aligned extern structs (Point, Size, Corners, etc.)
//!
//! Example:
//! ```zig
//! const geo = @import("geometry.zig");
//! const app_point = geo.PointF{ .x = 10, .y = 20 };
//! const gpu_point = app_point.toGpuPoint(); // Convert for rendering
//! ```

const std = @import("std");

// Forward declare GPU types to avoid circular imports
// These are the extern struct types from scene.zig
pub const GpuPoint = extern struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn init(x: f32, y: f32) GpuPoint {
        return .{ .x = x, .y = y };
    }

    pub const zero = GpuPoint{ .x = 0, .y = 0 };
};

pub const GpuSize = extern struct {
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(width: f32, height: f32) GpuSize {
        return .{ .width = width, .height = height };
    }

    pub const zero = GpuSize{ .width = 0, .height = 0 };
};

pub const GpuBounds = extern struct {
    origin: GpuPoint = .{},
    size: GpuSize = .{},

    pub fn init(x: f32, y: f32, width: f32, height: f32) GpuBounds {
        return .{
            .origin = GpuPoint.init(x, y),
            .size = GpuSize.init(width, height),
        };
    }

    pub const zero = GpuBounds{ .origin = GpuPoint.zero, .size = GpuSize.zero };
};

pub const GpuCorners = extern struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub fn all(radius: f32) GpuCorners {
        return .{
            .top_left = radius,
            .top_right = radius,
            .bottom_right = radius,
            .bottom_left = radius,
        };
    }

    pub const zero = GpuCorners{};
};

pub const GpuEdges = extern struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(width: f32) GpuEdges {
        return .{ .top = width, .right = width, .bottom = width, .left = width };
    }

    pub const zero = GpuEdges{};
};

// =============================================================================
// Unit Type Aliases
// =============================================================================

/// Logical pixels (before scaling)
pub const Pixels = f32;

/// Scaled pixels (after applying scale factor)
pub const ScaledPixels = f32;

// =============================================================================
// Point
// =============================================================================

/// A 2D point with x and y coordinates
pub fn Point(comptime T: type) type {
    return struct {
        x: T = 0,
        y: T = 0,

        const Self = @This();

        pub fn init(x_val: T, y_val: T) Self {
            return .{ .x = x_val, .y = y_val };
        }

        pub fn scale(self: Self, factor: T) Self {
            return .{ .x = self.x * factor, .y = self.y * factor };
        }

        pub fn add(self: Self, other: Self) Self {
            return .{ .x = self.x + other.x, .y = self.y + other.y };
        }

        pub fn sub(self: Self, other: Self) Self {
            return .{ .x = self.x - other.x, .y = self.y - other.y };
        }

        /// Convert to GPU-compatible point
        pub fn toGpuPoint(self: Self) GpuPoint {
            return .{
                .x = toF32(T, self.x),
                .y = toF32(T, self.y),
            };
        }

        pub const zero = Self{ .x = 0, .y = 0 };
    };
}

// =============================================================================
// Size
// =============================================================================

/// A 2D size with width and height
pub fn Size(comptime T: type) type {
    return struct {
        width: T = 0,
        height: T = 0,

        const Self = @This();

        pub fn init(w: T, h: T) Self {
            return .{ .width = w, .height = h };
        }

        pub fn scale(self: Self, factor: T) Self {
            return .{ .width = self.width * factor, .height = self.height * factor };
        }

        pub fn area(self: Self) T {
            return self.width * self.height;
        }

        /// Convert to GPU-compatible size
        pub fn toGpuSize(self: Self) GpuSize {
            return .{
                .width = toF32(T, self.width),
                .height = toF32(T, self.height),
            };
        }

        pub const zero = Self{ .width = 0, .height = 0 };
    };
}

// =============================================================================
// Rect / Bounds
// =============================================================================

/// A rectangle with origin point and size.
pub fn Rect(comptime T: type) type {
    return struct {
        origin: Point(T) = .{},
        size: Size(T) = .{},

        const Self = @This();

        pub fn init(x: T, y: T, w: T, h: T) Self {
            return .{
                .origin = .{ .x = x, .y = y },
                .size = .{ .width = w, .height = h },
            };
        }

        pub fn fromOriginSize(orig: Point(T), sz: Size(T)) Self {
            return .{ .origin = orig, .size = sz };
        }

        pub fn contains(self: Self, point: Point(T)) bool {
            return point.x >= self.origin.x and
                point.x < self.origin.x + self.size.width and
                point.y >= self.origin.y and
                point.y < self.origin.y + self.size.height;
        }

        pub fn containsPoint(self: Self, x: T, y: T) bool {
            return x >= self.origin.x and
                x < self.origin.x + self.size.width and
                y >= self.origin.y and
                y < self.origin.y + self.size.height;
        }

        pub fn inset(self: Self, edges: Edges(T)) Self {
            return .{
                .origin = .{
                    .x = self.origin.x + edges.left,
                    .y = self.origin.y + edges.top,
                },
                .size = .{
                    .width = @max(0, self.size.width - edges.horizontal()),
                    .height = @max(0, self.size.height - edges.vertical()),
                },
            };
        }

        pub fn scale(self: Self, factor: T) Self {
            return .{
                .origin = self.origin.scale(factor),
                .size = self.size.scale(factor),
            };
        }

        pub fn left(self: Self) T {
            return self.origin.x;
        }
        pub fn top(self: Self) T {
            return self.origin.y;
        }
        pub fn right(self: Self) T {
            return self.origin.x + self.size.width;
        }
        pub fn bottom(self: Self) T {
            return self.origin.y + self.size.height;
        }
        pub fn width(self: Self) T {
            return self.size.width;
        }
        pub fn height(self: Self) T {
            return self.size.height;
        }

        /// Convert to GPU-compatible bounds
        pub fn toGpuBounds(self: Self) GpuBounds {
            return .{
                .origin = self.origin.toGpuPoint(),
                .size = self.size.toGpuSize(),
            };
        }

        pub const zero = Self{};
    };
}

/// Alias for Rect
pub fn Bounds(comptime T: type) type {
    return Rect(T);
}

// =============================================================================
// Edges (for padding, margins, border widths)
// =============================================================================

pub fn Edges(comptime T: type) type {
    return struct {
        top: T = 0,
        right: T = 0,
        bottom: T = 0,
        left: T = 0,

        const Self = @This();

        pub fn all(value: T) Self {
            return .{ .top = value, .right = value, .bottom = value, .left = value };
        }

        pub fn symmetric(h: T, v: T) Self {
            return .{ .top = v, .right = h, .bottom = v, .left = h };
        }

        pub fn horizontal(self: Self) T {
            return self.left + self.right;
        }
        pub fn vertical(self: Self) T {
            return self.top + self.bottom;
        }

        /// Convert to GPU-compatible edges
        pub fn toGpuEdges(self: Self) GpuEdges {
            return .{
                .top = toF32(T, self.top),
                .right = toF32(T, self.right),
                .bottom = toF32(T, self.bottom),
                .left = toF32(T, self.left),
            };
        }

        pub const zero = Self{};
    };
}

// =============================================================================
// Corners (for border radii)
// =============================================================================

pub fn Corners(comptime T: type) type {
    return struct {
        top_left: T = 0,
        top_right: T = 0,
        bottom_right: T = 0,
        bottom_left: T = 0,

        const Self = @This();

        pub fn all(radius: T) Self {
            return .{ .top_left = radius, .top_right = radius, .bottom_right = radius, .bottom_left = radius };
        }

        /// Convert to GPU-compatible corners
        pub fn toGpuCorners(self: Self) GpuCorners {
            return .{
                .top_left = toF32(T, self.top_left),
                .top_right = toF32(T, self.top_right),
                .bottom_right = toF32(T, self.bottom_right),
                .bottom_left = toF32(T, self.bottom_left),
            };
        }

        pub const zero = Self{};
    };
}

// =============================================================================
// Color
// =============================================================================

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub fn init(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1.0 };
    }

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn rgb8(r: u8, g: u8, b: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = 1,
        };
    }

    pub fn hex(value: u32) Color {
        if (value > 0xFFFFFF) {
            return .{
                .r = @as(f32, @floatFromInt((value >> 24) & 0xFF)) / 255.0,
                .g = @as(f32, @floatFromInt((value >> 16) & 0xFF)) / 255.0,
                .b = @as(f32, @floatFromInt((value >> 8) & 0xFF)) / 255.0,
                .a = @as(f32, @floatFromInt(value & 0xFF)) / 255.0,
            };
        } else {
            return .{
                .r = @as(f32, @floatFromInt((value >> 16) & 0xFF)) / 255.0,
                .g = @as(f32, @floatFromInt((value >> 8) & 0xFF)) / 255.0,
                .b = @as(f32, @floatFromInt(value & 0xFF)) / 255.0,
                .a = 1.0,
            };
        }
    }

    pub fn withAlpha(self: Color, a: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }

    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const clear = transparent;
    pub const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const red = Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
    pub const green = Color{ .r = 0, .g = 1, .b = 0, .a = 1 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 1, .a = 1 };
    pub const yellow = Color{ .r = 1, .g = 1, .b = 0, .a = 1 };
    pub const cyan = Color{ .r = 0, .g = 1, .b = 1, .a = 1 };
    pub const magenta = Color{ .r = 1, .g = 0, .b = 1, .a = 1 };
    pub const orange = Color{ .r = 1, .g = 0.65, .b = 0, .a = 1 };
    pub const gold = Color{ .r = 1, .g = 0.84, .b = 0, .a = 1 };
    pub const purple = Color{ .r = 0.5, .g = 0, .b = 0.5, .a = 1 };
    pub const pink = Color{ .r = 1, .g = 0.75, .b = 0.8, .a = 1 };
    pub const gray = Color{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 };
};

// =============================================================================
// Concrete type aliases
// =============================================================================

pub const PointF = Point(Pixels);
pub const PointI = Point(i32);
pub const SizeF = Size(Pixels);
pub const SizeI = Size(i32);
pub const RectF = Rect(Pixels);
pub const RectI = Rect(i32);
pub const BoundsF = Bounds(Pixels);
pub const BoundsI = Bounds(i32);
pub const EdgesF = Edges(Pixels);
pub const EdgesI = Edges(i32);
pub const CornersF = Corners(Pixels);
pub const CornersI = Corners(i32);

// =============================================================================
// Helper Functions
// =============================================================================

/// Convert any numeric type to f32
fn toF32(comptime T: type, value: T) f32 {
    return switch (@typeInfo(T)) {
        .float => @floatCast(value),
        .int => @floatFromInt(value),
        .comptime_int => @floatFromInt(value),
        .comptime_float => @floatCast(value),
        else => @compileError("Cannot convert " ++ @typeName(T) ++ " to f32"),
    };
}

// =============================================================================
// Tests
// =============================================================================

test "point gpu conversion" {
    const p = PointF{ .x = 10.5, .y = 20.5 };
    const gpu = p.toGpuPoint();
    try std.testing.expectEqual(@as(f32, 10.5), gpu.x);
    try std.testing.expectEqual(@as(f32, 20.5), gpu.y);
}

test "point i32 gpu conversion" {
    const p = PointI{ .x = 10, .y = 20 };
    const gpu = p.toGpuPoint();
    try std.testing.expectEqual(@as(f32, 10.0), gpu.x);
    try std.testing.expectEqual(@as(f32, 20.0), gpu.y);
}

test "corners gpu conversion" {
    const c = CornersF.all(8.0);
    const gpu = c.toGpuCorners();
    try std.testing.expectEqual(@as(f32, 8.0), gpu.top_left);
    try std.testing.expectEqual(@as(f32, 8.0), gpu.bottom_right);
}
