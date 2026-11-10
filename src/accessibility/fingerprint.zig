//! Element fingerprinting for cross-frame identity.
//!
//! Problem: Immediate mode rebuilds the tree every frame, but platform
//! accessibility APIs expect stable object identity. VoiceOver tracks
//! focus by object pointer; AT-SPI2 uses stable D-Bus paths.
//!
//! Solution: Compute a fingerprint from semantic content. Elements with
//! matching fingerprints across frames are considered "the same element"
//! for platform sync purposes.

const std = @import("std");
const constants = @import("constants.zig");
const types = @import("types.zig");

const assert = std.debug.assert;

/// 64-bit fingerprint uniquely identifying an element's semantic identity.
///
/// Composed of:
/// - Role (8 bits)
/// - Parent fingerprint contribution (16 bits)
/// - Position in parent (8 bits)
/// - Name hash (32 bits)
pub const Fingerprint = packed struct(u64) {
    role: u8,
    parent_contrib: u16,
    position: u8,
    name_hash: u32,

    pub const INVALID: Fingerprint = .{
        .role = 0xFF,
        .parent_contrib = 0xFFFF,
        .position = 0xFF,
        .name_hash = 0xFFFFFFFF,
    };

    pub fn eql(self: Fingerprint, other: Fingerprint) bool {
        return self.toU64() == other.toU64();
    }

    pub fn toU64(self: Fingerprint) u64 {
        return @bitCast(self);
    }

    pub fn fromU64(value: u64) Fingerprint {
        return @bitCast(value);
    }

    /// Check if this is the invalid/sentinel fingerprint
    pub fn isValid(self: Fingerprint) bool {
        return !self.eql(INVALID);
    }

    /// Format for debug output
    pub fn format(
        self: Fingerprint,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("Fingerprint{{role={d}, parent={x}, pos={d}, name={x}}}", .{
            self.role,
            self.parent_contrib,
            self.position,
            self.name_hash,
        });
    }
};

/// Most children one parent, or the tree's top level, can have: every child
/// is an element of the tree.
pub const position_count_max: u16 = constants.MAX_ELEMENTS;

/// Compute fingerprint for an element.
///
/// Design: Fingerprint is intentionally NOT based on layout bounds or
/// visual properties. Two elements are "the same" if they have the same
/// role, name, and structural position - even if they moved on screen.
pub fn compute(
    role: types.Role,
    name: ?[]const u8,
    parent_fingerprint: ?Fingerprint,
    position_in_parent: u16,
) Fingerprint {
    assert(position_in_parent < position_count_max);
    // Hash the name (or use 0 for unnamed elements)
    const name_hash: u32 = if (name) |n| blk: {
        assert(n.len <= 65535); // Reasonable name length limit
        var h = std.hash.Wyhash.init(0);
        h.update(n);
        break :blk @truncate(h.final());
    } else 0;
    return computeWithHash(role, name_hash, parent_fingerprint, position_in_parent);
}

/// Compute fingerprint with a pre-computed name hash.
/// Use when the name hash is already available (e.g., from layout ID).
///
/// Siblings share their role, name, and parent, so their positions alone
/// must keep them apart. The position's low byte is the `position` field;
/// its high byte is spread into `parent_contrib` by an odd multiplier, a
/// bijection modulo 2^16, so two positions under `position_count_max` that
/// differ only above bit 7 still differ there. Positions below 256 add
/// nothing, so their fingerprints are unchanged from the 8-bit scheme.
pub fn computeWithHash(
    role: types.Role,
    name_hash: u32,
    parent_fingerprint: ?Fingerprint,
    position_in_parent: u16,
) Fingerprint {
    assert(position_in_parent < position_count_max);

    // Derive parent contribution (prevents collisions across subtrees)
    const parent_contrib: u16 = if (parent_fingerprint) |pf| blk: {
        // XOR high and low bits of parent fingerprint for contribution
        const pf_u64 = pf.toU64();
        break :blk @truncate(pf_u64 ^ (pf_u64 >> 16));
    } else 0;
    const position_high: u16 = position_in_parent >> 8;

    const result = Fingerprint{
        .role = @backingInt(role),
        .parent_contrib = parent_contrib ^ (position_high *% position_spread_multiplier),
        .position = @truncate(position_in_parent),
        .name_hash = name_hash,
    };

    // Post-condition: result should not be INVALID unless inputs are pathological
    assert(result.role != 0xFF or @backingInt(role) == 0xFF);
    return result;
}

/// Odd, so multiplying by it permutes `u16`; see `computeWithHash`.
const position_spread_multiplier: u16 = 0x9E37;

comptime {
    assert(position_spread_multiplier % 2 == 1);
    assert(position_count_max <= std.math.maxInt(u16));
}

// Compile-time assertions per CLAUDE.md
comptime {
    std.debug.assert(@sizeOf(Fingerprint) == 8);
    std.debug.assert(@bitSizeOf(Fingerprint) == 64);
}

test "fingerprint stability" {
    const fp1 = compute(.button, "Submit", null, 0);
    const fp2 = compute(.button, "Submit", null, 0);
    try std.testing.expect(fp1.eql(fp2));

    // Different name = different fingerprint
    const fp3 = compute(.button, "Cancel", null, 0);
    try std.testing.expect(!fp1.eql(fp3));

    // Different position = different fingerprint
    const fp4 = compute(.button, "Submit", null, 1);
    try std.testing.expect(!fp1.eql(fp4));

    // Different role = different fingerprint
    const fp5 = compute(.checkbox, "Submit", null, 0);
    try std.testing.expect(!fp1.eql(fp5));
}

test "fingerprint with parent" {
    const parent_fp = compute(.group, "Container", null, 0);

    const child1 = compute(.button, "OK", parent_fp, 0);
    const child2 = compute(.button, "OK", parent_fp, 1);
    const child3 = compute(.button, "OK", null, 0);

    // Same name, different position
    try std.testing.expect(!child1.eql(child2));

    // Same name and position, but different parent
    try std.testing.expect(!child1.eql(child3));
}

test "fingerprint null name" {
    const fp1 = compute(.group, null, null, 0);
    const fp2 = compute(.group, null, null, 0);
    const fp3 = compute(.group, "", null, 0);

    // Null names should produce consistent fingerprints
    try std.testing.expect(fp1.eql(fp2));

    // Null vs empty string should differ (empty string has hash, null has 0)
    try std.testing.expect(!fp1.eql(fp3));
}

test "fingerprint invalid sentinel" {
    const valid = compute(.button, "Test", null, 0);
    try std.testing.expect(!valid.eql(Fingerprint.INVALID));
    try std.testing.expect(valid.isValid());
    try std.testing.expect(!Fingerprint.INVALID.isValid());
}

test "fingerprint u64 roundtrip" {
    const fp1 = compute(.slider, "Volume", null, 5);
    const as_u64 = fp1.toU64();
    const fp2 = Fingerprint.fromU64(as_u64);

    try std.testing.expect(fp1.eql(fp2));
    try std.testing.expectEqual(fp1.role, fp2.role);
    try std.testing.expectEqual(fp1.position, fp2.position);
    try std.testing.expectEqual(fp1.name_hash, fp2.name_hash);
}

test "fingerprint determinism across frames" {
    // Simulate multiple frames building the same structure
    var frame_fingerprints: [10]Fingerprint = undefined;

    for (0..10) |frame| {
        frame_fingerprints[frame] = compute(.dialog, "Settings", null, 0);
    }

    // All frames should produce identical fingerprints
    const expected = frame_fingerprints[0];
    for (frame_fingerprints[1..]) |fp| {
        try std.testing.expect(fp.eql(expected));
    }
}

test "siblings past position 255 keep distinct fingerprints" {
    // Goal: same-role, same-name siblings never share a fingerprint at any
    // position a tree can hold. Methodology: compute every position under
    // `position_count_max` for one parent and check none repeats, including
    // the pairs 255 and 256, and 0 and 256, that share a low byte or overflow
    // the 8-bit field.
    const parent = compute(.list, "Items", null, 0);
    var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer seen.deinit();
    var position: u16 = 0;
    while (position < position_count_max) : (position += 1) {
        const fp = compute(.listitem, "Row", parent, position);
        try std.testing.expect(fp.isValid());
        const entry = try seen.getOrPut(fp.toU64());
        try std.testing.expect(!entry.found_existing);
    }
    const at_0 = compute(.listitem, "Row", parent, 0);
    const at_255 = compute(.listitem, "Row", parent, 255);
    const at_256 = compute(.listitem, "Row", parent, 256);
    try std.testing.expect(!at_0.eql(at_256));
    try std.testing.expect(!at_255.eql(at_256));
    try std.testing.expectEqual(at_0.position, at_256.position);
}

test "fingerprint with hash" {
    const name = "TestButton";
    var h = std.hash.Wyhash.init(0);
    h.update(name);
    const name_hash: u32 = @truncate(h.final());

    const fp1 = compute(.button, name, null, 0);
    const fp2 = computeWithHash(.button, name_hash, null, 0);

    try std.testing.expect(fp1.eql(fp2));
}
