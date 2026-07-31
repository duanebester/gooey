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
//! - Value identity via `std.hash.Wyhash`, fed *structurally* (field-by-field
//!   for structs, by content for slices) rather than over the raw value bytes.
//!   See `hashValue` for why raw-byte hashing was a correctness bug.

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

        // New key — store and return false (no previous value to compare).
        //
        // Capacity guard is an UNCONDITIONAL runtime check, not std.debug.assert:
        // the assert strips in ReleaseFast/ReleaseSmall (the builds users ship),
        // and the very next line writes at index self.count into fixed [64] arrays.
        // A stripped check would turn the 65th distinct key into an out-of-bounds
        // write — memory corruption rather than a clean failure (rules 4, 11, 17).
        // Fail fast: exceeding the hard cap means the caller is minting unbounded
        // distinct cx.changed() ids, which is a programming error, not a runtime
        // condition to degrade past. Matches entity.zig's release-safe @panic guard.
        if (self.count >= MAX_TRACKED_VALUES) {
            @panic("ChangeTracker capacity exceeded: too many distinct cx.changed() keys (max 64)");
        }
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

/// Hash a value into a u64 for change detection.
///
/// The hash is fed *structurally*, not from the value's raw bytes, because
/// raw-byte hashing had two correctness bugs that read as the opposite of
/// what a function named `changed` implies (rules 3 and 21):
///
///   1. **Struct padding.** `std.mem.asBytes(&value)` includes a struct's
///      uninitialised padding bytes, so two structs equal in every field
///      could hash differently → a spurious "changed" (the rule-21
///      buffer-bleed hazard surfacing as a correctness bug). Hashing
///      field-by-field never touches padding.
///   2. **Slices compared by address.** A `[]const u8` fat pointer hashed
///      by its (ptr, len) bytes tracks the *address*, not the *content* —
///      so an in-place string edit could be missed, and an identical string
///      at a new address could spuriously fire. Slices are now hashed by
///      content, which is what change detection actually wants.
///
/// Type support: ints, floats, bools, enums, optionals, arrays, slices, and
/// structs composed of those. Non-slice pointers hash the address (identity,
/// not the pointee — following it could dangle); this is intentional and
/// documented on `cx.changed`. Unsupported types (unions, error sets, …)
/// `@compileError` rather than silently hashing ambiguous bytes.
pub fn hashValue(comptime T: type, value: T) u64 {
    std.debug.assert(@sizeOf(T) > 0); // Zero-sized types can't change

    var hasher = std.hash.Wyhash.init(0);
    hashInto(&hasher, T, value);
    return hasher.final();
}

/// True for scalar types with no padding, whose contiguous memory is safe to
/// hash as a single byte span (lets `[]const u8` and other flat slices hash in
/// one `update` call instead of one call per element).
fn isFlatlyHashable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => true,
        else => false,
    };
}

/// Feed `value` into `hasher` structurally. Recurses over *types* at comptime
/// (not over runtime data), and every recursion strictly shrinks the type:
/// aggregates recurse into their element/field types and pointers stop at the
/// address, so the expansion always terminates. This is unlike the rule-6
/// runtime-recursion ban, which targets unbounded traversal of dynamic data.
fn hashInto(hasher: *std.hash.Wyhash, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        // Scalars: hash the raw bytes. Floats are hashed bytewise on purpose —
        // `std.hash.autoHash` rejects them, and for change detection bitwise
        // identity is exactly the "is the value I stored still the same"
        // question we want (incl. treating -0.0 and +0.0 as distinct).
        .int, .float, .bool, .@"enum" => {
            hasher.update(std.mem.asBytes(&value));
        },
        // Slices: hash length + contents. `[]const u8` (strings) and every
        // other `[]T` therefore compare by value, not by fat-pointer address.
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                const len: usize = value.len;
                hasher.update(std.mem.asBytes(&len));
                if (comptime isFlatlyHashable(ptr.child)) {
                    hasher.update(std.mem.sliceAsBytes(value));
                } else {
                    for (value) |element| hashInto(hasher, ptr.child, element);
                }
            } else {
                // Single/many/C pointers: hash the address (identity). The
                // pointee's lifetime is the caller's concern; following it
                // could dangle. Documented on `cx.changed`.
                const address: usize = @intFromPtr(value);
                hasher.update(std.mem.asBytes(&address));
            }
        },
        // Structs: hash each field so padding bytes never enter the hash.
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                hashInto(hasher, field.type, @field(value, field.name));
            }
        },
        // Optionals: hash a presence tag, then the payload when present. This
        // distinguishes `null` from a zero payload and skips the optional's
        // own padding.
        .optional => |info| {
            if (value) |payload| {
                hasher.update(&[_]u8{1});
                hashInto(hasher, info.child, payload);
            } else {
                hasher.update(&[_]u8{0});
            }
        },
        // Arrays: element-by-element, same padding rationale as structs.
        .array => |info| {
            if (comptime isFlatlyHashable(info.child)) {
                hasher.update(std.mem.sliceAsBytes(value[0..]));
            } else {
                for (value) |element| hashInto(hasher, info.child, element);
            }
        },
        else => {
            @compileError("cx.changed: unsupported value type '" ++ @typeName(T) ++
                "'. Supported: ints, floats, bools, enums, optionals, arrays, " ++
                "slices, and structs composed of those.");
        },
    }
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

test "strings hash by content, not address" {
    // The motivating bug: a `[]const u8` must compare by content so an
    // in-place edit registers as changed and an identical string at a
    // different address does not.
    var buf_a = [_]u8{ 'h', 'i' };
    var buf_b = [_]u8{ 'h', 'i' };
    const from_a: []const u8 = buf_a[0..];
    const from_b: []const u8 = buf_b[0..];

    // Same content at two different addresses → same hash.
    try std.testing.expectEqual(
        hashValue([]const u8, from_a),
        hashValue([]const u8, from_b),
    );

    // Different content → different hash.
    const hello = hashValue([]const u8, "hello");
    const world = hashValue([]const u8, "world");
    try std.testing.expect(hello != world);

    // An in-place edit at the *same* address must be detected as changed.
    var tracker = ChangeTracker{};
    const key: u32 = 99;
    _ = tracker.changed(key, hashValue([]const u8, buf_a[0..])); // first: false
    buf_a[1] = 'o'; // "hi" -> "ho", same backing memory
    try std.testing.expect(tracker.changed(key, hashValue([]const u8, buf_a[0..])));
}

test "structs with padding hash by field, not raw bytes" {
    // A struct whose layout has padding (bool + u32) must hash purely from its
    // field values, so two field-equal instances never diverge on stale
    // padding (the rule-21 buffer-bleed hazard as a correctness bug).
    const Padded = struct { flag: bool, count: u32 };

    // Build two instances from differently-initialised backing memory so any
    // padding bytes are likely to differ, then set identical field values.
    var raw_a: [8]u8 = [_]u8{0xAA} ** 8;
    var raw_b: [8]u8 = [_]u8{0x55} ** 8;
    const a: *Padded = @ptrCast(@alignCast(&raw_a));
    const b: *Padded = @ptrCast(@alignCast(&raw_b));
    a.* = .{ .flag = true, .count = 7 };
    b.* = .{ .flag = true, .count = 7 };

    try std.testing.expectEqual(hashValue(Padded, a.*), hashValue(Padded, b.*));

    // A real field change is still detected.
    const changed_count: Padded = .{ .flag = true, .count = 8 };
    try std.testing.expect(hashValue(Padded, a.*) != hashValue(Padded, changed_count));
}

test "optionals distinguish null from payload" {
    const none: ?u32 = null;
    const zero: ?u32 = 0;
    const one: ?u32 = 1;

    try std.testing.expect(hashValue(?u32, none) != hashValue(?u32, zero));
    try std.testing.expect(hashValue(?u32, zero) != hashValue(?u32, one));
    try std.testing.expectEqual(hashValue(?u32, one), hashValue(?u32, @as(?u32, 1)));
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
