//! CoreText font face implementation
//!
//! Implements the FontFace interface using Apple's CoreText framework.

const std = @import("std");
const ct = @import("bindings.zig");
const types = @import("../../types.zig");
const font_face_mod = @import("../../font_face.zig");

const Metrics = types.Metrics;
const GlyphMetrics = types.GlyphMetrics;
const RasterizedGlyph = types.RasterizedGlyph;
const SystemFont = types.SystemFont;
const FontFace = font_face_mod.FontFace;

/// CoreText-backed font face
pub const CoreTextFace = struct {
    /// CoreText font reference
    ct_font: ct.CTFontRef,
    /// Cached metrics
    metrics: Metrics,

    const Self = @This();

    /// Load a font by name (e.g., "SF Mono", "SF Pro", "Helvetica Neue")
    pub fn init(name: []const u8, size: f32) !Self {
        std.debug.assert(size > 0);
        std.debug.assert(name.len > 0);

        const cf_name = ct.createCFStringRuntime(name) orelse return error.InvalidFontName;
        defer ct.release(cf_name);

        const font = ct.CTFontCreateWithName(cf_name, @floatCast(size), null) orelse
            return error.FontNotFound;

        return Self{
            .ct_font = font,
            .metrics = computeMetrics(font, size),
        };
    }

    /// Load a system font
    pub fn initSystem(style: SystemFont, size: f32) !Self {
        std.debug.assert(size > 0);

        const font = switch (style) {
            .monospace => blk: {
                // Use system API for monospace - SF Mono needs this to work correctly
                const f = ct.CTFontCreateUIFontForLanguage(
                    ct.kCTFontUIFontUserFixedPitch,
                    @floatCast(size),
                    null,
                ) orelse return error.FontNotFound;
                break :blk f;
            },
            else => blk: {
                const name = switch (style) {
                    .monospace => unreachable,
                    .sans_serif => "SF Pro",
                    .serif => "New York",
                    .system => ".AppleSystemUIFont",
                };
                const cf_name = ct.createCFStringRuntime(name) orelse return error.InvalidFontName;
                defer ct.release(cf_name);
                break :blk ct.CTFontCreateWithName(cf_name, @floatCast(size), null) orelse
                    return error.FontNotFound;
            },
        };

        return Self{
            .ct_font = font,
            .metrics = computeMetrics(font, size),
        };
    }

    pub fn deinit(self: *Self) void {
        ct.release(self.ct_font);
        self.* = undefined;
    }

    /// Get as the generic FontFace interface
    pub fn asFontFace(self: *Self) FontFace {
        return font_face_mod.createFontFace(Self, self);
    }

    /// Get glyph ID for a Unicode codepoint
    pub fn glyphIndex(self: *const Self, codepoint: u21) u16 {
        var utf16_buf: [2]ct.UniChar = undefined;
        var count: usize = 1;

        if (codepoint <= 0xFFFF) {
            utf16_buf[0] = @intCast(codepoint);
        } else {
            const adjusted = codepoint - 0x10000;
            utf16_buf[0] = @intCast(0xD800 + (adjusted >> 10));
            utf16_buf[1] = @intCast(0xDC00 + (adjusted & 0x3FF));
            count = 2;
        }

        var glyph: ct.CGGlyph = 0;
        const success = ct.CTFontGetGlyphsForCharacters(
            self.ct_font,
            &utf16_buf,
            @ptrCast(&glyph),
            @intCast(count),
        );

        return if (success) glyph else 0;
    }

    /// Get advance width for a glyph (fast path for text measurement)
    /// Uses CTFontGetAdvancesForGlyphs which is optimized for this use case
    pub fn glyphAdvance(self: *const Self, glyph_id: u16) f32 {
        var glyph = glyph_id;
        var advance: ct.CGSize = undefined;
        _ = ct.CTFontGetAdvancesForGlyphs(
            self.ct_font,
            .horizontal,
            @ptrCast(&glyph),
            @ptrCast(&advance),
            1,
        );
        return @floatCast(advance.width);
    }

    /// Get metrics for a specific glyph
    pub fn glyphMetrics(self: *const Self, glyph_id: u16) GlyphMetrics {
        return getGlyphMetricsFromFont(self.ct_font, glyph_id);
    }

    /// Render a glyph with subpixel positioning
    /// subpixel_x and subpixel_y are in range [0.0, 1.0)
    pub fn renderGlyphSubpixel(
        self: *const Self,
        glyph_id: u16,
        scale: f32,
        subpixel_x: f32,
        subpixel_y: f32,
        buffer: []u8,
        buffer_size: u32,
    ) !RasterizedGlyph {
        std.debug.assert(scale > 0);
        std.debug.assert(subpixel_x >= 0 and subpixel_x < 1.0);
        std.debug.assert(subpixel_y >= 0 and subpixel_y < 1.0);

        return renderGlyphInternal(
            self.ct_font,
            glyph_id,
            self.metrics.point_size,
            scale,
            subpixel_x,
            subpixel_y,
            buffer,
            buffer_size,
        );
    }

    /// Render a glyph from any CTFontRef (for fallback fonts)
    /// This is a static method that can render glyphs from fonts not owned by this face
    pub fn renderGlyphFromFont(
        ct_font: ct.CTFontRef,
        glyph_id: u16,
        scale: f32,
        subpixel_x: f32,
        subpixel_y: f32,
        buffer: []u8,
        buffer_size: u32,
    ) !RasterizedGlyph {
        std.debug.assert(scale > 0);
        std.debug.assert(subpixel_x >= 0 and subpixel_x < 1.0);
        std.debug.assert(subpixel_y >= 0 and subpixel_y < 1.0);

        const font_size: f32 = @floatCast(ct.CTFontGetSize(ct_font));
        return renderGlyphInternal(
            ct_font,
            glyph_id,
            font_size,
            scale,
            subpixel_x,
            subpixel_y,
            buffer,
            buffer_size,
        );
    }

    fn computeMetrics(font: ct.CTFontRef, size: f32) Metrics {
        const ascender: f32 = @floatCast(ct.CTFontGetAscent(font));
        const descender: f32 = @floatCast(ct.CTFontGetDescent(font));
        const line_gap: f32 = @floatCast(ct.CTFontGetLeading(font));
        const traits = ct.CTFontGetSymbolicTraits(font);
        const is_monospace = (traits & ct.kCTFontTraitMonoSpace) != 0;

        var test_chars = [_]ct.UniChar{ 'M', '0' };
        var glyphs: [2]ct.CGGlyph = undefined;
        _ = ct.CTFontGetGlyphsForCharacters(font, &test_chars, &glyphs, 2);

        var advances: [2]ct.CGSize = undefined;
        _ = ct.CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, 2);

        const cell_width: f32 = @floatCast(@max(advances[0].width, advances[1].width));

        return .{
            .units_per_em = ct.CTFontGetUnitsPerEm(font),
            .ascender = ascender,
            .descender = descender,
            .line_gap = line_gap,
            .cap_height = @floatCast(ct.CTFontGetCapHeight(font)),
            .x_height = @floatCast(ct.CTFontGetXHeight(font)),
            .underline_position = @floatCast(ct.CTFontGetUnderlinePosition(font)),
            .underline_thickness = @floatCast(ct.CTFontGetUnderlineThickness(font)),
            .line_height = ascender + descender + line_gap,
            .point_size = size,
            .is_monospace = is_monospace,
            .cell_width = cell_width,
        };
    }
};

// =============================================================================
// Shared Internal Functions
// =============================================================================

/// Get glyph metrics from any CTFontRef
fn getGlyphMetricsFromFont(ct_font: ct.CTFontRef, glyph_id: u16) GlyphMetrics {
    var glyph = glyph_id;
    var advance: ct.CGSize = undefined;
    var bounds: ct.CGRect = undefined;

    _ = ct.CTFontGetAdvancesForGlyphs(
        ct_font,
        .horizontal,
        @ptrCast(&glyph),
        @ptrCast(&advance),
        1,
    );

    _ = ct.CTFontGetBoundingRectsForGlyphs(
        ct_font,
        .horizontal,
        @ptrCast(&glyph),
        @ptrCast(&bounds),
        1,
    );

    return .{
        .glyph_id = glyph_id,
        .advance_x = @floatCast(advance.width),
        .advance_y = @floatCast(advance.height),
        .bearing_x = @floatCast(bounds.origin.x),
        .bearing_y = @floatCast(bounds.origin.y + bounds.size.height),
        .width = @floatCast(bounds.size.width),
        .height = @floatCast(bounds.size.height),
    };
}

/// Internal glyph rendering implementation shared by both public methods
/// Renders a glyph from any CTFontRef with subpixel positioning
fn renderGlyphInternal(
    ct_font: ct.CTFontRef,
    glyph_id: u16,
    font_size: f32,
    scale: f32,
    subpixel_x: f32,
    subpixel_y: f32,
    buffer: []u8,
    buffer_size: u32,
) !RasterizedGlyph {
    // Assertions for input validation
    std.debug.assert(scale > 0);
    std.debug.assert(font_size > 0);
    std.debug.assert(buffer.len >= buffer_size);

    const glyph_metrics = getGlyphMetricsFromFont(ct_font, glyph_id);
    const padding: u32 = 2;
    const padding_f: f32 = @floatFromInt(padding);

    // Handle empty glyphs (spaces, etc.)
    if (glyph_metrics.width < 1 or glyph_metrics.height < 1) {
        return RasterizedGlyph{
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .advance_x = glyph_metrics.advance_x,
            .is_color = false,
        };
    }

    // Raster bounds in physical pixels (like GPUI's raster_bounds)
    // bearing_x/bearing_y are the glyph origin relative to pen position
    const raster_left = @floor(glyph_metrics.bearing_x * scale);
    const raster_top = @floor(glyph_metrics.bearing_y * scale);
    const raster_right = @ceil((glyph_metrics.bearing_x + glyph_metrics.width) * scale);
    const raster_bottom = @ceil((glyph_metrics.bearing_y - glyph_metrics.height) * scale);

    // Bitmap size with padding for antialiasing
    var width: u32 = @intFromFloat(raster_right - raster_left + padding_f * 2);
    var height: u32 = @intFromFloat(raster_top - raster_bottom + padding_f * 2);

    // Add extra pixel when subpixel variant is non-zero
    if (subpixel_x > 0) width += 1;
    if (subpixel_y > 0) height += 1;

    const clamped_w = @min(width, buffer_size);
    const clamped_h = @min(height, buffer_size);

    std.debug.assert(clamped_w > 0);
    std.debug.assert(clamped_h > 0);

    // Create CoreGraphics context
    const color_space = ct.CGColorSpaceCreateDeviceGray() orelse return error.GraphicsError;
    defer ct.CGColorSpaceRelease(color_space);

    const context = ct.CGBitmapContextCreate(
        buffer.ptr,
        clamped_w,
        clamped_h,
        8,
        clamped_w,
        color_space,
        ct.kCGImageAlphaNone,
    ) orelse return error.GraphicsError;
    defer ct.CGContextRelease(context);

    // Configure rendering for quality
    ct.CGContextSetAllowsAntialiasing(context, true);
    ct.CGContextSetShouldAntialias(context, true);
    ct.CGContextSetAllowsFontSmoothing(context, true);
    ct.CGContextSetShouldSmoothFonts(context, true);
    ct.CGContextSetGrayFillColor(context, 1.0, 1.0);
    ct.CGContextSetAllowsFontSubpixelPositioning(context, true);
    ct.CGContextSetShouldSubpixelPositionFonts(context, true);
    ct.CGContextSetAllowsFontSubpixelQuantization(context, false);
    ct.CGContextSetShouldSubpixelQuantizeFonts(context, false);

    // Move origin to account for glyph bounds (like GPUI does)
    // The context origin is bottom-left, Y increases upward
    ct.CGContextTranslateCTM(
        context,
        -raster_left + padding_f + subpixel_x,
        -raster_bottom + padding_f + subpixel_y,
    );
    ct.CGContextSetTextMatrix(context, ct.CGAffineTransform.identity);

    // Create scaled font for rasterization
    const scaled_font = ct.CTFontCreateCopyWithAttributes(
        ct_font,
        font_size * scale,
        null,
        null,
    ) orelse return error.FontError;
    defer ct.release(scaled_font);

    // Draw glyph at origin - the context translation positions it correctly
    var glyph = glyph_id;
    const position = ct.CGPoint{ .x = 0, .y = 0 };
    ct.CTFontDrawGlyphs(scaled_font, @ptrCast(&glyph), @ptrCast(&position), 1, context);

    // Return offsets directly from font metrics - no bitmap scanning needed
    // offset_x: where to place bitmap left edge relative to pen (physical pixels)
    // offset_y: where to place bitmap top edge relative to baseline (physical pixels, positive = above)
    return RasterizedGlyph{
        .width = clamped_w,
        .height = clamped_h,
        .offset_x = @intFromFloat(raster_left - padding_f),
        .offset_y = @intFromFloat(raster_top + padding_f),
        .advance_x = glyph_metrics.advance_x,
        .is_color = false,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "load system font" {
    var face = try CoreTextFace.initSystem(.monospace, 14.0);
    defer face.deinit();

    try std.testing.expect(face.metrics.ascender > 0);
    try std.testing.expect(face.metrics.line_height > 0);
}
