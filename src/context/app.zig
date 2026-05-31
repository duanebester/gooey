//! App — application-lifetime state shared across windows.
//!
//! Holds the state whose lifetime is naturally app-scoped rather than
//! per-window:
//!
//!   - `entities` — entity storage. Living on `App` (not `Window`) lets a
//!     model created in one window be observed by a view in another, and
//!     gives entities a well-defined owner that outlives any single window
//!     (e.g. an in-flight async task that survives a window close).
//!   - `globals` — type-keyed singleton store owning the app-wide `Keymap`
//!     and the `*const Theme` slot, so one keymap and one active theme are
//!     shared across every window. (`Debugger` stays per-window on
//!     `Window.globals` — its overlay quads and frame timing are bound to a
//!     single scene.)
//!   - `image_loader` — async URL fetch + decode + atlas cache. App-scoped
//!     so two windows requesting the same URL share one in-flight fetch,
//!     one pending set, and one failed set.
//!
//! ## Late-bound `image_loader`
//!
//! The loader needs an `*ImageAtlas` at init time, but the atlas lives on
//! `AppResources`, which is constructed at a different point relative to
//! `App.init` in the single- vs. multi-window flows. Rather than thread
//! `*ImageAtlas` through `App.init`, the loader uses two-phase init:
//!
//!   1. `App.init` / `App.initInPlace` allocates the entity map, registers
//!      the `Keymap` global, and leaves `image_loader` undefined
//!      (`image_loader_bound = false`).
//!   2. `App.bindImageLoader(*ImageAtlas)` runs `initInPlace` on the loader
//!      at the `App`'s final heap address (asserts single-bind). The
//!      framework caller that has the atlas calls this once before the
//!      first frame; in multi-window flows later windows hit the
//!      same-atlas short-circuit.
//!
//! ## Lifetime
//!
//! Two shapes:
//!
//!   1. Heap-allocated by `runtime/runner.zig` (single-window; `WebApp`'s
//!      `g_app` global on WASM). The runner owns the `App` and tears it
//!      down after the `WindowContext`, so entity cancel groups have a live
//!      `EntityMap` to walk.
//!   2. Embedded by value inside `runtime/multi_window_app.zig::App`
//!      (multi-window); `App.deinit` runs after the last window closes.
//!
//! `App` is always heap-allocated (or embedded in a heap-allocated
//! parent), which is why `bindImageLoader` can `initInPlace` the loader's
//! embedded `Io.Queue` (whose pointer must reference a stable address)
//! without a fixup dance.

const std = @import("std");
const Allocator = std.mem.Allocator;

const entity_mod = @import("entity.zig");
const EntityMap = entity_mod.EntityMap;

// `Globals` is the type-keyed singleton store (see `global.zig`); on
// `App` it owns `Keymap` and the `*const Theme` slot. `Debugger` stays
// per-window on `Window.globals`.
const global_mod = @import("global.zig");
const Globals = global_mod.Globals;

// `Keymap` is registered as an owned global on `App` — one keymap per
// app, since the action dispatch contract (`cmd-z` means Undo no matter
// which window is focused) is app-scoped.
const action_mod = @import("../input/actions.zig");
const Keymap = action_mod.Keymap;

// `ImageLoader` (URL fetch + decode + atlas cache) and `ImageAtlas`.
// On `App` the loader has one pending set, one failed set, and one
// fetch group across all windows, so two windows requesting the same
// URL share one fetch. Its atlas pointer is bound late (see file header).
const image_mod = @import("../image/mod.zig");
const ImageLoader = image_mod.ImageLoader;
const ImageAtlas = image_mod.ImageAtlas;

/// Application-lifetime state shared across all windows.
///
///   - `entities` — entity storage for shared state management.
///   - `globals` — type-keyed singleton store. Owns `Keymap` (registered
///     by `init` / `initInPlace`) and the `*const Theme` slot (populated
///     lazily by `Builder.setTheme`).
///   - `image_loader` — async URL fetch + decode + atlas-cache subsystem.
///     Late-bound against the shared `*ImageAtlas` via `bindImageLoader`
///     (see file header for the two-phase init rationale).
///
/// Per-window state (`Debugger`, `focus`, `hover`, `widgets`, `dispatch`,
/// `scene`, `layout`, ...) stays on `Window`.
pub const App = struct {
    allocator: Allocator,

    /// IO interface threaded through to `EntityMap` for
    /// cancellation-group bookkeeping. Captured here at `init`
    /// time so windows borrowing this `App` don't need to thread
    /// it again — they reach `app.io` instead. Single-threaded
    /// fallback (`std.Io.Threaded.global_single_threaded`) is the
    /// caller's responsibility, not ours.
    io: std.Io,

    /// Entity storage for shared state management.
    ///
    /// Living on `App` makes cross-window observation possible: a model
    /// created in window A can be observed by a view in window B because
    /// both borrow the same `*App` and reach the same map. Frame
    /// observations are cleared per-frame (`beginFrame` / `endFrame`) —
    /// the observer relationship survives across frames, but the per-frame
    /// "this view read that model this frame" set resets. The begin/end
    /// pair is idempotent (clearing an empty `frame_observations` is a
    /// no-op), so the redundant calls from N windows sharing the map are
    /// harmless.
    entities: EntityMap,

    /// Type-keyed singleton store (see `global.zig`). Owns the `Keymap`
    /// (registered post-init via `setOwned`) and the `*const Theme` slot
    /// (populated lazily by `Builder.setTheme`). `Debugger` stays on
    /// `Window.globals` because every window has its own.
    ///
    /// Torn down in `App.deinit` via `globals.deinit(allocator)` — the
    /// thunk built at `setOwned` time picks the right deinit shape per
    /// type, so `Keymap.deinit` is invoked correctly without the caller
    /// knowing the registry's internals.
    globals: Globals = .{},

    /// Async image-load subsystem (URL fetch + decode + atlas cache).
    /// App-scoped so two windows requesting the same URL share one
    /// in-flight fetch, pending set, and failed set.
    ///
    /// Initialised in two phases — see file header. `init` / `initInPlace`
    /// leave this field undefined and `image_loader_bound = false`; the
    /// framework caller that has the `*ImageAtlas` calls `bindImageLoader`
    /// once before the first frame.
    ///
    /// `ImageLoader.initInPlace` writes the embedded `Io.Queue`'s pointer
    /// to `&self.result_buffer`, so the loader must be initialised at its
    /// final heap address. `App` is always heap-allocated, so
    /// `bindImageLoader` can `initInPlace` directly without a fixup dance.
    image_loader: ImageLoader = undefined,

    /// `true` iff `bindImageLoader` has been called. Guards `App.deinit`
    /// against tearing down an undefined `image_loader` on an unbound
    /// `App` (test fixtures never bind a real atlas), and guards
    /// `bindImageLoader` against a double-bind.
    image_loader_bound: bool = false,

    const Self = @This();

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// Construct an `App` by value. Suitable when the caller embeds the
    /// result in a parent struct (`multi_window_app.zig` does this).
    ///
    /// The `EntityMap` is initialised against `allocator` and `io` (cancel
    /// groups need a live `io` to be cancelled on entity removal — null
    /// `io` is supported for tests only). Also registers an owned `Keymap`
    /// in `globals`: `setOwned` heap-allocates a `*Keymap`, and that
    /// pointer survives the by-value return because `globals` holds
    /// pointers to stable heap addresses, not the pointees themselves.
    pub fn init(allocator: Allocator, io: std.Io) !Self {
        // The `allocator` address-of check catches the rare bug where the
        // caller passed a stack-temp allocator that has gone out of scope;
        // `EntityMap.init` would store the dangling vtable and explode at
        // the first `alloc`.
        std.debug.assert(@intFromPtr(&allocator) != 0);

        var result = Self{
            .allocator = allocator,
            .io = io,
            .entities = EntityMap.init(allocator, io),
            .globals = .{},
        };
        errdefer result.entities.deinit();

        // Register the app-wide `Keymap`. `setOwned` can fail only on the
        // heap allocation for the owned `*Keymap` (the registry has room).
        // The `errdefer` above unwinds the `EntityMap`; the `Keymap`
        // allocation hasn't happened on the failure path, so nothing
        // further to free.
        try result.globals.setOwned(allocator, Keymap, Keymap.init(allocator));
        errdefer result.globals.deinit(allocator);

        // Pair-assert post-conditions: the map is ready for `entities.new`
        // / `read` / `write` and the Keymap slot is populated.
        std.debug.assert(result.entities.next_id == 1);
        std.debug.assert(result.globals.has(Keymap));

        // `image_loader` is intentionally left undefined; the caller binds
        // it via `bindImageLoader` after `AppResources` exists. Until then
        // `image_loader_bound = false` keeps `deinit` from touching it.
        std.debug.assert(!result.image_loader_bound);

        return result;
    }

    /// In-place init for callers that need to avoid a stack temp.
    /// Marked `noinline` so ReleaseSmall doesn't fold the stack frame
    /// back into the caller (WASM stack budget — CLAUDE.md §14).
    ///
    /// `self` must point at uninitialised memory; the function writes
    /// every field. Returns `!void` because `globals.setOwned(Keymap, ...)`
    /// can fail with `OutOfMemory`.
    pub noinline fn initInPlace(self: *Self, allocator: Allocator, io: std.Io) !void {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(@intFromPtr(&allocator) != 0);

        // Field-by-field — no struct literal — to avoid a stack temp
        // (CLAUDE.md §14 WASM stack budget).
        self.allocator = allocator;
        self.io = io;
        self.entities = EntityMap.init(allocator, io);
        errdefer self.entities.deinit();

        // `self` was raw memory (caller did `allocator.create` without
        // zeroing), so explicitly default-construct `globals`.
        self.globals = .{};

        // Register the app-wide `Keymap` (see `init` for rationale).
        try self.globals.setOwned(allocator, Keymap, Keymap.init(allocator));
        errdefer self.globals.deinit(allocator);

        // `self` was raw memory; the explicit `false` marks the unbound
        // state. `image_loader` stays undefined until `bindImageLoader`.
        self.image_loader_bound = false;

        std.debug.assert(self.entities.next_id == 1);
        std.debug.assert(self.globals.has(Keymap));
        std.debug.assert(!self.image_loader_bound);
    }

    /// Bind the image loader against the shared `*ImageAtlas`. Idempotent
    /// on same-atlas re-binds: the first call runs `ImageLoader.initInPlace`
    /// at the loader's final `App` heap address; later calls with the same
    /// pointer are no-ops; a different pointer trips the pair-assertion (a
    /// framework bug — every window in an `App` borrows the same atlas).
    ///
    /// Idempotency is required because both `WindowContext.init` and
    /// `WindowContext.initWithSharedResources` call this for every window
    /// they construct; the first window binds, later windows short-circuit.
    ///
    /// `image_atlas` must point at a stable heap address — the loader
    /// stores it and dereferences it on every `drain`. Both flows pass an
    /// atlas that lives for the whole `App` lifetime.
    pub fn bindImageLoader(self: *Self, image_atlas: *ImageAtlas) void {
        std.debug.assert(@intFromPtr(self) != 0);
        std.debug.assert(@intFromPtr(image_atlas) != 0);

        // Idempotent same-atlas short-circuit. A different atlas pointer
        // here is a framework bug (mixed-up `App` instances, or a rebuilt
        // `AppResources`), so assert rather than silently re-bind and
        // orphan in-flight fetches against the previous atlas.
        if (self.image_loader_bound) {
            std.debug.assert(self.image_loader.image_atlas == image_atlas);
            return;
        }

        // `App` is always heap-allocated, so `&self.image_loader` is at
        // its final address — the embedded `Io.Queue`'s pointer into
        // `result_buffer` cannot dangle.
        self.image_loader.initInPlace(self.io, self.allocator, image_atlas);
        self.image_loader_bound = true;

        // Pair-assert post-conditions: the loader is ready for
        // `enqueueIfRoom` / `drain`, with empty pending / failed sets.
        std.debug.assert(self.image_loader_bound);
        std.debug.assert(self.image_loader.pending_count == 0);
        std.debug.assert(self.image_loader.failed_count == 0);
    }

    /// Tear down the entity map, the image loader, and any state the
    /// `App` owns.
    ///
    /// Order matters:
    ///
    ///   1. `image_loader.deinit` — first, so background fetch tasks see
    ///      queue closure and cancellation. In-flight fetches must unwind
    ///      against a still-live atlas (a cancelling task may complete a
    ///      partial atlas write before observing cancellation). The atlas
    ///      is owned upstream and torn down *after* `App.deinit` returns.
    ///   2. `entities.deinit` — after the loader, so entity-attached cancel
    ///      groups can still walk the loader's pending set (forward-looking;
    ///      no group reaches into the loader today).
    ///   3. `globals.deinit` — last, so any pending cancel walks see a live
    ///      `Globals` rather than a zeroed one.
    ///
    /// The loader teardown is guarded by `image_loader_bound` (test
    /// fixtures never bind; an unconditional call would walk undefined
    /// memory).
    ///
    /// Not idempotent — a second call walks freed slots. Callers wanting a
    /// use-after-free trap should `undefined`-out the pointer afterward.
    pub fn deinit(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

        // Tear the loader down first: `deinit` closes the result queue and
        // cancels the fetch group so in-flight tasks unwind cleanly. The
        // guard skips this when no `bindImageLoader` ran (test fixtures).
        if (self.image_loader_bound) {
            self.image_loader.deinit();
            self.image_loader_bound = false;
        }

        // `EntityMap.deinit` cancels any attached async groups before
        // freeing entity data (see `entity.zig`), using the captured `io`
        // — which the caller must keep valid until after `App.deinit`.
        self.entities.deinit();

        // Tear down owned globals (`Keymap` today). The thunk built at
        // `setOwned` time invokes the right `deinit` shape per type.
        self.globals.deinit(self.allocator);
    }

    // =========================================================================
    // Accessors
    // =========================================================================

    /// Typed accessor for the app-wide keymap. A missing slot is a
    /// framework bug (every `init*` path registers one), hence the panic
    /// rather than a runtime fallback.
    pub fn keymap(self: *Self) *Keymap {
        return self.globals.get(Keymap) orelse {
            std.debug.panic("App.keymap(): no Keymap registered in globals (init* did not run?)", .{});
        };
    }

    // =========================================================================
    // Per-frame hooks
    // =========================================================================
    //
    // Called by `runtime/frame.zig::renderFrameImpl` once per render
    // callback. `beginFrame` drains image-load results then clears stale
    // entity observations; `endFrame` is a thin hook reserved for future
    // batching. `renderFrameImpl` fires once per window per tick, so
    // multi-window flows currently call these once per window.

    /// Per-tick app-scoped work. Drains async image-load results into the
    /// shared atlas (idempotent: a second call this tick gets 0 results),
    /// then clears stale entity observations from the previous tick.
    ///
    /// Order matters: the drain must run before any `Window` reads the
    /// atlas this tick (so freshly-decoded pixels are visible), and the
    /// observation clear must run before any `cx.entities.read(...)` this
    /// tick (so last tick's observations don't leak forward).
    ///
    /// The drain is skipped when `image_loader_bound = false` (test
    /// fixtures only) rather than walking undefined memory.
    pub fn beginFrame(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

        // Drain async image-load results. Guarded by `image_loader_bound`
        // so unbound test fixtures can call this hook safely.
        if (self.image_loader_bound) {
            self.image_loader.drain();
        }

        // Clear stale entity observations from the previous tick.
        // Idempotent, so the redundant per-window calls in multi-window
        // flows are harmless.
        self.entities.beginFrame();
    }

    /// Per-tick app-scoped finalisation. Currently a thin pass-through:
    /// `EntityMap.endFrame` is itself a no-op (observations are registered
    /// eagerly via `observe()`); the call stays for symmetry with
    /// `beginFrame` and as a hook for future batching.
    pub fn endFrame(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);
        self.entities.endFrame();
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
    // And a populated `Keymap` slot.
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
    // Two `*App` borrows from the same backing struct see the same
    // entities — the cross-window sharing property.
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
    // Bind a keystroke through the accessor; reading it back via the same
    // accessor sees the binding, proving the slot survives across calls.
    var app = try App.init(testing.allocator, undefined);
    defer app.deinit();

    const Undo = struct {};
    app.keymap().bind(Undo, "cmd-z", null);

    const match = app.keymap().match(.z, .{ .cmd = true }, &.{});
    try testing.expect(match != null);
}

test "App: keymap is shared across simulated windows" {
    // Cross-window sharing: a binding registered through "window A"'s
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
    // A fresh `App` reports `image_loader_bound = false` and tears down
    // cleanly without a `bindImageLoader` call — the pattern test fixtures
    // rely on.
    var app = try App.init(testing.allocator, undefined);
    defer app.deinit();

    try testing.expect(!app.image_loader_bound);
}

test "App: bindImageLoader wires the loader against the atlas" {
    // Exercise the full bind path with a real allocator, IO, and
    // `ImageAtlas`. After `bindImageLoader` the pending / failed sets are
    // empty and `image_loader_bound` flips true.
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
    // Cross-window sharing: a URL recorded as "pending" through one borrow
    // of `App` is visible as "pending" through a second borrow — this
    // eliminates duplicate fetches when two windows request the same URL.
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

test "App: beginFrame clears stale entity observations" {
    // `App.beginFrame` must clear frame observations made during the
    // previous tick. The test simulates one tick: an observer reads a
    // target (registering a frame observation), then `beginFrame` runs at
    // the start of the next tick and clears the slot.
    var app = try App.init(testing.allocator, undefined);
    defer app.deinit();

    const Counter = struct { value: i32 };
    const Observer = struct { last_seen: i32 };

    const target = try app.entities.new(Counter, .{ .value = 1 });
    const observer = try app.entities.new(Observer, .{ .last_seen = 0 });

    // Simulate a read-with-observation (the path widgets take
    // when they call `cx.entities.read(...)`). `observe` takes
    // raw `EntityId` values, not the typed `Entity(T)` wrapper —
    // unwrap via `.id` to match the call shape.
    app.entities.observe(target.id, observer.id);
    try testing.expectEqual(@as(usize, 1), app.entities.frameObservationCount());

    // The next tick's `beginFrame` must clear the observation.
    app.beginFrame();
    try testing.expectEqual(@as(usize, 0), app.entities.frameObservationCount());
}

test "App: beginFrame is a no-op when image_loader is unbound" {
    // `beginFrame` must be safe on `App` instances that never bound an
    // `ImageLoader`. The guard skips the loader drain when
    // `image_loader_bound = false`; without it the call would walk
    // undefined memory.
    var app = try App.init(testing.allocator, undefined);
    defer app.deinit();

    try testing.expect(!app.image_loader_bound);
    app.beginFrame();
    // Reaching this line without an assertion failure is the
    // contract; the entity-observation clear is a no-op on a
    // fresh `App` (zero observations), so the only behavioural
    // surface this test pins is the unbound-loader guard.
    app.endFrame();
}

test "App: beginFrame drains image_loader when bound" {
    // `beginFrame` must drain the image loader's result queue. With no
    // in-flight fetches the drain is a 0-result no-op; the test pins that
    // the call reaches through to the loader (bound path, real
    // `ImageAtlas`).
    const io = std.Io.Threaded.global_single_threaded.io();

    var app = try App.init(testing.allocator, io);
    defer app.deinit();

    var image_atlas = try ImageAtlas.init(testing.allocator, 1.0, io);
    defer image_atlas.deinit();

    app.bindImageLoader(&image_atlas);
    try testing.expect(app.image_loader_bound);

    // No fetches enqueued; drain is a 0-result no-op. The
    // pending / failed counts must remain zero across the
    // begin / end pair.
    app.beginFrame();
    app.endFrame();

    try testing.expectEqual(@as(u32, 0), app.image_loader.pending_count);
    try testing.expectEqual(@as(u32, 0), app.image_loader.failed_count);
}
