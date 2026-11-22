# Gooey API developer experience roadmap

## Status

Reviewed 2026-11-21 against v0.6.7. The settled items from the 0.3.1 review are in the
core contract (`docs/core-contract.md`); git history keeps the review. This page keeps
what is still open.

Its principles still apply: invalid configuration fails at compile time, optional values
mean absence and not failure, every capacity is observable and fails fast, and native and
web behave the same or say where they differ.

## P1: layout, open

`ui.Style` has rows, columns, weighted grow, wrapping rows, and aspect ratios. Still
missing:

- **Grid.** Columns that line up across rows (forms, tables, dashboards) need a grid;
  rows of fixed widths approximate one today. Proposed in `docs/layout-grid.md`.
- **Text truncation.** Ellipsis and a maximum line count for `ui.text`.

## P2: documentation and onboarding, open

- **An API guide.** The readme's "Building blocks" and "Components" sections are the
  current reference. A guide by task (state, layout, input, text, accessibility,
  capacity, testing) is still missing.
- **Examples as a learning progression.** Each kept example covers a feature; the
  showcase tutorial that was to order them is deferred (contract decision 15).
- **Compile-tested snippets.** Not automated. The contract's example snippets were
  checked by hand on 2026-11-14; the readme's are not checked.
- **Ownership and lifetimes.** Contract rule 6 (no slice passed during build is read after
  the tick) and §3 (handles, not pointers, across ticks) state the rules; declarations do
  not yet say which ones retain what.
- **A platform capability matrix.** The readme's "Platforms" and "Not yet in Gooey" sections
  list the differences in prose.

## P3: application testing, open

`App.initHeadless` runs an app on `TestBackend`: a test pushes input into
`app.window.queue`, calls `app.tick`, and reads the rendered frame's hit records and
accessibility tree. That is what the goldens use, but it reaches into `gooey.internals`.
A public harness that queries by key, text, role, or accessible name and injects input
and time is still to be designed.

## P4: standard components, open

`gooey-components` has `Button`, `Checkbox`, `Select`, `RadioGroup`, `Tooltip`,
`ContextMenu`, `Modal`, `List`, `TextInput`, `TextArea`, `CodeEditor`, and the Lucide icons;
`gooey-charts` has the charts. Still missing, in rough order of need:

- **Controls:** label with accessible association, separator, icon button, link, spinner,
  switch, slider, number input.
- **Overlays and feedback:** popover, toast, alert, confirmation dialog, dropdown menu,
  command palette, loading placeholders.
- **Forms:** field label, description, and error composition; form-level validation;
  focus on the first invalid field.
- **Application shell:** toolbar, status bar, split pane and resizable panels, sidebar,
  tree, table, closable tabs.
