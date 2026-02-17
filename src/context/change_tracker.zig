//! ChangeTracker — Fixed-capacity per-frame value change detection
//!
//! Tracks whether values have changed between frames using comptime string keys
//! and runtime value hashing. Designed for the common pattern of "invalidate
//! something when a dependency changes."
//!
//! ## Usage (via `cx.changed()`)
//!
//! ```zig
//! if (cx.changed("dark_mode", s.dark_mode) or cx.changed("window_width", size.width)) {
//!     s.invalidateCachedHeights();
//! }
//! ```
//!
//! ## Semantics
//!
//! - **First call** for a given key: stores the value hash, returns `false`
//!   (no previous value to compare against — matches the "was null" pattern).
//! - **Subsequent calls**: compares against stored hash, updates it, returns
//!   `true` if the value changed.
//!
//! ## Design
//!
//! - Zero allocation after initialization (fixed-capacity parallel arrays)
//! - Linear scan for lookup (cache-friendly for expected entry counts <64)
//! - Value identity via `std.hash.Wyhash` over raw bytes — works for any type

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

/// Hard cap on tracked values per application.
/// Typical apps track 2–10 values; 64 is generous headroom.
pub const MAX_TRACKED_VALUES: u32 = 64;

// =============================================================================
// ChangeTracker
// =============================================================================

pub const ChangeTracker = struct {
    keys: [MAX_TRACKED_VALUES]u32 = [_]u32{0} ** MAX_TRACKED_VALUES,
    value_hashes: [MAX_TRACKED_VALUES]u64 = [_]u64{0} ** MAX_TRACKED_VALUES,
    count: u32 = 0,

    const Self = @This();

    /// Check whether a value has changed since the last call with the same key.
    ///
    /// - `key_hash`: comptime-hashed string identifier (u32)
    /// - `value_hash`: runtime hash of the current value (u64)
    ///
    /// Returns `false` on the first call for a given key (no prior value).
    /// Returns `true` when the value hash differs from the stored one.
    pub fn changed(self: *Self, key_hash: u32, value_hash: u64) bool {
        // Assertion: key_hash must be non-zero (valid hash output)
        std.debug.assert(key_hash != 0);
        // Assertion: we haven't blown past capacity
        std.debug.assert(self.count <= MAX_TRACKED_VALUES);

        // Linear scan for existing entry (cache-friendly for small N)
        const len = self.count;
        for (self.keys[0..len], self.value_hashes[0..len]) |k, *h| {
            if (k == key_hash) {
                if (h.* == value_hash) return false;
                h.* = value_hash;
                return true;
            }
        }

        // New key — store and return false (no previous value to compare)
        std.debug.assert(self.count < MAX_TRACKED_VALUES); // Would exceed capacity — too many tracked values
        self.keys[self.count] = key_hash;
        self.value_hashes[self.count] = value_hash;
        self.count += 1;
        return false;
    }

    /// Reset all tracked values. Useful for testing or full-app state resets.
    pub fn reset(self: *Self) void {
        // Assertion: state is consistent before reset
        std.debug.assert(self.count <= MAX_TRACKED_VALUES);

        self.count = 0;
        // Zero the key slots so stale data can't match
        @memset(&self.keys, 0);
    }

    /// Number of values currently being tracked.
    pub fn trackedCount(self: *const Self) u32 {
        std.debug.assert(self.count <= MAX_TRACKED_VALUES);
        return self.count;
    }
};

// =============================================================================
// Value Hashing
// =============================================================================

/// Hash any value's raw bytes into a u64 for change detection.
///
/// Works for scalars (bool, i32, f32, etc.), small structs, enums, and
/// optionals. For pointer types, hashes the pointer value (address), not
/// the pointee — this is intentional (identity, not deep equality).
pub fn hashValue(comptime T: type, value: T) u64 {
    // Assertion: type has a well-defined memory layout
    std.debug.assert(@sizeOf(T) > 0); // Zero-sized types can't change
    std.debug.assert(@sizeOf(T) <= 256); // Sanity bound — not meant for large structs

    const bytes = std.mem.asBytes(&value);
    return std.hash.Wyhash.hash(0, bytes);
}

// =============================================================================
// Tests
// =============================================================================

test "first call returns false" {
    var tracker = ChangeTracker{};
    const key: u32 = 42;
    const hash = hashValue(bool, true);

    try std.testing.expect(!tracker.changed(key, hash));
    try std.testing.expectEqual(@as(u32, 1), tracker.trackedCount());
}

test "same value returns false" {
    var tracker = ChangeTracker{};
    const key: u32 = 42;

    _ = tracker.changed(key, hashValue(bool, true));
    try std.testing.expect(!tracker.changed(key, hashValue(bool, true)));
    try std.testing.expect(!tracker.changed(key, hashValue(bool, true)));
}

test "different value returns true" {
    var tracker = ChangeTracker{};
    const key: u32 = 42;

    _ = tracker.changed(key, hashValue(bool, false));
    try std.testing.expect(tracker.changed(key, hashValue(bool, true)));
    try std.testing.expectEqual(@as(u32, 1), tracker.trackedCount());
}

test "multiple keys tracked independently" {
    var tracker = ChangeTracker{};
    const key_a: u32 = 1;
    const key_b: u32 = 2;

    _ = tracker.changed(key_a, hashValue(f32, 1.0));
    _ = tracker.changed(key_b, hashValue(f32, 2.0));
    try std.testing.expectEqual(@as(u32, 2), tracker.trackedCount());

    // key_a unchanged, key_b changed
    try std.testing.expect(!tracker.changed(key_a, hashValue(f32, 1.0)));
    try std.testing.expect(tracker.changed(key_b, hashValue(f32, 999.0)));
}

test "value toggles detected each time" {
    var tracker = ChangeTracker{};
    const key: u32 = 7;

    _ = tracker.changed(key, hashValue(bool, false)); // first: false
    try std.testing.expect(tracker.changed(key, hashValue(bool, true))); // changed
    try std.testing.expect(tracker.changed(key, hashValue(bool, false))); // changed back
    try std.testing.expect(!tracker.changed(key, hashValue(bool, false))); // same
}

test "reset clears all state" {
    var tracker = ChangeTracker{};

    _ = tracker.changed(1, hashValue(i32, 10));
    _ = tracker.changed(2, hashValue(i32, 20));
    try std.testing.expectEqual(@as(u32, 2), tracker.trackedCount());

    tracker.reset();
    try std.testing.expectEqual(@as(u32, 0), tracker.trackedCount());

    // After reset, first call returns false again
    try std.testing.expect(!tracker.changed(1, hashValue(i32, 10)));
}

test "hashValue produces distinct hashes for distinct values" {
    const h1 = hashValue(f32, 1.0);
    const h2 = hashValue(f32, 2.0);
    const h3 = hashValue(f32, 1.0);

    try std.testing.expect(h1 != h2);
    try std.testing.expectEqual(h1, h3);
}

test "hashValue works with various types" {
    // bool
    const hf = hashValue(bool, false);
    const ht = hashValue(bool, true);
    try std.testing.expect(hf != ht);

    // i32
    const h0 = hashValue(i32, 0);
    const h1 = hashValue(i32, 1);
    try std.testing.expect(h0 != h1);

    // f64
    const hd1 = hashValue(f64, 3.14);
    const hd2 = hashValue(f64, 2.71);
    try std.testing.expect(hd1 != hd2);

    // enum
    const Direction = enum { up, down, left, right };
    const hu = hashValue(Direction, .up);
    const hdn = hashValue(Direction, .down);
    try std.testing.expect(hu != hdn);
}

test "struct size is bounded" {
    // ChangeTracker should be small enough for stack/embed
    // keys: 64 * 4 = 256 bytes
    // value_hashes: 64 * 8 = 512 bytes
    // count: 4 bytes
    // Total: ~772 bytes + padding
    try std.testing.expect(@sizeOf(ChangeTracker) <= 1024);
    try std.testing.expect(@sizeOf(ChangeTracker) > 0);
}
