//! `A11ySystem` — accessibility tree, platform bridge, and screen-reader
//! poll counter, extracted from `Gooey`.
//!
//! Rationale (cleanup item #1, plan §7c in
//! `docs/architectural-cleanup-plan.md`): five fields and five methods
//! on `Gooey` form a self-contained accessibility subsystem. Beyond
//! the line-count win, the init-in-place dance for `a11y.Tree` (~350KB)
//! is non-trivial and the WASM stack tricks belong with the subsystem
//! that needs them, not in the parent struct's init path.
//!
//! ## What lives here
//!
//! - `tree`: the per-frame `a11y.Tree` that widgets push elements
//!   into. Rebuilt every frame, ~zero alloc after init. ~350KB struct
//!   on a typical platform — the dominant size on this subsystem and
//!   the reason `initInPlace` is `noinline` (per `CLAUDE.md` §14).
//! - `platform_bridge`: storage for the active platform's bridge
//!   (`MacBridge` on macOS, `WebBridge` on freestanding, etc.). Lives
//!   here as a tagged union so the framework can hand out a uniform
//!   `Bridge` interface regardless of platform.
//! - `bridge`: the `Bridge` vtable handle that `tree` syncs to at the
//!   end of every frame, points into `platform_bridge`. Borrowed
//!   reference, lifetime tied to `platform_bridge`.
//! - `enabled`: cached "is a screen reader running?" flag, refreshed
//!   periodically (every `SCREEN_READER_CHECK_INTERVAL` frames). Hot
//!   path code (`Builder.accessible`, `cx.announce`, …) reads this
//!   to early-out when accessibility is off — zero cost in the common
//!   case.
//! - `check_counter`: frame counter driving the periodic refresh.
//!
//! ## Decoupling from `Gooey`
//!
//! The system doesn't take a `*Gooey` back-pointer. `tick` (frame
//! boundary update) takes the platform-window handles it needs and
//! computes everything else internally. `endFrame` takes a
//! `*const LayoutEngine` for the bounds-sync step — same shape as
//! `HoverState.update` (§7b). Per `CLAUDE.md` §6: data dependencies
//! are visible at the call site, not hidden in a god-pointer.
//!
//! ## Invariants
//!
//! - `bridge.ptr` always points into `platform_bridge` — the bridge
//!   is initialised in lockstep with the union and never replaced
//!   after init.
//! - `check_counter < SCREEN_READER_CHECK_INTERVAL` after every
//!   `beginFrame`. The counter ticks on every frame and resets on
//!   the periodic check.
//! - `enabled == true` implies the active bridge believes a screen
//!   reader is running OR the caller force-enabled via `forceEnable`.
//!   No other path sets `enabled = true`.

const std = @import("std");
const builtin = @import("builtin");

const a11y = @import("../accessibility/accessibility.zig");

const layout_mod = @import("../layout/layout.zig");
const LayoutEngine = layout_mod.LayoutEngine;

// =============================================================================
// A11ySystem
// =============================================================================

pub const A11ySystem = struct {
    /// Per-frame accessibility tree. Built up via `pushElement` /
    /// `popElement` during render, drained to the platform bridge by
    /// `endFrame`. ~350KB; the struct's stack-budget burden.
    tree: a11y.Tree,

    /// Storage for the active platform bridge. Tagged union so we can
    /// keep size predictable across platforms — only the active
    /// variant has any meaningful payload, the rest are `void`.
    platform_bridge: a11y.PlatformBridge,

    /// Vtable handle into `platform_bridge`. The dispatcher used by
    /// `tree.endFrame` to push dirty elements / removals /
    /// announcements to the OS-level accessibility runtime.
    bridge: a11y.Bridge,

    /// Cached "screen reader is running" flag. Refreshed every
    /// `SCREEN_READER_CHECK_INTERVAL` frames by `beginFrame`. Hot path
    /// code reads this to early-out when accessibility is off; the
    /// invariant is that an early-out path must be a no-op when this
    /// flag is `false`.
    enabled: bool = false,

    /// Frame counter for the periodic poll. Cheaper than calling into
    /// the OS every frame for "is VoiceOver running?" — at 60Hz with
    /// `SCREEN_READER_CHECK_INTERVAL = 60`, we poll once per second
    /// rather than 60 times per second.
    check_counter: u32 = 0,

    const Self = @This();

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /// Initialize the accessibility subsystem in place at the
    /// system's final heap address.
    ///
    /// Marked `noinline` to keep the WASM caller's stack frame
    /// bounded (per `CLAUDE.md` §14). Inlining lets the compiler
    /// combine the ~350KB `Tree` field of every `A11ySystem` into one
    /// giant frame; with `noinline`, only the immediately-enclosing
    /// init path pays the cost.
    ///
    /// `window` and `view` are the platform-native handles the bridge
    /// needs (NSWindow + NSView on macOS, ignored on others). Pass
    /// `null` from non-macOS platforms.
    pub noinline fn initInPlace(
        self: *Self,
        window: anytype,
        view: anytype,
    ) void {
        // Field-by-field — no struct literal, no stack temp. Mirrors
        // the convention used by `ImageLoader.initInPlace` and the
        // pre-extraction code in `Gooey.initOwnedPtr`.

        // Tree: in-place to dodge the ~350KB struct-literal stack
        // temp. The leaf `Tree.initInPlace` is itself `noinline`.
        self.tree.initInPlace();

        // Scalars first — cheap, sets the invariant.
        self.enabled = false;
        self.check_counter = 0;

        // Platform bridge wiring: `createPlatformBridge` is `noinline`
        // and writes the union variant + returns the dispatcher
        // handle. It must run after the union storage is at its final
        // address; that's true here because `self` is already at its
        // final heap address (`A11ySystem` is initialised in place by
        // its parent).
        self.platform_bridge = undefined;
        self.bridge = a11y.createPlatformBridge(&self.platform_bridge, window, view);

        // Pair-assertion on the write boundary (per `CLAUDE.md` §3):
        // the bridge dispatcher must point into our own storage. A
        // ptr-equality check would be heavyweight; the
        // intFromPtr-non-zero check is enough to catch a missed
        // assignment.
        std.debug.assert(@intFromPtr(self.bridge.ptr) != 0);
    }

    /// Tear down the platform bridge. Must be called from the parent
    /// struct's `deinit` before any teardown that might invalidate
    /// the underlying window / view handles.
    pub fn deinit(self: *Self) void {
        self.bridge.deinit();
    }

    // -------------------------------------------------------------------------
    // Frame boundaries
    // -------------------------------------------------------------------------

    /// Frame-start hook. Periodically polls the bridge for
    /// screen-reader status and, if enabled, prepares the tree for a
    /// fresh build.
    ///
    /// Cheap on the common path — when accessibility is off, the only
    /// cost is the counter increment and the modulo-style compare.
    /// Per `CLAUDE.md` §11: state the invariant positively (counter
    /// reaches the threshold), then act.
    pub fn beginFrame(self: *Self) void {
        // Pair-assertion: the counter must always be in the "not yet
        // due" range at frame start. If it ever exceeds the interval,
        // a previous frame skipped the reset.
        std.debug.assert(self.check_counter < a11y.constants.SCREEN_READER_CHECK_INTERVAL);

        self.check_counter += 1;
        if (self.check_counter >= a11y.constants.SCREEN_READER_CHECK_INTERVAL) {
            self.check_counter = 0;
            self.enabled = self.bridge.isActive();
        }

        // Begin the tree only when accessibility is on — zero cost
        // when it's off. The tree itself short-circuits on the cold
        // path, but we'd still pay the call overhead.
        if (self.enabled) {
            self.tree.beginFrame();
        }
    }

    /// Frame-end hook. Finalizes the tree, syncs bounds from the
    /// layout engine, and pushes dirty elements / announcements to
    /// the platform bridge.
    ///
    /// Zero cost when `enabled` is false — the entire body is gated
    /// behind the early-out. This is the contract that hot-path
    /// callers (`Builder.accessible`, `cx.announce`) rely on.
    pub fn endFrame(self: *Self, layout: *const LayoutEngine) void {
        if (!self.enabled) return;

        self.tree.endFrame();

        // Bounds sync runs on the just-built element list — a one-
        // time pass over the tree, O(elements). It must happen after
        // `endFrame` (the tree finalizes its element_count there) and
        // before `syncFrame` (the bridge reads bounds when pushing to
        // the platform).
        self.tree.syncBounds(layout);

        // Push everything to the platform — dirty elements, removals,
        // announcements, focus.
        self.bridge.syncFrame(&self.tree);
    }

    // -------------------------------------------------------------------------
    // Inspection / overrides
    // -------------------------------------------------------------------------

    /// Cached "is accessibility active?" flag. Read by hot-path
    /// callers to early-out when no screen reader is running.
    pub fn isEnabled(self: *const Self) bool {
        return self.enabled;
    }

    /// Force-enable accessibility, regardless of bridge state.
    /// Intended for tests and debugging — production code should rely
    /// on the periodic poll.
    pub fn forceEnable(self: *Self) void {
        self.enabled = true;
    }

    /// Force-disable accessibility, regardless of bridge state.
    /// Useful in tests where a real bridge would otherwise report
    /// `true` (e.g. the `WebBridge` heuristic).
    pub fn forceDisable(self: *Self) void {
        self.enabled = false;
    }

    /// Mutable access to the underlying tree. Valid only between
    /// `beginFrame` and `endFrame`. Callers should not retain the
    /// pointer across frames.
    pub fn getTree(self: *Self) *a11y.Tree {
        return &self.tree;
    }

    /// Queue a screen-reader announcement. No-op when accessibility
    /// is off — same shape as the pre-extraction `Gooey.announce`.
    pub fn announce(self: *Self, message: []const u8, priority: a11y.Live) void {
        if (!self.enabled) return;
        self.tree.announce(message, priority);
    }
};

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: exercise the lifecycle and the `enabled`-gated
// short-circuits. We can't easily test the periodic poll without
// stepping a real frame counter past the interval, so the poll
// behaviour is asserted directly on `check_counter`.
//
// Bridge-level behaviour is owned by the accessibility tests; here
// we just verify that the system wires the bridge into the tree
// correctly and that the cold-path early-outs are real.

const testing = std.testing;

test "A11ySystem: initInPlace produces a disabled, freshly-counted system" {
    var sys: A11ySystem = undefined;
    sys.initInPlace(null, null);
    defer sys.deinit();

    try testing.expectEqual(false, sys.isEnabled());
    try testing.expectEqual(@as(u32, 0), sys.check_counter);
    // The bridge dispatcher must point at the embedded platform
    // bridge storage — non-zero is enough to catch a missed wiring.
    try testing.expect(@intFromPtr(sys.bridge.ptr) != 0);
}

test "A11ySystem: forceEnable / forceDisable flip the cached flag" {
    var sys: A11ySystem = undefined;
    sys.initInPlace(null, null);
    defer sys.deinit();

    sys.forceEnable();
    try testing.expectEqual(true, sys.isEnabled());

    sys.forceDisable();
    try testing.expectEqual(false, sys.isEnabled());
}

test "A11ySystem: announce is a no-op when disabled" {
    var sys: A11ySystem = undefined;
    sys.initInPlace(null, null);
    defer sys.deinit();

    // Disabled by default — announce should not push to the tree.
    try testing.expectEqual(false, sys.isEnabled());
    sys.announce("ignored", .polite);
    try testing.expectEqual(@as(u32, 0), sys.tree.announcement_count);
}

test "A11ySystem: announce reaches the tree when enabled" {
    var sys: A11ySystem = undefined;
    sys.initInPlace(null, null);
    defer sys.deinit();

    sys.forceEnable();
    // The tree only accepts announcements during a frame — open one.
    sys.tree.beginFrame();
    sys.announce("hello", .polite);
    sys.tree.endFrame();

    try testing.expectEqual(@as(u32, 1), sys.tree.announcement_count);
}

test "A11ySystem: beginFrame increments the counter and resets at the interval" {
    var sys: A11ySystem = undefined;
    sys.initInPlace(null, null);
    defer sys.deinit();

    // Drive the counter up to one tick before the interval. Each
    // beginFrame increments by one; we should never see the counter
    // exceed the interval thanks to the modulo-style reset.
    const interval = a11y.constants.SCREEN_READER_CHECK_INTERVAL;
    var i: u32 = 0;
    while (i < interval - 1) : (i += 1) {
        sys.beginFrame();
    }
    try testing.expectEqual(interval - 1, sys.check_counter);

    // One more frame trips the reset.
    sys.beginFrame();
    try testing.expectEqual(@as(u32, 0), sys.check_counter);
}

test "A11ySystem: endFrame is a no-op when disabled" {
    // We can't easily construct a real `LayoutEngine` here, but we
    // can prove the early-out by giving `endFrame` a junk pointer
    // that would crash if dereferenced. As long as the early-out
    // fires, the junk pointer is never touched.
    var sys: A11ySystem = undefined;
    sys.initInPlace(null, null);
    defer sys.deinit();

    try testing.expectEqual(false, sys.isEnabled());
    const junk: *const LayoutEngine = @ptrFromInt(@alignOf(LayoutEngine));
    sys.endFrame(junk);
    // If we got here, the early-out worked.
}
