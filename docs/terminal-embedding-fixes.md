# Gooey — Fixes Needed for Terminal Embedding

Gaps in Gooey surfaced by `booey` (single-pane terminal prototype) and the
Jenkins terminal-multiplexer research
(`jenkins/docs/terminal-multiplexer-mvp.md`). Each item lists the evidence, the
workaround currently living in booey, and the fix that belongs here.

Status: **items 2, 3, 5, 6 landed; items 1, 4, 7 remaining.**
Date: 2026-07-30.

Done so far (build + `zig build test` green):

- **Item 5** — `App` now forwards every `CxConfig` field and the
  `init`/`on_init` name mismatch is fixed (native and WASM).
- **Item 3** — `ui.canvas` gained a `*anyopaque` userdata slot
  (`ui.canvasWithData`, surfaced as `DrawContext.user_data`).
- **Item 2** — general raw-keys opt-out on the `Focusable` vtable
  (`wantsRawKeys`); the CodeEditor Tab carve-out folded into it.
- **Item 6** (partial) — the two pure-append pending pools
  (`registerPendingCanvas`, `enqueuePendingTextWidget`) now clamp-and-warn
  instead of silently growing in release. The broader audit
  (`MAX_LAYOUT_ELEMENTS`, `MAX_RENDER_COMMANDS`, canvas draw-order blocks)
  is still open — see item 6.

---

## 1. Bold and italic text are declared but not wired

**Evidence.** `TextStyle` carries `weight` and `italic`
(`src/ui/styles.zig:150`), but `builder.renderText` forwards only two of the
four style flags (`src/ui/builder.zig:1251`):

```zig
.decoration = .{
    .underline = txt.style.underline,
    .strikethrough = txt.style.strikethrough,
},
```

`weight` and `italic` have no path onward. `TextSystem` holds a single
`current_face: ?PlatformFace` (`src/text/text_system.zig:504`) which
`loadFont` replaces wholesale, clearing the glyph and shape caches — there is
no face registry, so there is nothing for a weight to select. `.weight = .bold`
renders identically to regular everywhere it appears today (`a11y_demo.zig`,
`code_editor.zig`, `form_validation.zig`).

**Booey workaround.** A 0.5 px double-draw (`booey/src/terminal.zig`,
`drawGlyph` + `bold_overdraw_px`). It smears rather than embolds, and it costs
a second glyph run per bold cell.

**Fix.** Two seams already exist, so this is well-scoped:

1. `TextData.font_id: u16` is already threaded from layout through to render
   (`src/layout/render_commands.zig:86`, populated at
   `src/layout/scroll_pass.zig:196`) — plumbed but never set meaningfully.
2. `CoreTextFace.init(name, size)` loads any named face, so `"Menlo-Bold"` is
   one call away; `initSystem(.monospace, size)` also exists.

The work: a small fixed-capacity face registry in `TextSystem`
(regular / bold / italic / bold-italic) replacing `current_face`; key the
glyph and shape caches by `font_id` (the shape cache already keys on
`font_ptr`, so this is close to free); map `weight >= .semibold` and `italic`
to a `font_id` in `builder.renderText`.

For monospace this is unusually safe: the bold face of a monospace family has
identical advance width to the regular face, so the cell grid cannot shear.
Proportional text would need re-measurement — out of scope.

**Done when:** `.weight = .bold` visibly differs from regular in an existing
example, and monospace cell advance is unchanged between faces.

**Blocker found during scoping (2026-07-30).** The glyph cache (`GlyphKey`)
and shape cache (`ShapedRunKey`) both already carry a `font_ptr`, so a face
registry keyed by the _slot address_ gives correct cache separation for
free — the easy part. But `ShapedRunCache.checkFont` wipes the **entire**
shape cache whenever the incoming `font_ptr` differs from the last one
(`text_system.zig:204`). It assumes single-font usage. With a 4-face
registry, alternating regular/bold runs (a code editor with bold keywords, a
terminal with bold cells) would clear the whole shape cache on every switch —
catastrophic thrashing for all text, not just bold. A correct item 1 therefore
needs the shape cache to hold multiple faces concurrently: drop the
wipe-on-change heuristic and add a per-face generation counter to the key so
font _reload_ still invalidates (reload reuses the same slot address, so the
bare `font_ptr` cannot distinguish stale entries). That is a deliberate change
to the hottest path and is the real work here — the plumbing
(`builder.renderText` weight/italic → `font_id`; `font_id` through
`shapeTextInto` / `resolveGlyphBatch` / `text/render.renderText`; the
`measureTextCallback` already receives `font_id` and ignores it) is
mechanical by comparison. Native (CoreText) can derive variants via
`CTFontCreateCopyWithSymbolicTraits`; Linux/Web should store null variants and
fall back to the regular face (renders as today — no regression) until their
backends grow variant support.

## 2. Tab is unconditionally consumed by focus traversal

**Evidence.** `handleKeyDownEvent` (`src/runtime/input.zig:615-636`)
intercepts Tab / Shift-Tab for focus navigation before the app-level
`on_event` hook runs. This breaks shell tab-completion — unacceptable for a
terminal. `CodeEditor` already carves out a special case here (it wants Tab
for indentation), so there is precedent, but it is hard-coded to that one
widget.

**Booey workaround (since deleted).** The most invasive hack in booey was
`captureRawKeys` (`booey/src/terminal.zig`), which swapped
`platform_window.on_input` behind Gooey's back, chained the original
callback, and reached the widget through a `raw_key_owner` module global
because the filter was a bare function pointer with no userdata slot. It
worked for exactly one window and one widget, and it depended on an internal
field Gooey never promised to keep stable. With `wantsRawKeys` landed, booey
now opts out via the `Focusable` contract and the hack is gone.

**Fix.** A general "this focusable takes raw keys" opt-out on the `Focusable`
vtable, checked before the Tab arm in `handleKeyDownEvent`, rather than a
second hard-coded widget case next to `focusedCodeEditor`. Fold the existing
CodeEditor carve-out into the same mechanism so there is one rule, not two
special cases. (This is the Jenkins doc's open question §7.1 — resolving it
here unblocks both projects.)

## 3. `ui.canvas` has no userdata slot

**Evidence (historical).** `ui.canvas` took a bare
`*const fn (*DrawContext) void`. Any stateful canvas had to reach its state
through a module global — booey's `var term: Terminal = .{}`
(`booey/src/main.zig`) originally existed only for this reason. Workable for
one pane, unusable for N. Landed as `ui.canvasWithData` /
`DrawContext.user_data` (see status above).

**Fix (preferred).** Don't patch canvas; supersede it for grid-shaped content
with a `cellGrid` primitive (item 4). If canvas is kept for ad-hoc drawing, a
`*anyopaque` userdata parameter is a cheap independent improvement.

## 4. No cell-grid primitive; composition and canvas both hit caps

**Evidence.** The two existing ways to paint a terminal-sized grid both fail
at scale:

- One `ui.text` per attribute-run: `MAX_LAYOUT_ELEMENTS = 4096`
  (`src/core/limits.zig:80`). A full-colour 80×24 pane is 1920 runs; four
  panes is 7680 elements, ~1.9× over the cap.
- `ui.canvas`: reserves a fixed block of 256 draw orders each
  (`src/runtime/frame.zig:272`), which thousands of glyphs overrun; plus
  item 3.

**Fix.** A VT-agnostic `cellGrid` primitive following the `ui.codeEditor`
pattern: a `Builder.PendingCellGrid` that participates in layout,
`frame.zig::renderCellGrid` painting straight into the scene (bounded by
`MAX_GLYPHS_PER_FRAME` / `MAX_QUADS_PER_FRAME` = 65536, not the layout cap),
per-instance state via `window.element_states.get(State, layout_id.id)`, and
a `Focusable` implementation. Paint all background quads first, then glyph
runs, so the batch iterator coalesces into ~2 GPU batches.

Gooey must not depend on ghostty: the grid speaks
`{codepoint(s), fg, bg, flags}` plus a cursor and knows nothing about escape
sequences. Reusable for hex viewers, log tailers, sparkline grids.

Full design: `jenkins/docs/terminal-multiplexer-mvp.md` §3 and §6 Slice 1.

## 5. `gooey.App` drops config options that `runCx` supports

**Evidence (historical).** `App.main` used to forward a hard-coded subset
of fields to `runCx`: title, width, height, background_color, on_init,
on_event, custom_shaders, the glass options, font, and font_size. `CxConfig`
also has `on_close`, `on_resize`, `min_size`, `centered`, and `io` — silently
ignored if passed. Booey needed `on_close` (to hand the keyboard back and
close the pty before the window dies) and had to bypass `App` entirely and
call `gooey.run(...)` directly.

`on_init` also had a field-name mismatch: `App` read `config.init` while
`runCx` calls it `on_init` — callers of `App` who wrote `.on_init = ...` got
it silently dropped too.

Both are fixed: `App.main` (`src/app.zig`) now enumerates every `CxConfig`
field via `inline for` (so the two can never drift) and accepts both `init`
and `on_init` spellings. Booey no longer bypasses `App` — it uses
`gooey.App(...)` directly (`booey/src/main.zig:24`).

**Fix.** Forward every `CxConfig` field with the same
`@hasField`-with-default pattern, or better: accept a `CxConfig` directly and
delete the field-by-field copy so the two can never drift again. Fix the
`init`/`on_init` name mismatch while there.

## 6. Capacity enforcement is Debug-only

**Evidence.** The caps in `src/core/limits.zig` (`MAX_LAYOUT_ELEMENTS`,
`MAX_RENDER_COMMANDS`, canvas draw-order blocks, …) are enforced by
assertions only: Debug panics at the cap, release builds silently grow past
it. This contradicts the project's own "put a limit on everything / fail
fast" rule (`CLAUDE.md` §4) — the limit exists but the negative space is
unhandled in release.

**Fix.** On overflow in release, clamp and surface the condition (log once
per frame, or a debug-overlay counter) rather than growing silently.
Terminal-grid workloads are exactly the ones that will find these caps first.

**Progress (2026-07-30).** The two pure-append builder pools now clamp and
`std.log.warn` (matching the `Window.deferCommand` precedent):
`registerPendingCanvas` and `enqueuePendingTextWidget`. Still open, and
trickier because they are on hot paths or coupled to index bookkeeping:

- `MAX_LAYOUT_ELEMENTS` (4096) is **defined but never referenced** —
  `ElementList` is a growing `std.ArrayList` with no cap check at all. Adding
  enforcement must be careful not to break legitimately-large UIs.
- `MAX_RENDER_COMMANDS` is only `std.debug.assert`-guarded in `frame.zig`
  (and the local constant there is 65536, not the 8192 in `limits.zig` —
  reconcile these).
- The index-coupled pending pools (`pending_inputs`, `pending_text_areas`,
  `pending_code_editors`, `pending_scrolls`) capture `len` as an index before
  appending, so a naive early-return would desync the follow-up
  `enqueuePendingTextWidget` index. Clamp by skipping the append _and_ the
  matching enqueue together.

## 7. Lower priority: multiplexer conveniences

Not blocking booey; needed by Jenkins Slice 3+.

- **Weighted grow.** `Box.grow` is a bool (confirmed by the in-tree comment
  at `src/layout/benchmarks.zig:481`). A 2:1 split needs `width_percent` or
  explicit pixels. A numeric grow factor would make split trees natural.
  Note (2026-07-30): `Box.width_percent` / `height_percent` already exist and
  are wired through to `SizingAxis.percent` (`builder.zig:659`), so a 2:1
  split is expressible **today** as `width_percent = 0.667 / 0.333`. The
  remaining ask is ergonomic — a numeric `grow` factor for natural split
  trees — not a capability gap.
- **Splitter widget.** No resizable-divider exists; drag-to-resize must be
  hand-built from a thin `ui.box` plus mouse events.

---

## Suggested order

1. Item 5 (`App` forwarding) — smallest, immediately deletes booey's
   `gooey.run` workaround.
2. Item 1 (bold/italic) — independently valuable, makes existing examples
   honest. Jenkins Slice 0.
3. Items 2 + 4 together (raw-keys opt-out + `cellGrid`) — Jenkins Slice 1;
   deletes booey's two module globals and the input-callback swap.
4. Items 3, 6, 7 as they come up.
