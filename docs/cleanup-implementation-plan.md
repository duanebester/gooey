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
| 1   | `image/` + `Gooey`       | #1 (ImageLoader), #9 (Asset(T) seed)               | `@Type` in atlases, redundant arena mutex                  | Low         | ☐                     |
| 2   | `scene/svg.zig` + `svg/` | #12                                                | `@Type` on path-parsing, vector indexing on rasterizer     | Low         | ☐                     |
| 3   | `context/` extractions   | #1 finish, #8 (SubscriberSet)                      | `@Type` on a11y tree builders                              | Low         | ☐                     |
| 4   | Backward edges           | #2 (Focusable vtable), #3 (list layout to widgets) | `@Type` on vtable codegen                                  | Medium      | ☐                     |
| 5   | `cx.zig` namespaces      | #4                                                 | —                                                          | Low         | ☐                     |
| 6   | `DrawPhase` + globals    | #7, #10                                            | `@Type` on type-keyed globals                              | Low         | ☐                     |
| 7   | App/Window/Frame         | #5, #6, #14 (partial)                              | `init.minimal`, non-global argv/env                        | Medium-high | ☐                     |
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

**Pre-existing test failures (NOT 0.16 residue, tracked separately):**

- `zig build test` against 0.16.0 produces two failing test binaries
  on `main`. One trips the deferred command queue cap
  (`Deferred command queue full (32 commands) - dropping command`).
  These are not blocking the cleanup — they predate this branch and
  will be addressed out-of-band. Each subsequent PR's "definition of
  done" tracks failures **introduced by that PR**, not the
  pre-existing baseline.

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

- [ ] Move these fields out of `Gooey` and into a new `ImageLoader`:
      - `image_load_results` (cap `MAX_IMAGE_LOAD_RESULTS = 32`)
      - `pending_image_loads` (cap `MAX_PENDING_IMAGE_LOADS = 64`)
      - `failed_image_loads` (cap `MAX_FAILED_IMAGE_LOADS = 128`)
      - The `Io.Group` + `Io.Queue(LoadResult)` pair that drives them.
- [ ] `ImageLoader` exposes `init(io, gpa)`, `deinit`, `enqueue(url)`,
      `drain(callback)`. No `*Gooey` reference; takes `io` and the atlas
      pointer it writes into.
- [ ] Sketch `image/asset_cache.zig` with a generic
      `AssetCache(comptime T: type, comptime cap: u32)` skeleton — even
      if only `Image` uses it for now. SVG migrates in PR 2.
- [ ] 0.16: confirm `std.http.Client` use matches the
      [§7 networking pattern](./zig-0.16-changes.md#7-networking)
      (`http_client.request(.HEAD, …)` shape, `receiveHead(&buf)`).
- [ ] 0.16: audit `image/atlas.zig` for `@Type` usages (PR 0 may have
      caught these; confirm).
- [ ] Update all `Gooey` callers to go through `gooey.image_loader`
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

---

## PR 2 — SVG consolidation

**Goal:** eliminate the parallel `scene/svg.zig` and `svg/` modules.
There should be exactly one SVG module.

**Write scope:**

- `src/scene/svg.zig` (delete after content move)
- `src/svg/path.zig` (new — receives the path parser)
- `src/svg/mod.zig` (updated)
- `src/scene/mod.zig` (drop re-export)

**Tasks:**

- [ ] Move the path-parser code from `scene/svg.zig` into
      `svg/path.zig`. Keep type names but rehome them.
- [ ] Delete `scene/svg.zig`.
- [ ] Adopt `AssetCache(SvgDocument, MAX_SVG_DOCS)` from PR 1 for the
      SVG document cache.
- [ ] 0.16: any comptime path-parser tables that used `@Type` get
      converted (PR 0 should have done this; verify).
- [ ] 0.16: rasterizer SIMD audit — if any
      `@Vector(N, f32)[runtime_index]` exists, coerce to array first
      per [§21](./zig-0.16-changes.md#vectors).
- [ ] Resolve the `Vec2` name collision between `scene/` and `svg/` —
      keep `core.Point` everywhere and delete the duplicates.

**Definition of done:**

- `find_path src/scene/svg.zig` returns nothing.
- No two distinct types named `Vec2`.
- All SVG-rendering examples still render.

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

- [ ] Extract `HoverState` per
      [§7b](./architectural-cleanup-plan.md#7b-extract-a-hoverstate-struct):
      `hovered_layout_id`, `last_mouse_x`, `last_mouse_y`,
      `hovered_ancestors`, `hovered_ancestor_count`, `hover_changed`.
- [ ] Extract `BlurHandlerRegistry` (cap 64) per
      [§7d](./architectural-cleanup-plan.md#7d-extract-blurhandlerregistry).
- [ ] Extract `CancelRegistry` per
      [§7e](./architectural-cleanup-plan.md#7e-the-cancel_groups-registry).
- [ ] Extract `A11ySystem` per
      [§7c](./architectural-cleanup-plan.md#7c-extract-an-a11ysystem):
      `a11y_tree`, `a11y_platform_bridge`, `a11y_bridge`,
      `a11y_enabled`, `a11y_check_counter`.
- [ ] Introduce `SubscriberSet(comptime Key, comptime Cb,
      comptime cap)` (cleanup item #8). Use it as the storage for
      `BlurHandlerRegistry` and `CancelRegistry` to validate the
      generic shape on real callers before PR 8 leans on it.
- [ ] 0.16: audit `accessibility.zig` for `@Type` usage in the tree
      builder. Pair-assert at the write/read boundary on every
      `setNode` / `getNode` per CLAUDE.md §3.

**Definition of done:**

- `gooey.zig` is < 1,200 lines.
- `wc -l src/context/gooey.zig` confirmed in PR description.
- No public API change. All examples build unchanged.
- `SubscriberSet` has at least two distinct call sites.

---

## PR 4 — Break the backward edges

**Goal:** kill the `context → widgets` and `ui → widgets` imports.
After this PR, dependency direction is monotonic upward.

**Write scope:**

- `src/context/gooey.zig` (drop widget imports)
- `src/context/focus.zig` (new — defines `Focusable` vtable)
- `src/widgets/text_input_state.zig` (implements `Focusable`)
- `src/widgets/text_area_state.zig` (implements `Focusable`)
- `src/widgets/code_editor_state.zig` (implements `Focusable`)
- `src/widgets/uniform_list.zig` (receive layout helper)
- `src/ui/builder.zig` (drop direct widget imports)

**Tasks:**

- [ ] Define `Focusable` vtable per
      [§4 cleanup direction](./architectural-cleanup-plan.md#cleanup-direction-3):
      `{ ptr, vtable: { focus, blur, is_focused } }`.
- [ ] Convert `TextInput`, `TextArea`, `CodeEditorState` to register
      themselves with the focus manager via `Focusable`. Remove the
      direct imports from `context/gooey.zig` and
      `context/dispatch.zig`.
- [ ] Move `computeUniformListLayout` (and `tree_list`, `virtual_list`,
      `data_table` siblings) from `ui/builder.zig` into the matching
      `widgets/*.zig` file. `Builder` now takes a thin
      `ListLayoutInterface` and doesn't know which widget supplied it.
- [ ] 0.16: the `Focusable` vtable construction is a `@Struct(...)`
      shape; make sure it uses the new builtins consistently with PR 0.
- [ ] Update `core/interface_verify.zig` to compile-check
      `Focusable` for each widget.

**Definition of done:**

- `grep -n "@import.*widgets" src/context/` returns nothing.
- `grep -n "@import.*widgets" src/ui/` returns nothing.
- All widget tests pass.

---

## PR 5 — `cx.zig` sub-namespacing

**Goal:** drop `cx.zig` from ~1,971 lines by sub-namespacing the
widget-coordination APIs. **Additive — no removal yet.**

**Write scope:**

- `src/cx.zig` (mostly deletions / one-line forwarders)
- `src/cx/lists.zig` (new)
- `src/cx/animate.zig` (new)
- `src/cx/entities.zig` (new)
- `src/cx/focus.zig` (new)

**Tasks:**

- [ ] Move all `cx.uniformList`/`treeList`/`virtualList`/`dataTable`
      bodies into `cx/lists.zig`. `cx.lists.uniform(…)` is the new
      callsite.
- [ ] Same shape for animate, entities, focus.
- [ ] Old top-level methods become one-line forwarders marked with a
      `// Deprecated:` comment pointing to the new location.
      Removal happens in PR 9.
- [ ] Update examples and docs to use the sub-namespaced form.
- [ ] 0.16: nothing material in this PR.

**Definition of done:**

- `wc -l src/cx.zig` < 800.
- Both `cx.uniformList(…)` and `cx.lists.uniform(…)` work and produce
  identical output.

---

## PR 6 — `DrawPhase` + `Global(G)`

**Goal:** add the GPUI-style `DrawPhase` enum and per-method phase
assertions, and introduce `Global(G)` for type-keyed singletons (theme,
keymap, debugger).

**Write scope:**

- `src/context/draw_phase.zig` (new)
- `src/context/gooey.zig` (assertions added at method entry)
- `src/context/global.zig` (new)
- whatever currently holds the keymap / theme / debugger

**Tasks:**

- [ ] Define `DrawPhase = enum { none, prepaint, paint, focus }`.
      Add `current_phase: DrawPhase` to `Gooey` (or `FrameContext`).
      Per-method asserts: `paint_quad` requires `.paint`,
      `insert_hitbox` requires `.prepaint`, etc. Use **paired
      assertions** per CLAUDE.md §3.
- [ ] Define `Global(comptime G: type)` keyed on
      `core.TypeId.of(G)` with a fixed capacity
      (`MAX_GLOBALS = 32`). API: `set`, `get`, `update`.
- [ ] Move keymap, theme, debugger pointer out of `Gooey` and into
      globals. Keep `gooey.keymap()` etc. as thin convenience accessors.
- [ ] 0.16: `Global`'s type-keyed storage uses `@TypeOf` /
      `@typeName` rather than `@Type`. If PR 0 missed any
      type-builder helpers around the keymap, fix them here.

**Definition of done:**

- Calling a paint-only method outside a paint phase fails an assertion
  in debug builds.
- `Gooey` no longer owns `keymap`, `theme`, or `debugger` directly.

---

## PR 7 — App/Window split + `Frame` double buffer

**This is the architectural earthquake.** Largest PR; medium-high risk.
Plan it as its own multi-day effort.

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
