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

| PR  | Scope                    | Cleanup items                                      | 0.16 audits                                                | Risk        | Status                |
| --- | ------------------------ | -------------------------------------------------- | ---------------------------------------------------------- | ----------- | --------------------- |
| 0   | Mechanical sweep         | —                                                  | `@Type` split, local-address returns, `ArrayList` `.empty` | Low         | ☑ (no-op, audit only) |
| 1   | `image/` + `Gooey`       | #1 (ImageLoader), #9 (Asset(T) seed)               | `@Type` in atlases, redundant arena mutex                  | Low         | ☑                     |
| 2   | `scene/svg.zig` + `svg/` | #12                                                | `@Type` on path-parsing, vector indexing on rasterizer     | Low         | ☑                     |
| 3   | `context/` extractions   | #1 finish, #8 (SubscriberSet)                      | `@Type` on a11y tree builders                              | Low         | ☑                     |
| 4   | Backward edges           | #2 (Focusable vtable), #3 (list layout to widgets) | `@Type` on vtable codegen                                  | Medium      | ☑                     |
| 5   | `cx.zig` namespaces      | #4                                                 | —                                                          | Low         | ☑                     |
| 6   | `DrawPhase` + globals    | #7, #10                                            | `@Type` on type-keyed globals                              | Low         | ☑                     |
| 7   | App/Window/Frame         | #5, #6, #14 (partial)                              | `init.minimal`, non-global argv/env                        | Medium-high | ◐ (7a landed)         |
| 8   | element_states           | #11                                                | Heaviest `@Type` work                                      | Medium      | ☐                     |
| 9   | prelude + flags          | #13, #14 (finish)                                  | —                                                          | Medium      | ☐                     |
| 10  | Layout engine            | #15                                                | Vector indexing, `std.testing.Smith` fuzz targets          | Medium      | ☐                     |
| 11  | API check + Element      | #16, #17                                           | `@Type` on Element trait if any                            | Large       | ☐                     |

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
- ☐ 7b — Rename `Gooey → Window`, lift `keymap` / `globals` /
  `entities` / `image_loader` into a real `App`.
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
