# Gooey API developer experience roadmap

## Status

Reviewed 2026-11-14 against v0.5.1. This roadmap came from a review of the 0.3.1 API. The
0.4 migration (`docs/v0.4.0-plan.md`) replaced that API with the core
(`docs/v0.4.0-core-contract.md`), which settled most of its P0 and P1 items; this revision
records where each item stands and keeps the ones still open. Git history keeps the 0.3.1
review.

Its principles still apply: invalid configuration fails at compile time, optional values
mean absence and not failure, every capacity is observable and fails fast, and native and
web behave the same or say where they differ.

## P0 and P1: settled by the core

- **Reject unknown `App` configuration fields.** An unknown `Config` field is a compile
  error (contract §7).
- **Distinguish cancellation, absence, and errors.** Dialog outcomes are `file_selected`,
  `cancelled`, or `failed` (decision 11). macOS still reports an allocation failure as
  `cancelled`.
- **Structured capacity diagnostics.** Every pool fails fast with its name, capacity,
  request, and frame (rule 4).
- **Explicit platform support.** A frame a renderer's `capabilities` cannot draw fails
  fast, and a dialog request on a host without dialogs fails instead of doing nothing.
- **Multi-window lifecycle.** Multi-window is cut; one window per app (decision 14).
- **Type `setGlassStyle`.** Glass is cut (decision 14).
- **Retained accessor names and `getGooey`.** Replaced by `cx.retain` and `cx.get` with
  typed handles (§3).
- **One callback taxonomy.** One `Handler` with four method shapes, built by `cx.on` (§4).
- **Component identity rules.** Keys (`ui.box(.{ .key = ... })`); retained state, focus,
  and scroll require a keyed id and assert it (§2).
- **A narrower command context.** `Effects` (§4).

## P2: documentation and onboarding, open

- **An API guide.** The readme's "Building blocks" and "Components" sections are the
  current reference. A guide by task (state, layout, input, text, accessibility,
  capacity, testing) is still missing.
- **Examples as a learning progression.** The 15 kept examples each cover a feature
  (`docs/v0.4.0-plan.md`, Phase A policies); the showcase tutorial that was to order them
  is deferred (contract decision 15).
- **Compile-tested snippets.** Not automated. The contract's example snippets were
  checked by hand on 2026-11-14; the readme's are not checked.
- **Ownership and lifetimes.** Contract rule 6 (no slice passed during build is read after
  the tick) and §3 (handles, not pointers, across ticks) state the rules; declarations do
  not yet say which ones retain what.
- **A platform capability matrix.** The readme's "Platforms" and "Not in 0.4.0" sections
  list the differences in prose.

## P3: application testing, open

`App.initHeadless` runs an app on `TestBackend`: a test pushes input into
`app.window.queue`, calls `app.tick`, and reads the rendered frame's hit records and
accessibility tree. That is what the goldens use, but it reaches into `gooey.internals`.
A public harness that queries by key, text, role, or accessible name and injects input
and time is still to be designed.

## P4: standard components, open

`gooey-components` has `Button`, `Checkbox`, `Select`, `Modal`, `List`, `TextInput`,
`TextArea`, `CodeEditor`, and the Lucide icons; `gooey-charts` has the charts. Still
missing, in rough order of need:

- **Controls:** label with accessible association, separator, icon button, link, spinner,
  switch, slider, number input.
- **Overlays and feedback:** popover, toast, alert, confirmation dialog, dropdown menu,
  command palette, loading placeholders. Tooltips and drag need their layers first
  (contract decision 13).
- **Forms:** field label, description, and error composition; form-level validation;
  focus on the first invalid field.
- **Application shell:** toolbar, status bar, split pane and resizable panels, sidebar,
  tree, table, closable tabs.
