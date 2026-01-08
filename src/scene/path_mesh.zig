//! PathMesh - Triangulated path ready for GPU rendering
//!
//! Contains vertex positions and triangle indices suitable for
//! direct upload to vertex/index buffers. UV coordinates are
//! normalized to bounds for gradient support.

const std = @import("std");
const scene = @import("scene.zig");
const triangulator = @import("../core/triangulator.zig");
const stroke = @import("../core/stroke.zig");
const FixedArray = triangulator.FixedArray;

// =============================================================================
// Constants (static allocation per CLAUDE.md)
// =============================================================================

/// Maximum vertices per mesh
pub const MAX_MESH_VERTICES: u32 = triangulator.MAX_PATH_VERTICES;
/// Maximum indices per mesh
pub const MAX_MESH_INDICES: u32 = triangulator.MAX_PATH_INDICES;

// =============================================================================
// Errors
// =============================================================================

pub const PathMeshError = error{
    TooManyVertices,
    TooManyIndices,
} || triangulator.TriangulationError;

// =============================================================================
// PathVertex - GPU vertex format
// =============================================================================

/// GPU-ready vertex for path rendering
/// Layout: position (x, y) + UV for gradients (u, v)
pub const PathVertex = extern struct {
    /// X position in screen coordinates
    x: f32,
    /// Y position in screen coordinates
    y: f32,
    /// U texture coordinate (normalized to bounds, for gradients)
    u: f32 = 0,
    /// V texture coordinate (normalized to bounds, for gradients)
    v: f32 = 0,

    pub fn init(x: f32, y: f32) PathVertex {
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        return .{ .x = x, .y = y, .u = 0, .v = 0 };
    }

    pub fn withUV(x: f32, y: f32, u: f32, v: f32) PathVertex {
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        std.debug.assert(!std.math.isNan(u) and !std.math.isNan(v));
        return .{ .x = x, .y = y, .u = u, .v = v };
    }
};

comptime {
    // Verify GPU-friendly size (per CLAUDE.md assertion requirement)
    std.debug.assert(@sizeOf(PathVertex) == 16);
    // Verify alignment for GPU buffers
    std.debug.assert(@alignOf(PathVertex) == 4);
}

// =============================================================================
// PathMesh - Collection of vertices and indices
// =============================================================================

pub const PathMesh = struct {
    /// Vertex positions with UV coordinates
    vertices: FixedArray(PathVertex, MAX_MESH_VERTICES),
    /// Triangle indices (every 3 indices = 1 triangle)
    indices: FixedArray(u32, MAX_MESH_INDICES),
    /// Axis-aligned bounding box of all vertices
    bounds: scene.Bounds,

    const Self = @This();

    /// Initialize empty mesh
    pub fn init() Self {
        return .{
            .vertices = .{},
            .indices = .{},
            .bounds = .{},
        };
    }

    /// Build mesh from flattened path points and polygon indices
    ///
    /// `points` - Array of 2D points representing flattened path segments
    /// `polygons` - Array of index slices, each defining a closed polygon
    ///
    /// Returns error if path is too complex or degenerate
    pub fn fromFlattenedPath(
        points: []const triangulator.Vec2,
        polygons: []const triangulator.IndexSlice,
    ) PathMeshError!Self {
        // Assertions at API boundary
        std.debug.assert(points.len > 0);
        std.debug.assert(polygons.len > 0);

        var mesh = Self.init();
        var tri = triangulator.Triangulator.init();

        // Calculate bounds and convert points to vertices
        var min_x: f32 = std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var max_x: f32 = -std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);

        for (points) |p| {
            if (mesh.vertices.len >= MAX_MESH_VERTICES) {
                return error.TooManyVertices;
            }
            mesh.vertices.appendAssumeCapacity(.{ .x = p.x, .y = p.y });
            min_x = @min(min_x, p.x);
            min_y = @min(min_y, p.y);
            max_x = @max(max_x, p.x);
            max_y = @max(max_y, p.y);
        }

        mesh.bounds = scene.Bounds.init(min_x, min_y, max_x - min_x, max_y - min_y);

        // Generate UV coordinates (normalized to bounds)
        const w = if (mesh.bounds.size.width > 0) mesh.bounds.size.width else 1;
        const h = if (mesh.bounds.size.height > 0) mesh.bounds.size.height else 1;
        for (mesh.vertices.slice()) |*vtx| {
            vtx.u = (vtx.x - mesh.bounds.origin.x) / w;
            vtx.v = (vtx.y - mesh.bounds.origin.y) / h;
        }

        // Triangulate each polygon
        for (polygons) |poly| {
            const tri_indices = try tri.triangulate(points, poly);
            for (tri_indices) |idx| {
                if (mesh.indices.len >= MAX_MESH_INDICES) {
                    return error.TooManyIndices;
                }
                mesh.indices.appendAssumeCapacity(idx);
            }
        }

        return mesh;
    }

    /// Build mesh from a simple convex polygon (no holes)
    /// More efficient than fromFlattenedPath for simple shapes
    pub fn fromConvexPolygon(points: []const triangulator.Vec2) PathMeshError!Self {
        std.debug.assert(points.len >= 3);

        if (points.len > MAX_MESH_VERTICES) {
            return error.TooManyVertices;
        }

        const polygon = triangulator.IndexSlice{
            .start = 0,
            .end = @intCast(points.len),
        };

        return fromFlattenedPath(points, &[_]triangulator.IndexSlice{polygon});
    }

    /// Build mesh from pre-triangulated stroke data (bypasses ear-clipper)
    /// Used for closed stroke paths which create concave ring polygons
    pub fn fromStrokeTriangles(triangles: stroke.StrokeTriangles) PathMeshError!Self {
        var mesh = Self.init();

        // Calculate bounds and convert points to vertices
        var min_x: f32 = std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var max_x: f32 = -std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);

        for (triangles.vertices.constSlice()) |p| {
            if (mesh.vertices.len >= MAX_MESH_VERTICES) {
                return error.TooManyVertices;
            }
            mesh.vertices.appendAssumeCapacity(.{ .x = p.x, .y = p.y });
            min_x = @min(min_x, p.x);
            min_y = @min(min_y, p.y);
            max_x = @max(max_x, p.x);
            max_y = @max(max_y, p.y);
        }

        mesh.bounds = scene.Bounds.init(min_x, min_y, max_x - min_x, max_y - min_y);

        // Generate UV coordinates (normalized to bounds)
        const w = if (mesh.bounds.size.width > 0) mesh.bounds.size.width else 1;
        const h = if (mesh.bounds.size.height > 0) mesh.bounds.size.height else 1;
        for (mesh.vertices.slice()) |*vtx| {
            vtx.u = (vtx.x - mesh.bounds.origin.x) / w;
            vtx.v = (vtx.y - mesh.bounds.origin.y) / h;
        }

        // Copy indices directly (already triangulated)
        for (triangles.indices.constSlice()) |idx| {
            if (mesh.indices.len >= MAX_MESH_INDICES) {
                return error.TooManyIndices;
            }
            mesh.indices.appendAssumeCapacity(idx);
        }

        return mesh;
    }

    /// Number of triangles in the mesh
    pub fn triangleCount(self: *const Self) u32 {
        std.debug.assert(self.indices.len % 3 == 0);
        return @intCast(self.indices.len / 3);
    }

    /// Check if mesh is empty
    pub fn isEmpty(self: *const Self) bool {
        return self.vertices.len == 0 or self.indices.len == 0;
    }

    /// Get vertex data as bytes for GPU upload
    pub fn vertexBytes(self: *const Self) []const u8 {
        const vertices = self.vertices.constSlice();
        const ptr: [*]const u8 = @ptrCast(vertices.ptr);
        return ptr[0 .. vertices.len * @sizeOf(PathVertex)];
    }

    /// Get index data as bytes for GPU upload
    pub fn indexBytes(self: *const Self) []const u8 {
        const indices = self.indices.constSlice();
        const ptr: [*]const u8 = @ptrCast(indices.ptr);
        return ptr[0 .. indices.len * @sizeOf(u32)];
    }
};

// =============================================================================
// Tests
// =============================================================================

test "PathVertex size is 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(PathVertex));
}

test "PathMesh from square" {
    const square = [_]triangulator.Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 100, .y = 100 },
        .{ .x = 0, .y = 100 },
    };
    const polygon = triangulator.IndexSlice{ .start = 0, .end = 4 };

    const mesh = try PathMesh.fromFlattenedPath(&square, &[_]triangulator.IndexSlice{polygon});

    try std.testing.expectEqual(@as(usize, 4), mesh.vertices.len);
    try std.testing.expectEqual(@as(usize, 6), mesh.indices.len); // 2 triangles
    try std.testing.expectEqual(@as(u32, 2), mesh.triangleCount());

    // Check bounds
    try std.testing.expectEqual(@as(f32, 0), mesh.bounds.origin.x);
    try std.testing.expectEqual(@as(f32, 0), mesh.bounds.origin.y);
    try std.testing.expectEqual(@as(f32, 100), mesh.bounds.size.width);
    try std.testing.expectEqual(@as(f32, 100), mesh.bounds.size.height);

    // Check UV coords are normalized
    try std.testing.expectEqual(@as(f32, 0), mesh.vertices.get(0).u);
    try std.testing.expectEqual(@as(f32, 0), mesh.vertices.get(0).v);
    try std.testing.expectEqual(@as(f32, 1), mesh.vertices.get(2).u);
    try std.testing.expectEqual(@as(f32, 1), mesh.vertices.get(2).v);
}

test "PathMesh fromConvexPolygon" {
    const triangle = [_]triangulator.Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 100 },
        .{ .x = 100, .y = 0 },
    };

    const mesh = try PathMesh.fromConvexPolygon(&triangle);

    try std.testing.expectEqual(@as(usize, 3), mesh.vertices.len);
    try std.testing.expectEqual(@as(usize, 3), mesh.indices.len);
    try std.testing.expectEqual(@as(u32, 1), mesh.triangleCount());
}

test "PathMesh isEmpty" {
    const empty = PathMesh.init();
    try std.testing.expect(empty.isEmpty());

    const triangle = [_]triangulator.Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 0.5, .y = 1 },
    };
    const mesh = try PathMesh.fromConvexPolygon(&triangle);
    try std.testing.expect(!mesh.isEmpty());
}

test "PathMesh vertexBytes and indexBytes" {
    const triangle = [_]triangulator.Vec2{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 0.5, .y = 1 },
    };
    const mesh = try PathMesh.fromConvexPolygon(&triangle);

    const vb = mesh.vertexBytes();
    const ib = mesh.indexBytes();

    try std.testing.expectEqual(@as(usize, 3 * 16), vb.len); // 3 vertices * 16 bytes
    try std.testing.expectEqual(@as(usize, 3 * 4), ib.len); // 3 indices * 4 bytes
}
