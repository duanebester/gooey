//! Shared types for the text system
//!
//! These types are platform-agnostic and used by all text backends.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform/mod.zig");
const is_wasm = platform.is_wasm;
const is_macos = builtin.os.tag == .macos;

/// Subpixel variants for sharper text rendering at fractional pixel positions.
/// Each glyph can be cached at up to VARIANTS_X * VARIANTS_Y different sub-pixel offsets.
pub const SUBPIXEL_VARIANTS_X: u8 = 4;
pub const SUBPIXEL_VARIANTS_Y: u8 = 1; // Only horizontal variants needed for text

/// Maximum unique fallback fonts tracked during ShapedRun cleanup.
/// This is sufficient for typical text runs - exceeding this is extremely rare
/// and would only occur with text containing many different scripts/emoji.
pub const MAX_FALLBACK_FONTS_PER_RUN: usize = 16;

/// System font styles
pub const SystemFont = enum {
    monospace,
    sans_serif,
    serif,
    system,
};

/// Text decoration style
pub const TextDecoration = packed struct {
    underline: bool = false,
    strikethrough: bool = false,
    _padding: u6 = 0,

    pub const none = TextDecoration{};
    pub const underlined = TextDecoration{ .underline = true };
    pub const struckthrough = TextDecoration{ .strikethrough = true };

    pub inline fn hasAny(self: TextDecoration) bool {
        return self.underline or self.strikethrough;
    }
};

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

    /// Calculate baseline Y for vertically centering text in a box.
    /// Returns the Y coordinate of the baseline in logical pixels.
    pub inline fn calcBaseline(self: Metrics, box_y: f32, box_height: f32) f32 {
        const text_height = self.ascender + self.descender;
        const padding_top = (box_height - text_height) * 0.5;
        return box_y + padding_top + self.ascender;
    }

    /// Calculate strikethrough position (center of x-height, relative to baseline)
    /// Returns negative value (above baseline)
    pub inline fn strikethroughPosition(self: Metrics) f32 {
        return -(self.x_height * 0.5);
    }

    /// Get strikethrough thickness (same as underline by default)
    pub inline fn strikethroughThickness(self: Metrics) f32 {
        return self.underline_thickness;
    }
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

/// A shaped glyph with positioning information
pub const ShapedGlyph = struct {
    /// Glyph ID in the font
    glyph_id: u16,
    /// Horizontal offset from pen position
    x_offset: f32,
    /// Vertical offset from baseline
    y_offset: f32,
    /// Horizontal advance for next glyph
    x_advance: f32,
    /// Vertical advance (usually 0)
    y_advance: f32,
    /// Index into original text (byte offset)
    cluster: u32,
    /// Font reference for this glyph (for fallback fonts)
    /// If null, use the primary font. Retained by shaper, released in ShapedRun.deinit
    font_ref: ?*anyopaque = null,
    /// Whether this glyph uses a color font (emoji)
    is_color: bool = false,
};

/// Result of shaping a text run
pub const ShapedRun = struct {
    glyphs: []ShapedGlyph,
    /// Total advance width
    width: f32,
    /// Whether this run owns its memory (false for cache hits)
    owned: bool = true,

    // CoreFoundation release function (for fallback fonts) - macOS only
    const CFRelease = if (is_macos)
        struct {
            extern "c" fn CFRelease(cf: *anyopaque) void;
        }.CFRelease
    else
        struct {
            fn f(_: *anyopaque) void {}
        }.f;

    pub fn deinit(self: *ShapedRun, allocator: std.mem.Allocator) void {
        // Skip cleanup for cache hits (they don't own their memory)
        if (!self.owned) {
            self.* = undefined;
            return;
        }

        if (self.glyphs.len > 0) {
            // Release any retained fallback fonts (avoid double-release)
            // Only needed on macOS where we use CoreFoundation
            if (is_macos) {
                var released: [MAX_FALLBACK_FONTS_PER_RUN]usize = [_]usize{0} ** MAX_FALLBACK_FONTS_PER_RUN;
                var released_count: usize = 0;

                for (self.glyphs) |glyph| {
                    if (glyph.font_ref) |font_ptr| {
                        const ptr_val = @intFromPtr(font_ptr);
                        var already_released = false;
                        for (released[0..released_count]) |r| {
                            if (r == ptr_val) {
                                already_released = true;
                                break;
                            }
                        }
                        if (!already_released) {
                            // Assert we haven't exceeded the limit - this would indicate
                            // an unusually complex text run with many different fallback fonts
                            std.debug.assert(released_count < MAX_FALLBACK_FONTS_PER_RUN);
                            if (released_count < released.len) {
                                CFRelease(font_ptr);
                                released[released_count] = ptr_val;
                                released_count += 1;
                            }
                            // In release builds, skip releasing if at capacity (leak is better than crash)
                        }
                    }
                }
            }
            allocator.free(self.glyphs);
        }
        self.* = undefined;
    }
};

/// Result of rasterizing a glyph
pub const RasterizedGlyph = struct {
    /// Width of the rasterized bitmap in physical pixels
    width: u32,
    /// Height of the rasterized bitmap in physical pixels
    height: u32,
    /// Horizontal offset from pen position to glyph left edge (physical pixels)
    offset_x: i32,
    /// Vertical offset from baseline to glyph top edge (physical pixels)
    /// Positive means the glyph top is above the baseline.
    offset_y: i32,
    /// Horizontal advance to next glyph (logical pixels)
    advance_x: f32,
    /// Whether this is a color glyph (emoji)
    is_color: bool,
};

/// Text measurement result
pub const TextMeasurement = struct {
    /// Total width of the text
    width: f32,
    /// Height (based on font metrics)
    height: f32,
    /// Number of lines (for wrapped text)
    line_count: u32 = 1,
};
