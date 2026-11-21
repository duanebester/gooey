pub const bindings = @import("bindings.zig");
pub const CoreTextFace = @import("face.zig").CoreTextFace;
pub const CoreTextShaper = @import("shaper.zig").CoreTextShaper;

pub const CTFontRef = bindings.CTFontRef;
pub const CGGlyph = bindings.CGGlyph;

test {
    @import("std").testing.refAllDecls(@This());
}
