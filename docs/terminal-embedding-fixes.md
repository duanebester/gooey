# Gooey for terminal embedding

Gaps that `booey` (a single-pane terminal prototype) and the Jenkins terminal-multiplexer
research (`jenkins/docs/terminal-multiplexer-mvp.md`) found in 0.3.1, and where each stands
on the 0.4 core (`docs/v0.4.0-core-contract.md`).

Status, 2026-11-14 (`main` after #227): items 1, 2, 3, 5, and 6 are met by the core. Item 4
is met without a new primitive. Item 7 is half met: weighted grow works, and there is no
splitter.

The 0.3.1 version of this document (2026-07-30) described fixes to code the core replaced,
such as `CxConfig`, `ui.canvas`, the `Focusable` vtable, and the layout engine's render
commands; git history keeps it.

## 1. Bold and italic text: met

`ui.text`'s `weight` and `italic` select a face from the app's `FontLimits` (#92), and
`cx.measureText` takes the same options (#93), so measured widths match the drawn text. A
monospace family's bold face keeps the regular face's advance, so a cell grid does not shear.
A terminal sets `Config.fonts.mono` and draws with `.family = .mono` (contract decision 8),
listing the mono variants it needs in `fonts.limits`.

## 2. Tab taken by focus traversal: met

Tab moves focus only when no `on_key` handler on the focus path stopped the key (contract
§5). A terminal pane's `on_key` handles Tab and calls `effects.stopPropagation()`, so shell
completion receives it. There is no per-widget carve-out; `CodeEditor` indents the same way.

## 3. Canvas without user data: met

`ui.paint(Data, &data, paint_fn, style)` passes a typed `*const Data` to the paint function
(contract §1), so each pane paints its own state with no module globals.

## 4. A cell grid at terminal scale: met with `ui.paint`

A pane is one `ui.paint` element, not one element per attribute run, so it costs one layout
node however many cells it holds. Its paint function draws background runs with
`painter.fill` and text runs with `painter.text`, which shapes and places glyphs into the
glyph atlas. The frame's bounds are the app's `ResourceLimits.paint` and
`records.paint_record_count_frame_max`: past either, the frame fails fast naming the pool,
its limit, and the frame. At `.standard`, 8,192 glyphs per frame cover four full-colour
80×24 panes (7,680 cells); a bigger layout declares a larger profile or raises
`paint.glyph_count_frame_max`.

A dedicated `cellGrid` primitive is not planned. If profiling a real terminal shows
`painter.text` per run is too slow, the next step is a painter call that places a run of
pre-shaped cells.

## 5. `App` drops configuration fields: met

`gooey.App(State, render, config)` takes one `Config(State)`. An unknown field is a compile
error, `on_init` is the only spelling, and the core has no `on_close` to need (contract §7).

## 6. Capacity enforced only in Debug: met

Every pool is sized from `ResourceLimits` at init, and exhaustion panics in every build mode
with the pool name, capacity, requested count, and frame (contract rule 4).

## 7. Multiplexer conveniences: half met

- **Weighted grow: met (#227).** Siblings sized `.{ .grow = weight }` split the parent's
  free main-axis space by weight, each clamped between its content minimum and its
  `width_max` or `height_max`, so a 2:1 split is `.{ .grow = 2 }` beside `.{ .grow = 1 }`.
  A weight must be finite and greater than 0. `.percent` still sets a fixed fraction of
  the parent (`.width = .{ .percent = 0.667 }`).
- **Splitter: open.** No resizable divider exists, and the public API cannot build one
  yet: a `Box` takes clicks and keys but no pointer moves, so nothing can follow a drag.
  Pointer dragging is part of drag and drop, deferred to 0.6.
