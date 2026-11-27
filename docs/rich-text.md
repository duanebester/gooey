# Rich text

## Status

Proposed on 2026-11-26 against origin/main e085c4c. Phase 1 (styled spans) and phase 2
(links) are implemented. It depends on nothing unmerged. Selectable text
(`docs/selectable-text.md`) is out of scope; "Later" notes what this design keeps open for
it. The estimate is under "Effort", and the recommended first step under "First step".

## Why

`ui.Text` styles a whole element: one size, color, weight, italic, and family. A sentence
cannot hold a bold word, a colored name, inline code, or a link. Chat clients (a mention, a
link, `code`), markdown views (emphasis, strong, inline code, links), log views (a colored
level), and error messages (a monospace id) all need inline styles. Today an app can only
fake them by putting several texts in a `row` box, which cannot wrap a sentence across
lines, breaks alignment and truncation, and multiplies elements.

## What exists today

- **Element.** `ui.text(content, style)` builds one node (`cx.zig`, `buildText`). The node
  holds the text's bytes (`Frame.copyText`, one `TextRange`), one color, one font size, one
  family, and one variant. Layout receives one `TextConfig` with one `font_id`.
- **Measurement.** `LayoutEngine.text` measures the whole content once with
  `measure_text_fn(content, font_id, font_size)`. With `.ellipsis` it also measures "…";
  with `.words` it finds the widest word for the text's floor width.
- **Wrapping.** `sizing_pass.wrapLines` scans words (`WordScanState`, bounded batches in
  `word_scratch`) and packs them (`LinePacker`) into `WrappedLine`s of `{start_offset,
  extent, width}`, 12 bytes each, in the layout arena. A word is measured with one call;
  each space and tab adds `space_width` or `tab_width`, measured once per text. Lines are
  claimed against `paint.glyph_count_frame_max`.
- **Drawing.** `emit.emitText` draws each line in view with one `placeText` call, which
  splits the line into shaping runs (`runLength`) of one font. Every line has the same
  pitch (`TextConfig.lineHeightPx`), so `linesInView` finds the lines in a clip with
  arithmetic. A cut line (`extent.end != .whole`) goes through `measureCut` and
  `placeTextPrefix`, which walk shaped clusters of one font, then draws "…".
- **Decoration.** `text/types.zig` has `TextDecoration` (underline, strikethrough) and the
  font metrics have `underline_position` and `underline_thickness`, but `ui.Text` exposes
  neither.
- **Accessibility.** `ui.text` adds no node; a box's `a11y.label` repeats its text
  (`docs/accessibility.md`). `Role.link` and `A11y.href` exist.
- **Activation.** A focused record's `on_click` runs on Return, keypad Enter, or Space
  (`router.zig`, `activates`).

## Prior art

- **The web.** Inline elements (`<b>`, `<code>`, `<a>`) inside one block. Line breaking is
  decided by the text alone: a style change is never a break opportunity, so `foo<b>bar</b>`
  stays one word. Shaping breaks at a font change, so kerning does not cross it. An inline
  background and underline are drawn per line fragment. `text-overflow: ellipsis` draws the
  "…" in the block's style. Links are focusable in tree order; a link that wraps is one
  focus stop with several boxes.
- **GPUI `StyledText`.** One `SharedString` plus `Vec<(Range<usize>, HighlightStyle)>`,
  with highlights as byte ranges over one string; `InteractiveText` adds click and hover
  handlers on ranges, found from the painted layout. Taken: one contiguous string with a
  style table over byte ranges, so wrapping and truncation see one text.
- **egui `LayoutJob`.** One `text: String` and `sections: Vec<LayoutSection>`, each a byte
  range and a `TextFormat` (font, color, background, underline, strikethrough, italics,
  `valign`). Mixed sizes are allowed and each row takes its tallest section. Taken: the
  section fields; not taken in the first phases: mixed sizes (see "Size").
- **Flutter `Text.rich` / `TextSpan`.** A tree of spans with a `recognizer` for taps;
  styles inherit from the parent span. Taken: inheritance from the element's style, but as
  a flat list (no tree, so no recursion and no depth bound to choose).

## API

```zig
pub const Span = struct {
    text: []const u8,
    /// Each field left null inherits the element's `ui.Text` value.
    weight: ?FontWeight = null,
    italic: ?bool = null,
    family: ?FontFamily = null,
    color: ?ColorToken = null,
    /// A fill behind the span's glyphs on each line it covers, such as inline code.
    background: ?ColorToken = null,
    decoration: TextDecoration = .{},
    link: ?Link = null,
};

pub const Link = struct {
    on_click: Handler,
    /// A stable identity for focus across frames. Without it, the link's id is the
    /// text's id and the span's index, and inserting a span before it moves focus.
    key: ?Key = null,
    /// Reported to accessibility as the link's URL; not opened by Gooey.
    href: ?[]const u8 = null,
};

pub const Text = struct {
    // ... every field today, unchanged ...
    pub const Element = struct { ... }; // unchanged: `ui.text`'s element

    pub const Rich = struct {
        spans: []const Span,
        style: Text,

        pub const core_element: ElementKind = .text;
    };
};

/// A text made of styled spans. The spans' bytes are joined in order; `style` sets
/// everything they do not override, and everything that is per text (size, wrap,
/// line height, alignment, line count, overflow).
pub fn rich(spans: []const Span, style: Text) Text.Rich {
    return .{ .spans = spans, .style = style };
}
```

```zig
ui.rich(&.{
    .{ .text = "Build " },
    .{ .text = "#4821", .family = .mono, .background = .surface },
    .{ .text = " failed on " },
    .{ .text = "main", .weight = .semibold },
    .{ .text = ". " },
    .{ .text = "Open the log", .link = .{ .on_click = cx.handler(openLog) } },
}, .{ .wrap = .words, .color = .subtext });
```

Decisions:

- **One node kind, two element types.** `ui.rich` returns `Text.Rich`, so a text cannot
  hold both content and spans. Both build a `.text` node, so a text is a text everywhere
  (layout, emit, the debugger). Emit draws a plain text as one implicit run, so the two
  share every drawing path, and `ui.text` builds and lays out exactly as before.
- **A flat list, not a tree.** Markdown nests emphasis inside a link; the app's parser
  flattens it into spans with combined fields. A flat list has no recursion and one bound.
- **Spans are copied at build.** Each span's bytes go into the frame's text bytes back to
  back, so the slice may point at a buffer local to the render function, as `a11y` strings
  may. A markdown view parses into its own fixed buffer, reserved at init.
- **Link defaults.** A link span with no `color` takes the theme's `link` color and with no
  `decoration` is underlined, so links look like links without per-app styling. The cursor
  over a link is `.pointer`.
- **No per-span size** in the first phases (see "Size").

## Semantics

### Content and spans

The text's content is the concatenation of its spans' bytes. A span boundary must be a
codepoint boundary: a span whose first byte is a UTF-8 continuation byte panics with the
span's index and the text's first bytes, as `checkTextStyle` reports today. This check is
one byte per span, not a scan of the content. An empty span adds nothing and takes no slot,
except that an empty link span panics: a link needs text to be clicked and named.

A style change inside a grapheme cluster (a combining accent in its own span) shapes the
mark in its own run, as a browser does. It is allowed, not supported.

### Line breaking

Break opportunities depend only on the bytes, as on the web: `foo` regular followed by
`bar` bold is one word and never breaks between them. A word's width is the sum of its
pieces, each measured in its span's font. A space or tab takes the width of a space or tab
in the font of the span holding it.

### Size

Every span has the element's size, and every line the element's pitch. A `.mono` or bold
span whose font has a taller ascender sits on the element's baseline (the base font's
ascender), so lines stay evenly spaced. This keeps what depends on a uniform pitch:
`linesInView`'s arithmetic culling and the text-size cache key. Headings and other block
sizes are separate texts in a markdown view. Mixed sizes are under "Later".

### Drawing

Each drawn line is split into segments: the parts of the line between span boundaries.
Emit draws each segment with one `placeText` call in its span's font and color, advancing
the pen by the returned width, so segments abut exactly where the shaper put them. Shaping
does not cross a segment: kerning across a style change is lost, as on the web. Layout
measures the same pieces, one per span even where adjacent spans share a font, so the
widths it wraps by are the widths emit draws.

Per segment, in this order: a background quad (the segment's advance by the line's pitch),
then the glyphs, then a decoration quad from the base font's `underline_position` and
`underline_thickness` (strikethrough at half the x-height). A background or decoration
over a wrapped span is drawn once per line it covers. Alignment is unchanged: a line's
width is the sum of its segments, computed during wrapping.

### Truncation

Truncation keeps its rules (`docs/text-truncation.md`); only the walk changes:

- `measureCut` and `placeTextPrefix` walk segments instead of one run, switching font at
  each span boundary. The cut point can land in any span.
- The "…" is drawn and measured in the element's style, as CSS draws the ellipsis in the
  block's style, so `ellipsis_width` stays one measurement per text.
- A span cut by the "…" draws its background and decoration only under its kept part.
- A link loses the hit area of its hidden part. A link that is hidden entirely gets no
  hit record and no accessibility node, so it is not a Tab stop. This differs from a
  browser, which keeps a link cut by `overflow: hidden` focusable; Gooey cannot reveal
  it, so focusing it would show nothing.

### Links

A link span becomes interactive without a node of its own:

- **Hit records.** For each line a link covers, emit appends one `HitRecord` with the
  link's id, the segment's box (x and width from the pen, the line's top and pitch),
  `on_click`, `cursor = .pointer`, `focusable = true`, and `parent` set to the text's
  enclosing hit scope. Only the first segment is a `tab_stop`, so a wrapped link is one
  Tab stop. Records follow tree order, so a link inside a clickable box takes the press,
  as a later sibling does today.
- **Focus.** The router needs no change: Tab reaches the first segment, Return, Enter, or
  Space runs `on_click` (`activates`), and a click focuses it like any focusable record.
  Emit draws the focus ring around each segment of the focused link.
- **Shown bytes.** A link exists this frame only if a line shows one of its bytes: all of
  a whole line, or the kept prefix of a cut line, measured as emit draws the cut. A link
  wholly hidden by a cut, on any line, gets no record and no accessibility node. The
  accessibility and hit passes share this test (`linkLine`), so they agree.
- **Culled lines.** A shown link whose first shown line is outside its scroll box's view
  still gets one record, with that line's box and no pointer, so the pointer never finds
  it. Tab can reach it, and the focus reveal scrolls its line into view; the next frame
  draws exact segments. Records stay in byte order, which is Tab order. A link's first
  record, drawn or culled, is its one Tab stop (`SpanLink.hit`).
- **Drag previews and tooltips.** A fragment that takes no pointer gets no link records,
  so a dragged copy of a link cannot be focused or activated, even past a modal.
- **Focus ring.** One ring per drawn segment, at most 8 (`link_ring_count_max`); a link
  wrapping further rings its remaining lines as one box.
- **Identity.** A link's id is `text_id.child(key)` with a `key`, otherwise
  `text_id.auto(span_index)`. A text has no children, so these cannot collide with a node.
  Every segment of a link shares the id, so the router's `findRecord` lands on the first.

### Accessibility

`ui.text` and `ui.rich` still add no node for the text: the text is read through a box's
`a11y.label`, as today. Each shown link adds one node with role `.link`, its span's text as
the name, `focused` when held, and as bounds the union of its drawn segments inside the
clip. A shown link with no visible segment, scrolled away, has its first shown line's box
instead. The node nests under the nearest accessible ancestor, as a box does.

What reaches assistive technology is what a box's node reaches today: role, name, state,
and bounds. The node records `href`, as `A11y.href` does for a box, but the platform
bridge does not yet publish `href` for either, and no platform action routes to a
handler. A screen reader user activates a link as a keyboard user does: Tab to it, then
Return. Publishing `href` and accessibility actions is a bridge change for boxes and links
together.

`emitAccessibility` runs before `emitFragment`, which is where segment positions are
known. The accessibility pass appends each link's node with the text's bounds and stores
the node's index with the span; the fragment pass then writes the segment union into that
node. No second shaping pass is needed.

Labelling the surrounding text is the app's job today, and harder with spans because the
label is the joined spans. `ui.richLabel(spans, buffer) []const u8` joins them into an
app-owned buffer; whether rich texts should become `.text` nodes instead is open
question 1.

## Engine and core design

### Build

`buildText` with spans:

1. Checks every span (boundary byte, empty link, and the pool's room for the non-empty
   spans) before writing anything, so a failed build leaves no partial text.
2. Copies the spans' bytes back to back with `copyText` and asserts each range starts
   where the last ended, giving the node one `TextRange`.
3. Claims one slot per non-empty span in two arrays of the same index, reserved at init
   and reset by `beginBuild`:
   - **`window.span_runs: []TextRun`**, `{ end: u32, font_id: u16 }`, 8 bytes. Layout
     borrows the text's slice of them (`TextData.runs`) until the next `beginFrame`.
   - **`window.span_paints: []SpanPaint`**, color, optional background, and decoration,
     40 bytes, read only by emit. Links (phase 2) add their handler and id here.
4. Sets `node.spans = .{ .start, .len }` and passes `TextData.runs` (a slice of
   `span_runs`) to layout. A text without spans keeps empty `runs` and takes today's path.

`TextRun.end` values strictly increase and the last equals the content's length, asserted
when claimed and again when layout reads them.

### Layout

`LayoutEngine.text` measures each run instead of the whole content once (`measured_width`
is their sum). The floor width (widest word) and wrapping use the same scanner with a run
cursor:

- `WordScanState` carries the current run and its font's `space_width` and `tab_width`.
  When `byte_pos` reaches the run's `end`, `endWord` first measures the piece of the
  current word in the old font, then the cursor advances and measures a space and a tab in
  the new font. A word's width is the sum of its pieces.
- `LinePacker` is unchanged: it sees words with widths, as today.
- Loops are bounded as today (`batch_count <= text.len`), and the run cursor advances at
  most `runs.len` times per text, asserted.

`Cx.measureText` gains a span form, `cx.measureRich(spans, style, width)`, for virtual
lists that size rows before building them. Its `TextSizeKey.text_hash` hashes the bytes and
the `(end, font_id)` pairs, so a restyle that changes widths misses the cache and one that
only changes color hits it.

### Emit

`emitText` walks a line's segments with a run index found by binary search on `end` for the
line's first byte (O(log s)), then steps forward. A cut line uses the segment-walking
`measureCut` and `placeTextPrefix`. Link hit records and segment backgrounds come from the
same walk; no extra measurement or shaping happens.

## Capacities

One new field in `BuildLimits`, frame-scoped like `element_count_frame_max`:

| Profile    | `span_count_frame_max` | Reserved (80 B per span) |
| ---------- | ---------------------: | -----------------------: |
| `nano`     | 128                    | 10 KB                    |
| `small`    | 1,024                  | 80 KB                    |
| `standard` | 4,096                  | 320 KB                   |
| `large`    | 16,384                 | 1.25 MB                  |
| `ceiling`  | 65,535                 | 5 MB                     |

Each span reserves an 8 B layout run, a 40 B paint, and a 32 B link (`SpanLink`: id,
handler index, href, accessibility node index, first hit record, and whether a segment
was visible). The link is written only for link spans.

The arrays live on the build side, so one copy exists per window, not one per frame. They
are taken from fresh pages, so only the spans an app uses become resident.

Relationships, checked with the other limits: `span_count_frame_max <=
text_bytes_frame_max` (every slot holds at least one byte). `nano` keeps rich text because a
colored or bold word costs little. The limit must be at least 1: `check()` rejects 0 as it
does every other build pool, so an app that never uses spans keeps the smallest profile's
128 slots (10 KB of address space, none of it resident until used).

Fixed costs that do not scale with `span_count_frame_max`:

- **Blank widths** (`LayoutEngine.blank_scratch`): 8 B per word, `word_count_text_max`
  (1,024) words, so 8 KB per window, written only while scanning a rich text.
- **Layout nodes**: `TextData` grows from 88 to 96 B for the run table index
  (`runs_start`, `runs_count`), on every text element.
- **Build nodes**: `Node.spans` adds 8 B per node.

Everything else spans add comes from existing budgets. Links add to pools that were bound
by the element count, so their relationships widen by the span budget, letting an app raise
just the pool its links use:

- **Paint records** (`records.paint_record_count_frame_max`): at most one background and
  one decoration quad per segment. Glyph quads do not change: the same glyphs are drawn.
- **Hit records** (`records.hit_record_count_frame_max`): one per drawn link segment, or
  one per culled link. A link's segments are at most one plus the lines it continues onto,
  so the bound is `element_count_frame_max + span_count_frame_max +
  paint.glyph_count_frame_max` (layout's wrapped lines share the glyph budget).
- **Handlers** (`records.handler_count_frame_max`): one per link; the bound grows by
  `span_count_frame_max`.
- **Accessibility nodes** (`a11y.element_count_max`): one per shown link; the bound is
  `element_count_frame_max + span_count_frame_max`, under the 16,384 tree ceiling.
- **Keys** (`build.key_count_frame_max`): one per keyed link; the bound is
  `element_count_frame_max + span_count_frame_max`.
- **Text bytes** (`build.text_bytes_frame_max`): each link's `href` is copied once.
- **Wrapped lines** (`paint.glyph_count_frame_max`): unchanged; spans do not add lines.

Exhaustion fails fast as every pool does: `build pool 'spans' exhausted: capacity {d}
(ResourceLimits.build.span_count_frame_max), {d} in use, {d} requested, frame {d}`.

## Performance sketch

Per frame, with no allocation:

- **No spans.** One null check per text in build, layout, and emit. Target: within 0.5 %
  instructions in the Cachegrind gate, with `ui.text` output identical byte for byte.
- **Build.** Per span one boundary check, one `copyText`, and 48 bytes written, plus 24
  for a link. At `standard`, at most 4,096 spans, 288 KB written sequentially.
- **Layout.** Per span boundary at most three extra measure calls (the word's piece, a
  space, and a tab in the new font), served by the text system's measure cache
  (`text.measure_slot_count_max`). At most 12,288 extra calls at `standard`, and most hit.
- **Emit.** Segments per frame are at most spans plus wrapped lines (each line can split
  one span): 4,096 + 4,096 at `standard`. Each segment is one `placeText` call and at most
  two quads, so at most 16,384 extra paint records. Each segment is its own shaped run:
  more, shorter runs per line. A markdown view with many short spans therefore puts more
  pressure on `text.shaped_run_count_max` (256 at `standard`); a miss reshapes into the
  cache's fixed slots and does not allocate. The benchmark below measures this.
- **Links.** Texts without links skip every step here. Per shown link one `linkLine`
  walk: a binary search for its start line (at most 32 steps) and one step per line it
  covers. A cut line it covers costs one `measureCut`, served by the shaped-run cache; at
  most two walks per link per frame (accessibility, then hits or the offscreen box). Per
  link at most one culled record, one record per drawn segment, and up to 8 ring quads
  for the focused one.
- **Pointer.** Link records are ordinary hit records; nothing new per event.

## Tests

- **Layout (`engine_tests.zig`).** The synthetic backend gives bold a wider advance, so a
  text measured in the base font wraps differently from one measured per span. Expected
  widths come from the synthetic advances, not from the engine: a word that is half bold
  wraps where its summed width overflows; spaces inside a bold span take the bold space
  width; a style change inside a word never breaks it; the floor width is the widest
  mixed word; `measureRich` equals the built text's size.
- **Emit.** Segments of a line partition it and their widths sum to `line.width`; a
  centered mixed line is centered by its summed width; backgrounds and decorations are one
  quad per segment per line; a span wrapped over two lines gets two backgrounds. A cut
  line whose cut lands in a bold span keeps the right prefix, and the "…" has the base
  color. `ui.rich` with one span emits records identical to `ui.text` with the same style.
- **Links.** A link wrapped over two lines has two records with one id and one Tab stop;
  Tab then Return runs `on_click`; a click inside a clickable box goes to the link; a
  fully hidden link has no record and no node; a link on a culled line is reachable by Tab
  and revealed; the accessibility node's bounds are the segments' union.
- **Errors and capacity.** A span starting with a continuation byte and an empty link
  span panic with their messages. Fill `span_count_frame_max` exactly, check the last span
  draws, then one more is the `core-span-count` fail-fast mode, with its message in
  `build.zig`; a text whose spans do not fit panics before writing any of them.
- **Goldens.** `core_rich_text.txt` replays a new `src/examples/rich_text.zig`: a chat
  message with a mention, inline code, and a link; a markdown paragraph that wraps a bold
  phrase across lines; a truncated cell; Tab to the link and Return.
- **VOPR.** Random span lists over random content (boundaries at random codepoints, random
  fonts, links), random widths, alignments, and line counts. Invariants: runs strictly
  increase and end at the content's length; segments partition each drawn line; summed
  segment widths match `line.width` within the existing cut tolerance; every link record
  lies within its text's bounds; and wrapping a rich text whose spans all share the base
  font produces the same lines as `ui.text`.
- **Benchmark.** `text_rich_markdown` in `src/text/benchmarks.zig`: a screen of markdown
  with a span every few words, against the same text as plain `ui.text`.

## Effort

**Medium.** It adds no subsystem; it threads a run table through build, layout, and emit,
and reuses hit records, focus, and accessibility nodes for links. Approximate sizes,
including tests:

1. **Styled spans (medium, about 1,200 lines).** `Span`, `ui.rich`, the two arrays and
   their limit, segmented measurement and wrapping, per-segment drawing with backgrounds
   and decorations, segment-walking truncation, `measureRich`, and a golden.
2. **Links (medium, about 800 lines).** Hit records per segment, Tab stops, the focus
   ring, culled-line records, accessibility nodes and their bounds, `ui.richLabel`.

About 2,000 lines in two changes.

## First step

Phase 1 without links: `Span` with weight, italic, family, color, background, and
decoration; `ui.rich`; `build.span_count_frame_max`; and the run-aware scanner, emit walk,
and truncation walk, tested against synthetic widths. It unblocks chat and markdown
styling, and both later phases build on the same run table.

## Later

- **Mixed sizes.** Per-line ascent and descent (the tallest run's), stored in
  `WrappedLine` (12 to 16 bytes), line tops from a prefix sum instead of `index * pitch`,
  and a binary search in `linesInView`. Needed for inline emoji at a larger size or a
  superscript.
- **Link hover.** A hovered link changing its underline or color, which needs the hovered
  record's id in the build.
- **Inline images.** An icon or avatar in a line, as a span that reserves an advance.
- **Ranges over a string.** `ui.styled(content, ranges)` with `{ end, style }` ranges over
  one string, for syntax-colored log lines that already hold one buffer. It is the same
  run table with a second front end.
- **Selectable text.** Out of scope here. Spans are byte ranges over one contiguous string
  so that `docs/selectable-text.md` can later work on rich texts unchanged: segments pass
  their byte offset to `placeText`, so cluster offsets stay in whole-text terms; copy reads
  the bytes; a span background must then be drawn before the selection highlight.

## Open questions

1. **Text nodes.** Should a rich text, or any text with a link, add a `.text` or
   `.paragraph` node so its words are read without a box label?
2. **Ellipsis style.** The "…" takes the element's style. When the cut lands in a link or
   a colored span, should it take that span's color instead?
3. **Link colors.** Decided: the theme has a `link` color, separate from `primary`.
4. **Underline placement.** Decided: every segment's underline and strikethrough use the
   text's base font metrics, so a `.mono` word inside a link sits at the same height.
5. **Per-text span bound.** Spans are bounded per frame, not per text. Should one text
   also be capped, so one runaway message cannot use the whole frame's budget?
