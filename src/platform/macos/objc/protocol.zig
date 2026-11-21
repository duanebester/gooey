const c = @import("c.zig").c;

pub const Protocol = struct {
    value: *c.Protocol,
};

pub fn getProtocol(name: [:0]const u8) ?Protocol {
    return .{ .value = c.objc_getProtocol(name.ptr) orelse return null };
}
