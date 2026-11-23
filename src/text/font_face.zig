const std = @import("std");
const types = @import("types.zig");

pub const Metrics = types.Metrics;
pub const GlyphMetrics = types.GlyphMetrics;
pub const RasterizedGlyph = types.RasterizedGlyph;
pub const SystemFont = types.SystemFont;

pub const FontFace = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    metrics: Metrics,

    pub const VTable = struct {
        glyphIndex: *const fn (ptr: *anyopaque, codepoint: u21) u16,

        glyphAdvance: *const fn (ptr: *anyopaque, glyph_id: u16) f32,

        glyphMetrics: *const fn (ptr: *anyopaque, glyph_id: u16) GlyphMetrics,

        renderGlyphSubpixel: *const fn (
            ptr: *anyopaque,
            glyph_id: u16,
            font_size: f32,
            scale: f32,
            subpixel_x: f32,
            subpixel_y: f32,
            buffer: []u8,
            buffer_size: u32,
        ) anyerror!RasterizedGlyph,

        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub inline fn glyphIndex(self: FontFace, codepoint: u21) u16 {
        return self.vtable.glyphIndex(self.ptr, codepoint);
    }

    pub inline fn glyphAdvance(self: FontFace, glyph_id: u16) f32 {
        return self.vtable.glyphAdvance(self.ptr, glyph_id);
    }

    pub inline fn glyphMetrics(self: FontFace, glyph_id: u16) GlyphMetrics {
        return self.vtable.glyphMetrics(self.ptr, glyph_id);
    }

    pub inline fn renderGlyphSubpixel(
        self: FontFace,
        glyph_id: u16,
        font_size: f32,
        scale: f32,
        subpixel_x: f32,
        subpixel_y: f32,
        buffer: []u8,
        buffer_size: u32,
    ) !RasterizedGlyph {
        return self.vtable.renderGlyphSubpixel(self.ptr, glyph_id, font_size, scale, subpixel_x, subpixel_y, buffer, buffer_size);
    }

    pub fn deinit(self: *FontFace) void {
        self.vtable.deinit(self.ptr);
        self.* = undefined;
    }
};

pub fn createFontFace(comptime T: type, impl: *T) FontFace {
    const gen = struct {
        fn glyphIndex(ptr: *anyopaque, codepoint: u21) u16 {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.glyphIndex(codepoint);
        }

        fn glyphAdvance(ptr: *anyopaque, glyph_id: u16) f32 {
            const self: *T = @ptrCast(@alignCast(ptr));
            if (@hasDecl(T, "glyphAdvance")) {
                return self.glyphAdvance(glyph_id);
            } else {
                return self.glyphMetrics(glyph_id).advance_x;
            }
        }

        fn glyphMetrics(ptr: *anyopaque, glyph_id: u16) GlyphMetrics {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.glyphMetrics(glyph_id);
        }

        fn renderGlyphSubpixel(
            ptr: *anyopaque,
            glyph_id: u16,
            font_size: f32,
            scale: f32,
            subpixel_x: f32,
            subpixel_y: f32,
            buffer: []u8,
            buffer_size: u32,
        ) anyerror!RasterizedGlyph {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.renderGlyphSubpixel(glyph_id, font_size, scale, subpixel_x, subpixel_y, buffer, buffer_size);
        }

        fn deinit(ptr: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        const vtable = FontFace.VTable{
            .glyphIndex = glyphIndex,
            .glyphAdvance = glyphAdvance,
            .glyphMetrics = glyphMetrics,
            .renderGlyphSubpixel = renderGlyphSubpixel,
            .deinit = deinit,
        };
    };

    return .{
        .ptr = impl,
        .vtable = &gen.vtable,
        .metrics = impl.metrics,
    };
}
