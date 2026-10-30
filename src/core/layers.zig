//! Layers: fragments and their order (contract §6).
//!
//! Content is fragment zero. A box with a `layer` opens a fragment; fragments
//! paint in `order` and hit-test in reverse, so what is on top receives input.
//! Milestone 1 (counter and todo) opens no layers: `Cx` rejects a set
//! `layer` until floating layout moves onto the core in phase 4, and every
//! record carries fragment zero.

const std = @import("std");

const assert = std.debug.assert;

pub const Layer = struct {
    kind: Kind,
    anchor: Anchor,
    clip: enum { escape, inherit },

    pub const Kind = enum { popover, tooltip, modal, drag };
};

pub const Anchor = union(enum) {
    /// Relative to the box that opens the layer.
    parent: struct { x: f32 = 0, y: f32 = 0 },
    /// Relative to the window.
    window: struct { x: f32 = 0, y: f32 = 0 },
};

pub const content_fragment: u8 = 0;

/// Fragment paint order: content, then each layer kind in this order, then
/// open order within a kind.
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
    try std.testing.expect(kindRank(.popover) < kindRank(.modal));
    try std.testing.expect(kindRank(.modal) < kindRank(.drag));
}
