//! FontFace interface - abstraction over platform-specific font implementations
//!
//! This trait defines the operations that all font backends must support.
//! Use the concrete backend types (e.g., CoreTextFace) for platform-specific features.

const std = @import("std");
const types = @import("types.zig");

pub const Metrics = types.Metrics;
pub const GlyphMetrics = types.GlyphMetrics;
pub const RasterizedGlyph = types.RasterizedGlyph;
pub const SystemFont = types.SystemFont;

/// Font face interface - implemented by platform backends
pub const FontFace = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Cached metrics (computed at font load time)
    metrics: Metrics,

    pub const VTable = struct {
        /// Get glyph ID for a Unicode codepoint
        glyphIndex: *const fn (ptr: *anyopaque, codepoint: u21) u16,

        /// Get advance width for a glyph (fast path for text measurement)
        glyphAdvance: *const fn (ptr: *anyopaque, glyph_id: u16) f32,

        /// Get metrics for a specific glyph
        glyphMetrics: *const fn (ptr: *anyopaque, glyph_id: u16) GlyphMetrics,

        /// Render a glyph with subpixel positioning
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

        /// Release resources
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Get glyph ID for a Unicode codepoint
    /// Returns 0 for missing glyphs (.notdef)
    pub inline fn glyphIndex(self: FontFace, codepoint: u21) u16 {
        return self.vtable.glyphIndex(self.ptr, codepoint);
    }

    /// Get advance width for a glyph (fast path for text measurement)
    /// This is optimized to avoid loading full glyph outlines
    pub inline fn glyphAdvance(self: FontFace, glyph_id: u16) f32 {
        return self.vtable.glyphAdvance(self.ptr, glyph_id);
    }

    /// Get metrics for a specific glyph
    pub inline fn glyphMetrics(self: FontFace, glyph_id: u16) GlyphMetrics {
        return self.vtable.glyphMetrics(self.ptr, glyph_id);
    }

    /// Get glyph metrics for a codepoint (convenience)
    pub inline fn codepointMetrics(self: FontFace, codepoint: u21) GlyphMetrics {
        return self.glyphMetrics(self.glyphIndex(codepoint));
    }

    /// Render a glyph with subpixel positioning
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

    /// Release resources
    pub fn deinit(self: *FontFace) void {
        self.vtable.deinit(self.ptr);
        self.* = undefined;
    }
};

/// Helper to create a FontFace from a concrete implementation
pub fn createFontFace(comptime T: type, impl: *T) FontFace {
    const gen = struct {
        fn glyphIndex(ptr: *anyopaque, codepoint: u21) u16 {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.glyphIndex(codepoint);
        }

        fn glyphAdvance(ptr: *anyopaque, glyph_id: u16) f32 {
            const self: *T = @ptrCast(@alignCast(ptr));
            // Use glyphAdvance if available, otherwise fall back to glyphMetrics
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
