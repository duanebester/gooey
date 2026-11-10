//! Deterministic text backend for headless tests and goldens.
//!
//! Selected with the `text_backend = .synthetic` build option; see
//! `src/text/text_system.zig`. It needs no fonts, so it runs identically on
//! every host.

pub const SyntheticFace = @import("face.zig").SyntheticFace;
pub const SyntheticShaper = @import("shaper.zig").SyntheticShaper;

test {
    @import("std").testing.refAllDecls(@This());
}
