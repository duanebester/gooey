pub const bindings = @import("bindings.zig");
pub const FreeTypeFace = @import("face.zig").FreeTypeFace;
pub const HarfBuzzShaper = @import("shaper.zig").HarfBuzzShaper;

pub const FT_Face = bindings.FT_Face;
pub const hb_font_t = bindings.hb_font_t;

test {
    @import("std").testing.refAllDecls(@This());
}
