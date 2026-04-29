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
12. [PR 9 — `prelude.zig` trim + ownership flag drop](#pr-9--preludezig-trim--ownership-flag-drop)
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

| PR  | Scope                    | Cleanup items                                      | 0.16 audits                                                | Risk        | Status                     |
| --- | ------------------------ | -------------------------------------------------- | ---------------------------------------------------------- | ----------- | -------------------------- |
| 0   | Mechanical sweep         | —                                                  | `@Type` split, local-address returns, `ArrayList` `.empty` | Low         | ☑ (no-op, audit only)      |
| 1   | `image/` + `Gooey`       | #1 (ImageLoader), #9 (Asset(T) seed)               | `@Type` in atlases, redundant arena mutex                  | Low         | ☑                          |
| 2   | `scene/svg.zig` + `svg/` | #12                                                | `@Type` on path-parsing, vector indexing on rasterizer     | Low         | ☑                          |
| 3   | `context/` extractions   | #1 finish, #8 (SubscriberSet)                      | `@Type` on a11y tree builders                              | Low         | ☑                          |
| 4   | Backward edges           | #2 (Focusable vtable), #3 (list layout to widgets) | `@Type` on vtable codegen                                  | Medium      | ☑                          |
| 5   | `cx.zig` namespaces      | #4                                                 | —                                                          | Low         | ☑                          |
| 6   | `DrawPhase` + globals    | #7, #10                                            | `@Type` on type-keyed globals                              | Low         | ☑                          |
| 7   | App/Window/Frame         | #5, #6, #14 (partial)                              | `init.minimal`, non-global argv/env                        | Medium-high | ◐ (7a + 7b.1a/1b/2/3/6 landed) |
| 8   | element_states           | #11                                                | Heaviest `@Type` work                                      | Medium      | ☐                          |
| 9   | prelude + flags          | #13, #14 (finish)                                  | —                                                          | Medium      | ☐                          |
| 10  | Layout engine            | #15                                                | Vector indexing, `std.testing.Smith` fuzz targets          | Medium      | ☐                          |
| 11  | API check + Element      | #16, #17                                           | `@Type` on Element trait if any                            | Large       | ☐                          |

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

- [x] Move these fields out of `Gooey` and into a new `ImageLoader`:
      - `image_load_results` (cap `MAX_IMAGE_LOAD_RESULTS = 32`)
      - `pending_image_loads` (cap `MAX_PENDING_IMAGE_LOADS = 64`)
      - `failed_image_loads` (cap `MAX_FAILED_IMAGE_LOADS = 128`)
      - The `Io.Group` + `Io.Queue(LoadResult)` pair that drives them.
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
  - ☐ 7b.4 — Lift `keymap` and `globals` off `Window` onto `App`,
    keeping `Debugger` on `Window.globals` (audited per-window:
    overlay quads, frame timing, selected layout id all bound to
    one scene). `Keymap` and `*const Theme` move to
    `App.globals`.
  - ☐ 7b.5 — Lift `image_loader` to `App`. Pick between (a)
    shared queue with per-window draining and (b) per-window
    loaders pointing at the shared atlas; the choice has
    cross-window cache-hit-rate UX implications.
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
- ☐ 7c — `Frame` double buffer + `mem.swap` at frame boundary.
- ☐ 7d — `pub fn main(init: *Init)`-shaped entry point.
- ☐ 7e — Final `_owned` sweep + `grep -n "_owned" src/` returns nothing.

**Goal:** split `Gooey` into `App` (process-lifetime, shared resources)
+ `Window` (per-window frame state) + `Frame` (per-frame double
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

## PR 8 — Unified `element_states`

**Goal:** replace per-widget retained-state hash maps with a single
`HashMap((id, TypeId), *anyopaque)` keyed pool.
Adding a new widget no longer requires framework edits.

**Write scope:**

- `src/context/element_states.zig` (new)
- every `widgets/*_state.zig` (call site changes)
- `src/context/gooey.zig` / `window.zig` (drop per-widget maps)

**Tasks:**

- [ ] Define `ElementStates` with fixed capacity
      (`MAX_ELEMENT_STATES = 4096` — sketch the math:
      4096 × 32 B per slot = 128 KB; revisit if widgets exceed cap in
      practice).
- [ ] `with_element_state(global_id, fn(state) -> (R, state))` —
      mirror GPUI's
      [§19 pattern](./architectural-cleanup-plan.md#19-with_element_stateglobal_id-fnstate---r-state).
- [ ] Migrate existing widget state stores one widget at a time.
      `text_input_state` first (smallest), then `text_area_state`,
      then `code_editor_state`, then list state, etc.
- [ ] **0.16: this PR is the heaviest `@Type` user.** The `TypeId`
      construction and `*anyopaque` payload typing should be entirely
      `@TypeOf` / `@typeName` / `@Struct` style. No legacy `@Type`.
- [ ] Pair-assert at the `set` / `get` boundary on every state slot
      (CLAUDE.md §3).

**Definition of done:**

- Adding `widgets/foo_state.zig` requires zero edits to the
  framework — only `cx.with_element_state(id, …)` calls.
- All existing widget-state hash maps deleted.

---

## PR 9 — `prelude.zig` trim + ownership flag drop

**Goal:** finish the API hygiene work that was deferred earlier.
**Breaking** — bumps the public surface.

**Write scope:**

- `src/root.zig` (slim down)
- `src/prelude.zig` (new, ~10 names)
- `src/cx.zig` (delete deprecated forwarders from PR 5)
- examples + docs (one big sweep)

**Tasks:**

- [ ] Define `prelude.zig` with at most 10 names: `run`, `App`,
      `Window`, `Cx`, `Color`, plus a few constants
      (cap based on
      [§15 prelude philosophy](./architectural-cleanup-plan.md#15-the-preluders-philosophy--tiny-curated-re-export)).
- [ ] Demote the rest of `root.zig`'s 100+ flat re-exports into
      namespace re-exports (`gooey.widgets.Button`,
      `gooey.geometry.Rect`, etc.).
- [ ] Delete every deprecated `cx.foo` forwarder added in PR 5 in
      favor of `cx.lists.foo` / `cx.animate.foo` / etc.
- [ ] Confirm no `_owned: bool` survived PR 7. If any did, kill them
      here.

**Definition of done:**

- `wc -l src/root.zig` < 80.
- All examples updated.
- A migration note in `CHANGELOG.md` listing every renamed symbol.

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

- [ ] Split per pass: sizing, position, scroll. Each pass file is
      self-contained, takes the layout tree by `*const` reference, and
      writes results into a pass-specific output buffer.
- [ ] Each pass enforces the 70-line function limit
      (CLAUDE.md §5). Where a long function exists, push pure
      computation to leaves.
- [ ] 0.16: vector-indexing audit on layout SIMD
      (per [§21 vectors](./zig-0.16-changes.md#vectors)).
- [ ] 0.16: add `std.testing.Smith` fuzz targets per
      [§28 takeaways](./zig-0.16-changes.md#28-gooey-specific-takeaways)
      — at minimum a layout-tree fuzzer that randomizes node trees and
      asserts pass invariants.
- [ ] Loop-vectorization perf re-baseline (LLVM 21 regression). Run
      benches before/after; record numbers in
      `docs/benchmarks/`. **No code change expected — this is
      measurement only.** If a regression exceeds 10% on a hot path,
      file a follow-up issue, don't block this PR.

**Definition of done:**

- No file in `src/layout/` exceeds 1,500 lines.
- `zig build fuzz` runs the new layout fuzzer.
- Bench numbers recorded.

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
