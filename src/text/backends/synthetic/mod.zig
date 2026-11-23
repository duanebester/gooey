pub const SyntheticFace = @import("face.zig").SyntheticFace;
pub const SyntheticShaper = @import("shaper.zig").SyntheticShaper;

test {
    @import("std").testing.refAllDecls(@This());
}
