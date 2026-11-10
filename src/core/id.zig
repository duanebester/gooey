//! ElementId: one `u64` identity for layout, hit testing, focus, retained
//! state, and accessibility (contract §2).
//!
//! An id is derived from its parent's id, so the same key under two parents
//! names two elements. Keyed ids set the top bit; auto ids, which number
//! unkeyed siblings, clear it. Only keyed ids may own retained state, focus,
//! or accessibility identity, because an auto id changes when an earlier
//! sibling appears or disappears.

const std = @import("std");

const assert = std.debug.assert;

pub const Key = union(enum) {
    name: []const u8,
    index: u64,

    /// The key's hash. Names hash their bytes, so the string is not stored
    /// (contract rule 6).
    pub fn hash(self: Key) u64 {
        return switch (self) {
            .name => |name| blk: {
                assert(name.len > 0);
                break :blk std.hash.Wyhash.hash(key_seed_name, name);
            },
            .index => |index| std.hash.Wyhash.hash(key_seed_index, std.mem.asBytes(&index)),
        };
    }
};

const key_seed_name: u64 = 0x6b65795f6e616d65; // "key_name"
const key_seed_index: u64 = 0x6b65795f696e6478; // "key_indx"
const keyed_bit: u64 = 1 << 63;

pub const ElementId = enum(u64) {
    root = 0,
    _,

    /// The id of the child of `parent` with `key`.
    pub fn child(parent: ElementId, key: Key) ElementId {
        const mixed = mix(@backingInt(parent), key.hash());
        const id: ElementId = @fromBackingInt(@intCast(mixed | keyed_bit));
        assert(id.isKeyed());
        assert(id != .root);
        return id;
    }

    /// The id of the `sibling_index`-th unkeyed child of `parent`.
    pub fn auto(parent: ElementId, sibling_index: u32) ElementId {
        const mixed = mix(@backingInt(parent), @as(u64, sibling_index) +% 0x9e3779b97f4a7c15);
        // Zero is the root; an auto id that hashes to it takes the next value.
        const value = mixed & ~keyed_bit;
        const id: ElementId = @fromBackingInt(@intCast(if (value == 0) 1 else value));
        assert(!id.isKeyed());
        assert(id != .root);
        return id;
    }

    pub fn isKeyed(self: ElementId) bool {
        return @backingInt(self) & keyed_bit != 0;
    }
};

/// A 64-bit finalizer over the pair (Murmur3's fmix64 on a sum).
fn mix(parent: u64, value: u64) u64 {
    var x = parent *% 0xff51afd7ed558ccd +% value;
    x ^= x >> 33;
    x *%= 0xc4ceb9fe1a85ec53;
    x ^= x >> 33;
    return x;
}

test "keyed and auto ids differ by parent, key, and index" {
    // Goal: identity is scoped to the parent and keyed ids never collide
    // with auto ids. Methodology: derive ids that differ in one input each.
    const a = ElementId.root.child(.{ .name = "a" });
    const b = ElementId.root.child(.{ .name = "b" });
    try std.testing.expect(a != b);
    try std.testing.expect(a.isKeyed());
    try std.testing.expect(a.child(.{ .name = "a" }) != a);
    try std.testing.expect(a.child(.{ .index = 1 }) != b.child(.{ .index = 1 }));
    try std.testing.expect(ElementId.root.child(.{ .index = 0 }) != ElementId.root.auto(0));
    try std.testing.expect(!ElementId.root.auto(0).isKeyed());
    try std.testing.expect(ElementId.root.auto(0) != ElementId.root.auto(1));
    try std.testing.expectEqual(a, ElementId.root.child(.{ .name = "a" }));
}
