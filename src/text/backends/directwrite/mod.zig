pub const bindings = @import("bindings.zig");
pub const DirectWriteFace = @import("face.zig").DirectWriteFace;
pub const DirectWriteShaper = @import("shaper.zig").DirectWriteShaper;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
