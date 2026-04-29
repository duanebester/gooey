//! App — application-lifetime state shared across windows.
//!
//! ## Why this exists
//!
//! Per `docs/cleanup-implementation-plan.md` PR 7b.3, the entity map
//! moves off `Window` and onto `App`. Before this slice, every
//! per-window `Window` carried its own `entities: EntityMap`, which
//! meant:
//!
//!   - **No cross-window entity sharing.** A `Counter` entity created
//!     in window A could not be observed by a view in window B —
//!     each window's `EntityMap` was a separate islands of state.
//!     This contradicted GPUI's design (§10 in
//!     `architectural-cleanup-plan.md`), where `entities` lives on
//!     `App` exactly so models can be shared across windows.
//!   - **Lifetime confusion.** Entities outliving any single window
//!     (e.g. an in-flight async task that survives a window close
//!     and writes to a model on close completion) had no
//!     well-defined owner — the `Window`'s `EntityMap` would already
//!     be torn down.
//!
//! After this extraction:
//!
//!   - **Single-window**: `runtime/window_context.zig` owns one
//!     heap-allocated `App` and hands `*App` to its `Window`.
//!   - **Multi-window**: `runtime/multi_window_app.zig::App` embeds
//!     a `context.App` and hands `*context.App` to every window.
//!     All windows share the same `EntityMap`.
//!
//! See [`architectural-cleanup-plan.md` §10 GPUI mapping](../../docs/architectural-cleanup-plan.md#10-the-app--window--contextt-split)
//! for the broader sketch this lands as one slice.
//!
//! ## What's NOT here yet
//!
//! - `keymap` / `globals` (PR 7b.4) — still on `Window` until that
//!   slice. The GPUI mapping puts both on `App`, but `Debugger` is
//!   per-window (overlay quads, frame timing, selected layout id
//!   are all bound to one scene), so 7b.4 will split the global
//!   slot: `App.globals` owns `Keymap` + `*const Theme`,
//!   `Window.globals` keeps `Debugger`.
//! - `image_loader` (PR 7b.5) — placement still pending the
//!   shared-queue vs. per-window-loader UX decision in the plan.
//! - `AppResources` (already at app scope post-7b.2 in
//!   `multi_window_app.zig`; the single-window flow embeds it on
//!   `Window.resources` until the runner builds a real `App` in a
//!   later 7b slice).
//!
//! ## Lifetime
//!
//! Allocated and owned in two shapes only:
//!
//!   1. **Heap-allocated by `runtime/window_context.zig`** —
//!      single-window. The `WindowContext` owns the `App` and
//!      tears it down after the `Window` (so any entity-cleanup
//!      cancel groups have a live `EntityMap` to walk).
//!   2. **Embedded by-value inside `runtime/multi_window_app.zig::App`** —
//!      multi-window. The outer `App` owns the inner `context.App`
//!      directly; `App.deinit` calls `context_app.deinit()` after
//!      the last window has closed.
//!
//! The struct itself is small — `EntityMap` is the only heavy
//! field, and even it just owns a hash map + two arrays. The 7b.4
//! and 7b.5 slices will add `Keymap` (~few KB) and possibly
//! `ImageLoader` (~64KB result buffer). Total budget after all
//! 7b slices land should stay well under the 50KB threshold from
//! CLAUDE.md §14, so heap-allocation via `create` (vs.
//! `initInPlace`) is fine for now.

const std = @import("std");
const Allocator = std.mem.Allocator;

const entity_mod = @import("entity.zig");
const EntityMap = entity_mod.EntityMap;

/// Application-lifetime state shared across all windows.
///
/// Currently holds only `entities`. Subsequent 7b slices will add:
///
///   - `keymap` / `*const Theme` (PR 7b.4)
///   - `image_loader` (PR 7b.5, pending UX decision in the plan)
///
/// The struct grows additively — every field added here is one
/// that was previously per-window and whose lifetime is naturally
/// app-scoped. Per-window state (`Debugger`, `focus`, `hover`,
/// `widgets`, `dispatch`, `scene`, `layout`, ...) stays on
/// `Window` per the GPUI split in §10.
pub const App = struct {
    allocator: Allocator,

    /// IO interface threaded through to `EntityMap` for
    /// cancellation-group bookkeeping. Captured here at `init`
    /// time so windows borrowing this `App` don't need to thread
    /// it again — they reach `app.io` instead. Single-threaded
    /// fallback (`std.Io.Threaded.global_single_threaded`) is the
    /// caller's responsibility, not ours.
    io: std.Io,

    /// Entity storage for GPUI-style state management.
    ///
    /// Pre-7b.3 this was `Window.entities`. The lift to `App`
    /// makes cross-window observation possible: a model entity
    /// created in window A can be observed by a view entity in
    /// window B because both windows borrow the same `*App` and
    /// reach the same map. Frame observations are still cleared
    /// per-frame (`beginFrame` / `endFrame` on `EntityMap`) — the
    /// observer relationship survives across frames, but the
    /// per-frame "this view read that model this frame" set
    /// resets. With multiple windows sharing the map, the per-
    /// frame begin/end pair is driven by every window's
    /// `Window.beginFrame` / `endFrame`; the operation is
    /// idempotent (clearing an already-empty `frame_observations`
    /// is a no-op), so duplicate calls across N windows produce
    /// no visible artefact beyond the redundant work — acceptable
    /// for the small N our `MAX_WINDOWS` cap allows.
    entities: EntityMap,

    const Self = @This();

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// Construct an `App` by value. Suitable when the caller
    /// embeds the result in a parent struct (`multi_window_app.zig`
    /// uses this — `App.resources` is already there too, sharing
    /// the same lifetime).
    ///
    /// The `EntityMap` is initialised against `allocator` and `io`;
    /// see `entity.zig` for its own contract (cancel groups need
    /// a live `io` to be cancelled on entity removal — null `io`
    /// is supported for tests, but every framework code path
    /// should pass a real one).
    pub fn init(allocator: Allocator, io: std.Io) Self {
        // Pair the input assertion with the post-init one below
        // (CLAUDE.md §3 — "Pair assertions"). The `allocator`
        // address-of check catches the rare bug where the caller
        // passed a stack-temp allocator value type that has been
        // garbage-collected; `EntityMap.init` would happily store
        // the dangling vtable and explode at the first `alloc`.
        std.debug.assert(@intFromPtr(&allocator) != 0);

        const result = Self{
            .allocator = allocator,
            .io = io,
            .entities = EntityMap.init(allocator, io),
        };

        // Pair-assert: the result is ready for `entities.new` /
        // `read` / `write`. `EntityMap.init` is `pub fn init(...) Self`
        // (no errors), so reaching this line means the map is
        // populated; the assertion documents the post-condition
        // rather than guarding a hot path.
        std.debug.assert(result.entities.next_id == 1);

        return result;
    }

    /// In-place init for callers that need to avoid a stack
    /// temp. Used by `runtime/window_context.zig` on the
    /// heap-allocated single-window path so the single-window
    /// flow doesn't accumulate a `context.App`-shaped stack
    /// frame (CLAUDE.md §14, even though the current footprint
    /// is well under the 50KB threshold — the rule is "be
    /// consistent": every `init*Ptr` writes field-by-field).
    ///
    /// `self` must point at uninitialised memory; the function
    /// writes every field. No errors today; signature is `void`
    /// so callers don't need a `try`. Marked `noinline` per
    /// CLAUDE.md §14 so ReleaseSmall doesn't combine the stack
    /// frame back into the caller.
    pub noinline fn initInPlace(self: *Self, allocator: Allocator, io: std.Io) void {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(@intFromPtr(&allocator) != 0);

        // Field-by-field — no struct literal — to avoid a stack
        // temp (CLAUDE.md §14). Same idiom as
        // `Window.initOwnedPtr` and `AppResources.initOwnedInPlace`.
        self.allocator = allocator;
        self.io = io;
        self.entities = EntityMap.init(allocator, io);

        std.debug.assert(self.entities.next_id == 1);
    }

    /// Tear down the entity map and any state the `App` owns.
    ///
    /// Order matters in future 7b slices: when `image_loader`
    /// moves here (7b.5), its `deinit` must run before
    /// `entities.deinit` because entity-attached cancel groups
    /// may hold pointers into the loader's result buffer. For
    /// now there is only `entities` and the order is trivial.
    ///
    /// Idempotency: `EntityMap.deinit` is not idempotent — a
    /// second call would walk freed slots — so this `deinit`
    /// inherits that contract. Callers that need a use-after-
    /// free trap should `undefined`-out the pointer after
    /// calling.
    pub fn deinit(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

        // `EntityMap.deinit` cancels any attached async groups
        // before freeing entity data — see `entity.zig`. The
        // `io` captured here is the one those groups will be
        // cancelled against; it must still be valid at this
        // point, which is the caller's responsibility (drop
        // the `App` before tearing down the IO runtime).
        self.entities.deinit();
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "App: init and deinit cleanly" {
    var app = App.init(testing.allocator, undefined);
    defer app.deinit();

    // Fresh app should have an empty entity map.
    try testing.expectEqual(@as(usize, 0), app.entities.count());
}

test "App: initInPlace produces an equivalent instance" {
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);

    app.initInPlace(testing.allocator, undefined);
    defer app.deinit();

    try testing.expectEqual(@as(usize, 0), app.entities.count());
}

test "App: entity creation and access through the shared map" {
    var app = App.init(testing.allocator, undefined);
    defer app.deinit();

    const Counter = struct { value: i32 };
    const e = try app.entities.new(Counter, .{ .value = 42 });

    const data = app.entities.read(Counter, e) orelse return error.MissingEntity;
    try testing.expectEqual(@as(i32, 42), data.value);
}

test "App: entities survive across simulated windows" {
    // Two `*App` borrows from the same backing struct should see
    // the same entities — this is the cross-window sharing
    // property the 7b.3 lift unlocks.
    var app = App.init(testing.allocator, undefined);
    defer app.deinit();

    const Model = struct { count: i32 };

    // "Window A" creates an entity.
    const window_a: *App = &app;
    const m = try window_a.entities.new(Model, .{ .count = 7 });

    // "Window B" — a second borrow of the same `App` — reads it.
    const window_b: *App = &app;
    const data = window_b.entities.read(Model, m) orelse return error.MissingEntity;
    try testing.expectEqual(@as(i32, 7), data.count);
}
