const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

pub inline fn sel(name: [:0]const u8) Sel {
    return Sel.registerName(name);
}

pub const Sel = struct {
    value: c.SEL,

    pub fn registerName(name: [:0]const u8) Sel {
        assert(name.len > 0);
        return .{ .value = c.sel_registerName(name.ptr) };
    }
};
