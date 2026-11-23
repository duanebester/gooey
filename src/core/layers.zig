const std = @import("std");

const assert = std.debug.assert;

pub const Layer = struct {
    kind: Kind,
    anchor: Anchor,
    clip: enum { escape, inherit },

    pub const Kind = enum { popover, tooltip, modal, drag };
};

pub const Anchor = union(enum) {
    parent: struct { x: f32 = 0, y: f32 = 0 },
    window: struct { x: f32 = 0, y: f32 = 0 },
};

pub const content_fragment: u8 = 0;

pub fn kindRank(kind: Layer.Kind) u8 {
    const rank: u8 = switch (kind) {
        .popover => 1,
        .tooltip => 2,
        .modal => 3,
        .drag => 4,
    };
    assert(rank > content_fragment);
    return rank;
}

test "layer kinds rank above content" {
    try std.testing.expect(kindRank(.popover) < kindRank(.tooltip));
    try std.testing.expect(kindRank(.tooltip) < kindRank(.modal));
    try std.testing.expect(kindRank(.modal) < kindRank(.drag));
}
