const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform/mod.zig");
const is_wasm = platform.is_wasm;
const is_macos = builtin.os.tag == .macos;

pub const SUBPIXEL_VARIANTS_X: u8 = 4;
pub const SUBPIXEL_VARIANTS_Y: u8 = 1;

pub const MAX_FALLBACK_FONTS_PER_RUN: usize = 16;

pub const SystemFont = enum {
    monospace,
    sans_serif,
    serif,
    system,
};

pub const FontWeight = enum(u8) {
    thin,
    light,
    regular,
    medium,
    semibold,
    bold,
    black,

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

pub const FontFamily = enum(u1) {
    app,
    mono,

    pub fn fontId(family: FontFamily, variant: FontVariant) u16 {
        const result: u16 = @as(u16, @backingInt(family)) * FontVariant.count + variant.fontId();
        std.debug.assert(result < font_id_count);
        return result;
    }

    pub fn fromFontId(font_id: u16) FontFamily {
        std.debug.assert(font_id < font_id_count);
        return @fromBackingInt(@intCast(font_id / FontVariant.count));
    }

    pub fn variantFromFontId(font_id: u16) FontVariant {
        std.debug.assert(font_id < font_id_count);
        return FontVariant.fromFontId(font_id % FontVariant.count);
    }

    pub const count: u8 = 2;
    pub const font_id_count: u16 = @as(u16, count) * FontVariant.count;
};

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

pub const Metrics = struct {
    units_per_em: u32,
    ascender: f32,
    descender: f32,
    line_gap: f32,
    cap_height: f32,
    x_height: f32,
    underline_position: f32,
    underline_thickness: f32,
    line_height: f32,
    point_size: f32,
    is_monospace: bool,
    cell_width: f32,

    pub inline fn calcBaseline(self: Metrics, box_y: f32, box_height: f32) f32 {
        const text_height = self.ascender + self.descender;
        const padding_top = (box_height - text_height) * 0.5;
        return box_y + padding_top + self.ascender;
    }
};

pub const GlyphMetrics = struct {
    glyph_id: u16,
    advance_x: f32,
    advance_y: f32,
    bearing_x: f32,
    bearing_y: f32,
    width: f32,
    height: f32,
};

pub const ShapedGlyph = struct {
    glyph_id: u16,
    x_offset: f32,
    y_offset: f32,
    x_advance: f32,
    y_advance: f32,
    cluster: u32,
    font_ref: ?*anyopaque = null,
    is_color: bool = false,
};

pub const ShapedRun = struct {
    glyphs: []ShapedGlyph,
    width: f32,
    owned: bool = true,

    const CFRelease = if (is_macos)
        struct {
            extern "c" fn CFRelease(cf: *anyopaque) void;
        }.CFRelease
    else
        struct {
            fn f(_: *anyopaque) void {}
        }.f;

    pub fn deinit(self: *ShapedRun, allocator: std.mem.Allocator) void {
        if (!self.owned) {
            self.* = undefined;
            return;
        }

        if (self.glyphs.len > 0) {
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
                            std.debug.assert(released_count < MAX_FALLBACK_FONTS_PER_RUN);
                            if (released_count < released.len) {
                                CFRelease(font_ptr);
                                released[released_count] = ptr_val;
                                released_count += 1;
                            }
                        }
                    }
                }
            }
            allocator.free(self.glyphs);
        }
        self.* = undefined;
    }
};

pub const RasterizedGlyph = struct {
    width: u32,
    height: u32,
    offset_x: i32,
    offset_y: i32,
    advance_x: f32,
    is_color: bool,
};

pub const TextMeasurement = struct {
    width: f32,
    height: f32,
    line_count: u32 = 1,
};

pub const MeasureTextOptions = struct {
    max_width: ?f32 = null,
    font_size: ?f32 = null,
    weight: FontWeight = .regular,
    italic: bool = false,
};
