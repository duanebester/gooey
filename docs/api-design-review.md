# API Design Review — Developer Experience

Status: review notes / backlog. **P0 items resolved in PR #41** (Theme 2
release-safe assertion fixes + Theme 4 README/quick-start doc drift). **P1
consistency pass opened as PRs #42 (selection fields), #43 (handler naming),
and #44 (alignment/gap/padding types)**; P2–P3 remain open. Author:
agent-assisted review. Scope: the public developer-facing
API surface (`cx.*`, `ui.*`, components, `root.zig` module layout, README).
Findings are grounded in the source at the line references given; a handful were
verified directly against the code (noted).

This document catalogs nitpicks and rough edges in the API design. It is a
consistency/polish backlog, **not** a rewrite proposal — the core model
(`cx` behavior vs `ui` layout, first-parameter `State` inference, curated-core

- namespaces) is sound and should be preserved.

## Table of contents

- [What's good (preserve these)](#whats-good-preserve-these)
- [Cross-cutting themes](#cross-cutting-themes)
  - [Theme 1 — Naming/type inconsistency across equivalent concepts](#theme-1--namingtype-inconsistency-across-equivalent-concepts)
  - [Theme 2 — Debug-only assertions become release-mode UB](#theme-2--debug-only-assertions-become-release-mode-ub)
  - [Theme 3 — Stringly-typed identity + value-semantics surprises](#theme-3--stringly-typed-identity--value-semantics-surprises)
  - [Theme 4 — README teaches an API surface that no longer exists](#theme-4--readme-teaches-an-api-surface-that-no-longer-exists)
- [Individual findings](#individual-findings)
- [Priority summary](#priority-summary)

---

## What's good (preserve these)

- `cx` (behavior) vs `ui` (layout) split is clean and teachable.
- First-parameter `State` inference in handlers (`ExtractState`, `cx.zig`) is
  elegant, and the `@compileError` quality for malformed handler methods is
  excellent.
- Zero-allocation `u64` arg packing for handlers.
- The curated-core-7 + namespaces layout in `root.zig` is well-reasoned, and
  `api_check.zig` pins the public surface so it can't rot silently.
- Validation module is the most consistent corner of the API (parallel
  `required` / `requiredMsg` / `requiredCode` / `requiredResult` families).
- Child-tuple handling routes heterogeneous types cleanly and `@compileError`s
  on mis-typed components rather than silently dropping them.

---

## Cross-cutting themes

### Theme 1 — Naming/type inconsistency across equivalent concepts

The dominant DX drag. Near-identical concepts use divergent names/types/shapes
across the API, so developers cannot build muscle memory. Violates project
rule 9 ("Don't overload names with multiple meanings that are
context-dependent").

**Selection state — six spellings for "which one is on":**

| Component   | Field         | Type              | Ref                   |
| ----------- | ------------- | ----------------- | --------------------- |
| Checkbox    | `checked`     | `bool`            | `checkbox.zig:22`     |
| RadioButton | `is_selected` | `bool`            | `radio_group.zig:47`  |
| Tab         | `is_active`   | `bool`            | `tabs.zig:35`         |
| RadioGroup  | `selected`    | `usize` (no none) | `radio_group.zig:163` |
| Select      | `selected`    | `?usize`          | `select.zig:161`      |
| TabBar      | `active`      | `usize`           | `tabs.zig:155`        |

Suggested: booleans → `selected` (consistent `is_` policy either way); indices
→ `selected: ?usize` everywhere so "none" is uniform.

**Handler fields — `_handler` suffix applied at random:** `on_click_handler`,
`on_blur_handler`, `on_toggle_handler` carry it; `on_close`, `on_select`,
`on_change` don't — for the identical `HandlerRef` type. Worse:

- `on_select` means `OnSelectHandler` on Select (`select.zig:174`) but
  `HandlerRef` on MenuItem (`context_menu.zig:103`) — copy-paste fails to
  compile.
- `Modal.on_close` (`modal.zig:50`) vs `Select.on_close_handler`
  (`select.zig:182`) — same concept/type, different name.
- `TabBar.on_change` is a raw `*const fn(usize) void` (`tabs.zig:158`) while the
  sibling `Tab` uses `on_click_handler: HandlerRef` (`tabs.zig:38`).

Suggested: standardize on `on_<event>` with no `_handler` suffix and a single
`HandlerRef` type.

**`.alignment` is three different types** (verified in `ui/styles.zig`):

- `box` → struct: `.alignment = .{ .cross = .center }` (`styles.zig:208,239`)
- `hstack`/`vstack` → enum: `.alignment = .center` (`styles.zig:443,446`)
- `text` → a third enum (`left/center/right`) (`styles.zig:156,162`)

Nastiest trap: refactoring a `vstack` into a `box` (required the moment you want
a `background` — stacks carry no background/border/corner_radius) produces a
compile error on the alignment field that "was already correct."

**`gap`/`padding` types drift across containers:** `gap` is `f32` on box/stack
but `u16` on scroll (`styles.zig:472`); `padding` is a union on box/scroll but a
bare `f32` on stack/center. `.gap = 8.5` compiles in some places, not others.
Also `f32` spacing is false precision — the engine truncates via
`@intFromFloat` (`builder.zig:733`), so `8.5` silently becomes `8`.

**`size` is overloaded:** enum (`.small/.medium/.large`) on Button
(`button.zig:19`) vs pixels (`f32`) on Checkbox/RadioButton/Image/Svg.

**`enabled` vs `disabled`:** Button uses `enabled: bool = true`
(`button.zig:20`); TextInput/Select/MenuItem use `disabled: bool = false`
(opposite polarity); TextArea has neither.

**Other naming drift:** `variant` (Button) vs `style` (Tabs) for "visual kind";
`border_color_focused` (TextInput) vs `focus_border_color` (Select);
ProgressBar's `fill`/`secondary_fill` lack the `_color` suffix used elsewhere;
Modal prefixes everything with `content_*`; ValidatedTextInput renames the
wrapped input's fields to `input_height`/`input_padding`.

**Highest-leverage single fix:** unify the `alignment` shape and `gap`/`padding`
types so `hstack`/`vstack` become a clean, mechanical subset of `box`. This
collapses several findings at once.

### Theme 2 — Debug-only assertions become release-mode UB

> **Status: RESOLVED** (PR #41). The two real release-UB guards were promoted to
> unconditional `@panic`s; the entity item turned out to be a comptime check
> (never release UB) and was clarified rather than "fixed." Details per-item below.

Several core primitives guard invariants with `std.debug.assert`, which compiles
out in `ReleaseFast`/`ReleaseSmall` — the builds users ship. Contradicts rules 4
("fail fast"), 11, and 17. All three verified directly against source.

- ✅ **`cx.changed` 64-key overflow** (`change_tracker.zig:73`): guarded by
  `std.debug.assert(self.count < MAX_TRACKED_VALUES)` immediately before
  `self.keys[self.count] = ...`. In release, the 65th distinct key is an
  out-of-bounds write into a `[64]` array — memory corruption, not a clean
  failure. **Fixed:** the capacity check is now an unconditional `@panic` guard
  that runs before the write in every build.
- ✅ **`cx.state(T)` type mismatch** (`cx.zig:165`): guarded only by
  `std.debug.assert(self.state_type_id == typeId(T))` before a raw `@ptrCast`.
  In release, the wrong type silently reinterprets memory. **Fixed:** promoted
  to an unconditional `if (state_type_id != typeId(T)) @panic(...)` before the
  cast.
- ⚠️ **Entity `updateWith` arg-size** (`entity.zig:609`): the original claim of
  "silent corruption in release" was **inaccurate**. The `std.debug.assert(@sizeOf(Arg) <= 4)`
  lives inside a `comptime {}` block, so a violation is a _compile-time_ error,
  not a strippable runtime check. The 4-byte limit is also _structurally
  correct_ (the arg shares the packed `u64` with `entity_id`), so it cannot be
  unified with root `updateWith`'s 8-byte budget. **Addressed:** the only real
  defect — a cryptic `reached unreachable code` message — was replaced with a
  descriptive `@compileError` matching root `updateWith`, documenting _why_ the
  limit is 4.

Fix (applied): for the two real control-plane checks (each runs ~once/frame, so
cost is negligible), promoted to unconditional `@panic` guards that survive
release.

### Theme 3 — Stringly-typed identity + value-semantics surprises

Identity-by-string is pervasive: `cx.changed("dark_mode", …)`,
`cx.animations.tween("id", …)`, `TextInput{ .id = "new-todo" }`,
`widgetState(T, "id")`. Typos compile silently and track a different, lonely
key; distinct strings that hash-collide to the same `u32` silently corrupt each
other's state. The todo example's `const draft_input_id = "new-todo"` is itself
an admission the raw pattern is error-prone — yet other examples use bare
literals.

`cx.changed` also has surprising value semantics (verified at
`change_tracker.zig:106`): it hashes `std.mem.asBytes(&value)`, so:

- **Structs with padding** hash uninitialized padding → spurious "changed" (the
  rule-21 buffer-bleed hazard as a correctness bug).
- **Slices/strings compare by address, not content** — the doc comment says so
  (`cx.zig:745`). `cx.changed("draft", s.draft)` on a `[]const u8` can miss an
  in-place edit or fire on an identical string at a new address — the opposite
  of what a function named `changed` implies.

Suggested: offer an enum-keyed overload (`cx.changed(.dark_mode, v)`) for
rename-safety; either `@compileError` on padded/pointer types or special-case
`[]const u8` to hash contents. Document the collision risk.

### Theme 4 — README teaches an API surface that no longer exists

> **Status: RESOLVED** (PR #41). All stale tokens below were rewritten against
> the current surface, plus two more the review missed (`cx.gooey()` and the
> `keymap` field-vs-method error). `grep` for every stale token now returns
> nothing; `zig build` compiles all examples.

Verified by grepping `cx.zig`: **`cx.animate`, `cx.animateOn`, and
`cx.entityCx` do not exist** — moved to `cx.animations.tween`/`tweenOn` and
`cx.entities.context`. The README still teaches the old names (Animation section
~L1296, Entity section ~L1416), plus `gooey.lerp` and `g: *gooey.Gooey`. Also:

- The `root.zig` quick-start (lines 26–32) calls `gooey.run(AppState, …)` but
  never declares `AppState` (it's an anonymous struct) — the first code sample
  in the public root module won't compile.
- The "Deferred Commands" README section (L435–457) uses `g: *Gooey`
  throughout, but the real injected type is `*Window` (`gooey.Window`); no
  `Gooey` type exists.

Fix (applied): regenerated the stale sections against the current
`cx.animations.*` / `cx.entities.*` / `App` surface. Corrections shipped:
`cx.animate`/`cx.animateOn` → `cx.animations.tween`/`tweenOn`; `gooey.lerp` →
`gooey.animation.lerp`; `*Gooey`/`gooey.Gooey` → `*Window`; `gooey.Entity(T)` →
`gooey.context.Entity(T)`; `cx.entityCx` → `cx.entities.context`; `cx.gooey()` →
`cx.window()`; `keymap` field → `keymap()` method; corrected the
`deferCommand`/`deferCommandWith` call-site arg counts; and declared `AppState`
in the `root.zig` quick-start. Still open (follow-up): extend the
`api_check.zig` pinning approach to compile README snippets so this can't recur.

---

## Individual findings

- **Two entry points, unclear canonical**: `gooey.run(...)` (native-only) vs
  `gooey.App(...) + App.main(init)` (handles the WASM `@export` path).
  `root.zig:48` claims `run` is used by "~all examples," but most examples use
  `App`, and the two quick-starts (root.zig vs README todo) disagree. `App` is
  the superset — document it as canonical; demote `run` to "native shortcut."

- **Two deferral APIs**: `cx.@"defer"` / `cx.deferWith` (keyword-escaped, ugly
  at call sites; `cx.zig:434`) exist on `Cx`, while the README documents a
  different, more verbose `g.deferCommand(State, method)` on the window. Rename
  the `Cx` method to a non-keyword (`deferCommand`/`enqueue`) and reconcile the
  two APIs.

- **`on_click` + `on_click_handler` "one or the other" is unenforced**:
  `button.zig:15` labels them "one or the other," but `render` forwards _both_
  unconditionally to the box (`button.zig:111-112`) with no assertion.
  (`dispatch.zig` doesn't key on these names, so the earlier "both fire" claim
  is unconfirmed — but the missing enforcement of the documented contract is
  real.) Collapsing to one `on_click: ?HandlerRef` removes both the footgun and
  the awkward `_handler` suffix.

- **`ui.when` evaluates children eagerly** while `ui.maybe` is lazy
  (`primitives.zig:301` vs `:324`). `ui.when(user != null, .{ ui.text(user.?.name, .{}) })`
  dereferences `user.?` before the condition is checked, because the child tuple
  is built as an argument. The family looks uniform but only `maybe` is
  null-safe — a latent crash that reads like guarded access. Document loudly, or
  add a lazy `whenFn` variant.

- **`ui.each` teaches a cryptic return type**: the README uses
  `@TypeOf(ui.text("", .{}))` as the callback return annotation
  (`readme.md:342`); the tests just write `ui.Text` (`primitives.zig:685`). The
  `@TypeOf` incantation invites cargo-culting and breaks when the callback
  returns a container. Also note `each`'s callback must return a single element
  type (undocumented; surfaces as a peer-type-resolution error).

- **RadioGroup didn't get Select's ergonomic upgrade**: Select uses a single
  `on_select` receiving the index (good); RadioGroup still needs a positional
  `handlers: []const HandlerRef` array hand-aligned to option indices
  (`radio_group.zig:167`), where a too-short array makes those radios silently
  dead. Give RadioGroup an `on_select` mirroring Select; make `selected`
  optional.

- **`id` requiredness is inconsistent** and reintroduces a fixed bug: required
  on TextInput/Modal, optional (`?…= null`, auto-id) on Button/Checkbox/etc.,
  but defaulted to a shared string literal on Select (`"select"`,
  `select.zig:155`) and ContextMenu (`"context-menu"`, `context_menu.zig:131`) —
  the exact "two on one screen collide silently" anti-pattern that PR 11b.2b
  removed elsewhere.

- **`widgetState(T, "id").clear()` escape hatch**: the flagship todo reaches into
  a retained widget by string id to clear it after submit, because `bind` is
  one-way (widget→state only). Typed sugar (`cx.textField(id)`, `cx.zig:570`)
  exists but the docs teach the raw generic form, and a wrong type/id returns
  `null` so "clear" silently no-ops. Add a declarative reset path (two-way bind
  or `cx.resetInput(id)`); prefer the typed helper in docs.

- **Silent no-op on handler state-type mismatch**: generated wrappers resolve
  state with `getRootState(State) orelse return;` — a mis-wired handler does
  nothing with no `log.warn`/panic. A dead button with zero diagnostics is
  painful to debug (rules 11/17). At minimum `log.warn` on the `orelse` path.

- **Documented pointer-capture pattern can dangle**: README (~L416) blesses
  `cx.updateWith(&self.items[i], State.editItem)`. The pointer is packed at
  render time and invoked at click time; if the slice grows/reorders between,
  the handler dereferences freed/wrong memory. Lead with index/ID options;
  demote pointer capture with a lifetime warning.

- **Tooltip/Modal generic ergonomics**: `Tooltip(Button){ .child = Button{...} }`
  names the child type twice; the position enum requires `Tooltip(void).Position`
  to reference. README example at `readme.md:811` (`Tooltip(IconButton){ ...
.child = HelpIcon{} }`) has mismatched type param vs child and won't compile as
  written. Hoist `Position` to module scope; consider a non-generic
  `ui.tooltip(child, .{...})` helper.

- **No cap on `each`/array children** (`builder.zig:897`): runtime iteration is
  uncapped, contra rule 4 (`MAX_NESTED_COMPONENTS = 64`). Add a debug assertion
  or documented ceiling.

- **Silent drop of unknown child types** (`builder.zig:1150,1212`): a stray
  integer, string literal, or plain struct passed as a child renders nothing
  with no diagnostic — inconsistent with the strong `@compileError` given to
  mis-typed components a few lines above.

- **`textFmt` rotating buffer pool** (`primitives.zig:66`): 16 × 256-byte
  thread-local buffers, round-robin; >16 live results or >256-byte strings
  silently truncate/alias. Document the ceiling; assert on overflow rather than
  substituting `"..."`.

- **Validation asymmetries**: `minLength(value, n)` (single-use) vs
  `minLengthValidator(n)` (composable in `all()`) — two names, mixed calling
  conventions in one `all()` literal. Missing `numericResult`/`alphanumericResult`
  in the `Result` family. No `allCode()`. `ErrorCode.invalid_format` has no
  validator that produces it.

- **`corner_radius` is scalar-only** (`styles.zig:192`) though the engine
  supports per-corner — mirror `padding`'s union pattern.

- **`indent_px` is the only unit-suffixed pixel field** (`styles.zig:570`) in a
  sea of unit-less pixel fields — pick one convention (rule 9).

- **`getGooey()` legacy accessor** (`cx.zig:672`) returns `?*Window` and its own
  doc says "prefer `cx.window()`" — deprecate/rename.

---

## Priority summary

| Priority  | Item                                                                                                     | Type                          |
| --------- | -------------------------------------------------------------------------------------------------------- | ----------------------------- |
| ~~P0~~ ✅ | `changed` 64-key release OOB; `cx.state` release UB; entity arg-size assert — **done (PR #41)**          | correctness / release-only UB |
| ~~P0~~ ✅ | README doc drift (`cx.animate`/`entityCx`/`*Gooey`, uncompilable quick-start) — **done (PR #41)**        | first-run experience          |
| ~~P1~~ 🔀 | Unify `.alignment` shape + `gap`/`padding` types (stack becomes a clean subset of box) — **PR #44**      | consistency                   |
| ~~P1~~ 🔀 | Unify selection fields (`checked`/`is_selected`/`is_active`/`selected`/`active`) — **PR #42**            | consistency                   |
| ~~P1~~ 🔀 | Unify handler naming; fix `on_select` type collision; enforce Button "one or the other" — **PR #43**     | consistency / footgun         |
| P2        | `changed` string/struct value semantics; stringly-typed id collisions                                    | correctness surprise          |
| P2        | Give RadioGroup a Select-style `on_select`; fix Select/ContextMenu default ids                           | footgun                       |
| P2        | Document canonical entry point (`App`); rename `cx.@"defer"`                                             | clarity                       |
| P3        | `ui.when` eager-eval docs; `ui.each` return-type example; `disabled`/`enabled` polarity; `size` overload | nits                          |

**Through-line:** the design is good, but it reads like several well-designed
corners never reconciled with each other. A single "naming and types
consistency" pass across components + styles, plus converting the debug-only
invariant asserts to release-safe checks and refreshing the README, would take
dev-ex from "good with sharp edges" to "genuinely polished."

**Suggested starting points (low-risk, high-value, self-contained):** the
debug→release assertion fixes (Theme 2) and the README doc drift (Theme 4).

> **Update:** Theme 2 and Theme 4 shipped in PR #41. The P1 consistency pass
> is now open as three independent PRs — selection fields (#42), handler naming
> (#43), and alignment/gap/padding types (#44). Each standardizes one axis of
> naming/typing and updates its call sites + README; all three pass
> `zig build` and `zig build test`. Because they all touch example files and
> `readme.md`, merge them one at a time and resolve conflicts (suggested order:
> #42 → #43 → #44, saving the widest-blast-radius alignment PR for last).
> Handler-naming leaves the `on_select` type unification (OnSelectHandler vs
> HandlerRef) documented-but-deferred as a P2-sized follow-up. Next open items
> are the P2 batch (value-semantics/id collisions, RadioGroup `on_select`,
> canonical entry point).
