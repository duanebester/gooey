const std = @import("std");

const assert = std.debug.assert;

pub const Key = union(enum) {
    name: []const u8,
    index: u64,

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

const key_seed_name: u64 = 0x6b65795f6e616d65;
const key_seed_index: u64 = 0x6b65795f696e6478;
const keyed_bit: u64 = 1 << 63;

pub const ElementId = enum(u64) {
    root = 0,
    _,

    pub fn child(parent: ElementId, key: Key) ElementId {
        const mixed = mix(@backingInt(parent), key.hash());
        const id: ElementId = @fromBackingInt(@intCast(mixed | keyed_bit));
        assert(id.isKeyed());
        assert(id != .root);
        return id;
    }

    pub fn auto(parent: ElementId, sibling_index: u32) ElementId {
        const mixed = mix(@backingInt(parent), @as(u64, sibling_index) +% 0x9e3779b97f4a7c15);
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

fn mix(parent: u64, value: u64) u64 {
    var x = parent *% 0xff51afd7ed558ccd +% value;
    x ^= x >> 33;
    x *%= 0xc4ceb9fe1a85ec53;
    x ^= x >> 33;
    return x;
}

test "keyed and auto ids differ by parent, key, and index" {
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
