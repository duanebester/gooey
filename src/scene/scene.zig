//! Scene graph: collects all draw primitives for a frame, then handles
//! z-ordering and clipping (à la GPUI's scene.rs).
//!
//! The GPU geometry types (Point, Size, Bounds, Corners, Edges) are `extern
//! struct`s defined in geometry.zig as Gpu* and re-exported here; their memory
//! layout matches Metal shader expectations for direct buffer upload. Prefer
//! importing them from geometry.zig in new code.
//!
//! Primitives: Hsla (color), Quad, Shadow, GlyphInstance, plus the instance
//! types (Svg, Image, Path, Polyline, point clouds) pulled in below.

const std = @import("std");
const assert = std.debug.assert;
const geometry = @import("../core/geometry.zig");
const limits = @import("../core/limits.zig");
const svg_instance_mod = @import("svg_instance.zig");
pub const SvgInstance = svg_instance_mod.SvgInstance;
const image_instance_mod = @import("image_instance.zig");
pub const ImageInstance = image_instance_mod.ImageInstance;
const path_instance_mod = @import("path_instance.zig");
pub const PathInstance = path_instance_mod.PathInstance;
const polyline_mod = @import("polyline.zig");
pub const Polyline = polyline_mod.Polyline;
const point_cloud_mod = @import("point_cloud.zig");
pub const PointCloud = point_cloud_mod.PointCloud;
const colored_point_cloud_mod = @import("colored_point_cloud.zig");
pub const ColoredPointCloud = colored_point_cloud_mod.ColoredPointCloud;
const mesh_pool_mod = @import("mesh_pool.zig");
pub const MeshPool = mesh_pool_mod.MeshPool;
pub const MeshRef = mesh_pool_mod.MeshRef;
const path_mesh_mod = @import("path_mesh.zig");
pub const PathMesh = path_mesh_mod.PathMesh;
pub const PathVertex = path_mesh_mod.PathVertex;
const gradient_uniforms_mod = @import("gradient_uniforms.zig");
pub const GradientUniforms = gradient_uniforms_mod.GradientUniforms;
const gradient_mod = @import("gradient.zig");
pub const LinearGradient = gradient_mod.LinearGradient;
pub const RadialGradient = gradient_mod.RadialGradient;

// ============================================================================
// Hard Limits (imported from limits.zig - single source of truth)
// ============================================================================

pub const MAX_QUADS_PER_FRAME = limits.MAX_QUADS_PER_FRAME;
pub const MAX_GLYPHS_PER_FRAME = limits.MAX_GLYPHS_PER_FRAME;
pub const MAX_SHADOWS_PER_FRAME = limits.MAX_SHADOWS_PER_FRAME;
pub const MAX_SVGS_PER_FRAME = limits.MAX_SVGS_PER_FRAME;
pub const MAX_IMAGES_PER_FRAME = limits.MAX_IMAGES_PER_FRAME;
pub const MAX_PATHS_PER_FRAME = limits.MAX_PATHS_PER_FRAME;
pub const MAX_POLYLINES_PER_FRAME = limits.MAX_POLYLINES_PER_FRAME;
pub const MAX_POINT_CLOUDS_PER_FRAME = limits.MAX_POINT_CLOUDS_PER_FRAME;
pub const MAX_COLORED_POINT_CLOUDS_PER_FRAME = limits.MAX_COLORED_POINT_CLOUDS_PER_FRAME;
pub const MAX_CLIP_STACK_DEPTH = limits.MAX_CLIP_STACK_DEPTH;

pub const DrawOrder = u32;

/// Ceiling of the draw-order sort scratch (one u64 key per primitive). A
/// scene reserves `SceneLimits.sortKeyCountMax()` keys, the largest sortable
/// pool in its own budget, so the keyed sort never allocates (§2).
pub const MAX_SORT_KEYS = limits.MAX_SORT_KEYS;

/// Per-frame scene capacities selected by the application budget.
pub const SceneLimits = limits.SceneLimits;

// ============================================================================
// GPU Geometry Types (re-exported from geometry.zig)
// ============================================================================

// All extern structs, GPU-buffer-compatible (see geometry.zig).
pub const Point = geometry.GpuPoint;
pub const Size = geometry.GpuSize;
pub const Bounds = geometry.GpuBounds;
pub const Corners = geometry.GpuCorners;
pub const Edges = geometry.GpuEdges;

// ============================================================================
// HSLA Color (GPU-optimized)
// ============================================================================

/// HSLA color format - matches Metal shader expectations
pub const Hsla = extern struct {
    h: f32, // Hue [0, 1]
    s: f32, // Saturation [0, 1]
    l: f32, // Lightness [0, 1]
    a: f32, // Alpha [0, 1]

    pub fn init(h: f32, s: f32, l: f32, a: f32) Hsla {
        return .{ .h = h, .s = s, .l = l, .a = a };
    }

    /// Convert from RGBA to HSLA
    pub fn fromRgba(r: f32, g: f32, b: f32, a: f32) Hsla {
        const max_c = @max(r, @max(g, b));
        const min_c = @min(r, @min(g, b));
        const l = (max_c + min_c) / 2.0;

        if (max_c == min_c) {
            return .{ .h = 0, .s = 0, .l = l, .a = a };
        }

        const d = max_c - min_c;
        const s = if (l > 0.5) d / (2.0 - max_c - min_c) else d / (max_c + min_c);

        var h: f32 = 0;
        if (max_c == r) {
            h = (g - b) / d + (if (g < b) @as(f32, 6.0) else @as(f32, 0.0));
        } else if (max_c == g) {
            h = (b - r) / d + 2.0;
        } else {
            h = (r - g) / d + 4.0;
        }
        h /= 6.0;

        return .{ .h = h, .s = s, .l = l, .a = a };
    }

    /// Convert from geometry.Color to Hsla
    pub fn fromColor(c: geometry.Color) Hsla {
        return fromRgba(c.r, c.g, c.b, c.a);
    }

    /// Convert from HSLA to geometry.Color (RGB)
    pub fn toColor(self: Hsla) geometry.Color {
        if (self.s == 0) {
            // Achromatic (gray)
            return geometry.Color.rgba(self.l, self.l, self.l, self.a);
        }

        const q = if (self.l < 0.5) self.l * (1 + self.s) else self.l + self.s - self.l * self.s;
        const p = 2 * self.l - q;

        return geometry.Color.rgba(
            hueToRgb(p, q, self.h + 1.0 / 3.0),
            hueToRgb(p, q, self.h),
            hueToRgb(p, q, self.h - 1.0 / 3.0),
            self.a,
        );
    }

    fn hueToRgb(p: f32, q: f32, t_in: f32) f32 {
        var t = t_in;
        if (t < 0) t += 1;
        if (t > 1) t -= 1;
        if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
        if (t < 1.0 / 2.0) return q;
        if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
        return p;
    }

    // Common colors
    pub const transparent = Hsla{ .h = 0, .s = 0, .l = 0, .a = 0 };
    pub const white = Hsla{ .h = 0, .s = 0, .l = 1, .a = 1 };
    pub const black = Hsla{ .h = 0, .s = 0, .l = 0, .a = 1 };
    pub const red = Hsla{ .h = 0, .s = 1, .l = 0.5, .a = 1 };
    pub const green = Hsla{ .h = 0.333, .s = 1, .l = 0.5, .a = 1 };
    pub const blue = Hsla{ .h = 0.666, .s = 1, .l = 0.5, .a = 1 };
};

// ============================================================================
// Content Mask (for clipping)
// ============================================================================

/// Content mask for clipping (used for clip stack)
pub const ContentMask = struct {
    /// The clip bounds in screen coordinates
    bounds: ClipBounds,

    pub const ClipBounds = struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,

        /// Intersect two clip bounds, returning the overlapping region
        pub fn intersect(a: ClipBounds, b: ClipBounds) ClipBounds {
            const x = @max(a.x, b.x);
            const y = @max(a.y, b.y);
            const right = @min(a.x + a.width, b.x + b.width);
            const bottom = @min(a.y + a.height, b.y + b.height);
            return .{
                .x = x,
                .y = y,
                .width = @max(0, right - x),
                .height = @max(0, bottom - y),
            };
        }
    };

    /// Default mask that clips nothing (effectively infinite)
    pub const none = ContentMask{
        .bounds = .{ .x = 0, .y = 0, .width = 99999, .height = 99999 },
    };
};

/// Quad - the fundamental UI rectangle primitive
/// Layout matches Metal shader exactly (with float4 alignment padding)
pub const Quad = extern struct {
    order: DrawOrder = 0,
    _pad0: u32 = 0,
    bounds_origin_x: f32 = 0,
    bounds_origin_y: f32 = 0,
    bounds_size_width: f32 = 0,
    bounds_size_height: f32 = 0,
    clip_origin_x: f32 = -1e9,
    clip_origin_y: f32 = -1e9,
    clip_size_width: f32 = 2e9,
    clip_size_height: f32 = 2e9,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
    background: Hsla = Hsla.transparent,
    border_color: Hsla = Hsla.transparent,
    corner_radii: Corners = Corners.zero,
    border_widths: Edges = Edges.zero,

    pub fn filled(x: f32, y: f32, width: f32, height: f32, color: Hsla) Quad {
        std.debug.assert(width >= 0);
        std.debug.assert(height >= 0);
        return .{
            .bounds_origin_x = x,
            .bounds_origin_y = y,
            .bounds_size_width = width,
            .bounds_size_height = height,
            .background = color,
        };
    }

    pub fn rounded(x: f32, y: f32, width: f32, height: f32, color: Hsla, radius: f32) Quad {
        std.debug.assert(width >= 0);
        std.debug.assert(height >= 0);
        std.debug.assert(radius >= 0);
        return .{
            .bounds_origin_x = x,
            .bounds_origin_y = y,
            .bounds_size_width = width,
            .bounds_size_height = height,
            .background = color,
            .corner_radii = Corners.all(radius),
        };
    }

    pub fn withBorder(self: Quad, color: Hsla, width: f32) Quad {
        std.debug.assert(width >= 0);
        var q = self;
        q.border_color = color;
        q.border_widths = Edges.all(width);
        return q;
    }

    /// Create a quad with explicit clip bounds
    pub fn withClipBounds(self: Quad, clip: ContentMask.ClipBounds) Quad {
        var q = self;
        q.clip_origin_x = clip.x;
        q.clip_origin_y = clip.y;
        q.clip_size_width = clip.width;
        q.clip_size_height = clip.height;
        return q;
    }
};

comptime {
    // Quad must be 112 bytes for proper GPU buffer alignment
    if (@sizeOf(Quad) != 112) {
        @compileError(std.fmt.comptimePrint(
            "Quad must be 112 bytes, got {}",
            .{@sizeOf(Quad)},
        ));
    }
    // Verify background is at 16-byte aligned offset for Metal float4
    if (@offsetOf(Quad, "background") != 48) {
        @compileError(std.fmt.comptimePrint(
            "Quad.background must be at offset 48 for Metal float4 alignment, got {}",
            .{@offsetOf(Quad, "background")},
        ));
    }
}

// ============================================================================
// Shadow Primitive
// ============================================================================

/// Shadow - drop shadow behind UI elements
/// Renders as an expanded, blurred rounded rectangle using SDF.
///
/// Memory layout must match Metal shader exactly.
/// float4 types require 16-byte alignment in Metal!
pub const Shadow = extern struct {
    // Offset 0
    order: DrawOrder = 0,
    _pad0: u32 = 0,

    // Offset 8
    content_origin_x: f32 = 0,
    content_origin_y: f32 = 0,

    // Offset 16
    content_size_width: f32 = 0,
    content_size_height: f32 = 0,

    // Offset 24 - need padding to reach 32 for float4 alignment
    blur_radius: f32 = 10.0,
    offset_x: f32 = 0,

    // Offset 32 (16-byte aligned for float4)
    corner_radii: Corners = Corners.zero,

    // Offset 48 (16-byte aligned for float4)
    color: Hsla = Hsla.init(0, 0, 0, 0.25),

    // Offset 64
    offset_y: f32 = 4.0,
    _pad1: f32 = 0,
    _pad2: f32 = 0,
    _pad3: f32 = 0,

    // Total: 80 bytes

    pub fn drop(x: f32, y: f32, width: f32, height: f32, blur: f32) Shadow {
        std.debug.assert(width >= 0);
        std.debug.assert(height >= 0);
        std.debug.assert(blur >= 0);
        return .{
            .content_origin_x = x,
            .content_origin_y = y,
            .content_size_width = width,
            .content_size_height = height,
            .blur_radius = blur,
            .color = Hsla.init(0, 0, 0, 0.25),
            .offset_y = blur * 0.4,
        };
    }

    pub fn forQuad(quad: Quad, blur: f32) Shadow {
        std.debug.assert(blur >= 0);
        return .{
            .content_origin_x = quad.bounds_origin_x,
            .content_origin_y = quad.bounds_origin_y,
            .content_size_width = quad.bounds_size_width,
            .content_size_height = quad.bounds_size_height,
            .corner_radii = quad.corner_radii,
            .blur_radius = blur,
            .color = Hsla.init(0, 0, 0, 0.25),
            .offset_y = blur * 0.4,
        };
    }

    pub fn withColor(self: Shadow, c: Hsla) Shadow {
        var s = self;
        s.color = c;
        return s;
    }

    pub fn withOffset(self: Shadow, x: f32, y: f32) Shadow {
        var s = self;
        s.offset_x = x;
        s.offset_y = y;
        return s;
    }

    pub fn withCornerRadius(self: Shadow, radius: f32) Shadow {
        std.debug.assert(radius >= 0);
        var s = self;
        s.corner_radii = Corners.all(radius);
        return s;
    }
};

comptime {
    // Shadow must be 80 bytes for proper GPU buffer alignment
    if (@sizeOf(Shadow) != 80) {
        @compileError(std.fmt.comptimePrint(
            "Shadow must be 80 bytes, got {}",
            .{@sizeOf(Shadow)},
        ));
    }
    // Verify corner_radii is at 16-byte aligned offset for Metal float4
    if (@offsetOf(Shadow, "corner_radii") != 32) {
        @compileError(std.fmt.comptimePrint(
            "Shadow.corner_radii must be at offset 32 for Metal float4 alignment, got {}",
            .{@offsetOf(Shadow, "corner_radii")},
        ));
    }
    // Verify color is at 16-byte aligned offset for Metal float4
    if (@offsetOf(Shadow, "color") != 48) {
        @compileError(std.fmt.comptimePrint(
            "Shadow.color must be at offset 48 for Metal float4 alignment, got {}",
            .{@offsetOf(Shadow, "color")},
        ));
    }
}

// ============================================================================
// Text/Glyph Primitive
// ============================================================================

/// A single glyph instance for GPU rendering
/// Layout matches Metal shader (must be 16-byte aligned)
pub const GlyphInstance = extern struct {
    // Draw order for z-index interleaving
    order: DrawOrder = 0,
    _pad0: u32 = 0,
    // Screen position (top-left of glyph quad)
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    // Glyph size in pixels
    size_x: f32 = 0,
    size_y: f32 = 0,
    // Atlas UV coordinates
    uv_left: f32 = 0,
    uv_top: f32 = 0,
    uv_right: f32 = 0,
    uv_bottom: f32 = 0,
    // Padding to align color (float4) to 16-byte boundary
    // Without this, color is at offset 40; Metal requires float4 at 16-byte aligned offset (48)
    _pad1: u32 = 0,
    _pad2: u32 = 0,
    // Color (HSLA) - must be at 16-byte aligned offset for Metal float4
    color: Hsla = Hsla.black,
    // Clip bounds (content mask) - defaults to no clipping
    clip_x: f32 = 0,
    clip_y: f32 = 0,
    clip_width: f32 = 99999,
    clip_height: f32 = 99999,

    pub fn init(
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        uv_left: f32,
        uv_top: f32,
        uv_right: f32,
        uv_bottom: f32,
        color: Hsla,
    ) GlyphInstance {
        std.debug.assert(width >= 0);
        std.debug.assert(height >= 0);
        // UV coordinates must be in the normalized [0, 1] atlas range.
        std.debug.assert(uv_left >= 0 and uv_left <= 1);
        std.debug.assert(uv_top >= 0 and uv_top <= 1);
        std.debug.assert(uv_right >= 0 and uv_right <= 1);
        std.debug.assert(uv_bottom >= 0 and uv_bottom <= 1);
        return .{
            .pos_x = x,
            .pos_y = y,
            .size_x = width,
            .size_y = height,
            .uv_left = uv_left,
            .uv_top = uv_top,
            .uv_right = uv_right,
            .uv_bottom = uv_bottom,
            .color = color,
        };
    }

    /// Create a glyph with explicit clip bounds
    pub fn withClipBounds(self: GlyphInstance, clip: ContentMask.ClipBounds) GlyphInstance {
        var g = self;
        g.clip_x = clip.x;
        g.clip_y = clip.y;
        g.clip_width = clip.width;
        g.clip_height = clip.height;
        return g;
    }
};

comptime {
    if (@sizeOf(GlyphInstance) != 80) {
        @compileError(std.fmt.comptimePrint(
            "GlyphInstance must be 80 bytes, got {}",
            .{@sizeOf(GlyphInstance)},
        ));
    }
    // Verify color is at 16-byte aligned offset for Metal float4
    if (@offsetOf(GlyphInstance, "color") != 48) {
        @compileError(std.fmt.comptimePrint(
            "GlyphInstance.color must be at offset 48 for Metal float4 alignment, got {}",
            .{@offsetOf(GlyphInstance, "color")},
        ));
    }
}

// ============================================================================
// Draw-order sort (indirect key sort)
// ============================================================================
//
// `finish()` orders each per-type array by its `.order` field. Rather than hand
// `std.sort.pdq` the payload arrays directly — which makes every swap move a fat
// struct (a `Quad` is 128 B, a `GradientUniforms` 352 B) — we sort a compact
// array of `(order, index)` keys (8 B each, cache-resident) and then permute the
// payload into place once. This is Christer Ericson's "sort keys, not payloads"
// (2008): the comparison sort touches only the small keys, and each payload
// struct is moved at most once during the gather.

/// Sentinel written into a key slot once its payload has been placed, so the
/// outer permutation loop can skip cycles it has already walked. A real key is
/// `(order << 32) | index`; reaching all-ones would require `index == 0xFFFF_FFFF`,
/// which the per-frame limits (≤ 65536) make impossible — so there is no collision.
const PERM_DONE: u64 = std.math.maxInt(u64);

/// Pack a draw order and array index into a single sortable u64. The order
/// occupies the high 32 bits (primary key) and the index the low 32 bits, so an
/// ascending u64 sort breaks ties by insertion order — a stable, deterministic
/// result, unlike the old unstable payload pdq.
inline fn makeOrderKey(order: DrawOrder, index: u32) u64 {
    return (@as(u64, order) << 32) | @as(u64, index);
}

fn ascendingU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

/// Reorder `items` in place to `items[j] = old_items[perm[j]]`, where `perm[j]`
/// is the low 32 bits of `keys[j]` (the original index that belongs in sorted
/// slot `j`). Walks each permutation cycle once, holding the displaced element
/// in `tmp` and reading one slot ahead before overwriting, so every payload is
/// written exactly once. `keys` is consumed (slots are marked `PERM_DONE`).
fn applyPermutation(comptime T: type, items: []T, keys: []u64) void {
    std.debug.assert(items.len == keys.len);
    const count: u32 = @intCast(items.len);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (keys[i] == PERM_DONE) continue;
        const first_source: u32 = @truncate(keys[i]);
        if (first_source == i) {
            keys[i] = PERM_DONE; // already in place; close the trivial cycle
            continue;
        }

        const displaced = items[i]; // belongs at the cycle's closing slot
        var slot = i;
        while (true) {
            const source: u32 = @truncate(keys[slot]);
            keys[slot] = PERM_DONE;
            if (source == i) {
                items[slot] = displaced;
                break;
            }
            items[slot] = items[source];
            slot = source;
        }
    }
}

/// Parallel-array variant of `applyPermutation`: gathers `instances` and
/// `gradients` with the same permutation so the two stay index-aligned. This is
/// what lets the paths arrays be sorted together without the old O(n²) selection
/// sort that hand-swapped both arrays per comparison.
fn applyPermutationPaths(
    instances: []PathInstance,
    gradients: []GradientUniforms,
    keys: []u64,
) void {
    std.debug.assert(instances.len == gradients.len);
    std.debug.assert(instances.len == keys.len);
    const count: u32 = @intCast(instances.len);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (keys[i] == PERM_DONE) continue;
        const first_source: u32 = @truncate(keys[i]);
        if (first_source == i) {
            keys[i] = PERM_DONE;
            continue;
        }

        const displaced_instance = instances[i];
        const displaced_gradient = gradients[i];
        var slot = i;
        while (true) {
            const source: u32 = @truncate(keys[slot]);
            keys[slot] = PERM_DONE;
            if (source == i) {
                instances[slot] = displaced_instance;
                gradients[slot] = displaced_gradient;
                break;
            }
            instances[slot] = instances[source];
            gradients[slot] = gradients[source];
            slot = source;
        }
    }
}

/// Sort the parallel `path_instances` / `path_gradients` arrays together by draw
/// order. Paths are bounded by `MAX_PATHS_PER_FRAME` (4096), so the key scratch
/// fits comfortably on the stack (32 KB) — no heap scratch, no allocation, and
/// no dependence on the shared `sort_keys` buffer. Retires the previous O(n²)
/// selection sort entirely.
fn sortPathsByOrder(instances: []PathInstance, gradients: []GradientUniforms) void {
    std.debug.assert(instances.len == gradients.len);
    if (instances.len < 2) return; // 0 or 1 element is already ordered
    std.debug.assert(instances.len <= MAX_PATHS_PER_FRAME);

    const count: u32 = @intCast(instances.len);
    var keys: [MAX_PATHS_PER_FRAME]u64 = undefined;
    var i: u32 = 0;
    while (i < count) : (i += 1) keys[i] = makeOrderKey(instances[i].order, i);

    std.sort.pdq(u64, keys[0..count], {}, ascendingU64);
    applyPermutationPaths(instances, gradients, keys[0..count]);
}

// ============================================================================
// Scene - collects primitives for rendering
// ============================================================================

pub const Scene = struct {
    allocator: std.mem.Allocator,
    // Using ArrayListUnmanaged for static memory allocation policy:
    // Pre-allocate at init, no dynamic growth during rendering
    shadows: std.ArrayListUnmanaged(Shadow),
    quads: std.ArrayListUnmanaged(Quad),
    glyphs: std.ArrayListUnmanaged(GlyphInstance),
    svg_instances: std.ArrayListUnmanaged(SvgInstance),
    images: std.ArrayListUnmanaged(ImageInstance),
    path_instances: std.ArrayListUnmanaged(PathInstance),
    /// Parallel array of gradient data for path instances (same index as path_instances)
    /// If path_instances[i].hasGradient(), use path_gradients[i] for stop data
    path_gradients: std.ArrayListUnmanaged(GradientUniforms),
    /// Polylines for efficient chart/data visualization rendering
    polylines: std.ArrayListUnmanaged(Polyline),
    /// Point clouds for efficient scatter plot/marker rendering
    point_clouds: std.ArrayListUnmanaged(PointCloud),
    /// Colored point clouds for efficient rendering with per-point colors
    colored_point_clouds: std.ArrayListUnmanaged(ColoredPointCloud),
    mesh_pool: MeshPool,
    next_order: DrawOrder,
    // Clip mask stack for nested clipping regions
    clip_stack: std.ArrayListUnmanaged(ContentMask.ClipBounds),
    // Scratch buffer of (order, index) keys reused by `finish()` to sort each
    // per-type array indirectly (see the "Draw-order sort" section above).
    // Reserved by `initCapacity` at `limits.sortKeyCountMax()` keys.
    sort_keys: std.ArrayListUnmanaged(u64),
    /// This scene's budget. Inserts check against it, never the global ceilings;
    /// every list above was reserved at exactly this capacity.
    limits: SceneLimits,
    /// Frames completed by `finish`; names the frame in overflow reports.
    frame_count_finished: u64,
    // Per-array dirty flags: track which arrays had out-of-order inserts (requiring sort)
    needs_sort_shadows: bool,
    needs_sort_quads: bool,
    needs_sort_glyphs: bool,
    needs_sort_svgs: bool,
    needs_sort_images: bool,
    needs_sort_paths: bool,
    needs_sort_polylines: bool,
    needs_sort_point_clouds: bool,
    needs_sort_colored_point_clouds: bool,

    // Viewport culling
    viewport_width: f32,
    viewport_height: f32,
    culling_enabled: bool,

    // Stats tracking (optional)
    stats: ?*@import("../debug/render_stats.zig").RenderStats,

    const Self = @This();

    /// Zero-capacity scene. Allocates nothing; any insert fails fast. For
    /// callers that only present an empty scene (a clear) and never build one.
    pub fn initEmpty(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .shadows = .empty,
            .quads = .empty,
            .glyphs = .empty,
            .svg_instances = .empty,
            .images = .empty,
            .path_instances = .empty,
            .path_gradients = .empty,
            .polylines = .empty,
            .point_clouds = .empty,
            .colored_point_clouds = .empty,
            .mesh_pool = MeshPool.init(allocator),
            .next_order = 0,
            .clip_stack = .empty,
            .sort_keys = .empty,
            .limits = std.mem.zeroes(SceneLimits),
            .frame_count_finished = 0,
            .needs_sort_shadows = false,
            .needs_sort_quads = false,
            .needs_sort_glyphs = false,
            .needs_sort_svgs = false,
            .needs_sort_images = false,
            .needs_sort_paths = false,
            .needs_sort_polylines = false,
            .needs_sort_point_clouds = false,
            .needs_sort_colored_point_clouds = false,
            // Viewport culling - disabled by default (0 = no culling)
            .viewport_width = 0,
            .viewport_height = 0,
            .culling_enabled = false,
            .stats = null,
        };
    }

    /// Initialize a scene that reserves exactly `scene_limits` for every pool.
    /// This is the only constructor for a scene that is built into: after it
    /// returns, inserts never allocate, and a full pool fails fast (§2).
    pub fn initCapacity(allocator: std.mem.Allocator, scene_limits: *const SceneLimits) !Self {
        assert(scene_limits.check() == null);

        var self = initEmpty(allocator);
        errdefer self.deinit();
        self.limits = scene_limits.*;

        const budget = &self.limits;
        try self.shadows.ensureTotalCapacityPrecise(allocator, budget.shadow_count_frame_max);
        try self.quads.ensureTotalCapacityPrecise(allocator, budget.quad_count_frame_max);
        try self.glyphs.ensureTotalCapacityPrecise(allocator, budget.glyph_count_frame_max);
        try self.svg_instances.ensureTotalCapacityPrecise(allocator, budget.svg_count_frame_max);
        try self.images.ensureTotalCapacityPrecise(allocator, budget.image_count_frame_max);
        try self.path_instances.ensureTotalCapacityPrecise(allocator, budget.path_count_frame_max);
        try self.path_gradients.ensureTotalCapacityPrecise(allocator, budget.path_count_frame_max);
        try self.polylines.ensureTotalCapacityPrecise(allocator, budget.polyline_count_frame_max);
        try self.point_clouds.ensureTotalCapacityPrecise(
            allocator,
            budget.point_cloud_count_frame_max,
        );
        try self.colored_point_clouds.ensureTotalCapacityPrecise(
            allocator,
            budget.colored_point_cloud_count_frame_max,
        );
        try self.clip_stack.ensureTotalCapacityPrecise(allocator, budget.clip_depth_max);
        try self.sort_keys.ensureTotalCapacityPrecise(allocator, budget.sortKeyCountMax());

        assert(self.quads.capacity == budget.quad_count_frame_max);
        assert(self.sort_keys.capacity == budget.sortKeyCountMax());
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.shadows.deinit(self.allocator);
        self.quads.deinit(self.allocator);
        self.glyphs.deinit(self.allocator);
        self.svg_instances.deinit(self.allocator);
        self.images.deinit(self.allocator);
        self.path_instances.deinit(self.allocator);
        self.path_gradients.deinit(self.allocator);
        self.polylines.deinit(self.allocator);
        self.point_clouds.deinit(self.allocator);
        self.colored_point_clouds.deinit(self.allocator);
        self.clip_stack.deinit(self.allocator);
        self.sort_keys.deinit(self.allocator);
        self.mesh_pool.deinit();
    }

    /// Reserve the quad and matching sort-key storage used by ordered canvas
    /// drawing. Call during initialization, before the first frame can run.
    pub fn reserve_canvas_quads(self: *Self, capacity: u32) !void {
        std.debug.assert(capacity > 0);
        if (capacity > MAX_QUADS_PER_FRAME) return error.OutOfMemory;
        try self.quads.ensureTotalCapacity(self.allocator, capacity);
        try self.sort_keys.ensureTotalCapacity(self.allocator, capacity);
        std.debug.assert(self.quads.capacity >= capacity);
        std.debug.assert(self.sort_keys.capacity >= capacity);
    }

    pub fn clear(self: *Self) void {
        self.shadows.clearRetainingCapacity();
        self.quads.clearRetainingCapacity();
        self.glyphs.clearRetainingCapacity();
        self.svg_instances.clearRetainingCapacity();
        self.images.clearRetainingCapacity();
        self.path_instances.clearRetainingCapacity();
        self.path_gradients.clearRetainingCapacity();
        self.polylines.clearRetainingCapacity();
        self.point_clouds.clearRetainingCapacity();
        self.colored_point_clouds.clearRetainingCapacity();
        self.mesh_pool.resetFrame();
        self.clip_stack.clearRetainingCapacity();
        self.next_order = 0;
        self.needs_sort_shadows = false;
        self.needs_sort_quads = false;
        self.needs_sort_glyphs = false;
        self.needs_sort_svgs = false;
        self.needs_sort_images = false;
        self.needs_sort_paths = false;
        self.needs_sort_polylines = false;
        self.needs_sort_point_clouds = false;
        self.needs_sort_colored_point_clouds = false;
    }

    // ========================================================================
    // Pool storage (fixed capacity, fail fast)
    // ========================================================================

    /// The per-frame lists, named by their `Scene` field.
    const Pool = enum {
        shadows,
        quads,
        glyphs,
        svg_instances,
        images,
        path_instances,
        path_gradients,
        polylines,
        point_clouds,
        colored_point_clouds,
        clip_stack,
    };

    fn poolCapacity(self: *const Self, comptime pool: Pool) u32 {
        const budget = &self.limits;
        return switch (pool) {
            .shadows => budget.shadow_count_frame_max,
            .quads => budget.quad_count_frame_max,
            .glyphs => budget.glyph_count_frame_max,
            .svg_instances => budget.svg_count_frame_max,
            .images => budget.image_count_frame_max,
            .path_instances, .path_gradients => budget.path_count_frame_max,
            .polylines => budget.polyline_count_frame_max,
            .point_clouds => budget.point_cloud_count_frame_max,
            .colored_point_clouds => budget.colored_point_cloud_count_frame_max,
            .clip_stack => budget.clip_depth_max,
        };
    }

    /// Append into reserved storage. A full pool is a capacity-planning error:
    /// it stops the program with the pool, budget, and frame (CLAUDE.md §2)
    /// instead of growing or dropping the primitive. Callers that ignore insert
    /// errors (`catch {}`) therefore cannot lose work silently.
    fn push(self: *Self, comptime pool: Pool, item: anytype) void {
        const list = &@field(self, @tagName(pool));
        const capacity = self.poolCapacity(pool);
        assert(list.capacity >= capacity);
        assert(list.items.len <= capacity);
        if (list.items.len < capacity) {
            list.appendAssumeCapacity(item);
        } else {
            self.poolExhausted(@tagName(pool), capacity);
        }
    }

    fn poolExhausted(self: *const Self, pool_name: []const u8, capacity: u32) noreturn {
        @branchHint(.cold);
        std.debug.panic(
            "Scene pool '{s}' exhausted: capacity {d} (ResourceLimits.scene), " ++
                "{d} in use, 1 requested, frame {d}. Raise the app's ResourceLimits.",
            .{ pool_name, capacity, capacity, self.frame_count_finished },
        );
    }

    // ========================================================================
    // Clip Stack Management
    // ========================================================================

    /// Push a clip region onto the stack (intersects with current clip)
    pub fn pushClip(self: *Self, bounds: ContentMask.ClipBounds) !void {
        std.debug.assert(self.clip_stack.items.len <= self.limits.clip_depth_max);
        const current = self.currentClip();
        const intersected = ContentMask.ClipBounds.intersect(current, bounds);
        self.push(.clip_stack, intersected);
    }

    /// Pop the current clip region from the stack
    pub fn popClip(self: *Self) void {
        if (self.clip_stack.items.len > 0) {
            _ = self.clip_stack.pop();
        }
    }

    /// Get the current clip bounds (or no-clip if stack is empty)
    pub fn currentClip(self: *const Self) ContentMask.ClipBounds {
        if (self.clip_stack.items.len > 0) {
            return self.clip_stack.items[self.clip_stack.items.len - 1];
        }
        return ContentMask.none.bounds;
    }

    // ========================================================================
    // Draw Order Management
    // ========================================================================

    /// Reserve a block of draw orders for canvas rendering.
    /// Returns the base order; the canvas should use orders [base, base+count).
    /// This allows canvas primitives to maintain correct z-ordering with UI elements.
    pub fn reserveCanvasOrders(self: *Self, count: u32) DrawOrder {
        const base_order = self.next_order;
        self.next_order += count;
        return base_order;
    }

    // ========================================================================
    // SVG Insertion
    // ========================================================================

    /// Insert an SVG instance without clipping
    pub fn insertSvg(self: *Self, instance: SvgInstance) !void {
        std.debug.assert(self.svg_instances.items.len <= self.limits.svg_count_frame_max);
        var inst = instance;
        inst.order = self.next_order;
        self.next_order += 1;
        self.push(.svg_instances, inst);
    }

    /// Insert an SVG instance with the current clip mask applied
    pub fn insertSvgClipped(self: *Self, instance: SvgInstance) !void {
        std.debug.assert(self.svg_instances.items.len <= self.limits.svg_count_frame_max);
        const clip = self.currentClip();
        var inst = instance.withClip(clip.x, clip.y, clip.width, clip.height);
        inst.order = self.next_order;
        self.next_order += 1;
        self.push(.svg_instances, inst);
    }

    pub fn svgCount(self: *const Self) usize {
        return self.svg_instances.items.len;
    }

    pub fn getSvgInstances(self: *const Self) []const SvgInstance {
        return self.svg_instances.items;
    }

    // ========================================================================
    // Image Insertion
    // ========================================================================

    /// Insert an image instance without clipping
    pub fn insertImage(self: *Self, instance: ImageInstance) !void {
        std.debug.assert(self.images.items.len <= self.limits.image_count_frame_max);
        var inst = instance;
        inst.order = self.next_order;
        self.next_order += 1;
        self.push(.images, inst);
    }

    /// Insert an image instance with the current clip mask applied
    pub fn insertImageClipped(self: *Self, instance: ImageInstance) !void {
        std.debug.assert(self.images.items.len <= self.limits.image_count_frame_max);
        const clip = self.currentClip();
        var inst = instance.withClip(clip.x, clip.y, clip.width, clip.height);
        inst.order = self.next_order;
        self.next_order += 1;
        self.push(.images, inst);
    }

    pub fn imageCount(self: *const Self) usize {
        return self.images.items.len;
    }

    pub fn getImages(self: *const Self) []const ImageInstance {
        return self.images.items;
    }

    // ========================================================================
    // Path Insertion
    // ========================================================================

    /// Insert a path instance without clipping
    pub fn insertPath(self: *Self, instance: PathInstance) !void {
        std.debug.assert(self.path_instances.items.len <= self.limits.path_count_frame_max);
        std.debug.assert(instance.index_count > 0);

        var inst = instance;
        inst.order = self.next_order;
        self.next_order += 1;
        self.push(.path_instances, inst);
        // Append empty gradient (will be populated if instance has gradient)
        self.push(.path_gradients, GradientUniforms.none());
    }

    /// Insert a path instance with the current clip mask applied
    pub fn insertPathClipped(self: *Self, instance: PathInstance) !void {
        std.debug.assert(self.path_instances.items.len <= self.limits.path_count_frame_max);
        std.debug.assert(instance.index_count > 0);

        const clip = self.currentClip();
        var inst = instance.withClipBounds(clip);
        inst.order = self.next_order;
        self.next_order += 1;
        self.push(.path_instances, inst);
        self.push(.path_gradients, GradientUniforms.none());
    }

    /// Insert a path instance with a pre-reserved draw order
    pub fn insertPathWithOrder(self: *Self, instance: PathInstance, order: DrawOrder, clip: ContentMask.ClipBounds) !void {
        std.debug.assert(self.path_instances.items.len <= self.limits.path_count_frame_max);
        std.debug.assert(instance.index_count > 0);

        var inst = instance.withClipBounds(clip);
        inst.order = order;
        self.needs_sort_paths = true; // Out-of-order insert requires sorting
        self.push(.path_instances, inst);
        self.push(.path_gradients, GradientUniforms.none());
    }

    /// Insert a path instance with a linear gradient fill
    pub fn insertPathWithLinearGradient(
        self: *Self,
        instance: PathInstance,
        gradient: LinearGradient,
    ) !void {
        std.debug.assert(self.path_instances.items.len <= self.limits.path_count_frame_max);
        std.debug.assert(instance.index_count > 0);
        std.debug.assert(gradient.stop_count >= 2);

        const clip = self.currentClip();
        var inst = instance.withClipBounds(clip);
        inst.order = self.next_order;
        self.next_order += 1;
        self.push(.path_instances, inst);
        self.push(.path_gradients, GradientUniforms.fromLinear(gradient));
    }

    /// Insert a path instance with a radial gradient fill
    pub fn insertPathWithRadialGradient(
        self: *Self,
        instance: PathInstance,
        gradient: RadialGradient,
    ) !void {
        std.debug.assert(self.path_instances.items.len <= self.limits.path_count_frame_max);
        std.debug.assert(instance.index_count > 0);
        std.debug.assert(gradient.stop_count >= 2);

        const clip = self.currentClip();
        var inst = instance.withClipBounds(clip);
        inst.order = self.next_order;
        self.next_order += 1;
        self.push(.path_instances, inst);
        self.push(.path_gradients, GradientUniforms.fromRadial(gradient));
    }

    /// Insert a path with a mesh, allocating the mesh in the frame pool
    /// This is a convenience method that handles mesh allocation
    pub fn insertPathWithMesh(
        self: *Self,
        mesh: PathMesh,
        offset_x: f32,
        offset_y: f32,
        fill_color: Hsla,
    ) !void {
        std.debug.assert(!mesh.isEmpty());

        // Allocate mesh in frame pool
        const mesh_ref = try self.mesh_pool.allocateFrame(mesh);

        const inst = PathInstance.initWithBufferRanges(
            mesh_ref,
            offset_x,
            offset_y,
            fill_color,
            0, // vertex_offset - to be set by renderer
            0, // index_offset - to be set by renderer
            @intCast(mesh.indices.len),
        );

        try self.insertPathClipped(inst);
    }

    /// Insert a path with a mesh and a pre-reserved draw order.
    /// Use this for canvas rendering where z-order must match layout order.
    pub fn insertPathWithMeshAndOrder(
        self: *Self,
        mesh: PathMesh,
        offset_x: f32,
        offset_y: f32,
        fill_color: Hsla,
        order: DrawOrder,
        clip: ContentMask.ClipBounds,
    ) !void {
        std.debug.assert(!mesh.isEmpty());

        // Allocate mesh in frame pool
        const mesh_ref = try self.mesh_pool.allocateFrame(mesh);

        const inst = PathInstance.initWithBufferRanges(
            mesh_ref,
            offset_x,
            offset_y,
            fill_color,
            0, // vertex_offset - to be set by renderer
            0, // index_offset - to be set by renderer
            @intCast(mesh.indices.len),
        );

        try self.insertPathWithOrder(inst, order, clip);
    }

    /// Insert a line as a quad (4 vertices, 2 triangles) - efficient for diagonal lines
    /// This avoids the 67KB Path allocation by using a reusable scratch buffer.
    /// The 4 corners should be in counter-clockwise order: c0 -> c1 -> c2 -> c3
    pub fn insertLineQuad(
        self: *Self,
        c0_x: f32,
        c0_y: f32,
        c1_x: f32,
        c1_y: f32,
        c2_x: f32,
        c2_y: f32,
        c3_x: f32,
        c3_y: f32,
        fill_color: Hsla,
    ) !void {
        // Create a minimal mesh with just 4 vertices and 6 indices
        // PathMesh is ~14KB on stack, but much better than 67KB Path allocation
        var mesh = PathMesh.init();

        // Calculate bounds
        const min_x = @min(@min(c0_x, c1_x), @min(c2_x, c3_x));
        const max_x = @max(@max(c0_x, c1_x), @max(c2_x, c3_x));
        const min_y = @min(@min(c0_y, c1_y), @min(c2_y, c3_y));
        const max_y = @max(@max(c0_y, c1_y), @max(c2_y, c3_y));
        const w = if (max_x > min_x) max_x - min_x else 1;
        const h = if (max_y > min_y) max_y - min_y else 1;

        // Add 4 vertices with UV coordinates
        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(c0_x, c0_y, (c0_x - min_x) / w, (c0_y - min_y) / h));
        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(c1_x, c1_y, (c1_x - min_x) / w, (c1_y - min_y) / h));
        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(c2_x, c2_y, (c2_x - min_x) / w, (c2_y - min_y) / h));
        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(c3_x, c3_y, (c3_x - min_x) / w, (c3_y - min_y) / h));

        // Add 2 triangles (6 indices): 0-1-2 and 0-2-3
        mesh.indices.appendAssumeCapacity(0);
        mesh.indices.appendAssumeCapacity(1);
        mesh.indices.appendAssumeCapacity(2);
        mesh.indices.appendAssumeCapacity(0);
        mesh.indices.appendAssumeCapacity(2);
        mesh.indices.appendAssumeCapacity(3);

        mesh.bounds = Bounds.init(min_x, min_y, w, h);

        // Use the standard path insertion
        try self.insertPathWithMesh(mesh, 0, 0, fill_color);
    }

    /// Insert a line as a quad with a pre-reserved draw order.
    /// Use for canvas rendering where z-order must match layout order.
    pub fn insertLineQuadWithOrder(
        self: *Self,
        c0_x: f32,
        c0_y: f32,
        c1_x: f32,
        c1_y: f32,
        c2_x: f32,
        c2_y: f32,
        c3_x: f32,
        c3_y: f32,
        fill_color: Hsla,
        order: DrawOrder,
        clip: ContentMask.ClipBounds,
    ) !void {
        var mesh = PathMesh.init();

        const min_x = @min(@min(c0_x, c1_x), @min(c2_x, c3_x));
        const max_x = @max(@max(c0_x, c1_x), @max(c2_x, c3_x));
        const min_y = @min(@min(c0_y, c1_y), @min(c2_y, c3_y));
        const max_y = @max(@max(c0_y, c1_y), @max(c2_y, c3_y));
        const w = if (max_x > min_x) max_x - min_x else 1;
        const h = if (max_y > min_y) max_y - min_y else 1;

        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(c0_x, c0_y, (c0_x - min_x) / w, (c0_y - min_y) / h));
        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(c1_x, c1_y, (c1_x - min_x) / w, (c1_y - min_y) / h));
        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(c2_x, c2_y, (c2_x - min_x) / w, (c2_y - min_y) / h));
        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(c3_x, c3_y, (c3_x - min_x) / w, (c3_y - min_y) / h));

        mesh.indices.appendAssumeCapacity(0);
        mesh.indices.appendAssumeCapacity(1);
        mesh.indices.appendAssumeCapacity(2);
        mesh.indices.appendAssumeCapacity(0);
        mesh.indices.appendAssumeCapacity(2);
        mesh.indices.appendAssumeCapacity(3);

        mesh.bounds = Bounds.init(min_x, min_y, w, h);

        try self.insertPathWithMeshAndOrder(mesh, 0, 0, fill_color, order, clip);
    }

    /// Insert a single triangle (3 vertices, 1 triangle) - efficient for pie chart slices
    /// This avoids the 67KB Path allocation by creating a minimal mesh directly.
    /// Vertices should be in counter-clockwise order: v0 -> v1 -> v2
    pub fn insertTriangle(
        self: *Self,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        fill_color: Hsla,
    ) !void {
        var mesh = PathMesh.init();

        // Calculate bounds
        const min_x = @min(@min(x0, x1), x2);
        const max_x = @max(@max(x0, x1), x2);
        const min_y = @min(@min(y0, y1), y2);
        const max_y = @max(@max(y0, y1), y2);
        const w = if (max_x > min_x) max_x - min_x else 1;
        const h = if (max_y > min_y) max_y - min_y else 1;

        // Add 3 vertices with UV coordinates
        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(x0, y0, (x0 - min_x) / w, (y0 - min_y) / h));
        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(x1, y1, (x1 - min_x) / w, (y1 - min_y) / h));
        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(x2, y2, (x2 - min_x) / w, (y2 - min_y) / h));

        // Add 1 triangle (3 indices): 0-1-2
        mesh.indices.appendAssumeCapacity(0);
        mesh.indices.appendAssumeCapacity(1);
        mesh.indices.appendAssumeCapacity(2);

        mesh.bounds = Bounds.init(min_x, min_y, w, h);

        try self.insertPathWithMesh(mesh, 0, 0, fill_color);
    }

    /// Insert a single triangle with a pre-reserved draw order.
    /// Use for canvas rendering where z-order must match layout order.
    pub fn insertTriangleWithOrder(
        self: *Self,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        fill_color: Hsla,
        order: DrawOrder,
        clip: ContentMask.ClipBounds,
    ) !void {
        var mesh = PathMesh.init();

        const min_x = @min(@min(x0, x1), x2);
        const max_x = @max(@max(x0, x1), x2);
        const min_y = @min(@min(y0, y1), y2);
        const max_y = @max(@max(y0, y1), y2);
        const w = if (max_x > min_x) max_x - min_x else 1;
        const h = if (max_y > min_y) max_y - min_y else 1;

        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(x0, y0, (x0 - min_x) / w, (y0 - min_y) / h));
        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(x1, y1, (x1 - min_x) / w, (y1 - min_y) / h));
        mesh.vertices.appendAssumeCapacity(PathVertex.withUV(x2, y2, (x2 - min_x) / w, (y2 - min_y) / h));

        mesh.indices.appendAssumeCapacity(0);
        mesh.indices.appendAssumeCapacity(1);
        mesh.indices.appendAssumeCapacity(2);

        mesh.bounds = Bounds.init(min_x, min_y, w, h);

        try self.insertPathWithMeshAndOrder(mesh, 0, 0, fill_color, order, clip);
    }

    /// Get mesh pool for external use (e.g., caching persistent meshes)
    pub fn getMeshPool(self: *const Self) *const MeshPool {
        return &self.mesh_pool;
    }

    pub fn pathCount(self: *const Self) usize {
        return self.path_instances.items.len;
    }

    pub fn getPathInstances(self: *const Self) []const PathInstance {
        return self.path_instances.items;
    }

    /// Get gradient uniforms for path instances (parallel array)
    pub fn getPathGradients(self: *const Self) []const GradientUniforms {
        return self.path_gradients.items;
    }

    // ========================================================================
    // Polyline Insertion (efficient chart/data visualization)
    // ========================================================================

    /// Insert a polyline without clipping.
    /// Points should be pre-allocated (e.g., from scene.allocator or frame arena).
    pub fn insertPolyline(self: *Self, polyline: Polyline) !void {
        // Assertions at API boundary (per CLAUDE.md: minimum 2 per function)
        std.debug.assert(self.polylines.items.len <= self.limits.polyline_count_frame_max);
        std.debug.assert(polyline.point_count >= 2); // Need at least 2 points for a line

        var pl = polyline;
        pl.order = self.next_order;
        self.next_order += 1;
        self.push(.polylines, pl);
    }

    /// Insert a polyline with the current clip mask applied.
    /// Points should be pre-allocated (e.g., from scene.allocator or frame arena).
    pub fn insertPolylineClipped(self: *Self, polyline: Polyline) !void {
        std.debug.assert(self.polylines.items.len <= self.limits.polyline_count_frame_max);
        std.debug.assert(polyline.point_count >= 2);

        const clip = self.currentClip();
        var pl = polyline.withClipBounds(clip);
        pl.order = self.next_order;
        self.next_order += 1;
        self.push(.polylines, pl);
    }

    /// Insert a polyline with a pre-reserved draw order.
    /// Use when interleaving polylines with other primitives at specific z-orders.
    pub fn insertPolylineWithOrder(self: *Self, polyline: Polyline, order: DrawOrder, clip: ContentMask.ClipBounds) !void {
        std.debug.assert(self.polylines.items.len <= self.limits.polyline_count_frame_max);
        std.debug.assert(polyline.point_count >= 2);

        var pl = polyline.withClipBounds(clip);
        pl.order = order;
        self.needs_sort_polylines = true; // Out-of-order insert requires sorting
        self.push(.polylines, pl);
    }

    pub fn polylineCount(self: *const Self) usize {
        return self.polylines.items.len;
    }

    pub fn getPolylines(self: *const Self) []const Polyline {
        return self.polylines.items;
    }

    // ========================================================================
    // Point Cloud Primitives (instanced circles for scatter plots)
    // ========================================================================

    /// Insert a point cloud for instanced circle rendering.
    /// Positions should be pre-allocated (e.g., from scene.allocator or frame arena).
    pub fn insertPointCloud(self: *Self, cloud: PointCloud) !void {
        // Assertions at API boundary (per CLAUDE.md: minimum 2 per function)
        std.debug.assert(self.point_clouds.items.len <= self.limits.point_cloud_count_frame_max);
        std.debug.assert(cloud.count >= 1); // Need at least 1 point

        var pc = cloud;
        pc.order = self.next_order;
        self.next_order += 1;
        self.push(.point_clouds, pc);
    }

    /// Insert a point cloud with the current clip mask applied.
    /// Positions should be pre-allocated (e.g., from scene.allocator or frame arena).
    pub fn insertPointCloudClipped(self: *Self, cloud: PointCloud) !void {
        std.debug.assert(self.point_clouds.items.len <= self.limits.point_cloud_count_frame_max);
        std.debug.assert(cloud.count >= 1);

        const clip = self.currentClip();
        var pc = cloud.withClipBounds(clip);
        pc.order = self.next_order;
        self.next_order += 1;
        self.push(.point_clouds, pc);
    }

    /// Insert a point cloud with a pre-reserved draw order.
    /// Use when interleaving point clouds with other primitives at specific z-orders.
    pub fn insertPointCloudWithOrder(self: *Self, cloud: PointCloud, order: DrawOrder, clip: ContentMask.ClipBounds) !void {
        std.debug.assert(self.point_clouds.items.len <= self.limits.point_cloud_count_frame_max);
        std.debug.assert(cloud.count >= 1);

        var pc = cloud.withClipBounds(clip);
        pc.order = order;
        self.needs_sort_point_clouds = true; // Out-of-order insert requires sorting
        self.push(.point_clouds, pc);
    }

    pub fn pointCloudCount(self: *const Self) usize {
        return self.point_clouds.items.len;
    }

    pub fn getPointClouds(self: *const Self) []const PointCloud {
        return self.point_clouds.items;
    }

    // ========================================================================
    // Colored Point Cloud Primitives (instanced circles with per-point colors)
    // ========================================================================

    /// Insert a colored point cloud for instanced circle rendering with per-point colors.
    /// Positions and colors should be pre-allocated (e.g., from scene.allocator or frame arena).
    pub fn insertColoredPointCloud(self: *Self, cloud: ColoredPointCloud) !void {
        // Assertions at API boundary (per CLAUDE.md: minimum 2 per function)
        const colored_count_max = self.limits.colored_point_cloud_count_frame_max;
        std.debug.assert(self.colored_point_clouds.items.len <= colored_count_max);
        std.debug.assert(cloud.count >= 1); // Need at least 1 point

        var cpc = cloud;
        cpc.order = self.next_order;
        self.next_order += 1;
        self.push(.colored_point_clouds, cpc);
    }

    /// Insert a colored point cloud with the current clip mask applied.
    /// Positions and colors should be pre-allocated (e.g., from scene.allocator or frame arena).
    pub fn insertColoredPointCloudClipped(self: *Self, cloud: ColoredPointCloud) !void {
        const colored_count_max = self.limits.colored_point_cloud_count_frame_max;
        std.debug.assert(self.colored_point_clouds.items.len <= colored_count_max);
        std.debug.assert(cloud.count >= 1);

        const clip = self.currentClip();
        var cpc = cloud.withClipBounds(clip);
        cpc.order = self.next_order;
        self.next_order += 1;
        self.push(.colored_point_clouds, cpc);
    }

    /// Insert a colored point cloud with a pre-reserved draw order.
    /// Use when interleaving colored point clouds with other primitives at specific z-orders.
    pub fn insertColoredPointCloudWithOrder(self: *Self, cloud: ColoredPointCloud, order: DrawOrder, clip: ContentMask.ClipBounds) !void {
        const colored_count_max = self.limits.colored_point_cloud_count_frame_max;
        std.debug.assert(self.colored_point_clouds.items.len <= colored_count_max);
        std.debug.assert(cloud.count >= 1);

        var cpc = cloud.withClipBounds(clip);
        cpc.order = order;
        self.needs_sort_colored_point_clouds = true; // Out-of-order insert requires sorting
        self.push(.colored_point_clouds, cpc);
    }

    pub fn coloredPointCloudCount(self: *const Self) usize {
        return self.colored_point_clouds.items.len;
    }

    pub fn getColoredPointClouds(self: *const Self) []const ColoredPointCloud {
        return self.colored_point_clouds.items;
    }

    // ========================================================================
    // Glyph Insertion
    // ========================================================================

    /// Insert a glyph without clipping
    pub fn insertGlyph(self: *Self, glyph: GlyphInstance) !void {
        std.debug.assert(self.glyphs.items.len <= self.limits.glyph_count_frame_max);
        var g = glyph;
        g.order = self.next_order;
        self.next_order += 1;
        self.push(.glyphs, g);

        // Track inserted glyphs for profiler
        if (self.stats) |s| s.recordGlyphs(1);
    }

    /// Insert a glyph with the current clip mask applied
    pub fn insertGlyphClipped(self: *Self, glyph: GlyphInstance) !void {
        std.debug.assert(self.glyphs.items.len <= self.limits.glyph_count_frame_max);
        const clip = self.currentClip();
        var g = glyph.withClipBounds(clip);
        g.order = self.next_order;
        self.next_order += 1;
        self.push(.glyphs, g);

        // Track inserted glyphs for profiler
        if (self.stats) |s| s.recordGlyphs(1);
    }

    /// Insert a glyph with a pre-reserved draw order.
    /// Use this for canvas text rendering where z-order must match layout order.
    pub fn insertGlyphWithOrder(self: *Self, glyph: GlyphInstance, order: DrawOrder, clip: ContentMask.ClipBounds) !void {
        std.debug.assert(self.glyphs.items.len <= self.limits.glyph_count_frame_max);
        var g = glyph.withClipBounds(clip);
        g.order = order;
        self.needs_sort_glyphs = true;
        self.push(.glyphs, g);

        // Track inserted glyphs for profiler
        if (self.stats) |s| s.recordGlyphs(1);
    }

    pub fn glyphCount(self: *const Self) usize {
        return self.glyphs.items.len;
    }

    pub fn getGlyphs(self: *const Self) []const GlyphInstance {
        return self.glyphs.items;
    }

    /// Insert a shadow (call BEFORE the quad it shadows)
    pub fn insertShadow(self: *Self, shadow: Shadow) !void {
        std.debug.assert(self.shadows.items.len <= self.limits.shadow_count_frame_max);
        // Fast viewport cull - account for blur radius and offset
        if (self.culling_enabled) {
            const expand = shadow.blur_radius * 2; // Shadow extends beyond content
            const left = shadow.content_origin_x + shadow.offset_x - expand;
            const top = shadow.content_origin_y + shadow.offset_y - expand;
            const right = left + shadow.content_size_width + expand * 2;
            const bottom = top + shadow.content_size_height + expand * 2;

            if (right < 0 or left > self.viewport_width or
                bottom < 0 or top > self.viewport_height)
            {
                if (self.stats) |s| s.recordShadowsCulled(1);
                return;
            }
        }

        var s = shadow;
        s.order = self.next_order;
        self.next_order += 1;
        self.push(.shadows, s);
    }

    pub fn insertQuad(self: *Self, quad: Quad) !void {
        std.debug.assert(self.quads.items.len <= self.limits.quad_count_frame_max);
        // Fast viewport cull - skip if completely outside viewport
        if (self.culling_enabled) {
            const right = quad.bounds_origin_x + quad.bounds_size_width;
            const bottom = quad.bounds_origin_y + quad.bounds_size_height;

            if (right < 0 or quad.bounds_origin_x > self.viewport_width or
                bottom < 0 or quad.bounds_origin_y > self.viewport_height)
            {
                // Quad is fully outside viewport - skip it
                if (self.stats) |s| s.recordQuadsCulled(1);
                return;
            }
        }

        var q = quad;
        q.order = self.next_order;
        self.next_order += 1;
        self.push(.quads, q);

        // Track inserted quads for profiler
        if (self.stats) |s| s.recordQuads(1);
    }

    /// Insert a quad with a caller-specified draw order (for overlays, debug UI, etc.)
    /// This preserves the quad's order field and triggers sorting in finish().
    pub fn insertQuadWithOrder(self: *Self, quad: Quad) !void {
        std.debug.assert(self.quads.items.len <= self.limits.quad_count_frame_max);
        // Fast viewport cull - skip if completely outside viewport
        if (self.culling_enabled) {
            const right = quad.bounds_origin_x + quad.bounds_size_width;
            const bottom = quad.bounds_origin_y + quad.bounds_size_height;

            if (right < 0 or quad.bounds_origin_x > self.viewport_width or
                bottom < 0 or quad.bounds_origin_y > self.viewport_height)
            {
                // Quad is fully outside viewport - skip it
                if (self.stats) |s| s.recordQuadsCulled(1);
                return;
            }
        }

        // Preserve caller's order - this will require sorting
        self.needs_sort_quads = true;
        self.push(.quads, quad);

        // Track inserted quads for profiler
        if (self.stats) |s| s.recordQuads(1);
    }

    /// Check if there's an active clip (clip stack is not empty)
    pub fn hasActiveClip(self: *const Self) bool {
        return self.clip_stack.items.len > 0;
    }

    /// Insert a quad with the current clip mask applied
    pub fn insertQuadClipped(self: *Self, quad: Quad) !void {
        std.debug.assert(self.quads.items.len <= self.limits.quad_count_frame_max);
        const clip = self.currentClip();

        // Cull against clip bounds (even tighter than viewport)
        const right = quad.bounds_origin_x + quad.bounds_size_width;
        const bottom = quad.bounds_origin_y + quad.bounds_size_height;

        if (right < clip.x or quad.bounds_origin_x > clip.x + clip.width or
            bottom < clip.y or quad.bounds_origin_y > clip.y + clip.height)
        {
            // Quad is fully outside clip region - skip entirely
            if (self.stats) |s| s.recordQuadsCulled(1);
            return;
        }

        // Also check viewport if enabled
        if (self.culling_enabled) {
            if (right < 0 or quad.bounds_origin_x > self.viewport_width or
                bottom < 0 or quad.bounds_origin_y > self.viewport_height)
            {
                if (self.stats) |s| s.recordQuadsCulled(1);
                return;
            }
        }

        var q = quad.withClipBounds(clip);
        q.order = self.next_order;
        self.next_order += 1;
        self.push(.quads, q);

        // Track inserted quads for profiler
        if (self.stats) |s| s.recordQuads(1);
    }

    /// The sort-key scratch for `count` keys. Reserved at the largest sortable
    /// pool's capacity, so no pool can need more keys than it holds.
    fn acquireSortKeys(self: *Self, count: u32) []u64 {
        assert(count >= 2); // callers skip the sort for count < 2
        const buffer = self.sort_keys.allocatedSlice();
        assert(buffer.len == self.limits.sortKeyCountMax());
        assert(count <= buffer.len);
        return buffer[0..count];
    }

    /// Sort a single per-type array ascending by `.order` using the indirect key
    /// sort (see the "Draw-order sort" section). Falls back to a direct payload
    /// pdq if the key scratch is unavailable, keeping the result correct under
    /// allocation failure.
    fn sortByOrder(self: *Self, comptime T: type, items: []T) void {
        if (items.len < 2) return; // 0 or 1 element is already ordered
        const count: u32 = @intCast(items.len);

        const keys = self.acquireSortKeys(count);
        std.debug.assert(keys.len == count);

        var i: u32 = 0;
        while (i < count) : (i += 1) keys[i] = makeOrderKey(items[i].order, i);

        std.sort.pdq(u64, keys, {}, ascendingU64);
        applyPermutation(T, items, keys);
    }

    /// Finalize the scene for rendering.
    /// Sorts primitives by draw order only for arrays that had out-of-order
    /// inserts. Each array is ordered by an indirect key sort that moves the fat
    /// payload structs at most once (see the "Draw-order sort" section above).
    pub fn finish(self: *Self) void {
        assert(self.path_instances.items.len == self.path_gradients.items.len);
        self.frame_count_finished += 1;
        // Only sort arrays that had out-of-order inserts. The shadow, svg, and
        // image flags have no public setter today (no ordered-insert API for
        // those types), but routing them through the same path keeps the nine
        // types symmetric and correct the moment such an API is added.
        if (self.needs_sort_shadows) self.sortByOrder(Shadow, self.shadows.items);
        if (self.needs_sort_quads) self.sortByOrder(Quad, self.quads.items);
        if (self.needs_sort_glyphs) self.sortByOrder(GlyphInstance, self.glyphs.items);
        if (self.needs_sort_svgs) self.sortByOrder(SvgInstance, self.svg_instances.items);
        if (self.needs_sort_images) self.sortByOrder(ImageInstance, self.images.items);
        if (self.needs_sort_paths) {
            // Paths carry a parallel gradient array; gather both with one
            // permutation (retires the former O(n²) selection sort).
            sortPathsByOrder(self.path_instances.items, self.path_gradients.items);
        }
        if (self.needs_sort_polylines) self.sortByOrder(Polyline, self.polylines.items);
        if (self.needs_sort_point_clouds) self.sortByOrder(PointCloud, self.point_clouds.items);
        // Previously missing: the flag was set on out-of-order inserts but never
        // consumed, so colored point clouds rendered in insertion order. Wiring
        // the branch in fixes that dead-invariant bug (§11, negative space).
        if (self.needs_sort_colored_point_clouds) {
            self.sortByOrder(ColoredPointCloud, self.colored_point_clouds.items);
        }
    }

    pub fn shadowCount(self: *const Self) usize {
        return self.shadows.items.len;
    }

    pub fn quadCount(self: *const Self) usize {
        return self.quads.items.len;
    }

    pub fn getShadows(self: *const Self) []const Shadow {
        return self.shadows.items;
    }

    pub fn getQuads(self: *const Self) []const Quad {
        return self.quads.items;
    }

    /// Set viewport for culling. Call this before inserting primitives.
    pub fn setViewport(self: *Self, width: f32, height: f32) void {
        self.viewport_width = width;
        self.viewport_height = height;
    }

    /// Disable viewport culling
    pub fn disableCulling(self: *Self) void {
        self.culling_enabled = false;
    }

    /// Enabled viewport culling
    /// Primitives fully outside the viewport will be skipped.
    pub fn enableCulling(self: *Self) void {
        self.culling_enabled = true;
    }

    /// Attach stats tracker (optional)
    pub fn setStats(self: *Self, stats: *@import("../debug/render_stats.zig").RenderStats) void {
        self.stats = stats;
    }
};

/// Small budget for tests: every pool holds 4, except glyphs, which must hold
/// one whole shaped run (`MAX_GLYPHS_PER_RUN`) to pass `SceneLimits.check`.
const test_limits: SceneLimits = .{
    .quad_count_frame_max = 4,
    .shadow_count_frame_max = 4,
    .glyph_count_frame_max = limits.MAX_GLYPHS_PER_RUN,
    .svg_count_frame_max = 4,
    .image_count_frame_max = 4,
    .path_count_frame_max = 4,
    .polyline_count_frame_max = 4,
    .point_cloud_count_frame_max = 4,
    .colored_point_cloud_count_frame_max = 4,
    .clip_depth_max = 4,
};

test "initCapacity reserves exactly the budget and initEmpty reserves nothing" {
    // Goal: storage is sized from the scene's own budget, not the ceilings, and
    // the zero-capacity constructor allocates nothing (no leak-check findings).
    const testing = std.testing;
    var scene = try Scene.initCapacity(testing.allocator, &test_limits);
    defer scene.deinit();
    try testing.expectEqual(@as(usize, 4), scene.quads.capacity);
    try testing.expectEqual(@as(usize, 4), scene.path_gradients.capacity);
    try testing.expectEqual(@as(usize, limits.MAX_GLYPHS_PER_RUN), scene.glyphs.capacity);
    try testing.expectEqual(@as(usize, test_limits.sortKeyCountMax()), scene.sort_keys.capacity);

    var empty = Scene.initEmpty(testing.allocator);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.quads.capacity);
    try testing.expectEqual(@as(u32, 0), empty.poolCapacity(.quads));
}

test "every scene pool fills exactly to its budget without allocating" {
    // Goal: the capacity contract for each pool. Fill to exactly the budget,
    // check the last insert landed, and check the pool is then full, which is
    // the state where the next insert takes the fail-fast branch in `push`.
    // That branch panics, which a test cannot catch in-process, so the panic
    // itself is verified by the `scene-overflow` build step (a child process
    // whose abort and message are asserted). Inserts run against
    // `failing_allocator` to prove none of them allocates.
    const testing = std.testing;
    var scene = try Scene.initCapacity(testing.allocator, &test_limits);
    defer scene.deinit();
    const owner = scene.allocator;
    scene.allocator = testing.failing_allocator;
    defer scene.allocator = owner;

    const path = PathInstance{ .index_count = 3 };
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        try scene.insertShadow(Shadow.drop(0, 0, 10, 10, 2));
        try scene.insertQuad(Quad.filled(0, 0, 10, 10, Hsla.red));
        try scene.insertSvg(.{});
        try scene.insertImage(.{});
        try scene.insertPath(path);
        try scene.insertPolyline(.{ .point_count = 2 });
        try scene.insertPointCloud(.{ .count = 1 });
        try scene.insertColoredPointCloud(.{ .count = 1 });
        try scene.pushClip(.{ .x = 0, .y = 0, .width = 100, .height = 100 });
    }
    i = 0;
    while (i < limits.MAX_GLYPHS_PER_RUN) : (i += 1) {
        try scene.insertGlyph(GlyphInstance.init(0, 0, 6, 12, 0, 0, 1, 1, Hsla.black));
    }

    // The last insert of each kind landed: orders are assigned in insert order.
    const order_last: DrawOrder = scene.next_order - 1;
    try testing.expectEqual(order_last, scene.glyphs.items[scene.glyphs.items.len - 1].order);
    try testing.expectEqual(@as(usize, 4), scene.clip_stack.items.len);

    const pool_info = @typeInfo(Scene.Pool).@"enum";
    inline for (pool_info.field_names, pool_info.field_values) |field_name, field_value| {
        const pool: Scene.Pool = @fromBackingInt(@intCast(field_value));
        const list = &@field(scene, field_name);
        // Full: exactly at capacity, and the storage did not grow.
        try testing.expectEqual(@as(usize, scene.poolCapacity(pool)), list.items.len);
        try testing.expectEqual(@as(usize, scene.poolCapacity(pool)), list.capacity);
    }

    // Reuse after clear: the same storage takes a full frame again.
    scene.clear();
    scene.clip_stack.clearRetainingCapacity();
    i = 0;
    while (i < 4) : (i += 1) try scene.insertQuad(Quad.filled(0, 0, 1, 1, Hsla.red));
    try testing.expectEqual(@as(usize, 4), scene.quads.items.len);
    try testing.expectEqual(@as(usize, 4), scene.quads.capacity);
}

test "culled primitives do not consume budget at a full pool" {
    // Goal: boundary in the negative space. A quad that viewport culling drops
    // never reaches `push`, so a full pool must not fail on it.
    const testing = std.testing;
    var scene = try Scene.initCapacity(testing.allocator, &test_limits);
    defer scene.deinit();
    scene.setViewport(100, 100);
    scene.enableCulling();

    var i: u32 = 0;
    while (i < 4) : (i += 1) try scene.insertQuad(Quad.filled(0, 0, 10, 10, Hsla.red));
    try scene.insertQuad(Quad.filled(500, 500, 10, 10, Hsla.red)); // Off-screen.
    try testing.expectEqual(@as(usize, 4), scene.quads.items.len);
}

test "Scene finish skips sort when elements are in order" {
    const testing = std.testing;
    var scene = try Scene.initCapacity(testing.allocator, &test_limits);
    defer scene.deinit();

    // Insert elements in order (normal case)
    try scene.insertQuad(.{ .bounds_origin_x = 0, .bounds_origin_y = 0, .bounds_size_width = 10, .bounds_size_height = 10 });
    try scene.insertQuad(.{ .bounds_origin_x = 10, .bounds_origin_y = 10, .bounds_size_width = 10, .bounds_size_height = 10 });
    try scene.insertQuad(.{ .bounds_origin_x = 20, .bounds_origin_y = 20, .bounds_size_width = 10, .bounds_size_height = 10 });

    // needs_sort_quads should be false
    try testing.expect(!scene.needs_sort_quads);

    // finish() should be a no-op (fast path)
    scene.finish();

    // Verify order is preserved
    try testing.expectEqual(@as(DrawOrder, 0), scene.quads.items[0].order);
    try testing.expectEqual(@as(DrawOrder, 1), scene.quads.items[1].order);
    try testing.expectEqual(@as(DrawOrder, 2), scene.quads.items[2].order);
}

test "insertQuadWithOrder preserves draw order and triggers sort" {
    const testing = std.testing;
    var scene = try Scene.initCapacity(testing.allocator, &test_limits);
    defer scene.deinit();

    // Insert regular quads first (orders 0, 1, 2)
    try scene.insertQuad(.{ .bounds_origin_x = 0, .bounds_origin_y = 0, .bounds_size_width = 10, .bounds_size_height = 10 });
    try scene.insertQuad(.{ .bounds_origin_x = 10, .bounds_origin_y = 10, .bounds_size_width = 10, .bounds_size_height = 10 });
    try scene.insertQuad(.{ .bounds_origin_x = 20, .bounds_origin_y = 20, .bounds_size_width = 10, .bounds_size_height = 10 });

    // needs_sort_quads should be false after regular inserts
    try testing.expect(!scene.needs_sort_quads);

    // Insert a quad with a high explicit order (like debug overlay)
    const DEBUG_ORDER: DrawOrder = 0xFFFF_FF00;
    var overlay_quad = Quad.filled(50, 50, 100, 100, Hsla.red);
    overlay_quad.order = DEBUG_ORDER;
    try scene.insertQuadWithOrder(overlay_quad);

    // needs_sort_quads should now be true
    try testing.expect(scene.needs_sort_quads);

    // The overlay quad should have its order preserved
    try testing.expectEqual(DEBUG_ORDER, scene.quads.items[3].order);

    // After finish(), quads should be sorted by order
    scene.finish();

    // Regular quads (0, 1, 2) should come before overlay (DEBUG_ORDER)
    try testing.expectEqual(@as(DrawOrder, 0), scene.quads.items[0].order);
    try testing.expectEqual(@as(DrawOrder, 1), scene.quads.items[1].order);
    try testing.expectEqual(@as(DrawOrder, 2), scene.quads.items[2].order);
    try testing.expectEqual(DEBUG_ORDER, scene.quads.items[3].order);
}

test "insertQuadWithOrder interleaves correctly with BatchIterator" {
    const testing = std.testing;
    const batch_iter = @import("batch_iterator.zig");

    var scene = try Scene.initCapacity(testing.allocator, &test_limits);
    defer scene.deinit();

    // Insert: quad(0), glyph(1), quad(2), then overlay quad with high order
    try scene.insertQuad(Quad.filled(0, 0, 100, 100, Hsla.red));
    try scene.insertGlyph(GlyphInstance.init(0, 0, 10, 10, 0, 0, 1, 1, Hsla.black));
    try scene.insertQuad(Quad.filled(10, 10, 100, 100, Hsla.green));

    // Insert debug overlay with explicit high order
    var overlay = Quad.filled(50, 50, 200, 200, Hsla.blue);
    overlay.order = 1000;
    try scene.insertQuadWithOrder(overlay);

    // Finish to sort
    scene.finish();

    // Verify batch iterator yields in correct order
    var iter = batch_iter.BatchIterator.init(&scene);

    // First batch: quad at order 0
    const batch1 = iter.next().?;
    try testing.expect(batch1 == .quad);
    try testing.expectEqual(@as(usize, 1), batch1.quad.len);

    // Second batch: glyph at order 1
    const batch2 = iter.next().?;
    try testing.expect(batch2 == .glyph);

    // Third batch: quads at orders 2 and 1000 (coalesced - no other type between them)
    const batch3 = iter.next().?;
    try testing.expect(batch3 == .quad);
    try testing.expectEqual(@as(usize, 2), batch3.quad.len);
    try testing.expectEqual(@as(DrawOrder, 2), batch3.quad[0].order);
    try testing.expectEqual(@as(DrawOrder, 1000), batch3.quad[1].order);

    // No more batches
    try testing.expect(iter.next() == null);
}

test "finish sorts all nine per-type draw-order arrays ascending" {
    // Goal: prove every per-type array that can be flagged out-of-order is
    // actually re-sorted by `finish()` — including `colored_point_clouds`, whose
    // sort branch was previously missing (write-only flag), and the parallel
    // path arrays, whose gradients must travel with their instances. We seed
    // each array directly (white-box) with a descending-ish order permutation so
    // a correct sort must move every element, then assert ascending order.
    const testing = std.testing;
    var scene = try Scene.initCapacity(testing.allocator, &test_limits);
    defer scene.deinit();

    // Distinct, non-monotonic orders: a stable ascending sort must reorder them
    // to {0, 10, 20, 30, 40}.
    const orders = [_]DrawOrder{ 40, 10, 30, 0, 20 };

    // Append `n` default primitives of type `T` carrying the given orders.
    // References only `std` (file scope) and its parameters — no outer locals —
    // so it is a legal nested function in Zig.
    const seed = struct {
        fn run(
            comptime T: type,
            list: *std.ArrayListUnmanaged(T),
            gpa: std.mem.Allocator,
            order_values: []const DrawOrder,
        ) !void {
            for (order_values) |order| try list.append(gpa, .{ .order = order });
        }
    }.run;

    const expectAscending = struct {
        fn run(comptime T: type, items: []const T) !void {
            var i: usize = 1;
            while (i < items.len) : (i += 1) {
                try std.testing.expect(items[i - 1].order <= items[i].order);
            }
        }
    }.run;

    try seed(Shadow, &scene.shadows, scene.allocator, &orders);
    scene.needs_sort_shadows = true;
    try seed(Quad, &scene.quads, scene.allocator, &orders);
    scene.needs_sort_quads = true;
    try seed(GlyphInstance, &scene.glyphs, scene.allocator, &orders);
    scene.needs_sort_glyphs = true;
    try seed(SvgInstance, &scene.svg_instances, scene.allocator, &orders);
    scene.needs_sort_svgs = true;
    try seed(ImageInstance, &scene.images, scene.allocator, &orders);
    scene.needs_sort_images = true;
    try seed(Polyline, &scene.polylines, scene.allocator, &orders);
    scene.needs_sort_polylines = true;
    try seed(PointCloud, &scene.point_clouds, scene.allocator, &orders);
    scene.needs_sort_point_clouds = true;
    try seed(ColoredPointCloud, &scene.colored_point_clouds, scene.allocator, &orders);
    scene.needs_sort_colored_point_clouds = true;

    // Paths: parallel instance/gradient arrays. Tag each gradient's `param0`
    // with its instance's order so we can prove the gather kept them aligned.
    for (orders) |order| {
        try scene.path_instances.append(scene.allocator, .{ .order = order, .index_count = 1 });
        try scene.path_gradients.append(scene.allocator, .{ .param0 = @floatFromInt(order) });
    }
    scene.needs_sort_paths = true;

    scene.finish();

    try expectAscending(Shadow, scene.shadows.items);
    try expectAscending(Quad, scene.quads.items);
    try expectAscending(GlyphInstance, scene.glyphs.items);
    try expectAscending(SvgInstance, scene.svg_instances.items);
    try expectAscending(ImageInstance, scene.images.items);
    try expectAscending(Polyline, scene.polylines.items);
    try expectAscending(PointCloud, scene.point_clouds.items);
    try expectAscending(ColoredPointCloud, scene.colored_point_clouds.items);
    try expectAscending(PathInstance, scene.path_instances.items);

    // Parallel gather: each gradient must still sit beside its own instance.
    for (scene.path_instances.items, scene.path_gradients.items) |instance, gradient| {
        try testing.expectEqual(@as(f32, @floatFromInt(instance.order)), gradient.param0);
    }
}
