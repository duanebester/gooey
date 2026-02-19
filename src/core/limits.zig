//! Static allocation limits for Gooey
//!
//! All buffers and pools have fixed upper bounds to eliminate allocation
//! during rendering. If you hit a limit, increase it here and rebuild.
//!
//! ## Design Philosophy (per CLAUDE.md)
//!
//! - Zero dynamic allocation after initialization
//! - Pre-allocate pools for glyphs, render commands, widgets at startup
//! - Use fixed-capacity arrays instead of growing ArrayLists during rendering
//! - Put a limit on EVERYTHING to prevent infinite loops and tail latency spikes
//!
//! ## Limit Hierarchy
//!
//! ```
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ Per-Path Geometry Limits (triangulator.zig, path_mesh.zig)              │
//! │ - MAX_PATH_VERTICES: Maximum vertices in a single path                  │
//! │ - MAX_PATH_INDICES: Maximum indices after triangulation                 │
//! │ Purpose: Bound memory per PathMesh, prevent stack overflow              │
//! └─────────────────────────────────────────────────────────────────────────┘
//!                                    │
//!                                    ▼
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ Mesh Pool Limits (mesh_pool.zig)                                        │
//! │ - MAX_PERSISTENT_MESHES: Cached meshes (icons, static shapes)           │
//! │ - MAX_FRAME_MESHES: Per-frame scratch meshes (animations)               │
//! │ Purpose: Bound total mesh storage, enable cache eviction                │
//! └─────────────────────────────────────────────────────────────────────────┘
//!                                    │
//!                                    ▼
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ Per-Frame Instance Limits (scene.zig)                                   │
//! │ - MAX_PATHS_PER_FRAME: Total path draw calls per frame                  │
//! │ Purpose: Bound GPU upload size, fail fast on runaway rendering          │
//! └─────────────────────────────────────────────────────────────────────────┘
//! ```

const std = @import("std");

// =============================================================================
// Rendering Limits
// =============================================================================

/// Maximum quads per frame (rectangles, backgrounds)
pub const MAX_QUADS_PER_FRAME: u32 = 65536;

/// Maximum glyphs per frame (text characters)
pub const MAX_GLYPHS_PER_FRAME: u32 = 65536;

/// Maximum shadows per frame
pub const MAX_SHADOWS_PER_FRAME: u32 = 4096;

/// Maximum SVG instances per frame
pub const MAX_SVGS_PER_FRAME: u32 = 8192;

/// Maximum images per frame
pub const MAX_IMAGES_PER_FRAME: u32 = 4096;

/// Maximum path instances per frame
pub const MAX_PATHS_PER_FRAME: u32 = 4096;

/// Maximum polylines per frame
pub const MAX_POLYLINES_PER_FRAME: u32 = 4096;

/// Maximum point clouds per frame
pub const MAX_POINT_CLOUDS_PER_FRAME: u32 = 4096;

/// Maximum colored point clouds per frame (per-point colors for heat maps, particle effects)
pub const MAX_COLORED_POINT_CLOUDS_PER_FRAME: u32 = 4096;

/// Maximum clip stack depth (nested clips)
pub const MAX_CLIP_STACK_DEPTH: u32 = 32;

// =============================================================================
// Layout Limits
// =============================================================================

/// Maximum layout elements in tree
pub const MAX_LAYOUT_ELEMENTS: u32 = 4096;

/// Maximum nested component depth (prevent stack overflow)
pub const MAX_NESTED_COMPONENTS: u32 = 64;

/// Maximum render commands per frame
pub const MAX_RENDER_COMMANDS: u32 = 8192;

// =============================================================================
// Text Limits
// =============================================================================

/// Maximum glyphs in a single shaped run
pub const MAX_GLYPHS_PER_RUN: u32 = 1024;

/// Maximum cached shaped runs
pub const MAX_SHAPED_RUN_CACHE: u32 = 256;

/// Maximum text length for single-line inputs
pub const MAX_TEXT_LEN: u32 = 512;

// =============================================================================
// Accessibility Limits
// =============================================================================

/// Maximum accessibility tree elements
pub const MAX_A11Y_ELEMENTS: u32 = 1024;

/// Maximum pending announcements
pub const MAX_A11Y_ANNOUNCEMENTS: u32 = 16;

// =============================================================================
// Widget Limits
// =============================================================================

/// Maximum concurrent widgets
pub const MAX_WIDGETS: u32 = 256;

/// Maximum deferred commands per frame
pub const MAX_DEFERRED_COMMANDS: u32 = 32;

// =============================================================================
// Window Limits
// =============================================================================

/// Maximum windows per application
pub const MAX_WINDOWS: u32 = 8;

// =============================================================================
// Per-Path Geometry Limits
// =============================================================================

/// Maximum vertices per individual path.
/// Constrains PathMesh size to ~14KB to avoid stack overflow.
/// Source: triangulator.zig, path_mesh.zig
pub const MAX_PATH_VERTICES: u32 = 512;

/// Maximum triangles per path = MAX_PATH_VERTICES - 2 (simple polygon)
pub const MAX_PATH_TRIANGLES: u32 = MAX_PATH_VERTICES - 2;

/// Maximum indices per path = triangles × 3
pub const MAX_PATH_INDICES: u32 = MAX_PATH_TRIANGLES * 3;

/// Maximum path commands per path
pub const MAX_PATH_COMMANDS: u32 = 2048;

/// Maximum data floats per path (commands like cubicTo need 6 floats)
pub const MAX_PATH_DATA: u32 = MAX_PATH_COMMANDS * 8;

/// Maximum subpaths (each moveTo starts a new subpath)
pub const MAX_SUBPATHS: u32 = 64;

// =============================================================================
// Stroke Limits
// =============================================================================

/// Maximum input points for stroke expansion
pub const MAX_STROKE_INPUT: u32 = 512;

/// Maximum output points for stroke expansion.
/// Kept small to avoid stack overflow (ExpandedStroke ~8KB at 1024 points).
/// For UI strokes, 1024 points is plenty (circles flatten to ~64 points).
pub const MAX_STROKE_OUTPUT: u32 = 1024;

/// Number of segments for round caps/joins (affects smoothness)
pub const ROUND_SEGMENTS: u32 = 8;

/// Maximum triangles for direct stroke triangulation
pub const MAX_STROKE_TRIANGLES: u32 = MAX_STROKE_OUTPUT;

/// Maximum indices for stroke triangulation (3 per triangle)
pub const MAX_STROKE_INDICES: u32 = MAX_STROKE_TRIANGLES * 3;

// =============================================================================
// Mesh Pool Limits
// =============================================================================

/// Maximum persistent meshes (cached across frames: icons, static shapes)
/// Source: mesh_pool.zig
pub const MAX_PERSISTENT_MESHES: u32 = 512;

/// Maximum per-frame meshes (dynamic paths, animations, canvas callbacks)
/// Source: mesh_pool.zig
pub const MAX_FRAME_MESHES: u32 = 256;

// =============================================================================
// GPU Buffer Limits (Web/WGPU specific)
// =============================================================================

/// Web renderer batch buffer capacity for vertices (holds multiple paths)
/// Note: This is LARGER than MAX_PATH_VERTICES because it's a batch buffer
pub const WEB_BATCH_VERTICES: u32 = 16384;

/// Web renderer batch buffer capacity for indices
pub const WEB_BATCH_INDICES: u32 = 49152;

/// Web renderer maximum paths per batch
pub const WEB_MAX_PATHS_PER_BATCH: u32 = 256;

// =============================================================================
// Shader Constants
// =============================================================================

/// Maximum gradient color stops (must match GPU shader definitions)
pub const MAX_GRADIENT_STOPS: u32 = 16;

/// Epsilon for gradient range comparisons (avoids division by zero)
/// Used in both Metal and WGSL shaders for consistency
pub const GRADIENT_RANGE_EPSILON: f32 = 0.0001;

// =============================================================================
// Memory Budget Estimates
// =============================================================================

/// Estimated memory for glyph instances (for capacity planning)
pub const GLYPH_INSTANCE_SIZE: u32 = 48; // bytes per GlyphInstance
pub const ESTIMATED_GLYPH_MEMORY: u32 = MAX_GLYPHS_PER_FRAME * GLYPH_INSTANCE_SIZE;

/// Estimated memory for quads
pub const QUAD_SIZE: u32 = 128; // bytes per Quad (with all fields)
pub const ESTIMATED_QUAD_MEMORY: u32 = MAX_QUADS_PER_FRAME * QUAD_SIZE; // 8MB at 65536 quads

/// Per-path memory (at MAX_PATH_VERTICES=512):
///   - PathMesh: ~14KB (512 vertices × 16B + 1530 indices × 4B)
pub const ESTIMATED_PATH_MESH_SIZE: u32 = MAX_PATH_VERTICES * 16 + MAX_PATH_INDICES * 4;

/// Mesh pool memory estimates
pub const ESTIMATED_PERSISTENT_MESH_MEMORY: u32 = MAX_PERSISTENT_MESHES * ESTIMATED_PATH_MESH_SIZE;
pub const ESTIMATED_FRAME_MESH_MEMORY: u32 = MAX_FRAME_MESHES * ESTIMATED_PATH_MESH_SIZE;

// =============================================================================
// Compile-time Validation
// =============================================================================

comptime {
    // Sanity checks - fail compilation if limits are unreasonable
    std.debug.assert(MAX_GLYPHS_PER_FRAME >= MAX_GLYPHS_PER_RUN);
    std.debug.assert(MAX_NESTED_COMPONENTS <= 256); // Stack safety
    std.debug.assert(MAX_CLIP_STACK_DEPTH <= 64); // Reasonable nesting

    // Ensure web batch can hold at least a few max-size paths
    std.debug.assert(WEB_BATCH_VERTICES >= MAX_PATH_VERTICES * 4);
    std.debug.assert(WEB_BATCH_INDICES >= MAX_PATH_INDICES * 4);

    // Ensure frame mesh limit doesn't exceed persistent limit
    // (persistent is the "premium" tier, should have more capacity)
    std.debug.assert(MAX_FRAME_MESHES <= MAX_PERSISTENT_MESHES);

    // Ensure per-frame instance limit is reasonable
    std.debug.assert(MAX_PATHS_PER_FRAME >= 1024);

    // Indices are derived from vertices correctly
    std.debug.assert(MAX_PATH_TRIANGLES == MAX_PATH_VERTICES - 2);
    std.debug.assert(MAX_PATH_INDICES == MAX_PATH_TRIANGLES * 3);

    // Stroke limits are self-consistent
    std.debug.assert(MAX_STROKE_OUTPUT >= MAX_STROKE_INPUT);
    std.debug.assert(MAX_STROKE_TRIANGLES == MAX_STROKE_OUTPUT);
    std.debug.assert(MAX_STROKE_INDICES == MAX_STROKE_TRIANGLES * 3);
    std.debug.assert(ROUND_SEGMENTS >= 4); // Minimum for visual smoothness
}

// =============================================================================
// Tests
// =============================================================================

test "limit relationships" {
    // Indices are derived from vertices correctly
    try std.testing.expectEqual(MAX_PATH_TRIANGLES, MAX_PATH_VERTICES - 2);
    try std.testing.expectEqual(MAX_PATH_INDICES, MAX_PATH_TRIANGLES * 3);

    // Web batch can hold multiple paths
    const paths_per_batch = WEB_BATCH_VERTICES / MAX_PATH_VERTICES;
    try std.testing.expect(paths_per_batch >= 4);
}

test "memory estimates are reasonable" {
    // Glyph memory should be under 4MB
    try std.testing.expect(ESTIMATED_GLYPH_MEMORY < 4 * 1024 * 1024);

    // Quad memory should be under 16MB
    try std.testing.expect(ESTIMATED_QUAD_MEMORY < 16 * 1024 * 1024);

    // Total mesh pool memory should be under 16MB
    const total_mesh_memory = ESTIMATED_PERSISTENT_MESH_MEMORY + ESTIMATED_FRAME_MESH_MEMORY;
    try std.testing.expect(total_mesh_memory < 16 * 1024 * 1024);
}
