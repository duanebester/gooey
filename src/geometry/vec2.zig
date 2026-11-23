const std = @import("std");

pub const Vec2 = struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

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

    pub fn length(self: Vec2) f32 {
        return @sqrt(self.lengthSq());
    }

    pub fn normalize(self: Vec2) Vec2 {
        const len_sq = self.lengthSq();
        if (len_sq < 1e-12) {
            return Vec2{ .x = 1, .y = 0 };
        }
        const inv_len = 1.0 / @sqrt(len_sq);
        return self.scale(inv_len);
    }

    pub fn negate(self: Vec2) Vec2 {
        return .{ .x = -self.x, .y = -self.y };
    }

    pub fn perp(self: Vec2) Vec2 {
        return .{ .x = -self.y, .y = self.x };
    }

    pub const zero = Vec2{ .x = 0, .y = 0 };
};

pub const IndexSlice = struct {
    start: u32,
    end: u32,
    closed: bool = false,

    pub fn len(self: IndexSlice) u32 {
        std.debug.assert(self.end >= self.start);
        return self.end - self.start;
    }
};

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
    try std.testing.expectApproxEqAbs(@as(f32, 0), p.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), p.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), v.dot(p), 1e-6);
}

test "IndexSlice len" {
    const slice = IndexSlice{ .start = 3, .end = 7 };
    try std.testing.expectEqual(@as(u32, 4), slice.len());

    const empty = IndexSlice{ .start = 5, .end = 5 };
    try std.testing.expectEqual(@as(u32, 0), empty.len());
}
