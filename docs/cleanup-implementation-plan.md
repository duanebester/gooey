# Gooey Cleanup Implementation Plan

> Live tracking doc that stitches the
> [architectural cleanup plan](./architectural-cleanup-plan.md) together with
> the pending audits from
> [Zig 0.16 changes §28](./zig-0.16-changes.md#28-gooey-specific-takeaways)
> and the in-flight [`std.Io` migration](./zig-0.16-io-migration.md).
>
> This doc is the **execution playbook**. The other two are the **rationale**
> (why) and the **reference** (what changed upstream). When a PR lands, tick
> the box here and mark the corresponding bullets in the source docs as
> folded.

## TL;DR

- Cleanup work and remaining 0.16 audits are co-located in the same files,
  so we pair them PR-by-PR rather than running two parallel campaigns.
- Module-by-module ordering. Each PR has a **disjoint write scope** so they
  can be drafted in parallel by different agents/contributors without merge
  conflicts.
- One **PR 0** mechanical sweep up front (`@Type` builtins, local-address
  returns) so the architectural PRs aren't littered with cross-cutting
  churn.
- A handful of 0.16 items stay **out of scope** of the cleanup: WASM
  unblock (upstream-blocked), `Io.Evented` macOS backend (experimental),
  LLVM 21 perf re-baseline (measurement, not a refactor).

---

## Table of contents

1. [Principles](#1-principles)
2. [Tracker — at-a-glance](#2-tracker--at-a-glance)
3. [PR 0 — Mechanical 0.16 sweep](#pr-0--mechanical-016-sweep)
4. [PR 1 — `image/` + `ImageLoader` extraction](#pr-1--image--imageloader-extraction)
5. [PR 2 — SVG consolidation](#pr-2--svg-consolidation)
6. [PR 3 — `context/` subsystem extractions](#pr-3--context-subsystem-extractions)
7. [PR 4 — Break the backward edges](#pr-4--break-the-backward-edges)
8. [PR 5 — `cx.zig` sub-namespacing](#pr-5--cxzig-sub-namespacing)
9. [PR 6 — `DrawPhase` + `Global(G)`](#pr-6--drawphase--globalg)
10. [PR 7 — App/Window split + `Frame` double buffer](#pr-7--appwindow-split--frame-double-buffer)
11. [PR 8 — Unified `element_states`](#pr-8--unified-element_states)
12. [PR 9 — `root.zig` slim + ownership flag drop + 7d-examples entry-point sweep](#pr-9--rootzig-slim--ownership-flag-drop--7d-examples-entry-point-sweep)
13. [PR 10 — Layout engine split + fuzz targets](#pr-10--layout-engine-split--fuzz-targets)
14. [PR 11 — API check + three-phase Element lifecycle](#pr-11--api-check--three-phase-element-lifecycle)
15. [Out of scope (tracked separately)](#out-of-scope-tracked-separately)
16. [Cross-reference index](#cross-reference-index)

---

## 1. Principles

These are non-negotiable per
[`CLAUDE.md`](../CLAUDE.md). Every PR below must respect them; calling
them out here so they don't get re-litigated in review:

- **Static memory allocation.** New extracted subsystems
  (`ImageLoader`, `HoverState`, `SubscriberSet`, `AssetCache`,
  `element_states`) are fixed-capacity slot maps with hard caps declared
  at the top of the file as `MAX_*` constants. No growing
  `ArrayListUnmanaged` on a hot path.
- **70-line function limit.** Any extraction that produces a function
  longer than 70 lines must split it. The split must keep control flow
  in the parent and push pure computation to leaves
  ([CLAUDE.md §5](../CLAUDE.md)).
- **In-place initialization.** All new `init` paths use out-pointer
  `initInPlace(self: *Self, ...)` style with `noinline` where the
  containing struct is large
  ([CLAUDE.md §13–14](../CLAUDE.md)). This is viral — if a field is
  initialized in place, the parent must be too.
- **Two assertions per function minimum.** Pair them on data-validity
  boundaries (write to GPU buffer / read from GPU buffer)
  ([CLAUDE.md §3](../CLAUDE.md)).
- **No public-API regressions without an entry in `api_check.zig`.**
  Once PR 11 lands, every Tier-1 name change requires an explicit edit
  to the pin list.
- **Disjoint write scope per PR.** When delegating across agents, one
  PR == one write scope. PR boundaries below were chosen with this
  constraint.

---

## 2. Tracker — at-a-glance

| PR  | Scope                    | Cleanup items                                      | 0.16 audits                                                | Risk        | Status                                                                                                                                             |
| --- | ------------------------ | -------------------------------------------------- | ---------------------------------------------------------- | ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0   | Mechanical sweep         | —                                                  | `@Type` split, local-address returns, `ArrayList` `.empty` | Low         | ☑ (no-op, audit only)                                                                                                                              |
| 1   | `image/` + `Gooey`       | #1 (ImageLoader), #9 (Asset(T) seed)               | `@Type` in atlases, redundant arena mutex                  | Low         | ☑                                                                                                                                                  |
| 2   | `scene/svg.zig` + `svg/` | #12                                                | `@Type` on path-parsing, vector indexing on rasterizer     | Low         | ☑                                                                                                                                                  |
| 3   | `context/` extractions   | #1 finish, #8 (SubscriberSet)                      | `@Type` on a11y tree builders                              | Low         | ☑                                                                                                                                                  |
| 4   | Backward edges           | #2 (Focusable vtable), #3 (list layout to widgets) | `@Type` on vtable codegen                                  | Medium      | ☑                                                                                                                                                  |
| 5   | `cx.zig` namespaces      | #4                                                 | —                                                          | Low         | ☑                                                                                                                                                  |
| 6   | `DrawPhase` + globals    | #7, #10                                            | `@Type` on type-keyed globals                              | Low         | ☑                                                                                                                                                  |
| 7   | App/Window/Frame         | #5, #6, #14 (partial)                              | `init.minimal`, non-global argv/env                        | Medium-high | ☑ (7a + 7b.1a/1b/2/3/4/5/6 + 7c.1/2/3a/3b/3c/3d + 7d-framework landed; 7d-examples absorbed into 7d-framework — see notes; 7e resolved — see PR 9) |
| 8   | element_states           | #11                                                | Heaviest `@Type` work                                      | Medium      | ☑ (8.1 + 8.2 + 8.3 + 8.4-prep + 8.4a + 8.4b + 8.4c landed)                                                                                         |
| 9   | `root.zig` slim + flags  | #13, #14 (finish)                                  | `pub fn main(init)` example sweep (from 7d-examples)       | Medium      | ☑ (landed)                                                                                                                                         |
| 10  | Layout engine            | #15                                                | Vector indexing, `std.testing.Smith` fuzz targets          | Medium      | ☑ (landed)                                                                                                                                         |
| 11  | API check + Element      | #16, #17                                           | `@Type` on Element trait if any                            | Large       | ☐                                                                                                                                                  |

Cleanup item numbers reference the synthesis table in
[`architectural-cleanup-plan.md` §Synthesis](./architectural-cleanup-plan.md#synthesis-the-cleanup-plan).

---

## PR 0 — Mechanical 0.16 sweep

**Status: ☑ already folded in by prior 0.16 port commits.** No code
change is required — landing as a doc-only update so the audit trail
stays honest. The integration branch begins at PR 1.

**Goal (original):** get the cross-cutting 0.16 audits out of the way
once, so the architectural PRs that follow stay focused on architecture.

**Audit performed against `main` @ `4d350e1` (v0.1.2):**

- ✅ **`@Type(.{ .Struct = … })` builtins.**
  `grep -rn "@Type(" src/` → **0 matches**. The split-builtin migration
  was completed in earlier 0.16 port work.
- ✅ **`@typeInfo(T).Struct` lower-case tags.**
  All 18 `@typeInfo` call sites already use `.@"struct"`,
  `.@"enum"`, `.@"fn"`, `.@"union"` form. Findings:
  `src/ui/builder.zig` (×4), `src/context/gooey.zig` (×2),
  `src/cx.zig` (×4), `src/animation/animation.zig`,
  `src/core/geometry.zig`, `src/ai/theme_color.zig`,
  `src/ai/schema.zig`, `src/examples/lucide_demo.zig`,
  `src/validation.zig`. Re-audit at the top of any PR that touches
  these files.
- ✅ **`ArrayList(T) = .{}` post-init.**
  `grep -rn "ArrayList.*\.{}" src/` → **0 matches**. No remaining
  pre-`.empty` initialisations.
- ✅ **`@Vector` runtime indexing.**
  `grep -rn "@Vector" src/` → **0 matches**. No `@Vector` use in
  the codebase, so the runtime-indexing restriction is moot.
- ✅ **Local-address returns.**
  Last `zig build` against 0.16.0 surfaced no "address of local
  returned" diagnostics. Will be re-checked at the head of every
  subsequent PR.
- ✅ **Redundant arena mutexes.**
  Only `src/layout/arena.zig` and `src/text/benchmarks.zig` use
  `std.heap.ArenaAllocator`; neither wraps it in a mutex.

**Test baseline (correction):**

- `zig build test --summary all` against 0.16.0 reports
  `Build Summary: 9/9 steps succeeded; 980/980 tests passed` on `main`
  @ `4d350e1` (v0.1.2). An earlier note in this doc claimed two
  failing test binaries; that was a misread of the build graph —
  `run test w` lines belong to example test runners that emit
  diagnostic chatter (the chart `Series is 304 KB` size print, the
  `Deferred command queue full` warning) but exit `0` and contribute
  to the green total. There is no pre-existing failure baseline to
  track against; subsequent PRs must keep `Build Summary` green at
  the totals they push to.

**Definition of done:**

- ✅ Tracker row ticked.
- ✅ Bullets in
  [`zig-0.16-changes.md` §28](./zig-0.16-changes.md#28-gooey-specific-takeaways)
  for `@Type` removal, vector indexing, and arena lock-free marked
  ✅ folded.

---

## PR 1 — `image/` + `ImageLoader` extraction

**Goal:** lift async image loading out of `Gooey` into a self-contained
subsystem; lay the foundation for a generic `Asset(T)` cache.

**Write scope:**

- `src/context/gooey.zig` (delete loading bits)
- `src/image/loader.zig` (new)
- `src/image/asset_cache.zig` (new, generic skeleton)
- `src/image/mod.zig` (re-exports)

**Tasks:**

- [x] Move these fields out of `Gooey` and into a new `ImageLoader`: - `image_load_results` (cap `MAX_IMAGE_LOAD_RESULTS = 32`) - `pending_image_loads` (cap `MAX_PENDING_IMAGE_LOADS = 64`) - `failed_image_loads` (cap `MAX_FAILED_IMAGE_LOADS = 128`) - The `Io.Group` + `Io.Queue(LoadResult)` pair that drives them.
- [x] `ImageLoader` exposes `init(io, gpa)`, `deinit`, `enqueue(url)`,
      `drain(callback)`. No `*Gooey` reference; takes `io` and the atlas
      pointer it writes into.
- [x] Sketch `image/asset_cache.zig` with a generic
      `AssetCache(comptime T: type, comptime cap: u32)` skeleton — even
      if only `Image` uses it for now. SVG migrates in PR 2.
- [x] 0.16: confirm `std.http.Client` use matches the
      [§7 networking pattern](./zig-0.16-changes.md#7-networking)
      (`http_client.request(.HEAD, …)` shape, `receiveHead(&buf)`).
- [x] 0.16: audit `image/atlas.zig` for `@Type` usages (PR 0 may have
      caught these; confirm).
- [x] Update all `Gooey` callers to go through `gooey.image_loader`
      (or `resources.image_loader` if PR 7 has landed first).

**Notes:**

- `ImageLoader` is the prototype for the pattern used by every
  subsequent PR: a single struct, a single fixed-capacity queue, a
  single `Io.Group`, no back-pointer to the parent. Get this shape
  right; we'll reuse it 5+ times.
- Keep the public callsite `cx.loadImage(url, callback)` working —
  internal wiring changes only.

**Definition of done:**

- `Gooey` no longer has `image_load_results` / `pending_image_loads` /
  `failed_image_loads` / image-related `Io.Group`.
- `examples/image_grid` and the showcase example still load images.
- ~150 lines net out of `context/gooey.zig`.

**Landed:**

- ✅ `ImageLoader` struct in `src/image/loader.zig` owns
  `result_buffer` / `result_queue` / `fetch_group` / `pending_hashes` /
  `failed_hashes`. Public API: `initInPlace(io, gpa, atlas)`,
  `fixupQueue`, `deinit`, `isPending`, `isFailed`, `hasRoom`,
  `enqueueIfRoom(url, key) -> bool`, `drain`. No `*Gooey` reference.
- ✅ `src/image/asset_cache.zig` skeleton with `verifyAssetType` trait
  check + `AssetCache(T, options)` shape. Bodies stubbed with
  `@compileError("body lands in PR 2")` so SVG migration in PR 2
  cannot drift the shape silently.
- ✅ `src/image/mod.zig` re-exports `ImageLoader`, `ImageLoadResult`,
  `MAX_*` caps, and `AssetCache` so call sites can write
  `image_mod.ImageLoader` instead of reaching into `loader.*`.
- ✅ `Gooey` shrinks by 91 lines net (target was ~150 — the init/deinit
  shells stay because they call `image_loader.initInPlace` /
  `.deinit`). Forwarder methods `isImageLoadPending`,
  `isImageLoadFailed`, `fixupImageLoadQueue` retained on `Gooey` to
  preserve the call surface used by `runtime/render.zig` until PR 7
  reroutes call sites to `gooey.image_loader.*` directly.
- ✅ `runtime/render.zig` `ensureNativeUrlLoading` collapses to a single
  `gooey_ctx.image_loader.enqueueIfRoom(source, key)` call (down from
  ~30 lines of bookkeeping).
- ✅ 0.16 audits: `src/image/atlas.zig` and `src/image/loader.zig` clean
  of `@Type` usage; `std.http.Client` use already matches §7
  (`request(.GET, uri, ...)` → `sendBodiless` → `receiveHead(&buf)`).
- ✅ `zig build` green; `zig build test --summary all` reports
  `Build Summary: 9/9 steps succeeded; 983/983 tests passed`
  (vs. 980/980 on `main` — the +3 are the new ImageLoader tests).

---

## PR 2 — SVG consolidation

**Goal:** eliminate the parallel `scene/svg.zig` and `svg/` modules.
There should be exactly one SVG module.

**Write scope:**

- `src/scene/svg.zig` (delete after content move)
- `src/svg/path.zig` (new — receives the path parser)
- `src/svg/mod.zig` (updated)
- `src/scene/mod.zig` (drop re-export)
- `src/core/vec2.zig` (extend — `Vec2.init` + `IndexSlice.closed`)
- `src/root.zig` (re-point top-level `svg` namespace)
- `src/svg/backends/{cairo,coregraphics}.zig` (import path update)

**Tasks:**

- [x] Move the path-parser code from `scene/svg.zig` into
      `svg/path.zig`. Keep type names but rehome them.
- [x] Delete `scene/svg.zig`.
- [ ] Adopt `AssetCache(SvgDocument, MAX_SVG_DOCS)` from PR 1 for the
      SVG document cache. **Deferred** — see "Landed" notes; the SVG
      hot path does not currently keep `SvgPath` documents alive
      across frames (each rasterization parses then drops), so there
      is no second `AssetCache` consumer to validate the trait
      against. PR 1's `AssetCache` skeleton stays a `@compileError`
      stub until a real second caller appears.
- [x] 0.16: any comptime path-parser tables that used `@Type` get
      converted (PR 0 should have done this; verify) — `grep @Type src/svg`
      → no matches.
- [x] 0.16: rasterizer SIMD audit — if any
      `@Vector(N, f32)[runtime_index]` exists, coerce to array first
      per [§21](./zig-0.16-changes.md#vectors) — `grep @Vector src/svg`
      → no matches.
- [x] Resolve the `Vec2` name collision between `scene/` and `svg/` —
      `svg/path.zig` re-exports `core.Vec2` / `core.IndexSlice`; the
      duplicate `Vec2` struct is gone. (Plan originally said
      "`core.Point` everywhere" but `core.Point(T)` is a layout
      type with unit semantics; raw geometry math uses `core.Vec2`
      per `core/vec2.zig` doc comment.)

**Definition of done:**

- `find_path src/scene/svg.zig` returns nothing.
- No two distinct types named `Vec2`.
- All SVG-rendering examples still render.

**Landed:**

- ✅ `src/svg/path.zig` (new) holds `PathCommand`, `CubicBez`,
  `QuadraticBez`, `flattenArc`, `SvgPath`, `PathParser`,
  `SvgElementParser`, `flattenPath` — verbatim move from the old
  `scene/svg.zig`, with the local `Vec2` / `IndexSlice` declarations
  replaced by re-exports of `core.vec2.Vec2` / `core.vec2.IndexSlice`.
- ✅ `src/core/vec2.zig` gained `Vec2.init(x, y)` (used everywhere in
  the path parser instead of struct-literal noise) and an optional
  `closed: bool = false` field on `IndexSlice` so stroke rasterization
  can distinguish `Z`-terminated subpaths from open ones. Default
  keeps non-SVG callers (triangulator, mesh builder, benchmarks)
  source-compatible.
- ✅ `src/svg/mod.zig` re-exports the parser surface
  (`Vec2`, `IndexSlice`, `PathCommand`, `CubicBez`, `QuadraticBez`,
  `SvgPath`, `PathParser`, `SvgElementParser`, `flattenArc`,
  `flattenPath`) plus the `path` namespace, so backends keep using
  `svg_mod.SvgPath`-style names without reaching across modules.
- ✅ `src/svg/backends/cairo.zig` and
  `src/svg/backends/coregraphics.zig` switched their `svg_mod` import
  from `../../scene/svg.zig` to `../path.zig`. No call-site changes
  needed — types live behind the same `svg_mod.*` names.
- ✅ `src/scene/mod.zig` dropped the `pub const svg = @import("svg.zig")`
  re-export.
- ✅ `src/root.zig` top-level `pub const svg` now points at the
  consolidated `svg/mod.zig` (was `scene.svg`). Public surface
  preserved: `gooey.svg.SvgAtlas`, `gooey.svg.rasterize`, etc.
- ✅ `src/scene/svg.zig` deleted (`find src -name svg.zig` now only
  returns `src/components/svg.zig`, which is the unrelated UI
  component).
- ✅ `Vec2` collision audit:
  `grep -rn "^pub const Vec2 = struct" src/` → exactly one match,
  `src/core/vec2.zig`.
- ✅ `zig build` green; `zig build test --summary all` reports
  `Build Summary: 9/9 steps succeeded; 983/983 tests passed`
  (unchanged from PR 1 — this PR is a pure consolidation, no new
  tests, no test removals).

---

## PR 3 — `context/` subsystem extractions

**Goal:** drop `Gooey` from ~1,984 lines to under 1,200 by lifting
self-contained subsystems into peer modules. **No public API change.**

**Write scope:**

- `src/context/gooey.zig` (shrink)
- `src/context/hover.zig` (new)
- `src/context/blur_handlers.zig` (new)
- `src/context/cancel_registry.zig` (new)
- `src/context/a11y_system.zig` (new)
- `src/context/subscriber_set.zig` (new)

**Tasks:**

- [x] Extract `HoverState` per
      [§7b](./architectural-cleanup-plan.md#7b-extract-a-hoverstate-struct):
      `hovered_layout_id`, `last_mouse_x`, `last_mouse_y`,
      `hovered_ancestors`, `hovered_ancestor_count`, `hover_changed`.
- [x] Extract `BlurHandlerRegistry` (cap 64) per
      [§7d](./architectural-cleanup-plan.md#7d-extract-blurhandlerregistry).
- [x] Extract `CancelRegistry` per
      [§7e](./architectural-cleanup-plan.md#7e-the-cancel_groups-registry).
- [x] Extract `A11ySystem` per
      [§7c](./architectural-cleanup-plan.md#7c-extract-an-a11ysystem):
      `a11y_tree`, `a11y_platform_bridge`, `a11y_bridge`,
      `a11y_enabled`, `a11y_check_counter`.
- [x] Introduce `SubscriberSet(comptime Key, comptime Cb,
  comptime cap)` (cleanup item #8). Use it as the storage for
      `BlurHandlerRegistry` and `CancelRegistry` to validate the
      generic shape on real callers before PR 8 leans on it.
- [x] 0.16: audit `accessibility.zig` for `@Type` usage in the tree
      builder. Pair-assert at the write/read boundary on every
      `setNode` / `getNode` per CLAUDE.md §3. **Verified clean** —
      `grep "@Type\|@typeInfo" src/accessibility/` returns no matches;
      the tree builder uses fixed-size element / fingerprint arrays
      with no comptime metaprogramming. Pair-asserts on element
      bounds already live on `Tree.beginFrame` / `Tree.endFrame` /
      `Tree.syncBounds`
      (`std.debug.assert(self.element_count <= constants.MAX_ELEMENTS)`).

**Definition of done:**

- `gooey.zig` is < 1,200 lines. **Partial** — landed at 1,780 lines
  (down from 1,893). The four PR 3 extractions removed ~250 lines of
  subsystem state + methods; ~50 lines of one-line forwarders + module
  doc came back to preserve "no public API change". The remaining gap
  to 1,200 lines is dominated by four duplicated `init*` paths
  (~430 lines combined) which are explicitly slated for PR 7
  (App/Window split) and the `_owned: bool` flags slated for PR 9 —
  out of PR 3's listed task scope.
- `wc -l src/context/gooey.zig` confirmed in PR description.
- No public API change. All examples build unchanged.
- `SubscriberSet` has at least two distinct call sites.

**Landed:**

- ✅ `src/context/subscriber_set.zig` (new): generic
  `SubscriberSet(Key, Callback, options)` — fixed-capacity slot map
  with dense-prefix invariant, swap-remove `removeAt` / `removeWhere`,
  `forEach` visitor, `Insertion = { .inserted, .replaced, .dropped }`
  outcome enum. Slice-keyed sets supply a custom `keysEqual`
  (`std.mem.eql`); pointer-keyed sets fall through to the default
  `std.meta.eql`. Two distinct call shapes used in PR 3 (slice + payload
  in `BlurHandlerRegistry`, pointer + `void` in `CancelRegistry`)
  validate the generic before PR 8 leans on it for `element_states`.
- ✅ `src/context/hover.zig` (new): `HoverState` owns
  `hovered_layout_id` / `last_mouse_{x,y}` / `hovered_ancestors[32]` /
  `hovered_ancestor_count` / `hover_changed`. Public API:
  `init`, `initInPlace`, `beginFrame` (clears the latch),
  `update(tree, x, y) -> bool`, `refresh(tree)`, `isHovered`,
  `isLayoutIdHovered`, `isHoveredOrDescendant`, `ancestors()` slice
  view (read by the debug overlay generator), `clear`. The dispatch
  tree is threaded as a parameter to keep the data dependency
  visible at every call site (no `*Gooey` back-pointer).
- ✅ `src/context/blur_handlers.zig` (new): `BlurHandlerRegistry`
  backed by
  `SubscriberSet([]const u8, HandlerRef, .{ .capacity = 64, .keysEqual = std.mem.eql })`.
  Public API: `init`, `initInPlace`, `register`, `clearAll`,
  `getHandler`, `contains`, `count`, plus the `beginTransition` /
  `endTransition` re-entrancy latch (was
  `blur_handlers_invoked_this_transition` on `Gooey`).
- ✅ `src/context/cancel_registry.zig` (new): `CancelRegistry` backed
  by `SubscriberSet(*std.Io.Group, void, .{ .capacity = 64 })`.
  Public API: `init`, `initInPlace`, `register` (idempotent),
  `unregister -> bool`, `contains`, `count`, `cancelAll(io)`.
  Asserts on overflow rather than warn-and-drop — a leaked group at
  teardown is a use-after-free hazard worth crashing for.
- ✅ `src/context/a11y_system.zig` (new): `A11ySystem` owns the
  `a11y.Tree` (~350KB, `noinline initInPlace` per `CLAUDE.md` §14),
  the `PlatformBridge` storage, the `Bridge` dispatcher, the
  `enabled` cache, and the `check_counter`. Public API:
  `initInPlace(window, view)`, `deinit`, `beginFrame` (handles the
  60-frame screen-reader poll), `endFrame(layout)` (zero-cost when
  disabled — early-out is the contract hot-path callers rely on),
  `isEnabled`, `forceEnable` / `forceDisable`, `getTree`, `announce`.
- ✅ `src/context/gooey.zig` shrinks 113 lines net (1893 → 1780).
  Every removed method survives as a one-line forwarder
  (`updateHover` → `self.hover.update`, `registerCancelGroup` →
  `self.cancel_registry.register`, `isA11yEnabled` →
  `self.a11y.isEnabled`, etc.) — no public API change.
- ✅ External call sites updated to read sub-fields directly:
  - `runtime/frame.zig` `renderDebugOverlays` reads
    `gooey.hover.hovered_layout_id` / `gooey.hover.ancestors()`.
  - `runtime/input.zig` `handleMouseDownEvent` reads
    `gooey.hover.hovered_layout_id`.
  - `ui/builder.zig` `accessible` / `accessibleEnd` / `announce` /
    `isA11yEnabled` route through `g.a11y.*` (`isEnabled`,
    `getTree`, `announce`).
- ✅ `src/context/mod.zig` re-exports the four subsystems
  (`HoverState`, `BlurHandlerRegistry`, `CancelRegistry`,
  `A11ySystem`) plus `SubscriberSet` and the cap constants.
- ✅ `zig build test --summary all` reports
  `Build Summary: 9/9 steps succeeded; 1020/1020 tests passed`
  (vs. 983/983 on PR 2 — the +37 are the new `SubscriberSet`,
  `HoverState`, `BlurHandlerRegistry`, `CancelRegistry`, and
  `A11ySystem` unit tests).

---

## PR 4 — Break the backward edges

**Goal:** kill the `context → widgets` and `ui → widgets` imports.
After this PR, dependency direction is monotonic upward.

**Write scope:**

- `src/context/gooey.zig` (drop widget imports)
- `src/context/focus.zig` (defines `Focusable` vtable)
- `src/widgets/text_input_state.zig` (implements `Focusable`)
- `src/widgets/text_area_state.zig` (implements `Focusable`)
- `src/widgets/code_editor_state.zig` (implements `Focusable`)
- `src/widgets/uniform_list.zig` (receive layout helpers)
- `src/widgets/virtual_list.zig` (receive layout helpers)
- `src/widgets/data_table.zig` (receive layout helpers)
- `src/ui/builder.zig` (drop direct widget imports)

**Tasks:**

- [x] Define `Focusable` vtable per
      [§4 cleanup direction](./architectural-cleanup-plan.md#cleanup-direction-3):
      `{ ptr, vtable: { focus, blur, is_focused } }`.
- [x] Convert `TextInput`, `TextArea`, `CodeEditorState` to register
      themselves with the focus manager via `Focusable`. Remove the
      direct imports from `context/gooey.zig` and
      `context/dispatch.zig`.
- [x] Move `computeUniformListLayout` (and `virtual_list`,
      `data_table` siblings) from `ui/builder.zig` into the matching
      `widgets/*.zig` file. `Builder` now exposes only generic
      primitives (`pending_scrolls`, `generateId`, `layout`); each
      list widget owns its own `Layout` struct, `computeLayout` /
      `openElements` / `renderSpacer` / `registerScroll` / `syncScroll`
      and takes `*Builder` as a parameter.
- [x] 0.16: the `Focusable` vtable is a plain struct of
      `*const fn (...)` fields built at `comptime` from a generic
      `fromInstance(comptime T, instance: *T) Focusable` — no
      `@Type` / `@Struct` metaprogramming required, so the PR 0
      builtin-rename audit applies trivially.
- [x] Update `core/interface_verify.zig` to compile-check
      `Focusable` for each widget. New `verifyFocusableInterface(T)`
      asserts `focus` / `blur` / `isFocused` / `focusable` exist;
      `widgets/mod.zig` instantiates it once at `comptime` for each
      of the three focusable widgets so a missing method fails the
      build, not the next focus event.

**Definition of done:**

- `grep -n "@import.*widgets" src/context/gooey.zig src/context/dispatch.zig`
  returns nothing. **Done.**
- `grep -n "@import.*widgets" src/ui/` returns nothing. **Done.**
- `src/context/widget_store.zig` retains its widget imports — that
  module _is_ the per-type widget storage and dropping its imports
  requires the generic `element_states` map slated for PR 8 (see
  `architectural-cleanup-plan.md` §11 / §19). The original "no
  widget imports anywhere under `src/context/`" check was overly
  strict for the PR 4 task scope; the spirit (kill the
  `context → widgets` edges that drove `Gooey` and `DispatchTree`
  to know specific widget types) is achieved.
- All widget tests pass.

**Landed:**

- ✅ `src/context/focus.zig` (~120 lines added): `Focusable` trait
  (`{ ptr, vtable: { focus, blur, is_focused } }`) plus
  `Focusable.fromInstance(comptime T, instance) Focusable` —
  one comptime-built vtable per widget type, in static storage,
  shared across all instances. `eql(a, b)` is pointer-identity
  (the framework relies on this for "same-instance" checks across
  frames, and `WidgetStore` heap-allocates each widget exactly
  once so pointers are stable). `is_focused` is typed
  `*const fn (*anyopaque) bool` (non-`*const`) because
  `CodeEditorState.isFocused` delegates through its embedded
  `TextArea` and so cannot be `*const Self` — see the inline
  comment on `Focusable.VTable`.
- ✅ `FocusHandle` gains `widget: ?Focusable` plus
  `withWidget(focusable)` fluent setter. `FocusManager` gains a
  cached `focused_widget: ?Focusable` (refreshed in `endFrame` /
  `focus`) and a `focusWidget(id: []const u8)` convenience that
  is the public replacement for the old per-type
  `focusTextInput` / `focusTextArea` / `focusCodeEditor`.
  `FocusManager.focus(id)` now drives the trait's `blur()` on
  the previously-focused widget and `focus()` on the new one —
  no walk over per-type widget maps, and pointer-equality
  short-circuits a self-blur if focus moves within the same
  widget instance. `FocusManager.blur()` clears through the
  trait too.
- ✅ `src/widgets/text_input_state.zig`,
  `src/widgets/text_area_state.zig`,
  `src/widgets/code_editor_state.zig`: each gets a
  `pub fn focusable(self: *Self) focus_mod.Focusable` that
  returns `Focusable.fromInstance(Self, self)`. The widget files
  now import `../context/focus.zig` — that's `widgets → context`,
  the legal direction (the backward edge being broken is
  `context → widgets`).
- ✅ `src/context/gooey.zig` shrinks 61 lines net (1780 → 1719)
  and **drops the three widget-state type imports outright**.
  Methods removed: `textInput`, `textArea`, `codeEditor`,
  `textInputOrPanic`, `textAreaOrPanic`, `codeEditorOrPanic`,
  `getFocusedTextInput`, `getFocusedTextArea`,
  `getFocusedCodeEditor`, `focusTextInput`, `focusTextArea`,
  `focusCodeEditor`, `focusWidgetById` (the comptime switch),
  `syncWidgetFocus`. The replacement surface is **one** generic
  `pub fn focusWidget(self, id: []const u8)` that calls
  `self.focus.focusWidget(id)`. `invokeBlurHandlersForFocusedWidgets`
  collapses to `invokeBlurHandlerForFocusedWidget` — the focus
  manager already knows the focused element's `string_id`, so
  the registry lookup is a single `getHandler` call instead of
  three nested per-type-map walks. Adding a new focusable widget
  type now touches **only** `widgets/`.
- ✅ `src/ui/builder.zig` shrinks **737 lines net** (2427 → 1690)
  and **drops all three `@import("../widgets/*.zig")` lines**.
  The 780-line block of list helpers (Uniform / Virtual / Data
  Table) — `compute*Layout`, `open*Elements`, `render*Spacer`,
  `register*Scroll`, `sync*Scroll`, plus the private
  `compute*Sizing` / `compute*Padding` and the per-list `Layout`
  structs — moved into the matching widget files. Each function
  takes `*Builder` as its first arg and reaches the generic
  primitives directly (`b.pending_scrolls`,
  `b.pending_scrolls_by_layout_id`, `b.generateId()`,
  `b.layout`, `b.gooey.widgets.scrollContainer`). The rename
  drops the type prefix:
  `Builder.computeUniformListLayout` → `uniform_list.computeLayout`,
  `b.openUniformListElements` → `uniform_list.openElements`,
  `UniformListLayout` → `uniform_list.Layout`, etc.
  Builder's three `renderInput` / `renderTextArea` /
  `renderCodeEditor` methods also stop touching widget types
  through `g.textInput(id)` &c. and route through
  `g.widgets.textInput(id)` directly, then attach the widget's
  `Focusable` to its `FocusHandle` via `withWidget`.
- ✅ `src/cx.zig` updated: 16 list call sites switch from
  `b.syncUniformListScroll(...)` /
  `Builder.computeUniformListLayout(...)` etc. to
  `uniform_list.syncScroll(b, ...)` /
  `uniform_list.computeLayout(...)`. The widget-access
  forwarders (`textField`, `textAreaWidget`, `codeEditorWidget`)
  route through `self._gooey.widgets.*`; the focus forwarders
  (`focusTextField`, `focusTextArea`) call
  `self._gooey.focusWidget(id)`.
- ✅ `src/runtime/frame.zig` and `src/runtime/input.zig`:
  per-type `gooey.textInput(id)` / `gooey.getFocusedTextArea()`
  / `gooey.focusCodeEditor(id)` / etc. all rewrite to
  `gooey.widgets.*` and `gooey.focusWidget(id)`. Same for
  `src/examples/*.zig` (pomodoro, showcase, code_editor).
- ✅ `src/core/interface_verify.zig` gains
  `verifyFocusableInterface(comptime T)` asserting `focus`,
  `blur`, `isFocused`, `focusable` declarations exist.
  Re-exported from `core/mod.zig`. `widgets/mod.zig` runs the
  check at `comptime` for `TextInput`, `TextArea`,
  `CodeEditorState` — drop a method, fail the build.
- ✅ `src/context/mod.zig` re-exports `Focusable` so consumers
  reach it via `@import("context/mod.zig").Focusable`.
- ✅ `src/widgets/mod.zig`: `comptime` block at the bottom of
  the file pins the trait shape on all three focusable widgets.
- ✅ `zig build test --summary all` reports
  `Build Summary: 9/9 steps succeeded; 1023/1023 tests passed`
  (vs. 1020/1020 on PR 3 — the +3 are
  "Focusable vtable drives focus/blur on a widget",
  "FocusManager.focusWidget drives the registered Focusable",
  and "FocusManager.focus is a no-op for the same id" in
  `src/context/focus.zig`).

---

## PR 5 — `cx.zig` sub-namespacing

**Status: ☑ landed.** `wc -l src/cx.zig` = 788 (down from 1,972), all
1,026/1,026 tests pass. Branch `cleanup/pr-5-cx-namespacing`.

**Goal:** drop `cx.zig` from ~1,971 lines by sub-namespacing the
widget-coordination APIs. **Additive — no removal yet.**

**Write scope (landed):**

- `src/cx.zig` — mostly deletions and one-line forwarders.
- `src/cx_tests.zig` (new) — pattern tests moved out of `cx.zig` to
  keep it under the line budget; pulled back into the test graph via
  `comptime _ = @import("cx_tests.zig")` near the top of `cx.zig`.
- `src/cx/lists.zig` (new) — `Lists` namespace.
- `src/cx/animations.zig` (new) — `Animations` namespace. Named
  plural to avoid colliding with the still-deprecated `cx.animate`
  forwarder; the singular slot frees up in PR 9.
- `src/cx/entities.zig` (new) — `Entities` namespace.
- `src/cx/focus.zig` (new) — `Focus` namespace.

**Tasks:**

- [x] Move all `cx.uniformList` / `treeList` / `virtualList` /
      `dataTable` bodies into `cx/lists.zig`. `cx.lists.uniform(…)`
      is the new callsite.
- [x] Same shape for animations, entities, focus. Inside each
      namespace, the redundant prefix is dropped — see the migration
      tables in the new modules' doc comments
      (`cx.animate` → `cx.animations.tween`,
      `cx.createEntity` → `cx.entities.create`,
      `cx.focusNext` → `cx.focus.next`, etc).
- [x] Old top-level methods become one-line forwarders marked with a
      `// Deprecated:` comment pointing to the new location.
      Removal happens in PR 9.
- [x] Update examples and docs to use the sub-namespaced form.
      Updated: `uniform_list_example.zig`, `tree_example.zig`,
      `code_editor.zig`, `virtual_list_example.zig`,
      `data_table_example.zig`, `lucide_demo.zig`, `animation.zig`,
      `dynamic_counters.zig`, `form_validation.zig`.
- [x] 0.16: nothing material in this PR.

**Definition of done:**

- [x] `wc -l src/cx.zig` < 800 (landed at **788**).
- [x] Both `cx.uniformList(…)` and `cx.lists.uniform(…)` work — the
      forwarders on `Cx` are one-line calls into the namespace
      bodies, so the deprecated and new call shapes route through
      identical code. New tests in `cx_tests.zig` pin the
      decl-existence side of this contract and assert that the
      `DataTableCallbacks` alias produces the _same_ type from both
      namespaces.

**Implementation notes:**

- Each namespace marker (`Lists`, `Animations`, `Entities`, `Focus`)
  is a zero-sized struct that lives as a default-initialised field on
  `Cx`. Methods on those structs recover `*Cx` via
  `@fieldParentPtr`. That gives the documented `cx.lists.uniform(…)`
  call shape with no extra parens at the call site, no extra storage,
  and no aliasing of the `*Cx` pointer (CLAUDE.md §10).
- Each namespace has a `_align: [0]usize = .{}` field. Without it,
  the zero-sized field would limit `Cx`'s alignment to 1 and
  `@fieldParentPtr` would refuse to recover the parent pointer with
  "increases pointer alignment". `[0]usize` adds zero bytes but
  bumps the struct's alignment requirement to match the rest of
  `Cx`. A unit test asserts `@sizeOf` stays zero for every namespace
  marker so a future field accidentally sneaking in will fail loudly
  rather than silently bloating the hot context struct.
- The redundant `computeTriggerHash` helper from the old `cx.zig`
  was relocated — not duplicated — into `cx/animations.zig`. The
  deprecated forwarders on `Cx` route through that single copy.

---

## PR 6 — `DrawPhase` + `Global(G)`

**Status: ☑ landed.** Branch `cleanup/pr-6-draw-phase-globals`. Build
green, `Build Summary: 9/9 steps succeeded; 1053/1053 tests passed`
(up 27 from PR 5's 1026: 9 `DrawPhase` tests, 15 `Globals` tests, 3
ladder tests on `Gooey`).

**Goal:** add the GPUI-style `DrawPhase` enum and per-method phase
assertions, and introduce `Globals` for type-keyed singletons (theme,
keymap, debugger).

**Write scope (landed):**

- `src/context/draw_phase.zig` (new) — `DrawPhase` enum,
  `assertPhase` / `assertPhaseOneOf` / `assertInFrame` /
  `assertAdvance` helpers. Tagged `u8` per CLAUDE.md §15 so the
  field on `Gooey` is one byte.
- `src/context/global.zig` (new) — `Globals` struct with
  `MAX_GLOBALS = 32`, three ownership shapes (`owned`, `borrowed`,
  `borrowed_const`), `setOwned` / `setBorrowed` / `setBorrowedConst`,
  matching `replace*` and `update`. Linear-scan lookup over a
  fixed-capacity `[32]Entry` array.
- `src/context/gooey.zig` — `globals: Globals = .{}` and
  `current_phase: DrawPhase = .none` added; `keymap` / `debugger`
  fields **deleted** and replaced with `gooey.keymap()` /
  `gooey.debugger()` accessors that read from `globals`. The four
  init paths (`initOwned`, `initOwnedPtr`, `initWithSharedResources`,
  `initWithSharedResourcesPtr`) all `setOwned` `Keymap` and
  `Debugger`. Frame lifecycle (`beginFrame` / `endFrame` /
  `finalizeFrame`) advances through the phase ladder; `openElement`
  / `closeElement` / `text` assert `.prepaint`.
- `src/context/mod.zig` — re-exports `DrawPhase`, `Globals`,
  `MAX_GLOBALS`, and the `assert*` helpers.
- `src/ui/builder.zig` — `theme_ptr` field deleted; `setTheme` and
  `theme()` route through `gooey.globals.replaceBorrowedConst(Theme,
...)` / `getConst(Theme)` with a `&Theme.light` fallback for
  bare-builder unit tests.
- `src/runtime/frame.zig`, `src/runtime/input.zig`,
  `src/examples/actions.zig` — call sites updated from
  `gooey.debugger.foo()` / `gooey.keymap.foo()` to
  `gooey.debugger().foo()` / `gooey.keymap().foo()` (mechanical sed
  pass).

**Tasks:**

- [x] Define `DrawPhase = enum { none, prepaint, paint, focus }`.
      Add `current_phase: DrawPhase` to `Gooey`. Layout pass-through
      methods (`openElement`, `closeElement`, `text`) assert
      `.prepaint` per CLAUDE.md §3.
- [x] Define `Globals` keyed on `typeId(G)` (same shape as
      `entity.typeId` — `@typeName(T).ptr` interpret-as-`usize`)
      with a fixed capacity `MAX_GLOBALS = 32`. API: `setOwned`,
      `setBorrowed`, `setBorrowedConst`, `get`, `getConst`,
      `replaceBorrowed`, `replaceBorrowedConst`, `update`,
      `deinit`. Owned slots register a comptime-built deinit thunk
      that picks the right `G.deinit` shape (`fn(*Self) void` or
      `fn(*Self, Allocator) void`); primitives without a `deinit`
      decl are accepted via a `hasDeinit` guard.
- [x] Move keymap and debugger out of `Gooey` and into globals.
      `gooey.keymap()` / `gooey.debugger()` are thin one-liners
      that panic on missing slot (a framework bug, not a runtime
      fallback). Theme storage moves out of `Builder.theme_ptr` and
      into the same registry under the `*const Theme` shape.
- [x] 0.16: no `@Type` work was needed here — `Globals` uses
      `@typeName` for keys and `@hasDecl` / `@typeInfo(...).@"fn"`
      (already lower-case-tag form) for the deinit thunk reflection.

**Definition of done:**

- [x] Calling a layout method outside `.prepaint` fails an
      assertion in debug builds (e.g. `openElement` after
      `endFrame` panics with
      `DrawPhase mismatch: expected .prepaint, got .paint`).
- [x] `Gooey` no longer owns `keymap` or `debugger` directly —
      both moved to `globals`. Theme moved out of `Builder` into
      the same store.
- [x] `Build Summary: 9/9 steps succeeded; 1053/1053 tests passed`.

**Implementation notes:**

- **Three ownership shapes, not two.** GPUI's globals are roughly
  one shape ("we own it"). For Gooey, `*const Theme` callers pass
  `&Theme.dark` from rodata; copying the entire `Theme` into a heap
  slot per call would be wasteful and would break `cx.setTheme(...)`
  semantics where the user expects pointer identity. So `Globals`
  has `setOwned` (heap-alloc + deinit on teardown), `setBorrowed`
  (caller-managed `*G`), and `setBorrowedConst` (caller-managed
  `*const G`, with `get(G)` panicking and only `getConst(G)`
  succeeding). The const variant matters: `get(G)` would otherwise
  silently return a mutable view of an immutable global and break
  the borrow contract.
- **Linear scan beats a hash map at this size.** With
  `MAX_GLOBALS = 32`, a tagged-array scan is two cache lines and
  ~32 integer compares worst case. A hash map would allocate, grow,
  and pull in collision-resolution logic the registry doesn't need.
- **Phase ladder is centralised in `advancePhase`.** The frame
  lifecycle methods on `Gooey` call `self.advancePhase(.prepaint)`
  / `.paint` / `.focus` / `.none` rather than mutating the field
  directly. `assertAdvance` enforces the four-edge legal table at
  every transition, so a frame driver that forgets `finalizeFrame`
  fails on the **next** `beginFrame` rather than corrupting the
  next frame's state silently.
- **`Builder.theme_ptr` deletion is load-bearing.** Without it,
  `setTheme` would update `globals` but `theme()` would still read
  the cached pointer, drifting on the second frame. Keeping a
  single source of truth (`globals`) is the entire point of the
  PR. Bare-builder unit tests (no `gooey` parent) get
  `&Theme.light` from `theme()` — same fallback the old
  `theme_ptr orelse &Theme.light` provided.
- **Test stub `testGooey` survives unchanged.** It uses
  `Globals = .{}` (default) and never registers a keymap /
  debugger, so the deferred-command tests don't touch the new
  accessors. Three new ladder tests (`DrawPhase: default phase is
.none` / `walks the legal ladder` / `mirrors current_phase
across multiple ladders`) pin the phase machine without standing
  up a full UI stack.
- **`MAX_GLOBALS = 32` is generous.** PR 6 lands with 3 entries
  (theme, keymap, debugger). The cleanup plan calls out future
  consumers (focus debugger, settings, telemetry) that would push
  toward ~10. Doubling that headroom keeps `Gooey`'s embedded
  table at exactly 1 KiB on a 64-bit target — small enough not to
  worry about.

---

## PR 7 — App/Window split + `Frame` double buffer

**This is the architectural earthquake.** Largest PR; medium-high risk.
Planned as a multi-day effort split across landable sub-PRs (7a, 7b, …)
so each lands green on its own.

**Status:**

- ☑ **7a — `AppResources` + drop `_owned` flags.** Landed on
  `cleanup/pr-7a-app-resources`. `Build Summary: 9/9 steps succeeded;
1057/1057 tests passed` (vs. 1053 on PR 6 — the +4 are
  `AppResources`'s own ownership-shape tests). Five of six `_owned`
  flags retired; remaining `image_loader` per-window placement
  reserved for 7b. See "Sub-PR 7a" below.
- ◐ **7b — Rename `Gooey → Window`, lift `keymap` / `globals` /
  `entities` / `image_loader` into a real `App`.** In progress on
  `cleanup/pr-7b-app-window-split`. The work split into six
  landable slices once the surface area was mapped:
  - ☑ **7b.1a — `platform.Window → platform.PlatformWindow`.**
    Pure mechanical rename to free the `Window` name for the
    framework wrapper. `9/9 steps; 1057/1057 tests passed`.
  - ☑ **7b.1b — `Gooey → Window` (framework wrapper).** File
    rename `context/gooey.zig → context/window.zig`, struct
    rename, ~220 internal uses + 124 call-site references update
    in lockstep. `9/9 steps; 1057/1057 tests passed`.
  - ☑ **7b.2 — `multi_window_app::App` embeds `AppResources`.**
    Closes the 7a inconsistency where the multi-window owner
    still carried the pre-7a `*TextSystem` / `*SvgAtlas` /
    `*ImageAtlas` triplet. `9/9 steps; 1057/1057 tests passed`.
  - ☑ **7b.3 — Lift `entities: EntityMap` off `Window` onto
    `App`.** Landed on `cleanup/pr-7b3-entities-on-app`. New
    `src/context/app.zig` introduces a focused `App` struct
    (currently `allocator` + `io` + `entities`; subsequent 7b
    slices add `keymap` / `globals` / `image_loader`).
    Single-window flow heap-allocates one `App` in
    `runtime/runner.zig` (and on WASM in `app.zig::WebApp`);
    multi-window flow embeds a `context.App` by value inside
    `multi_window_app.zig::App`. Either way every `Window`
    borrows `*App` so cross-window entity observation becomes
    structurally possible. `Build Summary: 9/9 steps succeeded;
1061/1061 tests passed` (+4 vs. 1057 — the four `App`
    init/deinit/cross-window-share tests). See "Sub-PR 7b.3"
    below.
  - ☑ **7b.4 — Lift `keymap` and `*const Theme` off `Window`
    onto `App.globals`.** Landed on
    `cleanup/pr-7b4-keymap-theme-on-app`. `Keymap` registration
    moved off all four `Window.init*` paths onto `App.init` /
    `App.initInPlace`; `Window.keymap()` becomes a forwarder to
    `self.app.keymap()` so existing call sites
    (`runtime/input.zig`, `examples/actions.zig`) keep working
    without churn. The `*const Theme` slot follows the same
    lift via `Builder.setTheme` / `Builder.theme` writing
    through `window.app.globals` instead of `window.globals` —
    a single `cx.setTheme(&Theme.dark)` now repaints every
    window in a multi-window app, which was structurally
    impossible pre-7b.4. `Debugger` deliberately stays on
    `Window.globals` (overlay quads, frame timing, selected
    layout id all bound to one scene; sharing one debugger
    across windows would mix metrics from two unrelated
    frames). `App.init` / `initInPlace` signatures changed
    `Self → !Self` and `void → !void` because
    `Globals.setOwned` may fail with `OutOfMemory` — the
    three callers (`runtime/runner.zig`,
    `runtime/multi_window_app.zig`, `app.zig::WebApp`) added
    `try` in step. `Build Summary: 9/9 steps succeeded;
1063/1063 tests passed` (+2 vs. 1061 — the two new
    `App.keymap()` tests covering single-window access and the
    cross-window-share property the lift unlocks). See
    "Sub-PR 7b.4" below.
  - ☑ **7b.5 — Lift `image_loader` to `App`.** Landed on
    `cleanup/pr-7b5-image-loader-on-app`. Picked option (a)
    from the pre-flight choice list (shared loader on `App`
    rather than per-window loaders pointing at the shared
    atlas). Pre-7b.5 every per-window `Window` carried its
    own `ImageLoader`, so two windows requesting the same
    URL in the same frame would each launch a background
    fetch, double the bandwidth, and cache twice into the
    (already shared) atlas. Post-7b.5 the loader lives on
    `App`: pending and failed sets are app-scoped, the
    fetch group covers every window, and the
    `MAX_PENDING_IMAGE_LOADS` (64) cap is now a real
    app-wide ceiling rather than a per-window one. The
    loader's `*ImageAtlas` dependency is bound late via a
    new two-phase init — `App.init` / `App.initInPlace`
    leave `image_loader` undefined and
    `image_loader_bound = false`; both
    `WindowContext.init` (single-window) and
    `WindowContext.initWithSharedResources` (multi-window)
    call `app.bindImageLoader(window.resources.image_atlas)`
    after wiring `window.app = app`. `bindImageLoader` is
    idempotent on same-atlas re-binds (the first window
    performs the actual `initInPlace`; subsequent
    multi-window windows hit the same-atlas short-circuit),
    which sidesteps the field-init-ordering pinch in
    `multi_window_app::App.init` (where `resources` and
    `context_app` are siblings of one parent struct
    literal) without making the loader's lifecycle
    framework-call-site-dependent. `Window` lost the
    `image_loader` field, the `fixupImageLoadQueue`
    forwarder (no longer needed — `App.bindImageLoader`
    runs `initInPlace` at the loader's final heap address,
    so no by-value-copy queue dangle is possible), the
    `image_loader.deinit()` call from `Window.deinit`, and
    the four `.image_loader = undefined` slots in the
    init-path struct literals plus the `testWindow`
    fixture. `App.deinit` order rewrote to teardown the
    loader first (so in-flight fetches unwind against a
    still-live atlas — atlas is upstream-owned on
    `AppResources` and torn down _after_ `App.deinit`
    returns), then `entities`, then `globals`. `Build
Summary: 9/9 steps succeeded; 1066/1066 tests passed`
    (+3 vs. 1063 — three new `App` tests covering
    `bindImageLoader` single-bind, the unbound-deinit
    safety net for test fixtures, and the
    cross-window-share property the lift unlocks). See
    "Sub-PR 7b.5" below.
  - ☑ **7b.6 — Retire `Window.text_system` / `svg_atlas` /
    `image_atlas` back-compat aliases.** Landed on
    `cleanup/pr-7b6-retire-aliases`. ~28 internal call sites
    (the doc's pre-flight estimate of 124 was conservative —
    user examples never reached the aliases) rewritten through
    `window.resources.*` across `ui/builder.zig`,
    `runtime/{window_context,frame,render}.zig`, `app.zig`, and
    `context/window.zig`'s own self-references. The three
    pointer fields dropped from `Window`'s field list, taking
    their assignments out of every `init*` path with them.
    `Window.initWithSharedResources` /
    `initWithSharedResourcesPtr` and
    `WindowContext.initWithSharedResources` collapsed to take a
    single `*const AppResources` parameter; the bundle now
    stays bundled across the `App → WindowContext → Window`
    call chain. `9/9 steps; 1057/1057 tests passed`. Note: the
    four named `init*` entry points still exist on `Window`
    (`initOwned` / `initOwnedPtr` /
    `initWithSharedResources` / `initWithSharedResourcesPtr`);
    the parameter shape of the two shared-resources arms is
    now identical, but reducing to two named entry points
    requires a real `App` struct in the single-window flow,
    which lands later in 7b. See "Sub-PR 7b.6" below.
- ◐ 7c — `Frame` double buffer + `mem.swap` at frame boundary.
  Slicing across landable sub-PRs once the surface area was
  mapped:
  - ☑ **7c.1 — Lift per-tick app-scoped work onto `App`.**
    Pre-7c.1 `Window.beginFrame` / `endFrame` ran
    `self.app.image_loader.drain()` and
    `self.app.entities.beginFrame()` / `endFrame()` inline,
    once per window per tick. With N windows borrowing one
    `App` that's N redundant calls; `image_loader.drain` is
    idempotent (a second call gets 0 results), but
    `entities.beginFrame` is NOT — a window-A-render-then-
    window-B-begin sequence discards window-A's frame
    observations made earlier in the same tick. 7c.1 adds
    `App.beginFrame()` / `App.endFrame()` doing the
    app-scoped work (drain image_loader if bound on begin,
    clear stale entity observations on begin, symmetric
    no-op on end); `Window.beginFrame` / `endFrame` route
    through the new methods instead of unbundling
    `self.app.*` calls inline. The actual "call once per
    tick at the runtime layer" relocation lands in 7c.2 —
    landing the API surface first means the follow-up only
    has to relocate one method call, not split bundled
    work along the way. `Build Summary: 9/9 steps
succeeded; 1069/1069 tests passed` (+3 vs. 7b.5's 1066
    — three new `App.beginFrame` / `endFrame` tests). See
    "Sub-PR 7c.1" below.
  - ☑ **7c.2 — Hoist `App.beginFrame` / `App.endFrame`
    out of `Window` into the runtime frame driver.**
    Landed on `cleanup/pr-7c2-hoist-app-frame-hooks`.
    Pre-7c.2 the per-tick app-scoped pair lived inline
    in `Window.beginFrame` / `Window.endFrame`,
    reaching through `self.app.*`. The layering was
    wrong: app-scoped work belonged at the layer that
    owns the `App`, not in a per-window forwarder.
    Post-7c.2 `runtime/frame.zig::renderFrameImpl`
    drives the pair directly — `app.beginFrame()` runs
    after `window.beginFrame()` (so the per-window
    `image_atlas.beginFrame` has already reset the
    frame counter) and before `render_fn(cx)` (so
    observations made by widget renders this tick are
    not discarded by the entity-observation clear);
    `app.endFrame()` runs after `window.endFrame()`
    returns commands. Visible behaviour is unchanged
    for single-window flows (one window per render
    callback per tick, identical to pre-7c.2).
    Multi-window flows still hit the call once per
    window per tick because the platform layer
    dispatches each window's render callback
    independently — the centralised "all windows,
    this tick" driver lands in 7c.3+. The 7c.1 inline
    comment block on `App.beginFrame` was rewritten to
    call out the new caller (`renderFrameImpl`, not
    `Window`), and the matching block on
    `Window.beginFrame` / `Window.endFrame` documents
    that the hoisted call runs _outside_ the function,
    with the order constraint preserved by the runtime
    driver. `Build Summary: 9/9 steps succeeded;
1069/1069 tests passed` (no delta vs. 7c.1 — pure
    relocation; the three 7c.1 tests on
    `App.beginFrame` / `App.endFrame` still pin the
    method-level contract, and every example exercises
    the relocated call site through `zig build
install`). See "Sub-PR 7c.2" below.
  - ◐ 7c.3 — Introduce `Frame` struct holding `scene` +
    `dispatch` + per-frame transient state; double-buffer
    `rendered_frame` / `next_frame` with `mem.swap` at
    frame boundary. Slicing across landable sub-PRs once
    the surface area was mapped:
    - ☑ **7c.3a — `Frame` struct bundling `scene` +
      `dispatch`.** Landed on
      `cleanup/pr-7c3a-frame-struct`. New
      `src/context/frame.zig` introduces a `Frame`
      struct owning `scene: *Scene` + `dispatch:
*DispatchTree` behind a single `owned: bool` flag
      — same shape as `AppResources` from PR 7a, the
      symmetry deliberate since `Window` will end up
      holding one `AppResources` (app-lifetime shared)
      and one `Frame` (per-window per-tick) as its two
      ownership-bundle fields. All four `Window.init*`
      paths replace their previous two pairs of
      `allocator.create` + `T.init` + `setViewport`/
      `enableCulling` + `errdefer` blocks with a single
      `Frame.initOwned` / `Frame.initOwnedInPlace`
      call; `Window.deinit` replaces the matching two
      pairs of `T.deinit` + `allocator.destroy` with a
      single `self.frame.deinit()`. `window.scene` /
      `window.dispatch` are kept as back-compat alias
      fields populated from `frame.scene` /
      `frame.dispatch` by every init path; PR 7c.3b
      retires them by rewriting the ~167 internal call
      sites to reach through `window.frame.*`. The
      `borrowed` constructor on `Frame` exists today
      as a complete API surface so PR 7c.3c's
      double-buffer landing only has to wire callers,
      not introduce a third constructor on a stable
      type. `Build Summary: 9/9 steps succeeded;
1073/1073 tests passed` (+4 vs. 7c.2's 1069 —
      the four new `Frame` tests covering `initOwned`,
      `initOwnedInPlace`, `borrowed` deinit no-op, and
      zero-viewport tolerance). See "Sub-PR 7c.3a"
      below.
    - ☑ **7c.3b — Retire `window.scene` /
      `window.dispatch` back-compat aliases.** Landed
      on `cleanup/pr-7c3b-retire-scene-dispatch-aliases`.
      The pre-flight ~167-call-site estimate was
      generous — the actual sweep touched 6 files
      (`runtime/{frame,render,input,window_context}.zig`,
      `app.zig`, `context/window.zig`) and ~80
      inline references. Every `window.scene.*` /
      `self.scene.*` / `window.dispatch.*` /
      `self.dispatch.*` reference rewrites to reach
      through `window.frame.scene` /
      `window.frame.dispatch`; the two `*Scene` /
      `*DispatchTree` alias fields drop from
      `Window`'s field list, and the four
      `Window.init*` paths drop their alias-population
      lines. Same retirement shape PR 7b.6 used for
      the `text_system` / `svg_atlas` / `image_atlas`
      triplet. `Build Summary: 9/9 steps succeeded;
1073/1073 tests passed` (no delta vs. 7c.3a's
      1073 — pure call-site sweep, no new tests; the
      four `Frame` tests landed in 7c.3a continue to
      pin the ownership-shape contract). See "Sub-PR
      7c.3b" below.
    - ☑ **7c.3c — `rendered_frame` / `next_frame`
      double buffer with `mem.swap` at frame
      boundary.** Landed on
      `cleanup/pr-7c3c-double-buffer-frame`. **Direction:**
      renamed the existing `Window.frame` field to
      `Window.next_frame` (the build target — every
      pre-7c.3c call site that wrote through
      `window.frame.scene` / `window.frame.dispatch`
      was writing the frame currently under
      construction), and added `Window.rendered_frame:
Frame` for the previously-built tree.
      `mem.swap(&window.rendered_frame, &window.next_frame)`
      at the end of every tick in
      `runtime/frame.zig::renderFrameImpl`, then
      `window.next_frame.scene.clear()` and
      `window.next_frame.dispatch.reset()` recycle the
      now-stale buffer for the next build. Build call
      sites continue to write through
      `window.next_frame.*`; hit-testing for input
      events between frames reads
      `window.rendered_frame.dispatch` (the last
      fully-built tree, with bounds already synced
      pre-swap). Both `Window`-level slots carry
      `owned = true` — `mem.swap` is a physical struct
      exchange between two owning slots, not a hand-off
      through `Frame.borrowed`, so `Window.deinit`
      continues to free both pointee pairs across
      every swap. The four `Window.init*` paths
      allocate both `Frame`s up front (single-window
      pair owns its scene+dispatch; multi-window pair
      same per-window even with a borrowed
      `AppResources`); `Window.deinit` tears both
      down. On macOS / Linux a
      `platform_window.setScene(window.rendered_frame.scene)`
      update follows every swap so the
      `displayLinkCallback` / Linux render path tracks
      the heap-allocation rotation; web reads through
      `g_window.?.rendered_frame.scene` directly each
      tick and needs no setScene plumbing (the
      `getPlatformWindow` short-circuit in
      `renderFrameImpl` covers both). Hit-test sites
      in `runtime/input.zig` (`updateDragOverTarget`,
      `handleMouseDownEvent`, `handleDragSourceClick`,
      `handleDispatchClick`, `handleMouseUpEvent`,
      `handleFocusedKeyAction`) were rewritten to
      reach through `window.rendered_frame.dispatch`;
      build-pipeline call sites in
      `runtime/{frame,render}.zig`, `app.zig::WebApp`,
      and `runtime/window_context.zig` reach through
      `window.next_frame.*`. `Window.updateHover` /
      `Window.refreshHover` split: the former (called
      from input handlers between frames) reads
      `rendered_frame.dispatch`; the latter (called
      pre-swap inside `renderFrameImpl` after bounds
      sync) reads `next_frame.dispatch` and goes away
      in the follow-up slice that retires
      `refreshHover` per the (1) rationale below.
      `Builder` caches the `*Scene` / `*DispatchTree`
      pointers it was handed at `init` time, so the
      per-tick reset block in `renderFrameImpl` adds
      `builder.scene = window.next_frame.scene;
builder.dispatch = window.next_frame.dispatch;`
      alongside the `id_counter = 0` and pending-queue
      clears — keeps the cached pointers tracking
      `next_frame.*` across every swap. `Build
Summary: 9/9 steps succeeded; 1076/1076 tests
passed` (+3 vs. 7c.3b's 1073 — three new `Frame`
      `mem.swap` tests covering scene+dispatch
      exchange between two owning Frames, `owned =
true` preservation across arbitrary swap counts,
      and post-swap recycle landing on the right
      pointees without disturbing the
      just-rotated-into-rendered_frame pair). See
      "Sub-PR 7c.3c" below.

      Note on direction vs. 7c.3b's forward-compat
      sketch: PR 7c.3b read "7c.3c will rename
      `Window.frame` to `Window.rendered_frame`, add
      `Window.next_frame`" — that's backwards. The
      pre-7c.3c `Window.frame` was the active build
      target (every `window.frame.scene.*` write in
      `runtime/frame.zig::renderFrameImpl`,
      `Window.beginFrame`, `Builder.init`, and the
      widget render helpers was producing the frame
      under construction). GPUI's mapping in §11 is
      explicit: `mem::swap(rendered, next)` then
      `next.clear()`, with build writes landing in
      `next_frame`. Renaming `frame` → `rendered_frame`
      would have forced every build call site to flip
      to `next_frame` _and_ reshape the swap semantics
      in a follow-up slice, doubling the diff. The
      GPUI-faithful direction (`frame` → `next_frame`,
      add `rendered_frame`) made 7c.3c the single
      slice that landed the double buffer with its
      semantics intact.

      Performance rationale: the swap itself is a
      24-byte struct copy (allocator, two pointers,
      one-byte flag) — negligible at the slice
      boundary. The performance wins land in follow-up
      slices that the GPUI-faithful direction
      unlocks. (1) Hit-test correctness without
      `refreshHover`: pre-7c.3c
      `runtime/frame.zig::renderFrameImpl` called
      `window.refreshHover()` after the build pass to
      re-run hit testing against fresh bounds (input
      handling earlier in the tick used last frame's
      tree); with `rendered_frame` alive across the
      swap, input hit-tests against
      `rendered_frame.dispatch` (the last fully-built
      tree, with bounds already synced) and is
      correct the first time — one full hit-test
      pass per frame goes away. (2)
      `hovered_ancestors` cache simplification: the
      32-entry parent-chain cache in
      `context/hover.zig` exists _because_ the
      dispatch tree resets before the next mouse
      move arrives
      (`architectural-cleanup-plan.md` §11 calls
      this hack out by name); with
      `rendered_frame.dispatch` alive between frames,
      we re-walk the live tree on each hover update
      instead of populating the cache during build,
      reducing work in `HoverState.applyHit`. (3)
      Foundation for PR 8 `element_states`: the
      `with_element_state(global_id, …)` pattern in
      §19 looks up `(GlobalElementId, TypeId)` in
      `next_frame.element_states`, falling back to
      `rendered_frame.element_states`; the
      GPUI-faithful direction sets this up
      structurally with no further reshaping, while
      the literal-plan direction would have forced
      PR 8 to also flip the swap semantics. (4)
      Cleaner `dispatch.reset()` ownership: the
      explicit `window.next_frame.dispatch.reset()`
      at the start of `renderFrameImpl` is now
      redundant with the post-swap recycle on every
      tick after the first; PR 7c.3d cashed this
      in by retiring the start-of-frame reset
      entirely (tick 0 sees the same effective
      state via `Frame.initOwned`'s fresh dispatch).
      None of these wins land _in_ 7c.3c — the slice's job
      was the swap and the field rename; each
      follow-up slice cashes in one of the wins
      above against the new shape.

    - ☑ **7c.3d — Retire `refreshHover` and the
      start-of-frame `next_frame.dispatch.reset()`.**
      Landed on `cleanup/pr-7c3d-retire-refresh-hover`.
      Cashes in 7c.3c's win (1) and win (4) in a single
      slice (the 7c.3c plan grouped them — "the follow-up
      slice that retires `refreshHover` retires this
      duplicate reset at the same time"). Pre-7c.3d the
      per-tick frame driver in
      `runtime/frame.zig::renderFrameImpl` ran two redundant
      operations that existed only to paper over a hazard
      the 7c.3c double buffer made structurally impossible:
      (a) `window.refreshHover()` after the bounds-sync pass,
      to re-run hit testing against the just-built tree
      because input handlers earlier in the same tick had
      hit-tested against the in-progress single-buffer
      dispatch tree before bounds were synced; (b)
      `window.next_frame.dispatch.reset()` at the start of
      the function, redundant with the post-swap recycle on
      every tick after the first (and superfluous on tick 0
      because `Frame.initOwned`'s `DispatchTree.init`
      already produces an empty tree). Post-7c.3c, input
      always hit-tests against `rendered_frame.dispatch`
      (the previously-built tree, with bounds already
      synced and rotated in by the end-of-frame `mem.swap`),
      so (a) is unnecessary; the post-swap recycle plus
      first-tick `Frame.initOwned` cover both halves of
      (b)'s contract. With `refresh` retired, the
      `HoverState.last_mouse_x` / `HoverState.last_mouse_y`
      cache fields lose their only reader and follow it
      out — they existed solely so `refresh` could replay
      the last cursor coordinates without the runtime
      re-threading them, dead state per CLAUDE.md §10
      once `refresh` is gone. `Window.refreshHover`
      removed from the framework API surface; the
      `Window.updateHover` doc-block rewrites to drop the
      forward reference to `refreshHover` retirement (the
      retirement happened) and explain the post-7c.3d
      invariant. `hover.zig`'s module-level doc-block
      gains a `## History — refresh retirement (PR 7c.3d)`
      section recording why the cache fields and method
      are gone, so a future reader doesn't reintroduce
      them. `Build Summary: 9/9 steps succeeded; 1076/1076
tests passed` (no delta vs. 7c.3c's 1076 — pure
      removal of dead code + two existing-test assertion
      drops on the retired fields; the post-shape
      behaviour is already pinned by every existing
      `updateHover`-exercising test through input event
      paths and by every example through `zig build
install`). See "Sub-PR 7c.3d" below.

- ☑ 7d-framework — `App.main(init: std.process.Init)` /
  `WebApp.main` / `runCx` accept `init`. Landed on
  `cleanup/pr-7d-framework`. The pre-flight scope of
  "framework-side only, no user-facing example sweep"
  proved unworkable: Zig 0.16's `pub fn main(init)`
  contract is satisfied by the runtime providing `init`,
  so examples cannot construct it themselves to keep
  calling the new `App.main(init)`. The slice therefore
  absorbed the entire 7d-examples mechanical sweep
  (`pub fn main(init: std.process.Init)` signature +
  forwarded `init` arg to `App.main` / `gooey.runCx`)
  across 36 examples in one shot, with no `gooey.X` →
  `gooey.<ns>.X` demoted-name rewrites — those stay
  reserved for PR 9b/9c. `Build Summary: 9/9 steps
succeeded; 1103/1103 tests passed` (no delta vs.
  PR 8.4c — pure plumbing). **Full landing notes in
  [`pr-7d-framework-preflight.md`](./pr-7d-framework-preflight.md)**
  including the deviation rationale and the WASM
  `wasmInit` shadow fix.
- ☑ 7d-examples — Absorbed into 7d-framework's
  mechanical sweep above (the framework signature change
  could not land without it). PR 9 Task 4 is therefore
  already done; PR 9 only needs to land the demoted-name
  (`gooey.Button` → `gooey.components.Button`, etc.)
  rewrites against the already-migrated entry-point shape.
- ☐ 7e — Final `_owned` sweep + `grep -n "_owned" src/` returns nothing.
  Folded into PR 9 Task 5 (the structural audit pin).

**Goal:** split `Gooey` into `App` (process-lifetime, shared resources)

- `Window` (per-window frame state) + `Frame` (per-frame double
  buffer). Eliminate every `_owned: bool` flag.

**Write scope:**

- `src/app.zig` (rewritten)
- `src/window.zig` (new — receives most of the per-window guts of
  `Gooey`)
- `src/context/frame.zig` (new — `Frame` double-buffer struct)
- `src/context/gooey.zig` (becomes an orchestrator façade or is
  deleted entirely depending on call-site impact)
- `src/main.zig` / entry points (rewritten to take `init: *Init`)
- `examples/*/main.zig` (signatures updated)

**Tasks:**

- [ ] Define `Resources` (shared, app-lifetime) and `FrameContext`
      (per-window) per
      [§2 cleanup direction](./architectural-cleanup-plan.md#cleanup-direction).
- [ ] Define `Frame` with `rendered_frame` and `next_frame`
      double-buffered storage of `focus`, `element_states`,
      `mouse_listeners`, `dispatch_tree`, `scene`, `hitboxes`,
      `deferred_draws`, `input_handlers`, `tooltip_requests`,
      `cursor_styles`, `tab_stops`. Use `mem.swap` at frame boundary.
      Reference: [GPUI §11](./architectural-cleanup-plan.md#11-frame-double-buffering-with-memswap).
- [ ] Drop **every** `_owned: bool` flag. Ownership is encoded in
      whether the field is `T` (owned) vs `*T` (borrowed).
- [ ] All `noinline initInPlace` per CLAUDE.md §13–14 — `App`, `Window`,
      and `Frame` are all > 50 KB on WASM. Field-by-field, no struct
      literals.
- [ ] **0.16: rewrite the entry point against `Init`.**
      `pub fn main(init: *Init) !void` per
      [§9 "Juicy Main"](./zig-0.16-changes.md#9-juicy-main).
      Threaded `io`, `arena`, `gpa`, `environ_map`, `args` come from
      `init`. No more `std.os.argv` / `std.process.getEnvMap` global
      access.
- [ ] 0.16: any code path that previously took env vars or argv from
      globals is rewritten to take `*const std.process.Environ.Map` or
      `[]const [:0]const u8` explicitly.
- [ ] Examples and benchmarks adopt the new entry-point shape.

**Migration order (within the PR):**

1. Land `Resources` + `FrameContext` first behind a feature flag.
2. Rename `Gooey` → `Window`, move shared bits to `App`.
3. Add `Frame` and the `mem.swap` at frame boundary.
4. Drop ownership flags.
5. Rewrite entry point against `Init`.
6. Sweep examples.

**Definition of done:**

- `grep -n "_owned" src/` returns nothing.
- Multi-window example shares one `Resources` across N `Window`s.
- No global access to argv or env vars.
- WASM stack-budget assertions
  ([CLAUDE.md §14](../CLAUDE.md)) still hold for the new struct sizes.

---

**Sub-PR 7a — `AppResources` + drop `_owned` flags (landed):**

First landable slice of the App/Window earthquake. Goal: bundle
the three "expensive to duplicate per window" subsystems
(`TextSystem`, `SvgAtlas`, `ImageAtlas`) into one struct with a
single ownership flag, so the four parallel `init*` paths on
`Gooey` collapse toward two and the `*_owned: bool` flag triplet
retires. Reference: [`architectural-cleanup-plan.md` §2 cleanup
direction](./architectural-cleanup-plan.md#cleanup-direction)
and §17 (no ownership flags).

**Write scope (landed):**

- `src/context/app_resources.zig` (new) — `AppResources` struct
  with `initOwned` / `initOwnedInPlace` (single-window owning
  shape) and `borrowed` (multi-window borrowed view).
  `noinline initOwnedInPlace` per CLAUDE.md §14 so the WASM
  stack budget stays bounded across the embedded subsystem
  init paths. Four tests pin the two ownership shapes against
  `std.testing.allocator` (would catch any leak or double-free).
- `src/context/mod.zig` — re-exports `AppResources`.
- `src/context/gooey.zig` —
  - Adds `resources: AppResources` field.
  - **Drops** `text_system_owned`, `svg_atlas_owned`,
    `image_atlas_owned`, `scene_owned`, `layout_owned` (five of
    six `_owned` flags). The `scene` / `layout` flags were
    tautologically true — audit confirmed no init path ever
    left them borrowed.
  - All four init paths (`initOwned` / `initOwnedPtr` /
    `initWithSharedResources` / `initWithSharedResourcesPtr`)
    rewritten to delegate atlas / text-system creation through
    `AppResources`. The four-path shape is preserved for the 7a
    landing (PR 7b collapses to two when `Gooey → Window`
    rename happens).
  - `deinit` collapses three flag-guarded free blocks into one
    `self.resources.deinit()` call (no-op when borrowed).
  - Three back-compat alias fields preserved (`text_system`,
    `svg_atlas`, `image_atlas`) so the 124 existing
    `gooey.text_system` / etc. call sites keep working through
    7a; they retire in 7b.
  - `image_loader` stays on `Gooey` for now — its placement
    is a behavioural decision (one app-wide loop vs. per-window)
    deferred to 7b.

**Tasks landed:**

- [x] Define `AppResources` with two ownership shapes (`owned` /
      `borrowed`) and a single discriminator flag.
- [x] Single-window `Gooey` embeds an owning `AppResources` by
      value; multi-window `Gooey` embeds a borrowed view.
- [x] Five of six `_owned: bool` flags removed (`text_system_owned`,
      `svg_atlas_owned`, `image_atlas_owned`, `scene_owned`,
      `layout_owned`).
- [x] `Gooey.deinit` collapses three flag-guarded free blocks into
      one `resources.deinit()` call.
- [x] All four init paths preserved (renamed for clarity in 7b)
      — `runtime/window_context.zig` and
      `runtime/multi_window_app.zig` continue to call them as
      before. No call-site churn this sub-PR.
- [x] `Build Summary: 9/9 steps succeeded; 1057/1057 tests
    passed` (+4 vs. PR 6's 1053 — the four `AppResources`
      ownership-shape tests).
- [x] `zig build install` builds all examples (single-window
      and multi-window) without warnings.

**Implementation notes:**

- **`resources.owned` is disarmed after by-value copy in
  `initOwned`.** The local `var resources = try
AppResources.initOwned(...)` is copied by value into
  `result.resources`. Without flipping `resources.owned = false`
  on the local immediately after the copy, a later `errdefer`
  in the same function (e.g. a `globals.setOwned` failure)
  would tear down the heap pointees out from under the
  successfully-copied `result`. CLAUDE.md §22 ("buffer bleeds")
  framing in spirit — ownership transfer must be explicit at
  the moment of copy.
- **`AppResources.deinit` undefs the three pointers after
  free.** Idempotency on the borrowed shape (`owned = false`
  short-circuits early), but a deliberate use-after-free trap
  on the owned shape — a second `deinit` will read `undefined`
  pointers and trip the field-access asserts on the next
  framework call.
- **Image loader stays per-window.** Today every `Gooey` owns
  its own `ImageLoader` whose `Io.Queue` writes into
  `result_buffer` inside that loader. Moving the loader to
  `App` requires either (a) a shared queue with per-window
  draining (changes the drain semantics in `beginFrame`), or
  (b) per-window loaders pointing at a shared atlas (works but
  duplicates pending/failed sets across windows). The choice
  has UX implications (cache hit-rate across windows) and
  belongs in 7b alongside the `App` rename.
- **Five flags, not six.** `scene_owned` and `layout_owned`
  retired in 7a even though they are not part of
  `AppResources` — the audit
  (`grep -n 'layout_owned = false\|scene_owned = false' src/`)
  returned nothing, so the flags were already dead code. The
  sixth flag is the `image_loader_owned` slot we'd need to
  introduce if the loader moves to `App` in 7b. Net `_owned`
  count after 7a: zero on `Gooey`, one on `AppResources` (the
  bundle's own discriminator).

---

**Sub-PR 7b.1a — `platform.Window → platform.PlatformWindow` (landed):**

First slice of PR 7b. Pure mechanical rename of the public
`platform.Window` alias to `platform.PlatformWindow`, freeing the
`Window` name for the framework-level wrapper landing in 7b.1b. The
GPUI mapping in
[`architectural-cleanup-plan.md` §10](./architectural-cleanup-plan.md#10-the-app--window--contextt-split)
calls the OS-level handle `platform_window: PlatformWindow` for
exactly this reason — the two used to coexist only because nobody
had to talk about both at the same time, and PR 7b makes that
contradiction explicit.

**Write scope (landed):**

- `src/platform/mod.zig` — public alias `Window` → `PlatformWindow`.
- `src/root.zig` — re-export `pub const Window` →
  `pub const PlatformWindow`.
- 11 files across `src/app.zig`, `src/context/gooey.zig`,
  `src/runtime/{runner,multi_window_app,window_context,window_handle}.zig`,
  `src/examples/{linux_demo,glass}.zig`,
  `src/platform/interface.zig` — every `const Window =
platform.Window` import alias renames; every field /
  parameter / cast / test signature that referenced the
  framework-facing alias updates to match.

**Out of scope:**

- The per-OS internal aliases (`platform.macos.window.Window`,
  `platform.linux.window.Window`, `platform/web/window.zig::Window`)
  are untouched. They're internal to each backend and only one
  call site (`cx.zig::setGlassStyle`) reaches in via
  `platform.mac.window.Window`. Renaming them would muddy the PR
  with backend-specific churn for no clarity gain.

**Result:** `Build Summary: 9/9 steps succeeded; 1057/1057 tests
passed` (same count as 7a baseline; pure rename, no test
additions).

---

**Sub-PR 7b.1b — `Gooey → Window` framework wrapper (landed):**

Second mechanical slice. With 7b.1a having freed the `Window`
name, the framework wrapper struct collapses from the project's
working title `Gooey` to its real role: a per-window framework
context. Both
[`architectural-cleanup-plan.md` §10](./architectural-cleanup-plan.md#10-the-app--window--contextt-split)
and the original PR 7 sketch above call this struct `Window`; the
rename brings the code in line with the design docs.

**Write scope (landed):**

- `src/context/gooey.zig` renamed to `src/context/window.zig`.
  `pub const Gooey = struct { ... }` becomes `pub const Window =
struct { ... }`. The `gooey:` / `self.gooey` / `*Gooey` usages
  inside the file get the bulk rename in step.
- The struct's `window: ?*PlatformWindow` field renames to
  `platform_window: ?*PlatformWindow` so `self.window` inside
  `Window` methods isn't a self-reference shadow. The §10 GPUI
  sketch uses the same naming.
- `pub fn getWindow(self) ?*PlatformWindow` on `Window` renames
  to `getPlatformWindow` for the same reason.
- Every `gooey_mod` import alias renames to `window_mod`. Every
  `const Gooey = gooey_mod.Gooey` to
  `const Window = window_mod.Window`. Every
  `@import("gooey.zig")` to `@import("window.zig")`.
- `Cx` field `_gooey: *Gooey` renames to `_window: *Window`.
  `cx.gooey()` accessor renames to `cx.window()`. The
  `pub fn gooey(self: *Self)` declaration on `Cx` renames to
  `pub fn window(self: *Self)`.
- `Builder` field `gooey: ?*Gooey` renames to `window: ?*Window`.
  Every `b.gooey` / `self.gooey` on `Builder` accordingly.
- WASM globals on `app.zig`: `g_gooey: ?*Gooey` renames to
  `g_window: ?*Window`. The pre-existing `g_window:
?*PlatformWindow` (the OS handle global) renames first to
  `g_platform_window` to free the slot — same field-rename
  rationale as inside `Window`.
- `runtime/window_context.zig::init` /
  `initWithSharedResources` had a param `window: *PlatformWindow`
  that collided with the new local `window` (the framework
  wrapper). Renamed those two params (and only those two — the
  `WindowVTable`-shaped callbacks like `onRender` reach the
  framework wrapper through `self.window` so `window` remains
  the platform handle there) to `platform_window`.
- `runtime/frame.zig::updateImeCursorPosition` had a similar
  shadow (`const window = window.getWindow() orelse return`)
  that the bulk rename converted into a self-shadow; rewritten
  to `const platform_window = window.getPlatformWindow() orelse
return`.
- `src/cx.zig::setGlassStyle` and `src/cx.zig::close` had local
  `window` captures that now shadow the new `pub fn window`
  accessor on `Cx`; captures renamed to `pw`.
  `setGlassStyle`'s broken pre-rename `?*Window.ptr` access
  (dead code, never instantiated) fixed to a proper `if (...)
|pw|` unwrap while we were here.

**Out of scope:**

- Banner strings (`Gooey Layout Engine Benchmarks ...`) and
  package-import uses (`const gooey = @import("gooey")`) stay
  as is. The framework brand is still "gooey"; this slice only
  renames the framework wrapper struct.
- Historical doc comments in `context/focus.zig`,
  `context/global.zig`, `context/hover.zig`,
  `context/a11y_system.zig`, `context/cancel_registry.zig`,
  `context/draw_phase.zig` still reference `Gooey` when
  describing the pre-extraction state. They read naturally as
  historical context and are out of scope for the rename; a
  separate doc-touchup pass can polish them.

**Result:** `Build Summary: 9/9 steps succeeded; 1057/1057 tests
passed`. `zig build install` builds all examples (single- and
multi-window) without warnings.

---

**Sub-PR 7b.2 — `multi_window_app::App` embeds `AppResources`
(landed):**

Closes a 7a inconsistency. After PR 7a, the single-window
`Window.init*` paths embed an owning `AppResources` and the
`Window.initWithSharedResources*` paths embed a borrowed view of
some upstream-owned `AppResources`. But the `App` struct in
`src/runtime/multi_window_app.zig` — the actual upstream owner in
the multi-window case — still carried the pre-7a triplet of
separate `*TextSystem` / `*SvgAtlas` / `*ImageAtlas` pointers
built through three parallel allocate-and-init blocks. PR 7b.2
swaps that triplet for one `resources: AppResources` field, so
both ownership shapes now flow through the same struct.

**Why this lands as its own slice:** it has no API surface
change for `App` callers (the `init` / `deinit` / `openWindow`
signatures are unchanged), but the next slices in PR 7b are
about lifting four subsystems off `Window` onto `App`
(`entities`, `keymap`, `globals`, `image_loader`). Those slices
grow new fields on `App` under the `AppResources` / `App`
lifetime split — landing the resource bundle first means each
subsequent slice adds exactly the field it needs, without also
having to reshape the resource-ownership story mid-flight.

**Write scope (landed):**

- `App.text_system: *TextSystem`, `App.svg_atlas: *SvgAtlas`,
  `App.image_atlas: *ImageAtlas` three fields collapse to one
  `resources: AppResources` field. The `AppResources` import
  sits alongside the existing `TextSystem` / `SvgAtlas` /
  `ImageAtlas` imports (kept because some shared-resource
  pass-through still names the pointee types in signatures —
  those go in 7b.6).
- `App.init` replaces the ~30 lines of three parallel
  `allocator.create` / init / errdefer / `loadFont` blocks with
  a single `AppResources.initOwned(allocator, io, 1.0,
font_config)` call plus an `errdefer resources.deinit()`.
  Same precedent as `Window.initOwned` after PR 7a.
- `App.init` disarms the local `resources.owned = false` after
  the by-value copy into `self.resources` so an unwinding
  errdefer in this function doesn't tear the heap pointees down
  out from under the successfully-copied `self`. Carries the
  idiom from `Window.initOwned` verbatim.
- `App.deinit` replaces three flag-guarded free blocks (image
  atlas → svg atlas → text system) with one
  `self.resources.deinit()` call.
- All five internal call sites that reached `self.text_system`
  / `self.svg_atlas` / `self.image_atlas` rewrite to
  `self.resources.text_system` / etc. The three call sites in
  `createWindowContext` that pass these pointers into
  `WinCtx.initWithSharedResources` route through
  `self.resources.*` now; the three-arg call signature is
  preserved here and collapses to a single `*AppResources` arg
  in 7b.6.

**Updated `_owned` count:** zero on `Window`, one on
`Window.resources` (single-window owning shape) **or** zero on
`Window.resources` plus one on `App.resources` (multi-window
shape — `App` owns, every `Window` borrows). The `AppResources`
discriminator is still the only ownership flag in the new
world; just instantiated in two places now that `App` and
`Window` both embed one.

**Result:** `Build Summary: 9/9 steps succeeded; 1057/1057
tests passed`. `zig build install` builds all examples without
warnings.

---

**Sub-PR 7b.3 — Lift `entities: EntityMap` off `Window` onto `App` (landed):**

Third functional slice of PR 7b. Goal: lift the entity map
from per-window storage to application-scope storage so models
can be observed across windows, matching the GPUI mapping in
[`architectural-cleanup-plan.md` §10](./architectural-cleanup-plan.md#10-the-app--window--contextt-split).
Pre-7b.3 each `Window` carried its own `entities: EntityMap`,
which made cross-window observation structurally impossible —
a `Counter` entity created in window A could not be observed
by a view in window B because the two `EntityMap`s were
separate islands of state. Post-7b.3 the map lives on a shared
`App`, and every `Window` borrows `*App` to reach it.

**Why this lands as its own slice:** the lift is small in
mechanical terms (one field move + one borrowed pointer +
forwarder updates), but it introduces the `context.App` struct
that subsequent 7b slices accumulate state on (`keymap` /
`globals` in 7b.4, `image_loader` in 7b.5). Landing the struct
first means each subsequent slice adds one field at a time
without also having to introduce the ownership story.

**Write scope (landed):**

- `src/context/app.zig` (new) — `App` struct with
  `allocator: Allocator`, `io: std.Io`, `entities: EntityMap`.
  Two init shapes (`init` returning by value for embedded use,
  `initInPlace` for heap-allocated single-window use, marked
  `noinline` per CLAUDE.md §14 — consistency with
  `Window.initOwnedPtr` and `AppResources.initOwnedInPlace`,
  even though the current footprint is well under the 50KB
  threshold). Four tests pin the init/deinit shapes and the
  cross-window-share property against `std.testing.allocator`.
- `src/context/mod.zig` — re-exports `App`.
- `src/context/window.zig` —
  - **Drops** `entities: EntityMap` from the field list.
  - **Adds** `app: *App = undefined` borrowed-pointer field.
    Default `undefined` so the `testWindow` fixture and the
    intermediate state between `Window.initOwned` (which
    leaves `app` unset) and the caller's post-init assignment
    keep compiling. Every framework `init*` path is followed
    by an immediate `window.app = app` assignment in the
    caller, before any frame runs.
  - `Window.deinit` no longer calls `entities.deinit` —
    deliberately. The borrowed `*App` is owned upstream and
    freeing the `EntityMap` from `Window.deinit` would be a
    use-after-free in the multi-window case where one `App`
    outlives many windows.
  - `Window.beginFrame` / `endFrame` route through
    `self.app.entities.*` for the per-frame observation
    begin/end pair. With multi-window the call is redundantly
    invoked once per window per tick; `beginFrame` is
    idempotent (re-clearing an empty `frame_observations` is
    a no-op) and `endFrame` is currently a no-op hook.
    Documented in the field comment as forward-looking.
  - The five entity-related forwarder methods (`createEntity`
    / `readEntity` / `writeEntity` /
    `processEntityNotifications` / `getEntities`) all reach
    through `self.app.entities.*`. Call surface is preserved.
- `src/cx/entities.zig` — every `_window.entities.*` access
  rewritten to `_window.app.entities.*` (5 sites).
- `src/runtime/window_context.zig` —
  - `WindowContext.init` and `initWithSharedResources` both
    take a new `app: *App` parameter. Both write
    `window.app = app` immediately after constructing the
    `Window` (before `fixupImageLoadQueue`), so the field is
    non-`undefined` before any code that might reach through
    it runs.
  - `WindowContext` itself stores the borrowed `*App` for
    symmetry, although nothing on `WindowContext` reaches
    through it directly today — every consumer reaches
    through `self.window.app`. Reserved for future plumbing.
  - Pair-asserts `window.app == app` post-init in both paths
    (CLAUDE.md §3).
- `src/runtime/runner.zig` — `runCx` heap-allocates one
  `App` via `try allocator.create(App)` +
  `app_ptr.initInPlace(allocator, io)`, defers
  `app_ptr.deinit()` and `allocator.destroy(app_ptr)` so the
  `App` outlives the `Window`. Passes `app_ptr` to
  `WindowContext.init`.
- `src/runtime/multi_window_app.zig` — `App` (the
  multi-window owner) gains a `context_app: ContextApp` field
  initialised by-value in `App.init`, torn down in
  `App.deinit` after `closeAllWindows` and before
  `resources.deinit`. `createWindowContext` passes
  `&self.context_app` through the
  `WindowContext.initWithSharedResources` signature so every
  per-window `Window` borrows the same `EntityMap`.
- `src/app.zig` (WASM bootstrap) — `WebApp.initImpl`
  heap-allocates a `ContextApp` alongside the existing
  `Window`-on-WASM `initOwnedPtr` path, wires
  `window_ptr.app = app_ptr` immediately after the window
  init completes. New `g_app: ?*ContextApp` global mirrors
  the existing `g_*` pattern in this struct.

**Tasks landed:**

- [x] New `src/context/app.zig` with `App` struct holding
      `allocator` + `io` + `entities`.
- [x] Drop `entities: EntityMap` from `Window`; add
      `app: *App = undefined` borrowed pointer.
- [x] Route every `entities.*` access on `Window` and in
      `cx/entities.zig` through `self.app.entities.*`.
- [x] `WindowContext.init` and
      `WindowContext.initWithSharedResources` take a new
      `app: *App` parameter and wire it onto the freshly-
      constructed `Window`.
- [x] Single-window `runtime/runner.zig` heap-allocates one
      `App` per `runCx` call.
- [x] Multi-window `runtime/multi_window_app.zig::App` embeds
      `context_app: ContextApp` by value and passes
      `&self.context_app` to every window.
- [x] WASM `WebApp.initImpl` heap-allocates a `ContextApp`
      and wires it onto the single window.
- [x] `Build Summary: 9/9 steps succeeded; 1061/1061 tests
    passed` (+4 vs. 1057 — the four new `App` tests).
- [x] `zig build install` builds all examples (single-window
      and multi-window) without warnings.

**Implementation notes:**

- **`Window.deinit` deliberately does NOT touch `self.app`.**
  This is the central ownership invariant of 7b.3: the
  `*App` is borrowed, not owned. Tearing it down from
  `Window.deinit` would be a use-after-free in the
  multi-window case where one `App` services N windows; the
  upstream owner (`runner.zig`'s `defer` chain or
  `multi_window_app.zig::App.deinit`) tears the `App` down
  exactly once, after every `Window.deinit` has run.
- **Order of teardown in
  `multi_window_app.zig::App.deinit`:** `closeAllWindows` →
  `context_app.deinit` → `resources.deinit`. Rationale:
  `EntityMap.deinit` cancels any attached async groups,
  which today are user-driven but in the future may include
  framework-level cancel groups holding pointers into the
  image atlas's pixel buffers (if `ImageLoader` lands on
  `App` in 7b.5). Doing entity teardown before atlas
  teardown means those cancellation paths unwind against
  still-live atlases; the reverse order would risk
  use-after-free.
- **Multi-window `frame_observations` redundancy is
  forward-looking.** With one shared `EntityMap` and N
  windows each calling `entities.beginFrame` / `endFrame`
  per frame, the begin call discards `frame_observations`
  made by previously-rendered windows in the same tick. No
  current code path shares entities across windows (the
  multi-window example doesn't use entities), so the issue
  is documented in the comment but not fixed in 7b.3 — the
  proper fix lands in PR 7c alongside the `Frame`
  double-buffer move, where the per-tick begin/end pair
  becomes app-scoped instead of per-window.
- **`Window.app: *App = undefined` default is intentional.**
  `Window.initOwned` returns by value, leaving `app` unset;
  the caller assigns `window.app = app` immediately after
  the by-value copy lands at its final heap address.
  Threading `app` through `Window.initOwned`'s signature
  would be cleaner but conflicts with the four-init-path
  shape PR 7b.6 already documented as needing collapse —
  doing both reshapings in the same slice would muddy the
  diff. The follow-up 7b slice that collapses the init paths
  to two will thread `app` through the new shared signature
  in step.
- **WASM `g_app` leaks at process exit.** Same lifecycle as
  every other `g_*` global in `WebApp` — the browser tab
  teardown reclaims the entire WASM heap. Documented in the
  new global's comment for the next reader.
- **`context_app` vs. `App` naming.** The runtime
  multi-window owner is already named `App`
  (`multi_window_app.zig::App`); the new context-level
  struct is also `App` (`context/app.zig::App`). Inside
  `multi_window_app.zig` the alias
  `ContextApp = context_app_mod.App` disambiguates them at
  every call site. The `context_app` field name carries the
  disambiguation forward. A future cleanup that renames the
  multi-window `App` to `MultiWindowApp` (matching the
  `runtime.MultiWindowApp` re-export) would let both
  collapse to plain `App`, but that ripples through every
  `multi_window_app::App` call site and is out of scope for
  7b.3.

**Result:** `Build Summary: 9/9 steps succeeded; 1061/1061
tests passed`. `zig build install` builds all examples without
warnings.

---

**Sub-PR 7b.4 — Lift `keymap` and `*const Theme` onto `App.globals` (landed):**

Fourth functional slice of PR 7b. Goal: extend the 7b.3
`entities` lift to `Keymap` and the `*const Theme` slot, both
of which the GPUI mapping in
[`architectural-cleanup-plan.md` §10](./architectural-cleanup-plan.md#10-the-app--window--contextt-split)
puts on `App` rather than `Window`. Pre-7b.4 every
`Window.globals` owned its own `Keymap` (registered identically
in all four `Window.init*` paths) and the `*const Theme` slot
was per-window (a tab swap in window A would not repaint window
B). Post-7b.4 both slots live on `App.globals` and every
`Window` reaches them through its borrowed `*App`.

`Debugger` deliberately stays on `Window.globals`. Audit
confirmed every `Debugger` field — overlay quads, frame timing,
selected layout id, profiler panel state — is bound to a single
scene; sharing one debugger across windows would mix metrics
from two unrelated frames. The split (Keymap + Theme on `App`,
Debugger on `Window`) matches the GPUI sketch verbatim.

**Why this lands as its own slice:** mechanically the lift is
small (one new field on `App`, two `setOwned` calls relocated,
one accessor forwarder, two `Builder` getter/setter rewrites),
but the signature change cascade is non-trivial — `App.init` /
`initInPlace` go from infallible to `!`-returning because
`Globals.setOwned` may fail with `OutOfMemory`, and three
callers (`runtime/runner.zig`, `runtime/multi_window_app.zig`,
`app.zig::WebApp`) had to learn `try`. Landing those changes
in isolation keeps the diff legible and makes the next slice
(7b.5 `image_loader` placement) start from a clean signature
baseline.

**Write scope (landed):**

- `src/context/app.zig` —
  - **Adds** `globals: Globals = .{}` field. `Globals` is the
    PR 6 type-keyed singleton store; here it owns the
    app-scoped `Keymap` and (lazily, via `Builder.setTheme`)
    the `*const Theme` slot.
  - `App.init` / `App.initInPlace` register an owned `Keymap`
    in `globals` via `setOwned` after the `EntityMap` is
    constructed. `Keymap.init` is infallible; `setOwned` may
    fail with `OutOfMemory` (the heap allocation for the
    owned `*Keymap`), which is why both signatures now
    return `!`-types. The error path unwinds through
    `errdefer self.entities.deinit()` so the partial
    `EntityMap` does not leak.
  - `App.deinit` adds a `self.globals.deinit(self.allocator)`
    call after `entities.deinit`. Order rationale:
    `entities.deinit` first means any cancel-group walks
    triggered by entity removal see a still-live `Globals`,
    not a zeroed one. (No entity-attached cancel group today
    reaches into a global, but the reverse direction is not
    yet audited — keeping `entities` first stays safe.)
  - **Adds** `App.keymap()` accessor (panic on missing slot;
    same contract as the pre-7b.4 `Window.keymap()`).
  - Two new tests cover the single-window access and the
    cross-window-share property (one `App` borrowed twice
    sees the same `Keymap` bindings).
- `src/context/window.zig` —
  - **Drops** `Keymap` registration from all four `init*`
    paths (`initOwned` / `initOwnedPtr` /
    `initWithSharedResources` / `initWithSharedResourcesPtr`).
    The `Debugger` registration stays in place. Each path
    used to be:

    ```zig
    try result.globals.setOwned(allocator, Keymap, Keymap.init(allocator));
    errdefer result.globals.deinit(allocator);
    try result.globals.setOwned(allocator, debugger_mod.Debugger, .{});
    ```

    and collapses to:

    ```zig
    try result.globals.setOwned(allocator, debugger_mod.Debugger, .{});
    ```

    The intermediate `errdefer` retired alongside the first
    `try`; the second `try` is the last fallible call before
    `return`, so no `errdefer` is needed (the function
    unwinds through the surrounding allocator-create
    errdefers and the `result.globals.deinit` call inside
    `Window.deinit` if a later caller fails). Documented
    inline in each path.

  - `Window.keymap()` becomes a one-line forwarder:
    `return self.app.keymap();`. Existing call sites
    (`window.keymap().bind(...)` / `.match(...)` in
    `runtime/input.zig` and `examples/actions.zig`) reach
    through unchanged.
  - The `Keymap` import alias on the file survives only
    because the forwarder's return type still names
    `*Keymap`; a follow-up that retires the forwarder once
    enough callers route through `*App` directly can drop
    the alias and the import together.

- `src/ui/builder.zig` — `setTheme` writes to
  `g.app.globals.replaceBorrowedConst(Theme, t)` and `theme()`
  reads from `g.app.globals.getConst(Theme) orelse &Theme.light`.
  The `g.window orelse return &Theme.light` short-circuit
  survives for unit tests that bypass the full framework
  init wiring.
- `src/runtime/runner.zig` — `app_ptr.initInPlace(...)` gains a
  `try`. The pre-existing `defer allocator.destroy(app_ptr)`
  runs even on the error path, so a `setOwned` failure here
  does not leak the `allocator.create(App)` allocation.
- `src/runtime/multi_window_app.zig` —
  `.context_app = ContextApp.init(allocator, io)` becomes
  `.context_app = try ContextApp.init(allocator, io)`. The
  surrounding `errdefer resources.deinit()` unwinds the
  by-value resources copy on failure; the `EntityMap` /
  `Keymap` allocations that `ContextApp.init` would have
  made are torn down inside its own `errdefer` chain before
  this expression unwinds.
- `src/app.zig` — WASM bootstrap
  `app_ptr.initInPlace(...)` gains a `try`. WASM has no
  `defer` analog in the bootstrap, so a failure here leaves
  the `allocator.create(ContextApp)` allocation orphaned
  until the browser tab teardown reclaims the entire WASM
  heap — same lifecycle as every other `g_*` global.

**Tasks landed:**

- [x] Add `globals: Globals = .{}` to `App`.
- [x] Register an owned `Keymap` in `App.init` / `initInPlace`.
- [x] Tear down `globals` in `App.deinit` (after `entities`).
- [x] Add `App.keymap()` accessor with panic-on-missing
      contract.
- [x] Drop `Keymap` registration from all four `Window.init*`
      paths; keep `Debugger`.
- [x] Drop the now-vestigial `errdefer result.globals.deinit`
      after the final `setOwned` in each `Window.init*` path.
- [x] Rewrite `Window.keymap()` as a forwarder to
      `self.app.keymap()`.
- [x] Route `Builder.setTheme` / `Builder.theme` through
      `window.app.globals` instead of `window.globals`.
- [x] `runtime/runner.zig`, `runtime/multi_window_app.zig`,
      `app.zig::WebApp` learn `try` for the new `App.init*`
      signatures.
- [x] `Build Summary: 9/9 steps succeeded; 1063/1063 tests
    passed` (+2 vs. PR 7b.3's 1061 — the two new
      `App.keymap()` tests covering single-window access and
      the cross-window-share property).
- [x] `zig build install` builds all examples (single-window
      and multi-window) without warnings.

**Implementation notes:**

- **Theme slot ownership shape.** `Theme` is registered via
  `replaceBorrowedConst`, not `setOwned` — callers pass
  `&Theme.dark` from static storage, and the registry never
  frees it. The slot lives at `App.globals` lifetime; since
  `App.deinit` calls `globals.deinit` which is a no-op for
  `borrowed_const` entries, the static storage outlives the
  `App` and there is nothing to tear down. Pre-7b.4 the same
  shape lived on `Window.globals`; the lift is mechanical.
- **Forwarder vs. direct `*App` access.** `Window.keymap()`
  stays as a forwarder rather than retired in favour of
  `cx.app().keymap()` because the call surface that reads
  the keymap (`runtime/input.zig`, `examples/actions.zig`)
  is framework-internal and already reaches through
  `Window`. Retiring the forwarder would force a sweep
  across these call sites for no clarity gain in this
  slice; a future cleanup that introduces `Cx.app()` and
  reroutes user-facing call sites can drop the forwarder
  in step.
- **`init` errdefer ordering.** `App.init` orders the
  `errdefer` chain as: `entities` (allocated first) →
  `globals` (allocated second). On a `setOwned` failure,
  `entities.deinit` runs and the partial `globals` (still
  empty) needs no teardown. On any later failure,
  `globals.deinit` runs first, then `entities.deinit` — the
  registered `Keymap` is torn down via the registry's thunk
  before the entity map. The order matches the
  forward-ordered teardown in `App.deinit`, which is
  unusual (usually `errdefer` reverses construction order)
  but documented inline — `EntityMap` must outlive
  `Globals` for the same cancel-walk reason called out in
  the file header.
- **Signature change cascade was contained.** Three call
  sites added `try` for the new `App.init*` shapes
  (`runner.zig`, `multi_window_app.zig`, `app.zig`). No
  user examples reach the signatures directly — every
  example goes through `runCx` or `App.openWindow`, which
  absorb the `!`-return. The change is API-neutral from a
  user perspective.
- **`Window.testWindow` fixture stays valid.** The
  deferred-command and `DrawPhase` tests use a stub
  `Window` with `app: undefined`. None of those tests
  reaches `keymap()` or `theme()`, so the fact that the
  forwarder would panic on `undefined` `app` is moot.
  Tests that exercise the real `App.keymap()` accessor
  live on `App` itself (in `app.zig`).

**Result:** `Build Summary: 9/9 steps succeeded; 1063/1063
tests passed`. `zig build install` builds all examples without
warnings.

---

**Sub-PR 7b.6 — Retire `AppResources` back-compat aliases (landed):**

Closes the back-compat shim that PR 7a stood up to keep the
~28 internal call sites of `window.text_system` /
`window.svg_atlas` / `window.image_atlas` working across the
bundle extraction. With `AppResources` proven (PR 7a + 7b.2),
the alias fields are pure surface duplication of
`window.resources.*` and were retired wholesale. Goal: shrink
`Window`'s field list, eliminate the duplicate pointer storage,
and collapse the shared-resources `init*` parameter shape to
one `*const AppResources` argument so the bundle stays bundled
across the full `App → WindowContext → Window` call chain.

**Write scope (landed):**

- `src/context/window.zig` — drops the three back-compat alias
  fields (`text_system: *TextSystem` / `svg_atlas: *SvgAtlas` /
  `image_atlas: *ImageAtlas`), removes their assignments from
  `initOwned` / `initOwnedPtr` / `initWithSharedResources` /
  `initWithSharedResourcesPtr` and the `testWindow` fixture,
  rewrites the file's own self-references (`self.text_system`
  in `setFont` / `getTextSystem`, `self.image_atlas.*.beginFrame`
  in `beginFrame`) to reach through `self.resources.*`. Both
  `initWithSharedResources` and `initWithSharedResourcesPtr`
  collapse to take a single `shared_resources: *const AppResources`
  parameter; the per-pointer null assertions become per-bundle-slot
  assertions through that pointer. The bundle is wrapped in
  `AppResources.borrowed(...)` at the bottom of each function,
  same as before — only the parameter shape changes.
- `src/runtime/window_context.zig` — `initWithSharedResources`
  collapses likewise; new `app_resources_mod` import. Reach
  through `self.window.resources.*` for the four `setupWindow`
  / `*UploadCallback` call sites. The `TextSystem` / `SvgAtlas`
  / `ImageAtlas` type-alias imports survive because they're
  still named in the macOS thread-safe upload-callback signatures
  (`uploadTextAtlasLocked` / `uploadSvgAtlasLocked` /
  `uploadImageAtlasLocked`) and the `@ptrCast(@alignCast(ctx))`
  pattern needs the named types.
- `src/runtime/multi_window_app.zig` — `createWindowContext`
  passes `&self.resources` directly. Pre-7b.6 it unbundled the
  three pointers out of `self.resources.*` only for
  `Window.initWithSharedResources` to rebundle them inside
  `AppResources.borrowed(...)` two layers down — pure ceremony
  the collapsed signature retires. The orphaned `TextSystem` /
  `SvgAtlas` / `ImageAtlas` type-alias imports drop with the
  call site; every remaining reference in this file is
  value-level via `self.resources.*`.
- `src/runtime/frame.zig` — 8 call sites (`window.text_system` /
  `window.svg_atlas`) rewritten to `window.resources.*`.
- `src/runtime/render.zig` — 8 call sites
  (`window_ctx.text_system` / `window_ctx.svg_atlas` /
  `window_ctx.image_atlas`) rewritten likewise.
- `src/ui/builder.zig` — 3 call sites (`g.text_system.getMetrics`
  inside `renderInput` / `renderTextArea` / `renderCodeEditor`)
  rewritten to `g.resources.text_system.getMetrics`.
- `src/app.zig` — 5 WASM call sites in `WebApp.initImpl` and
  `WebApp.frame` (`g_window.?.text_system` / `svg_atlas` /
  `image_atlas`) rewritten to `g_window.?.resources.*`.

**Tasks landed:**

- [x] Migrate every internal `window.text_system` /
      `window.svg_atlas` / `window.image_atlas` call site
      (~28 in framework code; user examples never reached the
      aliases) to `window.resources.*`.
- [x] Drop the three back-compat alias fields from `Window`'s
      field list and every assignment in the four `init*` paths
      plus the `testWindow` fixture.
- [x] Collapse `Window.initWithSharedResources` /
      `initWithSharedResourcesPtr` and
      `WindowContext.initWithSharedResources` to take a single
      `*const AppResources` parameter.
- [x] Rewrite `multi_window_app::App.createWindowContext` to
      pass `&self.resources` directly. Drop now-orphaned
      type-alias imports.
- [x] `Build Summary: 9/9 steps succeeded; 1057/1057 tests
    passed` (same count as 7a/7b.1a/7b.1b/7b.2 baseline; this
      sub-PR adds no new tests — it's a pure surface-area
      reduction and the existing 1057 tests already cover every
      code path that crosses the rewritten boundary).
- [x] `zig build install` builds all examples (single-window
      and multi-window) without warnings.

**Implementation notes:**

- **Alias retirement was lossless.** Every alias field on
  `Window` was assigned exactly once (during init, from the
  same heap address `resources.*` pointed at) and never
  mutated thereafter. The pre-7b.6 aliases were structurally
  pure duplicates — the same pointer reachable via two paths.
  Dropping them removes the second path; no assertion or
  pointer-equality invariant on the framework side was
  relying on the duplication. The audit grepped every
  `\.text_system\b` / `\.svg_atlas\b` / `\.image_atlas\b`
  reference outside `app_resources.zig` and confirmed they
  all routed to either (a) the now-renamed `window.resources.*`
  field, (b) `DrawContext.text_system` on `ui/canvas.zig`
  (an unrelated optional field on a different struct), or
  (c) the per-OS internal `svg_atlas` / `image_atlas` fields
  on `platform/macos/window.zig` and `platform/linux/window.zig`
  (the GPU-upload pointers set by `setSvgAtlas` /
  `setImageAtlas`, again on a different struct).
- **Why the count was 28, not 124.** The pre-flight estimate
  in the 7a / 7b.2 landing notes anticipated ~124 sites
  because the doc author was extrapolating from the broader
  `gooey.*` field-access surface (the pre-7b.1b name).
  After the `Gooey → Window` rename in 7b.1b the actual
  aliased-field surface narrowed to the rendering-callback
  paths in `runtime/`, the WASM bootstrap in `app.zig`, and
  three `getMetrics` calls in `ui/builder.zig`. User examples
  reach the framework through `Cx`, not through the framework
  `Window` directly, so the alias retirement didn't ripple
  out to `examples/`.
- **Signature collapse keeps the bundle bundled.** The
  pre-7b.6 chain `App.createWindowContext →
WindowContext.initWithSharedResources →
Window.initWithSharedResources` unbundled
  `self.resources.{text_system, svg_atlas, image_atlas}` at
  the top, threaded the three pointers as separate
  parameters through two function boundaries, and rebundled
  them via `AppResources.borrowed(...)` inside the third —
  three unbundle/rebundle ceremonies that produced the same
  `AppResources` shape on both ends. Post-7b.6, the bundle
  is the parameter; the only construction is the
  `borrowed(...)` wrap inside `Window` to flip `owned` to
  `false`. This also aligns the call-chain with how
  `App.openWindow` already reasons about lifetime — the
  bundle is the unit of ownership on `App`, and now the
  unit of ownership on the wire too.
- **Four `init*` paths still survive 7b.6.** The
  shared-resources arms now share a parameter shape, but
  there are still four named entry points on `Window`
  (`initOwned` / `initOwnedPtr` / `initWithSharedResources` /
  `initWithSharedResourcesPtr`). The pre-7a plan in PR 7's
  goal section called for collapsing toward two; that
  collapse requires a real `App` struct in the single-window
  flow (so `runtime/runner.zig` can build an owning
  `AppResources` once and hand `*AppResources` to the lone
  `Window` via the same shared path), which lands in a
  later 7b slice alongside the entity / keymap /
  image-loader lifts.

**Result:** `Build Summary: 9/9 steps succeeded; 1057/1057
tests passed`. `zig build install` builds all examples without
warnings.

---

**Sub-PR 7b.5 — Lift `image_loader` onto `App` (landed):**

Fifth functional slice of PR 7b. Goal: lift the URL fetch +
decode + atlas-cache subsystem (`ImageLoader`) off `Window` and
onto `App`, finishing the GPUI mapping in
[`architectural-cleanup-plan.md` §10](./architectural-cleanup-plan.md#10-the-app--window--contextt-split)
for `entities` (7b.3), `keymap` / `*const Theme` (7b.4), and
now `image_loader`. Pre-7b.5 every per-window `Window` carried
its own `ImageLoader` whose pending and failed sets, fetch
group, and result queue were per-window islands — so the same
URL requested by two windows in the same frame would each
launch a background fetch, each spend a `MAX_PENDING_IMAGE_LOADS`
slot, and each write into the (already shared) `ImageAtlas`,
producing duplicate bandwidth + a small atlas race window
where two writers contend on the same key.

Post-7b.5 the loader lives once per `App`. Pending and failed
sets are app-scoped (the cross-window dedup property the lift
unlocks). The fetch group's lifetime envelope covers every
window (so cancelling the group in `App.deinit` unwinds every
in-flight fetch in one pass, regardless of which window
launched it). The `MAX_PENDING_IMAGE_LOADS` cap (64) is now a
real app-wide ceiling rather than a per-window one — a
behavioural change worth flagging: an app with 8 windows each
loading 8 distinct URLs concurrently used to share 8×64=512
slots and now shares 64. The cap was already per-app in
spirit (the framework only opens a small number of windows
in practice), but the lift makes it formal.

**Why this lands as its own slice:** the choice between (a)
shared queue with per-window draining and (b) per-window
loaders pointing at the shared atlas has UX implications
(cross-window cache hit-rate vs. drain semantics), and
flagging that decision in the original PR 7 outline meant
landing it discretely rather than folding it into 7b.4 or
7b.6. Option (a) won — see "Implementation notes" below for
the reasoning.

**Pre-flight choice (option a vs. b):**

- **Option (a) — shared loader on `App`** (chosen). Pending /
  failed sets are app-scoped → best cross-window cache-hit
  rate. The hard cap on in-flight loads becomes app-wide.
  Aligns with the GPUI mapping where async I/O is
  app-scoped. Drain semantics: any window calling `drain`
  empties the queue for all windows; results land in the
  next atlas pass on whichever window happens to draw
  first. Acceptable because the atlas itself is already
  shared post-7b.2 — a result drained by window A and
  rendered by window B sees the same heap pixels either
  way.
- **Option (b) — per-window loaders pointing at shared
  atlas** (rejected). Preserves drain locality (each window
  drains its own queue) but duplicates pending / failed
  bookkeeping across windows, which is the property the
  lift was supposed to fix. The drain-locality benefit is
  moot — background fetch tasks already cross window
  boundaries freely; the queue is the only thread-crossing
  primitive, and one queue serving N windows is
  structurally simpler than N queues whose results are
  demultiplexed by window identity (no current code path
  even tracks "which window asked").

**Two-phase init — the atlas-binding wrinkle:**

The loader needs an `*ImageAtlas` at `initInPlace` time, but
the atlas lives on `AppResources`, which is constructed
_after_ `App.init` on the single-window path
(`Window.initOwned` creates the owning `AppResources`) and
_before_ `App.init` on the multi-window path
(`multi_window_app::App.init` creates `self.resources`
first, then `self.context_app = ContextApp.init(...)`
embeds the `context.App` by value). Threading
`*ImageAtlas` through `App.init`'s signature would force
`multi_window_app` to reorder its field-init order (so
`context_app` could pass `self.resources.image_atlas` to
`init`, which is awkward because both are siblings in one
struct literal) and force the single-window runner to
construct a `Window` before the `App` it borrows.

Instead `App` exposes a two-phase init:

1. `App.init` / `App.initInPlace` allocate the entity map,
   register the `Keymap` global, and leave `image_loader`
   undefined. A new `image_loader_bound: bool` flag
   (default `false`) tracks the second-phase state.
2. `App.bindImageLoader(*ImageAtlas)` runs `initInPlace`
   on the loader at the `App`'s final heap address. `App`
   is always heap-allocated (single-window) or embedded
   by-value inside a heap-allocated parent (multi-window)
   by every framework caller, so `&self.image_loader` is
   already at its final address — no by-value copy will
   follow this call, and the embedded `Io.Queue`'s
   pointer to `&self.image_loader.result_buffer` cannot
   dangle. The pre-7b.5 `Window.fixupImageLoadQueue`
   dance retired alongside the field.

`bindImageLoader` is idempotent on same-atlas re-binds:
the first window opened in this `App` performs the actual
bind; every subsequent window (multi-window only) hits
the same-atlas short-circuit because every borrowed
`AppResources` in this `App`'s lifetime points at the
same upstream-owned `ImageAtlas`. A different atlas
pointer trips a hard assertion (a framework bug — the
caller has confused itself about which `App` it is
binding, or the parent rebuilt `AppResources`
mid-lifetime). The idempotency means both
`WindowContext.init` and
`WindowContext.initWithSharedResources` can call
`app.bindImageLoader(...)` unconditionally, without
needing a "bind-if-unbound" decision tree at the call
site.

**Write scope (landed):**

- `src/context/app.zig` —
  - **Adds** `image_loader: ImageLoader = undefined` and
    `image_loader_bound: bool = false` fields. The flag
    serves both as the deinit guard (so test fixtures
    that construct `App`s without binding can still tear
    them down cleanly) and as the same-atlas
    short-circuit sentinel for `bindImageLoader`.
  - **Adds** `App.bindImageLoader(*ImageAtlas)`.
    Idempotent on same-atlas re-binds (asserts pointer
    equality); runs `ImageLoader.initInPlace` once.
    Pair-asserts the loader's pending / failed counts
    are zero post-bind.
  - `App.init` / `App.initInPlace` no longer change
    semantics for the loader — they leave it undefined,
    and pair-assert `!image_loader_bound` post-init.
  - `App.deinit` rewrote teardown order to:
    1. `image_loader.deinit` (guarded by
       `image_loader_bound`) — closes the result queue,
       cancels the fetch group. In-flight fetches see
       queue closure on next put and cancel-point checks
       unwind cleanly.
    2. `entities.deinit` (was first pre-7b.5; demoted
       because the loader teardown must run while the
       atlas is still live, and the atlas is
       upstream-owned on `AppResources` which is torn
       down _after_ `App.deinit` returns).
    3. `globals.deinit` (Keymap, etc.).
  - Three new tests: bind path against a real
    `ImageAtlas`, unbound-deinit safety (test fixtures
    rely on this), and the cross-window-share property
    exercised through two `*App` borrows of the same
    backing struct.
- `src/context/window.zig` —
  - **Drops** `image_loader: ImageLoader` field.
  - **Drops** `Window.fixupImageLoadQueue` forwarder
    (`App.bindImageLoader` runs `initInPlace` at the
    loader's final heap address; no by-value-copy queue
    dangle is possible on the new path).
  - **Reroutes** `Window.isImageLoadPending` and
    `Window.isImageLoadFailed` forwarders through
    `self.app.image_loader.*`. Forwarder-not-direct-access
    keeps the call surface in `runtime/render.zig`
    unchanged for this slice; a follow-up cleanup can
    retire the forwarders once enough callers reach
    through `window.app` directly.
  - **Drops** `self.image_loader.deinit()` from
    `Window.deinit` (handed off to `App.deinit`).
  - **Drops** `.image_loader = undefined` slot from all
    four `init*` paths' struct literals plus the
    `testWindow` fixture. **Drops** the
    `result.image_loader.initInPlace(...)` /
    `self.image_loader.initInPlace(...)` calls in all
    four init paths (handed off to
    `App.bindImageLoader`).
  - **Reroutes** `Window.beginFrame`'s drain to
    `self.app.image_loader.drain()`. Multi-window
    redundancy (N windows each driving drain per tick)
    documented inline alongside the matching
    `entities.beginFrame` redundancy from PR 7b.3 — both
    retire in PR 7c when the per-tick begin/end pair
    moves to app-scope.
- `src/runtime/window_context.zig` —
  - `WindowContext.init` (single-window) drops
    `window.fixupImageLoadQueue()` after
    `window.app = app`; **adds**
    `app.bindImageLoader(window.resources.image_atlas)`
    in its place. `Window.initOwned` creates the owning
    `AppResources` (and the backing `ImageAtlas`) on
    this path, so this is the first moment a stable
    `*ImageAtlas` is available.
  - `WindowContext.initWithSharedResources`
    (multi-window) drops
    `window.fixupImageLoadQueue()`; **adds**
    `app.bindImageLoader(shared_resources.image_atlas)`.
    The first window opened in an `App` performs the
    actual `initInPlace` here; subsequent windows hit
    the same-atlas short-circuit.
- `src/app.zig` (WASM bootstrap) —
  - `WebApp.initImpl` adds
    `app_ptr.bindImageLoader(window_ptr.resources.image_atlas)`
    after `window_ptr.app = app_ptr`. Mirrors the
    single-window native path.
- `src/runtime/render.zig` —
  - `ensureNativeUrlLoading` rewrites
    `window_ctx.image_loader.enqueueIfRoom(...)` to
    `window_ctx.app.image_loader.enqueueIfRoom(...)`
    with a pair-assertion on
    `window_ctx.app.image_loader_bound` so a missing
    `App.bindImageLoader` call surfaces at the first
    place the loader's queue is touched.
- `src/image/loader.zig` —
  - `fixupQueue` itself stays — it remains a useful
    primitive for any future caller that needs by-value
    `ImageLoader` construction. Test comment updated to
    reflect that `Window.initOwned` no longer drives
    this pattern post-7b.5.

**Tasks landed:**

- [x] Add `image_loader: ImageLoader = undefined` and
      `image_loader_bound: bool = false` fields to `App`.
- [x] Add `App.bindImageLoader(*ImageAtlas)` with
      idempotent same-atlas semantics + single-bind
      assertion on different-atlas re-binds.
- [x] Rewrite `App.deinit` order to tear the loader
      down first (while the atlas is still live), then
      entities, then globals.
- [x] Drop `image_loader` field, `fixupImageLoadQueue`
      forwarder, and the `init*` / `deinit` /
      `beginFrame` / `testWindow` references on
      `Window`. Reroute `isImageLoadPending` /
      `isImageLoadFailed` through
      `self.app.image_loader.*`.
- [x] Reroute `Window.beginFrame`'s drain to
      `self.app.image_loader.drain()`.
- [x] Bind via `app.bindImageLoader(...)` from
      `WindowContext.init`,
      `WindowContext.initWithSharedResources`, and
      `WebApp.initImpl`.
- [x] Reroute
      `runtime/render.zig::ensureNativeUrlLoading`
      through `window_ctx.app.image_loader` with a
      pair-assertion on `image_loader_bound`.
- [x] Update the `fixupQueue` test comment in
      `image/loader.zig` to reflect the post-7b.5
      state.
- [x] `Build Summary: 9/9 steps succeeded; 1066/1066
    tests passed` (+3 vs. PR 7b.4's 1063 — three new
      `App` tests covering single-bind,
      unbound-deinit safety, and the
      cross-window-share property).
- [x] `zig build install` builds all examples
      (single-window and multi-window) without
      warnings.

**Implementation notes:**

- **Idempotency over single-bind.** An earlier draft of
  `bindImageLoader` enforced strict single-bind via
  `assert(!image_loader_bound)`. That worked for the
  single-window path (one window, one bind) but forced
  an asymmetric design on the multi-window path where
  the parent `multi_window_app::App.init` would have
  had to bind directly — which conflicts with the
  by-value return shape of `multi_window_app::App.init`
  (the loader's queue would dangle after the by-value
  copy into the caller's storage, requiring a
  `fixupQueue` call exactly like the pre-7b.5
  `Window.fixupImageLoadQueue`). The idempotent
  same-atlas variant lets every window's
  `WindowContext.init*` drive the bind unconditionally;
  the first window does the work, the rest
  short-circuit. This keeps the bind site in the call
  chain symmetric across single-window and
  multi-window flows.
- **`App.deinit` order swap is load-bearing.** Pre-7b.5
  `App.deinit` ran `entities.deinit` then
  `globals.deinit`. Post-7b.5 `image_loader.deinit`
  jumps to the front of the line. Rationale:
  cancelling the fetch group blocks until in-flight
  fetch tasks complete their current cancel-point
  check; those tasks may be mid-write into the shared
  `ImageAtlas` (via `cacheRgba` inside
  `ImageLoader.drain`, but also conceivably via
  direct `image_atlas.cacheImage` calls from a future
  eviction-re-fetch path). The atlas is upstream-owned
  on `AppResources` and torn down _after_ `App.deinit`
  returns, so loader-first ordering means the atlas
  is guaranteed live during cancellation. Pre-7b.5
  the pre-existing `Window.deinit` did
  `image_loader.deinit` first for the same reason;
  the lift preserves the invariant, just at a
  different scope.
- **Atlas pointer equality is the bind-correctness
  predicate.** `bindImageLoader`'s same-atlas
  short-circuit asserts
  `self.image_loader.image_atlas == image_atlas`. A
  different pointer would mean either (a) the caller
  mixed up `App` instances (e.g. handed
  `multi_window_app::App.context_app` a window's
  borrowed `AppResources` from a _different_ parent),
  or (b) the parent rebuilt `AppResources`
  mid-lifetime (which the framework does not do today
  and would invalidate every borrowing window's
  `resources` field anyway). Both are
  framework-internal bugs; the panic surfaces them at
  the bind site rather than letting an in-flight
  fetch land in the wrong atlas.
- **Drain redundancy across windows.** With one
  shared loader and N windows each calling
  `app.image_loader.drain()` from
  `Window.beginFrame`, the first window's drain
  empties the queue and subsequent calls in the same
  tick get 0 results. The decoded pixels land in the
  atlas during whichever window's drain happened
  first; rendering in any later-drawing window in
  the same tick sees the cached result. No artefact
  is visible to the user — the atlas is shared and
  the pixel data is identical regardless of which
  window's drain wrote it. The redundancy is wasted
  CPU (an empty queue lookup per extra window per
  tick); PR 7c (`Frame` double-buffer) retires it by
  moving the per-tick begin/end pair to app-scope.
- **WASM bootstrap mirrors the single-window native
  path.** `app.zig::WebApp.initImpl` heap-allocates
  one `App` (already in PR 7b.3) and one `Window`
  (already via `initOwnedPtr`); 7b.5 adds one
  `app_ptr.bindImageLoader(window_ptr.resources.image_atlas)`
  call after `window_ptr.app = app_ptr`. The
  WASM-vs-native split is structural rather than
  behavioural — both bind exactly once per `App`
  lifetime against the single window's atlas. The
  `g_app` global retains its pre-7b.5 lifecycle
  (leaks at process exit; browser tab teardown
  reclaims the WASM heap).
- **Forwarder retention on `Window`.**
  `isImageLoadPending` and `isImageLoadFailed` stay
  as forwarders on `Window` rather than retiring in
  favour of `cx.app().image_loader.*` because the
  call surface that reads them
  (`runtime/render.zig`) is framework-internal and
  already reaches through `Window`. Retiring the
  forwarders would force a sweep across the call
  sites for no clarity gain in this slice; a future
  cleanup that introduces `Cx.app()` and reroutes
  user-facing call sites can drop the forwarders in
  step. Same precedent as `Window.keymap()` in
  PR 7b.4.
- **`fixupQueue` retention on `ImageLoader`.** The
  primitive on `ImageLoader` itself stays — it
  remains useful for any future caller that needs
  by-value construction (e.g. a unit test that
  builds a loader on the stack and copies to heap).
  The retirement was of the
  `Window.fixupImageLoadQueue` _forwarder_, not the
  underlying primitive. The test
  `ImageLoader: fixupQueue restores the queue
pointer after a copy` continues to pin the
  primitive's contract.

**Result:** `Build Summary: 9/9 steps succeeded;
1066/1066 tests passed`. `zig build install` builds
all examples (single-window and multi-window)
without warnings.

---

**Sub-PR 7c.1 — Lift per-tick app-scoped work onto `App` (landed):**

First slice of PR 7c. Goal: get the API layering for
per-tick app-scoped work right before the larger `Frame`
double-buffer move that follows. Pre-7c.1
`Window.beginFrame` / `endFrame` ran
`self.app.image_loader.drain()` and
`self.app.entities.beginFrame()` / `endFrame()` inline —
two structural problems:

1. **Redundancy across N windows borrowing one `App`.**
   With N windows, the work runs N times per tick.
   `image_loader.drain` is idempotent (a second call gets
   0 results because the queue was emptied by the first),
   but `entities.beginFrame` is NOT — a window-A-render-
   then-window-B-begin sequence discards window-A's
   frame observations made earlier in the same tick.
   This was flagged as forward-looking debt in 7b.3
   ("the per-tick begin/end pair moves to app-scope in
   PR 7c") and 7b.5 ("PR 7c retires the drain
   redundancy"), with no current code path triggering
   the bug today (no example shares entities across
   windows), but the structural correctness gap was
   real.
2. **API layering wrong.** App-scoped work reached
   through a per-window forwarder rather than belonging
   to the `App` that owns the underlying state. The
   forwarder shape was a hold-over from pre-7b.3 when
   `entities` and `image_loader` lived on `Window`; once
   the lifts landed (7b.3 / 7b.5) the forwarder ceremony
   was vestigial.

**Why this lands as its own slice:** the actual "call once
per tick at the runtime layer" fix requires a runtime tick
driver — there is no centralised "all windows for this
tick" hook today; each window's render callback is
invoked independently by the platform. Building the tick
driver is non-trivial (needs to coordinate with
`Platform.run`'s event loop on each backend). Landing the
API surface first (7c.1) means the follow-up 7c slice only
has to relocate one method call from `Window.beginFrame`
to the new tick driver — no unbundling of inline work
along the way.

**Pre-flight choice (one method or two):**

- **Option (a) — `App.beginFrame()` + `App.endFrame()`
  pair** (chosen). Mirrors the `Window.beginFrame` /
  `endFrame` shape so the forwarder routes cleanly through
  both halves; gives `EntityMap.endFrame` a symmetric hook
  (currently a no-op, but reserved for future batching
  optimisations). The pair makes the per-tick lifecycle
  explicit at the `App` layer.
- **Option (b) — `App.tick()` single method** (rejected).
  Smaller surface, but conflates "begin tick" and "end
  tick" into one call. The 7c.3 `Frame` double-buffer move
  needs to do work between begin (clear `next_frame`) and
  end (`mem.swap` rendered ↔ next), so a single `tick()`
  would have to split anyway — landing the split now means
  7c.3 doesn't reshape the API again.

**Write scope (landed):**

- `src/context/app.zig` —
  - **Adds** `App.beginFrame()`. Drains
    `self.image_loader` if `image_loader_bound` is true
    (test fixtures construct `App` instances that never
    bind a loader; the guard skips the drain there to
    avoid walking undefined memory). Calls
    `self.entities.beginFrame()` to clear stale frame
    observations from the previous tick. Pair-asserts
    `@intFromPtr(self) != 0` on entry.
  - **Adds** `App.endFrame()`. Calls
    `self.entities.endFrame()` (currently a no-op hook on
    `EntityMap`). Symmetric placeholder for future
    batching work; the call stays for layering
    consistency so future hooks don't silently skip the
    app.
  - Three new tests pin the contract: stale-observation
    clearing on begin, unbound-loader safety (test
    fixtures), and bound-loader drain on a real
    `ImageAtlas` (no fetches enqueued, so drain is a
    0-result no-op — the test pins that the call reaches
    through to the loader instead of silently skipping
    when bound).
- `src/context/window.zig` —
  - `Window.beginFrame()` replaces the inline
    `self.app.image_loader.drain()` +
    `self.app.entities.beginFrame()` pair with a single
    `self.app.beginFrame()` call. Order constraints
    preserved (drain must run after
    `self.resources.image_atlas.beginFrame()` so
    freshly-decoded pixels write into the post-reset
    atlas; entity-observation clear must run before any
    element renders this frame).
  - `Window.endFrame()` replaces inline
    `self.app.entities.endFrame()` with
    `self.app.endFrame()`.
  - Both forwarder routes preserve the pre-7c.1
    behaviour exactly — single-window flows have one
    window per `App`, so the forwarder still drives the
    work once per tick. Multi-window flows still drive
    it per-window-per-tick (the redundancy is
    structurally unchanged at this slice); 7c.2
    relocates the call out of the per-window path.

**Tasks landed:**

- [x] Add `App.beginFrame()` doing the loader drain
      (guarded by `image_loader_bound`) + entity-
      observation clear.
- [x] Add `App.endFrame()` as a symmetric no-op
      placeholder calling `entities.endFrame()`.
- [x] Reroute `Window.beginFrame()` / `Window.endFrame()`
      through the new methods.
- [x] Three new tests covering stale-observation
      clearing, unbound-loader safety, and bound-loader
      drain.
- [x] `Build Summary: 9/9 steps succeeded; 1069/1069
    tests passed` (+3 vs. PR 7b.5's 1066).
- [x] `zig build install` builds all examples
      (single-window and multi-window) without warnings.

**Implementation notes:**

- **`image_loader_bound` guard is essential, not
  optional.** Test fixtures in `app.zig` (the four
  pre-7c.1 tests plus the three new ones) construct `App`
  instances against `testing.allocator` / `undefined` IO
  without ever calling `bindImageLoader`. A bound check
  inside `App.beginFrame` was the path of least
  resistance — the alternative (forcing every test to
  construct a real `ImageAtlas`) would balloon the test
  setup and require pinning
  `Io.Threaded.global_single_threaded` through every
  `App: ...` test that today uses `undefined`. The guard
  is a 3-line `if`; the alternative is a ~20-line setup
  boilerplate per test. Production framework code paths
  always bind before the first frame, so the guard is
  moot in production.
- **Order inside `App.beginFrame` is load-bearing.**
  Loader drain runs _first_ — `EntityMap.beginFrame`
  walks `frame_observations` and calls `unobserve`, which
  only touches entity slots. If a future pipeline lands
  entity-attached image fetches (a view entity that owns
  an in-flight URL fetch), the drain would write into
  the atlas before the entity slot's cancel walk; if the
  order were reversed, the cancel walk could free the
  atlas pixels that the drain is about to write. Today
  no such pipeline exists, but the forward-safe order is
  free.
- **`endFrame` symmetric placeholder rather than no-op
  call site.** `EntityMap.endFrame` is itself a no-op
  (frame observations are registered eagerly via
  `observe()` in `read`); calling it through
  `App.endFrame` is a redundant indirection today. The
  call stays because (a) the symmetry with
  `App.beginFrame` makes the per-tick lifecycle explicit
  at the API layer, and (b) future batching
  optimisations the `EntityMap.endFrame` hook is
  reserved for would otherwise silently skip the `App`
  if 7c.1 had elided the call. Cost is one function
  call per tick; benefit is a one-line change in
  `EntityMap.endFrame` lands without touching `App` or
  `Window`.
- **Multi-window redundancy still present at this
  slice.** With N windows borrowing one `App`,
  `Window.beginFrame` is called N times per tick and
  routes through `App.beginFrame` N times. The
  `image_loader.drain` is idempotent (acceptable); the
  `entities.beginFrame` clear is NOT — the pre-7c.1
  redundancy survives 7c.1 unchanged. Fixing it requires
  lifting the call to a once-per-tick driver at the
  runtime layer (7c.2), which needs platform-specific
  tick coordination. 7c.1's contribution is the API
  surface; 7c.2's is the relocation.
- **Forward compatibility with `Frame` double-buffer.**
  When 7c.3 introduces the `Frame` struct + `mem.swap`,
  `App.beginFrame` is the natural place to clear
  `next_frame` and `App.endFrame` is the natural place
  to swap rendered ↔ next. Landing the pair now means
  7c.3 can hang work off both methods without reshaping
  the API surface again.

**Result:** `Build Summary: 9/9 steps succeeded; 1069/1069
tests passed`. `zig build install` builds all examples
(single-window and multi-window) without warnings.

---

**Sub-PR 7c.2 — Hoist `App.beginFrame` / `App.endFrame`
out of `Window` into the runtime frame driver (landed):**

Second slice of PR 7c. Goal: get the app-scoped per-tick
begin/end pair off `Window` and onto the layer that owns
the `App`. 7c.1 introduced the API surface
(`App.beginFrame` / `App.endFrame`) and routed
`Window.beginFrame` / `Window.endFrame` through it; 7c.2
finishes the relocation by calling the pair directly from
`runtime/frame.zig::renderFrameImpl` (the per-window
render callback the platform layer dispatches) and
removing the inline calls from `Window.beginFrame` /
`Window.endFrame`.

**Why this lands as its own slice:** 7c.1 deliberately
landed the API surface first so the follow-up (this
slice) would only need to relocate one method call rather
than split bundled work along the way. Splitting the work
that way meant 7c.2 is small and reviewable in isolation
— three files touched, one call site moved, no semantic
change for single-window flows.

**Pre-flight choice (where the hoisted call lives):**

- **Option (a) — In `runtime/frame.zig::renderFrameImpl`,
  bracketing `window.beginFrame()` / `window.endFrame()`**
  (chosen). This is the per-window render callback the
  platform dispatches; one call to `renderFrameImpl` ↔
  one render tick for that window. Reaching `window.app`
  once at the top of the function keeps the call sites
  visually adjacent to `window.beginFrame` /
  `window.endFrame` so a reader sees the four calls in
  order.
- **Option (b) — In a new tick driver behind
  `Platform.run`** (rejected for this slice). The "real"
  multi-window fix needs a centralised driver that fires
  `app.beginFrame` once across all windows, then drives
  each window's render. Building that requires
  platform-specific tick coordination (CVDisplayLink →
  GCD bounce on macOS, Wayland frame callbacks on Linux,
  `requestAnimationFrame` on web) that's out of scope
  for this slice. Landing the relocation now removes the
  layering wart even though the multi-window-per-tick
  redundancy survives unchanged. The driver lands in
  7c.3+ alongside the `Frame` double-buffer, where the
  `mem.swap` at frame boundary needs the same
  once-per-tick anchor.

**Write scope (landed):**

- `src/runtime/frame.zig` —
  - `renderFrameImpl` caches `window.app` once at the
    top so the begin/end pair reaches the same `App`
    even if a future code path mutates `cx.window()`
    mid-frame (no such path exists today; the cache is
    also the natural place for the explanatory comment
    that the layer-correct caller is now this function,
    not `Window`).
  - `app.beginFrame()` call inserted between
    `window.beginFrame()` and `render_fn(cx)`. Order
    constraint documented inline: must follow
    `window.beginFrame()` (so the per-window
    `image_atlas.beginFrame()` has reset the frame
    counter) and must precede `render_fn` (so widget
    renders' observations are not discarded by the
    entity-observation clear). A future tick-driver in
    7c.3+ that drives N windows per tick must preserve
    the same order across the N-way fan-out.
  - `app.endFrame()` call inserted immediately after
    `window.endFrame()` returns commands. Position
    rationale: `App.endFrame` is currently a no-op, so
    any position that follows `window.endFrame()` is
    correct today; the chosen spot is symmetric with
    `app.beginFrame` (both bracket the per-window
    calls), which means future work the `App.endFrame`
    hook is reserved for can rely on the layout / a11y
    finalisation having already run.
- `src/context/window.zig` —
  - `Window.beginFrame()` and `Window.endFrame()` lose
    their inline `self.app.beginFrame()` /
    `self.app.endFrame()` calls. The 7c.1 comment block
    inside each function rewrites to call out that the
    work has moved up to `renderFrameImpl`, with the
    order invariant the caller upholds spelled out so a
    future reader of `Window.beginFrame` is not
    surprised by the absence.
  - The two functions' doc comments grow a "Per-tick
    app-scoped work is NOT done here" preamble that
    points at `runtime/frame.zig` for the actual call
    site. This is load-bearing for callers reading the
    `Window` struct in isolation: pre-7c.2 the
    self-contained shape ("call `beginFrame`, call
    `endFrame`, app-scoped work happens for free") was
    a reasonable expectation; post-7c.2 it isn't, and
    the doc needs to say so.
- `src/context/app.zig` —
  - The "Per-frame hooks" comment block on `App`
    rewrote to summarise the three-step history
    (7b.3/5 lifted state, 7c.1 introduced API, 7c.2
    relocated call) so a reader landing in this file
    sees the full arc without cross-referencing PR
    notes.
  - The doc comment on `App.beginFrame` /
    `App.endFrame` points at `renderFrameImpl` as the
    caller (was "called once per tick before any
    `Window.beginFrame` runs"). The
    `entities.beginFrame` inline comment drops the
    stale "`Window.beginFrame` is the only caller"
    claim and replaces it with the per-render-callback
    caller scoping.

**Tasks landed:**

- [x] Cache `window.app` in `renderFrameImpl` and call
      `app.beginFrame()` / `app.endFrame()` bracketing
      `window.beginFrame()` / `window.endFrame()`.
- [x] Drop the inline `self.app.beginFrame()` /
      `self.app.endFrame()` from `Window.beginFrame` /
      `Window.endFrame`. Update the inline comment
      block to point at the new caller.
- [x] Update doc comments on `App.beginFrame` /
      `App.endFrame` and the surrounding "Per-frame
      hooks" block in `app.zig` to reflect the
      relocated caller.
- [x] `Build Summary: 9/9 steps succeeded; 1069/1069
    tests passed` (no delta vs. 7c.1 — the
      relocation is pure, so the three 7c.1
      method-level tests on `App.beginFrame` /
      `App.endFrame` still pin the same contract).
- [x] `zig build install` builds all examples
      (single-window and multi-window) without
      warnings.

**Implementation notes:**

- **No new tests.** The natural unit boundary for
  testing this slice would be a runtime-frame test that
  constructs a `Cx`, calls `renderFrameImpl`, and
  asserts `app.beginFrame` ran. But `renderFrameImpl`
  requires a full UI stack (platform window, layout
  engine, scene, builder, debugger) that's expensive to
  construct in a test fixture — every existing test
  that exercises `renderFrameImpl` does so through a
  real example, which `zig build install` already
  covers. The 7c.1 tests on `App.beginFrame` /
  `App.endFrame` continue to pin the method-level
  contract (entity-observation clear, image-loader
  drain guard, symmetric `endFrame`); 7c.2 is a pure
  call-site relocation, so pinning the new caller would
  test the test fixture, not the code under test.
  Verified via the test count being unchanged at 1069 —
  every prior property still holds.
- **Multi-window redundancy survives this slice
  unchanged.** With N windows borrowing one `App`, the
  platform layer fires N render callbacks per tick;
  each call to `renderFrameImpl` runs `app.beginFrame()`
  once. Net: the begin/end pair fires N times per tick,
  same as pre-7c.2. The `image_loader.drain` is
  idempotent (acceptable); the `entities.beginFrame`
  clear is NOT — the structural correctness gap that
  7c.1's comment block flagged carries forward to 7c.2
  unchanged. Fixing it requires a centralised tick
  driver at the platform → runtime boundary that fires
  `app.beginFrame()` once _before_ any window's render
  callback runs, then drives each window's render in
  sequence, then fires `app.endFrame()` once _after_
  the last window has finished. That driver lands in
  7c.3+ alongside the `Frame` double-buffer, which
  needs the same once-per-tick anchor for its
  `mem.swap` at frame boundary.
- **Why hoist now if the multi-window fix waits.** Two
  reasons. (1) Layering — even without the
  multi-window-per-tick fix, calling app-scoped work
  through a per-window forwarder was a layering bug
  that misled readers (the 7c.1 comment block inside
  `Window.beginFrame` had to keep apologising for the
  shape). Moving the call to the runtime layer puts
  the work at the layer that owns the `App`. (2)
  Forward-compatibility — when 7c.3 lands the
  centralised tick driver, the relocation done here is
  what the driver replaces: lifting one method call
  out of `renderFrameImpl` into a wrapper, not
  unbundling work from inside `Window.beginFrame`.
  Splitting the move from the multi-window fix is the
  same staging strategy that 7a → 7b used (move the
  type / API first, fix the behaviour next).
- **Order constraint preserved at the new call site.**
  Pre-7c.2 the inline call inside `Window.beginFrame`
  ran after `image_atlas.beginFrame` and before any
  element render — the function's body order
  guaranteed it. Post-7c.2 the runtime driver
  preserves the same order: `window.beginFrame()`
  (which calls `image_atlas.beginFrame` internally)
  finishes before `app.beginFrame()` runs, and
  `app.beginFrame()` finishes before the user's
  `render_fn(cx)` runs. The constraint is now spelled
  out in the inline comment block on `renderFrameImpl`
  so a future reader doesn't have to reverse-engineer
  it from the call order.
- **No cleanup of the 7c.1 tests required.** The three
  tests added in 7c.1 (`App: beginFrame clears stale
entity observations`, `App: beginFrame is a no-op
when image_loader is unbound`, `App: beginFrame
drains image_loader when bound`) all exercise the
  methods directly, not through `Window`. They keep
  pinning the method-level contract regardless of who
  calls them; 7c.2 is invisible from their
  perspective.

**Result:** `Build Summary: 9/9 steps succeeded;
1069/1069 tests passed` (no delta vs. PR 7c.1's 1069).
`zig build install` builds all examples (single-window
and multi-window) without warnings.

---

**Sub-PR 7c.3a — `Frame` struct bundling `scene` +
`dispatch` (landed):**

First slice of PR 7c.3. Goal: introduce the `Frame`
struct that bundles `Window`'s two "rebuilt every
frame, owned by one window" rendering subsystems
(`Scene`, `DispatchTree`) into one struct with a
single ownership flag, so the four parallel
`Window.init*` paths each collapse two
`allocator.create` + init + `setViewport` /
`enableCulling` + `errdefer` blocks into a single
`Frame.initOwned*` call, and `Window.deinit`
collapses the matching two pairs of `T.deinit` +
`allocator.destroy` into a single
`self.frame.deinit()`. Reference:
[`architectural-cleanup-plan.md` §11 frame
double-buffering with `mem::swap`](./architectural-cleanup-plan.md#11-frame-double-buffering-with-memswap).

**Why this lands as its own slice:** PR 7c.3 in the
original sketch was "introduce `Frame` _and_ wire
the double-buffer _and_ sweep call sites" — a
single PR touching the struct definition, ~167
call sites, the swap point, and the borrowed-view
shape would have dwarfed every previous 7-slice's
review surface. The PR 7a → 7b.6 pattern (bundle
the type first, retire back-compat aliases next,
fold in behavioural changes last) maps cleanly
onto 7c.3 → 7c.3a (bundle) → 7c.3b (retire
aliases) → 7c.3c (double-buffer behaviour). 7c.3a
is small (one new file, four init paths edited,
one deinit edited, four tests added) and
reviewable in isolation; the call-site sweep that
made 7b.6's diff visible in this slice would have
buried the structural change under mechanical
churn. Splitting them lets each land on a
green-on-its-own basis.

**Pre-flight choice (single ownership flag vs.
per-pointer flags):**

- **Option (a) — single `owned: bool` on `Frame`**
  (chosen). Mirrors `AppResources` from PR 7a — the
  symmetry between the two ownership bundles is
  load-bearing for readers who internalise the
  pattern from one and want to read the other. The
  two pointees (`*Scene`, `*DispatchTree`) are
  always either both owned (single `Frame` shape,
  every init path today) or both borrowed (PR
  7c.3c double-buffer transient views, where the
  swap point produces a view backed by another
  `Frame`'s pointees). A per-pointer
  `scene_owned` / `dispatch_owned` flag pair
  would be tautological — no init path in 7c.3a
  or 7c.3c can produce a shape where one is owned
  and the other isn't.
- **Option (b) — no flag, ownership encoded in
  `T` vs `*T`** (rejected for this slice). The
  "right" final shape per CLAUDE.md §17 is to
  encode ownership in the field type, not a flag.
  But the 7c.3c double-buffer needs a borrowed
  shape (the post-swap transient view), and
  inverting the `Frame` / `*Frame` distinction at
  the field level would require every per-frame
  call site to learn about two `Frame` shapes
  simultaneously. Landing the flag now matches
  what 7a did for `AppResources`; PR 9
  ("`root.zig` slim + ownership flag drop")
  is where every flag-style ownership
  discriminator gets retired together, after
  every consumer has migrated.

**Pre-flight choice (which subsystems migrate in
7c.3a vs. later 7c.3 slices):**

- **Scope-of-7c.3a — just `scene` + `dispatch`**
  (chosen). The §11 sketch lists `focus`,
  `element_states`, `mouse_listeners`,
  `dispatch_tree`, `scene`, `hitboxes`,
  `deferred_draws`, `input_handlers`,
  `tooltip_requests`, `cursor_styles`, `tab_stops`
  as `Frame` fields. Migrating all eleven in one
  PR would touch every per-frame subsystem
  simultaneously — every test fixture, every
  render callback, every event handler. Picking
  the two heaviest pointee subsystems (each with
  its own `allocator.create` + init + `errdefer`
  block in every `Window.init*` path) gives the
  bundle a real structural anchor without
  dragging in unrelated subsystems. `focus` /
  `hover` / `mouse_listeners` / `tab_stops`
  migrate in later 7c.3 slices once the
  call-site sweep against `scene` and `dispatch`
  is complete; `element_states` is reserved for
  PR 8 (a keyed pool replacing `WidgetStore`'s
  per-type maps, not a simple field migration).
- **Why not push `layout: *LayoutEngine` into
  `Frame` too** (considered, rejected). Layout
  is rebuilt every frame, which fits the `Frame`
  bucket on first read. But the layout engine is
  the one subsystem `Window` needs to keep
  distinct from the `Frame` bundle for the 7c.3c
  swap to make sense: the swap point lives
  _between_ `endFrame` (which produces commands
  from `layout`) and the next `beginFrame`
  (which clears `next_frame.scene`). If layout
  were inside `Frame`, the swap would also swap
  layout state, which would invalidate
  `LayoutId`s mid-frame for any retained widget
  (text-input cursors, scroll positions). The
  GPUI sketch in §10 keeps `layout_engine`
  directly on `Window` for the same reason —
  it's the only "rebuilt every frame" subsystem
  that doesn't double-buffer.

**Write scope (landed):**

- `src/context/frame.zig` (new, ~385 lines
  including the file-header rationale, the
  struct definition with three constructors,
  four tests, and the `borrowed`-shape API
  surface reserved for 7c.3c) —
  - `Frame.initOwned(allocator, viewport_width,
viewport_height) !Self` —
    heap-allocates `Scene` + `DispatchTree`,
    calls `scene.setViewport` +
    `scene.enableCulling` inline so callers
    don't need a separate viewport-config
    step. Pair-asserts at entry (viewport ≥ 0,
    not NaN) and exit (pointers non-null,
    distinct heap addresses).
  - `Frame.initOwnedInPlace(self, allocator,
viewport_width, viewport_height) !void` —
    same semantics, marked `noinline` per
    CLAUDE.md §14 so the WASM stack budget
    stays bounded across the two internal
    subsystems. Used by `Window.initOwnedPtr`
    / `Window.initWithSharedResourcesPtr` (the
    WASM stack-overflow-safe init paths).
  - `Frame.borrowed(allocator, scene, dispatch)
Self` — reserved for PR 7c.3c. Builds an
    `owned = false` view over
    already-initialised pointees; `deinit`
    becomes a no-op so the same backing
    storage isn't double-freed when the swap
    point produces a transient view. Exposing
    the constructor today (even unused) means
    the double-buffer landing only has to
    wire callers, not introduce a third
    constructor on a stable type.
  - `Frame.deinit(self) void` — frees both
    pointees in `dispatch → scene` order if
    `owned`, otherwise no-op. Order matches
    the pre-7c.3a free order in
    `Window.deinit`; the reverse would also
    be safe (no inter-pointer references
    between the two) but matching keeps the
    PR 7c.3a diff minimal at the
    `Window.deinit` site.
  - Four tests: `initOwned allocates and
frees cleanly`, `initOwnedInPlace produces
an owned instance`, `borrowed deinit is a
no-op (no double-free)`, `zero viewport
is accepted`. The third test is the
    load-bearing one — it constructs an
    owning parent, borrows from it, tears the
    borrowed view down, then lets `defer
parent.deinit()` run; if the borrowed
    `deinit` had freed the parent's pointees,
    the parent's teardown would double-free
    under `testing.allocator`. Same coverage
    shape as `app_resources.zig`'s test
    block.

- `src/context/window.zig` —
  - New `frame: Frame = undefined` field on
    `Window`, placed adjacent to `layout:
*LayoutEngine` so the two "rebuilt every
    frame" subsystems read together in the
    struct header. The field's doc-comment
    spells out the ownership-uniform
    single-window shape that lands in 7c.3a,
    the borrowed shape reserved for 7c.3c, and
    the `undefined` default for `testWindow`
    test fixtures.
  - `scene: *Scene` and `dispatch:
*DispatchTree` doc-comments rewritten to
    mark the fields as PR 7c.3a back-compat
    aliases. They still exist as plain
    pointer fields (mirror of `frame.scene` /
    `frame.dispatch`); the pointer values are
    populated from the bundle by every init
    path at the same heap address. PR 7c.3b
    sweeps the ~167 call sites and drops the
    two fields.
  - `Window.initOwned` — the inline
    `allocator.create(Scene)` + `Scene.init`
    - `setViewport` + `enableCulling` +
      `errdefer` block (8 lines) and the inline
      `allocator.create(DispatchTree)` +
      `DispatchTree.init` + `errdefer` block
      (3 lines) replaced with a single `var
frame = try Frame.initOwned(allocator, w,
h)` + `errdefer frame.deinit()` (4
      lines). The struct literal grows a
      `.frame = frame` line; `.scene` and
      `.dispatch` reach into `frame.scene` /
      `frame.dispatch` so the back-compat
      aliases land at the same heap addresses.
      Post-literal, `frame.owned = false` is
      set so a later errdefer can't
      double-free against `result.frame.deinit()`
      in the caller — exact mirror of the
      `resources.owned = false` line PR 7a
      added.
  - `Window.initOwnedPtr` — same shape, but
    `Frame.initOwnedInPlace(&self.frame,
allocator, w, h)` writes directly into
    the heap-allocated `Window`'s `frame`
    slot, avoiding the by-value-copy disarm.
    The field-by-field block sets `self.scene
= self.frame.scene` and `self.dispatch =
self.frame.dispatch` for the alias
    mirror.
  - `Window.initWithSharedResources` /
    `Window.initWithSharedResourcesPtr` —
    same shape as the matching owned paths.
    The scene + dispatch tree are per-window
    state and remain owned per-window even
    in multi-window mode (only `AppResources`
    is borrowed). Sharing them across
    windows would break hit-testing — every
    window has its own draw-order space and
    its own dispatch tree.
  - `Window.deinit` — the previous two pairs
    of `T.deinit` + `allocator.destroy` (4
    lines) replaced with a single
    `self.frame.deinit()` call. The free
    order (`dispatch → scene`) matches the
    historical sequence inside
    `Frame.deinit`; the back-compat aliases
    (`self.scene` / `self.dispatch`) are NOT
    separately freed — they're mirror
    pointers into the same heap addresses
    `frame.deinit` just released, so
    touching them after this point would be
    a use-after-free. The comment block
    spells out the invariant for a future
    reader.

- `src/context/mod.zig` — add `pub const
frame = @import("frame.zig"); pub const
Frame = frame.Frame;` re-export alongside
  the existing `app_resources` block. The
  header comment summarises the symmetry
  between `AppResources` and `Frame` so a
  reader landing in this file sees both
  bundles together.

**Tasks landed:**

- [x] Create `src/context/frame.zig` with
      `Frame` struct, three constructors
      (`initOwned` / `initOwnedInPlace` /
      `borrowed`), `deinit`, and four tests.
- [x] Add `frame: Frame = undefined` field on
      `Window`; mark `scene` / `dispatch` as
      PR 7c.3a back-compat aliases via
      doc-comment rewrites.
- [x] Rewrite all four `Window.init*` paths
      to use `Frame.initOwned` /
      `Frame.initOwnedInPlace` and populate
      `scene` / `dispatch` aliases from
      `frame.scene` / `frame.dispatch`.
- [x] Replace the inline scene + dispatch
      teardown in `Window.deinit` with a
      single `self.frame.deinit()` call.
- [x] Re-export `Frame` from
      `src/context/mod.zig` alongside
      `AppResources`.
- [x] `Build Summary: 9/9 steps succeeded;
    1073/1073 tests passed` (+4 vs. PR
      7c.2's 1069 — the four new `Frame`
      ownership tests).
- [x] `zig build install` builds all examples
      (single-window and multi-window)
      without warnings.

**Implementation notes:**

- **No call-site sweep in this slice.** The
  ~167 internal `window.scene.*` /
  `window.dispatch.*` references stay
  unchanged in 7c.3a; they reach through the
  back-compat alias fields, which are
  populated from the bundle at the same heap
  addresses. PR 7c.3b rewrites every site to
  reach through `window.frame.scene` /
  `window.frame.dispatch` and drops the alias
  fields. Splitting the type introduction
  from the call-site sweep means each PR has
  a manageable review surface — 7c.3a's diff
  is +555 / −83 across 3 files (mostly the
  new `frame.zig`); 7c.3b will be a much
  wider but mechanical sweep across runtime,
  scene, layout, builder, examples, and the
  platform layer.
- **`testWindow` fixture stays as-is.** The
  fixture leaves every resource pointer at
  `undefined` (the deferred-command tests
  never reach through `scene` or
  `dispatch`). The new `frame: Frame =
undefined` field default keeps the same
  shape — no test edits needed. Adding a
  real `Frame` to the fixture would pull in
  `Scene` + `DispatchTree` heap allocations
  the tests don't exercise; the existing
  minimum is the right shape for those
  tests.
- **Why disarm `frame.owned` post-literal in
  `initOwned` / `initWithSharedResources`.**
  The by-value paths build a local `frame`,
  copy it into `result.frame`, then continue
  with more `try` calls (`globals.setOwned`).
  If one of those `try`s unwinds, the local
  `frame`'s `errdefer frame.deinit()` would
  tear down the pointees that `result.frame`
  is now the canonical owner of. Setting
  `frame.owned = false` post-literal disables
  the local `errdefer` cleanup —
  `result.frame` (which copied through with
  `owned = true` because it captured the
  literal _before_ the disarm) is the only
  one that will free the pointees. Exact
  mirror of the `resources.owned = false`
  line PR 7a added for the `AppResources`
  bundle.
- **No disarm needed in the `*Ptr` paths.**
  `Frame.initOwnedInPlace` writes directly
  into `self.frame` (the final heap
  address), so there's no intermediate
  by-value copy to disarm against. `errdefer
self.frame.deinit()` is wired correctly —
  if a later `try` unwinds, the bundle tears
  down exactly once at its final heap
  address. Same shape as
  `self.resources.initOwnedInPlace` from PR
  7a.
- **Free order mirrors pre-7c.3a
  `Window.deinit`.** Pre-7c.3a,
  `Window.deinit` freed `dispatch` first,
  then `scene` (after `globals.deinit`).
  7c.3a's `Frame.deinit` preserves that
  order exactly. The reverse would also be
  safe — no inter-pointer references between
  the two — but matching keeps the diff at
  the `Window.deinit` call site minimal:
  only the two pairs of `T.deinit` +
  `allocator.destroy` collapse into the
  single `self.frame.deinit()`, every other
  line in `deinit` stays put.
- **Viewport tolerance preserved.** Every
  pre-7c.3a `Window.init*` path called
  `scene.setViewport(w, h)` with values
  pulled from the platform window. Tests and
  stub fixtures sometimes construct a
  `Window` before the platform layer has
  reported a real surface size; the
  pre-7c.3a code tolerated a zero-sized
  viewport (culling becomes a no-op until
  the first resize event).
  `Frame.initOwned` / `initOwnedInPlace`
  assert `viewport_width >= 0` and
  `viewport_height >= 0` (not `> 0`),
  matching the pre-7c.3a behaviour. The
  fourth `Frame` test pins this tolerance
  so a future tightening of the assertion
  surfaces a regression.
- **Symmetric API surface to
  `AppResources`.** The `Frame` struct
  exposes `initOwned` / `initOwnedInPlace`
  / `borrowed` / `deinit` with identical
  signatures (modulo the type-specific
  parameters) to `AppResources`. A reader
  who has internalised one can read the
  other without re-learning the shape. The
  `borrowed` constructor on `Frame` is
  unused today; the `borrowed` constructor
  on `AppResources` is used by the
  multi-window flow. Same shape, different
  fill rate — when 7c.3c lands the
  double-buffer, `Frame`'s `borrowed`
  becomes load-bearing.
- **Scoping for the `borrowed` shape's
  future use.** PR 7c.3c will introduce
  `next_frame: Frame` alongside
  `rendered_frame: Frame` (renaming the
  current `frame` field) and call
  `mem.swap(&window.rendered_frame,
&window.next_frame)` at frame boundary.
  Post-swap, the `Frame` whose pointees
  were consumed becomes the "next frame"
  target. The borrowed shape is reserved
  for transient views (e.g. the runtime
  driver may want to hand a borrowed
  `Frame` to a hit-test pass without
  taking responsibility for its teardown).
  7c.3a lands the API surface so 7c.3c
  only needs to wire callers; the type's
  shape is stable across the two slices.

**Result:** `Build Summary: 9/9 steps
succeeded; 1073/1073 tests passed` (+4 vs.
PR 7c.2's 1069 — the four new `Frame`
tests). `zig build install` builds all
examples (single-window and multi-window)
without warnings.

---

**Sub-PR 7c.3b — Retire `window.scene` /
`window.dispatch` back-compat aliases (landed):**

Second slice of PR 7c.3. Goal: finish the bundle
introduction PR 7c.3a started by rewriting every
`Window` consumer to reach through
`window.frame.scene` / `window.frame.dispatch`
instead of the duplicate alias pointers, then
drop the two alias fields from `Window`'s
field list. Reference:
[`architectural-cleanup-plan.md` §11 frame
double-buffering with `mem::swap`](./architectural-cleanup-plan.md#11-frame-double-buffering-with-memswap).

**Why this lands as its own slice:** PR 7c.3a
deliberately stopped one step short of a
call-site sweep so reviewers could focus on the
`Frame` struct's ownership shape (three
constructors, single `owned: bool` flag,
mirror of `AppResources`) without ~80
mechanical line edits dwarfing the structural
diff. 7c.3b is the matching pair — pure
mechanical sweep, zero new logic, every test
that passed pre-7c.3b still passes post-7c.3b.
Same staging strategy PR 7a → 7b.6 used for the
`text_system` / `svg_atlas` / `image_atlas`
triplet (bundle the type, sweep the call sites,
drop the duplicate fields), now applied to the
per-frame rendering state.

**Pre-flight choice (sweep granularity):**

- **Option (a) — file-by-file sed** (chosen).
  The aliases are simple field accesses (no
  method-name collisions: there's no
  `window.dispatch(args)` method, only
  `window.dispatch.method(args)` field
  access; `Window.dispatchClick` etc. live on
  `DispatchTree`, not `Window`). A
  per-file `sed 's/window\.scene/window.frame.scene/g'`
  pass produces the right rewrite in one shot,
  then a verification grep confirms zero
  remaining `window\.scene` /
  `window\.dispatch` references outside
  the platform-window struct (which has its
  own unrelated `scene` field).
- **Option (b) — manual rewrite per call
  site** (rejected). The 6 files (~80 sites)
  would have been a long and error-prone
  manual edit. The sed pass + verification
  grep is provably equivalent for this
  rewrite shape (no overloaded names, no
  context-sensitive replacements).

**Write scope (landed):**

- `src/runtime/frame.zig` — 13 sites across
  `renderFrameImpl` (dispatch reset, scene
  clear, scene finish, dispatch tree walk for
  bounds sync), `renderCommands` (canvas
  base-order reservation, scrollbar render),
  `renderCanvasElements` (canvas execution),
  `renderTextInputs` /
  `renderTextAreas` /
  `renderCodeEditors` (per-pending-widget
  render), and `renderDebugOverlays`
  (overlay quads, inspector panel, profiler
  panel).
- `src/runtime/render.zig` — 11 sites
  across the per-render-command leaf
  functions (`renderShadow`,
  `renderRectangle`, `renderBorder`,
  `renderText`, `renderSvg`,
  `renderImage`, `renderScissorStart` /
  `renderScissorEnd`,
  `renderImagePlaceholder` /
  `renderImageError`). All reach through
  the `window_ctx: *Window` parameter.
- `src/runtime/input.zig` — 16 sites in
  pointer / key / drag handlers
  (`hitTest`, `dispatchPath`,
  `findDropTarget`, `getNodeConst`,
  `dispatchClickOutsideWithTarget`,
  `dispatchClick`, `focusPath`,
  `contextStack`, `dispatchAction`,
  `dispatchKeyDown`, `rootPath`).
- `src/runtime/window_context.zig` — 5
  sites: two `Builder.init` argument
  pairs (in `init` and
  `initWithSharedResources`) and the
  `window.setScene(self.window.scene)`
  call in `setupWindow` (the platform
  window receives a borrowed pointer to
  the framework window's scene; that pointer
  now reaches through `self.window.frame.scene`).
- `src/app.zig` — 3 sites: two
  `Builder.init` arguments in
  `WebApp.initImpl` and the
  `g_renderer.?.render(...)` scene-pointer
  argument in `WebApp.frame`.
- `src/context/window.zig` —
  - Drop the `scene: *Scene` and
    `dispatch: *DispatchTree` alias fields
    from the struct definition. Replaced
    with retirement-note comment blocks that
    point at `window.frame.scene` /
    `window.frame.dispatch` for future
    readers.
  - Drop `.scene = frame.scene` and
    `.dispatch = frame.dispatch` from the
    struct literals in `initOwned` and
    `initWithSharedResources`. The
    surrounding doc-comments rewrite to call
    out the alias retirement instead of
    pointing forward to it.
  - Drop `self.scene = self.frame.scene` /
    `self.dispatch = self.frame.dispatch`
    from the field-by-field init in
    `initOwnedPtr` and
    `initWithSharedResourcesPtr`. Same
    doc-comment shape.
  - Rewrite the four `Window`-method
    call sites that reached through the
    aliases (`Window.beginFrame` —
    `scene.clear`, `scene.setStats`,
    viewport sync; `updateHover` /
    `refreshHover` — `hover.update` /
    `hover.refresh` argument;
    `finishScene` — `scene.finish`;
    `getScene` accessor return). All now
    reach through `self.frame.scene` /
    `self.frame.dispatch`.
  - Drop `.scene = undefined` and
    `.dispatch = undefined` from the
    `testWindow` fixture; the
    `frame: Frame = undefined` default
    covers the deferred-command tests'
    needs without explicit init.
  - `Window.deinit` comment block updates
    to note that `frame.deinit` is now
    the single ownership boundary for
    per-frame rendering state — no mirror
    pointers to worry about.

**Out of scope:**

- `src/ui/builder.zig` keeps its own
  `scene: *Scene` and `dispatch: *DispatchTree`
  fields. They mirror the `Window`'s
  pointers (initialised from
  `window.frame.scene` / `window.frame.dispatch`
  by `Builder.init`), but they're independent
  fields on a different struct — the alias
  retirement only applies to the duplicate
  fields on `Window`. Folding `Builder`'s
  field copies into a `*Window` reach-through
  is a separate cleanup (would touch every
  `self.scene` / `self.dispatch` site
  inside `Builder`'s ~1700 lines, no
  ownership-shape benefit since the fields
  are simple borrowed pointers).
- `src/ui/canvas.zig` keeps its own
  `scene: *Scene` field for the same
  reason. The `Canvas` struct is a
  self-contained drawing primitive that
  takes a `*Scene` at construction time;
  no `*Window` reference, so the alias
  retirement doesn't apply.
- `src/platform/macos/window.zig` and
  `src/platform/linux/window.zig` keep
  their own `scene: ?*const Scene` fields.
  These are `platform.PlatformWindow`
  (the OS-level handle), not the framework
  `Window`; the field's purpose is to
  hand a borrowed scene pointer to the
  GPU renderer at render time, set via
  `PlatformWindow.setScene(scene)` from
  the framework layer. Renaming would
  require touching the per-OS rendering
  loops, which is out of scope.

**Tasks landed:**

- [x] Sweep `window.scene` / `window.dispatch` /
      `self.scene` / `self.dispatch` in the 6
      affected files (`runtime/frame.zig`,
      `runtime/render.zig`, `runtime/input.zig`,
      `runtime/window_context.zig`, `app.zig`,
      `context/window.zig`).
- [x] Drop the two alias fields from `Window`'s
      struct definition; replace with retirement-note
      comment blocks.
- [x] Drop the four alias-population sites in
      `Window.init*` paths (two struct-literal
      lines, two field-by-field lines).
- [x] Rewrite the four `Window`-method internal
      call sites (`beginFrame`, `updateHover`,
      `refreshHover`, `finishScene` /
      `getScene`) to reach through `self.frame.*`.
- [x] Update doc-comments in `Window` (struct
      header, both `initOwned` Frame setup
      blocks, both deinit blocks, `testWindow`
      fixture) to call out 7c.3b's alias
      retirement instead of pointing forward to it.
- [x] `Build Summary: 9/9 steps succeeded;
    1073/1073 tests passed` (no delta vs. PR
      7c.3a's 1073 — pure mechanical sweep, no
      new tests).
- [x] `zig build install` builds all examples
      (single-window and multi-window) without
      warnings.

**Implementation notes:**

- **No new tests.** The four `Frame` tests
  landed in 7c.3a (`initOwned` allocates and
  frees cleanly, `initOwnedInPlace` produces
  an owned instance, `borrowed` deinit is a
  no-op, zero viewport is accepted) continue to
  pin the ownership-shape contract. 7c.3b is a
  pure call-site sweep — every site now reaches
  through `window.frame.scene` /
  `window.frame.dispatch`, which are the same
  heap addresses the pre-7c.3b alias fields
  pointed at. If 7c.3a's tests passed, 7c.3b's
  rewrite preserves the same heap addresses, so
  every existing test that exercises
  scene/dispatch behaviour through any code path
  continues to pass without modification.
  Verified via the test count being unchanged at 1073.
- **`testWindow` fixture stays minimal.**
  Pre-7c.3b the fixture had to set
  `.scene = undefined` and
  `.dispatch = undefined` explicitly for the
  struct literal to compile. Post-7c.3b the
  alias fields are gone, and the
  `frame: Frame = undefined` default (introduced
  in 7c.3a) already covers the deferred-command
  tests this fixture is built for. Net delta on
  the fixture: -2 lines (the two
  `undefined` entries) and a comment block
  pointing at 7c.3a / 7c.3b for context.
- **Why no `frame.zig` edits in this slice.**
  The `Frame` struct landed in 7c.3a with
  three constructors and a `deinit` — every
  shape 7c.3b needs is already there. The
  `borrowed` constructor stays unused at this
  slice (reserved for 7c.3c's
  `mem.swap`-driven double-buffer transient
  views); the type's surface area is stable
  across 7c.3a → 7c.3b → 7c.3c.
- **Sweep verification.** Post-sweep grep
  confirms zero remaining `window\.scene` /
  `window\.dispatch` /
  `self\.scene` /
  `self\.dispatch` references outside (a)
  doc-comments inside `context/window.zig`
  describing the retirement, (b) the
  platform-window struct's unrelated
  `scene: ?*const Scene` field on
  `platform/macos/window.zig` /
  `platform/linux/window.zig` (which is the
  OS handle's borrowed-pointer slot, not a
  framework `Window` alias), and (c)
  `Builder`'s and `Canvas`'s own `scene` /
  `dispatch` fields (out-of-scope per the
  notes above). Pre-7c.3c, the only field
  named `scene` on `Window` is now
  `frame.scene`, and the only field named
  `dispatch` is now `frame.dispatch`. Same
  invariant PR 7b.6 left for the
  `text_system` / `svg_atlas` /
  `image_atlas` triplet on `AppResources`.
- **Forward compatibility with 7c.3c's
  double-buffer.** 7c.3c will rename
  `Window.frame` to `Window.rendered_frame`,
  add `Window.next_frame`, and call
  `mem.swap(&self.rendered_frame,
&self.next_frame)` at frame boundary. Every
  call site 7c.3b just rewrote already reaches
  through `window.frame.*`; 7c.3c's relocation
  becomes a single rename
  (`frame` → `rendered_frame`) plus the
  `mem.swap` call. Pre-7c.3b the
  `window.scene` / `window.dispatch` aliases
  would have needed their own
  `window.rendered_frame.scene` /
  `window.rendered_frame.dispatch` pass
  through, doubling the 7c.3c diff.
- **Multi-window flow unchanged.**
  `Window.initWithSharedResources` /
  `initWithSharedResourcesPtr` keep their
  own `Frame.initOwned` /
  `initOwnedInPlace` calls — scene and
  dispatch tree are per-window state even in
  multi-window mode (sharing them across
  windows would break hit-testing — every
  window has its own draw-order space). The
  alias retirement is invisible to the
  shared-vs-owned distinction; it's purely
  about how each window reaches its own
  per-frame state.

**Result:** `Build Summary: 9/9 steps
succeeded; 1073/1073 tests passed` (no delta
vs. PR 7c.3a's 1073). `zig build install`
builds all examples (single-window and
multi-window) without warnings.

**Sub-PR 7c.3c — `rendered_frame` /
`next_frame` double buffer with `mem.swap`
at frame boundary (landed):**

**Why this lands as its own slice:** PR
7c.3a bundled `scene` + `dispatch` into a
single `Frame` struct; PR 7c.3b retired the
back-compat `window.scene` /
`window.dispatch` aliases and rewrote every
internal call site to reach through
`window.frame.*`. PR 7c.3c is the third
and final piece of the original 7c.3
sketch: the actual `mem.swap`-driven double
buffer per
[`architectural-cleanup-plan.md` §11](./architectural-cleanup-plan.md#11-frame-double-buffering-with-memswap).
Splitting the three concerns across three
slices keeps each one's review surface small
enough to land green on its own — 7c.3c by
itself touches 7 files (one new field on
`Window`, four `Window.init*` paths, four
build-call-site files, three input-call-site
files, the `Builder` per-tick reset, and
the platform `setScene` update) plus the
three new `Frame` swap tests; doing it
alongside the type extraction or the alias
sweep would have dwarfed every previous
7-slice's diff.

**Direction (load-bearing for the slice's
shape):** the existing `Window.frame` field
was the active build target — every
`window.frame.scene.*` write in
`runtime/frame.zig::renderFrameImpl`,
`Window.beginFrame`, `Builder.init`, and the
widget render helpers was producing the
frame currently under construction. So 7c.3c
renamed `frame` → `next_frame` and added
`rendered_frame: Frame` for the
previously-built tree, putting the
GPUI-faithful naming right at the field
declaration. The literal-plan direction
(renaming `frame` → `rendered_frame` and
adding `next_frame` for the build target)
would have forced every build call site to
flip from `frame.*` → `next_frame.*` _and_
reshape the swap semantics in a follow-up
slice, doubling the diff. PR 7c.3b's
forward-compat sketch read "7c.3c will
rename `Window.frame` to
`Window.rendered_frame`" — that turned out
to be backwards once 7c.3c started, hence
the explicit note in the slice description
above.

**Pre-flight pivot — `Builder` caches its
`*Scene` / `*DispatchTree` pointers:** the
first build of 7c.3c hit a subtle aliasing
bug: `Builder.init` is called once per
`WindowContext` and stashes the
`*Scene` / `*DispatchTree` it was handed
into its own fields. Pre-7c.3c, those
pointers were stable for the `Builder`'s
lifetime because `Window.frame` never moved.
With `mem.swap` rotating the two heap-
allocated pairs every tick, the cached
pointers identify the GPU-side display
buffer instead of the live build target on
every tick after the first. Three options
were considered:

- **Option (a) — sync `builder.scene` /
  `builder.dispatch` from
  `window.next_frame.*` once per tick
  inside `renderFrameImpl`** (chosen). Two
  extra assignments alongside the
  existing per-tick `id_counter = 0` and
  pending-queue clears; total cost is two
  pointer writes per tick. Keeps the
  `Builder.init` shape unchanged for the
  ~50 build-call-site widgets that read
  `self.dispatch` directly.
- **Option (b) — make `Builder` hold a
  `*Window` and dereference
  `window.next_frame.{scene,dispatch}`
  on every read** (rejected). Cleaner at
  the type level but every
  `self.dispatch.pushNode()` /
  `self.dispatch.setLayoutId()` /
  `self.dispatch.popNode()` would learn
  an extra indirection in the hot path.
  The hot loops in
  `Builder.boxWithLayoutIdImpl` push and
  pop dispatch nodes per primitive;
  adding a pointer chase per access
  would be measurable on dense scenes.
- **Option (c) — refactor `Builder` to
  not cache the pointers at all
  (recompute from `*Window` lazily)**
  (rejected). Same cost as (b) at every
  use site, plus a wider blast radius
  (every `Builder` call site learns a
  new method signature).

The chosen option lives in
`renderFrameImpl`'s per-tick reset block:
the same place the `id_counter` /
pending-queue clears already lived. Two
new lines (`builder.scene =
window.next_frame.scene;
builder.dispatch =
window.next_frame.dispatch;`) plus a
matching comment block on
`runtime/window_context.zig`'s
`Builder.init` calls explain the
init-time-vs-per-tick split.

**Pre-flight pivot — platform `setScene`
update post-swap:** on macOS / Linux the
platform window holds a
`scene: ?*const Scene` slot populated by
`platform_window.setScene(...)` at
`WindowContext.setupWindow`. Pre-7c.3c that
was a one-shot setup because there was
only one Scene allocation per window. With
the double buffer, the heap allocation
that's "currently displayed" rotates into
`rendered_frame.scene` after every swap, so
the platform pointer must follow the
rotation. The choice was either:

- **Option (a) — `setScene` follows the
  swap** (chosen). `renderFrameImpl`
  calls
  `pw.setScene(window.rendered_frame.scene)`
  immediately after the `mem.swap` so
  the platform's scene pointer always
  identifies the just-built scene. The
  macOS `setScene` is mutex-aware
  (`render_in_progress` short-circuit
  skips the mutex when called from
  inside `displayLinkCallback`, which is
  where `renderFrameImpl` runs), so the
  extra call is a single pointer
  assignment plus `requestRender`. Web
  skips this branch entirely because
  `getPlatformWindow()` returns null on
  the web target — `WebApp.frame` reads
  through `g_window.?.rendered_frame.scene`
  directly each tick.
- **Option (b) — content-swap instead of
  pointer-swap** (rejected). Keeping the
  platform's scene pointer stable across
  swaps would require swapping `Scene`
  contents (vertex buffers, draw lists)
  instead of pointers — defeats the
  point of `mem.swap` (which is meant
  to be O(1) struct copy). Discarded
  immediately.
- **Option (c) — let the platform
  re-fetch `window.rendered_frame.scene`
  each render** (rejected for native).
  Web does this naturally because
  `WebApp.frame` is the render driver.
  Native displayLinkCallback / Linux
  render path doesn't have a `*Window`
  handle on the path that calls
  `renderer.renderScene` — threading one
  through would touch every platform's
  render entry point. Doing the
  `setScene` update at the framework
  layer (post-swap inside
  `renderFrameImpl`) keeps the platform
  code unchanged.

**Hover read-side split (`updateHover` vs.
`refreshHover`):** the two hover entry
points need different dispatch trees.

- `Window.updateHover(x, y)` is called
  from `runtime/input.zig` mouse move
  events, which arrive _between frames_
  (after frame N's swap, before frame
  N+1's build). The dispatch tree the
  user is currently _seeing_ lives on
  `rendered_frame.dispatch`, so this
  reads through there.
- `Window.refreshHover()` is called from
  `runtime/frame.zig::renderFrameImpl`
  after the bounds-sync pass, _before_
  the end-of-frame swap. At that moment
  the just-built tree (with current
  bounds) lives on `next_frame.dispatch`;
  `rendered_frame.dispatch` still holds
  the previous frame. Reading
  `next_frame.dispatch` here updates the
  hover state to match the bounds the
  user is _about to see_. The follow-up
  slice that retires `refreshHover` per
  win (1) above removes this method
  entirely — once input always
  hit-tests against `rendered_frame`,
  the post-build rerun becomes
  redundant.

A single `dispatch: *DispatchTree`
parameter would have been simpler at the
`HoverState` level, but the call-site
split is forced by the swap semantics:
the two callers fire on different sides
of the `mem.swap` boundary.

**Write scope:**

- `src/context/window.zig` — rename
  `frame: Frame = undefined` →
  `next_frame: Frame = undefined`, add
  `rendered_frame: Frame = undefined` slot
  alongside. Four `Window.init*` paths
  allocate both frames up front (was: one
  frame per init). `Window.deinit` tears
  both down (was: one). `beginFrame`,
  `finishScene`, `getScene`, `updateHover`,
  `refreshHover` rewritten to reach through
  the right slot per the read-side split
  above. `testWindow` fixture's comment
  block updated.
- `src/context/frame.zig` — three new tests
  for `mem.swap` semantics (scene+dispatch
  exchange, `owned = true` preservation
  across swap counts, post-swap recycle
  isolation). File-header doc-block
  rewritten to describe the
  rendered/next pair as the canonical
  shape (was: single `Frame` per `Window`
  with a forward-pointer to 7c.3c).
- `src/runtime/frame.zig` — build call
  sites switch from `window.frame.*` to
  `window.next_frame.*`. New end-of-frame
  block does
  `std.mem.swap(Frame, &window.rendered_frame,
&window.next_frame); window.next_frame.scene.clear();
window.next_frame.dispatch.reset();`
  followed by the platform `setScene`
  update. Per-tick reset block adds the
  two `builder.scene = ...; builder.dispatch
= ...;` lines per the pre-flight pivot
  above. New `Frame` import in the imports
  block (used by the `mem.swap` call).
- `src/runtime/render.zig` — every
  `window_ctx.frame.scene` →
  `window_ctx.next_frame.scene`. ~10 sites.
- `src/runtime/input.zig` — every
  `window.frame.dispatch` →
  `window.rendered_frame.dispatch`. ~12
  sites across the six hit-test entry
  points.
- `src/runtime/window_context.zig` — both
  `Builder.init` calls switch source from
  `window.frame.{scene,dispatch}` to
  `window.next_frame.{scene,dispatch}`;
  `setupWindow`'s `setScene` switches from
  `window.frame.scene` to
  `window.rendered_frame.scene` (the
  initial frame-0 setup; `renderFrameImpl`
  takes over for tick 1 onwards).
- `src/app.zig` — `WebApp.initImpl`'s
  `Builder.init` switches source to
  `g_window.?.next_frame.*`;
  `WebApp.frame`'s `g_renderer.?.render`
  switches from `g_window.?.frame.scene` to
  `g_window.?.rendered_frame.scene`.

**Tasks:**

- [x] Rename `Window.frame` → `next_frame`,
      add `rendered_frame` slot.
- [x] Update all four `Window.init*` paths
      to allocate both frames; update
      `Window.deinit` to tear both down.
- [x] Update `Window.beginFrame`,
      `finishScene`, `getScene` to reach
      through `next_frame.*`.
- [x] Split `updateHover` (reads
      `rendered_frame.dispatch`) and
      `refreshHover` (reads
      `next_frame.dispatch`).
- [x] Rewrite build-pipeline call sites in
      `runtime/frame.zig`,
      `runtime/render.zig`,
      `runtime/window_context.zig`,
      `app.zig::WebApp` to reach through
      `next_frame.*`.
- [x] Rewrite hit-test call sites in
      `runtime/input.zig` to reach through
      `rendered_frame.dispatch`.
- [x] Add the end-of-frame `mem.swap`
      block in `renderFrameImpl` (swap +
      clear next_frame.scene + reset
      next_frame.dispatch + platform
      setScene update).
- [x] Add the per-tick `builder.scene` /
      `builder.dispatch` reset in
      `renderFrameImpl`.
- [x] Three new `Frame` tests for
      `mem.swap` semantics.
- [x] Update file-header doc-block on
      `frame.zig` to describe the
      rendered/next pair as the canonical
      shape.
- [x] `Build Summary: 9/9 steps succeeded;
    1076/1076 tests passed` (+3 vs. PR
      7c.3b's 1073 — the three new
      `mem.swap` tests).
- [x] `zig build install` builds all
      examples (single-window and
      multi-window) without warnings.

**Implementation notes:**

- **Three new tests, all on `Frame`.** The
  swap semantics are anchored at the
  `Frame` level rather than the `Window`
  level because (a) `Window` swap requires
  a real platform window for the
  `setupWindow` path, which the test
  allocator can't provide, and (b) the
  invariant being tested is "does
  `std.mem.swap(Frame, &a, &b)` preserve
  ownership and exchange the pointee
  pointers as expected" — which is a
  `Frame`-level concern. The Window-level
  integration is exercised by every
  example through `zig build install` and
  by the existing 1073 tests that build
  scenes through `runtime/frame.zig`.
- **Two clears per frame on `next_frame.scene`.**
  `Window.beginFrame` clears
  `next_frame.scene` early (the historical
  pre-7c.3a clear), and `renderFrameImpl`'s
  end-of-frame post-swap recycle clears
  again. The first clear is redundant on
  every tick after the first (the post-
  swap recycle already left an empty
  buffer); on tick 0 the explicit clear
  covers the case where no prior swap
  has run. A future slice can prune the
  redundant clear; 7c.3c keeps both for
  safety.
- **Two resets per frame on `next_frame.dispatch`.**
  Same shape as the scene clears:
  `renderFrameImpl` resets
  `next_frame.dispatch` at the start
  (historical pre-7c.3a reset) AND in the
  end-of-frame recycle. Defensive
  double-reset for the same reason. Win
  (4) in the slice description above
  retires the start-of-frame reset.
- **No changes to `Frame.borrowed`.** The
  `borrowed` constructor on `Frame` (landed
  in 7c.3a) was originally sketched as
  "load-bearing for the swap point" — but
  the actual `mem.swap` between two
  `owned = true` slots doesn't go through
  `borrowed` at all. It's a physical
  struct exchange between two owning
  slots, both of which retain `owned =
true` post-swap. `Frame.borrowed`
  remains useful for diagnostic /
  transient inspection of either buffer
  (e.g. a debug overlay reading
  `rendered_frame.dispatch` without taking
  responsibility for tearing down its
  scene+dispatch pair) — the
  doc-comments on the constructor and the
  struct were rewritten to reflect that.
  The four 7c.3a tests (including the
  borrowed-deinit-no-op test) continue to
  pin the constructor's contract.
- **First-frame display behaviour.** On
  tick 0 (first frame ever), the
  end-of-frame swap rotates the just-
  built `next_frame` into `rendered_frame`
  and updates the platform `setScene` to
  point at the just-built scene. The GPU
  rendering inside the same
  `displayLinkCallback` then renders the
  freshly-swapped scene — _no_ one-frame
  display delay is introduced. (A
  start-of-frame swap variant would have
  introduced a one-frame delay because
  the GPU would render `rendered_frame`
  _before_ `next_frame` was built; the
  end-of-frame variant chosen here keeps
  the pre-7c.3c first-frame behaviour
  intact.)
- **Multi-window flow unchanged at the
  ownership layer.** Every `Window` in a
  multi-window app still owns its own
  `next_frame` + `rendered_frame` pair —
  scene + dispatch tree are per-window
  state and cannot be shared without
  breaking hit-testing. The double buffer
  is per-window; `multi_window_app::App`
  doesn't see it. The only multi-window
  call site this slice touched is the
  `setupWindow` path in
  `runtime/window_context.zig`, which now
  initialises the platform `setScene` to
  `rendered_frame.scene` rather than
  `frame.scene`.

**Result:** `Build Summary: 9/9 steps
succeeded; 1076/1076 tests passed` (+3 vs.
PR 7c.3b's 1073). `zig build install`
builds all examples (single-window and
multi-window) without warnings.

**Sub-PR 7c.3d — Retire `refreshHover` and the
start-of-frame `next_frame.dispatch.reset()` (landed):**

First slice that cashes in the wins the 7c.3c double
buffer was set up to unlock. Wins (1) and (4) from
7c.3c's slice description landed together because the
plan explicitly grouped them: with `refreshHover`
retired, the start-of-frame `next_frame.dispatch.reset()`
loses the only contract it was protecting (a defensive
double-reset on every tick after the first, redundant
with the post-swap recycle), and retiring both in the
same slice keeps the doc-comment churn coherent — the
comment block on the start-of-frame reset directly
names the `refreshHover` slice as its retirement
trigger.

**Why this is now safe (post-7c.3c invariants):**

- Input always hit-tests against
  `rendered_frame.dispatch`, the _previously-built tree
  with bounds already synced and rotated into
  `rendered_frame` by the end-of-frame `mem.swap`_. The
  bounds sync runs against `next_frame.dispatch` inside
  `renderFrameImpl` (after `endFrame()` returns commands),
  then the swap rotates the synced tree into
  `rendered_frame`. By the time the next mouse move
  arrives, the user is already seeing that tree and
  hit-testing reaches it. Pre-7c.3c (single buffer)
  input handlers had hit-tested against the in-progress
  build target before bounds were synced; the post-build
  `refreshHover()` corrected the resulting one-frame
  lag. Post-7c.3c there is no in-progress build target
  to mis-hit-test against — input always reads the
  rendered side.

- The end-of-frame `mem.swap` recycle
  (`window.next_frame.scene.clear(); window.next_frame.dispatch.reset();`)
  leaves `next_frame.dispatch` reset every tick after
  the first. Tick 0 starts with a fresh tree from
  `Frame.initOwned`'s `DispatchTree.init`. Either way,
  the dispatch tree is empty at the top of
  `renderFrameImpl`, making the explicit start-of-frame
  reset redundant on every tick. (7c.3c kept the reset
  in place that slice as a defensive double-reset,
  flagged as retirable in the slice's doc-block under
  win (4); 7c.3d cashes that in.)

**Write scope:**

- `src/context/hover.zig` — remove `HoverState.refresh`,
  `HoverState.last_mouse_x`, `HoverState.last_mouse_y`.
  `update` no longer captures the cursor coordinates
  into the cache (they were only read by `refresh`).
  `initInPlace` drops the two field clears. The
  module-level doc-block rewrites the `## What lives
here` enumeration to drop the cache fields, retitles
  the decoupling section from `## Decoupling from
Gooey` to `## Decoupling from Window` (the rename
  landed in 7b.1b but this file's docs hadn't been
  swept), and adds a new `## History — refresh
retirement (PR 7c.3d)` section recording why the
  cache fields and method are gone. The `update`
  function gains a 7c.3d note in its doc-comment
  spelling out the post-shape contract: `tree` is
  expected to be `rendered_frame.dispatch` at every
  call site (input handlers between frames; the only
  caller is `Window.updateHover`), and the
  double-buffer guarantees that tree has bounds
  already synced. Two existing tests (`HoverState:
init produces an empty, no-change state` and
  `HoverState: initInPlace matches init`) drop their
  two `last_mouse_*` field assertions each.
- `src/context/window.zig` — remove `Window.refreshHover`.
  Rewrite `Window.updateHover` doc-block to drop the
  forward reference to `refreshHover` retirement (the
  retirement happened) and explain the post-7c.3d
  invariant: input hit-tests against
  `rendered_frame.dispatch`, the layout pass that
  built that tree synced its bounds, no post-build
  re-run needed.
- `src/runtime/frame.zig` — remove the
  `window.refreshHover()` call after the bounds-sync
  loop in `renderFrameImpl`. Remove the start-of-frame
  `window.next_frame.dispatch.reset()` call. Both
  removals leave behind a 7c.3d comment block
  recording the retirement and the post-shape
  invariant (no live code change loses its
  documentation, per CLAUDE.md §16 "always say why").

**Tasks:**

- [x] Remove `HoverState.refresh`,
      `HoverState.last_mouse_x`, `HoverState.last_mouse_y`,
      and the `update`-side captures + `initInPlace`
      clears that fed them.
- [x] Rewrite `hover.zig`'s module-level doc-block
      with the `## History` section + post-shape
      invariants.
- [x] Drop the two `last_mouse_*` field assertions
      from the existing `HoverState: init` and
      `HoverState: initInPlace matches init` tests.
- [x] Remove `Window.refreshHover` from
      `src/context/window.zig`.
- [x] Rewrite `Window.updateHover` doc-block to
      record the post-7c.3d contract.
- [x] Remove the `window.refreshHover()` call after
      the bounds-sync loop in `renderFrameImpl`.
- [x] Remove the start-of-frame
      `window.next_frame.dispatch.reset()` call in
      `renderFrameImpl`.
- [x] Leave a 7c.3d comment block at each removal
      site recording the retirement and the
      post-shape invariant.
- [x] `Build Summary: 9/9 steps succeeded;
    1076/1076 tests passed` (no delta vs. 7c.3c).
- [x] `zig build install` builds all examples
      (single-window and multi-window) without
      warnings.

**Implementation notes:**

- **Why no new tests.** This slice is pure removal
  of dead code (`refresh` had a single caller, which
  also went away; `last_mouse_*` had a single
  reader, which also went away). The post-shape
  behaviour — input hit-tests against
  `rendered_frame.dispatch` and produces correct
  hover state on the first try — is exercised by
  every existing test that fires a mouse event
  through `Window.updateHover` (the input integration
  tests in `runtime/input.zig` and the example
  scenes through `zig build install`). Two existing
  tests dropped two field assertions each (the
  retired `last_mouse_*` fields), but the
  init-shape contract they pin remains intact.
  Adding a new test purely for the removal would be
  duplicating coverage that already exists.

- **`HoverState.last_mouse_*` retirement vs.
  keeping the fields "in case".** The fields
  existed solely so `refresh` could replay the last
  cursor coordinates without the runtime
  re-threading them through another event. With
  `refresh` gone, the only conceivable future
  reader would be a debugger overlay or a test
  harness that wants to know "where was the cursor
  on the last update" — neither is a real caller
  today, and CLAUDE.md §10 ("don't leave variables
  around after they're needed") wins over
  speculative keep-around. If a future caller does
  need that information, threading it through an
  explicit parameter is cheaper than maintaining
  invisible state on every input event.

- **Why `Window.beginFrame`'s
  `next_frame.scene.clear()` stayed.** Symmetry with
  the start-of-frame `dispatch.reset()` would
  suggest retiring the matching scene clear too,
  but the symmetry is superficial: `Window.beginFrame`
  is a `pub fn` on the `Window` struct (not strictly
  scoped to `renderFrameImpl`), and a future caller
  invoking `beginFrame` outside the runtime driver
  (e.g. a custom render loop) would expect the
  scene to be cleared. The dispatch reset lived
  only in `renderFrameImpl`, so its retirement
  doesn't change any public-API caller's
  expectations. Pruning the second
  `next_frame.scene.clear()` mid-`renderFrameImpl`
  (the call right before the command-replay pass)
  is a separate slice; this one keeps the scope
  tight to what 7c.3c's plan grouped together.

- **`hovered_ancestors` cache stays load-bearing.**
  Win (2) of the 7c.3c plan — replacing the
  32-entry parent-chain cache with a live re-walk
  of `rendered_frame.dispatch` — is _not_ part of
  this slice. The cache is still load-bearing for
  `isHoveredOrDescendant` reads between frames
  against the just-built rendered_frame tree, and
  the simplification needs its own design pass
  (the cache walk runs once per `update`; a live
  re-walk runs on every `isHoveredOrDescendant`
  read, which can be many per frame for complex
  tooltip trees). Lands in a follow-up slice.

- **First-frame behaviour unchanged.** Tick 0 had
  no prior `mem.swap` to recycle the buffer, so
  pre-7c.3d the start-of-frame `dispatch.reset()`
  was the path that gave the build a clean tree
  on the first frame. Post-7c.3d, tick 0 gets the
  clean tree from `Frame.initOwned`'s
  `DispatchTree.init` instead — same effective
  state (empty tree at the top of `renderFrameImpl`
  on tick 0), reached through a different path.
  Tick 1+ goes through the post-swap recycle
  (already there pre-7c.3d, doing the same
  reset). The retirement is purely the duplicate.

- **Multi-window flow unaffected at the
  ownership layer.** Hover state is per-window
  (every `Window` owns its own `HoverState`),
  and the dispatch tree is per-window
  (`rendered_frame.dispatch` lives on each
  `Window.frame`). The retirement removes a
  per-window method (`refreshHover`) and a
  per-window field-set (`last_mouse_*`); no
  cross-window plumbing changes.

**Result:** `Build Summary: 9/9 steps succeeded;
1076/1076 tests passed` (no delta vs. PR 7c.3c's
1076 — pure removal of dead code; two existing
tests drop two field assertions each on the
retired `last_mouse_*` fields). `zig build install`
builds all examples (single-window and
multi-window) without warnings.

---

## PR 8 — Unified `element_states`

**Goal:** replace per-widget retained-state hash maps with a single
`HashMap((id, TypeId), *anyopaque)` keyed pool.
Adding a new widget no longer requires framework edits.

**Write scope:**

- `src/context/element_states.zig` (new)
- every `widgets/*_state.zig` (call site changes)
- `src/context/gooey.zig` / `window.zig` (drop per-widget maps)

**Slicing strategy.** PR 8 mirrors PR 7's slice approach so the
write scope of each landing is small enough to review and revert:

- **PR 8.1** — `ElementStates` container in isolation. New file,
  no widget migration, no `WidgetStore` edits. Validates the
  generic shape against tests before any consumer is wired up.
  Same pattern as PR 3's `SubscriberSet` introduction.
- **PR 8.2** — first consumer (`select_states`, the smallest /
  u32-keyed map). Validates the call-site shape on a real caller
  and the `cx.with_element_state` ergonomics before larger
  widgets follow.
- **PR 8.3+** — `text_input_state`, `text_area_state`,
  `code_editor_state`, `scroll_container` peeled off one at a
  time. Each slice is one widget map gone from `WidgetStore`.
  PR 8.4a took the `scroll_container` arm first because it has
  no focus-coupled dispatch (only bounds + offsets are read by
  framework code) — a clean validation of the runtime-init
  upsert (`getOrInsert`) before tackling the focus fan-out that
  text widgets share.
- **PR 8.x (final)** — retire `WidgetStore`'s per-type fields and
  the `getOrCreateWidget` / `removeWidget` / `deinitWidgetMap`
  helpers. The store either disappears entirely (every widget on
  the new pool) or shrinks to the residual cross-cutting state
  (animations, change-tracker) that doesn't fit the keyed-pool
  shape.

**Tasks:**

- [x] **PR 8.1** — Define `ElementStates` with fixed capacity
      (`MAX_ELEMENT_STATES = 4096` — sketch the math:
      4096 × 32 B per slot = 128 KB; heap-allocated by callers per
      CLAUDE.md §14). Generic `(id_hash, type_id) -> *S` slot map
      with dense-prefix invariant, swap-remove, and a comptime-built
      type-erased deinit thunk. Public surface: `init` /
      `initInPlace` / `withElementState` / `insert` / `get` /
      `contains` / `remove` / `deinit`. 18 unit tests cover the
      every-axis-of-the-keyed-pool shape (composite key
      separation, stable pointer on hit, swap-remove dense prefix,
      three `deinit` shapes, capacity boundary). Re-exported from
      `src/context/mod.zig`. **No widget migration in this PR**
      — same shape as PR 3's `SubscriberSet` skeleton, validated
      in isolation before consumers are wired up.
- [x] **PR 8.2** — Migrate `select_states` (u32-keyed,
      smallest) onto `ElementStates`. Drop `select_states` field
      from `WidgetStore`; route `getOrCreateSelectState` /
      `getSelectState` / `closeSelectState` /
      `toggleSelectState` through the pool. Validates the
      call-site shape on a real consumer.
- [x] **PR 8.3** — `with_element_state(global_id, fn(state) -> (R, state))`
      sugar surfaced through `Cx`, mirroring GPUI's
      [§19 pattern](./architectural-cleanup-plan.md#19-with_element_stateglobal_id-fnstate---r-state).
      Lands once one consumer is on the pool so the ergonomic
      shape is informed by real call sites.
- [x] **PR 8.4-prep** — Disambiguate the engine type names from the
      user-facing component types so PR 8.4 can lift them onto the
      pool without a name clash. `widgets/text_input_state.zig`'s
      `pub const TextInput = struct {...}` (the engine: text buffer,
      cursor, IME, edit history) collided with
      `components/text_input.zig`'s `pub const TextInput = struct
    {...}` (the user-facing chrome component). PR 8.2 established
      the convention that each stateful widget owns one state
      declaration next to its component (`SelectState` in
      `components/select.zig`); applying that to the text-widget
      family required renaming the engine types from
      `widgets.TextInput` / `widgets.TextArea` to `TextInputState` /
      `TextAreaState`. Engine types in the file names (`*_state.zig`)
      already implied the rename — the previous flat `TextInput` was
      an artifact of pre-component-split history.

      Also collapses the three duplicate `pub const Bounds = struct
      { x, y, width, height: f32 }` definitions in
      `text_input_state.zig`, `text_area_state.zig`,
      `code_editor_state.zig` into a single `text_common.Bounds`.
      The unified `Bounds.contains` uses the half-open `[x, x+w) x
      [y, y+h)` form, matching `core/geometry.Rect.contains` and the
      framework-wide hit-test convention. `text_input` / `text_area`
      previously used the closed `[x, x+w]` form (right/bottom edge
      inside) — an accidental divergence from the rest of the
      framework. Pinned by 5 new `Bounds.contains` tests covering
      interior hit, left/top inclusive, right/bottom exclusive,
      every-direction outside, and the zero-size degenerate case.

- [x] **PR 8.4a** — `scroll_container` migrated onto
      `Window.element_states`. Smallest of the four remaining
      retained-storage widgets and the only one with no
      focus-coupled dispatch (only bounds + offsets are read by
      framework code), so it lands as a clean validation of the
      runtime-init `getOrInsert` upsert before the larger
      text-family migration. Drops the
      `scroll_containers: StringHashMap(*ScrollContainer)` field
      and the two `scrollContainer` / `getScrollContainer`
      accessors from `WidgetStore`; rewires `cx.scrollView` /
      `Builder.scroll` / `Builder.registerPendingScrollRegions` /
      `runtime/input.handleScrollEvent`,
      `handleMouseDragEvent`, `handleScrollbarClick`,
      `handleMouseUpEvent` / `runtime/frame.renderCommands` /
      `widgets/data_table.syncScroll` /
      `widgets/uniform_list.syncScroll` /
      `widgets/virtual_list.syncScroll` to reach through
      `g.element_states.getOrInsert(ScrollContainer, layout_id.id, ScrollContainer.init(allocator))`
      for the seed path and `g.element_states.get(ScrollContainer, layout_id.id)`
      for the read-only paths. Also flips
      `Builder.active_scroll_drag_id` from `?[]const u8` to `?u32`
      so the cached drag id is the layout-id hash that keys the
      pool slot — sidesteps the lifetime hazard of holding a
      borrowed slice across the frame-render boundary that used
      to free the duped key.
- [x] **PR 8.4b** — Migrate `text_input` + `text_area` together
      onto `Window.element_states`. They share the focused-widget
      dispatch fan-out in `runtime/input.zig`
      (`handleKeyDownEvent`, `handleTextInputEvent`,
      `handleCompositionEvent`, `updateImeCursorPosition`), so
      rewriting that pattern once is the most-performant slice
      — see PR 8.4-prep landing notes for the original slicing
      rationale. PR 8.4b also sweeps in `code_editor_state` (the
      planned PR 8.4c arm) because the focused-widget dispatch
      already touches all three engines together — keeping
      `code_editor` on `WidgetStore` would have meant a third
      pass over the same dispatch sites for no slicing benefit.
      `WidgetStore`'s entire text-engine surface (the three
      `StringHashMap(*State)` maps, the four generic widget
      helpers, and the ~16 accessor verbs) retires alongside,
      collapsing what was planned as PRs 8.4b + 8.4c into a
      single landing.
- [ ] **0.16: this PR is the heaviest `@Type` user.** The `TypeId`
      construction and `*anyopaque` payload typing should be entirely
      `@TypeOf` / `@typeName` / `@Struct` style. No legacy `@Type`.
      ✅ PR 8.1 — `typeId` uses `@typeName(T).ptr` cast through
      `@intFromPtr`, same shape as `Globals` / `EntityMap`. No
      `@Type` builtin invocations.
- [ ] Pair-assert at the `set` / `get` boundary on every state slot
      (CLAUDE.md §3). ✅ PR 8.1 — `withElementState` and `insert`
      both pair-assert on entry (`count <= cap`) and on exit
      (slot readback matches the inserted key). ✅ PR 8.2 —
      every consumer call site routes through those pair-asserted
      paths; no per-call-site assertions added (the pool's
      invariants are the load-bearing ones, not the consumer's
      id-hash arithmetic).

**Definition of done:**

- Adding `widgets/foo_state.zig` requires zero edits to the
  framework — only `cx.with_element_state(id, …)` calls.
- All existing widget-state hash maps deleted.

### PR 8.1 landing notes (container-only)

**Status:** ✅ landed.

**Result:** `Build Summary: 9/9 steps succeeded; 1094/1094 tests
passed` (net +18 vs. PR 7c.3d's 1076 — the new
`element_states.zig` brings 18 self-contained unit tests for the
slot-map invariants). `zig build install` succeeds without
warnings.

**Files added:**

- `src/context/element_states.zig` (~880 lines: ~430 lines of code
  - ~450 lines of doc comments and tests). Public surface:
    `MAX_ELEMENT_STATES = 4096`, `TypeId`, `typeId(T)`, `Key`,
    `ElementStates` with `init` / `initInPlace` / `deinit` /
    `withElementState` / `insert` / `get` / `contains` /
    `hasRoom` / `len` / `remove`.

**Files edited:**

- `src/context/mod.zig` — re-exports `element_states`,
  `ElementStates`, `MAX_ELEMENT_STATES`, `ElementStateKey`,
  `ElementStateTypeId`, `elementStateTypeId`. Symmetric with the
  existing `subscriber_set` / `SubscriberSet` re-export block
  introduced in PR 3.

**Why container-only.** Same rationale as PR 3's `SubscriberSet`
introduction (validated against blur/cancel registries one PR
later) and PR 1's `AssetCache` skeleton (body lands in PR 2 once
SVG proves the trait shape). Shipping the container in isolation
lets the slot-map invariants be exercised against the test suite
— dense-prefix, type-keyed disambiguation, capacity boundary,
three `deinit` shapes (`fn(*S) void`, `fn(*S, Allocator) void`,
none) — before the first consumer is wired up. PR 8.2
(`select_states`) then has zero risk of pool-side regressions:
the failure surface shrinks to the call-site routing.

**Why a fixed-capacity slot map (not `AutoHashMap`).** CLAUDE.md
§1 / §4 — every subsystem in the framework has a hard cap
declared at the top of the file as a `MAX_*` constant, with
insert past capacity surfacing an explicit error. The
architectural-cleanup plan calls this out specifically for
`element_states` in §"What we're already doing better than GPUI":
"GPUI uses `Vec` and `FxHashMap` everywhere — they accept
allocator pressure as a tradeoff for flexibility. CLAUDE.md's
hard caps + fixed-capacity arrays are stricter. Don't lose this
when adopting #8 and #11." The 4096-slot cap with linear-scan
`findIndex` is branch-predictor-friendly at this size; if a
profile shows hash lookup is needed for some workload, the
public surface is stable enough to swap the body to an
`AutoHashMap` keyed by `Key.hash()` without call-site changes.

**Why heap-allocated by callers.** Sketch the math (CLAUDE.md
§7): `Entry` is 32 bytes (composite key 16 B + ptr 8 B +
deinit_fn 8 B); `4096 * 32 B = 128 KiB`. That's well over the
WASM stack budget (CLAUDE.md §14) so `Window` will heap-allocate
`ElementStates` through `allocator.create(ElementStates)` +
`initInPlace` rather than embedding by value. The
static-allocation policy is preserved — the heap allocation is
once at `Window` init, and the 128 KiB array is fixed-size with
no growing.

**`with_element_state` semantic delta from GPUI.** GPUI's API
takes a closure that consumes `Option<S>` and returns `(R, S)`,
with the framework writing the new state back. Our shape returns
`*S` directly and lets the caller mutate through the borrow. The
semantics are equivalent (Gooey's single-threaded frame loop
makes the borrow safe), and the Zig shape avoids the
closure-capture awkwardness that a literal port would force on
every call site. Documented in the module header so future
reviewers don't try to port the closure shape verbatim.

**Frame-driven eviction deferred.** GPUI's `with_element_state`
falls back to `rendered_frame.element_states` when the current
frame hasn't touched an element yet, and `mem::swap` at the
frame boundary discards entries not accessed for two consecutive
frames. Today's `WidgetStore` keeps state forever (no GC), so
adopting the same "explicit `remove` on widget unmount"
semantics is a pure refactor against the existing widget
lifecycle. The frame-keyed eviction shape lands later — the
GPUI Frame double buffer is partly in place from PR 7c.3c, and
once `element_states` moves onto `Frame`, the swap semantics
fall out for free.

### PR 8.2 landing notes (first consumer: `Select`)

**Status:** ✅ landed.

**Result:** `Build Summary: 9/9 steps succeeded; 1094/1094 tests
passed` (same count as PR 8.1's baseline — no new tests are
introduced for PR 8.2 since the PR 8.1 unit suite already covers
the pool's slot-map invariants from the consumer side, and the
call-site sweep is exercised through the existing component
reachability graph). `zig build install` succeeds without
warnings.

**Files edited:**

- `src/context/window.zig` — added
  `element_states: *ElementStates` field on `Window`. Heap-allocated
  through `allocator.create(ElementStates)` + `initInPlace` in all
  four `Window` init paths (`initOwned`, `initOwnedPtr`,
  `initWithSharedResources`, `initWithSharedResourcesPtr`); the 128
  KiB entry table is too large for the WASM stack budget (CLAUDE.md
  §14). `Window.deinit` walks the pool's type-erased deinit thunks
  before freeing the backing allocation. The pool is per-window
  even in multi-window mode — `LayoutId` hashes are per-window, so
  sharing one pool across windows would conflate state for unrelated
  elements.

- `src/context/widget_store.zig` — dropped the `SelectState` type,
  the `select_states: AutoHashMap(u32, SelectState)` field, and the
  four `getOrCreateSelectState` / `getSelectState` /
  `closeSelectState` / `toggleSelectState` accessors. The
  init/deinit/lifecycle hooks for select state vanish entirely from
  the framework body.

- `src/components/select.zig` — owns the `SelectState` declaration
  next to the widget now (was on `WidgetStore`). `internalToggle` /
  `internalClose` route through `g.element_states.withElementState`
  / `.get`; `Select.resolveState` does the same.
  `SelectState.defaultInit` is the comptime miss-path factory the
  pool runs on first touch.

- `src/cx.zig` — `onSelect`'s `forIndexAndClose` path now closes
  the select via `g.element_states.get(SelectState, ...)`, with a
  local import of `components/select.zig` for the type. Future
  cleanup of `cx.zig`'s per-widget knowledge is tracked separately
  and not in scope for PR 8.2.

**Why `Select` first.** Same rationale as the slicing-strategy
bullet at the top of PR 8: smallest of the per-type widget maps
(one `bool` per slot vs. text-buffer-sized state for the text
family), simplest call-site shape (u32-keyed, four short helpers,
two internal handlers + one `resolveState` reader), and zero
lifecycle entanglement with focus or accessibility. Validating the
call-site shape against this consumer surfaces any pool-side
ergonomic gaps before the larger `text_input` / `text_area` /
`code_editor` / `scroll_container` migrations land.

**Why move `SelectState` into `components/select.zig`.** The
"adding a new stateful widget requires zero edits to the framework"
promise of PR 8 is the load-bearing test of the keyed-pool
adoption. Leaving `SelectState` on `WidgetStore` would have meant
the widget still relied on a framework-side type declaration; the
move establishes the new convention (widget owns its state
declaration, framework owns only the pool storage) for every
follow-on slice. The same shape lands when 8.4+ moves
`TextInput` / `TextArea` / `CodeEditorState` definitions out of
`widgets/*_state.zig` re-imports into `WidgetStore` and onto the
pool.

**Why `internalClose` does NOT create on miss.** Asymmetry with
`internalToggle` is deliberate: closing a never-opened Select is a
no-op (the dropdown wasn't rendered, so there's no state to close),
and calling `withElementState` from a click-outside handler that
fires on an untouched Select would add an empty entry to the pool
every click. The `if (g.element_states.get(...)) |ss|` shape
preserves the pre-PR-8.2 behaviour (`closeSelectState` was a
`getPtr` lookup, not a `getOrPut`).

**Why `cx.onSelect`'s close path uses `.get` (not
`withElementState`).** Reaching `forIndexAndClose` implies the
option button just rendered — which means `Select.resolveState`
already called `withElementState` for this `id_hash` earlier in the
frame, so the slot must exist. The defensive `null` arm is there
only for the case where the close handler somehow fires after the
Select's owning subtree was unmounted; logging or panicking would
be wrong (legitimate path), and creating a new slot just to flip a
bool would leak. Read-only `.get` is the right shape.

**Frame-driven eviction still deferred.** Same as PR 8.1: select
state persists across frames until the widget calls `.remove`
explicitly. The pre-PR-8.2 `WidgetStore.select_states` map had no
GC either (the only path that ever cleared a slot was the
`closeSelectState` mutation, which set `is_open = false` rather
than removing the entry), so PR 8.2 is a pure storage-shape
refactor with identical retention semantics. The frame-keyed
eviction shape lands later alongside the rest of the GPUI
`Frame` double-buffer adoption (PR 7c.3+ in flight).

### PR 8.3 landing notes (`Cx` sugar)

**Status:** ✅ landed.

**Result:** `Build Summary: 9/9 steps succeeded; 1096/1096 tests
passed` (net +2 vs. PR 8.2's 1094 — the two new
`cx.element_states` namespace tests pinning the field type and
the method signatures). `zig build install` succeeds without
warnings.

**Files added:**

- `src/cx/element_states.zig` (~256 lines: ~120 lines of code +
  ~135 lines of doc comments). Defines the `ElementStates`
  zero-sized namespace marker and ten public methods — `with` /
  `withById` / `get` / `getById` / `contains` / `containsById` /
  `insert` / `insertById` / `remove` / `removeById`. Same
  `_align: [0]usize` + `@fieldParentPtr` shape as the sibling
  `cx/lists.zig` / `cx/animations.zig` / `cx/entities.zig` /
  `cx/focus.zig` files introduced in PR 5.

**Files edited:**

- `src/cx.zig` — added the `element_states_mod` import and the
  `element_states: element_states_mod.ElementStates = .{}` field
  on `Cx`, alongside the existing PR 5 `lists` / `animations` /
  `entities` / `focus` namespace fields. File-level doc comment
  bumped to mention the new sub-namespace alongside the four PR 5
  ones. No other call-site churn — PR 8.2's `Select` consumer
  reaches through `cx._window.element_states.*` and continues to
  do so; the new public surface is for follow-on widgets in
  PR 8.4+.

- `src/cx_tests.zig` — extended the existing PR 5 sub-namespace
  zero-size test to cover the new `ElementStates` ZST, and the
  "sub-namespace methods are reachable as decls" test to pin all
  ten methods. Two new tests: "`cx.element_states`: namespace
  field is reachable on `Cx`" pins the field name + type via
  `@FieldType`, and "`cx.element_states`: signatures route the
  right comptime types" pins the parameter count of the five
  primary methods (`with`, `withById`, `get`, `insert`, `remove`)
  via `@typeInfo`, so a future refactor that drops or reorders a
  parameter fails compilation here.

**Why string-id sugar.** The pool itself takes a `u64` id_hash;
forcing every consumer to call `LayoutId.fromString(id).id` first
would re-litigate the hash boundary at every call site. The
`with` / `get` / `contains` / `insert` / `remove` group accepts
a `[]const u8` and hashes inline — same shape `cx.focus.widget`
already uses for its `id` parameter, and same shape
`cx.animations.tween` uses for its non-comptime `id` parameter.
The `*ById` variants surface the raw `u64` hash for callers that
already have a `LayoutId` in hand (PR 8.2's `Select.resolveState`
is the exemplar — it calls `internalToggle` / `internalClose`
with a pre-computed `LayoutId.id` packed into `EntityId.id`).

**Why no `Select` migration.** PR 8.3's task is the API surface,
not the consumer rewrite. PR 8.2's `Select` reaches the pool
through handler callbacks with shape `fn(g: *Window, packed_id:
EntityId) void` — not `fn(cx: *Cx, ...)`. Migrating those handler
shapes to `*Cx` would touch the dispatch boundary
(`OnSelectHandler` packing, `internalToggle` / `internalClose`
signatures, the `Window`-vs-`Cx` distinction in
`runtime/input.zig`) and is outside this slice's scope. The
`Cx`-side surface is what PR 8.4+ widgets will use from inside
`Component.render(cx: *Cx)` and similar `*Cx`-shaped contexts;
`Select`'s in-handler call sites stay on
`g.element_states.*` until that refactor lands separately.

**Shape delta from GPUI.** GPUI's
`with_element_state<S, R>(global_id, |Option<S>, &mut Window| -> (R, S)) -> R`
threads the optional state through a closure that returns the
updated state for the framework to write back. The returned `R`
is the closure's by-value result, so the borrow of `S` doesn't
escape the call. Zig's single-threaded frame loop makes the
simpler `*S` borrow safe without that ceremony — the closure
form was largely a Rust-borrow-checker accommodation. PR 8.1's
container note already established the
`withElementState(S, id, default) !*S` shape; PR 8.3's
`cx.element_states.with(S, id, default) !*S` is the same shape
with the string-id hashing folded in. Documented in the new
`cx/element_states.zig` module header so a future reader doesn't
attempt a literal port of the GPUI closure form.

**Why ten methods, not five.** Each of the five primary methods
(`with`, `get`, `contains`, `insert`, `remove`) has a `*ById`
variant. The pair-shape mirrors `cx.animations.tween` /
`tweenComptime` and reads naturally at call sites: the bare name
is the path most callers want (string id in, value out), and the
`*ById` variant exists for the rare case where the caller
already has a `u32` / `u64` hash on hand and wants to skip the
re-hash. No sentinel-value tricks at the API boundary
(passing `0` to mean "use a hash already on the call site"
would be a footgun — `LayoutId.fromString` reserves `0` as the
"none" sentinel, and the `*ById` variants assert `id_hash != 0`
on entry).

**Frame-driven eviction still deferred.** Same as PR 8.1 / 8.2:
the new `cx.element_states.remove*` methods exist as the
explicit-unmount path, but no widget calls them today. The
frame-keyed eviction shape (mirroring GPUI's
`mem::swap`-on-`element_states` pair) lands later alongside the
rest of the `Frame` double-buffer adoption already in flight on
PR 7c.3+. The `Cx` surface introduced here is forward-compatible
with that shape: `cx.element_states.with` returns `*S` regardless
of which underlying frame map serviced the lookup.

### PR 8.4-prep landing notes (engine-type rename + shared Bounds)

**Status:** ✅ landed.

**Result:** `Build Summary: 9/9 steps succeeded; 1101/1101 tests
passed` (net +5 vs. PR 8.3's 1096 — the five new
`text_common.Bounds.contains` tests pinning the half-open hit-test
semantics; the engine-type rename adds zero new tests since it's a
pure mechanical rename with no behaviour change). `zig build
install` clean.

**Two commits:**

1. **`widgets: promote shared Bounds to text_common.zig with
half-open semantics`.** Adds `pub const Bounds = struct { x, y,
width, height: f32, pub fn contains(...) bool }` to
   `widgets/text_common.zig` (the existing shared-utilities home
   for the text-widget family — UTF-8 navigation, selection,
   position helpers). Replaces the three duplicate `pub const
Bounds = struct {...}` definitions in `text_input_state.zig`,
   `text_area_state.zig`, `code_editor_state.zig` with one-line
   re-exports (`pub const Bounds = common.Bounds`) so existing
   `*_state.Bounds` import paths in `WidgetStore`,
   `widgets/mod.zig`, and `code_editor_state.zig`'s
   `text_area_mod.Bounds` import all keep compiling unchanged. Five
   new tests pin the half-open `[x, x+w) x [y, y+h)` semantics on
   every axis (interior hit, left/top inclusive, right/bottom
   exclusive, every-direction outside, zero-size degenerate).

2. **`widgets: rename engine types TextInput → TextInputState,
TextArea → TextAreaState`.** Pure mechanical type rename across 6
   files: `widgets/text_input_state.zig`,
   `widgets/text_area_state.zig`, `widgets/code_editor_state.zig`,
   `widgets/mod.zig`, `context/widget_store.zig`, `cx.zig`. The
   user-facing chrome components in `components/text_input.zig` /
   `components/text_area.zig` keep their `TextInput` / `TextArea`
   names (declarative literals like `TextInput{ .id = "...",
.placeholder = "..." }` are unchanged for application code). The
   accessor _verbs_ on `WidgetStore` (`textInput`,
   `textInputOrPanic`, `getFocusedTextInput`, ...) are also
   intentionally preserved — they're the framework's public API for
   "give me the engine state for this widget id" and only the
   _return types_ are renamed.

**Why a separate prep PR.** PR 8.4 is the storage migration:
lifting `TextInputState` + `TextAreaState` off the per-type
`StringHashMap`s in `WidgetStore` and onto the keyed
`Window.element_states` pool, mirroring PR 8.2's `Select`
landing. Bundling the disambiguation rename into PR 8.4 would have
mixed two distinct concerns in one diff (rename + storage shape
change), each with its own failure surface. Splitting them lets
PR 8.4 land as a pure storage-shape diff with already-disambiguated
type names, and leaves this prep PR as a small reviewable rename +
type-deduplication that's easy to revert independently if either
half causes trouble.

**Why option (a) on the rename.** The naming-cleanup discussion
considered three forks: (a) rename engine to `TextInputState` /
`TextAreaState`, keep components as `TextInput` / `TextArea`; (b)
keep engine name, move to a sibling file `*_engine.zig`; (c)
rename component instead. Option (a) won because the file names
already implied the engine-side rename (`text_input_state.zig` →
`TextInputState` is the natural convention) and the component
names are the user-facing public API surface — a component rename
would have rippled through every example and every doc reference.
Public API impact: `gooey.widgets.TextInput` → renamed to
`gooey.widgets.TextInputState` (and `widgets.TextArea` →
`widgets.TextAreaState`); the user-facing `gooey.TextInput` /
`gooey.TextArea` (re-exported from `components/`) is unchanged.
PR 9 already plans to demote `gooey.widgets.*` flat re-exports
into namespace re-exports, so the rename is best landed before
that shrinking happens.

**Why option α on the half-open Bounds semantics.** The three
widgets had three definitions of `Bounds.contains`: `text_input` /
`text_area` used the closed `[x, x+w]` form (right/bottom edge
inside the rectangle), `code_editor` used the half-open `[x, x+w)`
form. The half-open form matches `core/geometry.Rect.contains`
and the framework-wide hit-test convention (the layout engine,
clip rects, every other hit-test path). The closed form was an
accidental divergence — the kind of inconsistency that "feels right
for text fields" until a user clicks on the exact pixel boundary
between two widgets and gets a different result than every other
boundary in the framework. Aligning to half-open absorbs the only
behavioural change in the prep PR (three call sites:
`text_input_state.zig:289`, `text_area_state.zig:406`, `:433`). The
practical impact is sub-pixel given HiDPI fractional scaling; the
five new `Bounds.contains` tests pin the convention so a future
refactor that flips the inequalities back to `<=` fails at build
time.

**Why not collapse onto `core/geometry.BoundsF`.** `core/geometry`'s
`Rect(T)` / `Bounds(T)` is a generic value type with a nested
`origin: Point(T) + size: Size(T)` shape. Text widgets touch
`bounds.x` / `bounds.y` / `bounds.width` / `bounds.height` ~150
times across hot rendering and hit-testing loops; rewriting every
access to `bounds.origin.x` / `bounds.size.width` would add an
indirection that nobody asked for. The flat shape lives in
`text_common.zig` alongside the other widely-shared text-family
helpers (UTF-8 navigation, selection, position) — the same
"shared between TextInput / TextArea / CodeEditorState" home that's
been there since the helpers landed.

**Why bundle text_input + text_area in PR 8.4 (informed by this
prep work).** During the prep audit, the genuine engine-type
rename surface turned out to be much smaller than the initial
grep suggested — only 5 files have real type-references vs. ~25
files where the name appears in comments or in user-facing
component contexts. That disambiguation also revealed that
`runtime/input.zig` has a focused-widget dispatch fan-out
(`handleKeyDownEvent`, `handleTextInputEvent`,
`handleCompositionEvent`, `updateImeCursorPosition`) that walks
through `text_input` and `text_area` arms with identical shape.
Migrating them in separate PRs would force two passes through the
same dispatch boundary, with a half-migrated intermediate state
where one arm routes through the pool and the other arm still
walks a hashmap. Bundling them in PR 8.4 means the rewrite
happens once, cleanly, and the `cx.element_states.with(...)`
sugar from PR 8.3 gets exercised against its first real
consumers in the same slice.

**Frame-driven eviction still deferred.** Same as PR 8.1 / 8.2 /
8.3: the new shared `Bounds` type and the renamed engine types
don't change retention semantics. State persists across frames
until the widget calls `.remove` explicitly. The frame-keyed
eviction shape (mirroring GPUI's `mem::swap`-on-`element_states`
pair) lands later alongside the rest of the `Frame` double-buffer
adoption in flight on PR 7c.3+.

### PR 8.4a landing notes (`scroll_container` on the pool)

**Status:** ✅ landed.

**Result:** `Build Summary: 9/9 steps succeeded; 1103/1103 tests
passed` (net +2 vs. PR 8.4-prep's 1101 — the two new
`getOrInsert` tests on the pool, covering the create-on-miss
runtime-init path and the on-hit `initial`-is-ignored stable
pointer property). `zig build install` clean.

**Files added:** none. `getOrInsert` lands as a new method on the
existing `ElementStates` container introduced in PR 8.1.

**Files edited:**

- `src/context/element_states.zig` — adds `getOrInsert(comptime
S, id_hash, initial: S) !*S`. The runtime-init twin of
  `withElementState`: same get-or-create shape, but accepts a
  caller-built initial value rather than a comptime `default`
  factory. Stateful widgets like `ScrollContainer`,
  `TextInputState`, `TextAreaState`, `CodeEditorState` capture
  allocator + bounds + debug id at the call site, so they can't
  use `withElementState`'s comptime factory; the runtime variant
  is the right shape. Two tests pin the shape: create-on-miss
  with runtime init values, and on-hit pointer stability with
  `initial` ignored (prevents every-frame clobber).

- `src/widgets/scroll_container.zig` — drops the unused
  `id: []const u8` field. Pre-PR-8.4 it held the duped key from
  `WidgetStore.scroll_containers`; post-PR-8.4 the pool keys
  on `LayoutId.id` so there's no duped string for the field to
  point at, and the field was only ever written, never read.
  `init(allocator, id)` becomes `init(allocator)` — same shape
  as `ScrollState`, `Style`.

- `src/context/widget_store.zig` — drops the
  `scroll_containers: StringHashMap(*ScrollContainer)` field, the
  matching init/deinit lines, the `T == ScrollContainer` arm in
  the generic `getOrCreateWidget` helper, and the two
  `scrollContainer(id)` / `getScrollContainer(id)` accessors. The
  retired-accessor section gets a doc comment recording the
  migration shape and pointing follow-on readers at the pool
  call pattern. Same retirement shape PR 8.2 used for the
  `select_states` field and accessors.

- `src/cx.zig` — `cx.scrollView(id)` routes through
  `g.element_states.getOrInsert(ScrollContainer, hash,
ScrollContainer.init(g.allocator))` (was
  `g.widgets.scrollContainer(id)`). Hashes the string id once at
  the boundary via `LayoutId.fromString(id).id`. Failure modes
  (OOM / `error.ElementStatesAtCapacity`) collapse to `null` so
  the public surface stays optional — same shape callers had
  pre-PR-8.4 against the `?*ScrollContainer` return.

- `src/ui/builder.zig` — `Builder.scroll` (the
  create-on-touch site) seeds the pool entry through
  `getOrInsert` with the layout id already in hand;
  `registerPendingScrollRegions` and the rest of the framework
  are read-only against the pool, so they use `get` keyed by
  `pending.layout_id.id`. Also flips
  `active_scroll_drag_id: ?[]const u8` to `?u32` (the cached
  drag id is now the layout-id hash that keys the pool slot,
  not a borrowed string slice). The flip avoids re-hashing the
  string at every drag event and — more importantly — sidesteps
  the lifetime hazard of holding a borrowed slice across the
  frame-render boundary that used to free the duped key when
  `WidgetStore.scroll_containers` rebuilt.

- `src/runtime/input.zig` — `handleScrollEvent`,
  `handleMouseDragEvent`, `handleScrollbarClick`,
  `handleMouseUpEvent` all switch from
  `window.widgets.getScrollContainer(string_id)` to
  `window.element_states.get(ScrollContainer, layout_id_hash)`.
  The `setActiveScrollDrag` call sites pass `pending.layout_id.id`
  instead of `pending.id`. Pure mechanical rewire alongside the
  field-type flip in `Builder`.

- `src/runtime/frame.zig` — `renderCommands`'s scrollbar
  rendering branch reads through `window.element_states.get(
ScrollContainer, pending.layout_id.id)`. Read-only `get`
  rather than `getOrInsert` because the slot was already seeded
  by `Builder.scroll` earlier in the frame.

- `src/widgets/data_table.zig`, `src/widgets/uniform_list.zig`,
  `src/widgets/virtual_list.zig` — each `syncScroll(b, id,
state)` helper hashes the string id at the boundary and
  reaches into the pool with read-only `get`. The helper still
  accepts `id: []const u8` because callers compose ids
  dynamically (e.g. `tree_list` derives ids from node paths);
  the hash happens at the helper boundary rather than forcing
  the caller to hash first.

**Why `scroll_container` first.** Per the slicing-strategy bullet
at the top of PR 8: smallest of the four remaining
retained-storage widgets and the only one with no focus-coupled
dispatch (only bounds + offsets are read by framework code). The
focused-widget fan-out in `runtime/input.zig`
(`handleKeyDownEvent`, `handleTextInputEvent`,
`handleCompositionEvent`, `updateImeCursorPosition`) that
`text_input` / `text_area` / `code_editor_state` share is not
involved here — `scroll_container` participates in mouse
drag/scroll events through the per-frame `pending_scrolls` queue,
keyed by layout id, with no per-instance focused-flag. That keeps
PR 8.4a as a clean validation of the runtime-init upsert
(`getOrInsert`) shape against a real consumer before the larger
text-family migration in PR 8.4b lands.

**Why `getOrInsert` (not `withElementState`).** The comptime
`withElementState(S, id_hash, default: fn() S)` API requires a
no-argument factory. `ScrollContainer.init(allocator)` doesn't
fit that shape — and `TextInputState.initWithId(allocator,
bounds, id)` won't fit either when PR 8.4b lands. The
runtime-init `getOrInsert(S, id_hash, initial: S)` API takes a
caller-built initial value: the call site captures the
allocator (and any other runtime-only init data) and hands the
pool a fully-constructed `S` to copy into the slot. On hit the
`initial` is ignored — that's what the second new test pins.
Bundling the upsert as a single pool method keeps the
get-or-create discipline in one place rather than re-litigating
the lookup boundary at every consumer.

**Why drop `ScrollContainer.id`.** Pre-PR-8.4 the field held the
duped key from `WidgetStore.scroll_containers` (the StringHashMap
owned the string memory; the field was a borrowed view of it).
Post-PR-8.4 the pool keys on `LayoutId.id` (a u32 hash), so
there's no duped string for the field to point at. A grep
confirmed the field was set on `init` but never read — the
StringHashMap key was the lookup mechanism, and the field was
just dead weight. Dropping it is part of the pure-data-shape
reduction PR 8 promises: each widget's storage shrinks to what's
load-bearing for its behaviour, with the framework owning only
the `(id_hash, type_id) -> *S` mapping.

**Why `Builder.scroll` is the seed site.** The create-on-touch
contract pre-PR-8.4 was `widgets.scrollContainer(id)` returning
a freshly-constructed instance on miss. That semantics is
preserved here: `Builder.scroll` calls `getOrInsert` (the
upsert), and the rest of the framework (input handlers, frame
renderer, list-widget sync helpers) uses read-only `get`. If a
scroll region renders this frame, its slot is guaranteed to
exist by the time input/render/sync read; if it doesn't render
(e.g. unmounted because of a state change), the slot persists
but is unreferenced, and a future `cx.element_states.remove`
call would tear it down. Frame-driven eviction stays deferred,
same as every prior PR 8.x slice.

**Why flip `active_scroll_drag_id` to u32.** The pre-PR-8.4
field type was `?[]const u8` — a borrowed slice into the
StringHashMap key memory that `WidgetStore.scroll_containers`
duped on insert and freed on `removeWidget`. Post-PR-8.4 the
pool doesn't dupe keys (it hashes once at the boundary), so
there's no duped key memory to point at. Storing the hash
directly is also faster: the previous shape rehashed the
`[]const u8` on every `getScrollContainer(drag_id)` call inside
`handleMouseDragEvent` (which fires per mouse-move during a
drag); the u32 flip skips the rehash. The drag-id flip is a
strict win on both memory safety (no dangling-slice risk
across frame boundaries) and per-event work.

**Frame-driven eviction still deferred.** Same as PR 8.1 / 8.2 /
8.3 / 8.4-prep: scroll-container state persists across frames
until the widget calls `.remove` explicitly (no caller does so
today). The pre-PR-8.4 `WidgetStore.scroll_containers` had no
GC either — the pool's retention semantics are identical to
the StringHashMap's. The frame-keyed eviction shape lands later
alongside the rest of the GPUI `Frame` double-buffer adoption.

### PR 8.4b landing notes (text widgets on the pool + focused-widget dispatch rewrite)

**Status:** ✅ landed.

**Result:** `Build Summary: 9/9 steps succeeded; 1103/1103 tests
passed` (no delta vs. PR 8.4a's 1103 — the migration is a pure
call-site refactor over the existing `getOrInsert` shape PR 8.4a
already pinned with two unit tests; no semantic change so no new
tests). `zig build install` clean.

**Files added:** none. The migration reuses the same
`getOrInsert` / `get` / `remove` API that PR 8.4a landed on the
pool.

**Files edited:**

- `src/widgets/text_input_state.zig` — drops the unused `id:
ElementId` field, the `getId()` method, and the
  `core/element_id.zig` import. Collapses `init` and
  `initWithId` into a single `init(allocator, bounds)`
  constructor (the unique-id counter inside the pre-PR-8.4b
  `init` only existed to populate the now-retired field). Same
  reduction PR 8.4a did to `ScrollContainer.id`.

- `src/widgets/text_area_state.zig` — same shape as
  `text_input_state.zig`: drops the `id` field, `getId()`, and
  the `ElementId` import; collapses `init` + `initWithId`.

- `src/widgets/code_editor_state.zig` — same shape, plus
  retiring the `generateUniqueId` atomic counter (the only
  reader was `init`'s `ElementId.int(generateUniqueId())`,
  which is gone).

- `src/widgets/mod.zig` — module-header doc-comment for the
  text-input section refreshed to describe the post-PR-8.4b
  ownership shape (engine state lives on
  `Window.element_states`, keyed by `(EngineType,
layout_id.id)`) instead of the pre-PR-8.4b `WidgetStore`
  ownership shape.

- `src/context/widget_store.zig` — drops the three
  `StringHashMap(*State)` fields (`text_inputs`, `text_areas`,
  `code_editors`), the matching three `default_*_bounds` fields
  that seeded the pre-PR-8.4b create-on-touch path, the
  `accessed_this_frame: AutoHashMap([*]const u8, void)`
  ptr-keyed set (it only existed to bridge the StringHashMap key
  memory across frames), the four generic widget helpers
  (`getOrCreateWidget` / `removeWidget` / `getFocusedWidget` /
  `deinitWidgetMap`), and every accessor verb on the three
  retired widget types (`textInput` / `textInputOrPanic` /
  `getTextInput` / `removeTextInput` / `hasTextInput` /
  `textInputCount` / `getFocusedTextInput`, plus the same shape
  for `textArea` / `codeEditor`, plus the cross-type `blurAll`
  walk). The `beginFrame` / `endFrame` methods stay in place —
  they're load-bearing for the animation + spring + motion
  pools — but the `accessed_this_frame.clearRetainingCapacity()`
  line goes with the field. Retired-section doc-comment block
  records the migration shape and points readers at the pool
  call pattern. Same retirement shape PR 8.4a used for
  `scroll_containers`, scaled up to the three text widget maps.

- `src/ui/builder.zig` — `Builder.renderInput` /
  `renderTextArea` / `renderCodeEditor` are the create-on-touch
  sites: each seeds the pool entry on first render via
  `g.element_states.getOrInsert(EngineType, layout_id.id,
EngineType.init(g.allocator, default_bounds))` and reuses the
  resulting borrow for both the focus-state read (border colour)
  and the focus-vtable wire-up (`FocusHandle.withWidget(ti.focusable())`).
  Reusing the borrow lets each render pay for at most one pool
  lookup per widget per frame. The default seed bounds live on
  `Builder` itself (`DEFAULT_TEXT_INPUT_BOUNDS` /
  `DEFAULT_TEXT_AREA_BOUNDS` / `DEFAULT_CODE_EDITOR_BOUNDS`)
  alongside the existing `MAX_PENDING_*` caps; pre-PR-8.4b they
  lived on three `WidgetStore.default_*_bounds` fields, which
  retired with the maps. The seed values are only observed by
  code that touches the widget before its first post-layout
  render (none today, but the engines' `init` paths assert sane
  geometry, so the seed has to satisfy `bounds.width > 0` etc.).

- `src/runtime/input.zig` — introduces three new helpers
  (`focusedTextInput` / `focusedTextArea` / `focusedCodeEditor`)
  that walk `builder.pending_*` and return the first
  `isFocused()` match against the pool. Each helper is
  `pub` so `runtime/frame.zig::updateImeCursorPosition` can
  reach them without re-implementing the walk. Every
  pre-PR-8.4b dispatch site (`handleKeyDownEvent`'s escape +
  tab + control-key arms, `handleTextInputEvent`,
  `handleCompositionEvent`, `handleScrollEvent`'s text-area /
  code-editor branches, `handleCodeEditorClick`,
  `syncBoundVariablesCx` / `syncTextAreaBoundVariablesCx` /
  `syncCodeEditorBoundVariablesCx`) flips from the retired
  `widgets.getFocusedText*` / `widgets.text*` accessors to
  these helpers (or to `window.element_states.get(EngineType,
pending.layout_id.id)` for the pending-list-keyed paths).
  Each per-event handler shares one `builder` borrow across
  all three text-widget arms so the pending-list walk is paid
  for at most once per event.

- `src/runtime/frame.zig` — `renderTextInputs` /
  `renderTextAreas` / `renderCodeEditors` switch from
  `window.widgets.text*(pending.id)` to
  `window.element_states.get(EngineType, @as(u64,
pending.layout_id.id))`. Read-only `get` because
  `Builder.render*` already seeded the slot earlier this frame;
  a `null` return means the seed itself failed (capacity
  exhaustion or OOM at builder time), in which case skipping
  the post-layout render for this frame is the right
  fail-safe. `updateImeCursorPosition` learns a `*const Builder`
  parameter and routes through the new `focusedText*` helpers
  (was three `window.widgets.getFocusedText*` accessors
  pre-PR-8.4b).

- `src/cx.zig` — `cx.textField` / `cx.textAreaWidget` /
  `cx.codeEditorWidget` are now read-only `get` against the
  pool, hashing the string id at the boundary via
  `LayoutId.fromString(id).id`. Same shape PR 8.4a used for
  `cx.scrollView`, except read-only — `Builder.render*` is the
  create-on-touch boundary for these three, so the user-facing
  `cx.*` accessor doesn't need the `getOrInsert` upsert. The
  accessors stay `?*T` for the case where the widget hasn't
  mounted yet (callback firing before the first render).

- `src/context/window.zig` — the PR 4 doc-comment block on
  the per-widget-type forwarder retirement is updated to call
  out PR 8.4b's further retirement of the
  `widgets.text*` / `widgets.codeEditor` proxy accessors that
  PR 4 callers were pointed at. Post-PR-8.4b the canonical
  call shape is `window.element_states.get(EngineType,
layout_id.id)`.

- `src/examples/code_editor.zig`, `src/examples/pomodoro.zig`,
  `src/examples/showcase.zig` — example-side rewires.
  `code_editor.zig` adds a `sourceCodeEditor(g)` private
  helper that hashes `"source"` once and reads from the pool;
  replaces the four `g.widgets.codeEditor("source")` call
  sites. `pomodoro.zig` hashes `"task-input"` at the call
  site. `showcase.zig`'s `onEvent` focused-text-widget guard
  now goes through `gooey.runtime.input.focusedText{Input,Area}`.

**Why fold PR 8.4c into PR 8.4b.** The original slicing plan
had `text_input` + `text_area` landing in PR 8.4b and
`code_editor_state` in a separate PR 8.4c. The focused-widget
dispatch fan-out in `runtime/input.zig` (`handleKeyDownEvent`,
`handleTextInputEvent`, `handleCompositionEvent`,
`updateImeCursorPosition`) already touches all three engines
together — keeping `code_editor_state` on `WidgetStore` would
have meant a third pass over the same dispatch sites in PR 8.4c
for no slicing benefit. The three engines also share the
`(initWithId, getId, ElementId field, atomic-counter)` shape
that PR 8.4b retires; splitting them would have meant two
rounds of the same engine-type cleanup. Folding `code_editor`
in keeps the call-site sweep to a single landing while leaving
the per-engine reduction work as three independent commits in
the file (one per engine).

**Why the focused-widget dispatch is `pending_*`-list-driven.**
Pre-PR-8.4b the framework reached for the focused text widget
through three per-type accessors on `WidgetStore`
(`getFocusedTextInput` / `getFocusedTextArea` /
`getFocusedCodeEditor`), each walking its own StringHashMap
and calling `isFocused()` on every entry. Two replacement
shapes were considered:

- **Walk the matching `pending_*` list and look up each
  entry in the pool by `layout_id.id`** (chosen). The
  pending lists are bounded
  (`MAX_PENDING_INPUTS = 256`,
  `MAX_PENDING_TEXT_AREAS = 64`,
  `MAX_PENDING_CODE_EDITORS = 32`) per CLAUDE.md §4's
  hard-cap rule, and the focused widget rendered this frame
  so its layout id is in one of the lists. Same upper-bound
  shape the pre-PR-8.4b StringHashMap walk had, without the
  dynamically-grown map.
- **Extend `Focusable` with a `typeId()` accessor and
  discriminate the focus manager's cached
  `focused_widget: ?Focusable` by type** (rejected). Pulls
  `TypeId` (a pool concept) into `context/focus.zig`, where
  it doesn't belong. The `Focusable` vtable's job is to
  drive `focus()` / `blur()` / `isFocused()` polymorphically
  — the framework deliberately doesn't know about the
  concrete widget type at the focus layer. Discriminating by
  type id at the dispatch site would have re-introduced the
  `context → widgets` backward edge PR 4 worked to retire.

The chosen shape lives in `runtime/input.zig` as three pure
helpers (`focusedTextInput` / `focusedTextArea` /
`focusedCodeEditor`) that take `(*Window, *const Builder)` and
return the first `isFocused()` match. Each per-event handler
in the same file shares one `builder` borrow across all three
helpers so the pending-list walk is paid for at most once per
event.

**Why drop the engine-type `id` fields and `initWithId`.** Same
rationale PR 8.4a used for `ScrollContainer.id`: pre-PR-8.4b
the field held either a counter-derived `ElementId.int(...)`
(for `init`) or a `ElementId.named(id)` view of the duped key
from `WidgetStore.text_inputs` (for `initWithId`). Post-PR-8.4b
the pool keys on `LayoutId.id` (a u32 hash), there's no duped
string for the field to point at, and `getId()` was unused
outside its own definition. Same dead-weight reduction as
`ScrollContainer.id`, scaled up to three engines. The atomic
counter `generateUniqueId` in `code_editor_state.zig` was the
only thing populating its `ElementId.int(...)` path — it goes
with the field.

**Why the `accessed_this_frame` set retires.** Pre-PR-8.4b the
set was keyed by `[*]const u8` (the heap-stable pointer of the
StringHashMap key), and `getOrCreateWidget` / `removeWidget` /
`beginFrame` were the only writers/clearers. The pool keys
directly on the layout-id hash with no duped string, so there
is no key memory to bridge. `Window.element_states` slots
persist across frames the same way pre-PR-8.4b widget map
entries did (no GC either way — the retention semantics are
identical), so the per-frame access tracking the set provided
was already moot for the text widgets. The frame-keyed
eviction shape lands later alongside the rest of the GPUI
`Frame` double-buffer adoption, same as every prior PR 8.x
slice.

**Why fold the docs migration into PR 8.4b too.** Same one-pass
discipline PR 8.4a used. The retired-section doc-comment in
`widget_store.zig` and the `Bounds` alias doc-comments in
`text_input_state.zig` / `text_area_state.zig` /
`code_editor_state.zig` all reference the pre-PR-8.4b shape
(`WidgetStore.default_*_bounds` field, `WidgetStore` import
path); leaving them stale across a slice boundary would have
meant a second pass over every doc-comment site to refresh the
references. Bundled here so the docs-vs-code drift never
appears.

**Frame-driven eviction still deferred.** Same as PR 8.1 / 8.2
/ 8.3 / 8.4-prep / 8.4a: text-engine state persists across
frames until the widget calls `.remove` explicitly (no caller
does so today). The pre-PR-8.4b
`WidgetStore.text_inputs` / `text_areas` / `code_editors`
StringHashMaps had no GC either — the pool's retention
semantics are identical to the StringHashMap's. The frame-keyed
eviction shape lands later alongside the rest of the GPUI
`Frame` double-buffer adoption.

---

### PR 8.4c landing notes (residual `WidgetStore` shrink-down)

**Status:** ✅ landed.

**Result:** `Build Summary: 9/9 steps succeeded; 1103/1103 tests
passed` (no delta vs. PR 8.4b's 1103 — the storage move is a
pure refactor with identical retention semantics, so no new tests
are introduced). `zig build install` clean.

**Note on the 8.4c slot.** PR 8.4b's task-list entry says
_"collapsing what was planned as PRs 8.4b + 8.4c into a single
landing"_ — that was correct at the time for the original
`code_editor_state` arm of 8.4c (which folded into 8.4b because
the focused-widget dispatch already touched all three text
engines together). What PR 8.4b did _not_ land was the residual
cross-cutting state left on `WidgetStore` after every
per-widget map had been peeled off: the four animation pools
(`animations`, `springs`, `motions`, `spring_motions`, all
u32-keyed `AutoArrayHashMapUnmanaged`) and the
`change_tracker: ChangeTracker` field. PR 8.4c is that final
shrink-down. The two paths the cleanup plan kept open for this
slot — _lift onto `Frame` with frame-keyed eviction_ or
_collapse to a one-field holder_ — resolved to the collapse
path; the rationale is in the trailing "Why collapse, not
frame-keyed eviction" section below.

**Files added:**

- `src/animation/store.zig` (~470 lines: ~340 lines of code +
  ~130 lines of doc comments). Public surface: `AnimationStore`
  with `init` / `deinit` / `beginFrame` / `endFrame` /
  `hasActiveAnimations`, plus the four pools and every existing
  per-pool API verb (`animateById` / `animate` /
  `restartAnimationById` / `restartAnimation` /
  `animateOnById` / `animateOn` / `isAnimatingById` /
  `isAnimating` / `getAnimationById` / `getAnimation` /
  `removeAnimationById` / `removeAnimation` / `springById` /
  `spring` / `staggerById` / `stagger` / `motionById` /
  `motion` / `springMotionById` / `springMotion`). The file
  header records the move rationale, what's _not_ here
  (`ChangeTracker`, promoted to a peer `Window` field), and the
  still-deferred frame-keyed eviction shape — a future migration
  alongside `focus` / `mouse_listeners` / `tab_stops` onto
  `Frame`.

**Files edited:**

- `src/animation/mod.zig` — re-exports `store` and
  `AnimationStore` alongside the existing engine modules.
  Symmetric with how `context/mod.zig` used to re-export
  `widget_store` / `WidgetStore` (now retired below).

- `src/context/window.zig` — replaces the `widgets: WidgetStore`
  field with two peer fields:
  - `animations: AnimationStore` (the four pools, lifted off
    `WidgetStore` verbatim).
  - `change_tracker: ChangeTracker = .{}` (the per-frame
    value-diffing storage, with a fixed-capacity default so no
    init/deinit hook is needed).

  All four `Window` init paths (`initOwned` / `initOwnedPtr` /
  `initWithSharedResources` / `initWithSharedResourcesPtr`)
  swap `.widgets = WidgetStore.init(allocator, io)` for
  `.animations = AnimationStore.init(allocator, io)` (and the
  field-by-field `*Ptr` paths add an explicit
  `self.change_tracker = .{}` since defaults don't apply when
  raw memory is initialised member-by-member). `Window.deinit`
  flips `self.widgets.deinit()` to `self.animations.deinit()`.
  `Window.beginFrame` / `endFrame` flip to
  `self.animations.beginFrame()` / `.endFrame()`.
  `Window.hasActiveAnimations` forwards to
  `self.animations.hasActiveAnimations()`. The `testWindow()`
  fixture's `.widgets = undefined` slot becomes
  `.animations = undefined` (the deferred-command tests this is
  built for never reach into either field). The PR 4 "Widget
  Access — moved to `window.widgets.*`" section header is
  refreshed to "Widget Access — moved to
  `window.element_states.get(T, id)`" with the inline comment
  block noting PR 8.4c retires the `widgets:` field they hung
  off entirely.

- `src/cx/animations.zig` — all 12 forwarder bodies flip from
  `self.cx()._window.widgets.X` to
  `self.cx()._window.animations.X`. Sweep done via `sed`; no
  semantic change.

- `src/cx.zig` — `cx.changed` routes through
  `self._window.change_tracker.changed(key_hash, value_hash)`
  (was `self._window.widgets.change_tracker.changed(...)`).

- `src/components/modal.zig` — one call site:
  `g.animations.animateOn(...)` (was `g.widgets.animateOn(...)`).

- `src/context/mod.zig` — drops the `widget_store` /
  `WidgetStore` re-export block. The file header replaces the
  `WidgetStore - Retained storage for stateful widgets` bullet
  with `ElementStates` + `ChangeTracker` bullets and a PR 8.4c
  note explaining where the four surviving subsystems live now
  (per-element state → `window.element_states.*`; animation
  pools → `window.animations.*`; value-change diffing →
  `window.change_tracker.*`). The retired-export section keeps
  a stub block recording the rationale so future readers
  searching for `WidgetStore` find the migration trail.

- `src/root.zig` — drops `pub const WidgetStore = context.WidgetStore;`.
  Replaces it with `pub const AnimationStore = animation.AnimationStore;`
  as the public type the framework now exposes (the only
  prior external user of `WidgetStore` from `root.zig` was
  this one re-export — no examples or downstream code referenced
  it).

- `src/context/widget_store.zig` — **deleted.** Git reports the
  change as a 66% rename to `src/animation/store.zig` (most of
  the body — the four pools and their methods — is preserved
  verbatim; the dropped pieces are the `change_tracker` field
  and the retired-section doc-comment blocks documenting earlier
  8.x slices' field retirements).

- `src/animation/animation.zig`, `src/animation/motion.zig` —
  three stale `WidgetStore` doc-comment references refreshed to
  point at `AnimationStore` / `animation/store.zig`. Two were
  section headers (`// Animation State (stored in WidgetStore)`
  → `// Animation State (stored in AnimationStore — see
animation/store.zig)`); one was a tick-function header
  comment in `motion.zig`. The file header on `animation.zig`
  records the rename for readers who arrive here looking for
  the historical name.

**Why collapse, not frame-keyed eviction.** The cleanup plan
left two paths open for this slot. The chosen path is the
collapse:

- The animation pools' retention semantics are _already_
  decoupled from `WidgetStore`'s frame lifecycle —
  `last_queried_frame` + `frame_counter` heuristics in
  `animateById` / `animateOnById` detect "completed AND not
  queried last frame" (component was hidden) and restart on
  re-mount. Replacing that with the GPUI swap-discipline
  shape (fall-through from `next_frame.animations` to
  `rendered_frame.animations` with carry-forward on hit)
  would have been a behavioral change (2-frame eviction
  semantics) layered on top of the structural change
  (`WidgetStore` retirement). The two concerns are
  independent; bundling them would have meant the structural
  cleanup couldn't land without also vetting the behavioral
  upgrade for every animation call site in every demo.
- Frame-keyed eviction is naturally a peer to PR 7c.3's
  deferred "migrate `focus` / `mouse_listeners` /
  `tab_stops` onto `Frame`" work — the
  double-buffer-with-carry-forward shape is a `Frame`
  concern, not a `WidgetStore` concern. Doing it inside
  PR 8 would have conflated two cleanups along an
  arbitrary boundary.
- Definition-of-done for PR 8 (_"All existing widget-state
  hash maps deleted"_, _"Adding `widgets/foo_state.zig`
  requires zero edits to the framework"_) was already met
  after 8.4b. PR 8.4c's remaining structural job was the
  namespace deletion — collapsing `WidgetStore` into its
  two natural homes (`AnimationStore` in `animation/`,
  `ChangeTracker` directly on `Window`) closes that job
  without taking on the orthogonal behavioral upgrade.

The doc-comment at the top of `animation/store.zig` records
the deferral chain so a future reader doesn't re-litigate
the trade-off.

**Why `AnimationStore` lives in `animation/`, not `context/`.**
The four pools have always been animation infrastructure that
happened to live in `context/widget_store.zig` for historical
reasons (when `WidgetStore` was the catch-all retained-storage
namespace). Lifting them next to the engines they drive
(`animation/animation.zig` for `AnimationState`,
`animation/spring.zig` for `SpringState`,
`animation/motion.zig` for `MotionState` / `SpringMotionState`)
puts the storage next to the types it stores. The dependency
edge from `context/window.zig` into `animation/store.zig` is
the same shape every other `context → engine` import has
(e.g. `context/window.zig → text/text_system.zig`,
`context/window.zig → svg/atlas.zig`); it is _not_ the
`context → widgets` backward edge PR 4 broke (that one was
about concrete widget _state_ types leaking into `Window`'s
field list).

**Why `ChangeTracker` is a peer field on `Window`, not on
`AnimationStore`.** `cx.changed(key, value)` is per-frame
value-diffing across arbitrary keys (theme toggles, window
dimensions, debounce inputs, etc.); the call-site mix is
unrelated to animation lifecycle. The two subsystems were
only colocated on `WidgetStore` because that struct was the
historical miscellaneous-retained-state bucket. Promoting
`ChangeTracker` to a peer `Window` field puts it alongside
the other fixed-capacity per-`Window` subsystems
(`hover: HoverState`, `blur_handlers: BlurHandlerRegistry`,
`cancel_registry: CancelRegistry`) — all of which carry
default values and require no init/deinit hook.

**Frame-driven eviction still deferred.** Same as every prior
PR 8.x slice: animation pool entries persist until the
caller invokes `removeAnimation` / `swapRemove` explicitly.
The pre-PR-8.4c `WidgetStore` pools had the same shape — PR
8.4c is a pure storage-move refactor with identical retention
semantics. The frame-keyed eviction shape lands later
alongside the rest of the GPUI `Frame` double-buffer adoption,
joining the `focus` / `mouse_listeners` / `tab_stops`
migration that PR 7c.3 deferred. See the doc-comment block
at the top of `animation/store.zig` for the deferral chain.

---

## PR 9 — `root.zig` slim + ownership flag drop + 7d-examples entry-point sweep

**Goal:** finish the API hygiene work that was deferred earlier,
and absorb PR 7's two carry-over tasks (7d-examples entry-point
migration, 7e ownership-flag audit pin). **Breaking** — bumps
the public surface.

**Why fold 7d-examples in here:** the only `pub fn main()`
survivors are the 39 example files in `src/examples/` plus the
`src/app.zig` doc-block examples (2026-05-19 audit). PR 9
already commits to touching every example for the `cx.foo`
forwarder rewrite and the demoted-name migration, so doing the
entry-point signature migration in the same sweep avoids two
passes over identical files. See the 7d-examples entry in
PR 7's sub-task list for the state-of-the-world that justifies
the fold.

**Hard dependency:** 7d-framework (`App.main` / `WebApp.main` /
`runCx` accept `init: std.process.Init`) must land first as a
standalone prep PR. PR 7's tracker still shows ☐ 7d because the
framework-side signature change hasn't landed; without it, no
example can adopt the `main(init)` shape. 7d-framework is small
and well-bounded — it touches `src/app.zig` only and threads
`init` through to `runCx`. It is _not_ included in PR 9 because
(a) its risk profile is "framework runtime entry-point", which
is independent from the re-export hygiene work below, and
(b) keeping the two separately revertable preserves the bisect
property if either breaks downstream embedders.

**`usingnamespace` removal — context for the shape below.** Zig
0.16 removed `usingnamespace`. The earlier draft of PR 9 (lost
from an unsaved editor buffer; reconstructed here from the
2026-05-21 inventory pass and the conversation that designed
the Option A shape) specified a `src/prelude.zig` file with
`pub usingnamespace struct { … }` and example headers reading
`usingnamespace gooey.prelude;` — neither compiles on 0.16. The
fix is **no separate prelude file at all**. Instead, `root.zig`
keeps exactly 7 flat re-exports as the curated core (the same 7
the old prelude file would have exposed), with everything else
demoted to namespaces. Each example reaches `gooey.Cx`,
`gooey.App`, `gooey.Color`, … directly — one fewer hop than
`gooey.prelude.X` would have provided, and no per-example
`usingnamespace` boilerplate to read past. See
[§15 prelude philosophy](./architectural-cleanup-plan.md#15-the-preludes-philosophy--tiny-curated-re-export)
for the rationale; that section's pre-0.16 sketch is the
historical record of why the curated-7 list still applies.

**Write scope:**

- `src/root.zig` (slim down to the 7 curated re-exports +
  namespaces — ~50 lines)
- `src/cx.zig` (delete deprecated forwarders from PR 5)
- `src/app.zig` (update doc-block `main` examples to match)
- `src/examples/*.zig` (39 files — demoted-name rewrites +
  `pub fn main(init: std.process.Init)` signature)
- examples-adjacent docs (one big sweep)

**Tasks:**

- [x] **Task 1 — Reshape `root.zig` to a 7-name curated-core
      header + namespaces section.** The curated 7 stay flat at
      `gooey.X` (matching the pre-0.16 prelude list); everything
      else moves to its namespace. Shortlist landed during the
      2026-05-21 inventory pass over `src/root.zig` (451 lines,
      168 `pub` decls, ~130 flat aliases). Usage data:
      `grep gooey.X src/examples/*.zig` over 39 example files.

      | # | Curated-core name | Resolves to | Justification |
      |---|---|---|---|
      | 1 | `run` | `app.runCx` | Literal one-liner entry point. 35/39 examples. Drops the awkward `Cx` suffix now that the legacy path is gone. |
      | 2 | `App` | `app.App` | `pub fn main` generator. 35/39 examples. |
      | 3 | `Cx` | `app.Cx` | Render-callback parameter type. 38/39 examples. |
      | 4 | `Window` | `context.Window` | Framework wrapper. Needed for render-fn signatures, global-state APIs, multi-window story. 15 explicit uses; conceptually present everywhere. |
      | 5 | `Color` | `core.Color` | The single literal-friendly value type used inside render fns (`Color.rgb(…)`). 10/39 uses. `Rect`/`Size`/`Bounds` are layout returns, almost never typed explicitly. |
      | 6 | `std_options` | root const | **Zig contract** — looked up by name on the root source file. Must live at `gooey.std_options` for the documented `pub const std_options = gooey.std_options;` one-liner to route logs to the browser console on WASM. |
      | 7 | `log` | `log.zig` | Sibling of `std_options`. The doc-block in `root.zig` already promises `gooey.log.scoped(.myapp)` as the zero-config entry point. |

      **Borderline candidates explicitly cut** (with rationale,
      so future re-litigation has the reasoning):

      | Candidate | Uses | Why not |
      |---|---|---|
      | `Button` | 27 | §15's rule is _no concrete component types_. If `Button` is in, then `TextInput, Modal, Image, Checkbox, Svg, …` have weaker but real cases too. Drawing the line at zero concrete components keeps the curated core principled. |
      | `runCx` | 4 | Superseded by `run`. Delete the long name. |
      | `Image` | 18 | Same reasoning as `Button`. Reach via `gooey.components.Image`. |
      | `Entity` | 11 | Power-user type. `gooey.context.Entity`. |
      | `lerp` | 10 | Animation primitive. `gooey.animation.lerp`. |
      | `Theme` | 2 | Genuine candidate, but only 2 uses and the theming story isn't settled. Reserve a slot for when it is. |

      Target shape for `root.zig` (~50 lines, well under the
      80-line ceiling):

      ```zig
      //! Gooey — top-level public surface.
      //!
      //! Two tiers:
      //!   1. The seven flat re-exports below are the curated core.
      //!      They satisfy ~all uses across `src/examples/*.zig` and
      //!      are the only names guaranteed to live at `gooey.X`.
      //!   2. Everything else lives under a namespace
      //!      (`gooey.core.Rect`, `gooey.components.Button`,
      //!      `gooey.animation.lerp`, …). A namespace is the
      //!      source-of-truth home; the curated-core flat names
      //!      are re-exports for ergonomics only.
      //!
      //! Earlier drafts of this layout planned a `src/prelude.zig`
      //! file plus `usingnamespace gooey.prelude;` in example
      //! headers. Zig 0.16 removed `usingnamespace`, so the prelude
      //! file collapses into this top-section comment.

      const std = @import("std");
      const builtin = @import("builtin");

      // ============ Curated core (7) ============

      pub const run         = @import("app.zig").runCx;
      pub const App         = @import("app.zig").App;
      pub const Cx          = @import("app.zig").Cx;
      pub const Window      = @import("context/mod.zig").Window;
      pub const Color       = @import("core/mod.zig").Color;
      pub const log         = @import("log.zig");
      pub const std_options: std.Options = if (builtin.os.tag == .freestanding)
          .{ .logFn = wasmLogFn } else .{};

      // ============ Namespaces ============

      pub const core          = @import("core/mod.zig");
      pub const input         = @import("input/mod.zig");
      pub const scene         = @import("scene/mod.zig");
      pub const context       = @import("context/mod.zig");
      pub const animation     = @import("animation/mod.zig");
      pub const layout        = @import("layout/layout.zig");
      pub const text          = @import("text/mod.zig");
      pub const ui            = @import("ui/mod.zig");
      pub const components    = @import("components/mod.zig");
      pub const widgets       = @import("widgets/mod.zig");
      pub const platform      = @import("platform/mod.zig");
      pub const runtime       = @import("runtime/mod.zig");
      pub const image         = @import("image/mod.zig");
      pub const svg           = @import("svg/mod.zig");
      pub const debug         = @import("debug/mod.zig");
      pub const validation    = @import("validation.zig");
      pub const accessibility = @import("accessibility/mod.zig");
      pub const ai            = @import("ai/mod.zig");
      pub const file_dialog   = @import("file_dialog.zig");
      pub const app           = @import("app.zig");
      pub const testing       = if (builtin.is_test) @import("testing/mod.zig") else struct {};

      // Internal — referenced by name from `std_options`.
      fn wasmLogFn(/* … */) void { /* unchanged body … */ }
      ```

      `wasmLogFn` drops `pub`; nothing outside `root.zig` should
      reach for it (grep confirmed — only doc-comments mention it
      in examples).

- [x] **Task 2 — Demote the rest of `root.zig`'s ~123 non-core
      flat re-exports** into namespace re-exports
      (`gooey.components.Button`, `gooey.core.Rect`, etc.). The
      7 curated-core names from Task 1 stay flat.

      **Demotion ledger.** Every row below is a pure deletion
      because the symbol is already reachable through its
      namespace (verified against each `mod.zig` during the
      inventory pass):

      | Cluster | Lines to delete from `root.zig` | Reachable as |
      |---|---|---|
      | Components (19) | `Button, Checkbox, TextInput, TextArea, CodeEditor, ProgressBar, RadioGroup, RadioButton, Tab, TabBar, Svg, Icons, Lucide, Select, Image, AspectRatio, Tooltip, Modal, ValidatedTextInput` | `gooey.components.*` |
      | Geometry (10) | `Point, Size, Rect, Bounds, PointF, SizeF, BoundsF, Edges, Corners, Pixels` | `gooey.core.*` (`Color` stays in curated core, see Task 1) |
      | Input (6) | `InputEvent, KeyEvent, KeyCode, MouseEvent, MouseButton, Modifiers` | `gooey.input.*` |
      | Event system (4) | `Event, EventPhase, EventResult, ElementId` | `gooey.input.*` + `gooey.core.ElementId` |
      | Scene (6) | `Scene, Quad, Shadow, Hsla, GlyphInstance, render_bridge` | `gooey.scene.*` |
      | Image (5) | `ImageAtlas, ImageSource, ImageData, ObjectFit, wasm_image_loader` | `gooey.image.*`; `wasm_image_loader` migrates to `platform.web.image_loader` — see Task 2.5 below |
      | Window/runtime (8) | `AnimationStore, WindowId, WindowRegistry, WindowHandle, WindowContext, MultiWindowApp, AppWindowOptions, MAX_WINDOWS` | `Window` stays in curated core (see Task 1); `gooey.animation.AnimationStore`; rest at `gooey.platform.*` or `gooey.runtime.*` |
      | Layout (7) | `LayoutEngine, LayoutId, Sizing, Padding, CornerRadius, LayoutConfig, BoundingBox` | `gooey.layout.*` |
      | Widgets state (14) | `UniformListState, VirtualListState, VisibleRange, ScrollStrategy, DataTableState, DataTableColumn, SortDirection, RowRange, ColRange, VisibleRange2D, TreeListState, TreeNode, TreeEntry, TreeLineChar` | `gooey.widgets.*` |
      | Focus (4) | `FocusId, FocusHandle, FocusManager, FocusEvent` | `gooey.context.*` |
      | Cx/App (3) | `runCx, WebApp, CxConfig` | `Cx`/`App`/`run` stay in curated core (see Task 1); `CxConfig` at `gooey.runtime.CxConfig`; **`WebApp` deleted outright** (only `App` calls it, kept internal in `app.zig`); **`runCx` deleted outright** in favor of curated-core `run` |
      | Font/shader (2) | `FontConfig, CustomShader` | `gooey.context.FontConfig`, `gooey.core.CustomShader` |
      | Entity (5) | `Entity, EntityId, EntityMap, EntityContext, isView` | `gooey.context.*` |
      | Handler (3) | `HandlerRef, OnSelectHandler, typeId` | `gooey.context.HandlerRef`, `gooey.context.OnSelectHandler` (new, see Task 2.5), `gooey.context.typeId` |
      | Animation core (7) | `Animation, AnimationHandle, Easing, Duration, lerp, lerpInt, lerpColor` | `gooey.animation.*` |
      | Animation sub-mods (11) | `spring_mod, SpringConfig, SpringHandle, stagger_mod, StaggerConfig, StaggerDirection, motion_mod, MotionConfig, MotionHandle, MotionPhase, SpringMotionConfig` | `gooey.animation.spring`, `gooey.animation.stagger`, `gooey.animation.motion` are already namespaces; concrete types at `gooey.animation.*` |
      | Text (3) | `TextSystem, FontFace, TextMeasurement` | `gooey.text.*` |
      | UI styles (13) | `Builder, Theme, Box, StackStyle, CenterStyle, ScrollStyle, UniformListStyle, VirtualListStyle, TreeListStyle, DataTableStyle, InputStyle, TextAreaStyle, CodeEditorStyle` | `gooey.ui.*` |
      | Platform (10) | `MacPlatform, PlatformWindow, PlatformVTable, WindowVTable, PlatformCapabilities, WindowOptions, RendererCapabilities, PathPromptOptions, PathPromptResult, SavePromptOptions` | `gooey.platform.*` — **`MacPlatform` deleted outright**, callers use `gooey.platform.Platform` |

      **Total:** ~123 lines of flat aliases plus their
      doc-comments removed (the 7 curated-core names stay) →
      `root.zig` goes from 451 → ~50 lines.

- [x] **Task 2.5 — Module-side prep (lands before Task 2's
      deletes).** Three small additions so the deletions land
      cleanly:

      1. **`wasm_image_loader` → `platform.web.image_loader`.**
         The conditional-stub block currently lives in _two_
         places: `root.zig:234-256` (the public alias) and
         `runtime/render.zig:40-50` (a private `wasm_loader`
         alias that reaches the WASM-only loader directly,
         missed by the original grep). Move the conditional
         stub into `platform/mod.zig`'s inline `pub const web`
         struct (the existing `is_wasm`-gated branch already
         exposes `platform`, `window`, `imports`, and
         `file_dialog` — add `image_loader` next to them, plus
         a parallel stub in the `else` branch). Both call sites
         then resolve through `gooey.platform.web.image_loader.*`,
         eliminating the duplicate.
      2. **`OnSelectHandler` promotion.** Reachable today as
         `context.handler.OnSelectHandler` (`handler` is a
         `pub const` in `context/mod.zig:244`). Add a sibling
         re-export next to `HandlerRef`:
         `pub const OnSelectHandler = handler.OnSelectHandler;`.
         Mirrors `HandlerRef`, lets the `root.zig` deletion be
         unconditional.
      3. **`render_bridge`** — already at `scene.render_bridge`
         (`scene/mod.zig:145`). No work, just confirmed during
         inventory.

- [x] **Task 3 — Delete every deprecated `cx.foo` forwarder**
      added in PR 5 in favor of `cx.lists.foo` / `cx.animate.foo`
      / etc.

- [x] **Task 4 — (folded from 7d-examples, then folded again
      into 7d-framework) Migrate every example to
      `pub fn main(init: std.process.Init)`** per
      [§9 "Juicy Main"](./zig-0.16-changes.md#9-juicy-main).
      Landed as part of 7d-framework because the framework
      signature change forced the example sweep into the
      same PR — examples cannot construct `std.process.Init`
      themselves, so the moment `App.main` requires `init`,
      every example calling `App.main()` must learn the new
      signature in lockstep. 36 of 39 examples migrated
      (the 3 holdouts: `ai_canvas.zig` already had the new
      shape pre-7d; `linux_demo.zig` and `multi_window.zig`
      don't call `App.main` / `runCx` at all and stayed on
      bare `pub fn main() !void`, which is one of the three
      valid Zig 0.16 shapes). No example reaches for
      `std.os.argv` / `std.process.getEnvMap` /
      `std.process.argsAlloc` (already true in `src/` per
      the audit; reconfirmed during the 7d-framework sweep).

- [x] **Task 5 — (folded from 7e) Pin the structural `_owned`
      audit.** Add a compile-time test (or `build.zig` grep step)
      that fails if any `_owned: bool` field appears on `Window`
      or any of its sub-structs. `AppResources.owned` and
      `Frame.owned` are explicitly allow-listed — they are the
      deliberate two-shape ownership discriminators landed in
      7a / 7c.3a. The cache-marker `owned: bool` fields on
      `DecodedImage` (web image loader) and `ShapedRun` (text)
      are also allow-listed — they're per-entry "free this
      slice?" markers, not lifecycle flags.

**Examples sweep — concrete touch list.** From the usage grep,
only 5 demoted names are touched by more than ~5 example files:

| Symbol         | Example uses | Migration                                   |
| -------------- | ------------ | ------------------------------------------- |
| `gooey.Button` | 27           | → `gooey.components.Button`                 |
| `gooey.Image`  | 18           | → `gooey.components.Image`                  |
| `gooey.Entity` | 11           | → `gooey.context.Entity`                    |
| `gooey.Color`  | 10           | → no change (`Color` stays in curated core) |
| `gooey.lerp`   | 10           | → `gooey.animation.lerp`                    |

Everything else: ≤5 sites total, mechanical.

**Commit order inside PR 9** (keeps each commit independently
green):

1. Module-side prep (Task 2.5): one commit each
   (`platform.web.image_loader` move + duplicate stub cleanup;
   `context.OnSelectHandler` re-export).
2. Migrate the vertical proof: `counter.zig` first, then
   `tooltip.zig`. Confirms the example shape works
   end-to-end (`gooey.<ns>.X` for demoted names +
   `pub fn main(init: std.process.Init)` signature). No
   `usingnamespace` step is involved; each example just
   changes the small set of demoted-name references plus the
   `main` signature line.
3. Sweep the remaining 37 examples + `src/app.zig` doc-block
   examples. The Task 4 (`pub fn main(init: std.process.Init)`)
   migration lands in the same commits — both touch the same
   line in each file.
4. Delete `cx.foo` deprecated forwarders (Task 3). Independent
   of the demotion work — can land in parallel with steps 2–3
   if a different agent picks it up.
5. Slim `src/root.zig` to the target shape. With nothing
   referencing the demoted flat aliases anymore, this is a
   pure delete commit.
6. Owned-flag audit (Task 5) — compile-time test in
   `build.zig`'s test step that fails if any `_owned: bool`
   field appears outside the allow-list.
7. `CHANGELOG.md` migration table.

**Risk callouts:**

- **`std_options` lookup** — Zig finds `std_options` by walking
  the root source file, so the `pub const std_options` in
  `root.zig` must keep its exact name and stay at the top
  level. The curated-core list keeps it there.
- **`gooey.app` namespace stays** — even with the curated-core
  flat re-exports, power users still want `gooey.app.CxConfig`
  etc. Don't delete the namespace alias; it's distinct from
  the curated-core entries.
- **`MacPlatform` deletion** — verify no out-of-tree consumers
  (Spaceship/showcase tools, docs, README snippets) before the
  slim commit. Quick repo-wide grep gates the deletion.

**Definition of done:**

- `wc -l src/root.zig` < 80.
- `root.zig` exposes exactly 7 flat re-exports as the curated
  core (`run`, `App`, `Cx`, `Window`, `Color`, `log`,
  `std_options`); the rest live under namespaces.
- All 39 examples on `pub fn main(init: std.process.Init)`; no
  bare `pub fn main()` left in `src/examples/` or
  `src/app.zig` doc-blocks.
- Allow-listed `owned: bool` audit (task 5) running in
  `zig build test`.
- A migration note in `CHANGELOG.md` listing every renamed
  symbol.

### PR 9 landing notes

**Status:** ✅ landed.

**Result:** `Build Summary: 9/9 steps succeeded; 1121/1121 tests
passed` (vs. PR 8.4c's 1103 — +21 from the explicit
test-discovery anchor block in `root.zig` reaching leaf files the
pre-PR-9 flat aliases used to touch incidentally, +3 from the
new `_owned` audit tests, -2 from the deprecated forwarder /
`DataTableCallbacks` alias test deletions). `zig build install`
builds all 39 examples clean.

**Definition-of-done deviations:**

- `wc -l src/root.zig` = **407**, not <80. The 80-line target
  assumed namespace re-exports would transitively force
  `test {}` block analysis in leaf files (the way the pre-PR-9
  flat aliases did). They don't — `std.testing.refAllDecls`
  walks decls by reference but does not recurse through
  namespace imports' nested decls, and Zig 0.16's lazy comptime
  analysis means leaf-file tests stay out of the test binary
  unless something forces analysis of that file. Without an
  explicit anchor block, the slim drops ~41 tests off the
  baseline. The corrective recursive `refAllDeclsRecursive`
  utility was tried first and surfaced ~4 pre-existing dormant
  compilation bugs in unrelated subsystems
  (`accessibility/mod.zig:41` references an undefined
  `Accessibility` decl, `animation/store.zig:376` calls a
  non-pub `exitConfig`, `components/tabs.zig:223` has a
  type-coercion issue, `ui/canvas.zig` mishandles
  `*const PathMesh` as optional, `widgets/text_area_state.zig:404`
  switches on an auto-layout struct). Those are real bugs but
  out of scope for the cleanup PR; the explicit anchor block
  sidesteps them by reaching only the well-formed leaves we
  care about. The anchor block carries the rationale inline so
  a future reader doesn't try to shrink it back.

**Files added:**

- `src/context/owned_flag_audit.zig` (~130 lines: ~70 lines of
  code + ~60 lines of doc-comment header explaining the
  retirement chain). Compile-time audit: walks `Window`'s field
  list and fails the build if any `_owned: bool` or `owned: bool`
  field appears outside the explicit allow-list. The
  allow-list (`isAllowListedField`) carries four entries:
  `AppResources.owned` (PR 7a ownership discriminator),
  `Frame.owned` (PR 7c.3a ownership discriminator),
  `DecodedImage.owned` (per-entry WASM image-loader cache marker),
  `ShapedRun.owned` (per-entry text-shaping cache marker). Three
  tests: the audit fires against `Window`, the allow-list pins
  `AppResources.owned` and `Frame.owned` presence (so a
  rename catches as a test failure, not a silent allow-list
  miss). Hooked into `zig build test` through
  `context/mod.zig`'s `test {}` block.

- `docs/CHANGELOG.md`. New file. Migration index listing every
  demoted name + its new namespace path, the 28 deleted
  `cx.foo` forwarders + their `cx.<sub-namespace>.bar`
  replacements, the curated-core seven, and the `_owned: bool`
  audit's allow-list.

**Files edited (high-impact):**

- `src/root.zig` — 451 → 407 lines. Top section: 7 curated-core
  re-exports (`run`, `App`, `Cx`, `Window`, `Color`, `log`,
  `std_options`). Middle section: 21 namespace re-exports
  (`core`, `input`, `scene`, `context`, `animation`, `layout`,
  `text`, `ui`, `components`, `widgets`, `platform`, `runtime`,
  `image`, `svg`, `debug`, `validation`, `accessibility`, `ai`,
  `file_dialog`, `app`, `testing`). Bottom section:
  `wasmLogFn` (private, used by `std_options`) and the test
  block. The test block includes (a) the standard
  `refAllDecls(@This())`, (b) a comptime block touching ~70
  leaf types previously reached through flat aliases (verbose
  but explicit), (c) an `inline for` over leaf-module imports
  whose file-level `test {}` blocks dropped out of the
  discovery set after the slim.

- `src/platform/mod.zig` — the `pub const web` struct gains a
  fifth member (`image_loader`) on the WASM branch and a
  parallel stub on the native branch. Replaces the duplicate
  `wasm_image_loader` shim that used to live in both
  `root.zig` (public) and `runtime/render.zig` (private).

- `src/runtime/render.zig` — drops the private `wasm_loader`
  conditional shim (12 lines of dead duplicate) in favour of
  `const wasm_loader = platform.web.image_loader;`. Same shape
  the public alias now resolves through.

- `src/context/mod.zig` — `OnSelectHandler` promoted to a
  direct re-export next to `HandlerRef` (was reachable only
  through `context.handler.OnSelectHandler`, which made the
  `gooey.OnSelectHandler` deletion in PR 9 Task 2 messier than
  it needed to be). The `test {}` block now also walks
  `owned_flag_audit.zig`.

- `src/cx.zig` — deletes 28 deprecated forwarder methods
  (`createEntity` / `readEntity` / `writeEntity` / `entityCx` /
  `focusNext` / `focusPrev` / `blurAll` / `focusTextField` /
  `focusTextArea` / `isElementFocused` / `animateComptime` /
  `animate` / `restartAnimationComptime` / `restartAnimation` /
  `animateOnComptime` / `animateOn` / `springComptime` /
  `spring` / `staggerComptime` / `stagger` / `motionComptime` /
  `motion` / `springMotionComptime` / `springMotion` /
  `uniformList` / `treeList` / `virtualList` / `dataTable`) and
  the `Cx.DataTableCallbacks(CxType)` deprecated alias. Cleans
  up ~25 now-unused imports (the `Animation` / `SpringConfig` /
  `MotionConfig` etc. aliases that only the deleted forwarders
  referenced). File shrinks from 871 → ~720 lines.

- `src/cx_tests.zig` — deletes the `DataTableCallbacks:
deprecated alias produces same type as cx.lists`
  equivalence test (the deprecated alias is gone). The
  `DataTableCallbacks type structure` test points at
  `cx.lists.Lists.DataTableCallbacks(Cx)` (the canonical
  generic) rather than the deleted `Cx.DataTableCallbacks(Cx)`
  alias.

- `src/app.zig` — doc-block example rewritten from the
  stale-pre-PR-7d `gooey.UI` shape to the post-PR-9
  `pub fn main(init: std.process.Init)` + `*gooey.Cx` shape.
  The `WebApp` doc-block reroutes the example through the
  cross-platform `gooey.App` generator (now the only
  documented WASM entry point).

- `src/examples/*.zig` — 31 example files updated by a
  scripted sweep (`/tmp/gooey_rewrite.pl`). Every
  `gooey.<DemotedName>` reference flips to its namespace
  (`gooey.components.Button`, `gooey.context.Entity`,
  `gooey.animation.lerp`, …). `gooey.runCx` → `gooey.run`
  across 4 examples. The Color / Cx / App / Window curated
  names stay untouched.

- `src/examples/spaceship.zig` — 11 `cx.animate*` / `cx.spring*`
  call sites flipped to `cx.animations.tween*` /
  `cx.animations.spring*` etc.

- `src/animation/animation.zig`, `src/widgets/data_table.zig`,
  `src/widgets/uniform_list.zig`, `src/widgets/virtual_list.zig`
  — four doc-comment-only updates rewriting `cx.animate(...)` /
  `cx.dataTable(...)` / `cx.uniformList(...)` / `cx.virtualList(...)`
  to the `cx.animations.tween(...)` / `cx.lists.dataTable(...)`
  / `cx.lists.uniform(...)` / `cx.lists.virtual(...)` shape.

**Why the test-discovery anchor block is necessary.** Three
alternatives were considered before landing the explicit list:

- **Option (a) — explicit leaf anchors** (chosen). `root.zig`'s
  test block ends with an `inline for ([...]) |ns| { refAllDecls(ns); }`
  block that touches ~45 leaf files. Verbose but stable: every
  anchored file becomes a guaranteed-discovered file, with
  inline rationale recorded next to the list.
- **Option (b) — recursive `refAllDeclsRecursive` utility**
  (rejected). A `refAllDeclsRecursive(comptime T: type)`
  helper walking every nested struct/enum/union declaration
  would have been a single 15-line function instead of a 70-
  line anchor list. It surfaced 4 pre-existing dormant
  compilation bugs (enumerated above) on first run, all in
  subsystems orthogonal to PR 9's scope. Fixing them is
  appropriate follow-up work but not a blocker for PR 9. The
  recursive utility lives at HEAD for whoever picks up the
  follow-up.
- **Option (c) — accept the test-count drop** (rejected). 41
  tests is small in absolute terms but represents real
  coverage of `widgets/data_table.zig`, `widgets/tree_list.zig`,
  `animation/spring.zig`, etc. Losing it silently to a
  re-export reshuffle would be a regression.

**Why `MacPlatform` and `WebApp` deletions are safe.** The grep
results are unambiguous: zero out-of-tree references for either
name. `gooey.MacPlatform` is only referenced inside the
`platform/macos/` subtree (which uses the un-prefixed
`MacPlatform` struct directly, not the `gooey.MacPlatform`
alias). `gooey.WebApp` survives only as a doc-comment in
`src/app.zig` (rewritten in PR 9 to reach for `gooey.App`).
Neither name appears in any example file.

**Why the `cx.foo` deprecation period was short.** PR 5 (the
sub-namespacing landing) carried the deprecated forwarders
specifically as a migration aid for in-tree call sites; the
doc records the intent that they'd be deleted in PR 9 once the
sub-namespaces stabilised. Five months elapsed between PR 5 and
PR 9 — enough time for every internal caller (just `spaceship.zig`
in the end) to migrate to the new shape.

---

## PR 10 — Layout engine split + fuzz targets

**Goal:** break `layout/engine.zig` (4,009 lines, way over the 70-line
function limit's spirit) into per-pass files. Add fuzz targets while
we're in here.

**Write scope:**

- `src/layout/engine.zig` (becomes a façade, ~300 lines)
- `src/layout/sizing_pass.zig` (new)
- `src/layout/position_pass.zig` (new)
- `src/layout/scroll_pass.zig` (new)
- `src/layout/fuzz.zig` (new)

**Tasks:**

- [x] Split per pass: sizing, position, scroll. Each pass file is
      self-contained, takes the layout tree by `*const` reference, and
      writes results into a pass-specific output buffer.
- [x] Each pass enforces the 70-line function limit
      (CLAUDE.md §5). Where a long function exists, push pure
      computation to leaves.
- [ ] 0.16: vector-indexing audit on layout SIMD
      (per [§21 vectors](./zig-0.16-changes.md#vectors)). **Deferred to
      follow-up** — the layout pipeline doesn't currently use SIMD
      vector types directly; `rg @Vector src/layout/` returns zero hits.
      The audit is a no-op for this PR; the follow-up will land if
      `@Vector` shows up in a hot path during PR 11.
- [x] 0.16: add `std.testing.Smith` fuzz targets per
      [§28 takeaways](./zig-0.16-changes.md#28-gooey-specific-takeaways)
      — at minimum a layout-tree fuzzer that randomizes node trees and
      asserts pass invariants.
- [x] Loop-vectorization perf re-baseline (LLVM 21 regression). Run
      benches before/after; record numbers in
      `docs/benchmarks/`. **No code change expected — this is
      measurement only.** If a regression exceeds 10% on a hot path,
      file a follow-up issue, don't block this PR.

**Definition of done:**

- No file in `src/layout/` exceeds 1,500 lines.
- `zig build fuzz` runs the new layout fuzzer.
- Bench numbers recorded.

### PR 10 landing notes

**Status:** ☑ landed.

**Result:** `Build Summary: 9/9 steps succeeded; 1121/1121 tests passed`
(same total as PR 9's 1121 — the engine-tests split is a pure file
move, no new test bodies). Bench numbers post-split are **uniformly
faster** than the PR 9 baseline (full table below); two benches
improved past the >10% "improved" threshold (`nested_vertical_stack`
-16.6%, `full_percentage_and_ratio` -17.5%) and the remaining 22 are
all in the -1% to -14% range. **Zero regressions.** This is almost
certainly the function-decomposition work helping inlining and
register pressure — the per-pass free functions take `*LayoutEngine`
once and operate on primitives thereafter, exactly the
[CLAUDE.md §20](../CLAUDE.md) hot-loop shape.

**File-size DoD result.** `wc -l src/layout/*.zig`:

| File                        | Lines | Notes                                                                          |
| --------------------------- | ----: | ------------------------------------------------------------------------------ |
| `layout.zig`                |    66 | Public re-exports + test discovery anchor                                      |
| `arena.zig`                 |    68 | Unchanged                                                                      |
| `layout_id.zig`             |   146 | Unchanged                                                                      |
| `render_commands.zig`       |   204 | Unchanged                                                                      |
| `fuzz.zig`                  |   292 | **new** — `std.testing.Smith` targets + 3 invariant checks                     |
| `scroll_pass.zig`           |   310 | **new** — Phase 4: render commands + scissor framing                           |
| `position_pass.zig`         |   430 | **new** — Phase 3: positions + floating positioning                            |
| `types.zig`                 |   628 | Unchanged                                                                      |
| `engine.zig`                |   775 | **was 4,009** — now the LayoutEngine façade (types, builder API, orchestrator) |
| `engine_tests.zig`          |   937 | **new** — integration tests split out for the 1,500-line ceiling               |
| `benchmarks.zig`            |   949 | Unchanged                                                                      |
| `engine_internal_tests.zig` |   958 | **new** — data-structure / fast-path / fuzzer-found-bug tests                  |
| `sizing_pass.zig`           | 1,088 | **new** — Phases 1 & 2 (min/final sizes + text wrap) + grow/shrink             |

No file exceeds 1,500. The old `engine.zig` at 4,009 lines is gone.

**Function-size DoD result.** No function in `src/layout/` exceeds 70
lines of body. The pre-PR-10 offenders (`positionChildren` 144L,
`wrapText` 123L, `findWordBoundaries` 102L, `distributeShrink` 98L,
`computeMinSizes` 86L, `distributeSpace` 75L, `createElement` 71L)
were split by extracting pure computation into named helpers —
`accumulateChildMinSizes`, `sumDesiredSizes`, `accumulateWordsIntoLines`
+ `finalizeLastLine` + `LineResidual`, `emitOnNewline` / `emitOnSpace`
/ `emitFinalWord` with a `WordScanState` struct, `assignShrunkSize` +
`recurseShrinkChildren`, `distributionParams` + `crossAxisOffset` +
`sumChildrenAlongMainAxis`, `checkIdCollision` + `indexElementId` +
`trackFloatingElement` + `linkToParent`. The parent functions retain
all control flow per [CLAUDE.md §5](../CLAUDE.md) ("keeping control
flow (switches, ifs) in parent functions, moving pure computation to
helpers").

**Fuzzer found two pre-existing bugs.** Both surfaced on the first
`zig build fuzz` run, before any iteration tuning:

1. **`findWordBoundaries("", …)` panics.** The pre-PR-10 function
   asserted `text_str.len > 0` and `wrapText` didn't gate empty
   inputs. Fix: add an explicit `text_str.len == 0` short-circuit in
   `wrapText` (which is the public boundary), keep the assertion in
   `findWordBoundaries` as a documented precondition.
2. **`emitWrappedLines` over-asserted.** During the file split I added
   `assert(lines.len > 0)` to the extracted helper. The fuzzer caught
   that `wrapText` can legitimately return `&.{}` for no-op inputs and
   the caller's loop should simply run zero iterations. Replaced the
   bad assertion with two true preconditions: `font_size > 0` and
   `align_width >= 0`.

Both fixes shipped in the same commit as the file split because the
bugs only manifest after the split (helper #2 didn't exist before,
and helper #1's precondition documentation is now meaningful with the
new entry point). The fuzz targets remain green going forward.

**Cross-file invariants asserted by the fuzzer** (see `fuzz.zig`):

- `z_index` non-decreasing across the sorted command list
- `(scissor_start, scissor_end)` pairs balanced as a stack
- Every emitted bbox has finite coords and non-negative
  `width`/`height`

These are stated as engine post-conditions in `endFrame`'s doc-comment
and are now enforced by the fuzzer at every iteration.

**Test reorganization (folded into PR 10 because the 1,500-line file
cap forced the split).** The 1,818 lines of integration tests that
used to live at the bottom of `engine.zig` moved into two new files:

- `engine_tests.zig` (937 L): high-level engine tests — basic/nested/
  shrink/aspect/percent/floating/text-wrap/propagate/z-index/text-
  alignment/main-axis-distribution/SourceLoc.
- `engine_internal_tests.zig` (958 L): data-structure tests —
  `FixedCapacityArray`, `open_element_stack` / `floating_roots`
  fixed-capacity invariants, `id_to_index` pre-allocation,
  `beginFrame` clearing, UTF-8 text-wrap, floating `expand`,
  `Offset2D`, `WordInfo`, `distributeGrow`/`distributeShrink`
  correctness, fast-path coverage.

`layout.zig`'s `test {}` block routes test discovery to both via
`_ = @import("…_tests.zig")` so `zig build test` continues to find
them. **The two `SourceLoc.getBasename` tests** updated their
expected literal from `"engine.zig"` to the new test-file basenames
— the test still proves `getBasename` works, just on its current
residency.

**"Pass" semantics inside `endFrame` are unchanged.** The orchestrator
in `LayoutEngine.endFrame` / `endFrameTimed` still calls the phases
in the same order with the same arguments; only the call target
moved from `self.computeMinSizes(...)` to
`sizing_pass.computeMinSizes(self, ...)`. Timers, the
no-floating-roots z-sort skip, and the early-return on empty trees
all behave identically. The benchmark numbers below confirm there's
no functional drift.

**`scroll_pass.zig` naming.** The cleanup plan called this file
`scroll_pass.zig`; in practice it owns *all* of Phase 4 (render
command emission). I kept the planned name because the dominant
cross-cutting concern in that phase is scroll-container framing —
every scroll element gets paired `scissor_start` / `scissor_end`
commands wrapping its children, and that's the only state the
pass-level invariant assertions (in `fuzz.zig`) care about. The
per-primitive emit helpers (`emitShadow` / `emitRectangle` /
`emitBorder` / …) are leaves of the scroll-aware walk.

**Deferred 0.16 audit (vector indexing).** `rg @Vector src/layout/`
returns nothing today; the only SIMD-shaped paths in the layout
pipeline are scalar `f32` arithmetic over `LayoutElement.computed.*`.
The [§21 vectors](./zig-0.16-changes.md#vectors) audit was a no-op
for this PR. If PR 11's `Element` lifecycle work introduces SIMD
batching, that PR will absorb the audit there.

#### PR 10 bench comparison

Full `bench-compare` output: baseline =
`docs/benchmarks/macos-aarch64-layout-benchmarks-04-23-2026.json`
(pre-PR-10), current =
`docs/benchmarks/macos-aarch64-layout-benchmarks-05-20-2026.json`
(post-PR-10). Threshold 15%.

```
  Name                                          Baseline         Current     Delta  Status
--------------------------------------------------------------------------------------------------
  wide_no_wrap_simple_few                    55.45 ns/op     53.86 ns/op     -2.9%
  deep_nesting                               59.21 ns/op     55.70 ns/op     -5.9%
  space_distribution                         55.47 ns/op     53.00 ns/op     -4.4%
  percentage_sizing                          55.99 ns/op     54.44 ns/op     -2.8%
  shrink_overflow                            57.00 ns/op     53.66 ns/op     -5.9%
  expand_with_max_constraint                 42.77 ns/op     39.65 ns/op     -7.3%
  expand_with_min_constraint                 39.70 ns/op     39.29 ns/op     -1.0%
  mixed_layout                               46.98 ns/op     43.14 ns/op     -8.2%
  nested_vertical_stack                      65.03 ns/op     54.21 ns/op    -16.6%  >> improved
  percentage_and_ratio                       57.24 ns/op     54.99 ns/op     -3.9%
  flex_expand_equal_weights                  56.02 ns/op     47.94 ns/op    -14.4%
  flex_expand_weights                        43.43 ns/op     39.13 ns/op     -9.9%
  full_wide_no_wrap_simple_few               83.82 ns/op     82.11 ns/op     -2.0%
  full_deep_nesting                          97.77 ns/op     85.86 ns/op    -12.2%
  full_space_distribution                    86.18 ns/op     81.50 ns/op     -5.4%
  full_percentage_sizing                     95.52 ns/op     83.04 ns/op    -13.1%
  full_shrink_overflow                       90.07 ns/op     83.34 ns/op     -7.5%
  full_expand_with_max_constraint            71.25 ns/op     67.95 ns/op     -4.6%
  full_expand_with_min_constraint            70.34 ns/op     67.84 ns/op     -3.6%
  full_mixed_layout                          77.29 ns/op     73.16 ns/op     -5.3%
  full_nested_vertical_stack                 92.00 ns/op     83.19 ns/op     -9.6%
  full_percentage_and_ratio                 100.86 ns/op     83.19 ns/op    -17.5%  >> improved
  full_flex_expand_equal_weights             84.82 ns/op     74.64 ns/op    -12.0%
  full_flex_expand_weights                   71.01 ns/op     67.73 ns/op     -4.6%
--------------------------------------------------------------------------------------------------
  24 compared | 0 regressed | 2 improved | 0 new | 0 removed
  Result: PASS (threshold: 15.0%)
```


---

## PR 11 — API check + three-phase Element lifecycle

**Goal:** lock down the public API at compile time, and adopt the
three-phase Element lifecycle (`request_layout` / `prepaint` / `paint`)
that unblocks tooltips, drag previews, and autoscroll done correctly.

**Write scope:**

- `src/api_check.zig` (new)
- `src/element/element.zig` (new — Element trait)
- every widget that needs lifecycle phases
- `build.zig` (wire `api_check.zig` into the test step)

**Tasks:**

- [ ] `api_check.zig` mirrors `core/interface_verify.zig` but for
      Tier-1 public names. Reference
      [§8 public-API verification](./architectural-cleanup-plan.md#8-public-api-verification).
- [ ] Define the Element trait per
      [§18](./architectural-cleanup-plan.md#18-element-lifecycle-as-an-explicit-three-phase-trait):
      `request_layout` → `prepaint` → `paint`, with intermediate
      state types `RequestLayoutState` and `PrepaintState`.
- [ ] Convert tooltips, drag previews, scroll-into-view to use the
      three-phase model. They're currently wedged into single-phase
      paint.
- [ ] Combine with PR 6's `DrawPhase` assertions — phase entry/exit
      asserts that the previous phase completed.
- [ ] 0.16: any `@Type`-style trait codegen here uses the new
      builtins.

**Definition of done:**

- Tooltips render in their correct stacking order.
- Scroll-into-view works on dynamically-sized lists.
- `api_check.zig` compiled into the test binary.

---

## Out of scope (tracked separately)

These are 0.16 items we explicitly **do not** fold into the cleanup.
File a tracking issue per item; revisit on its own cadence.

- **WASM unblock.** Upstream-blocked on `posix.system.getrandom` /
  `IOV_MAX` typing under `wasm32-freestanding`. Watch the upstream
  fix; revive `build.zig` WASM steps when it lands. See
  [§28](./zig-0.16-changes.md#28-gooey-specific-takeaways).
- **`Io.Evented` macOS backend.** Experimental. Phase 6 of
  [`zig-0.16-io-migration.md`](./zig-0.16-io-migration.md). Would give
  GCD integration through the `Io` interface. Revisit once upstream
  marks it stable.
- **LLVM 21 vectorization regression.** Pure perf measurement, no
  code change. Bench-only follow-up; PR 10 records a baseline.
- **`@cImport` deprecation.** We don't currently use `@cImport`. If
  we add C interop (e.g., direct CoreText calls), use `addTranslateC`
  in `build.zig` per
  [§25 build system](./zig-0.16-changes.md#25-build-system).
- **Atomic-file API change.** Only relevant if/when we add settings
  persistence or document save. Not on the cleanup path.
- **`File.Stat.atime` becoming optional.** Only relevant for
  watcher / hot-reload paths, which Gooey does not have today.
- **`fs.path.relative` purity change.** Only relevant if Gooey starts
  doing path manipulation. Not today.

---

## Cross-reference index

Each row in this index maps a 0.16 takeaway from
[`zig-0.16-changes.md` §28](./zig-0.16-changes.md#28-gooey-specific-takeaways)
to the PR that absorbs it. Update both this doc and §28 when a PR lands.

| 0.16 takeaway                            | Folded into                                         |
| ---------------------------------------- | --------------------------------------------------- |
| `@Type` removal — comptime type building | PR 0 (sweep) + PR 4, PR 6, PR 8, PR 11 (per-module) |
| Vectors no runtime indexing              | PR 0 + PR 2 (rasterizer) + PR 10 (layout SIMD)      |
| Local-address return compile errors      | PR 0                                                |
| `ArrayList` `.empty`                     | PR 0                                                |
| `heap.ArenaAllocator` lock-free          | PR 0                                                |
| `init.minimal` + non-global argv/env     | PR 7                                                |
| `std.testing.Smith` fuzzing              | PR 10                                               |
| Loop-vectorization perf re-baseline      | PR 10 (measurement only)                            |
| `@cImport` deprecation                   | Out of scope (no current C interop)                 |
| Atomic-file API                          | Out of scope                                        |
| `File.Stat.atime` optional               | Out of scope                                        |
| `fs.path.relative` purity                | Out of scope                                        |
| WASM upstream unblock                    | Out of scope (separate tracking issue)              |
| `Io.Evented` macOS                       | Out of scope (Phase 6 of io-migration)              |

---

## Appendix — agent delegation notes

If splitting work across agents:

- **PRs 0–6 are sequenceable in parallel** if write scopes are
  respected. PR 0 is a hard prerequisite for the rest because it
  prevents `@Type` churn from leaking into every other PR.
- **PRs 7, 8, 11 must be serial.** Each materially depends on the
  previous and rewrites large surface area.
- When delegating, point the agent at:
  1. This doc (their PR section).
  2. `CLAUDE.md` (engineering principles, especially §3, §5, §10,
     §13, §14).
  3. The specific cleanup-plan section linked from this doc.
  4. `zig-0.16-changes.md` only when the PR's audit list mentions it.
- Each delegated task should produce: code changes, an updated
  checkbox in this doc's PR section, and updated cross-reference rows.
