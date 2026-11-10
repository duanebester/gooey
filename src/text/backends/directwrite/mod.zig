//! DirectWrite backend for Windows text rendering.
//!
//! Provides font loading, text shaping, and glyph rasterization using
//! DirectWrite (`dwrite.dll`), which ships with every supported Windows
//! release. See `face.zig` and `shaper.zig`.

pub const bindings = @import("bindings.zig");
pub const DirectWriteFace = @import("face.zig").DirectWriteFace;
pub const DirectWriteShaper = @import("shaper.zig").DirectWriteShaper;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
