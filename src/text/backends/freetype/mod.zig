//! FreeType/HarfBuzz backend for Linux text rendering
//!
//! Provides font loading, text shaping, and glyph rasterization
//! using FreeType, HarfBuzz, and Fontconfig.

pub const bindings = @import("bindings.zig");
pub const FreeTypeFace = @import("face.zig").FreeTypeFace;
pub const HarfBuzzShaper = @import("shaper.zig").HarfBuzzShaper;

// Re-export common types
pub const FT_Face = bindings.FT_Face;
pub const hb_font_t = bindings.hb_font_t;

test {
    @import("std").testing.refAllDecls(@This());
}
