//! Polygon triangulation using ear-clipping algorithm
//!
//! Converts flattened path polygons to triangle indices for GPU rendering.
//! Uses O(n²) ear-clipping - sufficient for UI paths (typically <1000 vertices).
//!
//! Handles both CCW and CW winding via signed area detection.

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Fixed Capacity Array (since std.BoundedArray doesn't exist in Zig 0.15)
// =============================================================================

/// A fixed-capacity array that doesn't allocate after initialization.
/// Used to avoid dynamic allocation during frame rendering per CLAUDE.md.
pub fn FixedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            std.debug.assert(self.len < capacity);
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn get(self: *const Self, index: usize) T {
            std.debug.assert(index < self.len);
            return self.buffer[index];
        }

        pub fn slice(self: *Self) []T {
            return self.buffer[0..self.len];
        }

        pub fn constSlice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn orderedRemove(self: *Self, index: usize) T {
            std.debug.assert(index < self.len);
            const item = self.buffer[index];
            // Shift elements left
            const len = self.len;
            for (index..len - 1) |i| {
                self.buffer[i] = self.buffer[i + 1];
            }
            self.len -= 1;
            return item;
        }
    };
}

// =============================================================================
// Types
// =============================================================================

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
};

pub const IndexSlice = struct {
    start: u32,
    end: u32,

    pub fn len(self: IndexSlice) u32 {
        std.debug.assert(self.end >= self.start);
        return self.end - self.start;
    }
};

// =============================================================================
// Constants (static allocation per CLAUDE.md)
// =============================================================================

/// Maximum vertices per path (reduced from 4096 to avoid stack overflow - PathMesh ~14KB at 512)
pub const MAX_PATH_VERTICES: u32 = 512;
/// Maximum triangles = MAX_PATH_VERTICES - 2 (for simple polygon)
pub const MAX_PATH_TRIANGLES: u32 = MAX_PATH_VERTICES - 2;
/// Maximum indices = triangles * 3
pub const MAX_PATH_INDICES: u32 = MAX_PATH_TRIANGLES * 3;

// =============================================================================
// Errors
// =============================================================================

pub const TriangulationError = error{
    TooManyVertices,
    DegeneratePolygon,
    EarClippingFailed,
};

// =============================================================================
// Triangulator
// =============================================================================

pub const Triangulator = struct {
    /// Output indices buffer (static allocation)
    indices: FixedArray(u32, MAX_PATH_INDICES),
    /// Detected winding direction (true = CCW)
    is_ccw: bool,

    const Self = @This();

    pub fn init() Self {
        return .{
            .indices = .{},
            .is_ccw = true,
        };
    }

    /// Reset for reuse (call between paths)
    pub fn reset(self: *Self) void {
        self.indices.len = 0;
        self.is_ccw = true;
    }

    /// Triangulate a single polygon (points[polygon.start..polygon.end])
    /// Returns slice into internal indices buffer
    pub fn triangulate(
        self: *Self,
        points: []const Vec2,
        polygon: IndexSlice,
    ) TriangulationError![]const u32 {
        const n = polygon.len();

        // Bounds checking at API boundary
        std.debug.assert(polygon.end <= points.len);
        if (n > MAX_PATH_VERTICES) return error.TooManyVertices;
        if (n < 3) return error.DegeneratePolygon;

        // Detect winding direction via signed area
        const poly_points = points[polygon.start..polygon.end];
        const area = signedArea(poly_points);
        self.is_ccw = area > 0;

        // Degenerate polygon check (zero area)
        if (@abs(area) < 1e-10) return error.DegeneratePolygon;

        const start_idx = self.indices.len;
        try self.earClipPolygon(points, polygon);
        return self.indices.slice()[start_idx..];
    }

    /// Core ear-clipping algorithm
    fn earClipPolygon(
        self: *Self,
        points: []const Vec2,
        polygon: IndexSlice,
    ) TriangulationError!void {
        const poly_points = points[polygon.start..polygon.end];
        const n = poly_points.len;

        // Internal assertions (already validated at API boundary)
        std.debug.assert(n >= 3);
        std.debug.assert(n <= MAX_PATH_VERTICES);

        // Build vertex index list (we'll remove ears as we go)
        var vertex_list: FixedArray(u32, MAX_PATH_VERTICES) = .{};
        for (0..n) |i| {
            vertex_list.appendAssumeCapacity(@intCast(i));
        }

        var remaining = n;
        var safety_counter: u32 = 0;
        const max_iterations: u32 = @intCast(n * n); // O(n²) worst case

        while (remaining > 3) {
            safety_counter += 1;
            if (safety_counter > max_iterations) {
                if (builtin.mode == .Debug) {
                    std.log.warn(
                        "Ear clipping failed: {} vertices remaining after {} iterations. " ++
                            "Polygon may be self-intersecting or have collinear points.",
                        .{ remaining, safety_counter },
                    );
                }
                return error.EarClippingFailed;
            }

            var found_ear = false;

            for (0..remaining) |i| {
                const prev = if (i == 0) remaining - 1 else i - 1;
                const next = if (i == remaining - 1) 0 else i + 1;

                const p0 = poly_points[vertex_list.get(prev)];
                const p1 = poly_points[vertex_list.get(i)];
                const p2 = poly_points[vertex_list.get(next)];

                // Check if this is a convex vertex (ear candidate)
                if (!isConvex(p0, p1, p2, self.is_ccw)) continue;

                // Check no other vertices inside this triangle
                if (hasPointInside(poly_points, &vertex_list, prev, i, next, p0, p1, p2)) continue;

                // Found an ear! Emit triangle and remove vertex
                self.indices.appendAssumeCapacity(polygon.start + vertex_list.get(prev));
                self.indices.appendAssumeCapacity(polygon.start + vertex_list.get(i));
                self.indices.appendAssumeCapacity(polygon.start + vertex_list.get(next));

                _ = vertex_list.orderedRemove(i);
                remaining -= 1;
                found_ear = true;
                break;
            }

            if (!found_ear) {
                if (builtin.mode == .Debug) {
                    std.log.warn("No ear found with {} vertices remaining", .{remaining});
                }
                return error.EarClippingFailed;
            }
        }

        // Emit final triangle
        if (remaining == 3) {
            self.indices.appendAssumeCapacity(polygon.start + vertex_list.get(0));
            self.indices.appendAssumeCapacity(polygon.start + vertex_list.get(1));
            self.indices.appendAssumeCapacity(polygon.start + vertex_list.get(2));
        }
    }
};

// =============================================================================
// Geometry Helpers
// =============================================================================

/// Calculate signed area of polygon (positive = CCW, negative = CW)
/// Uses the shoelace formula: area = 0.5 * Σ (x_i * y_{i+1} - x_{i+1} * y_i)
pub fn signedArea(points: []const Vec2) f32 {
    std.debug.assert(points.len >= 3);

    var area: f32 = 0;
    for (0..points.len) |i| {
        const j = (i + 1) % points.len;
        // Shoelace formula: cross product of consecutive vertices
        area += points[i].x * points[j].y - points[j].x * points[i].y;
    }
    return area / 2;
}

/// Winding-aware convexity test
fn isConvex(p0: Vec2, p1: Vec2, p2: Vec2, is_ccw: bool) bool {
    std.debug.assert(!std.math.isNan(p0.x) and !std.math.isNan(p0.y));
    std.debug.assert(!std.math.isNan(p1.x) and !std.math.isNan(p1.y));

    const v1 = p1.sub(p0);
    const v2 = p2.sub(p1);
    const cross_product = v1.cross(v2);
    return if (is_ccw) cross_product > 0 else cross_product < 0;
}

/// Check if any vertex (other than the triangle's own) lies inside the triangle
fn hasPointInside(
    poly_points: []const Vec2,
    vertex_list: *const FixedArray(u32, MAX_PATH_VERTICES),
    prev: usize,
    curr: usize,
    next: usize,
    p0: Vec2,
    p1: Vec2,
    p2: Vec2,
) bool {
    std.debug.assert(vertex_list.len > 0);
    std.debug.assert(prev < vertex_list.len and curr < vertex_list.len and next < vertex_list.len);

    for (0..vertex_list.len) |i| {
        if (i == prev or i == curr or i == next) continue;

        const pt = poly_points[vertex_list.get(i)];
        if (pointInTriangle(pt, p0, p1, p2)) return true;
    }
    return false;
}

/// Test if point p is inside triangle (a, b, c)
fn pointInTriangle(p: Vec2, a: Vec2, b: Vec2, c: Vec2) bool {
    std.debug.assert(!std.math.isNan(p.x) and !std.math.isNan(p.y));

    const d1 = sign(p, a, b);
    const d2 = sign(p, b, c);
    const d3 = sign(p, c, a);

    const has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0);
    const has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0);

    return !(has_neg and has_pos);
}

/// Sign of area of triangle formed by three points
fn sign(p1: Vec2, p2: Vec2, p3: Vec2) f32 {
    return (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y);
}

// =============================================================================
// Tests
// =============================================================================

test "triangulate square produces 2 triangles" {
    var tri = Triangulator.init();
    const square = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 1 },
    };
    const indices = try tri.triangulate(&square, .{ .start = 0, .end = 4 });
    try std.testing.expectEqual(@as(usize, 6), indices.len);
}

test "triangulate triangle produces 1 triangle" {
    var tri = Triangulator.init();
    const triangle = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 0.5, .y = 1 },
    };
    const indices = try tri.triangulate(&triangle, .{ .start = 0, .end = 3 });
    try std.testing.expectEqual(@as(usize, 3), indices.len);
}

test "triangulate convex pentagon produces 3 triangles" {
    var tri = Triangulator.init();
    const pentagon = [_]Vec2{
        .{ .x = 0.5, .y = 0 },
        .{ .x = 1, .y = 0.4 },
        .{ .x = 0.8, .y = 1 },
        .{ .x = 0.2, .y = 1 },
        .{ .x = 0, .y = 0.4 },
    };
    const indices = try tri.triangulate(&pentagon, .{ .start = 0, .end = 5 });
    // Pentagon = 5 - 2 = 3 triangles = 9 indices
    try std.testing.expectEqual(@as(usize, 9), indices.len);
}

test "triangulate CW winding works" {
    var tri = Triangulator.init();
    // CW square (reversed winding)
    const square_cw = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 1 },
        .{ .x = 1, .y = 1 },
        .{ .x = 1, .y = 0 },
    };
    const indices = try tri.triangulate(&square_cw, .{ .start = 0, .end = 4 });
    try std.testing.expectEqual(@as(usize, 6), indices.len);
}

test "triangulate degenerate polygon returns error" {
    var tri = Triangulator.init();
    const line = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
    };
    const result = tri.triangulate(&line, .{ .start = 0, .end = 2 });
    try std.testing.expectError(error.DegeneratePolygon, result);
}

test "signedArea CCW positive" {
    const ccw_square = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 1 },
    };
    const area = signedArea(&ccw_square);
    try std.testing.expect(area > 0);
}

test "signedArea CW negative" {
    const cw_square = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 1 },
        .{ .x = 1, .y = 1 },
        .{ .x = 1, .y = 0 },
    };
    const area = signedArea(&cw_square);
    try std.testing.expect(area < 0);
}

test "reset clears state" {
    var tri = Triangulator.init();
    const square = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 1 },
    };
    _ = try tri.triangulate(&square, .{ .start = 0, .end = 4 });
    try std.testing.expect(tri.indices.len > 0);

    tri.reset();
    try std.testing.expectEqual(@as(usize, 0), tri.indices.len);
}

test "triangulate L-shape (concave)" {
    var tri = Triangulator.init();
    // L-shaped polygon (concave)
    const l_shape = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 1, .y = 1 },
        .{ .x = 1, .y = 2 },
        .{ .x = 0, .y = 2 },
    };
    const indices = try tri.triangulate(&l_shape, .{ .start = 0, .end = 6 });
    // 6-gon = 4 triangles = 12 indices
    try std.testing.expectEqual(@as(usize, 12), indices.len);
}

test "triangulate 5-pointed star (concave)" {
    var tri = Triangulator.init();

    // 5-pointed star: 10 vertices alternating outer/inner
    const cx: f32 = 100;
    const cy: f32 = 150;
    const radius: f32 = 60;
    const inner_radius = radius * 0.4;

    var points: [10]Vec2 = undefined;
    for (0..10) |i| {
        const angle = std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * std.math.pi / 5.0;
        const r = if (i % 2 == 0) radius else inner_radius;
        points[i] = .{
            .x = cx + r * @cos(angle),
            .y = cy - r * @sin(angle),
        };
    }

    const indices = try tri.triangulate(&points, .{ .start = 0, .end = 10 });
    // 10-gon = 8 triangles = 24 indices
    try std.testing.expectEqual(@as(usize, 24), indices.len);
}
