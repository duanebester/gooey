//! App — application-lifetime state shared across windows.
//!
//! ## Why this exists
//!
//! Per `docs/cleanup-implementation-plan.md` PR 7b.3, the entity map
//! moves off `Window` and onto `App`. Before that slice, every
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
//! PR 7b.4 extends the same reasoning to `Keymap` and `*const Theme`:
//! both are app-scoped per the GPUI mapping in §10. Pre-7b.4 every
//! `Window.globals` held its own `Keymap` and (via `Builder.setTheme`)
//! its own `*const Theme` slot. Lifting them to `App.globals` lets
//! every window in the same app share one keymap (the keystroke
//! contract is the same regardless of which window is focused) and
//! one active theme (a tab swap in window A immediately repaints
//! window B with the new colors). `Debugger` deliberately stays on
//! `Window.globals` because its overlay quads, frame timing, and
//! selected layout id are all bound to a single scene — sharing one
//! debugger across windows would mix metrics from two unrelated
//! frames.
//!
//! After this extraction:
//!
//!   - **Single-window**: `runtime/window_context.zig` owns one
//!     heap-allocated `App` and hands `*App` to its `Window`. The
//!     `App` carries the `EntityMap` and the `Keymap` slot in
//!     `globals`; the `Window` keeps a per-window `Debugger`.
//!   - **Multi-window**: `runtime/multi_window_app.zig::App` embeds
//!     a `context.App` and hands `*context.App` to every window.
//!     All windows share the same `EntityMap`, the same `Keymap`,
//!     and the same `*const Theme` slot — but each has its own
//!     `Debugger`.
//!
//! See [`architectural-cleanup-plan.md` §10 GPUI mapping](../../docs/architectural-cleanup-plan.md#10-the-app--window--contextt-split)
//! for the broader sketch this lands as one slice.
//!
//! ## What's NOT here yet
//!
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
//!   1. **Heap-allocated by `runtime/runner.zig`** —
//!      single-window. The runner owns the `App` and tears it down
//!      after the `WindowContext` (so any entity-cleanup cancel
//!      groups have a live `EntityMap` to walk). On WASM the same
//!      role is played by `app.zig::WebApp`'s `g_app` global.
//!   2. **Embedded by-value inside `runtime/multi_window_app.zig::App`** —
//!      multi-window. The outer `App` owns the inner `context.App`
//!      directly; `App.deinit` calls `context_app.deinit()` after
//!      the last window has closed.
//!
//! The struct itself is small — `EntityMap` and `Globals` are the
//! only heavy fields, and `Globals` is a fixed-capacity 32-slot
//! array of small entries (~64 bytes per slot). PR 7b.4 adds one
//! owned `Keymap` (~few KB of bindings) and one borrowed-const
//! `*const Theme` (one pointer). PR 7b.5 may add an `ImageLoader`
//! (~64KB result buffer) — total budget after all 7b slices land
//! should still stay well under the 50KB threshold from CLAUDE.md
//! §14, so heap-allocation via `create` (vs. `initInPlace`) is
//! fine for now.

const std = @import("std");
const Allocator = std.mem.Allocator;

const entity_mod = @import("entity.zig");
const EntityMap = entity_mod.EntityMap;

// PR 7b.4 — `Globals` is the type-keyed singleton store introduced
// in PR 6 (see `global.zig`). It moves the bulk of cross-cutting
// state — `Keymap`, `*const Theme` — off `Window`'s direct field
// list and onto `App`'s. `Debugger` deliberately stays on
// `Window.globals` (per-window concern; see file header).
const global_mod = @import("global.zig");
const Globals = global_mod.Globals;

// PR 7b.4 — `Keymap` is registered as an owned global on `App`.
// One keymap per app, shared across every window — the action
// dispatch contract (`cmd-z` means Undo no matter which window
// is focused) is naturally app-scoped. `Keymap` exposes
// `pub fn deinit(*Keymap)` which `Globals.deinit` discovers via
// `hasDeinit` and invokes through the owned-deinit thunk.
const action_mod = @import("../input/actions.zig");
const Keymap = action_mod.Keymap;

/// Application-lifetime state shared across all windows.
///
/// Currently holds:
///
///   - `entities` — entity storage for GPUI-style state management
///     (lifted off `Window` in PR 7b.3).
///   - `globals` — type-keyed singleton store. Owns `Keymap`
///     (registered by `init` / `initInPlace`) and the `*const Theme`
///     slot (populated lazily by `Builder.setTheme`). Future slots
///     for app-scoped settings / telemetry land here too.
///
/// Subsequent 7b slices will add:
///
///   - `image_loader` (PR 7b.5, pending UX decision in the plan).
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

    /// Type-keyed singleton store (PR 6 — see `global.zig`). PR 7b.4
    /// lifts `Keymap` registration off `Window.globals` onto this
    /// field; the `*const Theme` slot is populated lazily by
    /// `Builder.setTheme` (see `ui/builder.zig`). `Debugger` stays
    /// on `Window.globals` because every window has its own.
    ///
    /// Default-constructed (`entries = @splat(Entry.empty)`);
    /// populated post-init by `init` / `initInPlace` via `setOwned`.
    /// Torn down in `App.deinit` via `globals.deinit(allocator)` —
    /// the thunk built at `setOwned` time picks the right shape
    /// per type (`fn(*T) void` vs. `fn(*T, Allocator) void`), so
    /// `Keymap.deinit(*Keymap)` is invoked correctly without the
    /// caller having to know the registry's internals.
    globals: Globals = .{},

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
    ///
    /// PR 7b.4 — also registers an owned `Keymap` in `globals`.
    /// `setOwned` heap-allocates a `*Keymap` via `allocator`; the
    /// resulting pointer survives the by-value copy (`globals` is
    /// a fixed-capacity array of small entries that hold pointers
    /// to stable heap addresses, so the copy duplicates the
    /// pointer slot without invalidating the pointee). The error
    /// path returns through `errdefer` — `entities.deinit` runs
    /// before `globals.deinit` for symmetry with the success-path
    /// `App.deinit` ordering, even though neither holds pointers
    /// into the other today.
    pub fn init(allocator: Allocator, io: std.Io) !Self {
        // Pair the input assertion with the post-init one below
        // (CLAUDE.md §3 — "Pair assertions"). The `allocator`
        // address-of check catches the rare bug where the caller
        // passed a stack-temp allocator value type that has been
        // garbage-collected; `EntityMap.init` would happily store
        // the dangling vtable and explode at the first `alloc`.
        std.debug.assert(@intFromPtr(&allocator) != 0);

        var result = Self{
            .allocator = allocator,
            .io = io,
            .entities = EntityMap.init(allocator, io),
            .globals = .{},
        };
        errdefer result.entities.deinit();

        // PR 7b.4 — register the app-wide `Keymap`. `Keymap.init`
        // is infallible; `setOwned` may fail with `OutOfMemory` if
        // the global registry is full, but `MAX_GLOBALS = 32` and
        // we are the first writer, so the only realistic failure
        // here is the heap allocation for the owned `*Keymap`
        // itself. The `errdefer` chain unwinds the `EntityMap`
        // above; the `Keymap` allocation has not happened yet on
        // the failure path so there is nothing further to free.
        try result.globals.setOwned(allocator, Keymap, Keymap.init(allocator));
        errdefer result.globals.deinit(allocator);

        // Pair-assert: the result is ready for `entities.new` /
        // `read` / `write`, and the registry has the Keymap slot
        // populated. `EntityMap.init` is `pub fn init(...) Self`
        // (no errors), so reaching this line means the map is
        // populated; the assertions document the post-conditions.
        std.debug.assert(result.entities.next_id == 1);
        std.debug.assert(result.globals.has(Keymap));

        return result;
    }

    /// In-place init for callers that need to avoid a stack
    /// temp. Used by `runtime/runner.zig` on the heap-allocated
    /// single-window path so the runner doesn't accumulate a
    /// `context.App`-shaped stack frame (CLAUDE.md §14, even though
    /// the current footprint is well under the 50KB threshold —
    /// the rule is "be consistent": every `init*Ptr` writes
    /// field-by-field).
    ///
    /// `self` must point at uninitialised memory; the function
    /// writes every field. Marked `noinline` per CLAUDE.md §14 so
    /// ReleaseSmall doesn't combine the stack frame back into the
    /// caller. PR 7b.4 — signature changed from `void` to `!void`
    /// because `globals.setOwned(Keymap, ...)` can fail with
    /// `OutOfMemory` (the heap-alloc for the owned `*Keymap`).
    pub noinline fn initInPlace(self: *Self, allocator: Allocator, io: std.Io) !void {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(@intFromPtr(&allocator) != 0);

        // Field-by-field — no struct literal — to avoid a stack
        // temp (CLAUDE.md §14). Same idiom as
        // `Window.initOwnedPtr` and `AppResources.initOwnedInPlace`.
        self.allocator = allocator;
        self.io = io;
        self.entities = EntityMap.init(allocator, io);
        errdefer self.entities.deinit();

        // PR 7b.4 — `globals` starts default-constructed (every
        // entry in the fixed-capacity array marked `empty`); the
        // assignment below makes that explicit since `self` was
        // raw memory before this call (caller did `allocator.create`
        // without zeroing).
        self.globals = .{};

        // PR 7b.4 — register the app-wide `Keymap`. See `init` for
        // the full rationale; the only difference here is the
        // `errdefer` order — `entities.deinit` runs first because
        // it was assigned first.
        try self.globals.setOwned(allocator, Keymap, Keymap.init(allocator));
        errdefer self.globals.deinit(allocator);

        std.debug.assert(self.entities.next_id == 1);
        std.debug.assert(self.globals.has(Keymap));
    }

    /// Tear down the entity map and any state the `App` owns.
    ///
    /// Order matters: `entities.deinit` runs **before**
    /// `globals.deinit` because no entity-attached cancel group
    /// today reaches into a global, but the reverse direction
    /// (a global's `deinit` walking the entity map) is not yet
    /// audited — keeping `entities` the first to go means any
    /// pending cancel walks see a live `Globals` instead of a
    /// zeroed one. When `image_loader` lands here in 7b.5, its
    /// `deinit` must run before `entities.deinit` because
    /// entity-attached fetches may hold pointers into the loader's
    /// result buffer.
    ///
    /// Idempotency: neither `EntityMap.deinit` nor `Globals.deinit`
    /// is fully idempotent — a second call would walk freed slots
    /// — so this `deinit` inherits that contract. Callers that
    /// need a use-after-free trap should `undefined`-out the
    /// pointer after calling.
    pub fn deinit(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

        // `EntityMap.deinit` cancels any attached async groups
        // before freeing entity data — see `entity.zig`. The
        // `io` captured here is the one those groups will be
        // cancelled against; it must still be valid at this
        // point, which is the caller's responsibility (drop
        // the `App` before tearing down the IO runtime).
        self.entities.deinit();

        // PR 7b.4 — tear down owned globals (`Keymap` today;
        // future settings / telemetry slots when they land). The
        // thunk built at `setOwned` time invokes the right
        // `deinit` shape per type, so callers don't have to
        // know the registry's internals.
        self.globals.deinit(self.allocator);
    }

    // =========================================================================
    // Accessors
    // =========================================================================

    /// PR 7b.4 — typed accessor for the app-wide keymap. Mirrors
    /// the pre-7b.4 `Window.keymap()` accessor in shape; the lift
    /// is transparent to call sites that go through the
    /// `Window.keymap()` forwarder. Direct callers (rare —
    /// `Cx.keymap()` may eventually land) get the same panic
    /// contract: a missing slot is a framework bug, not a
    /// runtime fallback, because every `init*` path on `App`
    /// registers one.
    pub fn keymap(self: *Self) *Keymap {
        return self.globals.get(Keymap) orelse {
            std.debug.panic("App.keymap(): no Keymap registered in globals (init* did not run?)", .{});
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "App: init and deinit cleanly" {
    var app = try App.init(testing.allocator, undefined);
    defer app.deinit();

    // Fresh app should have an empty entity map.
    try testing.expectEqual(@as(usize, 0), app.entities.count());
    // PR 7b.4 — and a populated `Keymap` slot.
    try testing.expect(app.globals.has(Keymap));
}

test "App: initInPlace produces an equivalent instance" {
    const app = try testing.allocator.create(App);
    defer testing.allocator.destroy(app);

    try app.initInPlace(testing.allocator, undefined);
    defer app.deinit();

    try testing.expectEqual(@as(usize, 0), app.entities.count());
    try testing.expect(app.globals.has(Keymap));
}

test "App: entity creation and access through the shared map" {
    var app = try App.init(testing.allocator, undefined);
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
    var app = try App.init(testing.allocator, undefined);
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

test "App: keymap accessor returns the registered Keymap" {
    // PR 7b.4 — bind a keystroke through the accessor; reading
    // it back via the same accessor should see the binding,
    // proving the slot survives across two `keymap()` calls.
    var app = try App.init(testing.allocator, undefined);
    defer app.deinit();

    const Undo = struct {};
    app.keymap().bind(Undo, "cmd-z", null);

    const match = app.keymap().match(.z, .{ .cmd = true }, &.{});
    try testing.expect(match != null);
}

test "App: keymap is shared across simulated windows" {
    // PR 7b.4 — the cross-window sharing property the keymap
    // lift unlocks: a binding registered through "window A"'s
    // borrow of `App` is visible through "window B"'s borrow.
    var app = try App.init(testing.allocator, undefined);
    defer app.deinit();

    const Save = struct {};

    const window_a: *App = &app;
    window_a.keymap().bind(Save, "cmd-s", null);

    const window_b: *App = &app;
    const match = window_b.keymap().match(.s, .{ .cmd = true }, &.{});
    try testing.expect(match != null);
}
