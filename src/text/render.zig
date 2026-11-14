//! Text placement: shaped text to glyph quads in the glyph atlas.
//!
//! `placeText` runs in three phases, optimized for minimal lock contention:
//!   Phase 1 — Compute device-pixel positions and subpixel offsets (no lock).
//!   Phase 2 — Batch-resolve all glyphs from the cache under a single mutex lock.
//!   Phase 3 — Place each glyph and hand it to the caller's sink (no lock).
//!
//! The batch glyph resolve (Phase 2) eliminates N-1 mutex lock/unlock pairs per
//! text run compared to the per-glyph locking pattern, saving ~500–2000 ns for
//! a 50-character string on macOS (atomic CAS + memory fence per lock).

const std = @import("std");
const platform = @import("../platform/mod.zig");
const text_system_mod = @import("text_system.zig");
const TextSystem = text_system_mod.TextSystem;
const ShapedRunCache = text_system_mod.ShapedRunCache;
const CachedGlyph = text_system_mod.CachedGlyph;
const ShapedGlyph = types.ShapedGlyph;
const types = @import("types.zig");
const FontVariant = types.FontVariant;
const FontFamily = types.FontFamily;

const is_wasm = platform.is_wasm;

const SUBPIXEL_VARIANTS_X = types.SUBPIXEL_VARIANTS_X;
const SUBPIXEL_VARIANTS_F: f32 = @floatFromInt(SUBPIXEL_VARIANTS_X);

/// Maximum glyphs per text run.  Matches ShapedRunCache capacity.
const MAX_GLYPHS_PER_RUN: u32 = ShapedRunCache.MAX_GLYPHS_PER_ENTRY;

// WASM stack budget check (rule #14): a run's shaped-glyph buffer and the four
// batch buffers in `placeBatches` are sized at MAX_GLYPHS_PER_RUN. Assert the
// combined footprint stays under 16 KB so it fits comfortably within WASM's
// 1 MB stack even in deep call chains (tick → emit → placeText).
comptime {
    const frame_bytes = MAX_GLYPHS_PER_RUN * (@sizeOf(ShapedGlyph) + @sizeOf(f32) + @sizeOf(f32) + @sizeOf(u8) + @sizeOf(CachedGlyph));
    std.debug.assert(frame_bytes <= 16384);
}

// =============================================================================
// Batches
// =============================================================================

/// Where a shaped run starts, and how its base-size advances scale.
const RunOrigin = struct {
    x: f32,
    baseline_y: f32,
    size_scale: f32,
    scale_factor: f32,
};

/// Resolve `glyphs` and hand them to `sink.batch` in batches of at most
/// `MAX_GLYPHS_PER_RUN`, the size of the stack buffers, carrying the pen
/// across batches. A run of any length is placed exactly as one batch would
/// place it, and the glyph cache lock is taken once per batch. Shaping is
/// not split, so kerning and ligatures across a batch edge are kept.
fn placeBatches(
    text_system: *TextSystem,
    family: FontFamily,
    variant: FontVariant,
    font_size: f32,
    glyphs: []const ShapedGlyph,
    origin: RunOrigin,
    sink: anytype,
) !void {
    std.debug.assert(glyphs.len > 0);
    std.debug.assert(origin.scale_factor > 0);
    var device_x: [MAX_GLYPHS_PER_RUN]f32 = undefined;
    var device_y: [MAX_GLYPHS_PER_RUN]f32 = undefined;
    var subpixel_x: [MAX_GLYPHS_PER_RUN]u8 = undefined;
    var cached: [MAX_GLYPHS_PER_RUN]CachedGlyph = undefined;
    const batch_count = @divFloor(glyphs.len - 1, MAX_GLYPHS_PER_RUN) + 1;
    var pen_x = origin.x;
    var start: usize = 0;
    for (0..batch_count) |_| {
        const end = @min(glyphs.len, start + MAX_GLYPHS_PER_RUN);
        const batch = glyphs[start..end];
        const count = batch.len;
        std.debug.assert(count > 0);
        std.debug.assert(count <= MAX_GLYPHS_PER_RUN);
        pen_x = computeGlyphDevicePositions(
            batch,
            pen_x,
            origin.baseline_y,
            origin.size_scale,
            origin.scale_factor,
            device_x[0..count],
            device_y[0..count],
            subpixel_x[0..count],
        );
        try text_system.resolveGlyphBatch(
            family,
            batch,
            variant,
            font_size,
            subpixel_x[0..count],
            cached[0..count],
        );
        try sink.batch(cached[0..count], device_x[0..count], device_y[0..count]);
        start = end;
    }
    std.debug.assert(start == glyphs.len);
}

/// `placeText`'s batches go to its caller's sink one glyph at a time.
fn GlyphSink(comptime Sink: type) type {
    return struct {
        sink: Sink,
        scale_factor: f32,

        fn batch(
            self: *const @This(),
            glyphs: []const CachedGlyph,
            xs: []const f32,
            ys: []const f32,
        ) !void {
            std.debug.assert(glyphs.len == xs.len);
            std.debug.assert(glyphs.len == ys.len);
            const scale_factor = self.scale_factor;
            for (glyphs, xs, ys) |glyph, dx, dy| {
                const placed = placeGlyph(glyph, dx, dy, scale_factor) orelse continue;
                self.sink.glyph(placed);
            }
        }
    };
}

// =============================================================================
// Phase 1: Device Position Computation
// =============================================================================

/// Compute device-pixel coordinates and subpixel X offsets for each glyph,
/// returning the pen after the last advance, where the next batch starts.
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
) f32 {
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
    return pen_x;
}

// =============================================================================
// Phase 3: Glyph Placement
// =============================================================================

/// One glyph `placeText` placed: its quad in logical pixels and its glyph
/// atlas rectangle, each UV edge in the normalized 0..1 range.
pub const PlacedGlyph = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    uv_left: f32,
    uv_top: f32,
    uv_right: f32,
    uv_bottom: f32,
};

/// The placement of one resolved glyph, or null for an empty region
/// (spaces, zero-width characters). Snaps to the device pixel grid, adds the
/// raster offset, and converts back to logical pixels, as GPUI does:
/// floor(device_pos) + raster_offset.
fn placeGlyph(cached: CachedGlyph, device_x: f32, device_y: f32, scale_factor: f32) ?PlacedGlyph {
    std.debug.assert(scale_factor > 0);
    if (cached.region.width == 0 or cached.region.height == 0) return null;

    // Use cached atlas size for thread-safe UV calculation.
    // (Atlas may grow between glyph caching and UV calculation in multi-window.)
    const uv = cached.uv();
    std.debug.assert(uv.u0 >= 0);
    std.debug.assert(uv.u0 <= 1);
    std.debug.assert(uv.v0 >= 0);
    std.debug.assert(uv.v0 <= 1);
    std.debug.assert(uv.u1 >= 0);
    std.debug.assert(uv.u1 <= 1);
    std.debug.assert(uv.v1 >= 0);
    std.debug.assert(uv.v1 <= 1);
    const placed = PlacedGlyph{
        .x = (@floor(device_x) + @as(f32, @floatFromInt(cached.offset_x))) / scale_factor,
        .y = (@floor(device_y) - @as(f32, @floatFromInt(cached.offset_y))) / scale_factor,
        .width = @as(f32, @floatFromInt(cached.region.width)) / scale_factor,
        .height = @as(f32, @floatFromInt(cached.region.height)) / scale_factor,
        .uv_left = uv.u0,
        .uv_top = uv.v0,
        .uv_right = uv.u1,
        .uv_bottom = uv.v1,
    };
    std.debug.assert(placed.width > 0);
    std.debug.assert(placed.height > 0);
    return placed;
}

// =============================================================================
// Public API
// =============================================================================

/// Shape `text` and hand each placed glyph to `sink.glyph(placed)`, in
/// order, returning the run's width. Glyphs land where the 0.3.1 runtime
/// placed them. The glyph cache may rasterize on a miss; the shaped run is
/// copied into a stack
/// buffer, so only a shape-cache miss uses the text system's allocator.
pub fn placeText(
    text_system: *TextSystem,
    text: []const u8,
    x: f32,
    baseline_y: f32,
    scale_factor: f32,
    font_size: f32,
    family: FontFamily,
    variant: FontVariant,
    sink: anytype,
) !f32 {
    std.debug.assert(font_size > 0);
    std.debug.assert(scale_factor > 0);
    if (text.len == 0) return 0;
    if (text_system.getMetrics() == null) return error.NoFontLoaded;
    // Each family scales by its own regular face (`loadMonoFont`).
    const metrics = text_system.getMetricsFor(family);
    const size_scale = font_size / metrics.point_size;

    var glyph_buf: [MAX_GLYPHS_PER_RUN]ShapedGlyph = undefined;
    var shaped = try text_system.shapeTextInto(family, text, variant, null, &glyph_buf);
    defer if (shaped.owned) shaped.deinit(text_system.run_allocator);
    if (shaped.glyphs.len == 0) return shaped.width * size_scale;
    const batch_sink = GlyphSink(@TypeOf(sink)){ .sink = sink, .scale_factor = scale_factor };
    try placeBatches(text_system, family, variant, font_size, shaped.glyphs, .{
        .x = x,
        .baseline_y = baseline_y,
        .size_scale = size_scale,
        .scale_factor = scale_factor,
    }, &batch_sink);
    return shaped.width * size_scale;
}
