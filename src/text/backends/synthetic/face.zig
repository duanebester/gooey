//! Synthetic font face: deterministic metrics and box glyphs, no font files.
//!
//! Goldens (`src/testing/goldens/`) compare paint and hit records across
//! machines, and on a real backend every glyph position depends on which
//! sans-serif the host resolves (DejaVu, Noto, SF Pro). This face derives
//! every metric from the point size and the codepoint alone, so a golden
//! captured on Linux matches one replayed on macOS bit for bit.
//!
//! Advances differ by character class rather than being one constant: a
//! single advance would hide off-by-one errors in cursor placement, wrapping,
//! and measurement, because every string of the same length would measure the
//! same. Bold faces are 10% wider so a measurement taken with the wrong face
//! shows up as a different width.

const std = @import("std");
const types = @import("../../types.zig");
const font_face_mod = @import("../../font_face.zig");

const assert = std.debug.assert;

const Metrics = types.Metrics;
const GlyphMetrics = types.GlyphMetrics;
const RasterizedGlyph = types.RasterizedGlyph;
const SystemFont = types.SystemFont;
const FontVariant = types.FontVariant;
const FontFace = font_face_mod.FontFace;

/// Largest point size the face accepts, matching the text system's bound.
const point_size_max: f32 = 1000;

pub const SyntheticFace = struct {
    metrics: Metrics,
    /// Multiplier on every advance: 1.1 for semibold and heavier, else 1.
    width_scale: f32,

    const Self = @This();

    /// The family name is ignored: every family is the same synthetic face.
    pub fn init(name: []const u8, size: f32, variant: FontVariant) !Self {
        assert(name.len > 0);
        assert(size > 0);
        return initSized(size, variant);
    }

    pub fn initSystem(style: SystemFont, size: f32, variant: FontVariant) !Self {
        _ = style;
        assert(size > 0);
        return initSized(size, variant);
    }

    fn initSized(size: f32, variant: FontVariant) Self {
        assert(size > 0);
        assert(size < point_size_max);
        const heavy = @backingInt(variant.weight()) >= @backingInt(types.FontWeight.semibold);
        const self = Self{
            .metrics = .{
                .units_per_em = 1000,
                .ascender = size * 0.8,
                .descender = size * 0.2,
                .line_gap = size * 0.2,
                .cap_height = size * 0.7,
                .x_height = size * 0.5,
                .underline_position = -size * 0.1,
                .underline_thickness = @max(1.0, size / 14.0),
                .line_height = size * 1.2,
                .point_size = size,
                .is_monospace = false,
                .cell_width = size * 0.6,
            },
            .width_scale = if (heavy) 1.1 else 1.0,
        };
        assert(self.metrics.line_height > self.metrics.ascender);
        assert(self.width_scale >= 1.0);
        return self;
    }

    pub fn deinit(self: *Self) void {
        assert(self.metrics.point_size > 0);
        self.* = undefined;
    }

    pub fn asFontFace(self: *Self) FontFace {
        assert(self.metrics.point_size > 0);
        return font_face_mod.createFontFace(Self, self);
    }

    /// The glyph id is the codepoint; codepoints past the BMP map to 0.
    pub fn glyphIndex(self: *const Self, codepoint: u21) u16 {
        assert(self.metrics.point_size > 0);
        if (codepoint <= std.math.maxInt(u16)) return @intCast(codepoint);
        return 0;
    }

    pub fn glyphAdvance(self: *const Self, glyph_id: u16) f32 {
        const advance = self.metrics.point_size * self.width_scale * advanceEm(glyph_id);
        assert(advance >= 0);
        return advance;
    }

    pub fn glyphMetrics(self: *const Self, glyph_id: u16) GlyphMetrics {
        const advance = self.glyphAdvance(glyph_id);
        assert(advance >= 0);
        return .{
            .glyph_id = glyph_id,
            .advance_x = advance,
            .advance_y = 0,
            .bearing_x = 0,
            .bearing_y = self.metrics.cap_height,
            .width = advance * 0.8,
            .height = self.metrics.cap_height,
        };
    }

    /// Rasterize a solid box covering 80% of the advance and the cap height.
    /// Subpixel offsets are ignored, so every variant has the same pixels.
    pub fn renderGlyphSubpixel(
        self: *const Self,
        glyph_id: u16,
        font_size: f32,
        scale: f32,
        subpixel_x: f32,
        subpixel_y: f32,
        buffer: []u8,
        buffer_size: u32,
    ) !RasterizedGlyph {
        assert(font_size > 0);
        assert(scale > 0);
        assert(subpixel_x >= 0 and subpixel_x < 1.0);
        assert(subpixel_y >= 0 and subpixel_y < 1.0);

        const ratio = font_size / self.metrics.point_size;
        const advance = self.glyphAdvance(glyph_id) * ratio;
        const width: u32 = @intFromFloat(@ceil(advance * 0.8 * scale));
        const height: u32 = @intFromFloat(@ceil(self.metrics.cap_height * ratio * scale));
        const byte_count = @as(u64, width) * height;
        if (byte_count > buffer_size) return error.GlyphTooLarge;
        assert(byte_count <= buffer.len);

        @memset(buffer[0..@intCast(byte_count)], 0xFF);
        return .{
            .width = width,
            .height = height,
            .offset_x = 0,
            .offset_y = @intCast(height),
            .advance_x = advance,
            .is_color = false,
        };
    }
};

/// Advance in ems by character class. Whitespace and the glyph for a
/// missing character still advance, so no input measures zero by accident.
fn advanceEm(glyph_id: u16) f32 {
    if (glyph_id == ' ') return 0.25;
    if (glyph_id >= '0' and glyph_id <= '9') return 0.55;
    if (glyph_id >= 'A' and glyph_id <= 'Z') {
        if (glyph_id == 'I') return 0.3;
        if (glyph_id == 'M' or glyph_id == 'W') return 0.85;
        return 0.65;
    }
    if (glyph_id >= 'a' and glyph_id <= 'z') {
        if (glyph_id == 'i' or glyph_id == 'j' or glyph_id == 'l') return 0.25;
        if (glyph_id == 'm' or glyph_id == 'w') return 0.8;
        return 0.5;
    }
    if (glyph_id < 0x80) return 0.35; // Punctuation and symbols.
    return 0.7; // Everything past ASCII.
}

test "synthetic advances differ by class and bold is wider" {
    // Goal: the properties goldens rely on. A narrow and a wide glyph must
    // differ, so cursor and wrap errors change positions; bold must be wider,
    // so measuring with the wrong face changes widths.
    var regular = try SyntheticFace.initSystem(.sans_serif, 20, .regular);
    var bold = try SyntheticFace.initSystem(.sans_serif, 20, .bold);
    try std.testing.expect(regular.glyphAdvance('i') < regular.glyphAdvance('m'));
    try std.testing.expectEqual(@as(f32, 5), regular.glyphAdvance(' '));
    try std.testing.expect(bold.glyphAdvance('m') > regular.glyphAdvance('m'));
    try std.testing.expectEqual(@as(u16, 0), regular.glyphIndex(0x1F600));

    var buffer: [64 * 64]u8 = undefined;
    const glyph = try regular.renderGlyphSubpixel('m', 20, 2, 0, 0, &buffer, buffer.len);
    try std.testing.expectEqual(@as(u32, 26), glyph.width);
    try std.testing.expectEqual(@as(u32, 28), glyph.height);
    try std.testing.expectError(error.GlyphTooLarge, regular.renderGlyphSubpixel(
        'm',
        20,
        4,
        0,
        0,
        &buffer,
        16,
    ));
}
