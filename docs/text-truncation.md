# Text truncation

## Status

Proposed on 2026-11-22 against `main` after decision 28 (grids), approved the same day
with the answers under "Resolved questions", and implemented as decision 29 in
`docs/core-contract.md`. `src/examples/text_truncation.zig` shows a sidebar, a table, and
clamped cards. Three points differ from the proposal: `overflow` is an inline enum beside
`wrap` and `alignment` rather than a named `TextOverflow`; a `.none` text's one cut line is
marked `cut_if_wide`, not `cut` ("Passes"); and, decided after review (resolved question
6), `.clip` cuts a too-wide line at the cut width too, so no text draws past it. It is the
last open item under "P1: layout" in `docs/api-developer-experience-roadmap.md`. It builds
on decision 26 (content floors and largest-first shrink) and decision 27 (heights after
widths). A text that fits its width lays out and draws byte for byte as before; only a line
wider than its width, which drew past its parent before, is now cut at it.

## Why

`ui.text` either draws one line past its box or wraps to as many lines as it needs. Neither
fits the places a list, a table, or a card holds text it does not control:

- **Table cells.** `src/examples/grid_layout.zig` wraps the name column (`.wrap = .words`),
  so one long name makes its row taller than the others. A cell that does not wrap runs
  into the next column instead, because decision 26 shrinks a `.fit` or `.grow` column only
  to its text's floor, which is the text's whole one-line width.
- **Sidebars and list rows.** A file or channel name in a fixed-width sidebar, beside an
  icon and a badge, must stay on one line and show that it was cut. Today the name either
  pushes the badge out of the row or draws over it.
- **Cards.** The dashboard cards in the same example wrap their body text without limit, so
  a long body makes its card, and every card on its grid row, taller. A card wants two or
  three lines and an ellipsis.
- **Virtualized lists.** `src/examples/virtual_list_example.zig` sizes each row with
  `cx.measureText`. A preview line clamped to two lines gives every row a known, bounded
  height.

Every case needs the same two things: a line cut at the text's width ends in "…", and a
wrapping text shows at most N lines.

## Prior art

- **Clay (`clay.h`).** `Clay_TextElementConfig` has `wrapMode` (words, newlines, none) and
  `textAlignment`, and nothing for truncation. A text that cannot wrap keeps its width until
  its parent's other children can shrink no more, then each line's render command is
  narrower than its text and the renderer cuts it at a scissor. Taken: nothing beyond the
  existing wrap modes; Clay is the reason this is new engine surface.
- **CSS `text-overflow` (CSS Overflow 3 and 4).** `clip`, `ellipsis`, or a string, on a
  block container with `overflow` other than `visible`, usually with `white-space: nowrap`.
  The user agent hides characters at the end of each overflowing line until the ellipsis
  fits and places it right after what remains; when even the ellipsis does not fit, the
  ellipsis itself is clipped. The ellipsis does not change the box's intrinsic sizes, but
  `overflow: hidden` makes a flex or grid item's automatic minimum size 0, so the item can
  shrink. Taken: the per-line rule, sizes unchanged by the ellipsis, and a small floor.
- **CSS `line-clamp` and `-webkit-line-clamp`.** `line-clamp: N` is `max-lines: N` and
  `block-ellipsis: auto`: the box keeps N lines, the rest is neither drawn nor measured,
  and the Nth line ends in an ellipsis. To make room, content is displaced from the end of
  that line "as if wrapping", back to the last soft wrap opportunity that lets the whole
  ellipsis fit, so the cut falls between words. A box with exactly N lines shows no
  ellipsis. The legacy `-webkit-line-clamp` needs `display: -webkit-box` and
  `-webkit-box-orient: vertical`. Taken: the clamp, height of exactly N lines, no ellipsis
  at exactly N lines. Not taken: the word-boundary cut ("Resolved questions" 2).
- **GPUI.** `TextStyle.text_overflow: Option<TextOverflow>` with `Truncate`,
  `TruncateStart`, and `TruncateMiddle`, each carrying its affix string, and
  `line_clamp: Option<usize>`. `.truncate()` is `overflow_hidden().whitespace_nowrap()
  .text_ellipsis()`; `.line_clamp(n)` sets the clamp and `overflow_hidden()` but no
  ellipsis. `LineWrapper::truncate_line` sums per-character widths from a cache (no
  kerning; its comment notes the overestimate), cuts at a character, and trims trailing
  whitespace and ASCII punctuation before the affix. `truncate_wrapped_line` wraps to the
  clamp, then fills the last line with the text that follows, character by character, so
  the cut falls mid-word ("aaa requir…"). It builds a new truncated string and shapes that.
  Taken: two independent fields, start and middle truncation as later variants of one
  enum, and the filled last line. Not taken: per-character widths, a new string per frame,
  and the affix string.
- **Flutter, UIKit, Android.** `Text(maxLines: n, overflow: TextOverflow.ellipsis)`,
  `numberOfLines` with `.byTruncatingTail`, and `maxLines` with `TextUtils.TruncateAt.END`
  all fill the last line and cut it at a grapheme. Confirms the filled last line as the
  native toolkit default.

## API

```zig
pub const Text = struct {
    // ... every field today, unchanged ...
    /// The most lines a wrapping text shows; the rest is not drawn and takes no
    /// height. null: every line. 1 to 255; needs `.wrap` other than `.none`.
    line_count_max: ?u8 = null,
    /// What marks a line cut short: one wider than the text (`.none` text, a
    /// `.newlines` paragraph, or a word longer than a `.words` line), or the last
    /// line of a text that `line_count_max` cut. `.clip` cuts with no mark:
    /// lines past the limit are dropped and a too-wide line is cut at the
    /// text's width; `.ellipsis` cuts it the same way and ends it in "…".
    overflow: enum { clip, ellipsis } = .clip,
};
```

`overflow` is an inline enum, as `wrap` and `alignment` are beside it; the engine's
`TextConfig.Overflow` mirrors it, and code that needs the type names it
`@FieldType(ui.Text, "overflow")`.

A table cell and a sidebar name, a card body of at most three lines, and a list preview:

```zig
const cell_text: ui.Text = .{ .size = 13, .overflow = .ellipsis };
const name_cell = ui.text(person.name, cell_text); // in a .grow column: one line, cut to it

const sidebar_row: ui.Style = .{ .width = .{ .grow = 1 }, .gap = 8, .alignment = .center_cross };
const channel_row = ui.box(.{ .style = sidebar_row }, .{
    icon,
    ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{
        ui.text(channel.name, .{ .overflow = .ellipsis }),
    }),
    badge, // keeps its width; the name gives way first
});

const card_body: ui.Text = .{
    .size = 15,
    .wrap = .words,
    .line_count_max = 3,
    .overflow = .ellipsis,
};

// The row's height before layout, as layout will size it: at most two lines.
const preview: ui.Text = .{ .wrap = .words, .line_count_max = 2, .overflow = .ellipsis };
const height = cx.measureText(message.body, preview, text_width).height;
```

Truncation changes only what is drawn. `ui.text` adds no accessibility node, so a screen
reader hears the full text only through a box that names it: a truncated cell's row box
sets `a11y.label` to the full text, as any row does today.

## Semantics

### The cut width

A text is cut at the width it wraps at: its parent's content width (its cell's, in a grid),
or the width its row shrank it to when that is narrower (`wrapElementText`'s `wrap_width`).
A `.none` text is cut at the same width, which it ignored before. A text whose parent
scrolls along x is not cut: its parent's content may be wider than the parent, so the text
scrolls instead.

### Which lines are cut

Each drawn line ends in one of three ways:

1. **Whole.** It fits the cut width, and either it is the text's last line or the next line
   is drawn too. Drawn as today.
2. **Too wide.** It is wider than the cut width: the whole of a `.none` text, a `.newlines`
   paragraph, or a `.words` line holding one word longer than the cut width. With
   `.ellipsis` it is cut and ends in "…"; with `.clip` it is cut at the same place with no
   mark, so no text draws past its cut width. Before, it drew whole, past its parent.
3. **Clamped.** It is line `line_count_max` and text follows it. With `.ellipsis` it ends
   in an ellipsis even when it fits; with `.clip` it ends where wrapping ended it and the
   rest is dropped.

A text of exactly `line_count_max` lines shows no ellipsis, as in CSS.

`.clip` keeps decision 26's floors, unlike `.ellipsis`: a row that overflows does not
shrink a `.clip` label below its one-line width, or a wrapping one below its widest word.
So a `.clip` text is cut only where its parent cannot give it its floor (a fixed or grid
column, a padded box), at the parent's content width. In a row that overflows despite its
floors, a text that does not start at the row's left edge may still pass the row's right
edge by its offset, as the row itself overflows (`Style.clip` on the row cuts that).

### Where a line is cut

A cut line keeps the longest start that fits the cut width with the ellipsis after it:

- **The clamped line is filled.** Its content runs from its start to the end of its
  paragraph (the next newline or the text's end), not to where wrapping broke it, so the
  last line is as full as a `.none` text cut at the same width: "Quarterly revenue grew
  in every reg…", not "Quarterly revenue grew in every…". When the paragraph ends on that
  line and another follows, the ellipsis follows the paragraph's last character.
- **At a cluster, before an advancing glyph.** The cut falls between two of the shaper's
  clusters (`ShapedGlyph.cluster`), so it never splits a UTF-8 sequence or a ligature, and
  never before a glyph with no advance. The shapers report a cluster per codepoint
  (HarfBuzz runs at `MONOTONE_CHARACTERS`; CoreText maps each glyph to its codepoint), so a
  combining accent or a variation selector is a cluster of its own; it advances by 0, and
  the second rule keeps it with its base. Gooey has no grapheme tables, and this needs
  none.
- **Whitespace trimmed.** Spaces and tabs before the cut are dropped, so the ellipsis
  follows the last visible character. Punctuation stays.
- **Exact widths.** The fit is decided from the shaped line's advances, kerning included,
  the same advances the line is drawn with. A too-wide line, as layout measured it, whose
  shaped width equals the cut width is drawn whole.
- **Too narrow for the ellipsis.** When the cut width is narrower than the ellipsis, the
  line draws nothing. CSS clips the ellipsis instead; Gooey draws no partial glyphs.

The ellipsis is U+2026 in the text's family, size, weight, and color. A face without the
glyph draws it through the text system's fallback, as any other missing glyph.

### Sizes

- **Width.** A text's minimum width stays its one-line width, so a `.fit` parent with room
  shows it whole; the ellipsis never makes a text wider or narrower than it would be
  without it (CSS: intrinsic sizes are unchanged). A cut line's box is the cut width.
- **Floor.** A text with `.ellipsis` floors at the ellipsis's width (or its one-line width,
  when that is smaller) instead of its widest word or its one-line width. Decision 26's
  overflow shrink therefore cuts it before it cuts a fixed sibling, and largest first: in a
  sidebar row the long name gives way, the badge does not. In a grid, a `.grow` column of
  truncating text grows from that floor, so equal weights stay equal and the text is cut
  instead of wrapped; a `.fit` column of truncating text gives way first in an overflowing
  grid. Floors propagate as today, so a `.fit` box around the text floors at the ellipsis
  plus its padding. This is CSS's `overflow: hidden` minimum, raised from 0 to the
  ellipsis so a shrunk text still says it was cut.
- **Height.** A clamped text is `min(lines, line_count_max)` lines tall. The minimum pass
  takes one line, as for every text; the wrap marks the text when its height differs, and
  decision 27's heights pass sizes its ancestors from the clamped height. A card row whose
  bodies are clamped to three lines is at most three lines tall.
- **`cx.measureText`** returns what layout will size: at most `line_count_max` lines tall,
  and no wider than `max_width`.

### Alignment

`.center` and `.right` align a cut line by the width it draws, ellipsis included, as CSS
aligns after placing the ellipsis. A right-aligned cut line ends at the cut width's right
edge less any trimmed whitespace and the part of a glyph that did not fit.

### Limits

- **Left to right only.** The cut keeps a line's start. Gooey has no bidirectional layout;
  wrapping makes the same assumption.
- **Graphemes by advance.** A grapheme whose later codepoints advance, such as an
  unligated emoji sequence joined by U+200D, can be cut inside. A font that ligates the
  sequence draws one glyph, which is never split.

## Validation

Each misuse panics when the text is declared, naming up to its first 32 bytes:

- `line_count_max` 0: "Text.line_count_max 0 ("{s}"): a text shows 1 to 255 lines".
- `line_count_max` with `.wrap = .none`: "Text.line_count_max ("{s}"): a .none text is one
  line; wrap at .words or .newlines".

The types bound the rest: `line_count_max` is a `u8` and `overflow` an enum.

## Engine design

### Storage

- `TextConfig` gains `line_count_max: u8` (0 for none, as the engine's sentinel) and
  `overflow: Overflow`, `enum(u1) { clip, ellipsis }`.
- `TextData` gains `ellipsis_width: f32`, measured once in `LayoutEngine.text` for an
  `.ellipsis` text and 0 otherwise.
- `WrappedLine` gains `end: LineEnd`, `enum(u2) { whole, cut_if_wide, cut }`: rule 1, 2,
  and 3 above. It stays 12 bytes: `length` becomes a `u30` packed with the `u2` end in
  one `u32`, so the size assertion in `LayoutCapacity.arenaBytes` holds unchanged. A
  comptime assertion checks that the ceiling of `build.text_bytes_frame_max` (4 MiB) fits
  in 30 bits, so no text the core declares has a line longer than `length` holds; the
  engine asserts the same of each text it wraps. A cut line's `width` is its cut width, so
  the widest line, the text's box, and emit's culling read it unchanged.
- No new pool and no new budget field. A clamped text claims at most `line_count_max`
  lines of `wrapped_line_count_frame_max`, never the lines it does not draw.

### Passes

1. **Declaration (core).** `Cx.buildText` validates the two fields and maps them in
   `textConfig`. `LayoutEngine.text` measures the ellipsis through the measure callback
   for an `.ellipsis` text and floors it at `@min(measured_width, ellipsis_width)`; it
   skips the `widestWord` scan, which that floor makes unnecessary. A floor below the
   one-line width sets `floors_differ`, as a wrapping text's does.
2. **Minimums and sizing.** Unchanged: floors and minimums already flow through
   `computeMinSizes`, `planChildSizes`, and the grid's column passes.
3. **Wrapping (`wrapElementText`, `wrapLines`).** A `.none` text whose one-line width is
   above its cut width, and whose parent does not scroll along x, gets one line, `[0, len)`,
   marked `cut_if_wide`, since no text follows it and its width came from the shaper emit
   draws with (`cutOneLine`); others keep `wrapped_lines = null`, as today. A wrapping text
   packs lines as today and marks each line wider than the cut width `cut_if_wide`, for
   either overflow. With `line_count_max = N`, `LinePacker` stops when line N would end at a
   wrap and text follows: line N then runs to its paragraph's end, found by one scan for
   `'\n'`, and is marked `cut` (or kept as wrapped, with `.clip`); the scan of words stops
   with it. A line N that ends at a newline with text after it is marked `cut` as is.
   `measureWrapped` uses the same packer, so `cx.measureText` stops at the same line.
   `TextSizeKey.style` adds `line_count_max` and `overflow` to the bits it packs (bits 50 to
   58).
4. **Heights (decision 27).** Unchanged: a clamped text that is not one line tall marks
   itself `min_height_dirty`, as any wrapped text does.
5. **Emit (`emitText`).** A line marked `whole` draws as today. A line marked
   `cut_if_wide` or `cut` goes to `emitCutLine`. `text_render.measureCut` walks the
   line's shaping runs (`runLength`) through `shapeTextInto`, adding advances until the
   pen passes the cut width less the ellipsis (less nothing, for `.clip`; the ellipsis
   width is the one layout measured at declaration); it keeps the last cut before an advancing
   glyph that starts a cluster and follows a byte that is not a space or tab, and returns
   the kept byte length and its width. A `cut_if_wide` line whose runs all fit is drawn
   whole. Emit then aligns the kept width plus the ellipsis, places the kept glyphs
   from the same runs (`text_render.placeTextPrefix`, each run a shape-cache hit the
   second time), and, for `.ellipsis`, places the ellipsis as a run of its own. A `.none`
   text's one cut line is drawn the same way.

The engine never builds a truncated string: the kept glyphs are a prefix of the shaped
line, so the drawn text keeps the line's own kerning and the arena holds no new bytes.

## Capacities

No new pool, no new budget field, and no growth of any reservation: `WrappedLine` keeps its
12 bytes, and the ellipsis width is one `f32` in `TextData`, which the element already
holds. A clamped text claims fewer of `wrapped_line_count_frame_max`'s lines than the same
text unclamped, so frames that clamp long texts write less of the arena and the line
scratch than they do today.

## Performance sketch

Per text, with no allocation:

- **Texts with neither field:** one branch in `LayoutEngine.text`, one in
  `wrapElementText`, one per line packed, and one per drawn line in `emitText` reading
  `end`. Target: within 0.5 % instructions in the Cachegrind gate, as decision 28 held
  grids to. Measured against `main` at 0a37bfb: every existing benchmark within +0.032 %
  (layout) and ±0.09 % (text, core, accessibility, noise), none regressed.
- **Declaration of an `.ellipsis` text:** "…" is measured once per `.ellipsis` text when
  it is declared, through the measure callback, which is a shape-cache hit after the first
  frame; it replaces `widestWord`'s scan of every word, so a long `.words` body declared
  with `.ellipsis` measures fewer words than today. Should benchmarks show the measure
  matters in a table of thousands of cells, it can be cached per font and size.
- **Clamped wrapping:** the batches of words up to and including the one in which line N
  ends, each at most `word_count_text_max` (1,024) words, then one byte scan of line N's
  paragraph. A 10,000-word body clamped to three lines measures one batch, 1,024 words,
  where it measures 10,000 today, and claims 3 lines where it claims about 250. The
  one-line measure in `LayoutEngine.text` still shapes the whole text once, as today.
  Measured: `text_clamp`, 100 cards of a 400-word body (one batch) clamped to three lines,
  runs 229 M instructions to `text_unclamped`'s 437 M, 48 % fewer, from the lines it
  neither packs past the clamp nor copies and from the `widestWord` scan an `.ellipsis`
  text skips. `text_ellipsis_cells`, 1,000 one-line cells cut by their rows, runs 20.6 M.
- **A cut line in emit:** the runs up to the cut, walked twice: once to find the cut, once
  to place it, the second from the shape cache. A run is at most 512 bytes
  (`ShapedRunCache.MAX_TEXT_LEN`) or `run_codepoint_count_max` codepoints, so a cut line
  shapes at most the runs its cut width covers plus one, whatever its paragraph's length.
  It places no more glyphs than the uncut line, plus one for the ellipsis.
- **Worst case at `standard`:** every one of 8,192 lines cut, each two short runs: about
  16,400 cached run lookups and one ellipsis run each. Today's emit already shapes each of
  those lines once through the same cache, so a frame of cut lines costs about twice a
  frame of the same lines uncut. Not yet measured: the gate's harnesses benchmark layout,
  not emit, so the proposed emit benchmark of cut cells is still to be written.

## Tests

- **Engine (`engine_tests.zig`, 10 px a byte, so "…" is 30 px):** a `.none` `.ellipsis`
  text of 10 bytes in a 100 px column is uncut; 11 and 40 bytes are one `cut_if_wide` line
  of width 100, one line tall; the same text with `.clip` is cut the same way with no
  ellipsis width and keeps its 400 px floor; in a box that scrolls along x it is uncut. A
  `.words`
  text of five lines clamped to 5 is five `whole` lines; clamped to 4, 2, and 1 it keeps
  that many, claims only those lines of the frame's budget, and its last is `cut`, runs on
  to the paragraph's end, and is the cut width wide. `.clip` with a clamp drops lines and
  marks none. A clamped line that ends at a newline with a paragraph after it is `cut` and
  keeps its bytes; one followed only by blank lines is `whole`. A 30-byte word in a 100 px
  `.words` `.ellipsis` text is a `cut_if_wide` line between two `whole` ones.
- **Floors:** a row of a 400 px `.ellipsis` text and a 300 px fixed box gives the text
  200 px in 500, its 30 px floor in 330, and the floor still in 310, overflowing; without
  `.ellipsis` the text keeps 400 px. A `.fit` box around the text floors at the ellipsis
  plus its padding.
- **Heights and measure:** a padded column of a title and a 200-word body clamped to 3
  lines is the title, three lines, and the padding tall, claims three lines, and
  `LayoutEngine.measureText` returns the body's laid-out size; a `.none` `.ellipsis`
  text measures at most the offered width.
- **`cx.measureText` (`core_checks.zig`):** two cases join the existing table, a clamp
  and a one-line `.ellipsis` text, each compared with its laid-out bounds.
- **Emit (`core_checks.zig`, synthetic face at size 10: "a" 5 px, a space 2.5, "é" and
  "…" 7):** ten "a" in 50 px draw uncut; in 49 px, eight and "…" 40 px after the first;
  "aaaa  bbbbbb" in 34 px drops the two spaces before "…" (the synthetic face draws
  spaces, so the glyph count shows it); "aaaaééé" in 37 px keeps "aaaaé", never a byte of
  "é"; 5 px, narrower than "…", draws nothing; a clamp to 2 lines fills line 2 to
  "aaaa aaaa" and adds "…"; `.right` starts the cut line 2 px in, so "…" ends inside 49;
  `.clip` draws nine "a" in 49 px with no mark and ten in 50. No case draws past its box.
  Existing checks whose text overflowed now see it cut: a centred `.newlines` line of
  103.5 px in 100 is cut to 95.5 and centred; `cx.measureText` of an 80 px `.none` text
  in 60 is 60; a 3,000-byte unwrapped text that must draw whole now sits in a box that
  scrolls along x. The VOPR's text area check accepts a cut word line at the wrap width
  and a zero-width preview cut to nothing.
- **Fail-fast modes** `core-text-line-count-zero` and `core-text-line-count-none` in
  `src/testing/fail_fast_check.zig`, with their messages in `build.zig`.
- **Goldens:** `core_truncation.txt` replays `src/examples/text_truncation.zig` through
  the core: a sidebar of long channel names beside unread badges, a file table on a grid
  whose `.grow` name column cuts long names with "…" and whose fixed note column cuts a
  long note with `.clip`, and three cards, two clamped to three lines
  with `.ellipsis` (one long, one short) and one clamped to two with `.clip`.
- **Fuzzing:** `fuzzTextWrapping` gives each text a random wrap mode, a clamp of 0 to 4
  where it wraps, and either overflow, and checks that it keeps at most `line_count_max`
  lines, that only `.ellipsis` marks a cut, that a cut line is at most the cut width, and
  that the text is as tall as its lines.
- **Benchmarks:** `text_clamp` and `text_unclamped` in `src/layout/benchmarks.zig`: 100
  cards of a 400-word body at 300 px, clamped to three lines with `.ellipsis` and not
  clamped; `text_ellipsis_cells`, 250 rows of four one-line `.ellipsis` cells that a row
  shrinks and cuts; each also as a full frame. The Cachegrind gate on every benchmark.

## Later

- **Start and middle truncation.** `overflow` values `.ellipsis_start` and `.ellipsis_middle`,
  as GPUI's `TruncateStart` and `TruncateMiddle`, for file paths and file names. A start
  cut walks a line's runs from its end, so it lands with its own engine test, one line
  only, and no clamp.
- **Telling the app a text was cut.** A table will want to show a cell's full text in a
  tooltip only when the cell's text was cut, which only layout knows, after the build. A
  bounded bit per text per frame, written by emit and read from the last frame as hit
  records are (`cx.hovered`), would cost almost nothing: one bit per text, no new pass,
  and a lookup by element id. Until then a cell can always set the tooltip, as Zed's tabs
  do.
- **`components.Table` and a sidebar component.** Roadmap P4; both use `.ellipsis` cells.

## Rejected

- **Per-character widths in layout** (GPUI's `CharWidthCache`). They ignore kerning, so a
  text that fits by its shaped width is cut, and they need a cache that grows with every
  new character. Emit already shapes each line; cutting there is exact and bounded.
- **A truncated string per frame** (GPUI). It needs arena bytes per cut line and a shape
  per new string, and the shape cache would fill with prefixes. A prefix of the shaped
  glyphs draws the same thing.
- **An affix string** (CSS `<string>`, GPUI's affix). Every caller uses "…"; a string
  would need copying into the frame and measuring per text.
- **A clip rect per cut `.clip` line.** It would cut pixel-exact, but through a glyph,
  and costs a clip push and pop paint record per cut line out of
  `paint.clip_depth_max` and the record budget, plus the glyphs past the edge that the
  rect then hides. The glyph prefix `.ellipsis` already uses costs neither: it draws
  fewer glyphs than the uncut line, reuses `measureCut` and `placeTextPrefix` with an
  ellipsis width of 0, and is exact to a cluster.
- **Cutting in the minimum or sizing pass.** Widths are not final until wrapping, and a
  cut there would measure each text more than once, which decisions 27 and 28 avoid.

## Resolved questions

Approved on 2026-11-22.

1. **Fields.** `line_count_max: ?u8` and `overflow` stay independent, as
   GPUI's `line_clamp` and `text_overflow`: a clamp does not imply the ellipsis, as it does
   in CSS's `line-clamp: N` and Tailwind's `line-clamp-N`, because an explicit field reads
   better. The default is named `.clip`, not `.visible`: with a clamp it drops the lines
   past the limit, so the name says the text is cut.
2. **Where the clamped line is cut.** Filled to the cut width and cut at a cluster, as GPUI,
   Flutter, UIKit, and Android do, not back at a word as CSS's `block-ellipsis` does,
   which wastes up to a word of width in a narrow cell.
3. **Floor of an `.ellipsis` text.** The ellipsis's width. CSS's is 0, which lets a text
   vanish; the one-line width would push a row's badge out before cutting the name. A
   `.words` `.ellipsis` text without a clamp may therefore shrink below its widest word and
   cut that word, where today it would overflow.
4. **Trimming before the ellipsis.** Spaces and tabs, as CSS. GPUI also trims ASCII
   punctuation, which turns "3.5" into "3…".
5. **Telling the app a text was cut.** Not in this change; see "Later".
6. **`.clip` and too-wide lines** (after review). `.clip` cuts a line wider than its cut
   width as `.ellipsis` does, without the "…", so `.clip` means the text never draws past
   its width; it stays the default. It cuts with the glyph prefix, not a clip rect
   ("Rejected"). It keeps decision 26's floors ("Which lines are cut"), so a label still
   gives way only after its row's other children, and a text in a box that scrolls along
   x is not cut. Every golden of a text that fits is unchanged byte for byte.
