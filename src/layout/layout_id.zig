//! Hash-based element IDs for stable identification across frames
//!
//! Inspired by Clay's CLAY_ID / CLAY_IDI macros. Uses string hashing
//! for deterministic element identification, with support for indexed
//! IDs in loops.

const std = @import("std");

/// Hash-based layout ID
pub const LayoutId = struct {
    /// The final computed hash
    id: u32,
    /// Hash before any index offset was applied
    base_id: u32,
    /// Index offset (for indexed IDs in loops)
    offset: u32,
    /// Original string for debugging (optional, may be null)
    string_id: ?[]const u8,

    const Self = @This();

    /// Create ID from a string literal (compile-time when possible)
    pub fn init(comptime str: []const u8) Self {
        const hash = comptime hashString(str, 0);
        return .{
            .id = hash,
            .base_id = hash,
            .offset = 0,
            .string_id = str,
        };
    }

    /// Create ID from runtime string
    pub fn fromString(str: []const u8) Self {
        const hash = hashString(str, 0);
        return .{
            .id = hash,
            .base_id = hash,
            .offset = 0,
            .string_id = str,
        };
    }

    /// Create indexed ID (for items in a loop)
    /// Example: LayoutId.indexed("list_item", i)
    pub fn indexed(comptime str: []const u8, index: u32) Self {
        const base = comptime hashString(str, 0);
        const hash = hashNumber(index, base);
        return .{
            .id = hash,
            .base_id = base,
            .offset = index,
            .string_id = str,
        };
    }

    /// Create child ID relative to a parent
    pub fn child(parent_id: u32, str: []const u8) Self {
        const hash = hashString(str, parent_id);
        return .{
            .id = hash,
            .base_id = hash,
            .offset = 0,
            .string_id = str,
        };
    }

    /// Create child ID with index
    pub fn childIndexed(parent_id: u32, str: []const u8, index: u32) Self {
        const base = hashString(str, parent_id);
        const hash = hashNumber(index, base);
        return .{
            .id = hash,
            .base_id = base,
            .offset = index,
            .string_id = str,
        };
    }

    pub fn eql(self: Self, other: Self) bool {
        return self.id == other.id;
    }

    /// Null/invalid ID
    pub const none = Self{ .id = 0, .base_id = 0, .offset = 0, .string_id = null };
};

/// Jenkins one-at-a-time hash for strings
fn hashString(str: []const u8, seed: u32) u32 {
    var hash = seed;
    for (str) |c| {
        hash +%= c;
        hash +%= hash << 10;
        hash ^= hash >> 6;
    }
    hash +%= hash << 3;
    hash ^= hash >> 11;
    hash +%= hash << 15;
    // Reserve 0 as "null/none" ID
    return if (hash == 0) 1 else hash;
}

/// Hash a number (for indexed IDs)
fn hashNumber(n: u32, seed: u32) u32 {
    var hash = seed;
    // Hash each byte of the number
    hash +%= (n & 0xFF) +% 48;
    hash +%= hash << 10;
    hash ^= hash >> 6;
    hash +%= ((n >> 8) & 0xFF) +% 48;
    hash +%= hash << 10;
    hash ^= hash >> 6;
    hash +%= ((n >> 16) & 0xFF) +% 48;
    hash +%= hash << 10;
    hash ^= hash >> 6;
    hash +%= ((n >> 24) & 0xFF) +% 48;
    hash +%= hash << 10;
    hash ^= hash >> 6;
    hash +%= hash << 3;
    hash ^= hash >> 11;
    hash +%= hash << 15;
    return if (hash == 0) 1 else hash;
}

test "element id hashing" {
    const id1 = LayoutId.init("button");
    const id2 = LayoutId.init("button");
    const id3 = LayoutId.init("label");

    try std.testing.expectEqual(id1.id, id2.id);
    try std.testing.expect(id1.id != id3.id);
}

test "indexed element ids" {
    const id0 = LayoutId.indexed("item", 0);
    const id1 = LayoutId.indexed("item", 1);
    const id2 = LayoutId.indexed("item", 2);

    try std.testing.expect(id0.id != id1.id);
    try std.testing.expect(id1.id != id2.id);
    try std.testing.expectEqual(id0.base_id, id1.base_id);
}
