//! Element identity — stable identity for elements across renders
//!
//! `ElementId` uniquely identifies a UI element via a name hash, an integer,
//! or a focus handle.  Identity is stable across re-renders so that the
//! framework can correlate state (focus, animation, layout cache) with the
//! element that owns it.

const std = @import("std");

// =============================================================================
// Element ID (stable identity across renders)
// =============================================================================

pub const ElementId = union(enum) {
    name: NamedId,
    integer: u64,
    focus_handle: u64,

    pub const NamedId = struct {
        hash: u64,

        pub fn init(name: []const u8) NamedId {
            return .{ .hash = std.hash.Wyhash.hash(0, name) };
        }
    };

    pub fn named(name: []const u8) ElementId {
        return .{ .name = NamedId.init(name) };
    }

    pub fn int(id: u64) ElementId {
        return .{ .integer = id };
    }

    pub fn eql(self: ElementId, other: ElementId) bool {
        return switch (self) {
            .name => |n| switch (other) {
                .name => |on| n.hash == on.hash,
                else => false,
            },
            .integer => |i| switch (other) {
                .integer => |oi| i == oi,
                else => false,
            },
            .focus_handle => |f| switch (other) {
                .focus_handle => |of| f == of,
                else => false,
            },
        };
    }

    pub fn hash(self: ElementId) u64 {
        return switch (self) {
            .name => |n| n.hash,
            .integer, .focus_handle => |i| i,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "named ElementId equality" {
    const a = ElementId.named("button_ok");
    const b = ElementId.named("button_ok");
    const c = ElementId.named("button_cancel");

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "integer ElementId equality" {
    const a = ElementId.int(42);
    const b = ElementId.int(42);
    const c = ElementId.int(99);

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "different variants are never equal" {
    const named = ElementId.named("foo");
    const integer = ElementId.int(named.hash());

    try std.testing.expect(!named.eql(integer));
}

test "hash returns deterministic values" {
    const a = ElementId.named("sidebar");
    const b = ElementId.named("sidebar");

    try std.testing.expectEqual(a.hash(), b.hash());
    try std.testing.expectEqual(ElementId.int(7).hash(), @as(u64, 7));
}
