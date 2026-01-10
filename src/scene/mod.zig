//! Scene - GPU Primitives
//!
//! Low-level rendering primitives for GPU submission.
//!
//! - `Scene` - Collects and sorts primitives for a frame
//! - `Quad` - Filled/bordered rectangle
//! - `Shadow` - Drop shadow primitive
//! - `GlyphInstance` - Text glyph for GPU rendering
//! - `SvgInstance` - SVG icon instance
//! - `ImageInstance` - Raster image instance
//! - `BatchIterator` - Yields draw-order batches for efficient rendering

const std = @import("std");

// =============================================================================
// Scene
// =============================================================================

pub const scene = @import("scene.zig");

pub const Scene = scene.Scene;
pub const DrawOrder = scene.DrawOrder;

// Hard limits (static memory allocation policy)
pub const MAX_QUADS_PER_FRAME = scene.MAX_QUADS_PER_FRAME;
pub const MAX_GLYPHS_PER_FRAME = scene.MAX_GLYPHS_PER_FRAME;
pub const MAX_SHADOWS_PER_FRAME = scene.MAX_SHADOWS_PER_FRAME;
pub const MAX_SVGS_PER_FRAME = scene.MAX_SVGS_PER_FRAME;
pub const MAX_IMAGES_PER_FRAME = scene.MAX_IMAGES_PER_FRAME;
pub const MAX_PATHS_PER_FRAME = scene.MAX_PATHS_PER_FRAME;
pub const MAX_POLYLINES_PER_FRAME = scene.MAX_POLYLINES_PER_FRAME;
pub const MAX_POINT_CLOUDS_PER_FRAME = scene.MAX_POINT_CLOUDS_PER_FRAME;
pub const MAX_CLIP_STACK_DEPTH = scene.MAX_CLIP_STACK_DEPTH;

// Geometry aliases (GPU-aligned)
pub const Point = scene.Point;
pub const Size = scene.Size;
pub const Bounds = scene.Bounds;
pub const Corners = scene.Corners;
pub const Edges = scene.Edges;

// Color
pub const Hsla = scene.Hsla;

// Content mask / clipping
pub const ContentMask = scene.ContentMask;

// =============================================================================
// Primitives
// =============================================================================

pub const Quad = scene.Quad;
pub const Shadow = scene.Shadow;
pub const GlyphInstance = scene.GlyphInstance;

// =============================================================================
// SVG Instance
// =============================================================================

pub const svg_instance = @import("svg_instance.zig");
pub const SvgInstance = svg_instance.SvgInstance;

// =============================================================================
// Path Instance
// =============================================================================

pub const path_instance = @import("path_instance.zig");
pub const PathInstance = path_instance.PathInstance;

// =============================================================================
// Polyline (efficient chart/data visualization)
// =============================================================================

pub const polyline = @import("polyline.zig");
pub const Polyline = polyline.Polyline;
pub const MAX_POLYLINE_POINTS = polyline.MAX_POLYLINE_POINTS;

// =============================================================================
// Point Cloud (instanced circles for scatter plots/markers)
// =============================================================================

pub const point_cloud = @import("point_cloud.zig");
pub const PointCloud = point_cloud.PointCloud;
pub const MAX_POINTS_PER_CLOUD = point_cloud.MAX_POINTS_PER_CLOUD;

// =============================================================================
// Path Mesh
// =============================================================================

pub const path_mesh = @import("path_mesh.zig");
pub const PathMesh = path_mesh.PathMesh;
pub const PathVertex = path_mesh.PathVertex;
pub const MAX_MESH_VERTICES = path_mesh.MAX_MESH_VERTICES;
pub const MAX_MESH_INDICES = path_mesh.MAX_MESH_INDICES;

// =============================================================================
// Mesh Pool
// =============================================================================

pub const mesh_pool = @import("mesh_pool.zig");
pub const MeshPool = mesh_pool.MeshPool;
pub const MeshRef = mesh_pool.MeshRef;
pub const MAX_PERSISTENT_MESHES = mesh_pool.MAX_PERSISTENT_MESHES;
pub const MAX_FRAME_MESHES = mesh_pool.MAX_FRAME_MESHES;

// =============================================================================
// Gradient Uniforms
// =============================================================================

pub const gradient_uniforms = @import("gradient_uniforms.zig");
pub const GradientUniforms = gradient_uniforms.GradientUniforms;
pub const GPU_MAX_STOPS = gradient_uniforms.GPU_MAX_STOPS;

// =============================================================================
// Image Instance
// =============================================================================

pub const image_instance = @import("image_instance.zig");
pub const ImageInstance = image_instance.ImageInstance;

// =============================================================================
// Batch Iterator
// =============================================================================

pub const batch_iterator = @import("batch_iterator.zig");

pub const BatchIterator = batch_iterator.BatchIterator;
pub const PrimitiveBatch = batch_iterator.PrimitiveBatch;
pub const PrimitiveKind = batch_iterator.PrimitiveKind;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
