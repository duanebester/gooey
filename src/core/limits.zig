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
const FontVariant = @import("../text/types.zig").FontVariant;

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

/// Widest framebuffer, in physical pixels, any window budget may declare (8K UHD).
pub const MAX_FRAMEBUFFER_WIDTH: u32 = 7680;

/// Tallest framebuffer, in physical pixels, any window budget may declare (8K UHD).
pub const MAX_FRAMEBUFFER_HEIGHT: u32 = 4320;

/// Most frames a renderer may have in flight. Every per-frame GPU ring, pool and
/// command buffer is reserved once per frame in flight, so this bounds them all.
pub const MAX_FRAMES_IN_FLIGHT: u32 = 3;

/// Fewest frames in flight: one the GPU reads while the CPU records the next.
/// Metal's `maximumDrawableCount` accepts only 2 or 3, which the range matches.
pub const MIN_FRAMES_IN_FLIGHT: u32 = 2;

/// Largest atlas side, in pixels, any atlas budget may declare. 4096² RGBA is 64 MiB.
pub const MAX_ATLAS_SIZE: u32 = 4096;

/// Smallest atlas side. Atlas sides are multiples of the shelf height quantum.
pub const MIN_ATLAS_SIZE: u32 = 64;

/// Largest SVG icon side, in device pixels, any atlas budget may rasterize.
pub const MAX_SVG_ICON_SIZE: u32 = 256;

/// Most bytes of path data (raw `d` data or shape elements) any atlas budget
/// lets one SVG icon carry. Lucide's longest icon is 808 B.
pub const MAX_SVG_PATH_BYTES: u32 = 64 * 1024;

/// Most vertices one SVG icon may flatten to under any atlas budget. Curves
/// flatten to half a device pixel, so the count grows with the icon's side:
/// Lucide's heaviest, `loader_pinwheel`, is 2,140 at 64 px and 8,530 at 256.
pub const MAX_SVG_PATH_VERTEX_COUNT: u32 = 32 * 1024;

/// Largest glyph bitmap side, in device pixels (the glyph render buffer).
pub const MAX_GLYPH_SIZE: u32 = 256;

/// Most rasterized atlas bytes any budget may upload in one frame: one 4096² R8
/// atlas plus two 4096² RGBA atlases spread over three frames.
pub const MAX_ATLAS_UPLOAD_BYTES_PER_FRAME: u32 = 48 * 1024 * 1024;

comptime {
    assert(MAX_ATLAS_UPLOAD_BYTES_PER_FRAME * 3 == MAX_ATLAS_SIZE * MAX_ATLAS_SIZE * 9);
}

// =============================================================================
// Application Resource Budget
// =============================================================================

/// The complete resource budget an application declares at `gooey.App(...)`
/// (`.limits = ...`), per CLAUDE.md §2. Every per-window subsystem sizes its
/// storage from this value during initialization and never grows afterwards.
///
/// Each subsystem owns one nested struct so later budgets (layout, a11y, text,
/// widgets) are added as new fields beside `scene`, `window` and `frame` without
/// reshaping the type. Fields have no defaults and there is no default profile:
/// callers pick one of the five named rungs or spell out every capacity, so no
/// capacity hides in a leaf default.
///
/// The rungs, smallest first, and the example class each was sized from
/// (docs/v0.4.0-memory-budget.md §4, measured peaks with their headroom):
/// `nano` (counter, actions, animation), `small` (todo, layout, accessible-form),
/// `standard` (showcase, data-table, spaceship, dashboard), `large` (lucide-demo,
/// images, mesh stress) and `ceiling` (every framework maximum).
pub const ResourceLimits = struct {
    scene: SceneLimits,
    window: WindowLimits,
    frame: FrameLimits,
    atlas: AtlasLimits,
    build: BuildLimits,
    records: RecordLimits,
    retained: RetainedLimits,
    events: EventLimits,
    text: TextLimits,
    entities: EntityLimits,

    /// Every profile name `gooey.App(.., .{ .limits = ... })` accepts, smallest first.
    /// `FontLimits` has a profile of each name, so one name selects both budgets.
    pub const profile_names = [_][]const u8{ "nano", "small", "standard", "large", "ceiling" };

    /// Counter-class apps: a few dozen elements and one face, two frames in flight.
    pub const nano: ResourceLimits = .{
        .scene = SceneLimits.nano,
        .window = WindowLimits.nano,
        .frame = FrameLimits.nano,
        .atlas = AtlasLimits.nano,
        .build = BuildLimits.nano,
        .records = RecordLimits.nano,
        .retained = RetainedLimits.nano,
        .events = EventLimits.nano,
        .text = TextLimits.nano,
        .entities = EntityLimits.nano,
    };

    /// Single-screen forms and lists, two frames in flight.
    pub const small: ResourceLimits = .{
        .scene = SceneLimits.small,
        .window = WindowLimits.small,
        .frame = FrameLimits.small,
        .atlas = AtlasLimits.small,
        .build = BuildLimits.small,
        .records = RecordLimits.small,
        .retained = RetainedLimits.small,
        .events = EventLimits.small,
        .text = TextLimits.small,
        .entities = EntityLimits.small,
    };

    /// Ordinary multi-panel UI apps. See `SceneLimits.standard`.
    pub const standard: ResourceLimits = .{
        .scene = SceneLimits.standard,
        .window = WindowLimits.standard,
        .frame = FrameLimits.standard,
        .atlas = AtlasLimits.standard,
        .build = BuildLimits.standard,
        .records = RecordLimits.standard,
        .retained = RetainedLimits.standard,
        .events = EventLimits.standard,
        .text = TextLimits.standard,
        .entities = EntityLimits.standard,
    };

    /// Dense-content apps: big tables, treemaps, full-screen editors, charts,
    /// hundreds of icons, large image atlases.
    pub const large: ResourceLimits = .{
        .scene = SceneLimits.large,
        .window = WindowLimits.large,
        .frame = FrameLimits.large,
        .atlas = AtlasLimits.large,
        .build = BuildLimits.large,
        .records = RecordLimits.large,
        .retained = RetainedLimits.large,
        .events = EventLimits.large,
        .text = TextLimits.large,
        .entities = EntityLimits.large,
    };

    /// Every capacity at its framework ceiling. For stress tests and benchmarks;
    /// costs about 16.5 MiB per scene and 25.5 MiB of Metal instance ring. The
    /// aggregate mesh geometry ceilings are validation bounds, not a renderable
    /// reservation: GPU renderers reserve geometry per frame in flight (Metal
    /// about 62 GiB per frame here), so a window that renders must lower them.
    pub const ceiling: ResourceLimits = .{
        .scene = SceneLimits.ceiling,
        .window = WindowLimits.ceiling,
        .frame = FrameLimits.ceiling,
        .atlas = AtlasLimits.ceiling,
        .build = BuildLimits.ceiling,
        .records = RecordLimits.ceiling,
        .retained = RetainedLimits.ceiling,
        .events = EventLimits.ceiling,
        .text = TextLimits.ceiling,
        .entities = EntityLimits.ceiling,
    };

    /// First violated rule, or null when the budget is valid. Shared by the
    /// comptime `validate` and the runtime initialization checks.
    pub fn check(self: *const ResourceLimits) ?Violation {
        if (self.scene.check()) |violation| return violation;
        if (self.window.check()) |violation| return violation;
        if (self.frame.check()) |violation| return violation;
        if (self.atlas.check()) |violation| return violation;
        if (checkCeilings(BuildLimits, .build, &self.build)) |violation| return violation;
        if (checkCeilings(RecordLimits, .records, &self.records)) |violation| return violation;
        if (checkCeilings(RetainedLimits, .retained, &self.retained)) |violation| return violation;
        if (checkCeilings(EventLimits, .events, &self.events)) |violation| return violation;
        if (self.text.check()) |violation| return violation;
        if (checkCeilings(EntityLimits, .entities, &self.entities)) |violation| return violation;
        return self.checkCoreRelationships();
    }

    /// Rules between the core's budgets. A hit record and a handler belong to
    /// an element, so neither can outnumber elements; the layout engine stores
    /// at most `MAX_LAYOUT_ENGINE_ELEMENTS` per frame.
    fn checkCoreRelationships(self: *const ResourceLimits) ?Violation {
        const element_count = self.build.element_count_frame_max;
        if (self.records.hit_record_count_frame_max > element_count) {
            return relationship(
                .records,
                "hit_record_count_frame_max",
                self.records.hit_record_count_frame_max,
                element_count,
            );
        }
        if (self.records.handler_count_frame_max > element_count * handler_count_element_max) {
            return relationship(
                .records,
                "handler_count_frame_max",
                self.records.handler_count_frame_max,
                element_count * handler_count_element_max,
            );
        }
        if (self.build.key_count_frame_max > element_count) {
            return relationship(
                .build,
                "key_count_frame_max",
                self.build.key_count_frame_max,
                element_count,
            );
        }
        if (self.records.paint_record_count_frame_max < element_count) {
            return .{
                .budget = .records,
                .field = "paint_record_count_frame_max",
                .rule = .below_relationship,
                .value = self.records.paint_record_count_frame_max,
                .bound = element_count,
            };
        }
        return null;
    }

    /// Runtime counterpart of `validate` for budgets that are not comptime-known
    /// (direct `runCx` / `openWindow` callers). An invalid budget is a
    /// programmer error, so it stops initialization with the broken rule.
    pub fn assertValid(self: *const ResourceLimits) void {
        if (self.check()) |violation| {
            std.debug.panic("invalid ResourceLimits.{t}.{s} = {d}: rule {t}, bound {d}", .{
                violation.budget,
                violation.field,
                violation.value,
                violation.rule,
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
/// `unifiedPrimitiveCountMax()` primitives per frame in flight. GPU renderers
/// also reserve mesh buffers from the aggregate geometry fields per frame in flight.
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
    /// Aggregate source geometry submitted per frame, summed over draws. Drawing
    /// a cached mesh twice consumes its vertices and indices twice. These counts
    /// are independent of draw budgets and of backend expansion or byte layouts.
    path_vertex_count_frame_max: u32,
    path_index_count_frame_max: u32,
    polyline_point_count_frame_max: u32,
    point_count_frame_max: u32,
    colored_point_count_frame_max: u32,
    clip_depth_max: u32,

    /// Counter-class apps. Largest measured peaks in the class (counter,
    /// dynamic-counters, actions, animation, file-dialog): quads 11, glyphs 118,
    /// no shadows, SVGs, images, paths or geometry. Headroom about 23x for quads;
    /// 1,024 glyphs is the floor because one shaped run is inserted whole. Mesh
    /// geometry allows a few small icons or one sparkline. About 127 KiB per scene.
    pub const nano: SceneLimits = .{
        .quad_count_frame_max = 256,
        .shadow_count_frame_max = 16,
        .glyph_count_frame_max = 1_024,
        .svg_count_frame_max = 16,
        .image_count_frame_max = 4,
        .path_count_frame_max = 16,
        .polyline_count_frame_max = 4,
        .point_cloud_count_frame_max = 4,
        .colored_point_cloud_count_frame_max = 4,
        .path_vertex_count_frame_max = 1_024,
        .path_index_count_frame_max = 2_048,
        .polyline_point_count_frame_max = 1_024,
        .point_count_frame_max = 1_024,
        .colored_point_count_frame_max = 1_024,
        .clip_depth_max = 8,
    };

    /// Single-screen apps. Largest measured peaks in the class (todo, layout,
    /// nested-overlay, drag-drop, accessible-form, code-editor): quads 40,
    /// shadows 2, glyphs 358, SVGs 2, no images, paths or geometry. Headroom
    /// about 25x for quads and 11x for glyphs. About 0.55 MiB per scene.
    pub const small: SceneLimits = .{
        .quad_count_frame_max = 1_024,
        .shadow_count_frame_max = 64,
        .glyph_count_frame_max = 4_096,
        .svg_count_frame_max = 128,
        .image_count_frame_max = 32,
        .path_count_frame_max = 128,
        .polyline_count_frame_max = 32,
        .point_cloud_count_frame_max = 32,
        .colored_point_cloud_count_frame_max = 32,
        .path_vertex_count_frame_max = 8_192,
        .path_index_count_frame_max = 8_192,
        .polyline_point_count_frame_max = 8_192,
        .point_count_frame_max = 8_192,
        .colored_point_count_frame_max = 8_192,
        .clip_depth_max = 16,
    };

    /// Ordinary multi-panel apps. Largest measured peaks in the class (showcase,
    /// data-table, spaceship, dashboard) while scrolling, hovering and switching
    /// tabs: quads 102 (spaceship), shadows 3, glyphs 1,370 (showcase), SVGs 26,
    /// images 1, paths 256, polylines 5, colored point clouds 3, clip depth 2.
    /// Quads and glyphs keep 40x and 6x headroom (decision 10 of the memory
    /// budget review); lucide-demo's 780 quads and 480 SVGs are on `large`.
    /// Geometry: dashboard needs 780 path vertices, 804 indices, 24 line points
    /// and 42 colored points, so the 4x cut (decision 3) still leaves at least
    /// 20x; `platform/linux/tests/mesh_stress.zig` (an 8,192-point line, 4,096
    /// points of each kind) runs on `large`. About 1.8 MiB per scene.
    pub const standard: SceneLimits = .{
        .quad_count_frame_max = 4_096,
        .shadow_count_frame_max = 512,
        .glyph_count_frame_max = 8_192,
        .svg_count_frame_max = 1_024,
        .image_count_frame_max = 256,
        .path_count_frame_max = 1_024,
        .polyline_count_frame_max = 256,
        .point_cloud_count_frame_max = 256,
        .colored_point_cloud_count_frame_max = 256,
        .path_vertex_count_frame_max = 16_384,
        .path_index_count_frame_max = 16_384,
        .polyline_point_count_frame_max = 32_768,
        .point_count_frame_max = 16_384,
        .colored_point_count_frame_max = 16_384,
        .clip_depth_max = 16,
    };

    /// Heavy apps: lucide-demo (780 quads, 480 SVGs), the images example, and the
    /// mesh stress fixtures. 16x `standard` for geometry and the glyph ceiling for
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
        .path_vertex_count_frame_max = 262_144,
        .path_index_count_frame_max = 262_144,
        .polyline_point_count_frame_max = 524_288,
        .point_count_frame_max = 262_144,
        .colored_point_count_frame_max = 262_144,
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
        .path_vertex_count_frame_max = MAX_PATHS_PER_FRAME * MAX_PATH_VERTICES,
        .path_index_count_frame_max = MAX_PATHS_PER_FRAME * MAX_PATH_INDICES,
        .polyline_point_count_frame_max = MAX_POLYLINES_PER_FRAME *
            @import("../scene/polyline.zig").MAX_POLYLINE_POINTS,
        .point_count_frame_max = MAX_POINT_CLOUDS_PER_FRAME *
            @import("../scene/point_cloud.zig").MAX_POINTS_PER_CLOUD,
        .colored_point_count_frame_max = MAX_COLORED_POINT_CLOUDS_PER_FRAME *
            @import("../scene/colored_point_cloud.zig").MAX_POINTS_PER_COLORED_CLOUD,
        .clip_depth_max = MAX_CLIP_STACK_DEPTH,
    };

    /// First violated rule, or null. Every field must be in `1..=ceiling`, and
    /// the cross-limit relationships below must hold.
    pub fn check(self: *const SceneLimits) ?Violation {
        inline for (@typeInfo(SceneLimits).@"struct".field_names) |field_name| {
            const value: u32 = @field(self, field_name);
            const bound: u32 = @field(ceiling, field_name);
            if (value == 0) {
                return .{
                    .budget = .scene,
                    .field = field_name,
                    .rule = .zero,
                    .value = value,
                    .bound = 1,
                };
            }
            if (value > bound) {
                return .{
                    .budget = .scene,
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
                .budget = .scene,
                .field = "glyph_count_frame_max",
                .rule = .below_relationship,
                .value = self.glyph_count_frame_max,
                .bound = MAX_GLYPHS_PER_RUN,
            };
        }
        // The draw-order sort scratch is sized from the largest sortable pool.
        if (self.sortKeyCountMax() > MAX_SORT_KEYS) {
            return .{
                .budget = .scene,
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
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
    }
};

/// Per-window framebuffer bounds, in physical pixels.
///
/// The CPU renderer backends (`-Dlinux-backend=wayland_cpu` and `fbdev`) reserve
/// their framebuffers and raster scratch for this size while the window
/// initializes and never resize them (CLAUDE.md §2). A Wayland window the
/// compositor makes larger renders at a reduced device scale, which the
/// compositor scales up; an fbdev panel larger than the budget fails
/// initialization. The GPU backends size their swapchains from the driver and
/// do not read these fields yet.
pub const WindowLimits = struct {
    framebuffer_width_max: u32,
    framebuffer_height_max: u32,

    /// Counter-class windows up to 1,280 x 800 points on a 2x Retina display (the
    /// budget is physical pixels). Two `wl_shm` frames map 31.3 MiB of virtual
    /// memory; pages become resident only for the window's actual size.
    pub const nano: WindowLimits = .{
        .framebuffer_width_max = 2560,
        .framebuffer_height_max = 1600,
    };

    /// Single-screen windows up to 1,920 x 1,080 points at 2x. Two `wl_shm` frames
    /// map 63.3 MiB of virtual memory; resident pages follow the window size.
    pub const small: WindowLimits = .{
        .framebuffer_width_max = 3840,
        .framebuffer_height_max = 2160,
    };

    /// Full screen at full scale on a 4K UHD display (3,840 wide) and on a 16"
    /// MacBook Pro (3,456 x 2,234), memory budget decision 2. Two `wl_shm` frames
    /// map 70.3 MiB per window; pages are touched, and so resident, only for the
    /// window's actual size.
    pub const standard: WindowLimits = .{
        .framebuffer_width_max = 3840,
        .framebuffer_height_max = 2400,
    };

    /// 5K, for full-screen windows on high-density desktop panels.
    pub const large: WindowLimits = .{
        .framebuffer_width_max = 5120,
        .framebuffer_height_max = 2880,
    };

    /// The framework ceilings themselves (8K UHD).
    pub const ceiling: WindowLimits = .{
        .framebuffer_width_max = MAX_FRAMEBUFFER_WIDTH,
        .framebuffer_height_max = MAX_FRAMEBUFFER_HEIGHT,
    };

    /// First violated rule, or null. Every field must be in `1..=ceiling`.
    pub fn check(self: *const WindowLimits) ?Violation {
        inline for (@typeInfo(WindowLimits).@"struct".field_names) |field_name| {
            const value: u32 = @field(self, field_name);
            const bound: u32 = @field(ceiling, field_name);
            if (value == 0) {
                return .{
                    .budget = .window,
                    .field = field_name,
                    .rule = .zero,
                    .value = value,
                    .bound = 1,
                };
            }
            if (value > bound) {
                return .{
                    .budget = .window,
                    .field = field_name,
                    .rule = .above_ceiling,
                    .value = value,
                    .bound = bound,
                };
            }
        }
        return null;
    }

    /// Pixels in the largest framebuffer the budget allows.
    pub fn framebufferPixelCountMax(self: *const WindowLimits) u64 {
        assert(self.framebuffer_width_max <= MAX_FRAMEBUFFER_WIDTH);
        assert(self.framebuffer_height_max <= MAX_FRAMEBUFFER_HEIGHT);
        return @as(u64, self.framebuffer_width_max) * self.framebuffer_height_max;
    }

    comptime {
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
    }
};

/// Frames a window's renderer keeps in flight. Every per-frame GPU resource is
/// reserved once per frame in flight at init: the Vulkan host and mesh pools,
/// descriptor sets, command buffers and fences, and the Metal instance and mesh
/// rings. It also sets the presentation image count: Metal's
/// `maximumDrawableCount` equals it, and the Vulkan swapchain asks for the
/// driver's minimum plus one image per frame in flight above two (the driver
/// minimum plus one, as before, at three). The CPU renderer draws synchronously,
/// so its two `wl_shm` slots, one the compositor reads and one being drawn, are
/// the minimum here and do not change with the budget.
///
/// Two frames halve the bound rings at `nano` and `small`, whose apps are not
/// GPU-bound, at the cost of less CPU/GPU overlap (memory budget decision 4).
/// `standard` and above keep three until frame pacing with two drawables has
/// been measured on a Mac.
pub const FrameLimits = struct {
    in_flight_count: u32,

    pub const nano: FrameLimits = .{ .in_flight_count = 2 };
    pub const small: FrameLimits = .{ .in_flight_count = 2 };
    pub const standard: FrameLimits = .{ .in_flight_count = 3 };
    pub const large: FrameLimits = .{ .in_flight_count = 3 };
    pub const ceiling: FrameLimits = .{ .in_flight_count = MAX_FRAMES_IN_FLIGHT };

    /// First violated rule, or null. The count must be in
    /// `MIN_FRAMES_IN_FLIGHT..=MAX_FRAMES_IN_FLIGHT`.
    pub fn check(self: *const FrameLimits) ?Violation {
        if (self.in_flight_count < MIN_FRAMES_IN_FLIGHT) {
            return .{
                .budget = .frame,
                .field = "in_flight_count",
                .rule = .below_relationship,
                .value = self.in_flight_count,
                .bound = MIN_FRAMES_IN_FLIGHT,
            };
        }
        if (self.in_flight_count > MAX_FRAMES_IN_FLIGHT) {
            return .{
                .budget = .frame,
                .field = "in_flight_count",
                .rule = .above_ceiling,
                .value = self.in_flight_count,
                .bound = MAX_FRAMES_IN_FLIGHT,
            };
        }
        return null;
    }

    comptime {
        assert(MIN_FRAMES_IN_FLIGHT <= MAX_FRAMES_IN_FLIGHT);
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
    }
};

/// Per-application atlas budgets: the glyph, SVG, and image atlases are square
/// textures of a fixed side, reserved once at initialization and never grown
/// (CLAUDE.md §2). When one is full it evicts its least recently used shelf;
/// items used in the current frame are never evicted, and a frame whose live
/// set does not fit fails fast with the atlas name.
///
/// GPU backends keep no CPU copy of atlas pixels. Rasterized pixels travel to
/// the texture through one bounded staging journal of `upload_bytes_frame_max`
/// bytes shared by the three atlases; work past it waits for the next frame.
/// The CPU renderer keeps its atlases in CPU memory, because they are its
/// textures. Values come from `docs/v0.4.0-memory-budget.md` §4.
pub const AtlasLimits = struct {
    /// Rasterized bytes all three atlases may stage for upload in one frame.
    /// GPU backends reserve this much staging per frame in flight.
    upload_bytes_frame_max: u32,
    /// Glyph atlas side in pixels (R8, 1 B per pixel).
    text_size: u32,
    /// SVG icon atlas side in pixels (RGBA, 4 B per pixel).
    svg_size: u32,
    /// Image atlas side in pixels (RGBA, 4 B per pixel).
    image_size: u32,
    /// Largest SVG icon side in device pixels; sizes the SVG raster buffer.
    svg_icon_size_max: u32,
    /// Most bytes of path data one SVG icon may carry. A longer path fails
    /// fast naming this field; it also sizes the SVG raster scratch.
    svg_path_bytes_max: u32,
    /// Most vertices one SVG icon may flatten to at its device size, which
    /// sizes the software rasterizer's scratch (Linux and Windows). An icon
    /// that needs more fails fast naming this field.
    svg_path_vertex_count_max: u32,

    /// Counter-class apps: counter's glyphs hold 144 of 512 text-atlas rows at
    /// 1x and 280 at 2x (measured with shelf packing), and no nano example draws
    /// icons or images. Textures: 0.25 + 0.25 + 0.25 MiB.
    /// A full nano atlas set uploads within 3 frames. SVG paths allow about
    /// twice Lucide's heaviest icon at each profile's largest icon side.
    pub const nano: AtlasLimits = .{
        .upload_bytes_frame_max = 256 * 1024,
        .text_size = 512,
        .svg_size = 256,
        .image_size = 256,
        .svg_icon_size_max = 64,
        .svg_path_bytes_max = 2 * 1024,
        .svg_path_vertex_count_max = 4 * 1024,
    };

    /// Forms and lists: todo holds 48 of 1024 text rows at 1x and 120 at 2x.
    /// Textures: 1 + 1 + 1 MiB.
    pub const small: AtlasLimits = .{
        .upload_bytes_frame_max = 1024 * 1024,
        .text_size = 1_024,
        .svg_size = 512,
        .image_size = 512,
        .svg_icon_size_max = 128,
        .svg_path_bytes_max = 4 * 1024,
        .svg_path_vertex_count_max = 8 * 1024,
    };

    /// The glyph atlas is 2048² for Retina display text: a frame of 70 distinct
    /// 52 pt glyphs at 2x needs more than 1024 shelf rows once glyphs are cached
    /// per subpixel variant. Showcase holds 132 glyph rows at 1x and 480 at 2x,
    /// 44 SVG rows, and 324 of 1024 image rows. Textures: 4 + 4 + 4 MiB. A full
    /// 1024² RGBA atlas uploads in 4 frames.
    pub const standard: AtlasLimits = .{
        .upload_bytes_frame_max = 1024 * 1024,
        .text_size = 2_048,
        .svg_size = 1_024,
        .image_size = 1_024,
        .svg_icon_size_max = 256,
        .svg_path_bytes_max = 8 * 1024,
        .svg_path_vertex_count_max = 16 * 1024,
    };

    /// lucide-demo's visible icons hold 520 of 2048 SVG rows at 2x, and the
    /// images example's logo copies hold 1032 of 2048 image rows at 1x and 2x.
    /// The image atlas was 4096² (64 MiB), which cost about 65 MB per window
    /// on macOS for space no example used. Textures: 16 + 16 + 16 MiB.
    pub const large: AtlasLimits = .{
        .upload_bytes_frame_max = 16 * 1024 * 1024,
        .text_size = 4_096,
        .svg_size = 2_048,
        .image_size = 2_048,
        .svg_icon_size_max = 256,
        .svg_path_bytes_max = 16 * 1024,
        .svg_path_vertex_count_max = 16 * 1024,
    };

    /// The framework ceilings themselves. Textures: 16 + 64 + 64 MiB.
    pub const ceiling: AtlasLimits = .{
        .upload_bytes_frame_max = MAX_ATLAS_UPLOAD_BYTES_PER_FRAME,
        .text_size = MAX_ATLAS_SIZE,
        .svg_size = MAX_ATLAS_SIZE,
        .image_size = MAX_ATLAS_SIZE,
        .svg_icon_size_max = MAX_SVG_ICON_SIZE,
        .svg_path_bytes_max = MAX_SVG_PATH_BYTES,
        .svg_path_vertex_count_max = MAX_SVG_PATH_VERTEX_COUNT,
    };

    /// First violated rule, or null. Every field must be in `1..=ceiling`;
    /// atlas sides are multiples of `MIN_ATLAS_SIZE`; the largest icon fits its
    /// atlas; and one frame can stage the largest glyph and the largest icon.
    pub fn check(self: *const AtlasLimits) ?Violation {
        inline for (@typeInfo(AtlasLimits).@"struct".field_names) |field_name| {
            const value: u32 = @field(self, field_name);
            const bound: u32 = @field(ceiling, field_name);
            if (value == 0) {
                return .{
                    .budget = .atlas,
                    .field = field_name,
                    .rule = .zero,
                    .value = 0,
                    .bound = 1,
                };
            }
            if (value > bound) {
                return .{
                    .budget = .atlas,
                    .field = field_name,
                    .rule = .above_ceiling,
                    .value = value,
                    .bound = bound,
                };
            }
        }
        inline for (.{ "text_size", "svg_size", "image_size" }) |field_name| {
            const value: u32 = @field(self, field_name);
            if (value % MIN_ATLAS_SIZE != 0) {
                return .{
                    .budget = .atlas,
                    .field = field_name,
                    .rule = .not_multiple,
                    .value = value,
                    .bound = MIN_ATLAS_SIZE,
                };
            }
        }
        return self.checkRelationships();
    }

    /// Runtime check for budgets that are not comptime-known.
    pub fn assertValid(self: *const AtlasLimits) void {
        if (self.check()) |violation| {
            std.debug.panic("invalid ResourceLimits.atlas.{s} = {d}: rule {t}, bound {d}", .{
                violation.field,
                violation.value,
                violation.rule,
                violation.bound,
            });
        }
    }

    /// Cross-field rules. Every atlas item carries a 1 px border on each side.
    fn checkRelationships(self: *const AtlasLimits) ?Violation {
        if (self.svg_size < self.svg_icon_size_max + 2) {
            return .{
                .budget = .atlas,
                .field = "svg_size",
                .rule = .below_relationship,
                .value = self.svg_size,
                .bound = self.svg_icon_size_max + 2,
            };
        }
        if (self.upload_bytes_frame_max < self.itemUploadBytesMax()) {
            return .{
                .budget = .atlas,
                .field = "upload_bytes_frame_max",
                .rule = .below_relationship,
                .value = self.upload_bytes_frame_max,
                .bound = self.itemUploadBytesMax(),
            };
        }
        return null;
    }

    /// Staged bytes of the largest glyph or icon, border included. Images have
    /// no budget-wide bound; an image larger than the staging journal fails fast.
    pub fn itemUploadBytesMax(self: *const AtlasLimits) u32 {
        assert(self.svg_icon_size_max <= MAX_SVG_ICON_SIZE);
        const glyph_side: u32 = MAX_GLYPH_SIZE + 2;
        const icon_side: u32 = self.svg_icon_size_max + 2;
        return @max(glyph_side * glyph_side, icon_side * icon_side * 4);
    }

    /// Bytes of the three atlas textures (GPU) or pixel stores (CPU renderer).
    pub fn textureBytes(self: *const AtlasLimits) u64 {
        assert(self.text_size <= MAX_ATLAS_SIZE);
        assert(self.image_size <= MAX_ATLAS_SIZE);
        var bytes: u64 = @as(u64, self.text_size) * self.text_size;
        bytes += @as(u64, self.svg_size) * self.svg_size * 4;
        bytes += @as(u64, self.image_size) * self.image_size * 4;
        return bytes;
    }

    comptime {
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
    }
};

// =============================================================================
// Core budgets (0.4.0 contract, "ResourceLimits")
// =============================================================================
//
// Per-window capacities of the 0.4.0 core. Every pool is reserved from these
// at initialization (contract rule 4); exhausting one panics with the pool's
// name, capacity, requested count, and frame. The `standard` row matches the
// contract's performance sketch; the other rungs scale it to their example
// class. `ceiling` holds the framework maxima `check` enforces.

/// Elements the layout engine stores per frame (`layout/engine.zig`).
pub const MAX_LAYOUT_ENGINE_ELEMENTS: u32 = 16_384;

/// Most handlers one element can register (click, click-outside, key).
pub const handler_count_element_max: u32 = 3;

/// Approved decision 1: component recursion is bounded, default 64, ceiling 128.
pub const MAX_COMPONENT_DEPTH: u32 = 128;

/// Build-phase capacities: the element tree one frame may describe.
pub const BuildLimits = struct {
    /// Elements (`box`, `text`, `paint`) per frame.
    element_count_frame_max: u32,
    /// Nested `cx.render` calls (approved decision 1).
    component_depth_max: u32,
    /// Keyed elements per frame, for duplicate-key detection.
    key_count_frame_max: u32,
    /// Bytes of text and accessibility strings copied per frame (rule 6).
    text_bytes_frame_max: u32,

    pub const nano: BuildLimits = .{
        .element_count_frame_max = 512,
        .component_depth_max = 64,
        .key_count_frame_max = 256,
        .text_bytes_frame_max = 16 * 1024,
    };
    pub const small: BuildLimits = .{
        .element_count_frame_max = 2_048,
        .component_depth_max = 64,
        .key_count_frame_max = 1_024,
        .text_bytes_frame_max = 64 * 1024,
    };
    pub const standard: BuildLimits = .{
        .element_count_frame_max = 4_096,
        .component_depth_max = 64,
        .key_count_frame_max = 4_096,
        .text_bytes_frame_max = 256 * 1024,
    };
    pub const large: BuildLimits = .{
        .element_count_frame_max = 16_384,
        .component_depth_max = 64,
        .key_count_frame_max = 16_384,
        .text_bytes_frame_max = 1024 * 1024,
    };
    pub const ceiling: BuildLimits = .{
        .element_count_frame_max = MAX_LAYOUT_ENGINE_ELEMENTS,
        .component_depth_max = MAX_COMPONENT_DEPTH,
        .key_count_frame_max = MAX_LAYOUT_ENGINE_ELEMENTS,
        .text_bytes_frame_max = 4 * 1024 * 1024,
    };
};

/// Emit-phase capacities: records one frame may hold, per record buffer.
pub const RecordLimits = struct {
    /// Paint records (quads, sprites, meshes, clips) across all fragments.
    paint_record_count_frame_max: u32,
    /// Hit records: interactive or keyed boxes.
    hit_record_count_frame_max: u32,
    /// Handlers bound by `cx.on` during build.
    handler_count_frame_max: u32,

    pub const nano: RecordLimits = .{
        .paint_record_count_frame_max = 4_096,
        .hit_record_count_frame_max = 512,
        .handler_count_frame_max = 512,
    };
    pub const small: RecordLimits = .{
        .paint_record_count_frame_max = 8_192,
        .hit_record_count_frame_max = 2_048,
        .handler_count_frame_max = 2_048,
    };
    pub const standard: RecordLimits = .{
        .paint_record_count_frame_max = 28_672,
        .hit_record_count_frame_max = 4_096,
        .handler_count_frame_max = 4_096,
    };
    pub const large: RecordLimits = .{
        .paint_record_count_frame_max = 65_536,
        .hit_record_count_frame_max = 16_384,
        .handler_count_frame_max = 16_384,
    };
    pub const ceiling: RecordLimits = .{
        .paint_record_count_frame_max = 262_144,
        .hit_record_count_frame_max = MAX_LAYOUT_ENGINE_ELEMENTS,
        .handler_count_frame_max = MAX_LAYOUT_ENGINE_ELEMENTS * handler_count_element_max,
    };
};

/// Retained-store slabs, one per size class (contract §3).
pub const RetainedLimits = struct {
    slot_count_64: u32,
    slot_count_256: u32,
    slot_count_1024: u32,
    slot_count_4096: u32,
    /// Untouched frames before a `.frame` entry is released.
    sweep_delay_frames: u32,

    pub const nano: RetainedLimits = .{
        .slot_count_64 = 128,
        .slot_count_256 = 64,
        .slot_count_1024 = 16,
        .slot_count_4096 = 4,
        .sweep_delay_frames = 8,
    };
    pub const small: RetainedLimits = .{
        .slot_count_64 = 512,
        .slot_count_256 = 256,
        .slot_count_1024 = 64,
        .slot_count_4096 = 16,
        .sweep_delay_frames = 8,
    };
    pub const standard: RetainedLimits = .{
        .slot_count_64 = 2_048,
        .slot_count_256 = 1_024,
        .slot_count_1024 = 256,
        .slot_count_4096 = 64,
        .sweep_delay_frames = 8,
    };
    pub const large: RetainedLimits = .{
        .slot_count_64 = 8_192,
        .slot_count_256 = 4_096,
        .slot_count_1024 = 1_024,
        .slot_count_4096 = 256,
        .sweep_delay_frames = 8,
    };
    pub const ceiling: RetainedLimits = .{
        .slot_count_64 = 65_536,
        .slot_count_256 = 16_384,
        .slot_count_1024 = 4_096,
        .slot_count_4096 = 1_024,
        .sweep_delay_frames = 600,
    };
};

/// Event queue, completion ring, and timer table (contract §5).
pub const EventLimits = struct {
    queue_count_max: u32,
    completion_count_max: u32,
    timer_count_max: u32,
    /// Bytes of event text (IME and typed text, dialog paths) in flight.
    text_bytes_max: u32,

    pub const nano: EventLimits = .{
        .queue_count_max = 64,
        .completion_count_max = 16,
        .timer_count_max = 8,
        .text_bytes_max = 4 * 1024,
    };
    pub const small: EventLimits = .{
        .queue_count_max = 128,
        .completion_count_max = 32,
        .timer_count_max = 16,
        .text_bytes_max = 8 * 1024,
    };
    pub const standard: EventLimits = .{
        .queue_count_max = 256,
        .completion_count_max = 64,
        .timer_count_max = 32,
        .text_bytes_max = 16 * 1024,
    };
    pub const large: EventLimits = .{
        .queue_count_max = 512,
        .completion_count_max = 128,
        .timer_count_max = 64,
        .text_bytes_max = 64 * 1024,
    };
    pub const ceiling: EventLimits = .{
        .queue_count_max = 4_096,
        .completion_count_max = 1_024,
        .timer_count_max = 256,
        .text_bytes_max = 1024 * 1024,
    };
};

/// One text-engine pool (contract §3, approved decision 6). A count of 0
/// reserves nothing; bytes and undo depth are then unused but still bounded.
pub const TextKindLimits = struct {
    count_max: u32,
    bytes_max: u32,
    undo_depth_max: u32,
};

/// The three text-engine pools: single-line inputs, multi-line areas, and code
/// editors. Milestone 1 implements inputs; `area` and `editor` reserve nothing
/// until phase 4 ports those engines, so every profile sets their count to 0.
pub const TextLimits = struct {
    input: TextKindLimits,
    area: TextKindLimits,
    editor: TextKindLimits,

    pub const nano: TextLimits = .{
        .input = .{ .count_max = 4, .bytes_max = 1024, .undo_depth_max = 32 },
        .area = .{ .count_max = 0, .bytes_max = 16 * 1024, .undo_depth_max = 32 },
        .editor = .{ .count_max = 0, .bytes_max = 64 * 1024, .undo_depth_max = 64 },
    };
    pub const small: TextLimits = .{
        .input = .{ .count_max = 16, .bytes_max = 4 * 1024, .undo_depth_max = 64 },
        .area = .{ .count_max = 0, .bytes_max = 64 * 1024, .undo_depth_max = 64 },
        .editor = .{ .count_max = 0, .bytes_max = 256 * 1024, .undo_depth_max = 128 },
    };
    pub const standard: TextLimits = .{
        .input = .{ .count_max = 64, .bytes_max = 8 * 1024, .undo_depth_max = 64 },
        .area = .{ .count_max = 0, .bytes_max = 128 * 1024, .undo_depth_max = 128 },
        .editor = .{ .count_max = 0, .bytes_max = 1024 * 1024, .undo_depth_max = 256 },
    };
    pub const large: TextLimits = .{
        .input = .{ .count_max = 128, .bytes_max = 8 * 1024, .undo_depth_max = 128 },
        .area = .{ .count_max = 0, .bytes_max = 128 * 1024, .undo_depth_max = 256 },
        .editor = .{ .count_max = 0, .bytes_max = 4 * 1024 * 1024, .undo_depth_max = 512 },
    };
    pub const ceiling: TextLimits = .{
        .input = .{ .count_max = 1_024, .bytes_max = 64 * 1024, .undo_depth_max = 1_024 },
        .area = .{ .count_max = 256, .bytes_max = 1024 * 1024, .undo_depth_max = 1_024 },
        .editor = .{ .count_max = 64, .bytes_max = 16 * 1024 * 1024, .undo_depth_max = 4_096 },
    };

    /// Counts may be 0; bytes and undo depth must be in `1..=ceiling`.
    pub fn check(self: *const TextLimits) ?Violation {
        inline for (.{ "input", "area", "editor" }) |kind| {
            const value: *const TextKindLimits = &@field(self, kind);
            const bound: *const TextKindLimits = &@field(ceiling, kind);
            inline for (@typeInfo(TextKindLimits).@"struct".field_names) |field_name| {
                const field_value: u32 = @field(value, field_name);
                const field_bound: u32 = @field(bound, field_name);
                const zero_allowed = comptime std.mem.eql(u8, field_name, "count_max");
                if (field_value == 0 and !zero_allowed) {
                    return .{
                        .budget = .text,
                        .field = kind ++ "." ++ field_name,
                        .rule = .zero,
                        .value = 0,
                        .bound = 1,
                    };
                }
                if (field_value > field_bound) {
                    return .{
                        .budget = .text,
                        .field = kind ++ "." ++ field_name,
                        .rule = .above_ceiling,
                        .value = field_value,
                        .bound = field_bound,
                    };
                }
            }
        }
        return null;
    }
};

/// Entity pools: every type in `Config.entities` gets one pool of this many.
pub const EntityLimits = struct {
    count_per_type_max: u32,

    pub const nano: EntityLimits = .{ .count_per_type_max = 16 };
    pub const small: EntityLimits = .{ .count_per_type_max = 64 };
    pub const standard: EntityLimits = .{ .count_per_type_max = 256 };
    pub const large: EntityLimits = .{ .count_per_type_max = 1_024 };
    pub const ceiling: EntityLimits = .{ .count_per_type_max = 4_096 };
};

/// Every `u32` field of a flat budget must be in `1..=ceiling`.
fn checkCeilings(comptime T: type, comptime budget: Violation.Budget, self: *const T) ?Violation {
    inline for (@typeInfo(T).@"struct".field_names) |field_name| {
        const value: u32 = @field(self, field_name);
        const bound: u32 = @field(T.ceiling, field_name);
        if (value == 0) {
            return .{
                .budget = budget,
                .field = field_name,
                .rule = .zero,
                .value = 0,
                .bound = 1,
            };
        }
        if (value > bound) {
            return .{
                .budget = budget,
                .field = field_name,
                .rule = .above_ceiling,
                .value = value,
                .bound = bound,
            };
        }
    }
    return null;
}

fn relationship(
    comptime budget: Violation.Budget,
    comptime field: []const u8,
    value: u32,
    bound: u32,
) Violation {
    return .{
        .budget = budget,
        .field = field,
        .rule = .above_relationship,
        .value = value,
        .bound = bound,
    };
}

comptime {
    for (ResourceLimits.profile_names) |name| {
        assert(@field(ResourceLimits, name).check() == null);
    }
    assert(BuildLimits.standard.component_depth_max == 64);
    assert(BuildLimits.ceiling.component_depth_max == 128);
}

/// A broken budget rule, precise enough to name in a compile error.
pub const Violation = struct {
    budget: Budget,
    field: []const u8,
    rule: Rule,
    value: u32,
    bound: u32,

    /// The `ResourceLimits` field holding the broken rule.
    pub const Budget = enum {
        scene,
        window,
        frame,
        atlas,
        build,
        records,
        retained,
        events,
        text,
        entities,
    };
    pub const Rule = enum {
        zero,
        above_ceiling,
        below_relationship,
        above_relationship,
        not_multiple,
    };

    /// Human-readable message. Comptime only: used by `ResourceLimits.validate`.
    pub fn describe(comptime self: Violation) []const u8 {
        return switch (self.rule) {
            .zero => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} must be at least 1, got 0",
                .{ self.budget, self.field },
            ),
            .above_ceiling => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} exceeds the framework ceiling {d}",
                .{ self.budget, self.field, self.value, self.bound },
            ),
            .below_relationship => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} is below the required minimum {d}",
                .{ self.budget, self.field, self.value, self.bound },
            ),
            .above_relationship => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} exceeds {d}, set by a related budget",
                .{ self.budget, self.field, self.value, self.bound },
            ),
            .not_multiple => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} is not a multiple of {d}",
                .{ self.budget, self.field, self.value, self.bound },
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

/// The font faces a text system loads during initialization (CLAUDE.md §2): one
/// face per entry in `variants`, so `variants.len` is the face count. Nothing is
/// loaded on first use. Text that requests a variant outside the set panics
/// with the variant's name, the loaded set, and this type's name.
///
/// Shaped like `SceneLimits` (named profiles, `check`, `assertValid`,
/// `validate`) so it moves into the planned `ResourceLimits.text` unchanged.
/// Every `ResourceLimits` profile name has a `FontLimits` profile of the same
/// name, so `gooey.App(..., .{ .limits = .nano })` selects both. An explicit
/// `.font_limits = ...` overrides the font half; the app forwards the result
/// through `FontConfig.limits` to every text system it creates.
///
/// Gooey-owned cost per face, allocated at init: FreeType 16,976 B (mostly a
/// 4,096-entry advance cache), web 1,460 B, DirectWrite 80 B, CoreText 56 B.
/// The platform library keeps its own state per open face; FreeType, HarfBuzz,
/// and Fontconfig used 24-38 KiB of heap per DejaVu face at init, measured
/// with `mallinfo2`.
/// Shaped-run, width, and glyph caches are shared by all faces, not per face.
pub const FontLimits = struct {
    /// Distinct variants; must include `.regular`, which supplies line metrics.
    variants: []const FontVariant,

    /// The weights Gooey's components and examples use (regular, medium,
    /// semibold, bold) plus italic and bold italic: six faces.
    pub const standard: FontLimits = .{
        .variants = &.{ .regular, .medium, .semibold, .bold, .italic, .bold_italic },
    };

    /// Regular only, for apps whose text never sets a weight or italic.
    pub const nano: FontLimits = .{ .variants = &.{.regular} };

    /// The four upright weights Gooey's components use. accessible-form, the
    /// widest `small` example, requests exactly these.
    pub const small: FontLimits = .{ .variants = &.{ .regular, .medium, .semibold, .bold } };

    /// The same six faces as `standard`: dense apps need more glyphs, not more faces.
    pub const large: FontLimits = standard;

    /// Every weight, upright and italic: the framework ceiling.
    pub const ceiling: FontLimits = .{ .variants = &all_variants };

    const all_variants: [FontVariant.count]FontVariant = blk: {
        var result: [FontVariant.count]FontVariant = undefined;
        for (&result, 0..) |*variant, index| variant.* = @fromBackingInt(@intCast(index));
        break :blk result;
    };

    pub const Rule = enum { empty, above_ceiling, duplicate, missing_regular };

    /// First violated rule, or null when the set is valid.
    pub fn check(self: *const FontLimits) ?Rule {
        if (self.variants.len == 0) return .empty;
        if (self.variants.len > FontVariant.count) return .above_ceiling;
        var seen: [FontVariant.count]bool = @splat(false);
        for (self.variants) |variant| {
            if (seen[@backingInt(variant)]) return .duplicate;
            seen[@backingInt(variant)] = true;
        }
        if (!seen[@backingInt(FontVariant.regular)]) return .missing_regular;
        assert(self.variants.len <= FontVariant.count);
        return null;
    }

    /// Runtime counterpart of `validate`. An invalid set is a programmer error.
    pub fn assertValid(self: *const FontLimits) void {
        if (self.check()) |rule| {
            std.debug.panic("invalid FontLimits.variants ({d} entries): rule {s}", .{
                self.variants.len,
                @tagName(rule),
            });
        }
    }

    /// Reject an invalid set at compile time, naming the broken rule.
    pub fn validate(comptime self: FontLimits) void {
        comptime {
            if (self.check()) |rule| {
                @compileError("invalid FontLimits.variants: rule " ++ @tagName(rule));
            }
        }
    }

    comptime {
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
    }
};

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
    // Goal: every shipped rung passes the same rules `validate` applies, every
    // budget has a profile of each name, and no rung offers less than the rung
    // below it for any capacity. Walking the rungs in pairs checks every field
    // of every budget against its neighbour, ending at the ceiling.
    const rungs = ResourceLimits.profile_names;
    inline for (rungs) |name| {
        try std.testing.expect(@field(ResourceLimits, name).check() == null);
        try std.testing.expect(@field(FontLimits, name).check() == null);
    }
    inline for (rungs[0 .. rungs.len - 1], rungs[1..]) |lower_name, upper_name| {
        const lower = @field(ResourceLimits, lower_name);
        const upper = @field(ResourceLimits, upper_name);
        inline for (.{ "scene", "window", "frame", "atlas" }) |budget| {
            const Budget = @TypeOf(@field(lower, budget));
            inline for (@typeInfo(Budget).@"struct".field_names) |field_name| {
                const lower_value = @field(@field(lower, budget), field_name);
                const upper_value = @field(@field(upper, budget), field_name);
                try std.testing.expect(lower_value <= upper_value);
            }
        }
        const lower_faces = @field(FontLimits, lower_name).variants.len;
        try std.testing.expect(lower_faces <= @field(FontLimits, upper_name).variants.len);
    }
    // Two frames in flight below `standard`, three from it up (decision 4).
    try std.testing.expectEqual(@as(u32, 2), ResourceLimits.small.frame.in_flight_count);
    try std.testing.expectEqual(@as(u32, 3), ResourceLimits.standard.frame.in_flight_count);
    try std.testing.expectEqual(@as(usize, 1), FontLimits.nano.variants.len);
    try std.testing.expectEqual(@as(usize, 4), FontLimits.small.variants.len);
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

    inline for (.{
        "path_vertex_count_frame_max",    "path_index_count_frame_max",
        "polyline_point_count_frame_max", "point_count_frame_max",
        "colored_point_count_frame_max",
    }) |field| {
        limits = ResourceLimits.standard;
        @field(limits.scene, field) = 0;
        try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
        @field(limits.scene, field) = @field(SceneLimits.ceiling, field);
        try std.testing.expect(limits.check() == null);
        @field(limits.scene, field) += 1;
        try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
    }

    // The frame budget reports under its own name at both ends of its range.
    limits = ResourceLimits.standard;
    limits.frame.in_flight_count = MIN_FRAMES_IN_FLIGHT - 1;
    try std.testing.expectEqual(Violation.Budget.frame, limits.check().?.budget);
    try std.testing.expectEqual(Violation.Rule.below_relationship, limits.check().?.rule);
    limits.frame.in_flight_count = MIN_FRAMES_IN_FLIGHT;
    try std.testing.expect(limits.check() == null);
    limits.frame.in_flight_count = MAX_FRAMES_IN_FLIGHT;
    try std.testing.expect(limits.check() == null);
    limits.frame.in_flight_count = MAX_FRAMES_IN_FLIGHT + 1;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
    try std.testing.expectEqualStrings("in_flight_count", limits.check().?.field);

    // The window budget reports under its own name, at both ends of each range.
    inline for (.{ "framebuffer_width_max", "framebuffer_height_max" }) |field| {
        limits = ResourceLimits.standard;
        @field(limits.window, field) = 0;
        try std.testing.expectEqual(Violation.Budget.window, limits.check().?.budget);
        try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
        @field(limits.window, field) = @field(WindowLimits.ceiling, field);
        try std.testing.expect(limits.check() == null);
        @field(limits.window, field) += 1;
        try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
    }

    // The atlas upload budget must stage the largest glyph or icon in one frame
    // and stay under its ceiling; both ends are checked one past the boundary.
    // At `standard` the largest item is a 256² RGBA icon plus its border.
    limits = ResourceLimits.standard;
    const item_bytes_max = limits.atlas.itemUploadBytesMax();
    try std.testing.expectEqual(@as(u32, 258 * 258 * 4), item_bytes_max);
    limits.atlas.upload_bytes_frame_max = item_bytes_max - 1;
    try std.testing.expectEqual(Violation.Budget.atlas, limits.check().?.budget);
    try std.testing.expectEqual(Violation.Rule.below_relationship, limits.check().?.rule);
    limits.atlas.upload_bytes_frame_max = item_bytes_max;
    try std.testing.expect(limits.check() == null);
    limits.atlas.upload_bytes_frame_max = MAX_ATLAS_UPLOAD_BYTES_PER_FRAME;
    try std.testing.expect(limits.check() == null);
    limits.atlas.upload_bytes_frame_max += 1;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
}

test "derived budget quantities" {
    // Goal: pin the relationships other subsystems size from, and keep the
    // per-scene sizes documented on each rung honest.
    const scene = SceneLimits.standard;
    try std.testing.expectEqual(@as(u32, 8_192), scene.sortKeyCountMax());
    try std.testing.expectEqual(@as(u32, 4_608), scene.unifiedPrimitiveCountMax());
    try std.testing.expectEqual(@as(u32, 272), SceneLimits.nano.unifiedPrimitiveCountMax());
    try std.testing.expectEqual(MAX_SORT_KEYS, SceneLimits.ceiling.sortKeyCountMax());
    const rungs = ResourceLimits.profile_names;
    inline for (rungs[0 .. rungs.len - 1], rungs[1..]) |lower_name, upper_name| {
        const lower_bytes = @field(SceneLimits, lower_name).sceneBytes();
        try std.testing.expect(lower_bytes < @field(SceneLimits, upper_name).sceneBytes());
    }
    try std.testing.expect(SceneLimits.nano.sceneBytes() < 128 * 1024);
    try std.testing.expect(SceneLimits.small.sceneBytes() < 576 * 1024);
    try std.testing.expect(scene.sceneBytes() < 1_843 * 1024);
    try std.testing.expect(SceneLimits.large.sceneBytes() < 12 * 1024 * 1024);
}
