//! Font face abstraction - wraps CoreText font for metrics and glyph access

const std = @import("std");
const ct = @import("coretext.zig");

/// Font metrics computed once at load time
pub const Metrics = struct {
    /// Design units per em
    units_per_em: u32,
    /// Ascent in points (positive, above baseline)
    ascender: f32,
    /// Descent in points (positive, below baseline)
    descender: f32,
    /// Line gap / leading
    line_gap: f32,
    /// Height of capital letters
    cap_height: f32,
    /// Height of lowercase 'x'
    x_height: f32,
    /// Underline position (negative = below baseline)
    underline_position: f32,
    /// Underline thickness
    underline_thickness: f32,
    /// Total line height (ascender + descender + line_gap)
    line_height: f32,
    /// Font size in points
    point_size: f32,
    /// Is this a monospace font?
    is_monospace: bool,
    /// Cell width for monospace fonts (advance of 'M')
    cell_width: f32,
};

/// Glyph metrics for a single glyph
pub const GlyphMetrics = struct {
    /// Glyph ID (0 = missing glyph)
    glyph_id: u16,
    /// Horizontal advance
    advance_x: f32,
    /// Vertical advance (usually 0 for horizontal text)
    advance_y: f32,
    /// Bounding box origin X (left bearing)
    bearing_x: f32,
    /// Bounding box origin Y (top bearing from baseline)
    bearing_y: f32,
    /// Bounding box width
    width: f32,
    /// Bounding box height
    height: f32,
};

/// A font face loaded from the system
pub const Face = struct {
    /// CoreText font reference
    ct_font: ct.CTFontRef,
    /// Cached metrics
    metrics: Metrics,

    const Self = @This();

    /// Load a font by name (e.g., "Menlo", "SF Pro", "Helvetica Neue")
    pub fn init(name: []const u8, size: f32) !Self {
        const cf_name = ct.createCFStringRuntime(name) orelse return error.InvalidFontName;
        defer ct.release(cf_name);

        const font = ct.CTFontCreateWithName(cf_name, @floatCast(size), null) orelse
            return error.FontNotFound;

        return Self{
            .ct_font = font,
            .metrics = computeMetrics(font, size),
        };
    }

    /// Load a font by PostScript name for precise matching
    pub fn initExact(postscript_name: []const u8, size: f32) !Self {
        return init(postscript_name, size);
    }

    /// Create with a known font (e.g., system default monospace)
    pub fn initSystem(style: SystemFont, size: f32) !Self {
        const name = switch (style) {
            .monospace => "Menlo",
            .sans_serif => "Helvetica Neue",
            .serif => "Times New Roman",
            .system => ".AppleSystemUIFont",
        };
        return init(name, size);
    }

    pub const SystemFont = enum {
        monospace,
        sans_serif,
        serif,
        system,
    };

    pub fn deinit(self: *Self) void {
        ct.release(self.ct_font);
        self.* = undefined;
    }

    /// Get glyph ID for a Unicode codepoint
    pub fn glyphIndex(self: *const Self, codepoint: u21) u16 {
        // Convert codepoint to UTF-16
        var utf16_buf: [2]ct.UniChar = undefined;
        var count: usize = 1;

        if (codepoint <= 0xFFFF) {
            utf16_buf[0] = @intCast(codepoint);
        } else {
            // Surrogate pair for codepoints > 0xFFFF
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

        return if (success) glyph else 0; // 0 is typically .notdef glyph
    }

    /// Get metrics for a specific glyph
    pub fn glyphMetrics(self: *const Self, glyph_id: u16) GlyphMetrics {
        var glyph = glyph_id;
        var advance: ct.CGSize = undefined;
        var bounds: ct.CGRect = undefined;

        _ = ct.CTFontGetAdvancesForGlyphs(
            self.ct_font,
            .horizontal,
            @ptrCast(&glyph),
            @ptrCast(&advance),
            1,
        );

        _ = ct.CTFontGetBoundingRectsForGlyphs(
            self.ct_font,
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

    /// Get glyph metrics for a codepoint (convenience)
    pub fn codepointMetrics(self: *const Self, codepoint: u21) GlyphMetrics {
        return self.glyphMetrics(self.glyphIndex(codepoint));
    }

    fn computeMetrics(font: ct.CTFontRef, size: f32) Metrics {
        const ascender: f32 = @floatCast(ct.CTFontGetAscent(font));
        const descender: f32 = @floatCast(ct.CTFontGetDescent(font));
        const line_gap: f32 = @floatCast(ct.CTFontGetLeading(font));
        const traits = ct.CTFontGetSymbolicTraits(font);
        const is_monospace = (traits & ct.kCTFontTraitMonoSpace) != 0;

        // Get cell width from 'M' or '0' for monospace detection
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

test "load system font" {
    var face = try Face.initSystem(.monospace, 14.0);
    defer face.deinit();

    try std.testing.expect(face.metrics.ascender > 0);
    try std.testing.expect(face.metrics.line_height > 0);
}
