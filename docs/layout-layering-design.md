# Layout and layering design

## Status

Implemented by the 0.4 core's layers (`docs/v0.4.0-core-contract.md` §6, `src/core/layers.zig`)
and current as of v0.5.1 (2026-11-14). The contract is normative; this document keeps the
reasoning behind it. It began as a proposal against the 0.3.1 runtime, whose floating
elements carried an additive `i16` z-index and were sorted command by command into the
render-command list; git history keeps that version.

## Decision

Keep the Clay-inspired box layout engine (`src/layout/`) and borrow only one idea from GPUI:
floating subtrees are laid out with their parent but painted, clipped, and hit-tested as
separate fragments in one shared order. Measured on 0.3.1, layout cost 38–70 ns per node
(65–83 ns with tree construction) up to 15,000 nodes, which gave no reason to replace it.

## Problems it solves

- **Paint and input disagreed.** Text widgets, scrollbars, canvases, and direct widget hit
  tests did not pass through one ordering and clipping model, so content behind an overlay
  could paint over it or take its input.
- **A numeric z-index is not a hierarchy.** Nested values were added, so a dropdown inside
  modal A (1000 + 100) painted over a later modal B (1050).
- **Sorting single commands broke clips.** Floating descendants could move outside their
  ancestor's scissor pair and escape its clip by accident, not by policy.
- **Numeric tiers leaked policy.** Apps had to learn conventions such as 100 for popups and
  1000 for modals.

## What the core does

- **A box with a `layer` opens a fragment** (`ui.Box.layer`: `kind`, `anchor`, and
  `clip`). Content is fragment zero. Fragments opened by the same fragment are ordered by
  kind, then by open order; a layer opened inside a layer's fragment comes after that
  fragment, so a popover inside a modal sits above the modal and a later modal sits above
  both.
- **Paint and hit records carry their fragment.** Paint goes in fragment order and hit
  testing in reverse, from the same frame, so what is on top receives input. Every element,
  text engines and scrollbars included, emits through the same records; nothing hit-tests
  on its own.
- **A modal fragment blocks hit testing** of every earlier fragment.
- **Clipping is a policy:** `.escape` leaves the ancestors' clips, `.inherit` keeps them.
- **Layers stay in the window.** One anchored to its parent that would run past the window's
  top or bottom opens on the parent's other side when it fits there, else it is clamped.
- **No numeric z-index** exists anywhere: not in the API, the layout engine (#221), or the
  packed frame, whose draws are already in fragment order.
- **Bounded:** layers per frame are `ResourceLimits.build.layer_count_frame_max`, which also
  sizes the layout engine's floating roots (each layer box floats), and fragments are
  written in linear passes with no sort.

## Differences from the proposal

- The public API is the `layer` field, not `Floating.dropdown()`-style presets; library
  components such as `Select` and `Modal` choose the layer.
- `Layer.Kind` has `popover`, `tooltip`, `modal`, and `drag`. Only `popover` and `modal`
  are implemented (contract decision 13); tooltips and drag wait for a component that needs
  them (drag's plan is draft #148).
- Focus scopes, placement beyond the vertical flip, and anchor ids are not built.
