//! Deterministic text backend for headless tests and goldens; selected with
//! the `text_backend = .synthetic` build option.

pub const SyntheticFace = @import("face.zig").SyntheticFace;
pub const SyntheticShaper = @import("shaper.zig").SyntheticShaper;

test {
    @import("std").testing.refAllDecls(@This());
}
