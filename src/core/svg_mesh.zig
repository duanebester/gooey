//! SVG Mesh - GPU-ready tessellated SVG data
//!
//! Combines parsed SVG path, tessellation, and GPU buffers into a
//! reusable mesh that can be rendered multiple times at different
//! positions, scales, and colors.

const std = @import("std");
const scene = @import("scene.zig");
const svg_mod = @import("svg.zig");
const tessellator_mod = @import("tessellator.zig");

pub const Vec2 = svg_mod.Vec2;

/// A tessellated SVG mesh ready for GPU rendering
pub const SvgMesh = struct {
    /// Vertex positions (in SVG coordinate space)
    vertices: []Vec2,
    /// Triangle indices (triplets, CCW winding)
    indices: []u16,
    /// Bounding box for the mesh
    bounds: Bounds,
    /// Original viewbox from SVG (if any)
    viewbox: ?Viewbox,

    allocator: std.mem.Allocator,

    pub const Bounds = struct {
        min_x: f32,
        min_y: f32,
        max_x: f32,
        max_y: f32,

        pub fn width(self: Bounds) f32 {
            return self.max_x - self.min_x;
        }

        pub fn height(self: Bounds) f32 {
            return self.max_y - self.min_y;
        }
    };

    pub const Viewbox = struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    };

    pub fn deinit(self: *SvgMesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
    }

    /// Get triangle count
    pub fn triangleCount(self: *const SvgMesh) usize {
        return self.indices.len / 3;
    }

    /// Get vertex count
    pub fn vertexCount(self: *const SvgMesh) usize {
        return self.vertices.len;
    }
};

/// Load and tessellate an SVG path string
pub fn loadFromPathData(allocator: std.mem.Allocator, path_data: []const u8) !SvgMesh {
    return loadFromPathDataWithTolerance(allocator, path_data, 0.5);
}

/// Load with custom curve flattening tolerance
pub fn loadFromPathDataWithTolerance(
    allocator: std.mem.Allocator,
    path_data: []const u8,
    tolerance: f32,
) !SvgMesh {
    // Parse path
    var parser = svg_mod.PathParser.init(allocator);
    var path = svg_mod.SvgPath.init(allocator);
    defer path.deinit();

    try parser.parse(&path, path_data);

    // Flatten curves to polygons
    var points: std.ArrayListUnmanaged(Vec2) = .{};
    defer points.deinit(allocator);
    var polygons: std.ArrayListUnmanaged(svg_mod.IndexSlice) = .{};
    defer polygons.deinit(allocator);

    try svg_mod.flattenPath(allocator, &path, tolerance, &points, &polygons);

    if (points.items.len < 3 or polygons.items.len == 0) {
        return error.EmptyPath;
    }

    // Tessellate
    var tess = tessellator_mod.Tessellator.init(allocator);
    defer tess.deinit();

    const result = try tess.tessellate(points.items, polygons.items);
    // result owns the memory, transfer to SvgMesh

    // Compute bounds
    var bounds = SvgMesh.Bounds{
        .min_x = std.math.floatMax(f32),
        .min_y = std.math.floatMax(f32),
        .max_x = std.math.floatMin(f32),
        .max_y = std.math.floatMin(f32),
    };
    for (result.vertices) |v| {
        bounds.min_x = @min(bounds.min_x, v.x);
        bounds.min_y = @min(bounds.min_y, v.y);
        bounds.max_x = @max(bounds.max_x, v.x);
        bounds.max_y = @max(bounds.max_y, v.y);
    }

    return SvgMesh{
        .vertices = result.vertices,
        .indices = result.indices,
        .bounds = bounds,
        .viewbox = null,
        .allocator = allocator,
    };
}

/// GPU-ready instance data for rendering an SVG mesh
pub const SvgInstance = extern struct {
    // Transform: position and scale
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,

    // Fill color (HSLA)
    color: scene.Hsla = scene.Hsla.black,

    // Clip bounds
    clip_x: f32 = -1e9,
    clip_y: f32 = -1e9,
    clip_width: f32 = 2e9,
    clip_height: f32 = 2e9,

    // Draw order
    order: scene.DrawOrder = 0,
    _pad: [3]f32 = .{ 0, 0, 0 },

    pub fn init(x: f32, y: f32, scale: f32, color: scene.Hsla) SvgInstance {
        return .{
            .offset_x = x,
            .offset_y = y,
            .scale_x = scale,
            .scale_y = scale,
            .color = color,
        };
    }

    pub fn withClip(self: SvgInstance, clip_x: f32, clip_y: f32, clip_w: f32, clip_h: f32) SvgInstance {
        var copy = self;
        copy.clip_x = clip_x;
        copy.clip_y = clip_y;
        copy.clip_width = clip_w;
        copy.clip_height = clip_h;
        return copy;
    }
};

// Compile-time size check for GPU alignment
comptime {
    // SvgInstance should be 64 bytes for good GPU alignment
    if (@sizeOf(SvgInstance) != 64) {
        @compileError(std.fmt.comptimePrint(
            "SvgInstance size must be 64 bytes, got {} bytes",
            .{@sizeOf(SvgInstance)},
        ));
    }
}
