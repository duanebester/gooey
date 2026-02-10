//! TextPool — Fixed-capacity string arena for draw command text.
//!
//! Push strings in, get them back by `u16` index. Text commands in
//! `DrawCommand` store a `text_idx: u16` that references entries here
//! rather than holding string slices (which contain pointers — not
//! serializable, not safely storable across frames, and break the
//! "no allocation" rule).
//!
//! Properties:
//! - Zero allocation — everything lives in fixed arrays
//! - O(1) push and get — index-based, no searching
//! - Cleared per batch — when AI sends a new batch, old strings are released
//! - 16KB limit — plenty for labels, annotations, paragraphs; fail-fast if exceeded

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

/// Total byte capacity for all pooled strings combined.
pub const MAX_TEXT_POOL_SIZE: usize = 16_384;

/// Maximum number of distinct string entries.
pub const MAX_TEXT_ENTRIES: usize = 256;

/// Maximum byte length for a single string entry.
pub const MAX_TEXT_ENTRY_SIZE: usize = 512;

// =============================================================================
// TextPool
// =============================================================================

pub const TextPool = struct {
    /// Flat byte buffer holding all string data contiguously.
    buffer: [MAX_TEXT_POOL_SIZE]u8 = undefined,

    /// Start offset of each entry within `buffer`.
    offsets: [MAX_TEXT_ENTRIES]u16 = undefined,

    /// Byte length of each entry.
    lengths: [MAX_TEXT_ENTRIES]u16 = undefined,

    /// Number of entries currently stored.
    count: u16 = 0,

    /// Number of bytes currently used in `buffer`.
    used: u16 = 0,

    const Self = @This();

    /// Push a string into the pool and return its index.
    ///
    /// Returns `null` if the pool is full (entry count or byte capacity
    /// exhausted). This is a fail-fast design — callers should handle
    /// the null and skip the command rather than crash.
    pub fn push(self: *Self, text: []const u8) ?u16 {
        // Per CLAUDE.md #3: assert at API boundary.
        std.debug.assert(text.len <= MAX_TEXT_ENTRY_SIZE);
        std.debug.assert(text.len <= std.math.maxInt(u16));

        if (self.count >= MAX_TEXT_ENTRIES) return null;
        if (@as(usize, self.used) + text.len > MAX_TEXT_POOL_SIZE) return null;

        const idx = self.count;
        const offset = self.used;
        const text_len: u16 = @intCast(text.len);

        @memcpy(self.buffer[offset .. offset + text_len], text);
        self.offsets[idx] = offset;
        self.lengths[idx] = text_len;
        self.count += 1;
        self.used += text_len;
        return idx;
    }

    /// Retrieve a string by its pool index.
    pub fn get(self: *const Self, idx: u16) []const u8 {
        // Per CLAUDE.md #3 + #11: assert the positive case, trap the negative.
        std.debug.assert(idx < self.count);

        const offset = self.offsets[idx];
        const length = self.lengths[idx];
        return self.buffer[offset .. offset + length];
    }

    /// Reset the pool for the next batch of commands.
    ///
    /// O(1) — just resets counters; buffer contents become garbage but are
    /// never read past `used`.
    pub fn clear(self: *Self) void {
        self.count = 0;
        self.used = 0;
    }

    /// Returns the number of entries currently stored.
    pub fn entryCount(self: *const Self) u16 {
        return self.count;
    }

    /// Returns the number of buffer bytes currently used.
    pub fn bytesUsed(self: *const Self) u16 {
        return self.used;
    }

    /// Returns remaining byte capacity in the buffer.
    pub fn bytesRemaining(self: *const Self) usize {
        return MAX_TEXT_POOL_SIZE - @as(usize, self.used);
    }

    /// Returns remaining entry slots.
    pub fn entriesRemaining(self: *const Self) usize {
        return MAX_TEXT_ENTRIES - @as(usize, self.count);
    }
};

// =============================================================================
// Compile-time Assertions (CLAUDE.md rules #3, #4)
// =============================================================================

comptime {
    // Size budget: pool must stay under 20KB for predictable memory layout.
    // buffer (16KB) + offsets (512B) + lengths (512B) + count (2B) + used (2B) ≈ 17KB
    std.debug.assert(@sizeOf(TextPool) < 20 * 1024);

    // Entry size must fit in u16 offset/length fields.
    std.debug.assert(MAX_TEXT_POOL_SIZE <= std.math.maxInt(u16) + 1);
    std.debug.assert(MAX_TEXT_ENTRY_SIZE <= std.math.maxInt(u16));

    // MAX_TEXT_ENTRIES must fit in u16 count field.
    std.debug.assert(MAX_TEXT_ENTRIES <= std.math.maxInt(u16));
}

// =============================================================================
// Tests
// =============================================================================

test "TextPool size under 20KB" {
    try std.testing.expect(@sizeOf(TextPool) < 20 * 1024);
}

test "TextPool push/get roundtrip" {
    var pool = TextPool{};

    const idx0 = pool.push("hello").?;
    const idx1 = pool.push("world").?;
    const idx2 = pool.push("").?; // empty string is valid

    try std.testing.expectEqual(@as(u16, 0), idx0);
    try std.testing.expectEqual(@as(u16, 1), idx1);
    try std.testing.expectEqual(@as(u16, 2), idx2);

    try std.testing.expectEqualStrings("hello", pool.get(idx0));
    try std.testing.expectEqualStrings("world", pool.get(idx1));
    try std.testing.expectEqualStrings("", pool.get(idx2));

    try std.testing.expectEqual(@as(u16, 3), pool.entryCount());
    try std.testing.expectEqual(@as(u16, 10), pool.bytesUsed()); // "hello" + "world" = 10
}

test "TextPool entry capacity returns null when full" {
    var pool = TextPool{};

    // Fill all entry slots with tiny strings.
    var i: usize = 0;
    while (i < MAX_TEXT_ENTRIES) : (i += 1) {
        const result = pool.push("x");
        try std.testing.expect(result != null);
    }

    try std.testing.expectEqual(@as(u16, MAX_TEXT_ENTRIES), pool.entryCount());

    // Next push must return null — entry slots exhausted.
    try std.testing.expect(pool.push("overflow") == null);
}

test "TextPool byte capacity returns null when full" {
    var pool = TextPool{};

    // Push a 512-byte string (MAX_TEXT_ENTRY_SIZE) repeatedly until buffer is full.
    const big = "A" ** MAX_TEXT_ENTRY_SIZE;
    const max_fits = MAX_TEXT_POOL_SIZE / MAX_TEXT_ENTRY_SIZE; // 16384 / 512 = 32

    var i: usize = 0;
    while (i < max_fits) : (i += 1) {
        const result = pool.push(big);
        try std.testing.expect(result != null);
    }

    try std.testing.expectEqual(@as(u16, @intCast(max_fits)), pool.entryCount());
    try std.testing.expectEqual(@as(u16, @intCast(MAX_TEXT_POOL_SIZE)), pool.bytesUsed());

    // Buffer is exactly full. Even a 1-byte push must fail.
    try std.testing.expect(pool.push("x") == null);
}

test "TextPool clear resets and allows reuse" {
    var pool = TextPool{};

    _ = pool.push("before clear");
    _ = pool.push("also before");
    try std.testing.expectEqual(@as(u16, 2), pool.entryCount());
    try std.testing.expect(pool.bytesUsed() > 0);

    pool.clear();

    try std.testing.expectEqual(@as(u16, 0), pool.entryCount());
    try std.testing.expectEqual(@as(u16, 0), pool.bytesUsed());
    try std.testing.expectEqual(@as(usize, MAX_TEXT_POOL_SIZE), pool.bytesRemaining());
    try std.testing.expectEqual(@as(usize, MAX_TEXT_ENTRIES), pool.entriesRemaining());

    // Can push again after clear.
    const idx = pool.push("after clear").?;
    try std.testing.expectEqual(@as(u16, 0), idx);
    try std.testing.expectEqualStrings("after clear", pool.get(idx));
}

test "TextPool sequential indices are contiguous" {
    var pool = TextPool{};

    const strings = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo" };
    var indices: [strings.len]u16 = undefined;

    for (strings, 0..) |s, i| {
        indices[i] = pool.push(s).?;
        try std.testing.expectEqual(@as(u16, @intCast(i)), indices[i]);
    }

    // Verify all strings are retrievable and correct.
    for (strings, 0..) |expected, i| {
        try std.testing.expectEqualStrings(expected, pool.get(indices[i]));
    }
}

test "TextPool bytesRemaining and entriesRemaining" {
    var pool = TextPool{};

    try std.testing.expectEqual(@as(usize, MAX_TEXT_POOL_SIZE), pool.bytesRemaining());
    try std.testing.expectEqual(@as(usize, MAX_TEXT_ENTRIES), pool.entriesRemaining());

    _ = pool.push("test"); // 4 bytes

    try std.testing.expectEqual(@as(usize, MAX_TEXT_POOL_SIZE - 4), pool.bytesRemaining());
    try std.testing.expectEqual(@as(usize, MAX_TEXT_ENTRIES - 1), pool.entriesRemaining());
}

test "TextPool handles max entry size exactly" {
    var pool = TextPool{};

    // A string of exactly MAX_TEXT_ENTRY_SIZE should succeed.
    const max_str = "B" ** MAX_TEXT_ENTRY_SIZE;
    const idx = pool.push(max_str);
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(usize, MAX_TEXT_ENTRY_SIZE), pool.get(idx.?).len);
}

test "TextPool preserves binary content" {
    var pool = TextPool{};

    // Push bytes including nulls and high bytes — pool is byte-agnostic.
    const binary = &[_]u8{ 0x00, 0xFF, 0x42, 0x00, 0x7F };
    const idx = pool.push(binary).?;
    const got = pool.get(idx);

    try std.testing.expectEqual(@as(usize, 5), got.len);
    try std.testing.expectEqual(@as(u8, 0x00), got[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), got[1]);
    try std.testing.expectEqual(@as(u8, 0x42), got[2]);
    try std.testing.expectEqual(@as(u8, 0x00), got[3]);
    try std.testing.expectEqual(@as(u8, 0x7F), got[4]);
}
