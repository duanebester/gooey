//! Text rendering - converts shaped text to GPU glyph instances

const std = @import("std");
const platform = @import("../platform/mod.zig");
const scene_mod = @import("../scene/mod.zig");
const Scene = scene_mod.Scene;
const Quad = scene_mod.Quad;
const GlyphInstance = scene_mod.GlyphInstance;
const ContentMask = scene_mod.ContentMask;
const DrawOrder = scene_mod.DrawOrder;
const TextSystem = @import("text_system.zig").TextSystem;
const Hsla = @import("../core/mod.zig").Hsla;
const types = @import("types.zig");
const TextDecoration = types.TextDecoration;
const RenderStats = @import("../debug/render_stats.zig").RenderStats;

const is_wasm = platform.is_wasm;

const SUBPIXEL_VARIANTS_X = types.SUBPIXEL_VARIANTS_X;
const SUBPIXEL_VARIANTS_F: f32 = @floatFromInt(SUBPIXEL_VARIANTS_X);

pub const RenderTextOptions = struct {
    clipped: bool = true,
    decoration: TextDecoration = .{},
    /// Optional separate color for decorations (uses text color if null)
    decoration_color: ?Hsla = null,
    /// Optional stats for performance tracking (pass null to skip)
    stats: ?*RenderStats = null,
    /// Base draw order for z-ordering (0 = use scene's auto-ordering)
    base_order: DrawOrder = 0,
    /// Current draw order offset (incremented per glyph when ordered)
    current_order: *DrawOrder = undefined,
    /// Clip bounds for ordered rendering
    clip_bounds: ContentMask.ClipBounds = ContentMask.none.bounds,

    /// Check if this uses explicit ordering
    pub fn isOrdered(self: *const RenderTextOptions) bool {
        return self.base_order != 0;
    }

    /// Get next order and increment
    pub fn nextOrder(self: *RenderTextOptions) DrawOrder {
        const order = self.base_order + self.current_order.*;
        self.current_order.* += 1;
        return order;
    }
};

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
    // Assertions: validate font_size and scale_factor
    std.debug.assert(font_size > 0);
    std.debug.assert(font_size < 1000); // Reasonable upper bound
    std.debug.assert(scale_factor > 0);

    if (text.len == 0) return 0;

    // Calculate size scale for shaping (base metrics → requested size)
    // Shaped glyphs have advances/offsets at the base font size, scale them
    const size_scale = if (text_system.getMetrics()) |metrics|
        font_size / metrics.point_size
    else
        1.0;

    var shaped = try text_system.shapeText(text, options.stats);
    defer shaped.deinit(text_system.allocator);

    var pen_x = x;
    for (shaped.glyphs) |glyph| {
        // Scale offsets and advances from base size to requested size
        const scaled_x_offset = glyph.x_offset * size_scale;
        const scaled_y_offset = glyph.y_offset * size_scale;
        const scaled_advance = glyph.x_advance * size_scale;

        // Convert to device pixels
        const device_x = (pen_x + scaled_x_offset) * scale_factor;
        const device_y = (baseline_y + scaled_y_offset) * scale_factor;

        // Extract fractional part for subpixel variant selection
        const frac_x = device_x - @floor(device_x);
        const subpixel_x: u8 = @intFromFloat(@floor(frac_x * SUBPIXEL_VARIANTS_F));

        // Get cached glyph - use fallback font if specified
        const cached = if (glyph.font_ref) |fallback_font|
            try text_system.getGlyphFallback(fallback_font, glyph.glyph_id, font_size, subpixel_x, 0)
        else
            try text_system.getGlyphSubpixel(glyph.glyph_id, font_size, subpixel_x, 0);

        if (cached.region.width > 0 and cached.region.height > 0) {
            // Use cached atlas size for thread-safe UV calculation
            // (atlas may grow between glyph caching and UV calculation in multi-window)
            const uv = cached.uv();

            const glyph_w = @as(f32, @floatFromInt(cached.region.width)) / scale_factor;
            const glyph_h = @as(f32, @floatFromInt(cached.region.height)) / scale_factor;

            // Snap to device pixel grid, then add offset, then convert back to logical
            // This is how GPUI does it: floor(device_pos) + raster_offset
            const glyph_x = (@floor(device_x) + @as(f32, @floatFromInt(cached.offset_x))) / scale_factor;
            const glyph_y = (@floor(device_y) - @as(f32, @floatFromInt(cached.offset_y))) / scale_factor;

            const instance = GlyphInstance.init(glyph_x, glyph_y, glyph_w, glyph_h, uv.u0, uv.v0, uv.u1, uv.v1, color);

            if (options.isOrdered()) {
                try scene.insertGlyphWithOrder(instance, options.nextOrder(), options.clip_bounds);
            } else if (options.clipped) {
                try scene.insertGlyphClipped(instance);
            } else {
                try scene.insertGlyph(instance);
            }
        }

        pen_x += scaled_advance;
    }

    // Scale total width for decorations and return value
    const scaled_width = shaped.width * size_scale;

    // Render decorations if any
    if (options.decoration.hasAny()) {
        if (text_system.getMetrics()) |metrics| {
            const decoration_color = options.decoration_color orelse color;
            const text_width = scaled_width;

            // Underline
            if (options.decoration.underline) {
                // underline_position is negative (below baseline)
                const underline_y = baseline_y - metrics.underline_position;
                const thickness = @max(1.0, metrics.underline_thickness);

                var underline_quad = Quad.filled(
                    x,
                    underline_y,
                    text_width,
                    thickness,
                    decoration_color,
                );
                if (options.isOrdered()) {
                    underline_quad.order = options.nextOrder();
                    underline_quad = underline_quad.withClipBounds(options.clip_bounds);
                    try scene.insertQuadWithOrder(underline_quad);
                } else {
                    try scene.insertQuad(underline_quad);
                }
            }

            // Strikethrough
            if (options.decoration.strikethrough) {
                // strikethrough goes through the middle of x-height
                const strike_y = baseline_y - (metrics.x_height * 0.5);
                const thickness = @max(1.0, metrics.underline_thickness);

                var strike_quad = Quad.filled(
                    x,
                    strike_y,
                    text_width,
                    thickness,
                    decoration_color,
                );
                if (options.isOrdered()) {
                    strike_quad.order = options.nextOrder();
                    strike_quad = strike_quad.withClipBounds(options.clip_bounds);
                    try scene.insertQuadWithOrder(strike_quad);
                } else {
                    try scene.insertQuad(strike_quad);
                }
            }
        }
    }

    return scaled_width;
}

// =============================================================================
// Tests
// =============================================================================

test "size_scale calculation" {
    const testing = std.testing;

    // Test the size_scale formula used in renderText
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
