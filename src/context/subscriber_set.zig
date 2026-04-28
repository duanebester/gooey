//! `SubscriberSet(Key, Callback, cap)` — generic fixed-capacity slot map for
//! "register N callbacks keyed by K, iterate them, swap-remove on cleanup."
//!
//! Rationale (cleanup item #8 in `docs/architectural-cleanup-plan.md`):
//!
//! Five distinct ad-hoc registries on `Gooey` all share the same shape:
//!
//!   - `blur_handlers: [64]?BlurHandlerEntry`     (FocusId → BlurCallback)
//!   - `cancel_groups: [64]*Io.Group`              (() → *Io.Group)
//!   - `pending_image_hashes: [64]u64`             (folded into AssetCache PR1)
//!   - `failed_image_hashes:  [128]u64`            (folded into AssetCache PR1)
//!   - `deferred_commands:   [32]DeferredCommand`  (kept on Gooey for now)
//!
//! Rather than copy-paste the same swap-remove / iterate / capacity-cap
//! logic into each, this generic owns the slot-map invariants once and
//! every consumer composes it.
//!
//! ## Design choices
//!
//! - **Fixed capacity at comptime.** Per `CLAUDE.md` §2 and §4: every
//!   subsystem has a hard cap, declared by the consumer at instantiation.
//!   Insert past capacity returns `Insertion.dropped` so the caller can
//!   surface the limit violation (warn-and-drop or assert, depending on
//!   the criticality of the registry).
//!
//! - **Keys are comptime-generic.** Callers pick the key (`FocusId`, the
//!   trivial `void` for "tag-less" sets like cancel groups, an interned
//!   string ID, etc). Equality goes through a comptime function pointer
//!   so we don't bake `std.meta.eql` semantics into hot loops — `Group`
//!   pointers want pointer-equality, `[]const u8` IDs want
//!   `std.mem.eql`, and so on. See `Options.keysEqual`.
//!
//! - **No allocations.** Backing is `[cap]?Entry`. Swap-remove keeps the
//!   used prefix dense, so iteration cost is O(used), not O(cap).
//!
//! - **No RAII handle yet.** GPUI uses RAII `Subscription` to remove on
//!   drop; that's a follow-up (cleanup item #8 calls it out). For now,
//!   removal is explicit (`removeWhere`) — matches the existing
//!   call-site shape of `BlurHandlerRegistry` / `CancelRegistry` and
//!   keeps PR 3 a pure refactor.
//!
//! - **Two consumers in PR 3** (`BlurHandlerRegistry`, `CancelRegistry`)
//!   to validate the generic shape on real callers, per the PR 3
//!   "Definition of done" in `docs/cleanup-implementation-plan.md`.
//!   PR 8 (`element_states`) leans on the same generic for its
//!   listener storage.

const std = @import("std");

// =============================================================================
// Options
// =============================================================================

/// Configuration for a `SubscriberSet` instantiation.
///
/// Per `CLAUDE.md` §9 (named arguments via `options: struct`): a single
/// comptime struct so adding future knobs (RAII handles, retain-on-iter
/// semantics) does not break call sites. The two `u64`s in the original
/// design — `Key` and `cap` — are pulled into `Options` for the same
/// reason: a function taking two integers must use an options struct.
pub fn Options(comptime Key: type, comptime Callback: type) type {
    return struct {
        /// Hard capacity. Insert past this returns `.dropped`.
        capacity: u32,

        /// Equality predicate for keys. Defaults to `std.meta.eql`,
        /// which is the right answer for primitive keys (`u32`,
        /// `FocusId`, opaque pointer wrappers) but wrong for
        /// `[]const u8` IDs (compares slice headers, not contents).
        ///
        /// Pass an explicit comparator for slice-keyed sets:
        /// ```
        /// .keysEqual = struct {
        ///     fn eq(a: []const u8, b: []const u8) bool {
        ///         return std.mem.eql(u8, a, b);
        ///     }
        /// }.eq,
        /// ```
        keysEqual: *const fn (Key, Key) bool = defaultKeysEqual(Key),

        // Type info threaded through so `SubscriberSet` doesn't need to
        // re-derive them from `Options`. Comptime-only — zero runtime
        // cost.
        const KeyType = Key;
        const CallbackType = Callback;
    };
}

/// Default key equality: `std.meta.eql`. Works for primitives, packed
/// integers, and POD structs. For `[]const u8` IDs, override via
/// `Options.keysEqual`.
fn defaultKeysEqual(comptime Key: type) *const fn (Key, Key) bool {
    return struct {
        fn eq(a: Key, b: Key) bool {
            return std.meta.eql(a, b);
        }
    }.eq;
}

// =============================================================================
// SubscriberSet
// =============================================================================

/// Outcome of `insert`. The caller is responsible for translating
/// `dropped` into a warning, assertion, or fatal — depends on the
/// registry's criticality. Callers never silently discard.
pub const Insertion = enum {
    inserted,
    /// An existing entry with the same key was overwritten.
    replaced,
    /// At-capacity; entry was not stored.
    dropped,
};

/// Module-private alias used to re-export `Insertion` from inside the
/// generic struct body without re-importing the module by name.
const ModuleInsertion = Insertion;

/// Generic fixed-capacity subscriber set.
///
/// Type parameters:
///   - `Key`: comptime key type (primitive, struct, or slice).
///   - `Callback`: payload type stored alongside the key.
///   - `options`: compile-time `Options(Key, Callback)`.
///
/// Storage is `[cap]?Entry`, with `count` tracking the dense used
/// prefix. Removed slots are filled by swap-remove from the tail so
/// iteration cost is O(count), not O(cap).
pub fn SubscriberSet(
    comptime Key: type,
    comptime Callback: type,
    comptime options: Options(Key, Callback),
) type {
    comptime std.debug.assert(options.capacity > 0);
    comptime std.debug.assert(options.capacity <= std.math.maxInt(u32));

    return struct {
        const Self = @This();

        // Re-export type info for consumers that want to introspect the
        // generic at the use site without re-listing all three params.
        pub const KeyT = Key;
        pub const CallbackT = Callback;
        pub const CAPACITY: u32 = options.capacity;

        // Re-export the module-level `Insertion` enum so callers can
        // refer to outcomes via `MySet.Insertion.inserted` instead of
        // reaching into the parent module — keeps the consumer's
        // import surface narrow. Aliased through `ModuleInsertion`
        // (private to the module) so the generic body can return
        // `ModuleInsertion` without colliding with this `pub const`.
        pub const Insertion = ModuleInsertion;

        /// One slot. Optional so `clear` can null-stomp without caring
        /// about partial-init state of the payload types. Iteration
        /// only walks `entries[0..count]`, so the `null` branch is a
        /// defensive belt — the invariant is that the used prefix is
        /// fully populated.
        pub const Entry = struct {
            key: Key,
            callback: Callback,
        };

        /// Backing storage. `entries[0..count]` is the dense used
        /// prefix; everything from `count..CAPACITY` is `null` and must
        /// not be read.
        entries: [options.capacity]?Entry,

        /// Number of populated slots. Invariant:
        /// `entries[i] != null` for all `i < count`.
        count: u32,

        // -------------------------------------------------------------------------
        // Lifecycle
        // -------------------------------------------------------------------------

        /// Empty subscriber set. `count == 0`, all slots `null`.
        pub fn init() Self {
            return .{
                .entries = [_]?Entry{null} ** options.capacity,
                .count = 0,
            };
        }

        /// In-place initialization. Use this for sets embedded in a
        /// large parent struct (per `CLAUDE.md` §13) — avoids a stack
        /// temp from `init()`'s struct literal when the surrounding
        /// frame is already tight on budget.
        pub fn initInPlace(self: *Self) void {
            // Field-by-field init — no struct literal, no stack temp.
            // For `capacity = 64` this is 64 slot writes, which the
            // compiler lowers to a memset of the optional tag bytes.
            var i: u32 = 0;
            while (i < options.capacity) : (i += 1) {
                self.entries[i] = null;
            }
            self.count = 0;
        }

        // -------------------------------------------------------------------------
        // Inspection
        // -------------------------------------------------------------------------

        /// `true` iff `count == 0`.
        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        /// `true` iff inserting one more entry would not exceed capacity.
        pub fn hasRoom(self: *const Self) bool {
            return self.count < options.capacity;
        }

        /// Number of populated slots.
        pub fn len(self: *const Self) u32 {
            std.debug.assert(self.count <= options.capacity);
            return self.count;
        }

        /// Find the index of the first entry whose key matches `key`,
        /// or `null` if none. Linear scan over the dense used prefix.
        pub fn find(self: *const Self, key: Key) ?u32 {
            std.debug.assert(self.count <= options.capacity);
            var i: u32 = 0;
            while (i < self.count) : (i += 1) {
                // Slots in `[0..count)` are guaranteed populated by the
                // invariant maintained by `insert` / `removeAt`.
                if (self.entries[i]) |entry| {
                    if (options.keysEqual(entry.key, key)) return i;
                } else {
                    // Defensive: if a null slips into the used prefix
                    // we have a real bug. Surface it loudly.
                    unreachable;
                }
            }
            return null;
        }

        /// `true` iff any entry has key `key`.
        pub fn contains(self: *const Self, key: Key) bool {
            return self.find(key) != null;
        }

        /// Borrow a const reference to the callback for `key`, or
        /// `null` if absent. Pointer is invalidated by any subsequent
        /// `insert` / `removeAt` / `clear`.
        pub fn getCallback(self: *const Self, key: Key) ?*const Callback {
            const idx = self.find(key) orelse return null;
            // `self.entries[idx]` is non-null by the find post-condition.
            return &self.entries[idx].?.callback;
        }

        // -------------------------------------------------------------------------
        // Mutation
        // -------------------------------------------------------------------------

        /// Insert (or replace) a (key, callback) pair.
        ///
        /// - If a matching key exists, the callback is overwritten and
        ///   `.replaced` is returned.
        /// - Else if there is room, the entry is appended at index
        ///   `count` and `.inserted` is returned.
        /// - Else the entry is dropped (`.dropped`). The caller decides
        ///   what to do (warn, assert, abort).
        ///
        /// O(count) — the linear scan dominates.
        pub fn insert(self: *Self, key: Key, callback: Callback) ModuleInsertion {
            std.debug.assert(self.count <= options.capacity);

            if (self.find(key)) |idx| {
                self.entries[idx] = .{ .key = key, .callback = callback };
                return .replaced;
            }

            if (self.count >= options.capacity) {
                return .dropped;
            }

            self.entries[self.count] = .{ .key = key, .callback = callback };
            self.count += 1;
            return .inserted;
        }

        /// Remove the entry at index `idx` via swap-remove. The entry
        /// at `count - 1` is moved into slot `idx`, and `count` is
        /// decremented. Order is not preserved.
        ///
        /// Asserts `idx < count` — out-of-range removal is a
        /// programming error, not a runtime condition.
        pub fn removeAt(self: *Self, idx: u32) void {
            std.debug.assert(idx < self.count);
            std.debug.assert(self.count <= options.capacity);

            self.count -= 1;
            if (idx < self.count) {
                // Swap tail into `idx`. The tail slot was guaranteed
                // populated by the same invariant.
                self.entries[idx] = self.entries[self.count];
            }
            self.entries[self.count] = null;
        }

        /// Remove the first entry whose key matches `key`. Returns
        /// `true` iff an entry was actually removed. O(count).
        pub fn remove(self: *Self, key: Key) bool {
            const idx = self.find(key) orelse return false;
            self.removeAt(idx);
            return true;
        }

        /// Remove every entry for which `predicate(key, callback)`
        /// returns `true`. Iterates over indices in reverse so
        /// swap-removes during the walk don't skip subsequent entries.
        ///
        /// Returns the count of removed entries.
        pub fn removeWhere(
            self: *Self,
            context: anytype,
            comptime predicate: fn (@TypeOf(context), Key, Callback) bool,
        ) u32 {
            std.debug.assert(self.count <= options.capacity);
            if (self.count == 0) return 0;

            var removed: u32 = 0;
            // Reverse walk: i goes from count-1 down to 0. After a
            // swap-remove at i, the new entry at i is one we have not
            // visited yet — but its index is < i, and we keep
            // decrementing, so we'll still hit it.
            var i: u32 = self.count;
            while (i > 0) {
                i -= 1;
                if (self.entries[i]) |entry| {
                    if (predicate(context, entry.key, entry.callback)) {
                        self.removeAt(i);
                        removed += 1;
                    }
                } else {
                    unreachable;
                }
            }
            return removed;
        }

        /// Clear every populated slot. Equivalent to:
        ///   `while (count > 0) removeAt(count - 1);`
        /// but cheaper — single bulk null-stomp of the used prefix.
        pub fn clear(self: *Self) void {
            std.debug.assert(self.count <= options.capacity);
            var i: u32 = 0;
            while (i < self.count) : (i += 1) {
                self.entries[i] = null;
            }
            self.count = 0;
        }

        // -------------------------------------------------------------------------
        // Iteration
        // -------------------------------------------------------------------------

        /// Slice over the populated prefix. Caller must NOT mutate the
        /// set during iteration — use `forEach` or `removeWhere` for
        /// that. Slots are guaranteed non-null over `[0..count)`.
        pub fn slice(self: *Self) []?Entry {
            std.debug.assert(self.count <= options.capacity);
            return self.entries[0..self.count];
        }

        /// Const slice — same shape as `slice`, but read-only.
        pub fn sliceConst(self: *const Self) []const ?Entry {
            std.debug.assert(self.count <= options.capacity);
            return self.entries[0..self.count];
        }

        /// Invoke `visitor(context, key, *callback)` for each entry.
        /// The callback is passed by mutable pointer so visitors can
        /// update state in place (e.g. animation timers). The set
        /// itself must NOT be mutated from within the visitor —
        /// use `removeWhere` for conditional removal.
        pub fn forEach(
            self: *Self,
            context: anytype,
            comptime visitor: fn (@TypeOf(context), Key, *Callback) void,
        ) void {
            std.debug.assert(self.count <= options.capacity);
            var i: u32 = 0;
            while (i < self.count) : (i += 1) {
                if (self.entries[i]) |*entry_ptr| {
                    visitor(context, entry_ptr.*.key, &entry_ptr.*.callback);
                } else {
                    unreachable;
                }
            }
        }
    };
}

// =============================================================================
// Tests
// =============================================================================
//
// Goal: lock down the slot-map invariants so the two PR 3 consumers
// (`BlurHandlerRegistry`, `CancelRegistry`) and the future PR 8 consumer
// (`element_states`) can rely on them without reading the body.
//
// Methodology: exercise each public method on a small `u32`-keyed set
// and verify the dense-prefix invariant after every mutation.

const testing = std.testing;

const TestSet = SubscriberSet(u32, u64, .{ .capacity = 4 });

fn assertDensePrefix(set: *const TestSet) !void {
    // Every slot in `[0..count)` is populated; every slot in
    // `[count..CAPACITY)` is null. This is the load-bearing invariant
    // the rest of the methods depend on.
    var i: u32 = 0;
    while (i < TestSet.CAPACITY) : (i += 1) {
        if (i < set.count) {
            try testing.expect(set.entries[i] != null);
        } else {
            try testing.expect(set.entries[i] == null);
        }
    }
}

test "SubscriberSet: init produces an empty, dense-prefix set" {
    var set = TestSet.init();
    try testing.expectEqual(@as(u32, 0), set.len());
    try testing.expect(set.isEmpty());
    try testing.expect(set.hasRoom());
    try assertDensePrefix(&set);
}

test "SubscriberSet: initInPlace matches init shape" {
    var set: TestSet = undefined;
    set.initInPlace();
    try testing.expectEqual(@as(u32, 0), set.len());
    try assertDensePrefix(&set);
}

test "SubscriberSet: insert appends and tracks count" {
    var set = TestSet.init();

    try testing.expectEqual(TestSet.Insertion.inserted, set.insert(1, 100));
    try testing.expectEqual(TestSet.Insertion.inserted, set.insert(2, 200));
    try testing.expectEqual(@as(u32, 2), set.len());
    try testing.expect(set.contains(1));
    try testing.expect(set.contains(2));
    try testing.expect(!set.contains(3));
    try assertDensePrefix(&set);
}

test "SubscriberSet: insert with existing key replaces, does not grow" {
    var set = TestSet.init();
    _ = set.insert(1, 100);
    _ = set.insert(2, 200);

    try testing.expectEqual(TestSet.Insertion.replaced, set.insert(1, 999));
    try testing.expectEqual(@as(u32, 2), set.len());

    const cb = set.getCallback(1) orelse return error.Missing;
    try testing.expectEqual(@as(u64, 999), cb.*);
    try assertDensePrefix(&set);
}

test "SubscriberSet: insert past capacity returns .dropped" {
    var set = TestSet.init();
    _ = set.insert(1, 100);
    _ = set.insert(2, 200);
    _ = set.insert(3, 300);
    _ = set.insert(4, 400);

    // Set is full — fifth insert must drop, not corrupt.
    try testing.expect(!set.hasRoom());
    try testing.expectEqual(TestSet.Insertion.dropped, set.insert(5, 500));
    try testing.expectEqual(@as(u32, 4), set.len());
    try testing.expect(!set.contains(5));
    try assertDensePrefix(&set);
}

test "SubscriberSet: remove preserves dense prefix via swap-remove" {
    var set = TestSet.init();
    _ = set.insert(1, 100);
    _ = set.insert(2, 200);
    _ = set.insert(3, 300);

    // Remove the middle entry. Tail (key=3) should land in slot 1.
    try testing.expect(set.remove(2));
    try testing.expectEqual(@as(u32, 2), set.len());
    try testing.expect(set.contains(1));
    try testing.expect(!set.contains(2));
    try testing.expect(set.contains(3));
    try assertDensePrefix(&set);
}

test "SubscriberSet: remove of absent key returns false, no state change" {
    var set = TestSet.init();
    _ = set.insert(1, 100);

    try testing.expect(!set.remove(42));
    try testing.expectEqual(@as(u32, 1), set.len());
    try assertDensePrefix(&set);
}

test "SubscriberSet: removeWhere matches and clears multiple entries" {
    var set = TestSet.init();
    _ = set.insert(1, 100);
    _ = set.insert(2, 200);
    _ = set.insert(3, 300);
    _ = set.insert(4, 400);

    // Drop every even key — 2 and 4 should go.
    const Predicate = struct {
        fn isEven(_: void, key: u32, _: u64) bool {
            return key % 2 == 0;
        }
    };
    const removed = set.removeWhere({}, Predicate.isEven);
    try testing.expectEqual(@as(u32, 2), removed);
    try testing.expectEqual(@as(u32, 2), set.len());
    try testing.expect(set.contains(1));
    try testing.expect(!set.contains(2));
    try testing.expect(set.contains(3));
    try testing.expect(!set.contains(4));
    try assertDensePrefix(&set);
}

test "SubscriberSet: clear empties the set without touching capacity" {
    var set = TestSet.init();
    _ = set.insert(1, 100);
    _ = set.insert(2, 200);
    _ = set.insert(3, 300);

    set.clear();
    try testing.expectEqual(@as(u32, 0), set.len());
    try testing.expect(set.isEmpty());
    try testing.expect(set.hasRoom());
    try assertDensePrefix(&set);

    // Capacity is unchanged — we can re-insert immediately.
    try testing.expectEqual(TestSet.Insertion.inserted, set.insert(7, 700));
    try assertDensePrefix(&set);
}

test "SubscriberSet: forEach visits exactly the populated prefix" {
    var set = TestSet.init();
    _ = set.insert(10, 1);
    _ = set.insert(20, 2);
    _ = set.insert(30, 3);

    var sum: u64 = 0;
    const Visitor = struct {
        fn add(acc: *u64, _: u32, cb: *u64) void {
            acc.* += cb.*;
        }
    };
    set.forEach(&sum, Visitor.add);
    try testing.expectEqual(@as(u64, 6), sum);
}

test "SubscriberSet: getCallback returns null for absent key" {
    var set = TestSet.init();
    _ = set.insert(1, 100);
    try testing.expectEqual(@as(?*const u64, null), set.getCallback(99));
    try testing.expect(set.getCallback(1) != null);
}

// -------------------------------------------------------------------------
// Custom-equality test — locks in the contract for `[]const u8` IDs,
// which is the shape `BlurHandlerRegistry` will use in PR 3.
// -------------------------------------------------------------------------

const StringSet = SubscriberSet([]const u8, u32, .{
    .capacity = 4,
    .keysEqual = struct {
        fn eq(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.eq,
});

test "SubscriberSet: custom keysEqual handles []const u8 by content" {
    var set = StringSet.init();

    // Two distinct slice headers, same content. With the default
    // `std.meta.eql` they would collide at the slice level (different
    // pointers); the custom comparator must dedupe by content.
    const a: []const u8 = "hello";
    const b_buf = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const b: []const u8 = b_buf[0..];

    try testing.expectEqual(StringSet.Insertion.inserted, set.insert(a, 1));
    try testing.expectEqual(StringSet.Insertion.replaced, set.insert(b, 2));
    try testing.expectEqual(@as(u32, 1), set.len());

    const cb = set.getCallback("hello") orelse return error.Missing;
    try testing.expectEqual(@as(u32, 2), cb.*);
}
