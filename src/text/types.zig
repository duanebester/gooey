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

/// Font weight, ordered from lightest to heaviest. `TextStyle.weight` uses this type.
pub const FontWeight = enum(u8) {
    thin,
    light,
    regular,
    medium,
    semibold,
    bold,
    black,

    /// CSS `font-weight` number, the shared scale every backend maps from.
    pub fn cssWeight(self: FontWeight) u16 {
        const result: u16 = switch (self) {
            .thin => 100,
            .light => 300,
            .regular => 400,
            .medium => 500,
            .semibold => 600,
            .bold => 700,
            .black => 900,
        };
        std.debug.assert(result >= 100);
        std.debug.assert(result <= 900);
        return result;
    }
};

/// One loadable face of a font family: a weight, upright or italic. Each text
/// system loads one face per variant in its `FontLimits.variants` during init.
///
/// The tag value is the layout `font_id`. `regular` is 0 so the layout default
/// (`TextConfig.font_id = 0`) selects the regular upright face.
pub const FontVariant = enum(u8) {
    regular,
    italic,
    thin,
    thin_italic,
    light,
    light_italic,
    medium,
    medium_italic,
    semibold,
    semibold_italic,
    bold,
    bold_italic,
    black,
    black_italic,

    pub const count: u8 = @typeInfo(FontVariant).@"enum".field_names.len;

    /// Weight of each tag pair, in tag order: tag `2k` is upright, `2k + 1` italic.
    const weight_by_pair = [_]FontWeight{
        .regular, .thin, .light, .medium, .semibold, .bold, .black,
    };

    comptime {
        std.debug.assert(count == weight_by_pair.len * 2);
        std.debug.assert(@backingInt(FontVariant.regular) == 0);
        std.debug.assert(count == @typeInfo(FontWeight).@"enum".field_names.len * 2);
    }

    pub fn init(font_weight: FontWeight, italic_style: bool) FontVariant {
        const pair: u8 = for (weight_by_pair, 0..) |candidate, index| {
            if (candidate == font_weight) break @intCast(index);
        } else unreachable;
        const tag: u8 = pair * 2 + @intFromBool(italic_style);
        const result: FontVariant = @fromBackingInt(tag);
        std.debug.assert(result.weight() == font_weight);
        std.debug.assert(result.isItalic() == italic_style);
        return result;
    }

    /// The variant a layout `font_id` names. An id outside the enum is a
    /// programmer error: only `FontVariant.fontId` produces font ids.
    pub fn fromFontId(font_id: u16) FontVariant {
        if (font_id < count) {
            return @fromBackingInt(@intCast(font_id));
        } else {
            std.debug.panic("font_id {d} is not a FontVariant (valid ids are 0..{d})", .{
                font_id,
                count - 1,
            });
        }
    }

    pub fn fontId(self: FontVariant) u16 {
        const result: u16 = @backingInt(self);
        std.debug.assert(result < count);
        return result;
    }

    pub fn weight(self: FontVariant) FontWeight {
        return weight_by_pair[@backingInt(self) / 2];
    }

    pub fn isItalic(self: FontVariant) bool {
        return @backingInt(self) % 2 == 1;
    }
};

/// Which loaded family a run draws with (contract decision 8). `app` is the
/// app's font (`Config.font`); `mono` is the optional second family
/// (`Config.fonts.mono`), with its own faces from `FontLimits.mono_variants`.
pub const FontFamily = enum(u1) {
    app,
    mono,

    /// The layout `font_id` of `variant` in this family. App ids equal
    /// `FontVariant.fontId`, so 0.3.1 layout ids keep their meaning; mono ids
    /// follow them.
    pub fn fontId(family: FontFamily, variant: FontVariant) u16 {
        const result: u16 = @as(u16, @backingInt(family)) * FontVariant.count + variant.fontId();
        std.debug.assert(result < font_id_count);
        return result;
    }

    /// The family a layout `font_id` names. Ids come only from `fontId`.
    pub fn fromFontId(font_id: u16) FontFamily {
        std.debug.assert(font_id < font_id_count);
        return @fromBackingInt(@intCast(font_id / FontVariant.count));
    }

    /// The variant a layout `font_id` names, in either family.
    pub fn variantFromFontId(font_id: u16) FontVariant {
        std.debug.assert(font_id < font_id_count);
        return FontVariant.fromFontId(font_id % FontVariant.count);
    }

    pub const count: u8 = 2;
    pub const font_id_count: u16 = @as(u16, count) * FontVariant.count;
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
                var released: [MAX_FALLBACK_FONTS_PER_RUN]usize = @splat(0);
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

/// Options for the platform text shaper's measurement pass.
/// A `null` field selects the shaper's natural default rather than a
/// magic numeric sentinel, so callers do not have to encode "unset"
/// as a zero (which would otherwise be ambiguous with a real width of
/// zero or a degenerate font size):
/// - `max_width == null` means measure on a single line with no
///   wrapping, so the returned width is the full unwrapped advance.
/// - `font_size == null` means measure at the currently loaded font's
///   size, so the caller does not have to restate it.
///
/// `weight` and `italic` select the face exactly as `TextStyle` does for
/// rendering, with the same defaults, so a measured width matches the drawn
/// text. A combination outside the text system's `FontLimits.variants`
/// panics, as it does when rendered.
pub const MeasureTextOptions = struct {
    max_width: ?f32 = null,
    font_size: ?f32 = null,
    weight: FontWeight = .regular,
    italic: bool = false,
};
