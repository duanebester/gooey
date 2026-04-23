# Zig 0.16 `std.Io` Migration Roadmap

Zig 0.16 introduced `std.Io` (PR [#25592](https://github.com/ziglang/zig/pull/25592)) — the
`Allocator` pattern applied to IO and concurrency. Two implementations ship today:

| Implementation | Backing                        | Concurrency | Cancellation |
| -------------- | ------------------------------ | ----------- | ------------ |
| `Io.Threaded`  | Thread pool                    | Yes / No¹   | Yes / No¹    |
| `Io.Evented`   | io_uring (Linux) / GCD (macOS) | Yes         | Yes          |

¹ Depends on `-fsingle-threaded` flag. WASM was intended to use single-threaded
mode, but `Io.Threaded` does not currently compile for `wasm32-freestanding` in
Zig 0.16.0 — **WASM support is deferred pending an upstream fix**, and the
`wasm` / `wasm-*` build steps have been removed from `build.zig` for the 0.1.0
tag (WASM _source_ paths are left intact). See
[Verification blockers](#verification-blockers-from-timezig-migration-fallout)
and the [Remediation Plan](#remediation-plan--unblock-zig-build-test-wasm-deferred)
below.

This document tracks Gooey's incremental adoption of `std.Io` to replace
platform-specific dispatcher code, eliminate per-dispatch heap allocation,
and give developers a familiar one-parameter pattern for all async work.

---

## Current State

### Migration progress

| Phase | Scope                                           | Status                                          |
| ----- | ----------------------------------------------- | ----------------------------------------------- |
| 1     | Thread `Io` through the framework               | ✅ Complete                                     |
| 2     | Replace platform dispatchers with `Io.Queue(T)` | ✅ Complete                                     |
| 3     | Structured cancellation via `Io.Group`          | ✅ Complete                                     |
| 4     | Async image + network loading                   | ✅ Complete                                     |
| 5     | Retire `mutex.zig` / `time.zig` shims           | ✅ Complete (render-mutex shim retained)        |
| 6     | Evaluate `Io.Evented` for macOS                 | ⏳ Blocked upstream                             |
| —     | WASM build (`wasm32-freestanding`)              | 🚫 Deferred — upstream `Io.Threaded` regression |

### Verification blockers (from `time.zig` migration fallout)

- **`zig build test`** — ✅ **Unblocked.** Mechanical Zig 0.16 API churn
  (ArrayList `.{}` → `.empty`, `std.io.fixedBufferStream` →
  `std.Io.Writer.fixed`, `std.os.argv` → `init.minimal.args.vector`,
  `std.time.timestamp()` → `std.Io.Clock.real.now(io).toSeconds()`, and
  `Io.File.{Reader,Writer}` byte-sink methods relocated onto `.interface`)
  is fixed across `accessibility/debug.zig`, `charts/src/accessibility.zig`,
  `testing/mock_file_dialog.zig`, `widgets/text_input_state.zig`,
  `bench/json_writer.zig`, and `bench/compare.zig`. `Reporter.init` now
  takes `(module_name, io, argv)` with `argv` forwarded from
  `init.minimal.args.vector` — benchmark `main` callers updated across
  `{context,core,layout,text}/benchmarks.zig`. `zig build test` reports
  `Build Summary: 9/9 steps succeeded; 980/980 tests passed`, and every
  bench target (`bench`, `bench-context`, `bench-core`, `bench-text`,
  `bench-compare`) compiles and runs.
  The only remaining verification blocker is WASM, which is an upstream issue:

- **`zig build wasm`** — **deferred for Zig 0.16.0** (the `wasm` / `wasm-*`
  build steps have been removed from `build.zig`; the command itself no longer
  exists). `std.Io.Threaded` eagerly references `posix.system.getrandom`
  (Threaded.zig:2064) and `posix.IOV_MAX` (posix.zig:90), both of which
  resolve to `void` / absent on `wasm32-freestanding` (posix.zig:57
  `else => struct { ... }`). The Phase-1 invariant ("WASM uses
  `init_single_threaded`") is a compile-time failure regardless of whether
  you call the real init or the single-threaded one — just typechecking
  `Threaded` fails. An upstream bug, not something we caused. Rather than
  carry a local `Io` vtable shim, we're forgoing WASM support on 0.16.0 and
  waiting for upstream to land the gating fix. See
  [Remediation](#remediation-plan--unblock-zig-build-test-wasm-deferred)
  below for the tracking plan.

### Using `std.Io` today

- [x] **Framework-wide `Io`** — `gooey.App` constructs `Io.Threaded` in generated `main()`; threaded through `Cx` via `cx.io()` accessor.
- [x] **Image loader** — `std.Io.Dir.readFileAlloc` (sync path) + `std.http.Client` via `Io` for URL fetches (`src/image/loader.zig`).
- [x] **Code editor example** — `std.Io.Dir` for file/directory listing (`src/examples/code_editor.zig`).
- [x] **AI canvas example** — `std.Io.File.stdin()` streaming reader (`src/examples/ai_canvas.zig`).
- [x] **Bench / watcher** — `std.Io.Dir` for filesystem access (`src/bench/`, `src/runtime/watcher.zig`).
- [x] **Cross-thread result delivery** — `Io.Queue(T)` pattern via `cx.drainQueue(T, queue, buffer)`; replaces the removed dispatcher APIs.
- [x] **Structured cancellation** — `Io.Group` with app-level registry (`cx.registerCancelGroup`) and entity-attached groups (`cx.attachEntityCancelGroup`); auto-cancel on component unmount and window close.
- [x] **Async image URL loading** — Single `Io.Queue(ImageLoadResult)` on `Gooey`, drained each frame in `beginFrame`; single `Io.Group` for all image fetches; fail-cache prevents per-frame retry storms; bounded exponential backoff with jitter for transient errors inside the fetch task.

### Platform dispatchers — deleted

`src/platform/macos/dispatcher.zig` and `src/platform/linux/dispatcher.zig` were deleted
in Phase 2. The `cx.dispatchBackground()` / `dispatchOnMainThread()` / `dispatchAfter()`
APIs and the `dispatch/dispatch.h` C import are gone. Applications now express the same
patterns with `cx.io().async(fn, .{args})` + `Io.Queue(T)` for result delivery — no heap
`Task`/`Context` per dispatch, no C trampoline.

### Deliberately shimmed (not yet migrated)

- **`src/platform/mutex.zig`** — Reduced in Phase 5 to a **render-mutex-only shim**
  (option 3 from the Phase 5 design below). The CVDisplayLink callback on macOS has
  no `Io` instance because the thread is spawned by CoreVideo, not Gooey. Every other
  mutex in the framework (atlas locks, text shape/glyph caches) now uses
  `std.Io.Mutex` with `io` stored on the owning struct. A one-off mutex-guarded
  counter in `code_editor_state.generateUniqueId` was collapsed to an atomic
  `fetchAdd` — simpler than a mutex for a monotonic ID generator.

- **`src/platform/time.zig`** — **Deleted** in Phase 5. All animation / profiling /
  timing call sites now sample `std.Io.Timestamp.now(io, .awake)` directly. The
  monotonic `.awake` clock (`CLOCK_UPTIME_RAW` on macOS, `CLOCK_MONOTONIC` on Linux)
  guarantees non-negative elapsed deltas regardless of NTP or wall-clock edits —
  callers that previously used `i64` ms deltas keep the same semantics with
  stronger invariants. Render-thread diagnostic sites (CVDisplayLink FPS counter,
  Wayland frame callback counter, Metal custom-shader `updateTiming`) reach for
  `std.Io.Threaded.global_single_threaded.io()` at the callsite — same escape
  hatch used for the render mutex (option 3 below).

---

## Key `std.Io` Primitives

| Primitive                    | Purpose                                                    |
| ---------------------------- | ---------------------------------------------------------- |
| `io.async(fn, .{args})`      | Express that work _can_ be done independently (infallible) |
| `future.await(io)`           | Block until the result is ready                            |
| `future.cancel(io)`          | Request interruption — returns `error.Canceled`            |
| `io.concurrent(fn, .{args})` | Work that _must_ run concurrently (fallible, allocates)    |
| `Io.Group`                   | Manage many async tasks — wait/cancel all together         |
| `Io.Queue(T)`                | Bounded, thread-safe, many-producer many-consumer channel  |
| `Io.Clock` / `Io.Duration`   | Type-safe time units                                       |
| `Io.Mutex` / `Io.Condition`  | Sync primitives (require `Io` parameter)                   |

The same code works identically whether backed by threads, io_uring, GCD, or
single-threaded blocking IO. Swap only the `Io` construction in `main()`.

### Async/await pattern

```zig
var foo_future = io.async(foo, .{args});
defer if (foo_future.cancel(io)) |resource| resource.deinit() else |_| {};

var bar_future = io.async(bar, .{args});
defer if (bar_future.cancel(io)) |resource| resource.deinit() else |_| {};

const foo_result = try foo_future.await(io);
const bar_result = try bar_future.await(io);
```

### `Io.Queue(T)` pattern

```zig
const MAX_RESULTS = 32;
var result_buffer: [MAX_RESULTS]AsyncResult = undefined;
var result_queue: Io.Queue(AsyncResult) = .init(&result_buffer);

// Producer (background):
result_queue.putOneUncancelable(io, .{ .image_loaded = decoded });

// Consumer (render loop):
while (result_queue.getOne(io)) |result| switch (result) {
    .image_loaded => |img| uploadToAtlas(img),
    .data_fetched => |data| updateState(data),
} else |_| {}
```

Fixed-capacity. No heap allocation. Hard cap. Exactly what CLAUDE.md prescribes.

---

## Phase 1: Store `Io` on `Gooey` — Thread It Through the Framework

**Goal**: Make `std.Io` available everywhere in the framework without ad-hoc
`global_single_threaded` calls scattered across the codebase.

### Rationale

Every current use of `std.Io` in Gooey grabs a one-off instance:

```zig
const io = std.Io.Threaded.global_single_threaded.io();
```

This works, but it is the `std.Io` equivalent of reaching for `std.heap.page_allocator`
whenever you need an `Allocator`. The application's `main` function should construct the
`Io` instance, just as it constructs the allocator.

### Design

```zig
// In main():
var threaded: std.Io.Threaded = .init(gpa);
defer threaded.deinit();
const io = threaded.io();

try gooey.runCx(State, &state, render, .{
    .io = io,        // New field.
    // ...
});
```

`Gooey` stores the `Io` and exposes it through `Cx`:

```zig
// cx.zig
pub fn io(self: *Cx) std.Io {
    return self._gooey.io;
}
```

For WASM, `main` was intended to construct `Io.Threaded` with `-fsingle-threaded`
semantics (sequential execution, no fibers) — the same binary-level guarantee the
previous `void` dispatcher provided. **This path is currently broken on Zig 0.16.0**
due to an upstream regression; see [Remediation Step 3](#step-3--wasm-deferred-pending-upstream-fix)
for details.

### Tasks

- [x] **1.1** Add `io: std.Io` field to `Gooey` struct — Initialized from `CxConfig` or a default `global_single_threaded` fallback.
- [x] **1.2** Add `io: ?std.Io` to `CxConfig` — Optional — falls back to `Io.Threaded.global_single_threaded` when null.
- [x] **1.3** Expose `cx.io()` accessor on `Cx` — Mirrors `cx.allocator()` pattern.
- [x] **1.4** Replace all `global_single_threaded` call sites — `image/loader.zig`, `examples/code_editor.zig`, `bench/`, `runtime/watcher.zig`.
- [x] **1.5** Update `gooey.App(...)` to construct `Io.Threaded` in generated `main()` — WASM path uses `init_single_threaded`.
- [x] **1.6** Replace `global_single_threaded.io()` with `std.testing.io` in tests — Swapped every in-test-body call site to `std.testing.io` (backed by `Io.Threaded`, initialised per-test by `lib/compiler/test_runner.zig`, exported at `std/testing.zig` L34-35). Touched files: `src/animation/animation.zig`, `src/animation/spring.zig`, `src/animation/motion.zig` (its test-only `testIo()` helper was deleted; only caller was the tests themselves), `src/debug/debugger.zig`, and the two `bench/json_writer.zig` tests added during Step 1. Remaining `global_single_threaded.io()` call sites are all the documented Phase-5 escape hatches (render-thread diagnostics, widget input timestamps, example apps, benchmark `time` shims, `runCx` fallback, WASM init) — none are in test bodies.

### Invariants

- `cx.io()` must never be called outside the render function (same lifetime rule as `*Cx` itself).
- Background tasks that outlive a frame must capture `Io` by value, not through `*Cx`.
- WASM builds must use `-fsingle-threaded` `Io` — no fibers, no stack switching.
  (Currently non-compiling on Zig 0.16.0 due to an upstream `Io.Threaded` regression;
  WASM support is deferred — see Remediation Step 3.)

---

## Phase 2: Replace Dispatchers with `Io.Queue(T)`

**Goal**: Eliminate ~400 lines of platform-specific dispatcher code. Replace heap-allocating
GCD/eventfd trampolines with a single, zero-allocation `Io.Queue(T)` bridge.

### Rationale

The current developer API for cross-thread dispatch requires:

1. Defining a `Context` struct.
2. Heap-allocating both the `Task` and the `Context`.
3. Type-erasing the callback through a trampoline.
4. Dispatching back to the main thread with another heap-allocated round trip.

With `Io.Queue(T)`, background work produces typed results into a bounded channel,
and the render loop drains them — no heap allocation, no type erasure, no trampoline.

### Before / After

**Before** (current macOS dispatcher):

```zig
const Ctx = struct { app: *AppState, url: []const u8 };
try cx.dispatchBackground(Ctx, .{ .app = self, .url = url }, struct {
    fn handler(ctx: *Ctx) void {
        const result = fetchImage(ctx.url);
        // Dispatch BACK to main thread — another heap allocation.
        const MainCtx = struct { app: *AppState, result: ImageResult };
        ctx.app.gooey.dispatchOnMainThread(MainCtx, .{
            .app = ctx.app,
            .result = result,
        }, struct {
            fn apply(main_ctx: *MainCtx) void {
                main_ctx.app.loaded_image = main_ctx.result;
            }
        }.apply) catch {};
    }
}.handler);
```

**After** (with `Io.Queue`):

```zig
// App-level queue — fixed capacity, zero allocation.
var result_buffer: [32]AppResult = undefined;
var result_queue: Io.Queue(AppResult) = .init(&result_buffer);

// Kick off background work:
var future = cx.io().async(fetchImage, .{ url, &result_queue });
defer if (future.cancel(cx.io())) |_| {} else |_| {};

// In render loop — drain results:
while (result_queue.getOne(cx.io())) |result| switch (result) {
    .image_loaded => |img| self.loaded_image = img,
} else |_| {}
```

### Tasks

- [x] **2.1** Design `AppResult` union for common async result types — Documented as `union(enum)` pattern in `cx.zig` Io.Queue section comment. Apps define their own result types.
- [x] **2.2** Add `Io.Queue` support to `Gooey` / `Cx` — Added `cx.drainQueue(T, queue, buffer)` non-blocking helper for render loops.
- [x] **2.3** Remove `cx.dispatchBackground()` — Removed (zero call sites; skipped deprecation step).
- [x] **2.4** Remove `cx.dispatchOnMainThread()` — Removed (zero call sites; skipped deprecation step).
- [x] **2.5** Remove `cx.dispatchAfter()` — Removed (zero call sites; skipped deprecation step).
- [x] **2.6** Remove `src/platform/macos/dispatcher.zig` — Deleted. GCD trampoline pattern eliminated.
- [x] **2.7** Remove `src/platform/linux/dispatcher.zig` — Deleted. eventfd/TaskQueue pattern eliminated.
- [x] **2.8** Remove `dispatch/dispatch.h` C import — Eliminated with dispatcher file deletion.
- [x] **2.9** Update all examples that use `dispatch*` APIs — No examples used dispatch; nothing to update.

### What stays the same

- **CVDisplayLink** remains the render driver on macOS. `std.Io` does not replace vsync-driven rendering.
- **The main thread AppKit event loop** remains. `Io` handles background work, not UI event dispatch.
- **The DispatchTree** (UI hit-testing/event routing) is unrelated and stays as-is.

---

## Phase 3: Structured Cancellation for Component Lifecycles

**Goal**: Give every component a way to express "this async work belongs to me" and
automatically cancel it when the component unmounts.

### Rationale

Today there is no structured way to cancel in-flight background work when a widget is
removed from the tree or a window closes. If a background task holds a stale pointer
to freed state, the result is use-after-free.

`Io.Group` solves this: a lightweight handle that manages many async tasks and supports
waiting for or cancelling all of them together.

### Design sketch

Two cancellation mechanisms — a global registry for app-level groups, and
entity-attached groups for per-entity lifecycle:

```zig
const MyComponent = struct {
    io_group: std.Io.Group = .init,
    result_buffer: [32]AppResult = undefined,
    result_queue: std.Io.Queue(AppResult),

    pub fn startFetch(self: *MyComponent, io: std.Io, url: []const u8) void {
        self.io_group.async(io, fetchData, .{ url, &self.result_queue });
    }
};

// Register for auto-cancel on window close:
cx.registerCancelGroup(&my_component.io_group);

// Or attach to an entity for auto-cancel on entity removal:
const entity = try cx.createEntity(MyData, .{});
cx.attachEntityCancelGroup(entity.id, &my_data.io_group);
```

### Tasks

- [x] **3.1** Design component lifecycle hook for cancellation — `deinit` with `Io` parameter, or framework-managed groups.
- [x] **3.2** Add `Io.Group` to widget/entity system — Per-entity or per-component group.
- [x] **3.3** Auto-cancel on component unmount — When a component is removed from the tree, cancel its group.
- [x] **3.4** Auto-cancel on window close — When a window closes, cancel all groups owned by its components.
- [x] **3.5** Document cancellation patterns — Examples showing correct `defer` + `cancel` idioms.

---

## Phase 4: Async Image and Network Loading

**Goal**: Implement the long-standing `TODO: async URL loading` in `src/image/loader.zig`
and provide a general pattern for network-backed resources.

**Status**: Complete. `ui.ImagePrimitive{ .source = "https://..." }` works identically
on native and WASM with no user-side plumbing. The primitive is deliberately stateless
(see 4.4 resolution below); bounded retry with exponential backoff + jitter lives
inside the fetch task (4.5b); the failed-URL cache (4.5a) prevents per-frame retry
storms; session-level cancellation works via the cancel-group teardown added in Phase 3.

### Rationale

Zig 0.16's `std.http.Client` uses `std.Io` natively. DNS queries go out in parallel to
all configured nameservers, TCP connections race (happy eyeballs), and the first success
cancels the rest — all with no heap allocation.

### Architecture (as shipped)

```
User writes:  ui.ImagePrimitive{ .source = "https://example.com/photo.jpg" }

Frame N  (native):  renderImage → cache miss → ensureNativeUrlLoading
                     → dupe URL → addPendingImageLoad
                     → Gooey.image_load_group.async(loader.loadFromUrl)
                     → renderImagePlaceholder (gray box)

Background:         loader.loadFromUrl → std.http.Client.fetch
                     → loader.loadFromMemory → Gooey.image_load_queue.put

Frame N+1:          beginFrame → drainImageLoadQueue → atlas.cacheRgba
                     renderImage → cache hit → render with fit/effects/corners
```

On WASM the same `renderImage` entry point dispatches to `ensureWasmImageLoading` →
browser `fetch` + `createImageBitmap` → `atlas.cacheRgba`. A failed URL (any cause —
404, DNS, TLS, decode error) is recorded in `Gooey.failed_image_hashes` and surfaces
an error placeholder on subsequent frames instead of re-queuing a fetch.

### Tasks

- [x] **4.1** Implement `loadFromUrl` in `image/loader.zig` — Uses `std.http.Client` with `Io`; `fetchHttpBody` helper reads response into bounded buffer; pushes `ImageLoadResult` into `Io.Queue`.
- [x] **4.2** Design `ImageLoadResult` type — Tagged union (`.loaded` / `.failed`) delivered through `Io.Queue`. Background tasks produce results; `Gooey.drainImageLoadQueue()` consumes them each frame and caches into the atlas. Single global queue on `Gooey` with `[32]`-element fixed backing buffer.
- [x] **4.3** Add loading-state support to `Image` component — `renderImage()` detects URL sources on native, calls `ensureNativeUrlLoading()` to kick off `Group.async` fetch, and renders placeholder while load is in flight. Next frame after completion, atlas cache hit renders the image normally.
- [x] **4.4** Cancellation on `Image` unmount — **Resolved by design: `ImagePrimitive` stays stateless.** The render path runs every frame at display refresh rate; per-primitive cancellation would require either entity-backing every `Image` (losing URL-level dedupe — ten `<img>`s of the same URL would produce ten fetches) or per-URL refcount tracking in the render path. Neither is worth the complexity for the "user navigated away from an image" case: the in-flight fetch will land in the atlas, be LRU-evicted if unused, and cost at most one HTTP request. Session-level cancellation (window close / app exit) already works via `image_load_group.cancel()` in `Gooey.deinit()`. Users who need per-component lifecycles (cancel, retry UI, progress reporting, swappable URLs) build their own component using the Phase 3 pattern: own an `Io.Group` + `Io.Queue(ImageLoadResult)` on component state, call `image_mod.loader.loadFromUrl` directly, and register via `cx.attachEntityCancelGroup` for auto-cancel on entity removal.
- [x] **4.5a** Failed URL cache — `Gooey` tracks a fixed-capacity `[128]u64` set of permanently-failed URL hashes. `drainImageLoadQueue` adds the hash on `.failed`; `ensureNativeUrlLoading` short-circuits (checked before pending lookup, as the cheapest rejection). `renderImage` surfaces the error placeholder for known-failed URLs instead of an infinite loading state. Fixes a real bug: a 404 URL previously retried at frame rate (60 req/s). All failure modes (404/DNS/TLS/timeout/decode) treated identically at this layer; classification and retry happen inside the fetch task (4.5b).
- [x] **4.5b** Retry/backoff policy — **Implemented inside `loadFromUrl`, not in the render path.** The render path cannot initiate retries: it runs at display refresh rate, and retry logic would either spam requests at 60+ Hz or require stateful timers per URL. Instead, retry lives on the background fiber where `io.sleep` is natural and cancelable. `fetchHttpBody` classifies errors into `Transient` (DNS, connect, TLS handshake, HTTP 5xx, read/write I/O) or `Permanent` (HTTP 4xx, malformed URL, unsupported scheme, decode error, OOM, response-too-large). Permanent errors fail fast. Transient errors retry up to `MAX_FETCH_ATTEMPTS = 3` with exponential backoff (`BASE_BACKOFF_MS = 500` → 500 ms, 1 s, 2 s) and ±25 % jitter (PRNG seeded from URL hash for determinism in tests, independent streams across concurrent fetches). Worst-case wall-clock to `.failed` is ~3.5 s; during that window the `Image` shows a loading placeholder — no user-visible difference from a slow first attempt. Cancellation propagates through the backoff sleep as `std.Io.Cancelable`, so window close or cancel-group fire unwinds the task cleanly without finishing the retry schedule. Atlas-eviction behavior: when LRU evicts a previously-successful URL image, the next frame's cache miss re-runs `ensureNativeUrlLoading`; the URL is not in the failed set, so a fresh fetch kicks off automatically. This is the desired behavior — documented in `renderImage`'s cache-miss branch.
- [x] **4.6** WASM path — `renderImage()` auto-routes URL sources through `ensureWasmImageLoading` on WASM (which already dispatched to `loadFromUrlAsync` for URL-shaped sources). Users no longer write per-index dispatch callbacks, pending-request tables, or manual `cacheRgba` calls — `ui.ImagePrimitive{ .source = "https://..." }` works identically on native and WASM. `MAX_SOURCE_PATH_LEN` raised to match `image_mod.loader.MAX_URL_LENGTH` (8192) so length asserts agree across platforms. `src/examples/images_wasm.zig` rewritten as a minimal reference for the new pattern.

---

## Phase 5: Retire Platform Shims

**Goal**: Drop `src/platform/mutex.zig` and `src/platform/time.zig` in favor of `std.Io`
primitives once `Io` is threaded through the framework.

### `mutex.zig` → `std.Io.Mutex`

| Current                   | Replacement                                      |
| ------------------------- | ------------------------------------------------ |
| `os_unfair_lock` (macOS)  | `std.Io.Mutex`                                   |
| `pthread_mutex_t` (Linux) | `std.Io.Mutex`                                   |
| no-op (WASM)              | `std.Io.Mutex` (no-op under `-fsingle-threaded`) |

**Caveat — the render mutex**: The `render_mutex` is locked on the CVDisplayLink thread,
which does not naturally have an `Io` instance. Options:

1. Store a dedicated `Io` on the `Window` struct for the render thread.
2. Use `Io.Threaded.global_single_threaded` as an escape hatch for the render mutex only.
3. Keep the platform mutex exclusively for render synchronization and migrate everything else.

Option 3 is the most pragmatic starting point.

**Prior art — Zed's GPUI**: Zed (a production GPU-accelerated editor)
also stays on `CVDisplayLink` rather than migrating to `CADisplayLink`,
explicitly citing older-macOS support as the reason ([`crates/gpui_macos/src/display_link.rs`](https://github.com/zed-industries/zed/blob/main/crates/gpui_macos/src/display_link.rs)).
Two design points from GPUI worth recording here:

- **Main-thread bounce vs. render-on-vsync-thread.** Zed's CV callback
  does not render on the vsync thread — it posts a GCD
  `DISPATCH_SOURCE_TYPE_DATA_ADD` source targeting `DispatchQueue::main()`,
  so the render callback runs on the main thread. This eliminates
  render-state synchronization (no `render_mutex`) and automatically
  coalesces backed-up vsync ticks, at the cost of one thread-hop of
  frame latency and dependence on main-thread scheduling. Gooey makes
  the opposite tradeoff: render on the vsync thread for lower latency
  and pay the one mutex. Either is defensible; both ship in production.
- **`CVDisplayLinkRelease` race.** Zed observed sporadic segfaults from
  `CVDisplayLinkRelease` racing with the CV timer thread still touching
  the object, and their fix is to `mem::forget` the link rather than
  release it. Gooey calls `CVDisplayLinkRelease` in `DisplayLink.deinit`
  today (`stop()` returns synchronously first, so the race window should
  be closed). If we ever see matching crash reports on window close,
  skipping the release call is the known-good workaround — per-window
  lifetime, bounded cost. Documented inline in `src/platform/macos/display_link.zig`.

### `time.zig` → `std.Io.Clock` / `std.Io.Duration`

| Current                            | Replacement                        |
| ---------------------------------- | ---------------------------------- |
| `mach_absolute_time` (macOS)       | `std.Io.Timestamp.now(io, .awake)` |
| `clock_gettime(MONOTONIC)` (Linux) | `std.Io.Timestamp.now(io, .awake)` |
| JS `Date.now()` (WASM)             | `std.Io.Timestamp.now(io, .awake)` |

Type-safe `Duration` and `Timestamp` types eliminate raw `u64` nanosecond juggling.
All framework call sites sample the monotonic `.awake` clock — phase deltas are
asserted `>= 0` at each site, documenting (and verifying) the invariant that
NTP/wall-clock adjustments can no longer break timing math.

### Tasks

- [x] **5.1** Audit all `mutex.zig` usage — classify render-thread vs. non-render-thread — Determines which mutexes can migrate. Audit results:
  - **Non-render (migrated):** `ImageAtlas.mutex`, `SvgAtlas.mutex`, `TextSystem.shape_cache_mutex`, `TextSystem.glyph_cache_mutex`, `CodeEditorState.generateUniqueId` counter.
  - **Render-only (kept on shim):** `Window.render_mutex` on macOS — locked from the CVDisplayLink callback thread.
- [x] **5.2** Migrate non-render mutexes to `std.Io.Mutex` — Each atlas and `TextSystem` stores `io: std.Io` on the struct (a pair of pointers into the process-lifetime vtable — safe to copy across threads). All lock sites use `lockUncancelable(self.io)` / `unlock(self.io)` because none of the call sites propagate `std.Io.Cancelable` and the critical sections are short. The code-editor unique-ID counter became `std.atomic.Value(u64)` with `fetchAdd(1, .monotonic)`.
- [x] **5.3** Decide render mutex strategy — **Option 3** (keep platform mutex for render sync only). Plumbing `io` through the CVDisplayLink callback would require storing a dedicated `Io` on `Window` purely to satisfy the `std.Io.Mutex` API; the render mutex is already the simplest part of the shim (single user, single purpose) and adds negligible complexity. `mutex.zig` now exists solely for `Window.render_mutex` on macOS.
- [x] **5.4** Migrate `time.zig` to `Io.Clock` / `Io.Duration` — Every framework call site now samples `std.Io.Timestamp.now(io, .awake)`. Breakdown by layer:
  - **Animation leaves** (`animation/animation.zig`, `motion.zig`, `spring.zig`): `AnimationState.init`, `SpringState.init`, `calculateProgress`, `tickSpring`, `tickMotion`, `tickSpringMotion`, and `AnimationHandle.restart` all take `io: std.Io`. `AnimationState.start_time` is now `std.Io.Timestamp` (with `.zero` as the sentinel for `initSettled`); `SpringState.last_time` replaces `last_time_ms: i64`.
  - **Widget store** (`context/widget_store.zig`): stores `io: std.Io` on the struct, threads it into every animation / spring / motion tick.
  - **Debugger** (`debug/debugger.zig`): all `begin*`/`end*` methods take `io` as an argument. Kept as a pure data struct (embedded `.{}` in `Gooey`); `Gooey` passes `self.io` at each call site in `beginFrame`/`endFrame`/`finalizeFrame` and `runtime/frame.zig`.
  - **Layout profiling** (`layout/engine.zig`): `endFrameTimed(io)` samples 7 monotonic timestamps per call. A local `durationNs` helper asserts `>= 0` per phase.
  - **Window context** (`runtime/window_context.zig`): debug-only frame-budget timing reuses `self.gooey.io`.
  - **Text shaping** (`text/text_system.zig`): shape-miss timing reuses `self.io` (already stored on `TextSystem`). WASM still skips the clock read — JS FFI on the shaping hot path isn't free.
  - **Widgets** (`widgets/text_input_state.zig`, `text_area_state.zig`): `getTimestamp()` helpers (called from every keystroke path: `handleKey`, `insertText`, `deleteSelectionWithHistory`, cursor blink) reach for `std.Io.Threaded.global_single_threaded.io()`. Threading `io` through the entire widget input API purely for an edit-history timestamp would balloon this patch for no real gain — `std.Io` is a pair of pointers into the process-lifetime vtable, so the lookup is effectively free.
  - **Examples** (`examples/pomodoro.zig`, `spaceship.zig`): `getTimestamp()` / `tick()` helpers use the same single-threaded global pattern.
  - **Render-thread diagnostic sites** (`platform/linux/window.zig` FPS + GPU submit timing, `platform/macos/window.zig` CVDisplayLink FPS counter, `platform/macos/metal/custom_shader.zig` `updateTiming`): reach for the single-threaded global at the callsite. These threads are spawned by Wayland / CoreVideo / Metal and carry no `*Cx`/`Gooey` — same escape hatch used for the render mutex (option 3 above).
  - **Benchmarks** (`context/`, `core/`, `layout/`, `text/benchmarks.zig`): each file defines a small local `time` shim with `Instant.now()` / `.since()` wrapping `std.Io.Clock.awake`. Keeps dozens of sample sites reading as two-line capture-then-diff without threading `io` through the closure-heavy benchmark harness signatures.
- [x] **5.5** Reduce `src/platform/mutex.zig` to render-mutex-only shim — Updated module-level docs to explain why the shim remains. The `NoOpMutex` branch is still selected on WASM (single-threaded, no render thread).
- [x] **5.6** Delete `src/platform/time.zig` — Gone. `platform/mod.zig` no longer exports `pub const time`; its docstring now points readers at `std.Io.Timestamp.now(io, .awake)` and this document.

---

## Phase 6: Evaluate `Io.Evented` for macOS

**Goal**: When `Io.Evented` stabilizes, evaluate the GCD-backed implementation as
a drop-in replacement for `Io.Threaded` on macOS.

### Why this matters

`Io.Evented` on macOS uses Grand Central Dispatch under the hood — the same system
Gooey's current dispatcher wraps manually. Switching to `Io.Evented` would give Gooey
native dispatch queue integration through the standard `Io` interface, with userspace
stack switching (fibers/green threads) instead of OS threads.

### Current blockers

- `Io.Evented` is **experimental** — Andrew noted a performance regression when used for the Zig compiler.
- Some vtable functions are unimplemented.
- Missing builtin to determine max stack size for a function — important for WASM's 1MB stack budget.
- The GCD backend is proof-of-concept quality.

### Tasks

- [ ] **6.1** Track `Io.Evented` stabilization upstream — Watch Zig issues and devlog.
- [ ] **6.2** Benchmark `Io.Evented` vs `Io.Threaded` for Gooey workloads — Frame latency, atlas upload, async image load.
- [ ] **6.3** Test fiber stack usage on WASM — Ensure no stack overflow with Gooey's large structs.
- [ ] **6.4** Provide `Io` backend selection in `CxConfig` — Let developers choose threaded vs. evented.

---

## Remediation Plan — unblock `zig build test`, WASM deferred

The main migration is done; these steps get the native verification toolchain
back to green so future changes can be regression-tested. WASM is deferred on
Zig 0.16.0 pending an upstream fix — we're tracking but not working around it.
Steps are ordered by dependency — (1) must land before (2) can be verified.

### Step 1 — Fix `zig build test` (Zig 0.16 API churn) ✅ Complete

Landed. Pre-existing 0.16 API churn (not `std.Io`-related). All changes were
mechanical; the sweep below is left in place as a record of which call sites
moved so `git blame` readers have the rationale near the code.

**`std.io.fixedBufferStream(buf).writer()` → `std.Io.Writer.fixed(buf)`**
(and `fbs.getWritten()` → `writer.buffered()`). The framework already uses
the new API correctly in `src/text/text_debug.zig` — we're just finishing
the sweep.

- `src/accessibility/debug.zig:358,376` — 2 sites (`formatElement`, `formatState`)
- `charts/src/accessibility.zig:134,219,247,266,540` — 5 sites

**`ArrayListUnmanaged(T) = .{}` → `.empty`** — 0.16's unmanaged ArrayList
dropped the default struct-literal init; the replacement is the `.empty`
constant. The framework already uses `.empty` elsewhere (`text_input_state.initWithId`,
`text_area_state.setText`).

- `src/testing/mock_file_dialog.zig:91` — `.stored_open_paths = .{}`
- `src/widgets/text_input_state.zig:172,173` — `.buffer = .{}`, `.preedit_buffer = .{}`

**`std.os.argv` / `std.time.timestamp()` / `std.time.epoch.EpochSeconds`** —
all three were removed from 0.16. Replacements:

- `std.os.argv` → `init.args.vector` (every bench `main` is already
  `fn main(init: std.process.Init)`, so `args` is already in hand).
- `std.time.timestamp()` → `std.Io.Clock.real.now(io).toSeconds()`
  using the `io` from `init.io` (already plumbed through `Reporter.init`).
- `std.time.epoch.EpochSeconds` — **still exists** at `std/time/epoch.zig`;
  only the _source_ of the seconds changes, the Y/M/D decomposition is unchanged.

Call-site changes (as landed):

- `src/bench/json_writer.zig` — `getCurrentDate` now takes `io: std.Io` and
  calls `std.Io.Clock.real.now(io).toSeconds()`; `serializePayload` reads
  the same clock through `self.io`. `parseArgs` takes an explicit
  `argv: []const [*:0]const u8` slice instead of reaching for
  `std.os.argv`. `std.time.epoch.EpochSeconds` is untouched — only the
  _source_ of the seconds changed.
- `src/bench/compare.zig` — `parseArgs` takes `argv` explicitly; `main`
  forwards `init.minimal.args.vector`. (Not in the original fallout list,
  but uses the same removed API and fails as soon as `json_writer.zig`
  compiles.)
- `Reporter.init(name, io)` → `Reporter.init(name, io, argv)` at callers
  (`src/{context,core,layout,text}/benchmarks.zig`). We opted for an
  explicit `argv` parameter over passing `std.process.Init` wholesale —
  it keeps the Reporter API decoupled from the process-entry-point type
  and lets unit tests construct an empty-argv reporter with `&.{}`.
  Benchmark `main` functions forward `init.minimal.args.vector` at the
  call site.

**Bonus fallout (not in the original list, surfaced by bench compilation):**

- `Io.File.Writer` / `Io.File.Reader` — byte-sink methods (`writeAll`,
  `readAlloc`, etc.) relocated onto the embedded `.interface`
  (`std.Io.Writer` / `std.Io.Reader`). Fixed in `src/bench/json_writer.zig`
  (`writer.interface.writeAll`) and `src/bench/compare.zig`
  (`reader.interface.readAlloc`). `File.Writer.flush` stays on the outer
  type — it forwards to the interface flush and surfaces any latched
  error.
- `TextSystem.initInPlace(gpa, scale)` → `initInPlace(gpa, scale, io)` —
  required by the Phase-5 migration of the embedded shape/glyph cache
  mutexes to `std.Io.Mutex`. Fixed in `src/text/benchmarks.zig` by
  forwarding `reporter.io`.

### Step 2 — Task 1.6 (`std.testing.io`) ✅ Complete

Landed alongside Step 1. Every `std.Io.Threaded.global_single_threaded.io()`
inside a `test "..." { ... }` body is now `std.testing.io`; the one
test-only `testIo()` helper (`src/animation/motion.zig`) was deleted. The
bench-file `time.benchIo()` wrappers live on — they're called from
benchmark runtime code, not tests, and the Phase-5 audit deliberately
flagged them as keepers. Phase 1 flipped to ✅ Complete.

### Step 3 — WASM deferred pending upstream fix

**Decision: forgo `wasm32-freestanding` builds on Zig 0.16.0.** `zig build wasm`
fails because `std.Io.Threaded`'s comptime body eagerly references
`posix.system.getrandom` (Threaded.zig:2064) and `posix.IOV_MAX` (posix.zig:90),
both of which resolve to `void` / absent on `wasm32-freestanding` (posix.zig:57
`else => struct { ... }`). Analysis happens just from taking the type — even
`global_single_threaded` (a comptime pointer to a `Threaded` instance) forces it.

**This is an upstream bug, not a Gooey bug.** The Phase-1 invariant says "WASM
uses `init_single_threaded`", which is _supposed_ to skip the thread-pool / RNG
paths. That gating was silently broken by post-merge churn to `std.Io.Threaded`.

**Rationale for deferring rather than working around**:

- A local `Io` vtable shim would need to stub ~40 function pointers, most of
  which would be `unreachable` landmines that produce confusing panics if the
  WASM path ever reaches them.
- The shim would be dead code the day upstream fixes this — a maintenance tax
  with a short half-life.
- CLAUDE.md rule #12 ("zero dependencies, spirit of") favors not carrying a
  parallel IO implementation.
- WASM is one of three targets Gooey supports; native builds (macOS, Linux)
  cover the primary development loop. Losing WASM temporarily is annoying but
  not blocking.

**Tracking**:

- Watch for the fix to land in a Zig nightly / 0.16.x patch release. The
  likely shape of the fix is gating the `use_dev_urandom` / `IOV_MAX`
  references behind `native_os == .linux` or the `@TypeOf(...) != void` idiom
  already used elsewhere in `Threaded.zig` — minimal repro is
  `@TypeOf(std.Io.Threaded.init_single_threaded)` targeted at
  `wasm32-freestanding`.
- Do **not** remove WASM _source_ paths (`src/platform/web/`, wasm examples,
  `WebApp` in `app.zig`, `images_wasm.zig`, etc.) — they stay intact and will
  resume compiling once upstream is fixed.
- The `build.zig` `wasm` / `wasm-*` steps **have been removed** (along with
  the `addWasmExample` helper) so `zig build` presents a clean step list on
  0.16.0. Restore them from git history prior to the 0.1.0 tag when upstream
  lands the fix. The in-file comment where the steps used to live points
  future readers at this document.

**Exit criteria** — when upstream ships the fix:

1. Update the toolchain pin to include the fix.
2. Restore the WASM build steps and `addWasmExample` helper in `build.zig`
   from git history prior to the 0.1.0 tag.
3. Run `zig build wasm` — expect it to succeed.
4. Run the WASM examples in a browser, verify animation timing is correct
   (that's the only `Io`-touching path on WASM — `Io.Timestamp.now(io, .awake)`
   from animation / spring / motion / debugger).
5. Flip the deferred row in the progress table to ✅ Complete.
6. Remove the warning footnote on the implementation table at the top of
   this document.
7. Remove the in-file WASM deferral comments in `build.zig` (one in
   `pub fn build`, one where `addWasmExample` used to live).
8. Remove this "Step 3" section.

### Sequencing

Steps (1) and (2) landed together — `zig build test` is green and Task 1.6
is complete. Step (3) remains a waiting game; re-check on each toolchain
bump for the upstream `Io.Threaded` gating fix.

---

## Risks

| Risk                                                    | Severity | Mitigation                                                                                                                                              |
| ------------------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WASM stack budget (1MB)                                 | High     | Use `Io.Threaded` with `-fsingle-threaded` for WASM — no fibers, sequential execution                                                                   |
| `Io.Threaded` broken on `wasm32-freestanding` in 0.16.0 | High     | **WASM support deferred on 0.16.0; `wasm` build steps removed.** Native paths (macOS, Linux) unaffected; wait for upstream fix — see Remediation Step 3 |
| `Io.Evented` instability                                | Medium   | Phase 6 is deferred until upstream stabilizes; `Io.Threaded` is production-ready now                                                                    |
| Sweeping refactor scope                                 | Medium   | Phased approach — each phase is independently valuable and shippable                                                                                    |
| CVDisplayLink thread lacks `Io`                         | Medium   | Keep platform mutex for render sync (Phase 5, option 3)                                                                                                 |
| `Io.Mutex` API ergonomics                               | Low      | Requiring `io` at every lock site is verbose but consistent with the `Allocator` pattern                                                                |
| Upstream API churn                                      | Low      | `std.Io` is merged and shipping; the core interface is stable                                                                                           |

---

## Non-Goals

- **Replacing CVDisplayLink** — vsync-driven rendering is orthogonal to `std.Io`. The
  display link thread stays as-is.
- **Replacing the AppKit event loop** — `NSApplication.nextEventMatchingMask:` is the
  correct way to receive macOS UI events. `Io` handles background work, not UI events.
- **Replacing the DispatchTree** — UI event routing (hit testing, capture/bubble) is
  unrelated to IO concurrency.
- **Async rendering** — The render function runs synchronously on the main thread (or
  CVDisplayLink thread during normal operation). This is correct for immediate-mode UI.

---

## References

- [std.Io PR #25592](https://github.com/ziglang/zig/pull/25592) — Andrew Kelley's design and implementation
- [std.io.Writer rewrite PR #24329](https://github.com/ziglang/zig/pull/24329) — Concrete vtable-based IO types
- [Zig devlog](https://ziglang.org/devlog/) — Ongoing `Io.Evented` development notes
- [CLAUDE.md](../CLAUDE.md) — Gooey engineering principles (static allocation, hard limits, assertion density)
