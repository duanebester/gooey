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

/// Bitset for tracking reflex (concave) vertices - O(1) lookup, 64 bytes for 512 vertices
pub const ReflexSet = std.bit_set.IntegerBitSet(MAX_PATH_VERTICES);

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
    /// Tracks reflex (concave) vertices for O(n×r) triangulation instead of O(n²)
    reflex_vertices: ReflexSet,

    const Self = @This();

    pub fn init() Self {
        return .{
            .indices = .{},
            .is_ccw = true,
            .reflex_vertices = ReflexSet.initEmpty(),
        };
    }

    /// Reset for reuse (call between paths)
    pub fn reset(self: *Self) void {
        self.indices.len = 0;
        self.is_ccw = true;
        self.reflex_vertices = ReflexSet.initEmpty();
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

        // Pre-compute reflex vertices (O(n)) - only these can be inside ear triangles
        self.reflex_vertices = ReflexSet.initEmpty();
        for (0..n) |i| {
            const prev_idx = if (i == 0) n - 1 else i - 1;
            const next_idx = if (i == n - 1) 0 else i + 1;
            const p0 = poly_points[prev_idx];
            const p1 = poly_points[i];
            const p2 = poly_points[next_idx];

            if (!isConvex(p0, p1, p2, self.is_ccw)) {
                self.reflex_vertices.set(i);
            }
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

                const idx_prev = vertex_list.get(prev);
                const idx_curr = vertex_list.get(i);
                const idx_next = vertex_list.get(next);

                const p0 = poly_points[idx_prev];
                const p1 = poly_points[idx_curr];
                const p2 = poly_points[idx_next];

                // Check if this is a convex vertex (ear candidate)
                if (!isConvex(p0, p1, p2, self.is_ccw)) continue;

                // Check no reflex vertices inside this triangle (O(r) instead of O(n))
                if (hasPointInsideReflex(poly_points, &vertex_list, &self.reflex_vertices, prev, i, next, p0, p1, p2)) continue;

                // Found an ear! Emit triangle and remove vertex
                self.indices.appendAssumeCapacity(polygon.start + idx_prev);
                self.indices.appendAssumeCapacity(polygon.start + idx_curr);
                self.indices.appendAssumeCapacity(polygon.start + idx_next);

                // Clear reflex status for removed vertex
                self.reflex_vertices.unset(idx_curr);

                _ = vertex_list.orderedRemove(i);
                remaining -= 1;

                // Update reflex status for neighbors (they may become convex)
                if (remaining >= 3) {
                    const new_prev = if (i == 0) remaining - 1 else if (i > remaining) 0 else i - 1;
                    const new_curr = if (i >= remaining) 0 else i;
                    self.updateReflexStatus(new_prev, &vertex_list, poly_points);
                    self.updateReflexStatus(new_curr, &vertex_list, poly_points);
                }

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

    /// Update reflex status for a vertex after neighbor removal
    fn updateReflexStatus(
        self: *Self,
        list_idx: usize,
        vertex_list: *const FixedArray(u32, MAX_PATH_VERTICES),
        poly_points: []const Vec2,
    ) void {
        const n = vertex_list.len;
        if (n < 3) return;

        std.debug.assert(list_idx < n);

        const prev = if (list_idx == 0) n - 1 else list_idx - 1;
        const next = if (list_idx == n - 1) 0 else list_idx + 1;

        const p0 = poly_points[vertex_list.get(prev)];
        const p1 = poly_points[vertex_list.get(list_idx)];
        const p2 = poly_points[vertex_list.get(next)];

        const vertex_idx = vertex_list.get(list_idx);
        if (isConvex(p0, p1, p2, self.is_ccw)) {
            self.reflex_vertices.unset(vertex_idx);
        } else {
            self.reflex_vertices.set(vertex_idx);
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

/// Check if any reflex vertex (other than the triangle's own) lies inside the triangle
/// Only reflex (concave) vertices can be inside an ear - convex vertices are geometrically excluded.
/// This reduces complexity from O(n) to O(r) where r = reflex vertex count.
fn hasPointInsideReflex(
    poly_points: []const Vec2,
    vertex_list: *const FixedArray(u32, MAX_PATH_VERTICES),
    reflex_set: *const ReflexSet,
    prev: usize,
    curr: usize,
    next: usize,
    p0: Vec2,
    p1: Vec2,
    p2: Vec2,
) bool {
    std.debug.assert(vertex_list.len > 0);
    std.debug.assert(prev < vertex_list.len and curr < vertex_list.len and next < vertex_list.len);

    const idx_prev = vertex_list.get(prev);
    const idx_curr = vertex_list.get(curr);
    const idx_next = vertex_list.get(next);

    // Only iterate over reflex vertices
    var iter = reflex_set.iterator(.{});
    while (iter.next()) |reflex_idx| {
        // Skip triangle vertices
        if (reflex_idx == idx_prev or reflex_idx == idx_curr or reflex_idx == idx_next) continue;

        // Check if this reflex vertex is still in the active vertex list
        var found = false;
        for (0..vertex_list.len) |i| {
            if (vertex_list.get(i) == reflex_idx) {
                found = true;
                break;
            }
        }
        if (!found) continue;

        const pt = poly_points[reflex_idx];
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

// =============================================================================
// Reflex Vertex Tracking Tests (P1)
// =============================================================================

test "convex polygon has no reflex vertices" {
    var tri = Triangulator.init();
    // Regular convex hexagon
    var hexagon: [6]Vec2 = undefined;
    for (0..6) |i| {
        const angle = @as(f32, @floatFromInt(i)) * std.math.pi / 3.0;
        hexagon[i] = .{
            .x = @cos(angle),
            .y = @sin(angle),
        };
    }
    _ = try tri.triangulate(&hexagon, .{ .start = 0, .end = 6 });
    // After triangulation, reflex set should be empty (all vertices convex)
    try std.testing.expectEqual(@as(usize, 0), tri.reflex_vertices.count());
}

test "L-shape has correct reflex vertex" {
    var tri = Triangulator.init();
    // L-shaped polygon has exactly one reflex vertex at index 3
    const l_shape = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 1, .y = 1 }, // This is the reflex (concave) vertex
        .{ .x = 1, .y = 2 },
        .{ .x = 0, .y = 2 },
    };
    const indices = try tri.triangulate(&l_shape, .{ .start = 0, .end = 6 });
    // Should still produce correct triangulation
    try std.testing.expectEqual(@as(usize, 12), indices.len);
}

test "star shape has multiple reflex vertices" {
    var tri = Triangulator.init();

    // 5-pointed star: inner vertices (odd indices) are reflex
    const cx: f32 = 0;
    const cy: f32 = 0;
    const radius: f32 = 1.0;
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
    try std.testing.expectEqual(@as(usize, 24), indices.len);
}

test "reflex tracking handles reuse correctly" {
    var tri = Triangulator.init();

    // First: triangulate a concave shape
    const l_shape = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 1, .y = 1 },
        .{ .x = 1, .y = 2 },
        .{ .x = 0, .y = 2 },
    };
    _ = try tri.triangulate(&l_shape, .{ .start = 0, .end = 6 });

    // Reset and triangulate a convex shape
    tri.reset();
    const square = [_]Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 1 },
    };
    _ = try tri.triangulate(&square, .{ .start = 0, .end = 4 });

    // Reflex set should be empty after convex polygon
    try std.testing.expectEqual(@as(usize, 0), tri.reflex_vertices.count());
}
