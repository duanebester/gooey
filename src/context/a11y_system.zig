//! `A11ySystem` — accessibility tree, platform bridge, and screen-reader
//! poll counter.
//!
//! - `tree`: per-frame `a11y.Tree` widgets push elements into; rebuilt
//!   every frame, ~zero alloc after init. ~350KB — the dominant size
//!   here and the reason `initInPlace` is `noinline`.
//! - `platform_bridge`: tagged-union storage for the active platform's
//!   bridge, so the framework hands out a uniform `Bridge` regardless
//!   of platform.
//! - `bridge`: `Bridge` vtable handle into `platform_bridge` that
//!   `tree` syncs to each frame end. Borrowed; lifetime tied to
//!   `platform_bridge`.
//! - `enabled`: cached "is a screen reader running?" flag, refreshed
//!   every `SCREEN_READER_CHECK_INTERVAL` frames. Hot-path code reads
//!   it to early-out when accessibility is off.
//! - `check_counter`: frame counter driving the periodic refresh.
//!
//! The system takes no back-pointer: frame hooks receive the handles
//! they need (`initInPlace` the platform window/view, `endFrame` a
//! `*const LayoutEngine`) so data dependencies are visible at the call
//! site.
//!
//! Invariants:
//! - `bridge.ptr` always points into `platform_bridge` — initialised
//!   in lockstep with the union and never replaced after init.
//! - `check_counter < SCREEN_READER_CHECK_INTERVAL` after every
//!   `beginFrame`.
//! - `enabled == true` only via the periodic poll finding a screen
//!   reader or an explicit `forceEnable`.

const std = @import("std");
const builtin = @import("builtin");

const a11y = @import("../accessibility/accessibility.zig");

const layout_mod = @import("../layout/layout.zig");
const LayoutEngine = layout_mod.LayoutEngine;

// =============================================================================
// A11ySystem
// =============================================================================

pub const A11ySystem = struct {
    /// Per-frame accessibility tree. Built up during render, drained
    /// to the platform bridge by `endFrame`. ~350KB; the struct's
    /// stack-budget burden.
    tree: a11y.Tree,

    /// Tagged-union storage for the active platform bridge — only the
    /// active variant has a meaningful payload, keeping size
    /// predictable across platforms.
    platform_bridge: a11y.PlatformBridge,

    /// Vtable handle into `platform_bridge`, used by `tree.endFrame` to
    /// push dirty elements / removals / announcements to the OS
    /// accessibility runtime.
    bridge: a11y.Bridge,

    /// Cached "screen reader is running" flag, refreshed every
    /// `SCREEN_READER_CHECK_INTERVAL` frames by `beginFrame`. Hot-path
    /// code early-outs when this is `false`, so every such path must be
    /// a no-op in that case.
    enabled: bool = false,

    /// Frame counter for the periodic poll. At 60Hz with
    /// `SCREEN_READER_CHECK_INTERVAL = 60` we poll once per second
    /// rather than calling into the OS every frame.
    check_counter: u32 = 0,

    const Self = @This();

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /// Initialize the accessibility subsystem in place at the system's
    /// final heap address.
    ///
    /// Marked `noinline` so the compiler can't fold the ~350KB `Tree`
    /// field into the caller's WASM stack frame; only the enclosing
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
        // Field-by-field — no struct literal, no stack temp.

        // Tree in-place to dodge the ~350KB struct-literal stack temp.
        // The leaf `Tree.initInPlace` is itself `noinline`.
        self.tree.initInPlace();

        // Scalars first — cheap, sets the invariant.
        self.enabled = false;
        self.check_counter = 0;

        // `createPlatformBridge` writes the union variant and returns
        // the dispatcher handle. It must run after the union storage is
        // at its final address, which holds because `self` is already
        // initialised in place by its parent.
        self.platform_bridge = undefined;
        self.bridge = a11y.createPlatformBridge(&self.platform_bridge, window, view);

        // Write-boundary assertion: the dispatcher must point into our
        // own storage. Non-zero is enough to catch a missed assignment.
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
    /// fresh build. Cheap on the common path — when accessibility is
    /// off, the only cost is the counter increment and compare.
    pub fn beginFrame(self: *Self) void {
        // The counter must be in the "not yet due" range at frame
        // start; exceeding the interval means a prior frame skipped
        // the reset.
        std.debug.assert(self.check_counter < a11y.constants.SCREEN_READER_CHECK_INTERVAL);

        self.check_counter += 1;
        if (self.check_counter >= a11y.constants.SCREEN_READER_CHECK_INTERVAL) {
            self.check_counter = 0;
            self.enabled = self.bridge.isActive();
        }

        // Begin the tree only when accessibility is on — skips the
        // call overhead on the cold path.
        if (self.enabled) {
            self.tree.beginFrame();
        }
    }

    /// Frame-end hook. Finalizes the tree, syncs bounds from the
    /// layout engine, and pushes dirty elements / announcements to the
    /// platform bridge. Zero cost when `enabled` is false — the entire
    /// body is gated behind the early-out.
    pub fn endFrame(self: *Self, layout: *const LayoutEngine) void {
        if (!self.enabled) return;

        self.tree.endFrame();

        // Bounds sync runs on the just-built element list. It must
        // happen after `endFrame` (which finalizes `element_count`)
        // and before `syncFrame` (which reads bounds when pushing to
        // the platform).
        self.tree.syncBounds(layout);

        // Push dirty elements, removals, announcements, and focus.
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
    /// is off.
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
