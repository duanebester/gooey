//! `CancelRegistry` — fixed-capacity store of `*std.Io.Group` pointers
//! to cancel at teardown (window close / app exit).
//!
//! Apps register their own `Io.Group`s so teardown can cancel them in
//! lock-step with framework teardown — otherwise an `async` task in a
//! user-owned group could outlive the entity it serves and write into
//! freed memory. Cancellation is blocking, so it only happens at
//! teardown; mid-frame cancellation belongs to the entity-attached
//! groups in `EntityMap`.
//!
//! Backed by `SubscriberSet(*std.Io.Group, void, ...)` — a tag-less
//! set whose `void` payload reflects that the only thing we do with a
//! registered group is iterate and cancel; the key carries everything.
//!
//! Cancellation order is intentionally unspecified: the swap-remove
//! slot map reorders the tail on `unregister`. Apps needing ordered
//! cancellation must sequence the calls themselves.

const std = @import("std");

const subscriber_set_mod = @import("subscriber_set.zig");
const SubscriberSet = subscriber_set_mod.SubscriberSet;

// =============================================================================
// Capacity caps
// =============================================================================

/// Hard cap on simultaneously-registered cancel groups. Past the cap
/// `register` asserts rather than warn-and-drop: a dropped
/// registration is a leaked async task the teardown path won't cancel,
/// and the resulting use-after-free is catastrophic to debug. Fail
/// loud, fail fast.
pub const MAX_CANCEL_GROUPS: u32 = 64;

// =============================================================================
// Backing set
// =============================================================================
//
// Pointer keys with `void` payload. Default `std.meta.eql` compares
// pointer identity, which is what we want: two `*Io.Group` values are
// the same group iff they point at the same memory.

const Set = SubscriberSet(*std.Io.Group, void, .{
    .capacity = MAX_CANCEL_GROUPS,
});

// =============================================================================
// CancelRegistry
// =============================================================================

pub const CancelRegistry = struct {
    /// Slot map of registered groups. The `Callback` payload is `void`
    /// because all we need at cancellation time is the group pointer.
    groups: Set,

    const Self = @This();

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /// Empty registry. Use this in by-value init paths.
    pub fn init() Self {
        return .{ .groups = Set.init() };
    }

    /// In-place initialization for sets embedded in a large parent
    /// struct. Delegates to the generic so the dense-prefix invariant
    /// is established the same way every time.
    pub fn initInPlace(self: *Self) void {
        self.groups.initInPlace();
    }

    // -------------------------------------------------------------------------
    // Registration
    // -------------------------------------------------------------------------

    /// Register `group` for automatic cancellation at teardown.
    ///
    /// Asserts the cap is not exceeded — overflow means a leaked task
    /// at teardown (see module doc on assert vs. warn-and-drop).
    ///
    /// Idempotent: re-registering an already-present group is a no-op
    /// (`insert` returns `.replaced` on an identity match, and the
    /// `void` payload makes the replace indistinguishable from the
    /// original entry).
    pub fn register(self: *Self, group: *std.Io.Group) void {
        // Write-boundary pair-assertions: the pointer is non-null
        // (guards against zeroed `undefined` garbage), and we have
        // room (failing this silently drops a registration).
        std.debug.assert(@intFromPtr(group) != 0);
        std.debug.assert(self.groups.hasRoom() or self.groups.contains(group));

        const outcome = self.groups.insert(group, {});
        // `.dropped` is impossible given the `hasRoom` assert above:
        // the only paths are `.inserted` or `.replaced`.
        std.debug.assert(outcome != .dropped);
    }

    /// Unregister a group — typically called when the async work
    /// completes normally and the group should no longer be cancelled
    /// at teardown. Returns `true` iff the group was actually present;
    /// removing a missing group is a silent no-op.
    pub fn unregister(self: *Self, group: *std.Io.Group) bool {
        std.debug.assert(@intFromPtr(group) != 0);
        return self.groups.remove(group);
    }

    /// `true` iff `group` is currently registered.
    pub fn contains(self: *const Self, group: *std.Io.Group) bool {
        std.debug.assert(@intFromPtr(group) != 0);
        return self.groups.contains(group);
    }

    /// Number of currently-registered groups.
    pub fn count(self: *const Self) u32 {
        return self.groups.len();
    }

    // -------------------------------------------------------------------------
    // Cancellation
    // -------------------------------------------------------------------------

    /// Cancel every registered group, then empty the registry. Called
    /// at teardown, where blocking is acceptable. A second call is a
    /// harmless no-op. Cancellation order is unspecified.
    ///
    /// Pure leaf — the caller keeps teardown ordering; we own the loop.
    pub fn cancelAll(self: *Self, io: std.Io) void {
        // Walk the dense prefix once, cancel each group, then bulk
        // clear. We don't `removeAt` per group because the swap-remove
        // would reorder the tail and risk double-cancelling under any
        // future re-entry; a single clear after the walk is cheaper
        // and re-entry-proof.
        const slots = self.groups.sliceConst();
        std.debug.assert(slots.len == self.groups.len());

        for (slots) |slot| {
            // The dense-prefix invariant guarantees every slot in
            // `[0..count)` is non-null.
            const entry = slot orelse unreachable;
            entry.key.cancel(io);
        }

        self.groups.clear();
    }
};

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: the contract is "registered groups get cancelled
// exactly once at `cancelAll`; un-registered groups don't." We
// exercise registration / unregistration / clearing with stand-in
// pointers rather than real `Io.Group`s, which need a concrete `Io`
// that's overkill for a slot-map test.

const testing = std.testing;

// Stack-allocated `Io.Group` values used as identity-distinct
// pointers. We never call `cancel` on them — we test the registry's
// bookkeeping, not downstream cancellation.
var test_group_a: std.Io.Group = .init;
var test_group_b: std.Io.Group = .init;
var test_group_c: std.Io.Group = .init;

test "CancelRegistry: init produces an empty registry" {
    const r = CancelRegistry.init();
    try testing.expectEqual(@as(u32, 0), r.count());
}

test "CancelRegistry: initInPlace matches init" {
    var r: CancelRegistry = undefined;
    r.initInPlace();
    try testing.expectEqual(@as(u32, 0), r.count());
}

test "CancelRegistry: register adds groups by pointer identity" {
    var r = CancelRegistry.init();

    r.register(&test_group_a);
    r.register(&test_group_b);

    try testing.expectEqual(@as(u32, 2), r.count());
    try testing.expect(r.contains(&test_group_a));
    try testing.expect(r.contains(&test_group_b));
    try testing.expect(!r.contains(&test_group_c));
}

test "CancelRegistry: register is idempotent for the same pointer" {
    var r = CancelRegistry.init();

    r.register(&test_group_a);
    r.register(&test_group_a);
    r.register(&test_group_a);

    try testing.expectEqual(@as(u32, 1), r.count());
    try testing.expect(r.contains(&test_group_a));
}

test "CancelRegistry: unregister removes a known group, no-op for unknown" {
    var r = CancelRegistry.init();

    r.register(&test_group_a);
    r.register(&test_group_b);

    try testing.expect(r.unregister(&test_group_a));
    try testing.expectEqual(@as(u32, 1), r.count());
    try testing.expect(!r.contains(&test_group_a));
    try testing.expect(r.contains(&test_group_b));

    // Removing again is a silent no-op.
    try testing.expect(!r.unregister(&test_group_a));
    try testing.expect(!r.unregister(&test_group_c));
    try testing.expectEqual(@as(u32, 1), r.count());
}

test "CancelRegistry: unregister preserves dense-prefix via swap-remove" {
    var r = CancelRegistry.init();

    r.register(&test_group_a);
    r.register(&test_group_b);
    r.register(&test_group_c);
    try testing.expectEqual(@as(u32, 3), r.count());

    // Drop the middle entry — the underlying `SubscriberSet` swaps
    // the tail into the freed slot, but `contains` for the remaining
    // two groups must still return `true`.
    try testing.expect(r.unregister(&test_group_b));
    try testing.expectEqual(@as(u32, 2), r.count());
    try testing.expect(r.contains(&test_group_a));
    try testing.expect(!r.contains(&test_group_b));
    try testing.expect(r.contains(&test_group_c));
}
