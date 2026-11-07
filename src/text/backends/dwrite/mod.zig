//! DirectWrite backend for Windows text rendering
//!
//! Font loading, text shaping, and glyph rasterization through the system
//! DirectWrite COM interfaces, using hand-written bindings (no SDK headers):
//! family lookup via the system font collection, shaping via
//! `IDWriteTextAnalyzer`, and grayscale rasterization via
//! `IDWriteGlyphRunAnalysis`.

pub const bindings = @import("bindings.zig");
pub const DirectWriteFace = @import("face.zig").DirectWriteFace;
pub const DirectWriteShaper = @import("shaper.zig").DirectWriteShaper;

// Re-export common types
pub const IDWriteFactory = bindings.IDWriteFactory;
pub const IDWriteFontFace = bindings.IDWriteFontFace;

test {
    @import("std").testing.refAllDecls(@This());
}
