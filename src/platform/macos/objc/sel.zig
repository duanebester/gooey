//! Selector wrapper. A `Sel` is the runtime's interned representation of a
//! method name. `msgSend` accepts either a string literal (which it registers
//! on the fly) or a pre-registered `Sel`.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

/// Shorthand, equivalent to `Sel.registerName`.
pub inline fn sel(name: [:0]const u8) Sel {
    return Sel.registerName(name);
}

pub const Sel = struct {
    value: c.SEL,

    /// Register a method name with the Objective-C runtime and return its
    /// selector. Registration is idempotent: the same name always maps to the
    /// same selector for the lifetime of the process.
    pub fn registerName(name: [:0]const u8) Sel {
        assert(name.len > 0);
        return .{ .value = c.sel_registerName(name.ptr) };
    }
};
