# Selectable text

## Status

Proposed on 2026-11-22 against origin/main 0a37bfb. Not implemented. It depends on nothing
unmerged, but "Truncation" depends on `docs/text-truncation.md`, being built on the
`text-truncation` branch. The estimate is under "Effort", and the recommended first step
under "First step".

## Why

A user can copy text only out of `TextInput`, `TextArea`, and `CodeEditor`. Everything an
app shows with `ui.text`, such as an error message, a log line, an ID in a table cell, a
chat message, or a file path, cannot be selected or copied. Browsers, GPUI apps (Zed's
markdown views), and egui (`Label`s are selectable by default since 0.26) all let users do
this.

## What exists today

**Inputs.** `src/core/text_engine.zig` owns selection for the three text kinds:

- **State.** Each engine is a retained slot (`Pool(kind)`, a `retained.Slab`) with `cursor`
  and `anchor` byte offsets; the selection is `[min, max)` of the two.
- **Keys.** `applyCommand` hard-codes Cmd-A, Cmd-C, Cmd-X, Cmd-V, and Cmd-Z, with Cmd on
  Apple platforms and Ctrl elsewhere (`editCommand`). Shift with the arrows, Home, or End
  extends the selection. None of this goes through `keymap.zig`: the engine's `on_key`
  handler sees the key only after the keymap has not claimed it (`router.zig`, `findAction`
  before `bubble`).
- **Clipboard.** `src/core/clipboard.zig` is one buffer reserved at init, sized by
  `clipboardBytes` to the largest text kind's `bytes_max` (8 KiB for inputs at `standard`).
  `write` copies into it, and the tick's `flush` hands it to the platform after the drain.
  Text past the buffer is cut at a codepoint boundary.
- **Pointer.** Only `TextArea` and `CodeEditor` take clicks. `onClick` stores the click as
  `pending_click`, and the next build's `resolveClick` finds the area's bounds in the
  rendered frame's hit records and binary-searches prefix widths (`columnAt`, O(log n)
  `measureText` calls), because a handler has no text measurement. `TextInput` does not
  place its caret on a click, and no kind selects by dragging, by double click (words),
  or by triple click (lines). Platforms already fill `MouseEvent.click_count`.
- **Drawing.** The component's paint function measures the prefixes before and after the
  selection and fills a quad of `selection_color` (`primary` at 30 %) before drawing the
  glyphs, only while the field is focused.
- **Accessibility.** `A11y.selection` reports the selection in the field's `value`.

**Static text.** `ui.text` has none of this:

- **No identity.** A text takes an automatic id (`autoId`: its parent's id and its index
  among the parent's children) and has no `key`.
- **No hit record.** `buildText` adds a layout node; emit draws the text's lines and adds
  no `HitRecord`, so the router cannot find a text under the pointer, and the pointer never
  shows an I-beam over one.
- **No glyph positions after drawing.** Wrapped lines (`TextData.wrapped_lines`, start and
  length in bytes, and width) live in the layout arena of the frame being built.
  `placeText` places glyphs from the shaper's clusters, but its sink receives only quads,
  without byte offsets, and spaces produce no quad. Handlers read only the rendered frame
  (`tick.zig`), which keeps the text bytes (`Frame.copyText`) and nothing about where each
  byte was drawn.
- **No retained state.** No slot holds a selection over a text.
- **No focus or keys.** A text is never focused; with nothing focused, keys go to the
  top-level records and stop there.
- **No accessibility.** `ui.text` adds no accessibility node (`docs/accessibility.md`):
  a box's `a11y.label` repeats its text.

## Prior art

- **The web.** One selection per document, a `Selection` of `Range`s whose ends are
  (node, offset) pairs in DOM order. Dragging selects across elements; `user-select: none`
  leaves an element out, and the selection skips it. Copy joins the text with a newline at
  block boundaries. Text cut by `text-overflow: ellipsis` copies whole: the ellipsis is
  drawn, not part of the content. Focusing an input replaces the document's selection.
  Taken: one selection per window, ends as (element, byte offset) in tree order, skipping
  texts that are not selectable, copying the full string of a cut text, and focus taking
  the selection over.
- **GPUI `StyledText` and `InteractiveText`.** `InteractiveText` adds clicks, hovers, and
  tooltips for byte ranges, keyed by an element id, using the text's painted layout
  (`TextLayout::index_for_position`). It does not select. Taken: positions from what was
  painted, not a second measurement.
- **Zed's `markdown` crate.** A `Markdown` entity holds one `Selection` (`start`, `end`,
  `reversed`, `pending`, and a mode of character, word, line, or all) over the whole
  rendered document. Its blocks are one element, so a selection crosses paragraphs but
  never leaves the view. Copy is an action (`markdown::Copy`) bound in the view's key
  context, and the view is focusable. Taken: the selection's modes, word and line extension
  during a drag, and the reversed flag.
- **`gpui-selectable-text` (third-party).** A leaf that drops in where a string went. Drag,
  double, triple, and quadruple click, Shift-click, Shift-arrow extension, Cmd-C, Cmd-A,
  Escape, a click elsewhere clearing it, and one selection per `SelectionScope`. Taken: the
  gesture list as the target for later phases.
- **egui `Label::selectable`.** On by default (`Style::interaction.selectable_labels`).
  One `LabelSelectionState` per viewport holds the two ends as (widget id, cursor). Since
  0.26 a selection crosses labels in one layer: while laying out, a label between the two
  ends paints as fully selected, and copy joins the labels with a space or a newline by
  where they sit. A label that does not see both ends in a frame takes back the selection
  it painted. A fully selected elided label copies its whole text, not the "…". Taken: the
  per-layer boundary, the join rule, and the elided-label rule.

## API

```zig
pub const Text = struct {
    // ... every field today, unchanged ...
    /// The user may select this text with the pointer and copy it. Its lines keep
    /// their drawn positions in the frame (see "Storage").
    selectable: bool = false,
};
```

```zig
const message: ui.Text = .{ .wrap = .words, .selectable = true };

ui.box(.{ .style = .{ .direction = .column, .gap = 8 } }, .{
    ui.text(error_title, .{ .weight = .semibold, .selectable = true }),
    ui.text(error_detail, message),
    ui.text(request_id, .{ .family = .mono, .selectable = true }),
});
```

There is no other API in the first phases: no handler, no retained handle, and no `key`.
The window owns the selection, and Cmd-C copies it. Later phases add
`effects.copyTextSelection()` for a Copy button or a context menu, and `cx.textSelection()`
to read the selected text (see "Later").

## Semantics

### One selection per window

A window holds at most one static-text selection, like a document. Its two ends are an
anchor (where the press landed) and a head (where the pointer is), each a text's id and a
byte offset on a codepoint boundary. The selection is every byte between them in tree
order, counting only selectable texts in the same fragment (the window's content or one
layer), as egui confines a selection to one layer. A non-selectable text between the ends
is skipped, as `user-select: none` is.

### Gestures

- **Press** on a selectable text, where no interactive record is in front of it (see
  "Hit testing"), clears any selection and puts both ends at the nearest cluster boundary.
  The press still blurs the focused element, as today.
- **Drag** moves the head; past a text, the head goes to the nearest boundary of the
  selectable text nearest the pointer in the same fragment. The press captures the
  pointer, so a drag outside the window keeps extending.
- **Double click** selects the word under the pointer and a drag then extends by words;
  **triple click** selects the line between newlines and extends by lines. Words use the
  text engine's word boundaries (`previousWord`, `nextWord`).
- **Shift-press** extends from the anchor.
- **Release** ends the gesture; the selection stays.
- **Escape** clears it, and so does a press anywhere that is not on a selectable text, and
  focus moving to an element (a click or Tab into an input), because an input's selection
  is then the one the user sees.

A press on a selectable text inside a box with `on_click` still clicks on release when the
pointer did not move past `Capture.click_slop_px`; a press that moves past it selects,
and the click is not delivered, as a browser behaves with text inside a link. A text inside
a box with `on_pointer_drag` or `draggable` is not selectable by the pointer: the gesture
belongs to that box.

### Copy

Cmd-C (Ctrl-C off Apple platforms, the same `editCommand` test) copies the selection when
no keymap binding and no `on_key` handler on the focus path claimed the key, as the
router's other defaults (Tab, Enter, Shift-F10) apply. A focused input therefore keeps its
own copy. With a selection and nothing focused, Cmd-A selects every selectable text of the
selection's fragment.

The copied text is each selected text's bytes in tree order. Between two texts it adds a
newline when the second starts below the first's last line, otherwise a space unless one
side already ends or starts with whitespace, as egui joins labels. The bytes come from the
rendered frame, so the copy is what the user saw.

### Truncation

`docs/text-truncation.md` keeps the full string in the frame and only marks which wrapped
lines emit cuts (`length` packs a 2-bit end marker). Selection follows from that:

- Stops (see "Storage") are recorded only for the clusters drawn. The "…" gets one stop
  whose byte offset is the end of the line's full content, and for the last kept line of
  a text cut by `line_count_max`, the end of the whole text.
- The pointer on or after the "…" therefore selects through the hidden end, and the "…"
  is highlighted when the hidden part is selected.
- Copy reads byte ranges, so a selection that covers a cut text copies its full string,
  as egui copies an elided label whole and a browser copies text cut by `text-overflow`.
- A selection never ends inside hidden text: an end that falls there after the text
  changed, or after a resize cuts more of it, moves to the start of the "…".

## Engine and core design

### Storage

The rendered frame must answer "which byte is under this point" without the layout arena
(the build side's) or text measurement, so emit records what it drew. Three arrays in
`records.Frame`, reserved at init with the frame and reset by `beginFrame`:

- **`text_hits: []TextHit`**, one per selectable text emitted: its id, its bytes
  (`TextRange` into the frame's text), its bounds, the nearest ancestor hit record
  (`parent`, as `HitRecord.parent`) and fragment, its line pitch, and its first line and
  line count in `text_lines`. About 56 bytes.
- **`text_lines: []TextLine`**, one per line drawn: its byte start and length, its top, and
  its first stop and stop count in `text_stops`. 20 bytes.
- **`text_stops: []TextStop`**, one per cluster boundary drawn: `{ offset: u32, x: f32 }`,
  plus one at each line's end. 8 bytes.

Stops come from the shaper's clusters, so kerning, ligatures, and fallback fonts place them
where the glyphs are drawn; prefix widths (`columnAt`) do not account for ligatures that
span a boundary. `placeText`'s sink gains a `stop(cluster, pen_x)` call for every shaped
glyph, including spaces, which have no quad. Only selectable texts pass a sink that keeps
stops. Lines that emit culls (out of a scroll box's view) record a `TextLine` with no
stops: a pointer can never be over them, and copy needs only their bytes.

Each array is a fixed reservation. Exhaustion fails fast as every pool does: `text stops:
capacity {d} (ResourceLimits.records.text_stop_count_frame_max), requested {d}, frame {d}`.

The selection itself is one `TextSelection` value in the `Window`, under 100 bytes:
`anchor` and `head` as `{ id: ElementId, offset: u32, content_hash: u64 }`, the mode
(character, word, line), the word or line the gesture started on, and a gesture flag. It
needs no pool: the window holds one.

### Hit testing

The router's press path finds the hit record under the point as today, then scans the
rendered frame's `text_hits` of that fragment for a text whose lines contain the point and
whose `parent` is that record (or the root with no record). A text covered by a later
sibling, a layer, or a modal therefore never takes the press. The offset is a binary
search of that line's stops for the nearest boundary. A pointer between or past texts maps
to the nearest line of the nearest text by y, then x, in tree order.

`cursorOf` returns `.text` (the I-beam) over a selectable text whose parent record sets no
cursor. Hovering needs no state: it is the same scan.

### Resolution in the drain

Because the stops are in the rendered frame, the router resolves a press, a drag step, and
a copy inside the drain, with no pending point to resolve at the next build (unlike
`TextArea.resolveClick`) and no text measurement. A copy right after a drag in the same
drain copies what that drag selected. The press reuses the pointer capture of
`on_pointer_drag`, owned by the window instead of a record.

### Across frames

The ends name texts by id. Each build, emit computes a text's content hash only when its
id is one of the two ends (at most two hashes per frame). An end whose text is missing
from the new frame, or whose content changed, clears the selection, as egui drops a
selection it cannot see both ends of. An automatic id moves with its index among siblings,
so inserting a sibling before a selected text clears the selection rather than moving it
to the wrong text; a text whose content changes in place (a counter) clears it too.

### Drawing

Emit knows the selection when it reaches a text: a flag in the emit pass turns on at the
first end met in tree order and off at the second, as egui's `has_reached_primary`. For each
drawn line with selected bytes, emit appends a placeholder quad before the line's glyphs,
places the glyphs (recording stops), then fills the quad from the stops, so the highlight
sits behind the glyphs with no second measurement. The color is the theme's `primary` at
30 %, the inputs' `selection_color`; a theme token is an open question. A selected newline
shows as a 4 px sliver past the line's end, as `TextArea` draws it.

### Clipboard

`clipboardBytes` becomes the largest of the text kinds' `bytes_max` and
`text.selection_copy_bytes_max`. The selection copy budget must be at least
`build.text_bytes_frame_max + records.text_hit_count_frame_max` (every byte of a frame's
text plus one separator per text), checked when limits are validated, so a copy never
overflows: the copy asserts it fits instead of cutting it. The reservation comes from fresh
pages, so only the bytes a copy touches become resident. fbdev's in-process clipboard
reserves the same size.

### Accessibility

Unchanged in the first phases: `ui.text` adds no node, and the selection is pointer-only,
as it is in egui and in a browser without caret browsing. See "Open questions".

## Capacities

New fields in `RecordLimits`, frame-scoped like `hit_record_count_frame_max`, and one in
`TextLimits`. Each frame holds its own arrays and the window has two frames.

Texts is `records.text_hit_count_frame_max`, lines `records.text_line_count_frame_max`, and
stops `records.text_stop_count_frame_max`:

| Profile    | Texts  | Lines  | Stops   | Reserved, both frames |
| ---------- | -----: | -----: | ------: | --------------------: |
| `nano`     | 0      | 0      | 0       | 0                     |
| `small`    | 128    | 512    | 4,096   | 100 KB                |
| `standard` | 512    | 2,048  | 16,384  | 401 KB                |
| `large`    | 2,048  | 8,192  | 65,536  | 1.6 MB                |
| `ceiling`  | 16,384 | 65,536 | 524,288 | 12.8 MB               |

Relationships, checked at comptime with the other limits: `text_hit_count_frame_max <=
element_count_frame_max`; `text_line_count_frame_max <= paint.glyph_count_frame_max` (the
layout's wrapped-line scratch is that size); `text_stop_count_frame_max >=
text_line_count_frame_max`. `nano` reserves nothing, and a selectable text with a zero
budget panics at declaration with the field to raise, as a `TextArea` does with
`text.area.count_max = 0`.

`selection_copy_bytes_max` is `build.text_bytes_frame_max + text_hit_count_frame_max` in
each profile: 263 KB at `standard`, up from 128 KiB (the area's `bytes_max`), reserved
from fresh pages.

## Performance sketch

Per frame, with no allocation:

- **No selectable text.** One branch per text in emit. Target: within 0.5 % instructions
  in the Cachegrind gate.
- **Selectable texts.** Per drawn line one `TextLine` (20 B); per shaped glyph one sink
  call and one `TextStop` (8 B); per text one `TextHit` (56 B). Worst case at `standard`:
  16,384 stops, 2,048 lines, and 512 texts, 200 KB written per frame, sequentially, beside
  the glyph records emit already writes. Selected lines add one quad each, at most 2,048.
- **Pointer.** One scan of the fragment's `text_hits` (at most 512 records at `standard`,
  on adjacent cache lines) and one binary search of at most one line's stops per press or
  drag step. Drag steps are bounded by `events.queue_count_max` per drain: at most about
  130,000 record reads per drain at `standard`, under 0.1 ms.
- **Copy.** One pass over the selected texts' bytes into the clipboard buffer: at most
  `selection_copy_bytes_max`, 260 KB, once per Cmd-C.
- **Across frames.** At most two content hashes per frame, over at most
  `text_bytes_frame_max` bytes.

## Tests

- **Records (`records.zig`, emit tests).** With the synthetic backend (one fixed advance
  per codepoint, so expected positions are computed independently): stops of a one-line
  text, of a wrapped text with `.center` alignment, and of multi-byte text land on
  codepoint boundaries; a culled line records bytes and no stops; a non-selectable text
  records nothing.
- **Router.** A press on a text under a later sibling or a layer does not select; a press
  inside a clickable box clicks without moving and selects when moved; a drag from one
  text into a non-selectable text and on into a third skips the middle one; a double click
  then drag extends by words; Escape, a press elsewhere, and focusing an input clear it;
  Cmd-C with an input focused copies the input's selection, not the static one.
- **Copy.** The join rule: two texts in a row, two in a column, a text already ending in a
  space; a selection over a cut text copies its full string (after truncation lands).
- **Capacity.** Fill `text_stop_count_frame_max` exactly, check the last stop, then one
  more is the `core-text-stop-count` fail-fast mode, with its message in `build.zig`; the
  same for texts and lines; a selectable text with a zero budget.
- **Goldens.** `core_selectable_text.txt` replays a new `src/examples/selectable_text.zig`:
  a press, a drag across two paragraphs, Cmd-C, and the clipboard's content in the dump.
- **VOPR.** A `selectable_text` workload in `src/testing/vopr.zig` with
  `vopr_selectable_text_model.zig`, on the example above: wrapped paragraphs, a grid of
  cells, a truncated cell (after truncation lands), a scroll box, a button with a label,
  and a `TextInput`. Actions: presses, drags, and releases at random points, inside and
  outside texts and the window; double and triple clicks; Shift-press; Cmd-C; Cmd-A;
  Escape; wheel scrolls; typing in the input; clicking the button. The model computes the
  expected selection from the synthetic advances and the example's layout, and checks the
  clipboard after every copy. Model-free invariants added to `vopr_invariants.zig`: every
  end is on a codepoint boundary within its text; stops increase within a line; every
  highlight quad lies within its line's box; a selection never ends in hidden text.
  Determinism and `checkStableRebuild` already cover the drawing.

## Effort

**Large overall; medium for the first phases.** It touches every layer of the core but
adds no new subsystem: the frame records, emit, `text/render.zig`'s sink, the router, the
window, limits, the clipboard's size, and a new example and VOPR workload. Approximate
sizes, including tests:

1. **Frame records (medium, about 600 lines).** `Text.selectable`, the three arrays, stops
   from the shaper, the offset query, limits, and fail-fast modes.
2. **Selection in one text (medium, about 900 lines).** Press, drag, double and triple
   click, Shift-press, Escape, Cmd-C, the highlight, the I-beam, the clipboard's size, and
   a golden.
3. **Across texts (medium, about 1,000 lines).** Tree-order ends, skipping, the join rule,
   Cmd-A, and the VOPR workload.
4. **Truncation (small, about 200 lines).** Stops for "…", hidden ends, and full-string
   copy, after truncation lands.

About 2,700 lines in four changes, close to the grid change (#304, about 3,000 lines).
"Later" is not estimated.

Why not small: there is no static-text hit testing to extend, so phase 1 is new
infrastructure in the frame and in emit, and the selection must work against the rendered
frame while the next frame may be in flight. Why not larger: the pointer capture and its
`click_slop_px`, `click_count`, the clipboard service, and the word boundaries exist, and
one selection per window needs no pool.

## First step

Phase 1 alone, with no visible behavior: `Text.selectable`, the three frame arrays and
their limits, the sink's `stop` call, and a frame query `textOffsetAt(point) ?{ text, offset
}` tested against independently computed synthetic positions. It is the foundation every
later phase reads, and it also unblocks other features that need a byte under the pointer:
GPUI-style clickable ranges (links in text), per-character tooltips, and the "this text was
cut" bit that `docs/text-truncation.md` defers.

## Later

- **Copy from a button or a menu.** `effects.copyTextSelection()` and a press that keeps the
  selection (a toolbar's Copy button, a context menu item). Today any press off text clears
  it.
- **Reading the selection.** `cx.textSelection() ?[]const u8`, for "Search for …" menus.
- **Keyboard.** Shift with the arrows extending from the head, as egui and
  `gpui-selectable-text` do.
- **Inputs on the same gestures.** `TextInput` places no caret on a click, and no input
  selects by dragging or by double click. The press, drag, and word logic here can serve
  the engines too, with their own stops.
- **Autoscroll.** A drag past a scroll box's edge scrolls it, as `gpui-selectable-text`'s
  `autoscroll` does.

## Open questions

1. **Default.** egui makes labels selectable by default and a browser makes all text
   selectable. This proposal is opt-in per text, so a button's label never starts a
   selection and an app pays nothing it did not ask for. Should a box be able to turn it
   on for its subtree (`Box.selectable_text`), so a whole article or log view is one
   switch?
2. **Scope.** A selection here is bounded by a fragment (the window's content or one layer),
   as egui bounds it by a layer. Should an app be able to bound it more tightly, as
   `gpui-selectable-text`'s `SelectionScope` does, so a drag in one table cell cannot run
   into the next?
3. **Virtual lists.** A row scrolled out of a `List` is not built, so a selection whose end
   leaves the frame is cleared. A browser keeps it because the DOM keeps the row. Is
   clearing acceptable, or should an end whose text is missing be kept until it returns?
4. **Identity.** Automatic ids shift when a sibling is inserted before a text, which clears
   its selection. Should `ui.Text` take an optional `key`, or is clearing enough?
5. **A press that keeps the selection.** Which presses keep it: a right press on the
   selection (a context menu), a press on a box that is not focusable? A browser keeps it
   for a right press and for a press on a button.
6. **Accessibility.** macOS exposes `AXSelectedText` on static text and Windows UIA a
   `TextPattern`. `ui.text` has no node today. Should a selectable text become a node with
   role `.text` and `A11y.selection`, or is that a separate change?
7. **Theme.** Inputs hard-code `primary` at 30 % for the selection. Should the theme gain
   a `selection` token both use?
8. **Copy format.** Plain text only, or also HTML or rich text where a platform supports
   it, as Zed's `CopyAsMarkdown`? Plain only is proposed.
