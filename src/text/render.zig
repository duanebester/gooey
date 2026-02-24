//! Text rendering — converts shaped text to GPU glyph instances.
//!
//! The rendering pipeline has three phases, optimized for minimal lock contention:
//!   Phase 1 — Compute device-pixel positions and subpixel offsets (no lock).
//!   Phase 2 — Batch-resolve all glyphs from the cache under a single mutex lock.
//!   Phase 3 — Build GlyphInstances and emit to the scene (no lock).
//!
//! The batch glyph resolve (Phase 2) eliminates N-1 mutex lock/unlock pairs per
//! text run compared to the per-glyph locking pattern, saving ~500–2000 ns for
//! a 50-character string on macOS (atomic CAS + memory fence per lock).

const std = @import("std");
const platform = @import("../platform/mod.zig");
const scene_mod = @import("../scene/mod.zig");
const Scene = scene_mod.Scene;
const Quad = scene_mod.Quad;
const GlyphInstance = scene_mod.GlyphInstance;
const ContentMask = scene_mod.ContentMask;
const DrawOrder = scene_mod.DrawOrder;
const text_system_mod = @import("text_system.zig");
const TextSystem = text_system_mod.TextSystem;
const ShapedRunCache = text_system_mod.ShapedRunCache;
const CachedGlyph = text_system_mod.CachedGlyph;
const ShapedGlyph = types.ShapedGlyph;
const Hsla = scene_mod.Hsla;
const types = @import("types.zig");
const Metrics = types.Metrics;
const TextDecoration = types.TextDecoration;
const RenderStats = @import("../debug/render_stats.zig").RenderStats;

const is_wasm = platform.is_wasm;

const SUBPIXEL_VARIANTS_X = types.SUBPIXEL_VARIANTS_X;
const SUBPIXEL_VARIANTS_F: f32 = @floatFromInt(SUBPIXEL_VARIANTS_X);

/// Maximum glyphs per text run.  Matches ShapedRunCache capacity.
const MAX_GLYPHS_PER_RUN: u32 = ShapedRunCache.MAX_GLYPHS_PER_ENTRY;

pub const RenderTextOptions = struct {
    clipped: bool = true,
    decoration: TextDecoration = .{},
    /// Optional separate color for decorations (uses text color if null).
    decoration_color: ?Hsla = null,
    /// Optional stats for performance tracking (pass null to skip).
    stats: ?*RenderStats = null,
    /// Base draw order for z-ordering (0 = use scene's auto-ordering).
    base_order: DrawOrder = 0,
    /// Current draw order offset (incremented per glyph when ordered).
    current_order: *DrawOrder = undefined,
    /// Clip bounds for ordered rendering.
    clip_bounds: ContentMask.ClipBounds = ContentMask.none.bounds,

    /// Check if this uses explicit ordering.
    pub fn isOrdered(self: *const RenderTextOptions) bool {
        return self.base_order != 0;
    }

    /// Get next order and increment.
    pub fn nextOrder(self: *RenderTextOptions) DrawOrder {
        const order = self.base_order + self.current_order.*;
        self.current_order.* += 1;
        return order;
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Render shaped text to the scene, returning the scaled width.
///
/// Glyph cache lookups are batched under a single mutex lock (Phase 2),
/// eliminating N-1 lock/unlock pairs for an N-glyph text run.
pub fn renderText(
    scene: *Scene,
    text_system: *TextSystem,
    text: []const u8,
    x: f32,
    baseline_y: f32,
    scale_factor: f32,
    color: Hsla,
    font_size: f32,
    options: *RenderTextOptions,
) !f32 {
    std.debug.assert(font_size > 0);
    std.debug.assert(font_size < 1000);
    std.debug.assert(scale_factor > 0);

    if (text.len == 0) return 0;

    // Shaped glyphs have advances/offsets at the base font size; scale them.
    const size_scale = if (text_system.getMetrics()) |metrics|
        font_size / metrics.point_size
    else
        1.0;

    // Stack buffer for warm-path glyph copies — avoids GPA alloc/free (~5,000 ns).
    // MAX_GLYPHS_PER_RUN (128) * @sizeOf(ShapedGlyph) ≈ 6 KB; safe for WASM stack.
    var glyph_buf: [MAX_GLYPHS_PER_RUN]ShapedGlyph = undefined;
    var shaped = try text_system.shapeTextInto(text, options.stats, &glyph_buf);
    defer if (shaped.owned) shaped.deinit(text_system.allocator);

    const scaled_width = shaped.width * size_scale;
    const glyph_count = shaped.glyphs.len;

    if (glyph_count == 0) return scaled_width;
    std.debug.assert(glyph_count <= MAX_GLYPHS_PER_RUN);

    // Phase 1: Compute device-pixel positions and subpixel offsets (no lock).
    var device_positions_x: [MAX_GLYPHS_PER_RUN]f32 = undefined;
    var device_positions_y: [MAX_GLYPHS_PER_RUN]f32 = undefined;
    var subpixel_offsets_x: [MAX_GLYPHS_PER_RUN]u8 = undefined;

    computeGlyphDevicePositions(
        shaped.glyphs,
        x,
        baseline_y,
        size_scale,
        scale_factor,
        device_positions_x[0..glyph_count],
        device_positions_y[0..glyph_count],
        subpixel_offsets_x[0..glyph_count],
    );

    // Phase 2: Batch-resolve all glyphs under a single glyph_cache_mutex lock.
    // One lock/unlock for the entire run instead of N separate lock/unlock pairs.
    var cached_results: [MAX_GLYPHS_PER_RUN]CachedGlyph = undefined;

    try text_system.resolveGlyphBatch(
        shaped.glyphs,
        font_size,
        subpixel_offsets_x[0..glyph_count],
        cached_results[0..glyph_count],
    );

    // Phase 3: Build GlyphInstances and emit to the scene (no lock).
    try emitGlyphsToScene(
        scene,
        cached_results[0..glyph_count],
        device_positions_x[0..glyph_count],
        device_positions_y[0..glyph_count],
        scale_factor,
        color,
        options,
    );

    // Render decorations (underline, strikethrough) if requested.
    if (options.decoration.hasAny()) {
        if (text_system.getMetrics()) |metrics| {
            try renderDecorations(scene, metrics, x, baseline_y, scaled_width, color, options);
        }
    }

    return scaled_width;
}

// =============================================================================
// Phase 1: Device Position Computation
// =============================================================================

/// Compute device-pixel coordinates and subpixel X offsets for each glyph.
/// Tracks pen_x cumulatively across the glyph run.
fn computeGlyphDevicePositions(
    shaped_glyphs: []const ShapedGlyph,
    start_x: f32,
    baseline_y: f32,
    size_scale: f32,
    scale_factor: f32,
    out_device_x: []f32,
    out_device_y: []f32,
    out_subpixel_x: []u8,
) void {
    std.debug.assert(shaped_glyphs.len > 0);
    std.debug.assert(shaped_glyphs.len == out_device_x.len);
    std.debug.assert(shaped_glyphs.len == out_device_y.len);
    std.debug.assert(shaped_glyphs.len == out_subpixel_x.len);
    std.debug.assert(scale_factor > 0);
    std.debug.assert(size_scale > 0);

    var pen_x = start_x;
    for (shaped_glyphs, 0..) |glyph, index| {
        // Scale offsets and advances from base font size to requested size.
        const scaled_x_offset = glyph.x_offset * size_scale;
        const scaled_y_offset = glyph.y_offset * size_scale;
        const scaled_advance = glyph.x_advance * size_scale;

        // Convert logical coordinates to device pixels.
        const device_x = (pen_x + scaled_x_offset) * scale_factor;
        const device_y = (baseline_y + scaled_y_offset) * scale_factor;

        // Extract fractional part for subpixel variant selection.
        const fractional_x = device_x - @floor(device_x);

        out_device_x[index] = device_x;
        out_device_y[index] = device_y;
        out_subpixel_x[index] = @intFromFloat(@floor(fractional_x * SUBPIXEL_VARIANTS_F));

        pen_x += scaled_advance;
    }
}

// =============================================================================
// Phase 3: Scene Emission
// =============================================================================

/// Build GlyphInstances from resolved CachedGlyphs and insert into the scene.
/// Skips glyphs with empty regions (spaces, zero-width characters).
fn emitGlyphsToScene(
    scene: *Scene,
    cached_glyphs: []const CachedGlyph,
    device_positions_x: []const f32,
    device_positions_y: []const f32,
    scale_factor: f32,
    color: Hsla,
    options: *RenderTextOptions,
) !void {
    std.debug.assert(cached_glyphs.len > 0);
    std.debug.assert(cached_glyphs.len == device_positions_x.len);
    std.debug.assert(cached_glyphs.len == device_positions_y.len);
    std.debug.assert(scale_factor > 0);

    for (cached_glyphs, device_positions_x, device_positions_y) |cached, device_x, device_y| {
        if (cached.region.width == 0 or cached.region.height == 0) continue;

        // Use cached atlas size for thread-safe UV calculation.
        // (Atlas may grow between glyph caching and UV calculation in multi-window.)
        const uv = cached.uv();

        const glyph_width = @as(f32, @floatFromInt(cached.region.width)) / scale_factor;
        const glyph_height = @as(f32, @floatFromInt(cached.region.height)) / scale_factor;

        // Snap to device pixel grid, then add raster offset, then convert back to logical.
        // This is how GPUI does it: floor(device_pos) + raster_offset.
        const glyph_x = (@floor(device_x) + @as(f32, @floatFromInt(cached.offset_x))) / scale_factor;
        const glyph_y = (@floor(device_y) - @as(f32, @floatFromInt(cached.offset_y))) / scale_factor;

        const instance = GlyphInstance.init(
            glyph_x,
            glyph_y,
            glyph_width,
            glyph_height,
            uv.u0,
            uv.v0,
            uv.u1,
            uv.v1,
            color,
        );

        if (options.isOrdered()) {
            try scene.insertGlyphWithOrder(instance, options.nextOrder(), options.clip_bounds);
        } else if (options.clipped) {
            try scene.insertGlyphClipped(instance);
        } else {
            try scene.insertGlyph(instance);
        }
    }
}

// =============================================================================
// Decoration Rendering
// =============================================================================

/// Render text decorations (underline, strikethrough) as scene quads.
fn renderDecorations(
    scene: *Scene,
    metrics: Metrics,
    x: f32,
    baseline_y: f32,
    text_width: f32,
    color: Hsla,
    options: *RenderTextOptions,
) !void {
    std.debug.assert(text_width >= 0);
    std.debug.assert(options.decoration.hasAny());

    const decoration_color = options.decoration_color orelse color;

    // Underline: rendered below the baseline at the font's underline position.
    if (options.decoration.underline) {
        // underline_position is negative (below baseline).
        const underline_y = baseline_y - metrics.underline_position;
        const thickness = @max(1.0, metrics.underline_thickness);

        var quad = Quad.filled(x, underline_y, text_width, thickness, decoration_color);
        if (options.isOrdered()) {
            quad.order = options.nextOrder();
            quad = quad.withClipBounds(options.clip_bounds);
            try scene.insertQuadWithOrder(quad);
        } else {
            try scene.insertQuad(quad);
        }
    }

    // Strikethrough: rendered through the middle of the x-height.
    if (options.decoration.strikethrough) {
        const strike_y = baseline_y - (metrics.x_height * 0.5);
        const thickness = @max(1.0, metrics.underline_thickness);

        var quad = Quad.filled(x, strike_y, text_width, thickness, decoration_color);
        if (options.isOrdered()) {
            quad.order = options.nextOrder();
            quad = quad.withClipBounds(options.clip_bounds);
            try scene.insertQuadWithOrder(quad);
        } else {
            try scene.insertQuad(quad);
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "size_scale calculation" {
    const testing = std.testing;

    // Test the size_scale formula used in renderText.
    const base_size: f32 = 16.0;

    // size_scale = font_size / base_size
    const scale_for_24 = 24.0 / base_size;
    const scale_for_32 = 32.0 / base_size;
    const scale_for_12 = 12.0 / base_size;
    const scale_for_16 = 16.0 / base_size; // Same as base = 1.0

    try testing.expectApproxEqAbs(@as(f32, 1.5), scale_for_24, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), scale_for_32, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.75), scale_for_12, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), scale_for_16, 0.001);
}
