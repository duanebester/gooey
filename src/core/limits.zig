//! Path Rendering Limits - Centralized documentation and constants
//!
//! This module documents the various limits used throughout the path rendering
//! system. These limits serve different purposes at different levels:
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
//!                                    │
//!                                    ▼
//! ┌─────────────────────────────────────────────────────────────────────────┐
//! │ GPU Buffer Limits (platform-specific)                                   │
//! │ - Web: MAX_PATH_VERTICES=16384, MAX_PATH_INDICES=49152, MAX_PATHS=256   │
//! │ - Metal: Uses mesh pool directly (no separate buffer limits)            │
//! │ Purpose: Size GPU buffers, handle batch capacity                        │
//! └─────────────────────────────────────────────────────────────────────────┘
//! ```
//!
//! ## Why Web Limits Differ
//!
//! The web renderer (WGPU) uses larger vertex/index limits (16384/49152) than
//! the per-path limits (512/1530) because it batches multiple paths into a
//! single GPU buffer upload. The web limits represent the total buffer capacity
//! for ALL paths in a single draw batch, not per-path limits.
//!
//! Relationship: Web buffer can hold ~32 maximum-size paths (16384 / 512)
//!
//! ## Memory Budget Estimates
//!
//! Per-path memory (at MAX_PATH_VERTICES=512):
//!   - PathMesh: ~14KB (512 vertices × 16B + 1530 indices × 4B)
//!
//! Mesh pool memory (at max capacity):
//!   - Persistent: 512 × 14KB = ~7MB
//!   - Frame: 256 × 14KB = ~3.5MB
//!   - Total: ~10.5MB (heap allocated per CLAUDE.md)
//!
//! Per-frame instance memory (at MAX_PATHS_PER_FRAME=4096):
//!   - PathInstances: 4096 × 112B = ~450KB
//!   - GradientUniforms: 4096 × 352B = ~1.4MB
//!

const std = @import("std");

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
// Per-Frame Instance Limits
// =============================================================================

/// Maximum path instances (draw calls) per frame
/// Source: scene.zig
pub const MAX_PATHS_PER_FRAME: u32 = 4096;

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
// Compile-time Validation
// =============================================================================

comptime {
    // Ensure web batch can hold at least a few max-size paths
    std.debug.assert(WEB_BATCH_VERTICES >= MAX_PATH_VERTICES * 4);
    std.debug.assert(WEB_BATCH_INDICES >= MAX_PATH_INDICES * 4);

    // Ensure frame mesh limit doesn't exceed persistent limit
    // (persistent is the "premium" tier, should have more capacity)
    std.debug.assert(MAX_FRAME_MESHES <= MAX_PERSISTENT_MESHES);

    // Ensure per-frame instance limit is reasonable
    std.debug.assert(MAX_PATHS_PER_FRAME >= 1024);
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
