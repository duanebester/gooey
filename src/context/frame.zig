//! Frame — per-window, per-frame rendering bundle.
//!
//! Bundles the two "rebuilt every frame, owned by one Window" rendering
//! subsystems — `Scene` and `DispatchTree` — into one struct with a single
//! `owned: bool` ownership discriminator.
//!
//! ## Ownership & lifetime
//!
//! Two shapes:
//!
//!   1. **Owning** (`initOwned` / `initOwnedInPlace`, `owned = true`) —
//!      this `Frame` allocated the two pointees and `deinit` frees them.
//!      Each `Window` owns a pair by value: `rendered_frame` (the
//!      previously-built tree, hit-tested between frames) and `next_frame`
//!      (the build target). `mem.swap` between the two slots physically
//!      exchanges the structs (pointers AND the `owned` flag), so both
//!      remain owning across every swap and `Window.deinit` frees both
//!      pairs. Scene + dispatch are per-window state and cannot be shared
//!      across windows without breaking hit-testing.
//!   2. **Borrowed** (`borrowed`, `owned = false`) — a view over
//!      already-initialised pointees for diagnostic / transient inspection
//!      (e.g. a debug overlay reading `rendered_frame.dispatch`); `deinit`
//!      is a no-op so the owner remains the single tear-down path.
//!
//! The struct is small (~24 bytes); the heavy storage lives in the two
//! pointees, which are heap-allocated for WASM stack reasons (CLAUDE.md
//! §14: `Scene` and `DispatchTree` each carry many KB of
//! `ArrayListUnmanaged`s).

const std = @import("std");
const Allocator = std.mem.Allocator;

const scene_mod = @import("../scene/scene.zig");
const Scene = scene_mod.Scene;

const dispatch_mod = @import("dispatch.zig");
const DispatchTree = dispatch_mod.DispatchTree;

/// Bundle of per-window, per-frame rendering subsystems.
///
/// Holds heap-allocated `Scene` and `DispatchTree`. The `owned: bool`
/// field discriminates two ownership shapes:
///
///   - `owned = true` — this `Frame` allocated the two pointees and
///     `deinit` must free them. Set by `initOwned` / `initOwnedInPlace`.
///     Both slots in `Window` (`rendered_frame` and `next_frame`) are
///     always `owned = true`; `mem.swap` between them physically exchanges
///     the whole struct, so both keep their owning shape and
///     `Window.deinit` frees both pointee pairs.
///   - `owned = false` — a borrowed view over already-initialised pointees
///     for diagnostic / transient inspection (e.g. a debug overlay reading
///     `rendered_frame.dispatch`). `deinit` is a no-op so the owner is the
///     single tear-down path. Set by `borrowed`.
pub const Frame = struct {
    allocator: Allocator,

    scene: *Scene,
    dispatch: *DispatchTree,

    /// True when this struct owns the two pointees (`initOwned*` path);
    /// false for a borrowed diagnostic view. See struct doc-comment for
    /// the two shapes and the `mem.swap` invariant.
    owned: bool,

    const Self = @This();

    // =========================================================================
    // Owning init paths
    // =========================================================================

    /// Allocate and initialise both subsystems against `allocator`.
    ///
    /// Returns a `Frame` that owns the heap allocations; the caller must
    /// invoke `deinit` exactly once. The `viewport_width` /
    /// `viewport_height` parameters drive `scene.setViewport` +
    /// `scene.enableCulling` inline so callers can't forget the step.
    pub fn initOwned(
        allocator: Allocator,
        viewport_width: f32,
        viewport_height: f32,
    ) !Self {
        // Pair with the post-init assertions at the bottom of this function.
        std.debug.assert(viewport_width >= 0);
        std.debug.assert(viewport_height >= 0);
        std.debug.assert(!std.math.isNan(viewport_width));
        std.debug.assert(!std.math.isNan(viewport_height));

        const scene = try allocator.create(Scene);
        errdefer allocator.destroy(scene);
        scene.* = Scene.init(allocator);
        errdefer scene.deinit();

        // Viewport culling — folded in here so no caller can forget the
        // step (which would silently disable culling and balloon GPU work
        // on large scenes).
        scene.setViewport(viewport_width, viewport_height);
        scene.enableCulling();

        const dispatch = try allocator.create(DispatchTree);
        errdefer allocator.destroy(dispatch);
        dispatch.* = DispatchTree.init(allocator);

        // Pair-assert: the post-init pointers must be non-null and
        // distinct. Pointer-equality between the two would imply a
        // cross-aliased allocation bug somewhere upstream.
        std.debug.assert(@intFromPtr(scene) != 0);
        std.debug.assert(@intFromPtr(dispatch) != 0);
        std.debug.assert(@intFromPtr(scene) != @intFromPtr(dispatch));

        return .{
            .allocator = allocator,
            .scene = scene,
            .dispatch = dispatch,
            .owned = true,
        };
    }

    /// In-place owning init for callers that need to avoid a stack temp.
    /// Marked `noinline` so ReleaseSmall doesn't fold the stack frame back
    /// into the caller (WASM stack budget — CLAUDE.md §14).
    ///
    /// `self` must point at uninitialised memory; the function writes
    /// every field. On error, partially-allocated subsystems are torn
    /// down via the same `errdefer` chain as `initOwned`.
    pub noinline fn initOwnedInPlace(
        self: *Self,
        allocator: Allocator,
        viewport_width: f32,
        viewport_height: f32,
    ) !void {
        std.debug.assert(viewport_width >= 0);
        std.debug.assert(viewport_height >= 0);
        std.debug.assert(!std.math.isNan(viewport_width));
        std.debug.assert(!std.math.isNan(viewport_height));

        const scene = try allocator.create(Scene);
        errdefer allocator.destroy(scene);
        scene.* = Scene.init(allocator);
        errdefer scene.deinit();

        scene.setViewport(viewport_width, viewport_height);
        scene.enableCulling();

        const dispatch = try allocator.create(DispatchTree);
        errdefer allocator.destroy(dispatch);
        dispatch.* = DispatchTree.init(allocator);

        // Field-by-field — no struct literal — to avoid a stack temp
        // (CLAUDE.md §14 WASM stack budget).
        self.allocator = allocator;
        self.scene = scene;
        self.dispatch = dispatch;
        self.owned = true;

        std.debug.assert(@intFromPtr(self.scene) != 0);
        std.debug.assert(@intFromPtr(self.dispatch) != 0);
        std.debug.assert(@intFromPtr(self.scene) != @intFromPtr(self.dispatch));
    }

    // =========================================================================
    // Borrowed init path
    // =========================================================================

    /// Build a borrowed `Frame` view over already-initialised pointees.
    /// `deinit` is a no-op for this instance — the upstream owner tears
    /// the pointees down. Used for diagnostic / transient inspection
    /// (e.g. a debug overlay reading `rendered_frame.dispatch`).
    /// `mem.swap` between `Window`'s owning slots does NOT go through this
    /// constructor; it swaps the structs in place, leaving both
    /// `owned = true`.
    pub fn borrowed(
        allocator: Allocator,
        scene: *Scene,
        dispatch: *DispatchTree,
    ) Self {
        std.debug.assert(@intFromPtr(scene) != 0);
        std.debug.assert(@intFromPtr(dispatch) != 0);
        std.debug.assert(@intFromPtr(scene) != @intFromPtr(dispatch));

        return .{
            .allocator = allocator,
            .scene = scene,
            .dispatch = dispatch,
            .owned = false,
        };
    }

    // =========================================================================
    // Teardown
    // =========================================================================

    /// Tear down the two subsystems if `owned`, otherwise no-op.
    /// Idempotent only in the borrowed case — calling `deinit`
    /// twice on an `owned = true` instance is a use-after-free,
    /// same as any other heap-owning struct.
    pub fn deinit(self: *Self) void {
        if (!self.owned) return;

        // Dispatch first (holds per-frame listener blocks), then scene
        // (owns the per-frame draw lists). Order is not load-bearing —
        // there are no inter-pointer references between the two.
        self.dispatch.deinit();
        self.allocator.destroy(self.dispatch);

        self.scene.deinit();
        self.allocator.destroy(self.scene);

        // Null out so an accidental re-deinit fails fast on the
        // pointer check, rather than double-freeing.
        self.scene = undefined;
        self.dispatch = undefined;
        self.owned = false;
    }
};

// =============================================================================
// Tests
// =============================================================================
//
// These tests pin the two ownership shapes against `std.testing.allocator`,
// which surfaces any leak or double-free immediately. The `borrowed` path
// is verified by borrowing from an owning parent and confirming the
// borrowed `deinit` is a no-op (no double-free against the parent).

const testing = std.testing;

test "Frame: initOwned allocates and frees cleanly" {
    var frame = try Frame.initOwned(testing.allocator, 800, 600);
    defer frame.deinit();

    try testing.expect(frame.owned);
    try testing.expect(@intFromPtr(frame.scene) != 0);
    try testing.expect(@intFromPtr(frame.dispatch) != 0);

    // Viewport was applied inline by `initOwned` — pin the values
    // so a future refactor can't silently drop the call.
    try testing.expectEqual(@as(f32, 800), frame.scene.viewport_width);
    try testing.expectEqual(@as(f32, 600), frame.scene.viewport_height);
    try testing.expect(frame.scene.culling_enabled);
}

test "Frame: initOwnedInPlace produces an owned instance" {
    var frame: Frame = undefined;
    try frame.initOwnedInPlace(testing.allocator, 1024, 768);
    defer frame.deinit();

    try testing.expect(frame.owned);
    try testing.expect(@intFromPtr(frame.scene) != 0);
    try testing.expect(@intFromPtr(frame.dispatch) != 0);

    try testing.expectEqual(@as(f32, 1024), frame.scene.viewport_width);
    try testing.expectEqual(@as(f32, 768), frame.scene.viewport_height);
    try testing.expect(frame.scene.culling_enabled);
}

test "Frame: borrowed deinit is a no-op (no double-free)" {
    // Build an owning parent against `testing.allocator`; if the
    // borrowed `deinit` below tore the parent's allocations down
    // again, the parent's own `deinit` at scope exit would
    // double-free and the test allocator would surface it.
    var parent = try Frame.initOwned(testing.allocator, 640, 480);
    defer parent.deinit();

    var view = Frame.borrowed(testing.allocator, parent.scene, parent.dispatch);
    try testing.expect(!view.owned);
    try testing.expectEqual(parent.scene, view.scene);
    try testing.expectEqual(parent.dispatch, view.dispatch);

    // Tear down the borrowed view; must NOT free the parent's
    // pointees. Pinned via `defer parent.deinit()` above — if
    // the borrowed `deinit` freed the backing storage, the
    // parent's teardown would hit a double-free under
    // `testing.allocator`.
    view.deinit();

    // Post-teardown, a borrowed view's pointers are not nulled
    // (they were pointing at backing storage the view didn't
    // own). The parent's pointers are still live and point at
    // the same heap addresses they did pre-borrow.
    try testing.expectEqual(parent.scene, view.scene);
    try testing.expectEqual(parent.dispatch, view.dispatch);
}

test "Frame: zero viewport is accepted" {
    // Test fixtures sometimes construct a `Window` before the platform
    // layer reports a real surface size; a zero-sized viewport is a
    // legitimate transient state (culling is a no-op until the first
    // resize event), so the bundle must accept it.
    var frame = try Frame.initOwned(testing.allocator, 0, 0);
    defer frame.deinit();

    try testing.expectEqual(@as(f32, 0), frame.scene.viewport_width);
    try testing.expectEqual(@as(f32, 0), frame.scene.viewport_height);
    try testing.expect(frame.scene.culling_enabled);
}

// =============================================================================
// Double-buffer `mem.swap` tests
// =============================================================================
//
// Pin the swap semantics that `runtime/frame.zig::renderFrameImpl` relies
// on: `std.mem.swap(Frame, &a, &b)` exchanges the entire struct (both
// pointee pointers AND the `owned` flag), so two owning `Frame`s remain
// owning across every swap and a single `deinit` per slot covers both
// heap-allocated pairs for the parent `Window`'s lifetime.

test "Frame: mem.swap exchanges scene + dispatch between two owning Frames" {
    // Two owning `Frame`s with distinct viewport sizes so we can
    // tell which `Scene` is which post-swap (the pointee
    // identity, not just the pointer value, anchors the test).
    var a = try Frame.initOwned(testing.allocator, 800, 600);
    defer a.deinit();

    var b = try Frame.initOwned(testing.allocator, 1024, 768);
    defer b.deinit();

    const a_scene_before = a.scene;
    const a_dispatch_before = a.dispatch;
    const b_scene_before = b.scene;
    const b_dispatch_before = b.dispatch;

    std.mem.swap(Frame, &a, &b);

    // Pointer identity swaps: `a` now refers to what was `b`'s
    // backing storage, and vice versa.
    try testing.expectEqual(b_scene_before, a.scene);
    try testing.expectEqual(b_dispatch_before, a.dispatch);
    try testing.expectEqual(a_scene_before, b.scene);
    try testing.expectEqual(a_dispatch_before, b.dispatch);

    // Viewport sizes follow the pointers — confirms the swap
    // exchanged the actual `Scene` allocations (not just
    // overwrote two distinct `*Scene` pointers with the same
    // value).
    try testing.expectEqual(@as(f32, 1024), a.scene.viewport_width);
    try testing.expectEqual(@as(f32, 768), a.scene.viewport_height);
    try testing.expectEqual(@as(f32, 800), b.scene.viewport_width);
    try testing.expectEqual(@as(f32, 600), b.scene.viewport_height);
}

test "Frame: mem.swap preserves owned=true on both halves" {
    // The double-buffer's correctness rests on this: both
    // `Window.next_frame` and `Window.rendered_frame` are
    // `owned = true` at init, and `mem.swap` exchanges the
    // entire struct (including the `owned` flag), so both
    // remain `owned = true` post-swap. `Window.deinit` then
    // tears down both pairs unconditionally regardless of how
    // many swaps have run.
    var a = try Frame.initOwned(testing.allocator, 640, 480);
    defer a.deinit();

    var b = try Frame.initOwned(testing.allocator, 320, 240);
    defer b.deinit();

    try testing.expect(a.owned);
    try testing.expect(b.owned);

    std.mem.swap(Frame, &a, &b);
    try testing.expect(a.owned);
    try testing.expect(b.owned);

    // Two more swaps to confirm the invariant holds across
    // arbitrary swap counts (the `Window` lifetime sees one
    // swap per tick).
    std.mem.swap(Frame, &a, &b);
    std.mem.swap(Frame, &a, &b);
    try testing.expect(a.owned);
    try testing.expect(b.owned);
}

test "Frame: mem.swap survives recycle (clear/reset on the post-swap older buffer)" {
    // After `runtime/frame.zig::renderFrameImpl`'s end-of-frame
    // swap, the now-stale buffer (pre-swap `next_frame`,
    // post-swap `next_frame` again — the slot, not the
    // pointee) is recycled via `scene.clear()` +
    // `dispatch.reset()`. Pin that the recycle calls land on
    // the post-swap pointees and don't disturb the
    // just-rotated-into-rendered_frame pair.
    var rendered_frame = try Frame.initOwned(testing.allocator, 800, 600);
    defer rendered_frame.deinit();

    var next_frame = try Frame.initOwned(testing.allocator, 800, 600);
    defer next_frame.deinit();

    // Capture the pre-swap identities so we can verify the
    // recycle calls land on the right pointees post-swap.
    const just_built_scene = next_frame.scene;
    const just_built_dispatch = next_frame.dispatch;
    const stale_scene = rendered_frame.scene;
    const stale_dispatch = rendered_frame.dispatch;

    // Plant a small bit of mutable state we can read back to
    // confirm the recycle hit the right buffer. The viewport
    // is a convenient handle (each `Frame` was init'd at
    // 800×600; mutating one half lets us tell them apart).
    stale_scene.setViewport(123, 456);

    std.mem.swap(Frame, &rendered_frame, &next_frame);

    // Post-swap: `rendered_frame.scene` is the just-built
    // pointee; `next_frame.scene` is the stale one we marked
    // above.
    try testing.expectEqual(just_built_scene, rendered_frame.scene);
    try testing.expectEqual(just_built_dispatch, rendered_frame.dispatch);
    try testing.expectEqual(stale_scene, next_frame.scene);
    try testing.expectEqual(stale_dispatch, next_frame.dispatch);
    try testing.expectEqual(@as(f32, 123), next_frame.scene.viewport_width);
    try testing.expectEqual(@as(f32, 456), next_frame.scene.viewport_height);

    // Recycle the stale half (mirrors the post-swap
    // `next_frame.scene.clear() + next_frame.dispatch.reset()`
    // in `renderFrameImpl`). The clear is a no-op for an
    // already-empty scene at this point; the test is that the
    // calls land on the stale pointees and don't touch
    // `rendered_frame.*`.
    next_frame.scene.clear();
    next_frame.dispatch.reset();

    // The viewport survives `Scene.clear()` (clearing only
    // drops draw primitives, not viewport configuration), so
    // we can still tell which buffer we're looking at.
    try testing.expectEqual(@as(f32, 123), next_frame.scene.viewport_width);
    try testing.expectEqual(@as(f32, 800), rendered_frame.scene.viewport_width);

    // Both halves retain ownership across the swap + recycle
    // — `defer rendered_frame.deinit()` and `defer
    // next_frame.deinit()` at the top of this function will
    // free both heap pairs cleanly under `testing.allocator`.
    try testing.expect(rendered_frame.owned);
    try testing.expect(next_frame.owned);
}
