//! 2D math vector and index slice primitives
//!
//! `Vec2` is a computation-oriented 2D vector with math operations (dot, cross,
//! lengthSq) used by triangulation, stroke expansion, and path building.
//!
//! This is distinct from `geometry.Point(T)` which serves layout/positioning.
//! `Vec2` is always `f32` and carries no unit semantics — it's for raw geometry
//! math on the data plane.
//!
//! `IndexSlice` describes a contiguous range of vertex indices within a shared
//! buffer, used to delineate sub-polygons inside a flattened path.

const std = @import("std");

// =============================================================================
// Vec2
// =============================================================================

/// A 2D vector for geometry computation (triangulation, strokes, paths).
/// Always f32 — no unit type parameter, no GPU alignment constraints.
pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn scale(self: Vec2, s: f32) Vec2 {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    pub fn dot(self: Vec2, other: Vec2) f32 {
        return self.x * other.x + self.y * other.y;
    }

    pub fn cross(self: Vec2, other: Vec2) f32 {
        return self.x * other.y - self.y * other.x;
    }

    pub fn lengthSq(self: Vec2) f32 {
        return self.x * self.x + self.y * self.y;
    }

    /// Euclidean length. Prefer `lengthSq` when comparing magnitudes.
    pub fn length(self: Vec2) f32 {
        return @sqrt(self.lengthSq());
    }

    /// Unit vector in the same direction. Returns (1, 0) for degenerate
    /// (near-zero) inputs so callers never see NaN.
    pub fn normalize(self: Vec2) Vec2 {
        const len_sq = self.lengthSq();
        if (len_sq < 1e-12) {
            return Vec2{ .x = 1, .y = 0 }; // Default direction for degenerate vectors.
        }
        const inv_len = 1.0 / @sqrt(len_sq);
        return self.scale(inv_len);
    }

    /// Negate both components. Avoids the multiply in `.scale(-1)`.
    pub fn negate(self: Vec2) Vec2 {
        return .{ .x = -self.x, .y = -self.y };
    }

    /// Perpendicular vector (90° counter-clockwise rotation).
    pub fn perp(self: Vec2) Vec2 {
        return .{ .x = -self.y, .y = self.x };
    }

    pub const zero = Vec2{ .x = 0, .y = 0 };
};

// =============================================================================
// IndexSlice
// =============================================================================

/// A half-open range [start, end) of vertex indices within a shared buffer.
/// Used to delineate individual polygons inside a flattened multi-polygon path.
pub const IndexSlice = struct {
    start: u32,
    end: u32,

    /// Number of indices in the range. Asserts `end >= start`.
    pub fn len(self: IndexSlice) u32 {
        std.debug.assert(self.end >= self.start);
        return self.end - self.start;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Vec2 arithmetic" {
    const a = Vec2{ .x = 3, .y = 4 };
    const b = Vec2{ .x = 1, .y = 2 };

    const sum = a.add(b);
    try std.testing.expectApproxEqAbs(@as(f32, 4), sum.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6), sum.y, 1e-6);

    const diff = a.sub(b);
    try std.testing.expectApproxEqAbs(@as(f32, 2), diff.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2), diff.y, 1e-6);

    const scaled = a.scale(2);
    try std.testing.expectApproxEqAbs(@as(f32, 6), scaled.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 8), scaled.y, 1e-6);
}

test "Vec2 dot and cross" {
    const a = Vec2{ .x = 1, .y = 0 };
    const b = Vec2{ .x = 0, .y = 1 };

    // Perpendicular vectors: dot = 0, cross = ±1.
    try std.testing.expectApproxEqAbs(@as(f32, 0), a.dot(b), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), a.cross(b), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), b.cross(a), 1e-6);
}

test "Vec2 lengthSq" {
    const v = Vec2{ .x = 3, .y = 4 };
    try std.testing.expectApproxEqAbs(@as(f32, 25), v.lengthSq(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), Vec2.zero.lengthSq(), 1e-6);
}

test "Vec2 length" {
    const v = Vec2{ .x = 3, .y = 4 };
    try std.testing.expectApproxEqAbs(@as(f32, 5), v.length(), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), Vec2.zero.length(), 1e-6);
}

test "Vec2 normalize" {
    const v = Vec2{ .x = 3, .y = 4 };
    const n = v.normalize();
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), n.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), n.y, 1e-6);
    // Normalized vector has unit length.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), n.length(), 1e-6);
}

test "Vec2 normalize degenerate returns default direction" {
    const n = Vec2.zero.normalize();
    try std.testing.expectApproxEqAbs(@as(f32, 1), n.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), n.y, 1e-6);
}

test "Vec2 negate" {
    const v = Vec2{ .x = 3, .y = -4 };
    const neg = v.negate();
    try std.testing.expectApproxEqAbs(@as(f32, -3), neg.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4), neg.y, 1e-6);
}

test "Vec2 perp is perpendicular and CCW" {
    const v = Vec2{ .x = 1, .y = 0 };
    const p = v.perp();
    // 90° CCW rotation of (1,0) is (0,1).
    try std.testing.expectApproxEqAbs(@as(f32, 0), p.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), p.y, 1e-6);
    // Perpendicular vectors have zero dot product.
    try std.testing.expectApproxEqAbs(@as(f32, 0), v.dot(p), 1e-6);
}

test "IndexSlice len" {
    const slice = IndexSlice{ .start = 3, .end = 7 };
    try std.testing.expectEqual(@as(u32, 4), slice.len());

    const empty = IndexSlice{ .start = 5, .end = 5 };
    try std.testing.expectEqual(@as(u32, 0), empty.len());
}
