//! WebFontFace - Font implementation using JavaScript Canvas 2D API
//!
//! Rasterizes glyphs via JS imports and provides metrics.
//! API matches CoreTextFace for cross-platform compatibility.

const std = @import("std");
const types = @import("../../types.zig");
const font_face_mod = @import("../../font_face.zig");

const Metrics = types.Metrics;
const GlyphMetrics = types.GlyphMetrics;
const RasterizedGlyph = types.RasterizedGlyph;
const SystemFont = types.SystemFont;
const FontFace = font_face_mod.FontFace;

// JS imports
extern "env" fn getFontMetrics(
    font_ptr: [*]const u8,
    font_len: u32,
    size: f32,
    out_ascent: *f32,
    out_descent: *f32,
    out_line_height: *f32,
) void;

extern "env" fn measureText(
    font_ptr: [*]const u8,
    font_len: u32,
    size: f32,
    text_ptr: [*]const u8,
    text_len: u32,
) f32;

extern "env" fn rasterizeGlyph(
    font_ptr: [*]const u8,
    font_len: u32,
    size: f32,
    codepoint: u32,
    out_buffer: [*]u8,
    buffer_size: u32,
    out_width: *u32,
    out_height: *u32,
    out_bearing_x: *f32,
    out_bearing_y: *f32,
    out_advance: *f32,
) void;

extern "env" fn rasterizeGlyphSubpixel(
    font_ptr: [*]const u8,
    font_len: u32,
    size: f32,
    codepoint: u32,
    subpixel_x: f32,
    subpixel_y: f32,
    out_buffer: [*]u8,
    buffer_size: u32,
    out_width: *u32,
    out_height: *u32,
    out_bearing_x: *f32,
    out_bearing_y: *f32,
    out_advance: *f32,
) void;

/// Web-backed font face (matches CoreTextFace API)
pub const WebFontFace = struct {
    /// Font name stored inline (no allocation needed)
    font_name_buf: [128]u8,
    font_name_len: u8,
    /// Cached metrics
    metrics: Metrics,

    /// Glyph advance cache - avoids repeated JS calls for common characters
    /// Direct-mapped cache for codepoints 0-255 (ASCII + Latin-1)
    advance_cache: [256]f32,
    /// Tracks which entries are valid (0 = not cached, 1 = cached)
    advance_cache_valid: [256]u8,

    const Self = @This();

    /// Load a font by name (CSS font-family)
    pub fn init(name: []const u8, size: f32) !Self {
        var self = Self{
            .font_name_buf = undefined,
            .font_name_len = 0,
            .metrics = undefined,
            .advance_cache = [_]f32{0} ** 256,
            .advance_cache_valid = [_]u8{0} ** 256,
        };

        // Copy font name to internal buffer
        const copy_len = @min(name.len, self.font_name_buf.len);
        @memcpy(self.font_name_buf[0..copy_len], name[0..copy_len]);
        self.font_name_len = @intCast(copy_len);

        // Get font metrics from JS
        var ascent: f32 = 0;
        var descent: f32 = 0;
        var line_height: f32 = 0;

        getFontMetrics(name.ptr, @intCast(name.len), size, &ascent, &descent, &line_height);

        // Measure cell width (for monospace detection)
        const m_width = measureText(name.ptr, @intCast(name.len), size, "M", 1);
        const i_width = measureText(name.ptr, @intCast(name.len), size, "i", 1);
        const is_monospace = @abs(m_width - i_width) < 0.1;

        self.metrics = .{
            .units_per_em = 1000,
            .ascender = ascent,
            .descender = descent,
            .line_gap = line_height - ascent - descent,
            .cap_height = ascent * 0.7,
            .x_height = ascent * 0.5,
            .underline_position = -(descent * 0.5),
            .underline_thickness = @max(1.0, size / 14.0),
            .line_height = line_height,
            .point_size = size,
            .is_monospace = is_monospace,
            .cell_width = m_width,
        };

        return self;
    }

    /// Load a system font
    pub fn initSystem(style: SystemFont, size: f32) !Self {
        const font_name = switch (style) {
            .monospace => "monospace",
            .sans_serif => "system-ui, -apple-system, sans-serif",
            .serif => "Georgia, serif",
            .system => "system-ui, -apple-system, sans-serif",
        };
        return init(font_name, size);
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    /// Get as the generic FontFace interface
    pub fn asFontFace(self: *Self) FontFace {
        return font_face_mod.createFontFace(Self, self);
    }

    fn fontName(self: *const Self) []const u8 {
        return self.font_name_buf[0..self.font_name_len];
    }

    /// Get glyph ID for a Unicode codepoint (on web we use codepoint directly)
    pub fn glyphIndex(_: *const Self, codepoint: u21) u16 {
        return @truncate(codepoint);
    }

    /// Get advance width for a glyph (fast path for text measurement)
    /// Uses cached value if available, otherwise measures via JS
    pub fn glyphAdvance(self: *Self, glyph_id: u16) f32 {
        // Check cache first for common characters (avoids JS call)
        if (glyph_id < 256 and self.advance_cache_valid[glyph_id] != 0) {
            return self.advance_cache[glyph_id];
        }

        // Cache miss - measure single character via JS
        var char_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(glyph_id), &char_buf) catch return 0;

        const name = self.fontName();
        const advance = measureText(name.ptr, @intCast(name.len), self.metrics.point_size, &char_buf, @intCast(len));

        // Cache for future lookups
        if (glyph_id < 256) {
            self.advance_cache[glyph_id] = advance;
            self.advance_cache_valid[glyph_id] = 1;
        }

        return advance;
    }

    /// Get metrics for a specific glyph
    pub fn glyphMetrics(self: *Self, glyph_id: u16) GlyphMetrics {
        // Check advance cache first for common characters (avoids JS call)
        if (glyph_id < 256 and self.advance_cache_valid[glyph_id] != 0) {
            return .{
                .glyph_id = glyph_id,
                .advance_x = self.advance_cache[glyph_id],
                .advance_y = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .width = 0,
                .height = 0,
            };
        }

        var buffer: [1]u8 = undefined;
        var width: u32 = 0;
        var height: u32 = 0;
        var bearing_x: f32 = 0;
        var bearing_y: f32 = 0;
        var advance: f32 = 0;

        const name = self.fontName();
        rasterizeGlyph(name.ptr, @intCast(name.len), self.metrics.point_size, glyph_id, &buffer, 0, &width, &height, &bearing_x, &bearing_y, &advance);

        // Cache the advance for future lookups
        if (glyph_id < 256) {
            self.advance_cache[glyph_id] = advance;
            self.advance_cache_valid[glyph_id] = 1;
        }

        return .{
            .glyph_id = glyph_id,
            .advance_x = advance,
            .advance_y = 0,
            .bearing_x = bearing_x,
            .bearing_y = bearing_y,
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        };
    }

    /// Render a glyph to a bitmap buffer
    pub inline fn renderGlyph(self: *const Self, glyph_id: u16, font_size: f32, scale: f32, buffer: []u8, buffer_size: u32) !RasterizedGlyph {
        return self.renderGlyphSubpixel(glyph_id, font_size, scale, 0.0, 0.0, buffer, buffer_size);
    }

    /// Render a glyph with subpixel positioning
    pub fn renderGlyphSubpixel(self: *const Self, glyph_id: u16, font_size: f32, scale: f32, subpixel_x: f32, subpixel_y: f32, buffer: []u8, buffer_size: u32) !RasterizedGlyph {
        var width: u32 = 0;
        var height: u32 = 0;
        var bearing_x: f32 = 0;
        var bearing_y: f32 = 0;
        var advance: f32 = 0;

        const size = font_size * scale;
        const name = self.fontName();

        // Use subpixel-aware rasterization
        rasterizeGlyphSubpixel(
            name.ptr,
            @intCast(name.len),
            size,
            glyph_id,
            subpixel_x,
            subpixel_y,
            buffer.ptr,
            buffer_size,
            &width,
            &height,
            &bearing_x,
            &bearing_y,
            &advance,
        );

        // advance from JS is at scaled size (font_size * scale), convert to logical units
        return .{
            .width = width,
            .height = height,
            .offset_x = @intFromFloat(bearing_x),
            .offset_y = @intFromFloat(-bearing_y),
            .advance_x = advance / scale,
            .is_color = false,
        };
    }
};
