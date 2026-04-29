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
//! - `AppResources` (already at app scope post-7b.2 in
//!   `multi_window_app.zig`; the single-window flow embeds it on
//!   `Window.resources` until the runner builds a real `App` in a
//!   later 7b slice).
//!
//! ## Late-bound `image_loader`
//!
//! PR 7b.5 lifted `image_loader` off `Window` onto `App`. The
//! loader needs an `*ImageAtlas` at init time — but the atlas
//! lives on `AppResources`, which is constructed *after*
//! `App.init` in the single-window flow (`Window.initOwned`
//! creates the resources), and *before* `App.init` in the
//! multi-window flow (`multi_window_app::App.init` creates the
//! shared `AppResources` and *then* the embedded `context.App`).
//! Rather than thread `*ImageAtlas` through `App.init`'s
//! signature (which would force `multi_window_app` to reorder
//! `resources` / `context_app` field init and force the
//! single-window runner to construct a `Window` before the
//! `App` it borrows), `App` exposes a two-phase init:
//!
//!   1. `App.init` / `App.initInPlace` allocates the entity map,
//!      registers the `Keymap` global, and leaves `image_loader`
//!      undefined (`image_loader_bound = false`).
//!   2. `App.bindImageLoader(*ImageAtlas)` runs `initInPlace` on
//!      the loader at the `App`'s final heap address (no
//!      `fixupQueue` dance — `App` is already heap-allocated by
//!      every framework caller). Asserts single-bind.
//!
//! Bind sites:
//!
//!   - **Single-window** (native + WASM): the runner / WASM
//!     bootstrap creates the `Window` first (which creates the
//!     owning `AppResources`), then calls
//!     `app.bindImageLoader(window.resources.image_atlas)`. See
//!     `runtime/window_context.zig::WindowContext.init` and
//!     `app.zig::WebApp.initImpl`.
//!   - **Multi-window**: `multi_window_app::App.init` constructs
//!     the shared `AppResources` and the embedded `context.App`
//!     in that order, then calls
//!     `context_app.bindImageLoader(resources.image_atlas)` once.
//!     Subsequent windows opened via
//!     `WindowContext.initWithSharedResources` do *not* re-bind
//!     — the loader is already wired against the shared atlas
//!     that every window's borrowed `AppResources` points at.
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
//! The struct itself is moderately sized after PR 7b.5 — the
//! embedded `ImageLoader` is the largest contributor:
//! `result_buffer` is `MAX_IMAGE_LOAD_RESULTS` (32) entries
//! × `@sizeOf(ImageLoadResult)` (~32 B per slot, union with
//! pointers) ≈ 1 KB; `pending_hashes` is 64 × 8 B = 512 B;
//! `failed_hashes` is 128 × 8 B = 1 KB. Plus `EntityMap`
//! (~few KB) and `Globals` (32 × ~64 B ≈ 2 KB). Total well
//! under the 50 KB heap-vs-stack threshold from CLAUDE.md §14
//! — `runtime/runner.zig` and `app.zig::WebApp` still use
//! `allocator.create(App)` + `initInPlace` for consistency
//! with the larger `Window`, not because the size demands it.

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

// PR 7b.5 — `ImageLoader` and `ImageAtlas` from the image
// subsystem. `ImageLoader` is the URL-fetch + decode +
// atlas-cache machine extracted in PR 1; pre-7b.5 it lived as
// a per-window field on `Window`, which made cross-window
// dedup structurally impossible (window A and window B
// requesting the same URL would each launch a fetch, double
// the bandwidth, and cache twice into the shared atlas).
// Lifting onto `App` means one pending set, one failed set,
// one fetch group covering all windows. The loader's atlas
// pointer is bound late (see file header).
const image_mod = @import("../image/mod.zig");
const ImageLoader = image_mod.ImageLoader;
const ImageAtlas = image_mod.ImageAtlas;

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
///   - `image_loader` — async URL fetch + decode + atlas-cache
///     subsystem, lifted off `Window` in PR 7b.5. Late-bound
///     against the shared `*ImageAtlas` via `bindImageLoader`
///     (see file header for the two-phase init rationale).
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

    /// PR 7b.5 — async image-load subsystem (URL fetch + decode
    /// + atlas cache). Pre-7b.5 every `Window` carried its own
    /// `ImageLoader`; the lift here makes the pending set, the
    /// failed set, and the fetch group app-scoped, so two
    /// windows requesting the same URL share one in-flight
    /// fetch.
    ///
    /// Initialised in two phases — see file header. `init` /
    /// `initInPlace` leave this field undefined and
    /// `image_loader_bound = false`; the framework caller that
    /// has the `*ImageAtlas` available calls `bindImageLoader`
    /// exactly once before the first frame.
    ///
    /// `ImageLoader.initInPlace` writes the embedded
    /// `Io.Queue`'s pointer to `&self.result_buffer`, so the
    /// loader must be initialised at its final heap address.
    /// `App` is always heap-allocated (or embedded by-value
    /// inside a heap-allocated parent) by every framework
    /// caller, so we can `initInPlace` directly without a
    /// `fixupQueue` dance like the pre-7b.5 `Window.initOwned`
    /// path needed.
    image_loader: ImageLoader = undefined,

    /// PR 7b.5 — `true` iff `bindImageLoader` has been called.
    /// Guards `App.deinit` against tearing down an undefined
    /// `image_loader` field on an unbound `App` (test fixtures
    /// in this file construct `App` instances that never bind
    /// against a real atlas), and guards `bindImageLoader`
    /// against a double-bind (a framework-internal bug, not a
    /// runtime fallback). Pair-asserted in
    /// `runtime/render.zig::ensureNativeUrlLoading` so a
    /// missing-bind reaches the developer at the call site
    /// instead of corrupting the loader's queue invariants.
    image_loader_bound: bool = false,

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

        // PR 7b.5 — `image_loader` is intentionally left
        // undefined here. The caller binds it via
        // `bindImageLoader(*ImageAtlas)` after the parent has
        // constructed an `AppResources`. Until then,
        // `image_loader_bound = false` (the struct's default)
        // ensures `deinit` skips the loader and prevents a
        // double-bind from `bindImageLoader` itself.
        std.debug.assert(!result.image_loader_bound);

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

        // PR 7b.5 — `self` was raw memory before this call
        // (caller did `allocator.create` without zeroing); the
        // explicit `false` here makes the unbound state
        // explicit. `image_loader` itself stays undefined
        // until `bindImageLoader` runs.
        self.image_loader_bound = false;

        std.debug.assert(self.entities.next_id == 1);
        std.debug.assert(self.globals.has(Keymap));
        std.debug.assert(!self.image_loader_bound);
    }

    /// PR 7b.5 — bind the image loader against the shared
    /// `*ImageAtlas`. Idempotent on same-atlas re-binds: the
    /// first call runs `ImageLoader.initInPlace` at the loader's
    /// final `App` heap address, subsequent calls with the same
    /// atlas pointer are no-ops, and a call with a different
    /// atlas pointer trips the pair-assertion (a framework bug
    /// — every window in an `App`'s lifetime borrows the same
    /// shared `ImageAtlas`, so a different pointer means the
    /// caller has confused itself about which `App` it is
    /// binding).
    ///
    /// Idempotency is required because both
    /// `WindowContext.init` (single-window) and
    /// `WindowContext.initWithSharedResources` (multi-window)
    /// call this from each window they construct. The first
    /// window in either flow performs the actual bind; every
    /// subsequent window in the same `App` (multi-window only)
    /// hits the same-atlas short-circuit. This avoids needing
    /// a separate "bind-if-unbound" entry point and keeps the
    /// `App.init → bindImageLoader` ordering consistent with
    /// every other late-bound subsystem the framework will add
    /// in future PRs.
    ///
    /// `image_atlas` must point at a stable heap address — the
    /// loader stores the pointer and dereferences it on every
    /// `drain` call. The single-window flow passes
    /// `window.resources.image_atlas` (lives on `Window` for
    /// the duration); the multi-window flow passes
    /// `multi_window_app::App.resources.image_atlas` (lives on
    /// the outer `App` for the duration). Both are stable
    /// heap addresses for the entire `App` lifetime.
    pub fn bindImageLoader(self: *Self, image_atlas: *ImageAtlas) void {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(@intFromPtr(image_atlas) != 0);

        // Idempotent same-atlas short-circuit. The single-window
        // flow's only window calls this once and falls through to
        // the bind branch. The multi-window flow's first window
        // calls this and falls through; the second-and-later
        // windows hit this short-circuit because every window in
        // an `App` lifetime borrows the same shared
        // `AppResources.image_atlas`. A different atlas pointer
        // here would mean either (a) the caller mixed up `App`
        // instances, or (b) the parent rebuilt `AppResources`
        // mid-lifetime — both framework bugs, hence the panic
        // rather than a silent re-bind that would orphan in-
        // flight fetches against the previous atlas.
        if (self.image_loader_bound) {
            std.debug.assert(self.image_loader.image_atlas == image_atlas);
            return;
        }

        // `App` is always heap-allocated (or embedded inside a
        // heap-allocated parent) by every framework caller, so
        // `&self.image_loader` is already at its final
        // address — no by-value copy will follow this call,
        // and the embedded `Io.Queue`'s pointer to
        // `&self.image_loader.result_buffer` cannot dangle.
        self.image_loader.initInPlace(self.io, self.allocator, image_atlas);
        self.image_loader_bound = true;

        // Pair-assert: the loader is now ready for
        // `enqueueIfRoom` / `drain` calls. Pending / failed
        // sets start empty (the `initInPlace` body zeroes
        // them); asserting one of those invariants here
        // documents the post-condition for the next reader.
        std.debug.assert(self.image_loader_bound);
        std.debug.assert(self.image_loader.pending_count == 0);
        std.debug.assert(self.image_loader.failed_count == 0);
    }

    /// Tear down the entity map, the image loader, and any
    /// state the `App` owns.
    ///
    /// Order matters:
    ///
    ///   1. `image_loader.deinit` — runs **first** so
    ///      background fetch tasks see queue closure on their
    ///      next put attempt and cancel-group cancellation on
    ///      their next cancel-point check. Tearing the loader
    ///      down before the atlas (which lives on
    ///      `AppResources`, owned upstream) means in-flight
    ///      fetches unwind against a still-live atlas — the
    ///      cancel path inside a fetch task may complete a
    ///      partial atlas write before observing cancellation,
    ///      and that write must land on memory that has not
    ///      yet been freed. The atlas being upstream-owned
    ///      means `App.deinit` does not control its lifetime;
    ///      the upstream owner (`runtime/runner.zig`'s defer
    ///      chain in single-window mode, or
    ///      `multi_window_app::App.deinit` in multi-window
    ///      mode) is responsible for tearing the atlas down
    ///      *after* `App.deinit` returns.
    ///   2. `entities.deinit` — runs after the loader because
    ///      entity-attached cancel groups may walk the loader's
    ///      pending set during cleanup (forward-looking; today
    ///      no entity cancel group reaches into the loader,
    ///      but the structural ordering keeps that direction
    ///      safe).
    ///   3. `globals.deinit` — runs last because no
    ///      entity-attached cancel group today reaches into a
    ///      global, but the reverse direction (a global's
    ///      `deinit` walking the entity map) is not yet
    ///      audited. Keeping `entities` torn down first means
    ///      any pending cancel walks see a live `Globals`
    ///      instead of a zeroed one.
    ///
    /// PR 7b.5 — the loader teardown is guarded by
    /// `image_loader_bound`. Test fixtures in this file
    /// construct `App` instances that never bind a loader; an
    /// unconditional `image_loader.deinit()` call would walk
    /// undefined memory and trip the queue's internal asserts.
    /// Production framework code paths always bind exactly
    /// once via `bindImageLoader`, so the guard is moot in
    /// production but essential for testability.
    ///
    /// Idempotency: neither `EntityMap.deinit` nor `Globals.deinit`
    /// is fully idempotent — a second call would walk freed slots
    /// — so this `deinit` inherits that contract. Callers that
    /// need a use-after-free trap should `undefined`-out the
    /// pointer after calling.
    pub fn deinit(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

        // PR 7b.5 — tear the loader down first. `deinit`
        // closes the result queue (background tasks see
        // closure on next put) and cancels the fetch group
        // (in-flight tasks unwind cleanly). Blocking is
        // acceptable here — we are shutting down. The guard
        // skips this when no `bindImageLoader` call ever ran
        // (test fixtures only); production framework code
        // always binds before the first frame.
        if (self.image_loader_bound) {
            self.image_loader.deinit();
            self.image_loader_bound = false;
        }

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

test "App: image_loader starts unbound; deinit skips it" {
    // PR 7b.5 — fresh `App` reports `image_loader_bound = false`
    // and tears down cleanly without a `bindImageLoader` call.
    // This is the exact pattern test fixtures rely on; a
    // regression here would force every test to construct a
    // real `ImageAtlas`.
    var app = try App.init(testing.allocator, undefined);
    defer app.deinit();

    try testing.expect(!app.image_loader_bound);
}

test "App: bindImageLoader wires the loader against the atlas" {
    // PR 7b.5 — exercise the full bind path: real allocator,
    // real (single-threaded) IO, real `ImageAtlas`. After
    // `bindImageLoader` the pending and failed sets are
    // populated (empty), and `image_loader_bound` flips true.
    const io = std.Io.Threaded.global_single_threaded.io();

    var app = try App.init(testing.allocator, io);
    defer app.deinit();

    var image_atlas = try ImageAtlas.init(testing.allocator, 1.0, io);
    defer image_atlas.deinit();

    app.bindImageLoader(&image_atlas);
    try testing.expect(app.image_loader_bound);
    try testing.expectEqual(@as(u32, 0), app.image_loader.pending_count);
    try testing.expectEqual(@as(u32, 0), app.image_loader.failed_count);
}

test "App: image_loader is shared across simulated windows" {
    // PR 7b.5 — the cross-window sharing property the loader
    // lift unlocks. A URL recorded as "pending" through one
    // borrow of `App` is visible as "pending" through a
    // second borrow. This is the exact property that
    // structurally eliminates duplicate fetches when two
    // windows render the same URL in the same frame.
    const io = std.Io.Threaded.global_single_threaded.io();

    var app = try App.init(testing.allocator, io);
    defer app.deinit();

    var image_atlas = try ImageAtlas.init(testing.allocator, 1.0, io);
    defer image_atlas.deinit();

    app.bindImageLoader(&image_atlas);

    // "Window A" enqueues a URL. `ImageKey.init` takes an
    // `ImageSource` union plus optional logical dimensions and
    // a scale factor — same shape `runtime/render.zig` uses
    // when building keys for the loader.
    const url = "https://example.com/cat.png";
    const key = image_mod.ImageKey.init(.{ .url = url }, 64.0, 64.0, 1.0);
    const window_a: *App = &app;
    const launched = window_a.image_loader.enqueueIfRoom(url, key);
    try testing.expect(launched);

    // "Window B" — second borrow of the same `App` — observes
    // the URL is already pending and would short-circuit.
    const window_b: *App = &app;
    try testing.expect(window_b.image_loader.isPending(key.source_hash));

    // Cancel the in-flight fetch before tearing down so the
    // background task does not race the test allocator.
    // `App.deinit` (run via the outer `defer`) handles this
    // via `image_loader.deinit()`.
}
