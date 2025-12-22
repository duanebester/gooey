//! Simple Ear-Clipping Tessellator
//!
//! Converts simple polygons (no self-intersections) into triangles.
//! Uses the ear-clipping algorithm for O(n²) complexity but simple implementation.
//!
//! For an MVP, this handles most icon SVGs well. A more robust tessellator
//! (Bentley-Ottmann) can be added later for complex self-intersecting paths.

const std = @import("std");
const svg = @import("svg.zig");
const Vec2 = svg.Vec2;
const IndexSlice = svg.IndexSlice;

/// Output of tessellation - vertices and triangle indices
pub const TessellationResult = struct {
    vertices: []Vec2,
    indices: []u16,

    pub fn deinit(self: *TessellationResult, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.indices);
    }
};

/// Simple ear-clipping tessellator
pub const Tessellator = struct {
    allocator: std.mem.Allocator,
    out_verts: std.ArrayListUnmanaged(Vec2) = .{},
    out_indices: std.ArrayListUnmanaged(u16) = .{},
    active: std.ArrayListUnmanaged(u16) = .{},

    pub fn init(allocator: std.mem.Allocator) Tessellator {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tessellator) void {
        self.out_verts.deinit(self.allocator);
        self.out_indices.deinit(self.allocator);
        self.active.deinit(self.allocator);
    }

    pub fn clear(self: *Tessellator) void {
        self.out_verts.clearRetainingCapacity();
        self.out_indices.clearRetainingCapacity();
        self.active.clearRetainingCapacity();
    }

    /// Tessellate multiple polygons into triangles
    pub fn tessellate(
        self: *Tessellator,
        points: []const Vec2,
        polygons: []const IndexSlice,
    ) !TessellationResult {
        self.clear();

        // Copy all vertices
        try self.out_verts.appendSlice(self.allocator, points);

        // Tessellate each polygon
        for (polygons) |poly| {
            try self.tessellatePolygon(points, poly);
        }

        // Return owned slices
        const verts = try self.allocator.dupe(Vec2, self.out_verts.items);
        const indices = try self.allocator.dupe(u16, self.out_indices.items);

        return .{
            .vertices = verts,
            .indices = indices,
        };
    }

    fn tessellatePolygon(self: *Tessellator, points: []const Vec2, poly: IndexSlice) !void {
        const n = poly.end - poly.start;
        if (n < 3) return;

        // Build active vertex list
        self.active.clearRetainingCapacity();
        try self.active.ensureTotalCapacity(self.allocator, n);

        // Determine winding order
        const signed_area = computeSignedArea(points[poly.start..poly.end]);
        const ccw = signed_area > 0;

        // Add vertices in correct order for CCW output
        if (ccw) {
            for (poly.start..poly.end) |i| {
                self.active.appendAssumeCapacity(@intCast(i));
            }
        } else {
            var i = poly.end;
            while (i > poly.start) {
                i -= 1;
                self.active.appendAssumeCapacity(@intCast(i));
            }
        }

        // Ear clipping
        var iterations: u32 = 0;
        const max_iterations = n * n; // Safety limit

        while (self.active.items.len > 2 and iterations < max_iterations) {
            iterations += 1;
            var found_ear = false;

            for (0..self.active.items.len) |i| {
                const prev_idx = if (i == 0) self.active.items.len - 1 else i - 1;
                const next_idx = if (i == self.active.items.len - 1) 0 else i + 1;

                const a = self.active.items[prev_idx];
                const b = self.active.items[i];
                const c = self.active.items[next_idx];

                if (self.isEar(points, a, b, c)) {
                    // Add triangle (CCW winding)
                    try self.out_indices.append(self.allocator, a);
                    try self.out_indices.append(self.allocator, b);
                    try self.out_indices.append(self.allocator, c);

                    // Remove the ear vertex
                    _ = self.active.orderedRemove(i);
                    found_ear = true;
                    break;
                }
            }

            if (!found_ear) {
                // Degenerate polygon, break to avoid infinite loop
                break;
            }
        }
    }

    fn isEar(self: *Tessellator, points: []const Vec2, a: u16, b: u16, c: u16) bool {
        const pa = points[a];
        const pb = points[b];
        const pc = points[c];

        // Check if triangle is convex (CCW)
        if (!isConvex(pa, pb, pc)) return false;

        // Check if any other vertex is inside this triangle
        for (self.active.items) |idx| {
            if (idx == a or idx == b or idx == c) continue;
            if (pointInTriangle(points[idx], pa, pb, pc)) {
                return false;
            }
        }

        return true;
    }
};

/// Check if angle at B is convex (CCW winding)
fn isConvex(a: Vec2, b: Vec2, c: Vec2) bool {
    const ab = b.sub(a);
    const bc = c.sub(b);
    return ab.cross(bc) > 0;
}

/// Check if point P is inside triangle ABC
fn pointInTriangle(p: Vec2, a: Vec2, b: Vec2, c: Vec2) bool {
    const v0 = c.sub(a);
    const v1 = b.sub(a);
    const v2 = p.sub(a);

    const dot00 = v0.x * v0.x + v0.y * v0.y;
    const dot01 = v0.x * v1.x + v0.y * v1.y;
    const dot02 = v0.x * v2.x + v0.y * v2.y;
    const dot11 = v1.x * v1.x + v1.y * v1.y;
    const dot12 = v1.x * v2.x + v1.y * v2.y;

    const inv_denom = 1.0 / (dot00 * dot11 - dot01 * dot01);
    const u = (dot11 * dot02 - dot01 * dot12) * inv_denom;
    const v = (dot00 * dot12 - dot01 * dot02) * inv_denom;

    return (u >= 0) and (v >= 0) and (u + v < 1);
}

/// Compute signed area of polygon (positive = CCW)
fn computeSignedArea(points: []const Vec2) f32 {
    if (points.len < 3) return 0;

    var area: f32 = 0;
    for (0..points.len) |i| {
        const j = (i + 1) % points.len;
        area += points[i].x * points[j].y;
        area -= points[j].x * points[i].y;
    }
    return area * 0.5;
}

// ============================================================================
// Tests
// ============================================================================

test "tessellate triangle" {
    const allocator = std.testing.allocator;
    var tess = Tessellator.init(allocator);
    defer tess.deinit();

    const points = [_]Vec2{
        Vec2.init(0, 0),
        Vec2.init(100, 0),
        Vec2.init(50, 100),
    };
    const polygons = [_]IndexSlice{
        .{ .start = 0, .end = 3 },
    };

    var result = try tess.tessellate(&points, &polygons);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.vertices.len);
    try std.testing.expectEqual(@as(usize, 3), result.indices.len);
}

test "tessellate square" {
    const allocator = std.testing.allocator;
    var tess = Tessellator.init(allocator);
    defer tess.deinit();

    const points = [_]Vec2{
        Vec2.init(0, 0),
        Vec2.init(100, 0),
        Vec2.init(100, 100),
        Vec2.init(0, 100),
    };
    const polygons = [_]IndexSlice{
        .{ .start = 0, .end = 4 },
    };

    var result = try tess.tessellate(&points, &polygons);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), result.vertices.len);
    try std.testing.expectEqual(@as(usize, 6), result.indices.len); // 2 triangles
}

test "tessellate pentagon" {
    const allocator = std.testing.allocator;
    var tess = Tessellator.init(allocator);
    defer tess.deinit();

    const points = [_]Vec2{
        Vec2.init(50, 0),
        Vec2.init(100, 35),
        Vec2.init(80, 100),
        Vec2.init(20, 100),
        Vec2.init(0, 35),
    };
    const polygons = [_]IndexSlice{
        .{ .start = 0, .end = 5 },
    };

    var result = try tess.tessellate(&points, &polygons);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), result.vertices.len);
    try std.testing.expectEqual(@as(usize, 9), result.indices.len); // 3 triangles
}
