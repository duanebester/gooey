//! `A11ySystem` — accessibility tree, platform bridge, and screen-reader
//! poll counter.
//!
//! - `tree`: per-frame `a11y.Tree` widgets push elements into; rebuilt
//!   every frame from tables reserved at init from `ResourceLimits.a11y`.
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
//! The system takes no back-pointer: `bindPlatform` receives the platform
//! window/view it needs, so data dependencies are visible at the call site.
//! `core/screen_reader.zig` builds the tree from each published frame and
//! syncs it to the bridge.
//!
//! Invariants:
//! - `bridge.ptr` always points into `platform_bridge` — written in
//!   lockstep with the union by `initInPlace`, `bindPlatform` and
//!   `bindHeadless`, which run only during initialization and teardown.
//! - `check_counter < SCREEN_READER_CHECK_INTERVAL` after every
//!   `beginFrame`.
//! - `enabled == true` only via the periodic poll finding a screen
//!   reader or an explicit `forceEnable`.

const std = @import("std");
const builtin = @import("builtin");

const a11y = @import("../accessibility/accessibility.zig");

// =============================================================================
// A11ySystem
// =============================================================================

pub const A11ySystem = struct {
    /// Per-frame accessibility tree. Built from each published frame and
    /// drained to the platform bridge by `screen_reader.publish`.
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

    /// Reserve the tree from `capacity` and start on the no-op bridge, for a
    /// window with no platform window yet (`Window.initHeadlessPtr`). The
    /// tree is built as usual; nothing is published to an OS accessibility
    /// runtime until `bindPlatform`.
    ///
    /// `noinline` keeps the tree's setup out of the caller's WASM frame.
    pub noinline fn initInPlace(self: *Self, capacity: *const a11y.TreeCapacity) !void {
        try self.tree.initInPlace(capacity);
        self.enabled = false;
        self.check_counter = 0;
        self.platform_bridge = .{ .null_bridge = {} };
        self.bridge = a11y.NullBridge.bridge();
        std.debug.assert(self.bridgeAddressValid());
        std.debug.assert(!self.bridge.isActive());
    }

    /// Replace the bridge with the platform's, sized to the tree. The tree's
    /// storage is kept: binding happens during initialization, and a rebind
    /// must not allocate (§2).
    ///
    /// `window` and `view` are the platform-native handles the bridge needs
    /// (NSWindow and NSView on macOS, the `uia.Host` on Windows, null
    /// elsewhere).
    pub fn bindPlatform(self: *Self, window: anytype, view: anytype) void {
        std.debug.assert(self.bridgeAddressValid());
        self.bridge.deinit();
        self.enabled = false;
        self.check_counter = 0;
        // The union is at its final address because `self` is.
        self.platform_bridge = .{ .null_bridge = {} };
        self.bridge = a11y.createPlatformBridge(
            &self.platform_bridge,
            @intCast(self.tree.elements.len),
            window,
            view,
        );
        std.debug.assert(self.bridgeAddressValid());
    }

    /// Return to the no-op bridge before the native window goes away.
    pub fn bindHeadless(self: *Self) void {
        std.debug.assert(self.bridgeAddressValid());
        self.bridge.deinit();
        self.enabled = false;
        self.check_counter = 0;
        self.platform_bridge = .{ .null_bridge = {} };
        self.bridge = a11y.NullBridge.bridge();
        std.debug.assert(!self.bridge.isActive());
    }

    /// Whether `bridge.ptr` points into this system's own `platform_bridge`.
    ///
    /// False after a by-value copy or move of an initialized system: the copy's
    /// dispatcher still points at the original storage, which is a dead stack
    /// frame if the original was a local (CLAUDE.md §13). That is exactly how a
    /// `Window` returned by value crashed its second multi-window instance. The
    /// null bridge has no storage, so it always passes.
    pub fn bridgeAddressValid(self: *const Self) bool {
        if (self.platform_bridge == .null_bridge) return true;
        const storage_start = @intFromPtr(&self.platform_bridge);
        const storage_end = storage_start + @sizeOf(a11y.PlatformBridge);
        const bridge_address = @intFromPtr(self.bridge.ptr);
        if (bridge_address < storage_start) return false;
        return bridge_address < storage_end;
    }

    /// Tear down the bridge, then release the tree. Must be called from the
    /// parent struct's `deinit` before any teardown that might invalidate the
    /// underlying window / view handles.
    pub fn deinit(self: *Self) void {
        std.debug.assert(self.bridgeAddressValid());
        self.bridge.deinit();
        self.tree.deinit();
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
        // The system must not have moved since `initInPlace`; every bridge call
        // below would otherwise go through a dangling dispatcher.
        std.debug.assert(self.bridgeAddressValid());

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

    /// Mutable access to the underlying tree. Valid only between the
    /// tree's `beginFrame` and `endFrame`. Callers should not retain the
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
    try sys.initInPlace(&a11y.TreeCapacity.standard);
    defer sys.deinit();
    sys.bindPlatform(null, null);

    try testing.expectEqual(false, sys.isEnabled());
    try testing.expectEqual(@as(u32, 0), sys.check_counter);
    // The bridge dispatcher must point at the embedded platform
    // bridge storage.
    try testing.expect(@intFromPtr(sys.bridge.ptr) != 0);
    try testing.expect(sys.bridgeAddressValid());
}

test "A11ySystem: a by-value copy is detected as a dangling bridge" {
    // Goal: the per-frame assertion catches the multi-window crash, where a
    // `Window` built on the stack was copied to the heap after `initInPlace`.
    // Methodology: init one system in place, copy it into a second heap slot the
    // way `window.* = try Window.init...()` did, and check that only the
    // original passes. Only the original is torn down: the copy shares its
    // bridge resources.
    const original = try testing.allocator.create(A11ySystem);
    defer testing.allocator.destroy(original);
    try original.initInPlace(&a11y.TreeCapacity.standard);
    original.bindPlatform(null, null);
    defer original.deinit();

    const copy = try testing.allocator.create(A11ySystem);
    defer testing.allocator.destroy(copy);
    copy.* = original.*;

    try testing.expect(original.bridgeAddressValid());
    if (original.platform_bridge == .null_bridge) {
        try testing.expect(copy.bridgeAddressValid()); // no storage to dangle into
    } else {
        try testing.expect(!copy.bridgeAddressValid());
    }
}

test "A11ySystem: forceEnable / forceDisable flip the cached flag" {
    var sys: A11ySystem = undefined;
    try sys.initInPlace(&a11y.TreeCapacity.standard);
    defer sys.deinit();

    sys.forceEnable();
    try testing.expectEqual(true, sys.isEnabled());

    sys.forceDisable();
    try testing.expectEqual(false, sys.isEnabled());
}

test "A11ySystem: announce is a no-op when disabled" {
    var sys: A11ySystem = undefined;
    try sys.initInPlace(&a11y.TreeCapacity.standard);
    defer sys.deinit();

    // Disabled by default — announce should not push to the tree.
    try testing.expectEqual(false, sys.isEnabled());
    sys.announce("ignored", .polite);
    try testing.expectEqual(@as(u16, 0), sys.tree.announcement_count);
}

test "A11ySystem: announce reaches the tree when enabled" {
    var sys: A11ySystem = undefined;
    try sys.initInPlace(&a11y.TreeCapacity.standard);
    defer sys.deinit();

    sys.forceEnable();
    // The tree only accepts announcements during a frame — open one.
    sys.tree.beginFrame();
    sys.announce("hello", .polite);
    sys.tree.endFrame();

    try testing.expectEqual(@as(u16, 1), sys.tree.announcement_count);
}

test "A11ySystem: beginFrame increments the counter and resets at the interval" {
    var sys: A11ySystem = undefined;
    try sys.initInPlace(&a11y.TreeCapacity.standard);
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
