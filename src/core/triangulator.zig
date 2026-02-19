//! Polygon triangulation using ear-clipping algorithm
//!
//! Converts flattened path polygons to triangle indices for GPU rendering.
//! Uses O(n²) ear-clipping - sufficient for UI paths (typically <1000 vertices).
//!
//! Handles both CCW and CW winding via signed area detection.

const std = @import("std");
const builtin = @import("builtin");
const limits = @import("limits.zig");
const vec2_mod = @import("vec2.zig");
const fixed_array_mod = @import("fixed_array.zig");

// =============================================================================
// Re-exports — canonical definitions live in dedicated modules
// =============================================================================

pub const FixedArray = fixed_array_mod.FixedArray;
pub const Vec2 = vec2_mod.Vec2;
pub const IndexSlice = vec2_mod.IndexSlice;

// =============================================================================
// Constants — re-exported from limits.zig (single source of truth)
// =============================================================================

pub const MAX_PATH_VERTICES = limits.MAX_PATH_VERTICES;
pub const MAX_PATH_TRIANGLES = limits.MAX_PATH_TRIANGLES;
pub const MAX_PATH_INDICES = limits.MAX_PATH_INDICES;

/// Bitset for tracking vertex membership — O(1) lookup, 64 bytes for 512 vertices.
/// Used for both reflex-vertex tracking and active-vertex tracking.
pub const ReflexSet = std.bit_set.IntegerBitSet(limits.MAX_PATH_VERTICES);

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

    /// Core ear-clipping algorithm.
    ///
    /// Uses an intrusive circular doubly-linked list for O(1) vertex removal
    /// instead of shifting a dense array (O(n) per removal). After clipping
    /// an ear the scan resumes from the previous neighbor — the vertex most
    /// likely to be the next ear — rather than restarting from vertex 0.
    ///
    /// Total memory-write savings: O(n) vs O(n²) for the removal step alone,
    /// which dominates for polygons approaching MAX_PATH_VERTICES (512).
    fn earClipPolygon(
        self: *Self,
        points: []const Vec2,
        polygon: IndexSlice,
    ) TriangulationError!void {
        const poly_points = points[polygon.start..polygon.end];
        const n: u32 = @intCast(poly_points.len);

        // Internal assertions (already validated at API boundary).
        std.debug.assert(n >= 3);
        std.debug.assert(n <= MAX_PATH_VERTICES);

        // Intrusive circular doubly-linked list — O(1) removal vs O(n) array shift.
        // Each entry stores the *vertex index* of the next/prev active vertex in the
        // polygon ring.  Two u32 arrays × 512 entries = 4 KB on the stack.
        var next_v: [MAX_PATH_VERTICES]u32 = undefined;
        var prev_v: [MAX_PATH_VERTICES]u32 = undefined;

        // Active vertex bitset for O(1) membership checks in hasPointInsideReflex.
        var active_set = ReflexSet.initEmpty();

        for (0..n) |i| {
            next_v[i] = if (i == n - 1) 0 else @as(u32, @intCast(i)) + 1;
            prev_v[i] = if (i == 0) n - 1 else @as(u32, @intCast(i)) - 1;
            active_set.set(i);
        }

        // Pre-compute reflex vertices (O(n)) — only these can block an ear.
        self.reflex_vertices = ReflexSet.initEmpty();
        for (0..n) |i| {
            const p0 = poly_points[prev_v[i]];
            const p1 = poly_points[i];
            const p2 = poly_points[next_v[i]];

            if (!isConvex(p0, p1, p2, self.is_ccw)) {
                self.reflex_vertices.set(i);
            }
        }

        var remaining: u32 = n;
        var safety_counter: u32 = 0;
        const max_iterations: u32 = n * n; // O(n²) worst case.

        // Start scanning from vertex 0.
        var scan_start: u32 = 0;

        while (remaining > 3) {
            var found_ear = false;
            var curr = scan_start;
            var scanned: u32 = 0;

            while (scanned < remaining) : (scanned += 1) {
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

                const pv = prev_v[curr];
                const nv = next_v[curr];

                const p0 = poly_points[pv];
                const p1 = poly_points[curr];
                const p2 = poly_points[nv];

                // Convex vertex with no reflex point inside → ear.
                if (isConvex(p0, p1, p2, self.is_ccw) and
                    !hasPointInsideReflex(poly_points, &self.reflex_vertices, &active_set, pv, curr, nv, p0, p1, p2))
                {
                    // Emit triangle.
                    self.indices.appendAssumeCapacity(polygon.start + pv);
                    self.indices.appendAssumeCapacity(polygon.start + curr);
                    self.indices.appendAssumeCapacity(polygon.start + nv);

                    // Unlink curr from the ring — O(1) pointer update.
                    next_v[pv] = nv;
                    prev_v[nv] = pv;
                    self.reflex_vertices.unset(curr);
                    active_set.unset(curr);
                    remaining -= 1;

                    // Neighbors may have become convex after removal.
                    if (remaining >= 3) {
                        self.updateReflexLinked(pv, &next_v, &prev_v, poly_points);
                        self.updateReflexLinked(nv, &next_v, &prev_v, poly_points);
                    }

                    // Resume from the previous neighbor — most likely next ear.
                    scan_start = pv;
                    found_ear = true;
                    break;
                }

                curr = next_v[curr];
            }

            if (!found_ear) {
                if (builtin.mode == .Debug) {
                    std.log.warn("No ear found with {} vertices remaining", .{remaining});
                }
                return error.EarClippingFailed;
            }
        }

        // Emit final triangle from the three remaining vertices.
        if (remaining == 3) {
            const v0 = scan_start;
            const v1 = next_v[v0];
            const v2 = next_v[v1];
            std.debug.assert(next_v[v2] == v0); // Ring integrity.
            self.indices.appendAssumeCapacity(polygon.start + v0);
            self.indices.appendAssumeCapacity(polygon.start + v1);
            self.indices.appendAssumeCapacity(polygon.start + v2);
        }
    }

    /// Update reflex status for a vertex using linked-list neighbors.
    fn updateReflexLinked(
        self: *Self,
        vertex: u32,
        next_vertex: *const [MAX_PATH_VERTICES]u32,
        prev_vertex: *const [MAX_PATH_VERTICES]u32,
        poly_points: []const Vec2,
    ) void {
        const p0 = poly_points[prev_vertex[vertex]];
        const p1 = poly_points[vertex];
        const p2 = poly_points[next_vertex[vertex]];

        if (isConvex(p0, p1, p2, self.is_ccw)) {
            self.reflex_vertices.unset(vertex);
        } else {
            self.reflex_vertices.set(vertex);
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
    reflex_set: *const ReflexSet,
    active_set: *const ReflexSet,
    idx_prev: u32,
    idx_curr: u32,
    idx_next: u32,
    p0: Vec2,
    p1: Vec2,
    p2: Vec2,
) bool {
    std.debug.assert(active_set.count() > 0);

    // Only iterate over reflex vertices — O(r) where r = reflex count.
    var iter = reflex_set.iterator(.{});
    while (iter.next()) |reflex_idx| {
        // Skip triangle vertices
        if (reflex_idx == idx_prev or reflex_idx == idx_curr or reflex_idx == idx_next) continue;

        // O(1) check: is this reflex vertex still in the active polygon?
        if (!active_set.isSet(reflex_idx)) continue;

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
