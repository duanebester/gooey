//! Minimal protocol wrapper. Gooey only needs to look up a protocol by name
//! (`getProtocol`) and hand its underlying pointer to `class_addProtocol` when
//! building the custom `NSTextInputClient` view class. None of the richer
//! protocol introspection from upstream is used, so only `.value` is exposed.

const c = @import("c.zig").c;

pub const Protocol = struct {
    value: *c.Protocol,
};

/// Look up a registered protocol by name, returning null if the runtime does
/// not know it.
pub fn getProtocol(name: [:0]const u8) ?Protocol {
    return .{ .value = c.objc_getProtocol(name.ptr) orelse return null };
}
