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
const assert = std.debug.assert;

// Element types, imported only for `@sizeOf` in budget and memory estimates. The
// scene module imports this file for its ceilings; the cycle is between files,
// not between comptime values, so Zig resolves it.
const scene_types = @import("../scene/scene.zig");
const SvgInstance = @import("../scene/svg_instance.zig").SvgInstance;
const ImageInstance = @import("../scene/image_instance.zig").ImageInstance;
const PathInstance = @import("../scene/path_instance.zig").PathInstance;
const GradientUniforms = @import("../scene/gradient_uniforms.zig").GradientUniforms;
const Polyline = @import("../scene/polyline.zig").Polyline;
const PointCloud = @import("../scene/point_cloud.zig").PointCloud;
const ColoredPointCloud = @import("../scene/colored_point_cloud.zig").ColoredPointCloud;

// =============================================================================
// Rendering Limits (absolute framework ceilings)
// =============================================================================
//
// These are the ceilings an application budget (`ResourceLimits`) may not
// exceed. They are not the capacities a window allocates: `ResourceLimits`
// selects those, and `SceneLimits.check` enforces `budget <= ceiling`.

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
// Application Resource Budget
// =============================================================================

/// The complete resource budget an application declares at `gooey.App(...)`
/// (`.limits = ...`), per CLAUDE.md §2. Every per-window subsystem sizes its
/// storage from this value during initialization and never grows afterwards.
///
/// Each subsystem owns one nested struct so later budgets (layout, a11y, text,
/// widgets) are added as new fields beside `scene` without reshaping the type.
/// Fields have no defaults: callers pick a named profile or spell out every
/// capacity, so no capacity hides in a leaf default.
pub const ResourceLimits = struct {
    scene: SceneLimits,

    /// Measured default for ordinary UI apps. See `SceneLimits.standard`.
    pub const standard: ResourceLimits = .{ .scene = SceneLimits.standard };

    /// Dense-content apps: big tables, treemaps, full-screen editors, charts.
    pub const large: ResourceLimits = .{ .scene = SceneLimits.large };

    /// Every capacity at its framework ceiling. For stress tests and benchmarks;
    /// costs about 16.5 MiB per scene and 25.5 MiB of Metal instance ring.
    pub const ceiling: ResourceLimits = .{ .scene = SceneLimits.ceiling };

    /// First violated rule, or null when the budget is valid. Shared by the
    /// comptime `validate` and the runtime initialization checks.
    pub fn check(self: *const ResourceLimits) ?Violation {
        return self.scene.check();
    }

    /// Runtime counterpart of `validate` for budgets that are not comptime-known
    /// (direct `runCx` / `openWindow` callers). An invalid budget is a
    /// programmer error, so it stops initialization with the broken rule.
    pub fn assertValid(self: *const ResourceLimits) void {
        if (self.check()) |violation| {
            std.debug.panic("invalid ResourceLimits.scene.{s} = {d}: rule {s}, bound {d}", .{
                violation.field,
                violation.value,
                @tagName(violation.rule),
                violation.bound,
            });
        }
    }

    /// Reject an invalid budget at compile time with a message naming the
    /// field, its value, and the bound it broke.
    pub fn validate(comptime self: ResourceLimits) void {
        comptime {
            if (self.check()) |violation| @compileError(violation.describe());
        }
    }
};

/// Per-window, per-frame scene capacities. Each window allocates two scenes
/// (built and presented) of exactly these sizes, plus a Metal instance ring of
/// `unifiedPrimitiveCountMax()` primitives per frame in flight.
pub const SceneLimits = struct {
    quad_count_frame_max: u32,
    shadow_count_frame_max: u32,
    glyph_count_frame_max: u32,
    svg_count_frame_max: u32,
    image_count_frame_max: u32,
    /// Path instances; the parallel gradient array has the same capacity.
    path_count_frame_max: u32,
    polyline_count_frame_max: u32,
    point_cloud_count_frame_max: u32,
    colored_point_cloud_count_frame_max: u32,
    clip_depth_max: u32,

    /// Measured default. Peaks recorded across 24 examples while scrolling,
    /// hovering, and switching tabs, at 800x600-class and 1512x945 windows:
    /// quads 780 (lucide-demo), shadows 3, glyphs 1370 (showcase), SVGs 480,
    /// images 18, paths 256, polylines 5, point clouds 0, colored point clouds 3,
    /// clip depth 2. Headroom is about 10x for quads and glyphs, which also
    /// covers a 5K-class window (about 2.6x the area of the measured one).
    /// Scene storage: about 2.9 MiB per scene, two scenes per window.
    pub const standard: SceneLimits = .{
        .quad_count_frame_max = 8_192,
        .shadow_count_frame_max = 512,
        .glyph_count_frame_max = 16_384,
        .svg_count_frame_max = 1_024,
        .image_count_frame_max = 256,
        .path_count_frame_max = 1_024,
        .polyline_count_frame_max = 256,
        .point_cloud_count_frame_max = 256,
        .colored_point_cloud_count_frame_max = 256,
        .clip_depth_max = 16,
    };

    /// Heavy apps: about 4x `standard` for geometry and the glyph ceiling for
    /// full-screen text. Scene storage: about 11.6 MiB per scene.
    pub const large: SceneLimits = .{
        .quad_count_frame_max = 32_768,
        .shadow_count_frame_max = 2_048,
        .glyph_count_frame_max = 65_536,
        .svg_count_frame_max = 4_096,
        .image_count_frame_max = 1_024,
        .path_count_frame_max = 4_096,
        .polyline_count_frame_max = 1_024,
        .point_cloud_count_frame_max = 1_024,
        .colored_point_cloud_count_frame_max = 1_024,
        .clip_depth_max = 32,
    };

    /// The framework ceilings themselves; the upper bound for every budget.
    pub const ceiling: SceneLimits = .{
        .quad_count_frame_max = MAX_QUADS_PER_FRAME,
        .shadow_count_frame_max = MAX_SHADOWS_PER_FRAME,
        .glyph_count_frame_max = MAX_GLYPHS_PER_FRAME,
        .svg_count_frame_max = MAX_SVGS_PER_FRAME,
        .image_count_frame_max = MAX_IMAGES_PER_FRAME,
        .path_count_frame_max = MAX_PATHS_PER_FRAME,
        .polyline_count_frame_max = MAX_POLYLINES_PER_FRAME,
        .point_cloud_count_frame_max = MAX_POINT_CLOUDS_PER_FRAME,
        .colored_point_cloud_count_frame_max = MAX_COLORED_POINT_CLOUDS_PER_FRAME,
        .clip_depth_max = MAX_CLIP_STACK_DEPTH,
    };

    /// First violated rule, or null. Every field must be in `1..=ceiling`, and
    /// the cross-limit relationships below must hold.
    pub fn check(self: *const SceneLimits) ?Violation {
        inline for (@typeInfo(SceneLimits).@"struct".field_names) |field_name| {
            const value: u32 = @field(self, field_name);
            const bound: u32 = @field(ceiling, field_name);
            if (value == 0) {
                return .{ .field = field_name, .rule = .zero, .value = value, .bound = 1 };
            }
            if (value > bound) {
                return .{
                    .field = field_name,
                    .rule = .above_ceiling,
                    .value = value,
                    .bound = bound,
                };
            }
        }
        // One shaped text run is inserted whole, so a frame must hold at least one.
        if (self.glyph_count_frame_max < MAX_GLYPHS_PER_RUN) {
            return .{
                .field = "glyph_count_frame_max",
                .rule = .below_relationship,
                .value = self.glyph_count_frame_max,
                .bound = MAX_GLYPHS_PER_RUN,
            };
        }
        // The draw-order sort scratch is sized from the largest sortable pool.
        if (self.sortKeyCountMax() > MAX_SORT_KEYS) {
            return .{
                .field = "sortKeyCountMax()",
                .rule = .above_ceiling,
                .value = self.sortKeyCountMax(),
                .bound = MAX_SORT_KEYS,
            };
        }
        return null;
    }

    /// Capacity of the indirect draw-order sort scratch: the largest pool that
    /// `Scene.sortByOrder` sorts. Paths sort through their own fixed scratch.
    pub fn sortKeyCountMax(self: *const SceneLimits) u32 {
        var count_max: u32 = self.shadow_count_frame_max;
        count_max = @max(count_max, self.quad_count_frame_max);
        count_max = @max(count_max, self.glyph_count_frame_max);
        count_max = @max(count_max, self.svg_count_frame_max);
        count_max = @max(count_max, self.image_count_frame_max);
        count_max = @max(count_max, self.polyline_count_frame_max);
        count_max = @max(count_max, self.point_cloud_count_frame_max);
        count_max = @max(count_max, self.colored_point_cloud_count_frame_max);
        assert(count_max >= self.quad_count_frame_max);
        return count_max;
    }

    /// Quads plus shadows: both convert to one GPU primitive type and share the
    /// renderer's per-frame instance ring.
    pub fn unifiedPrimitiveCountMax(self: *const SceneLimits) u32 {
        assert(self.quad_count_frame_max <= MAX_QUADS_PER_FRAME);
        assert(self.shadow_count_frame_max <= MAX_SHADOWS_PER_FRAME);
        return self.quad_count_frame_max + self.shadow_count_frame_max;
    }

    /// Bytes one scene reserves for this budget (element arrays, path gradients,
    /// clip stack, and sort keys). Excludes the mesh pool, which has its own
    /// fixed limits.
    pub fn sceneBytes(self: *const SceneLimits) u64 {
        var bytes: u64 = 0;
        bytes += @as(u64, self.quad_count_frame_max) * @sizeOf(scene_types.Quad);
        bytes += @as(u64, self.shadow_count_frame_max) * @sizeOf(scene_types.Shadow);
        bytes += @as(u64, self.glyph_count_frame_max) * @sizeOf(scene_types.GlyphInstance);
        bytes += @as(u64, self.svg_count_frame_max) * @sizeOf(SvgInstance);
        bytes += @as(u64, self.image_count_frame_max) * @sizeOf(ImageInstance);
        bytes += @as(u64, self.path_count_frame_max) * @sizeOf(PathInstance);
        bytes += @as(u64, self.path_count_frame_max) * @sizeOf(GradientUniforms);
        bytes += @as(u64, self.polyline_count_frame_max) * @sizeOf(Polyline);
        bytes += @as(u64, self.point_cloud_count_frame_max) * @sizeOf(PointCloud);
        bytes += @as(u64, self.colored_point_cloud_count_frame_max) *
            @sizeOf(ColoredPointCloud);
        bytes += @as(u64, self.clip_depth_max) * @sizeOf(scene_types.ContentMask.ClipBounds);
        bytes += @as(u64, self.sortKeyCountMax()) * @sizeOf(u64);
        assert(bytes > 0);
        return bytes;
    }

    comptime {
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
    }
};

/// A broken budget rule, precise enough to name in a compile error.
pub const Violation = struct {
    field: []const u8,
    rule: Rule,
    value: u32,
    bound: u32,

    pub const Rule = enum { zero, above_ceiling, below_relationship };

    /// Human-readable message. Comptime only: used by `ResourceLimits.validate`.
    pub fn describe(comptime self: Violation) []const u8 {
        return switch (self.rule) {
            .zero => std.fmt.comptimePrint(
                "ResourceLimits.scene.{s} must be at least 1, got 0",
                .{self.field},
            ),
            .above_ceiling => std.fmt.comptimePrint(
                "ResourceLimits.scene.{s} = {d} exceeds the framework ceiling {d}",
                .{ self.field, self.value, self.bound },
            ),
            .below_relationship => std.fmt.comptimePrint(
                "ResourceLimits.scene.{s} = {d} is below the required minimum {d}",
                .{ self.field, self.value, self.bound },
            ),
        };
    }
};

/// Upper bound on the draw-order sort scratch: the largest sortable ceiling.
pub const MAX_SORT_KEYS: u32 = blk: {
    var count_max: u32 = 0;
    for ([_]u32{
        MAX_SHADOWS_PER_FRAME,
        MAX_QUADS_PER_FRAME,
        MAX_GLYPHS_PER_FRAME,
        MAX_SVGS_PER_FRAME,
        MAX_IMAGES_PER_FRAME,
        MAX_POLYLINES_PER_FRAME,
        MAX_POINT_CLOUDS_PER_FRAME,
        MAX_COLORED_POINT_CLOUDS_PER_FRAME,
    }) |count| count_max = @max(count_max, count);
    break :blk count_max;
};

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

/// Bytes per glyph instance, derived so the estimate cannot go stale (it was
/// hard-coded as 48 while the struct had grown to 80).
pub const GLYPH_INSTANCE_SIZE: u32 = @sizeOf(scene_types.GlyphInstance);
pub const ESTIMATED_GLYPH_MEMORY: u32 = MAX_GLYPHS_PER_FRAME * GLYPH_INSTANCE_SIZE;

/// Bytes per quad, derived (it was hard-coded as 128 while the struct is 112).
pub const QUAD_SIZE: u32 = @sizeOf(scene_types.Quad);
pub const ESTIMATED_QUAD_MEMORY: u32 = MAX_QUADS_PER_FRAME * QUAD_SIZE;

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
    // Glyph memory at the ceiling should be under 8MB
    try std.testing.expect(ESTIMATED_GLYPH_MEMORY < 8 * 1024 * 1024);

    // Quad memory should be under 16MB
    try std.testing.expect(ESTIMATED_QUAD_MEMORY < 16 * 1024 * 1024);

    // Total mesh pool memory should be under 16MB
    const total_mesh_memory = ESTIMATED_PERSISTENT_MESH_MEMORY + ESTIMATED_FRAME_MESH_MEMORY;
    try std.testing.expect(total_mesh_memory < 16 * 1024 * 1024);
}

test "named profiles are valid and ordered" {
    // Goal: every shipped profile passes the same rules `validate` applies, and
    // `large` never offers less than `standard` for any capacity.
    try std.testing.expect(ResourceLimits.standard.check() == null);
    try std.testing.expect(ResourceLimits.large.check() == null);
    try std.testing.expect(ResourceLimits.ceiling.check() == null);
    inline for (@typeInfo(SceneLimits).@"struct".field_names) |field_name| {
        const standard_value = @field(SceneLimits.standard, field_name);
        const large_value = @field(SceneLimits.large, field_name);
        try std.testing.expect(standard_value <= large_value);
        try std.testing.expect(large_value <= @field(SceneLimits.ceiling, field_name));
    }
}

test "check reports each negative case precisely" {
    // Goal: cover the rules `validate` turns into compile errors. Each case
    // starts from a valid profile and breaks exactly one rule at its boundary.
    var limits = ResourceLimits.standard;
    limits.scene.svg_count_frame_max = 0;
    const zero = limits.check().?;
    try std.testing.expectEqual(Violation.Rule.zero, zero.rule);
    try std.testing.expectEqualStrings("svg_count_frame_max", zero.field);

    limits = ResourceLimits.standard;
    limits.scene.quad_count_frame_max = MAX_QUADS_PER_FRAME + 1;
    const above = limits.check().?;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, above.rule);
    try std.testing.expectEqual(MAX_QUADS_PER_FRAME, above.bound);

    // Exactly at the ceiling is valid.
    limits.scene.quad_count_frame_max = MAX_QUADS_PER_FRAME;
    try std.testing.expect(limits.check() == null);

    limits = ResourceLimits.standard;
    limits.scene.glyph_count_frame_max = MAX_GLYPHS_PER_RUN - 1;
    const below = limits.check().?;
    try std.testing.expectEqual(Violation.Rule.below_relationship, below.rule);
    limits.scene.glyph_count_frame_max = MAX_GLYPHS_PER_RUN;
    try std.testing.expect(limits.check() == null);

    limits = ResourceLimits.standard;
    limits.scene.clip_depth_max = MAX_CLIP_STACK_DEPTH + 1;
    try std.testing.expectEqualStrings("clip_depth_max", limits.check().?.field);
}

test "derived budget quantities" {
    // Goal: pin the relationships other subsystems size from.
    const scene = SceneLimits.standard;
    try std.testing.expectEqual(@as(u32, 16_384), scene.sortKeyCountMax());
    try std.testing.expectEqual(@as(u32, 8_704), scene.unifiedPrimitiveCountMax());
    try std.testing.expectEqual(MAX_SORT_KEYS, SceneLimits.ceiling.sortKeyCountMax());
    try std.testing.expect(scene.sceneBytes() < SceneLimits.large.sceneBytes());
    try std.testing.expect(SceneLimits.large.sceneBytes() < SceneLimits.ceiling.sceneBytes());
    // The documented sizes stay honest.
    try std.testing.expect(scene.sceneBytes() < 3 * 1024 * 1024);
    try std.testing.expect(SceneLimits.large.sceneBytes() < 12 * 1024 * 1024);
}
