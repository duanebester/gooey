//! Frame — per-window, per-frame rendering bundle.
//!
//! ## Why this exists
//!
//! Per `docs/cleanup-implementation-plan.md` PR 7c.3 (the second-to-last
//! slice of the App/Window earthquake), the two "rebuilt every frame, owned
//! by one Window" rendering subsystems — `Scene` and `DispatchTree` — are
//! gathered into one struct. Before this extraction, `Window` carried each
//! as an independent `*T` with its own `allocator.create` + `init` +
//! `errdefer` block in every one of the four parallel init paths
//! (`initOwned` / `initOwnedPtr` / `initWithSharedResources` /
//! `initWithSharedResourcesPtr`), and a hard-coded teardown order in
//! `Window.deinit`.
//!
//! After this extraction:
//!
//!   - **Single-window**: `Window` owns *two* `Frame`s by value
//!     (`rendered_frame` + `next_frame`); both are
//!     `owned = true`. `mem.swap` between them at the frame
//!     boundary doesn't change ownership — it swaps which slot
//!     refers to which heap-allocated `Scene` / `DispatchTree`
//!     pair, and both pairs remain owned by the parent `Window`
//!     across every swap.
//!   - **Multi-window**: each `Window` still owns its own pair (the
//!     scene + dispatch tree are per-window state — they cannot be
//!     shared across windows without breaking hit-testing).
//!   - **Borrowed view** (`Frame.borrowed`): an `owned = false`
//!     view over already-initialised pointees. PR 7c.3a introduced
//!     the constructor as a complete API surface; PR 7c.3c uses
//!     it for diagnostic / transient inspection of either buffer
//!     across the swap (e.g. a debug overlay reading
//!     `rendered_frame.dispatch` without taking ownership of its
//!     teardown). The owning pair on `Window` always carries
//!     `owned = true`.
//!
//! See [`architectural-cleanup-plan.md` §11 frame double-buffering with
//! `mem::swap`](../../docs/architectural-cleanup-plan.md#11-frame-double-buffering-with-memswap)
//! for the GPUI pattern this lands as a first concrete slice. The doc
//! sketches `Frame` as carrying *every* per-frame transient
//! (`focus`, `element_states`, `mouse_listeners`, `dispatch_tree`,
//! `scene`, `hitboxes`, `deferred_draws`, `input_handlers`,
//! `tooltip_requests`, `cursor_styles`, `tab_stops`); 7c.3a lands the
//! two heaviest pointee subsystems as the structural anchor, and
//! later 7c.3 slices migrate the rest piece by piece. Keeping the
//! initial bundle small means the call-site sweep (PR 7c.3b) and the
//! double-buffer landing (PR 7c.3c) each touch only a manageable
//! cross-section of the codebase.
//!
//! ## What's NOT here yet
//!
//! - `focus`, `hover`, `mouse_listeners`, `tab_stops`. These are
//!   per-frame transients per the GPUI mapping in §11, but they
//!   currently live in standalone subsystems on `Window` (`focus:
//!   FocusManager`, `hover: HoverState`, …). Migrating them belongs
//!   in a later 7c.3 slice once the call-site sweep against `scene`
//!   and `dispatch` is complete and the double-buffer is wired —
//!   trying to move five subsystems in one PR would dwarf the
//!   review surface 7c.3a / 7c.3b / 7c.3c can already absorb.
//! - `element_states`. Reserved for PR 8 — it's the keyed pool that
//!   replaces `WidgetStore`'s per-type maps, not a simple migration.
//!   PR 7c.3c lays the structural groundwork (double-buffer with
//!   `mem.swap` and a live `rendered_frame` between frames) so the
//!   PR 8 fall-through lookup `next_frame.element_states ↦
//!   rendered_frame.element_states` is a single-field addition
//!   here, not a swap-semantics flip.
//!
//! ## Lifetime
//!
//! Allocated and owned in two shapes:
//!
//!   1. **By value, embedded in `Window`** — every window owns a
//!      pair: `rendered_frame: Frame` (the previously-built tree
//!      hit-tested against between frames) and `next_frame: Frame`
//!      (the build target written by every render-pipeline call
//!      site). Both carry `owned = true`. `Window.deinit` tears
//!      both down via `Frame.deinit`.
//!   2. **Borrowed view** (`Frame.borrowed`) — an `owned = false`
//!      view over already-initialised pointees. The underlying
//!      `Scene` / `DispatchTree` pointers stay owned by their
//!      parent `Window` slot; the borrowed view's `deinit` is a
//!      no-op. Used for diagnostic / transient inspection of
//!      either buffer (e.g. a debug overlay reading
//!      `rendered_frame.dispatch` without taking responsibility
//!      for tearing down its scene + dispatch pair). Note that
//!      `mem.swap` between the two owning slots in `Window`
//!      doesn't go through `borrowed` — it physically swaps the
//!      two `Frame` structs (including their `scene` / `dispatch`
//!      pointers and `owned` flags), so both slots remain
//!      `owned = true` post-swap and `Window.deinit` continues
//!      to free both pointee pairs.
//!
//! The struct itself is roughly `@sizeOf(Allocator) + 2 * @sizeOf(*T)`
//! plus a 1-byte `owned` flag — the heavy storage stays inside the two
//! pointee subsystems, which were already heap-allocated for WASM
//! stack reasons (CLAUDE.md §14: `Scene` carries multiple
//! `ArrayListUnmanaged`s totalling tens of KB at full depth, and
//! `DispatchTree` similarly).

const std = @import("std");
const Allocator = std.mem.Allocator;

const scene_mod = @import("../scene/scene.zig");
const Scene = scene_mod.Scene;

const dispatch_mod = @import("dispatch.zig");
const DispatchTree = dispatch_mod.DispatchTree;

/// Bundle of per-window, per-frame rendering subsystems.
///
/// Holds heap-allocated `Scene` and `DispatchTree`. The
/// `owned: bool` field discriminates two ownership shapes:
///
///   - `owned = true` — this `Frame` allocated the two pointees and
///     `deinit` must free them. Set by `initOwned` /
///     `initOwnedInPlace`. Both slots in `Window`
///     (`rendered_frame` and `next_frame`) are always
///     `owned = true` — `mem.swap` between them physically
///     exchanges the entire struct, so both halves of the swap
///     keep their owning shape and `Window.deinit` continues
///     to free both pointee pairs.
///   - `owned = false` — a borrowed view over already-initialised
///     pointees. Used for diagnostic / transient inspection of
///     either buffer (e.g. a debug overlay reading
///     `rendered_frame.dispatch` without taking responsibility
///     for tearing it down). `deinit` is a no-op so the upstream
///     owner's later `deinit` is the single tear-down path.
///     Set by `borrowed`.
///
/// This is the **only** ownership flag in the bundle — the per-field
/// `scene_owned` / `dispatch_owned` flags that PR 7a's audit could
/// have introduced were ruled out as tautological back then (no init
/// path borrowed either pointer); 7c.3a does the actual extraction
/// without re-introducing per-pointer flags. One flag, one struct.
/// Same shape as `AppResources` from PR 7a — the symmetry is
/// deliberate, since `Window` will end up holding one `AppResources`
/// (app-lifetime shared) and one `Frame` (per-window per-tick) as
/// its two ownership-bundle fields.
pub const Frame = struct {
    allocator: Allocator,

    scene: *Scene,
    dispatch: *DispatchTree,

    /// True when this struct owns the two pointees (allocated in an
    /// `initOwned*` path). False when borrowed from another `Frame`
    /// (a transient diagnostic view that doesn't tear the pointees
    /// down). The owning slots on `Window` (both `rendered_frame`
    /// and `next_frame`) always carry `true` — `mem.swap` between
    /// them is a physical struct exchange, so both slots remain
    /// owning across every swap. See struct doc-comment for the
    /// two ownership shapes.
    owned: bool,

    const Self = @This();

    // =========================================================================
    // Owning init paths
    // =========================================================================

    /// Allocate and initialise both subsystems against `allocator`.
    ///
    /// Returns a `Frame` that owns the heap allocations; the caller
    /// is responsible for invoking `deinit` exactly once. The
    /// `viewport_width` / `viewport_height` parameters drive
    /// `scene.setViewport` + `scene.enableCulling` inline so callers
    /// don't need a separate viewport-config step — every existing
    /// `Window.init*` path did that work right after `Scene.init`.
    ///
    /// Used by single-window `Window.initOwned` and
    /// `Window.initWithSharedResources`, both of which previously
    /// open-coded the `allocator.create(Scene)` + `Scene.init` +
    /// `setViewport` + `enableCulling` + `allocator.create(DispatchTree)`
    /// + `DispatchTree.init` sequence inline.
    pub fn initOwned(
        allocator: Allocator,
        viewport_width: f32,
        viewport_height: f32,
    ) !Self {
        // Pair the input assertions with the post-init ones at the
        // bottom of this function (CLAUDE.md §3 — "Pair assertions").
        std.debug.assert(viewport_width >= 0);
        std.debug.assert(viewport_height >= 0);
        std.debug.assert(!std.math.isNan(viewport_width));
        std.debug.assert(!std.math.isNan(viewport_height));

        const scene = try allocator.create(Scene);
        errdefer allocator.destroy(scene);
        scene.* = Scene.init(allocator);
        errdefer scene.deinit();

        // Viewport culling — every pre-7c.3a `Window.init*` path did
        // this immediately after `Scene.init`. Folding it in here
        // means no caller can forget the step (which would silently
        // disable culling and balloon GPU work on large scenes).
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

    /// In-place owning init for callers that need to avoid a stack
    /// temp (WASM `Window.initOwnedPtr` /
    /// `Window.initWithSharedResourcesPtr` are the primary callers).
    /// Marked `noinline` per CLAUDE.md §14 so ReleaseSmall doesn't
    /// combine the stack frame back into the caller.
    ///
    /// `self` must point at uninitialised memory; the function
    /// writes every field. On error, any partially-allocated
    /// subsystems are torn down via the same `errdefer` chain as
    /// `initOwned`.
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
        // (CLAUDE.md §14). The struct is small (~24 bytes) so the
        // literal would not be ruinous, but the rule is "be
        // consistent": every `initInPlace` writes field-by-field.
        // Same shape as `AppResources.initOwnedInPlace`.
        self.allocator = allocator;
        self.scene = scene;
        self.dispatch = dispatch;
        self.owned = true;

        std.debug.assert(@intFromPtr(self.scene) != 0);
        std.debug.assert(@intFromPtr(self.dispatch) != 0);
        std.debug.assert(@intFromPtr(self.scene) != @intFromPtr(self.dispatch));
    }

    // =========================================================================
    // Borrowed init path (reserved for PR 7c.3c double-buffer)
    // =========================================================================

    /// Build a borrowed `Frame` view over already-initialised
    /// pointees. `deinit` becomes a no-op for this instance — the
    /// upstream owner is responsible for tearing the pointees down.
    ///
    /// Used for diagnostic / transient inspection of either buffer
    /// without taking ownership of its teardown (e.g. a debug
    /// overlay reading `rendered_frame.dispatch` while the parent
    /// `Window` keeps the owning slot intact). Note that
    /// `mem.swap` between the two owning slots on `Window` does
    /// NOT go through this constructor — it physically swaps the
    /// two `Frame` structs in place, so both slots stay
    /// `owned = true` post-swap.
    ///
    /// Mirrors `AppResources.borrowed` from PR 7a — the API
    /// symmetry is deliberate.
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

        // Order mirrors pre-7c.3a `Window.deinit`: dispatch first
        // (it holds per-frame listener blocks that may reference
        // event-loop state, but has no scene back-reference),
        // then scene (which owns the per-frame draw lists). The
        // reverse order would also be safe — there are no
        // inter-pointer references between the two — but matching
        // the historical order keeps the diff in `Window.deinit`
        // minimal for the PR 7c.3a landing.
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
// These tests pin the two ownership shapes against `std.testing.allocator`
// — which would surface a leak or double-free immediately. The
// `borrowed` path is verified by constructing an `owned = true` parent,
// borrowing from it, and confirming the borrowed `deinit` is a no-op
// (no double-free against the parent's allocations). Same coverage
// shape as `app_resources.zig`'s test block — the symmetry between
// the two bundles is load-bearing for readers who internalise the
// pattern from one and want to read the other.

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
    // Test fixtures sometimes construct a `Window` before the
    // platform layer has reported a real surface size; the
    // pre-7c.3a `Window.init*` paths tolerated a zero-sized
    // viewport (culling is then a no-op until the first resize
    // event). Pin the same tolerance here so the bundle
    // doesn't reject a legitimate transient state.
    var frame = try Frame.initOwned(testing.allocator, 0, 0);
    defer frame.deinit();

    try testing.expectEqual(@as(f32, 0), frame.scene.viewport_width);
    try testing.expectEqual(@as(f32, 0), frame.scene.viewport_height);
    try testing.expect(frame.scene.culling_enabled);
}

// =============================================================================
// PR 7c.3c — double-buffer `mem.swap` tests
// =============================================================================
//
// Pin the swap semantics that `runtime/frame.zig::renderFrameImpl`
// relies on: `std.mem.swap(Frame, &a, &b)` exchanges the entire
// struct (both pointee pointers AND the `owned` flag), so two
// owning `Frame`s remain owning across every swap and a single
// `deinit` per slot covers both heap-allocated pairs across the
// lifetime of the parent `Window`. These tests pin that
// invariant directly against `testing.allocator` — a leak or a
// double-free would surface immediately.

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
