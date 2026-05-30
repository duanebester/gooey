//! `CancelRegistry` — fixed-capacity store of `*std.Io.Group` pointers
//! that should be cancelled at teardown (window close / app exit).
//!
//! Rationale (cleanup item #1, plan §7e in
//! `docs/architectural-cleanup-plan.md`): the original implementation
//! sat on `Gooey` as a `[64]*std.Io.Group` array plus three methods
//! (`registerCancelGroup`, `unregisterCancelGroup`, `cancelAllGroups`).
//! Like the blur registry, it is a self-contained subsystem that the
//! god struct does not need to be aware of.
//!
//! ## Why a registry at all?
//!
//! Apps register their own `Io.Group`s here so that `Gooey.deinit`
//! (window close, app exit) can cancel them in lock-step with the
//! framework's own teardown — without this, an `async` task spawned
//! into a user-owned group could outlive the entity it was working on
//! and write into freed memory. Cancellation is blocking, so it only
//! happens at teardown boundaries; mid-frame cancellation belongs to
//! the entity-attached groups in `EntityMap`, not here.
//!
//! ## Storage
//!
//! Backed by `SubscriberSet(*std.Io.Group, void, .{ ... })` per PR 3
//! task list — a "tag-less" set where the `Callback` payload is
//! `void` because the only thing we ever do with a registered group
//! is iterate and cancel. The "key" carries all the information.
//! Together with `BlurHandlerRegistry` this gives the generic two
//! distinct call shapes (slice key + payload, pointer key + no
//! payload) before PR 8 leans on it for `element_states`.
//!
//! Hard cap: `MAX_CANCEL_GROUPS = 64`. Same as the pre-extraction
//! array. Past the cap, `register` asserts — the old code asserted
//! too. The cap is a programming-error sentinel, not a runtime
//! degradation: 64 distinct top-level cancel groups is already
//! pathological, and silently dropping one would mean a use-after-
//! free at teardown.
//!
//! ## Order of cancellation
//!
//! Cancellation order is intentionally unspecified. The
//! `SubscriberSet`-backed store is a swap-remove slot map, so even
//! `unregister` reorders the tail. Apps that need ordered cancellation
//! must compose two registries or sequence cancellations themselves.

const std = @import("std");

const subscriber_set_mod = @import("subscriber_set.zig");
const SubscriberSet = subscriber_set_mod.SubscriberSet;

// =============================================================================
// Capacity caps
// =============================================================================

/// Hard cap on simultaneously-registered cancel groups.
///
/// 64 matches the pre-extraction `MAX_CANCEL_GROUPS`. A real app would
/// have to register more than 64 distinct top-level `Io.Group`s to hit
/// this — in practice, most apps register one or two (per long-running
/// component). Past the cap we assert rather than warn-and-drop: a
/// dropped registration here means a leaked async task that the
/// teardown path will not cancel, and the resulting use-after-free is
/// catastrophic to debug. Fail loud, fail fast.
pub const MAX_CANCEL_GROUPS: u32 = 64;

// =============================================================================
// Backing set
// =============================================================================
//
// Pointer keys with `void` payload — the registry is a set of group
// pointers. Default `std.meta.eql` compares pointer identity, which
// is exactly what we want: two `*Io.Group` values are "the same
// group" iff they point at the same memory.

const Set = SubscriberSet(*std.Io.Group, void, .{
    .capacity = MAX_CANCEL_GROUPS,
});

// =============================================================================
// CancelRegistry
// =============================================================================

pub const CancelRegistry = struct {
    /// Slot map of registered groups. The `Callback` payload is
    /// `void` because all the information we need at cancellation
    /// time is the group pointer itself.
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
    /// struct (per `CLAUDE.md` §13). Delegates to the generic so the
    /// dense-prefix invariant is established the same way every time.
    pub fn initInPlace(self: *Self) void {
        self.groups.initInPlace();
    }

    // -------------------------------------------------------------------------
    // Registration
    // -------------------------------------------------------------------------

    /// Register `group` for automatic cancellation at teardown.
    ///
    /// Asserts the cap is not exceeded — overflow here means a leaked
    /// task at teardown, which is a programming error, not a runtime
    /// condition (see module doc for the rationale on assert vs.
    /// warn-and-drop).
    ///
    /// Idempotent: registering a group that is already in the set is
    /// a no-op (the underlying `insert` returns `.replaced` on an
    /// identity match, and the `void` payload makes the replace
    /// indistinguishable from the original entry).
    pub fn register(self: *Self, group: *std.Io.Group) void {
        // Pair-assertions on the write boundary (per `CLAUDE.md` §3):
        //   1. The pointer is non-null. `*std.Io.Group` is a non-
        //      optional pointer, but we still guard against zeroed
        //      garbage that callers might construct via `undefined`.
        //   2. We have room. Failing this means we silently drop a
        //      registration — see module doc.
        std.debug.assert(@intFromPtr(group) != 0);
        std.debug.assert(self.groups.hasRoom() or self.groups.contains(group));

        const outcome = self.groups.insert(group, {});
        // `.dropped` is impossible: the `hasRoom` assert above
        // guarantees the only paths are `.inserted` (new) or
        // `.replaced` (already-registered, idempotent).
        std.debug.assert(outcome != .dropped);
    }

    /// Unregister a group — typically called when the async work
    /// completes normally and the group should no longer be cancelled
    /// at teardown.
    ///
    /// Returns `true` iff the group was actually present. The pre-
    /// extraction code returned `void` and silently no-op'd on
    /// missing groups; we keep that semantic by leaving the return
    /// optional for callers that do not care, while exposing the
    /// information for tests and assertions.
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

    /// Cancel every registered group. Called from `Gooey.deinit`.
    ///
    /// Blocking is acceptable here — we are tearing down. After this
    /// call, the registry is empty: a second call would have nothing
    /// to do, but is harmless. Cancellation order is unspecified
    /// (swap-remove slot map); apps that need ordered cancellation
    /// must sequence the calls themselves.
    ///
    /// Pure leaf — `Gooey.deinit` keeps the control flow (which
    /// teardown step happens first) and we own the loop. Per
    /// `CLAUDE.md` §5: control flow up, loops down.
    pub fn cancelAll(self: *Self, io: std.Io) void {
        // Walk the dense prefix once, cancel each group, then drop
        // the whole set. We don't `removeAt` per group because the
        // swap-remove would reorder the tail and we'd cancel some
        // groups twice if a future change introduced re-entry. A
        // single bulk clear after the walk is both cheaper and
        // re-entry-proof.
        const slots = self.groups.sliceConst();
        std.debug.assert(slots.len == self.groups.len());

        for (slots) |slot| {
            // The dense-prefix invariant guarantees every slot in
            // `[0..count)` is non-null; the `unreachable` matches the
            // same defensive style used elsewhere in the codebase
            // (see `SubscriberSet.find`).
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
// Methodology: the registry's contract is "registered groups get
// cancelled exactly once at `cancelAll`, in some order; un-registered
// groups don't." We exercise registration / unregistration / clearing
// without spawning real `Io.Group`s — those need a concrete `Io`
// implementation that's overkill for a slot-map test. Two stand-in
// pointers are enough to verify identity-equality and capacity
// behaviour.

const testing = std.testing;

// Two stack-allocated `Io.Group` values used as identity-distinct
// pointers. We never call `cancel` on them in these tests — the
// behaviour we're testing is the registry's bookkeeping, not the
// downstream cancellation.
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

    // Removing again is a silent no-op — matches the pre-extraction
    // shape where `unregisterCancelGroup` walked the array and
    // returned without flagging a missing entry.
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
