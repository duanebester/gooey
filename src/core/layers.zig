//! Layers: fragments and their order (contract §6).
//!
//! Content is fragment zero. A box with a `layer` opens a fragment; fragments
//! paint in `order` and hit-test in reverse, so what is on top receives input.
//! Emit writes each fragment's paint after the previous one's into the one
//! stream, and tags its hit records with the fragment. Only `.popover` is
//! implemented (contract decision 13); `Cx` fails fast on the other kinds.

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
