# Text truncation

## Status

Proposed on 2026-11-22 against `main` after decision 28 (grids), for review before any code
is written. It is the last open item under "P1: layout" in
`docs/api-developer-experience-roadmap.md`. It builds on decision 26 (content floors and
largest-first shrink) and decision 27 (heights after widths), and changes no existing
default: a text that sets neither field below lays out and draws as it does today.

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
  at exactly N lines. Not taken: the word-boundary cut ("Open questions" 2).
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
    /// line of a text that `line_count_max` cut. `.visible` draws such a line
    /// whole, past its box, as today; `.ellipsis` ends it in "…".
    overflow: TextOverflow = .visible,
};

pub const TextOverflow = enum { visible, ellipsis };
```

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
A `.none` text is cut at the same width, which it ignores today.

### Which lines are cut

Each drawn line ends in one of three ways:

1. **Whole.** It fits the cut width, and either it is the text's last line or the next line
   is drawn too. Drawn as today.
2. **Too wide.** It is wider than the cut width: the whole of a `.none` text, a `.newlines`
   paragraph, or a `.words` line holding one word longer than the cut width. With
   `.ellipsis` it is cut; with `.visible` it draws past its box, as today.
3. **Clamped.** It is line `line_count_max` and text follows it. With `.ellipsis` it ends
   in an ellipsis even when it fits; with `.visible` it ends where wrapping ended it and the
   rest is not drawn.

A text of exactly `line_count_max` lines shows no ellipsis, as in CSS.

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
  and for a `.ellipsis` text no wider than `max_width`.

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
  `overflow: TextOverflow`, a byte each; a comptime assertion pins its size.
- `TextData` gains `ellipsis_width: f32`, measured once in `LayoutEngine.text` for an
  `.ellipsis` text and 0 otherwise.
- `WrappedLine` gains `end: LineEnd`, `enum(u8) { whole, cut_if_wide, cut }`: rule 1, 2,
  and 3 above. It grows from 12 to 16 bytes; the comptime size assertion in
  `LayoutCapacity.arenaBytes` moves to 16. A cut line's `width` is its cut width, so the
  widest line, the text's box, and emit's culling read it unchanged.
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
3. **Wrapping (`wrapElementText`, `wrapLines`).** A `.none` `.ellipsis` text whose one-line
   width is above its cut width gets one line, `[0, len)`, marked `cut`; others keep
   `wrapped_lines = null`, as today. A wrapping text packs lines as today and marks each
   line wider than the cut width `cut_if_wide` when it is `.ellipsis`. With
   `line_count_max = N`, `LinePacker` stops when line N would end at a wrap and text
   follows: line N then runs to its paragraph's end, found by one scan for `'\n'`, and is
   marked `cut` (or kept as wrapped, with `.visible`); the scan of words stops with it. A
   line N that ends at a newline with text after it is marked `cut` as is. `measureWrapped`
   uses the same packer, so `cx.measureText` stops at the same line. `TextSizeKey.style`
   adds `line_count_max` and `overflow` to the bits it packs (bits 50 to 58).
4. **Heights (decision 27).** Unchanged: a clamped text that is not one line tall marks
   itself `min_height_dirty`, as any wrapped text does.
5. **Emit (`emitText`).** A line marked `whole` draws as today. A line marked
   `cut_if_wide` or `cut` goes to `text_render.placeTextCut`, which walks the line's
   shaping runs (`runLength`) through `shapeTextInto`, adding advances until the next
   cluster would pass the cut width less the ellipsis; trims trailing spaces and tabs; and
   returns the kept byte length and its width. A `cut_if_wide` line whose runs all fit is
   drawn whole. Emit then aligns the kept width plus the ellipsis, places the kept glyphs
   from the same runs (each run a shape-cache hit the second time), and places the ellipsis
   as a run of its own. A `.none` text's one cut line is drawn the same way.

The engine never builds a truncated string: the kept glyphs are a prefix of the shaped
line, so the drawn text keeps the line's own kerning and the arena holds no new bytes.

## Capacities

No new budget field. `WrappedLine`'s four new bytes grow the arena's line reservation and
the line scratch, each `glyph_count_frame_max` lines, both from fresh pages and resident
only as far as frames write lines:

| Profile    | `paint.glyph_count_frame_max` | Reserved now | Reserved after | Growth  |
| ---------- | ----------------------------: | -----------: | -------------: | ------: |
| `nano`     | 1,024                         | 24 KB        | 32 KB          | 8 KB    |
| `small`    | 4,096                         | 96 KB        | 128 KB         | 32 KB   |
| `standard` | 8,192                         | 192 KB       | 256 KB         | 64 KB   |
| `large`    | 65,236                        | 1.5 MB       | 2.0 MB         | 510 KB  |
| `ceiling`  | 65,536                        | 1.5 MB       | 2.0 MB         | 512 KB  |

A clamped text uses fewer lines than the same text unclamped, so frames that clamp long
texts write less of either reservation than they do today.

## Performance sketch

Per text, with no allocation:

- **Texts with neither field:** one branch in `LayoutEngine.text`, one in
  `wrapElementText`, and one per drawn line in `emitText` reading `end`. Target: within
  0.5 % instructions in the Cachegrind gate, as decision 28 held grids to.
- **Declaration of an `.ellipsis` text:** one measure of "…", a shape-cache hit after the
  first frame, instead of `widestWord`'s scan of every word. A long `.words` body declared
  with `.ellipsis` measures fewer words than today.
- **Clamped wrapping:** the batches of words up to and including the one in which line N
  ends, each at most `word_count_text_max` (1,024) words, then one byte scan of line N's
  paragraph. A 10,000-word body clamped to three lines measures one batch, 1,024 words,
  where it measures 10,000 today, and claims 3 lines where it claims about 250. The
  one-line measure in `LayoutEngine.text` still shapes the whole text once, as today.
- **A cut line in emit:** the runs up to the cut, walked twice: once to find the cut, once
  to place it, the second from the shape cache. A run is at most 512 bytes
  (`ShapedRunCache.MAX_TEXT_LEN`) or `run_codepoint_count_max` codepoints, so a cut line
  shapes at most the runs its cut width covers plus one, whatever its paragraph's length.
  It places no more glyphs than the uncut line, plus one for the ellipsis.
- **Worst case at `standard`:** every one of 8,192 lines cut, each two short runs: about
  16,400 cached run lookups and one ellipsis run each. Today's emit already shapes each of
  those lines once through the same cache, so a frame of cut lines costs about twice a
  frame of the same lines uncut, to be measured by a benchmark.

## Tests

- **Engine (`engine_tests.zig`, 10 px a character):** a `.none` `.ellipsis` text of 40
  characters in a 100 px column is one line marked `cut` of width 100, one line tall; at
  exactly 400 px it is `wrapped_lines = null`. A `.words` text of five lines clamped to 2
  is two lines, the second marked `cut` and running to the paragraph's end, two lines tall,
  and adds 2 to `wrapped_line_count`; clamped to 5 it is five `whole` lines; clamped to 4,
  four lines with the last `cut`. A clamped line that ends at a newline with a paragraph
  after it is `cut`. A word of 30 characters in a 100 px `.words` `.ellipsis` text is a
  `cut_if_wide` line between two `whole` ones. `.visible` with a clamp drops lines and
  marks none.
- **Floors:** a 500 px row of a 400 px `.ellipsis` text and a 300 px fixed box gives the
  text 200 px and cuts it; at 310 px the text is at its floor, the ellipsis's width; the
  same row without `.ellipsis` keeps the text at 400 px and overflows, as decision 26 does.
  Twelve equal `.grow` columns with one long `.ellipsis` text stay equal and the text is one
  line. A `.fit` box around the text floors at the ellipsis plus its padding.
- **Heights:** a card of a heading and a body clamped to 3 lines is three lines plus the
  heading tall at any body length; its stretched grid row follows it (decision 27).
- **Measure:** `cx.measureText` and layout agree on clamped and `.ellipsis` texts at three
  widths, and the text size cache keys them apart from the same text unclamped.
- **Emit (`core` tests with the synthetic backend, whose advances differ by character
  class):** a line whose shaped width equals the cut width draws whole and one class wider
  is cut; trailing spaces are trimmed before the ellipsis; "naïve café" cut inside "café"
  never splits "é"; a cut width narrower than the ellipsis draws nothing; `.right` puts the
  ellipsis's right edge within one advance of the box's; a single 3,000-byte word cut at
  200 px shapes only its first run. The ellipsis's glyph id is 0x2026, which the synthetic
  face shades apart from every ASCII glyph.
- **Fail-fast modes** in `src/testing/fail_fast_check.zig` for both panics, with their
  messages in `build.zig`.
- **Goldens:** `core_truncation.txt` replays a new `src/examples/text_truncation.zig`
  through the core: a sidebar of long channel names with badges, the grid example's table
  with an `.ellipsis` name column, and three cards with bodies clamped to 3 lines.
- **Fuzzing:** `fuzz.zig` gives random texts random clamps and overflow. Every frame checks
  that a text draws at most `line_count_max` lines, that every `cut` line's width is its
  cut width, and that its height is its drawn lines times the pitch.
- **Benchmarks:** `text_clamp` in `src/layout/benchmarks.zig` (300 cards, each a
  2,000-word body clamped to 3 lines) beside the same layout unclamped; an emit benchmark
  of 1,000 cut table cells; the Cachegrind gate on every existing layout benchmark.

## Later

- **Start and middle truncation.** `TextOverflow.ellipsis_start` and `.ellipsis_middle`,
  as GPUI's `TruncateStart` and `TruncateMiddle`, for file paths and file names. A start
  cut walks a line's runs from its end, so it lands with its own engine test, one line
  only, and no clamp.
- **Reporting a cut to the app.** A tooltip that shows a cut name in full needs to know
  that the name was cut, which only layout knows, after the build. See "Open questions" 5.
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
- **`.clip` as a third value.** A box with `clip = .clip` already cuts its children's
  pixels at its edge, and a text-level clip would spend a clip-stack entry per text.
- **Cutting in the minimum or sizing pass.** Widths are not final until wrapping, and a
  cut there would measure each text more than once, which decisions 27 and 28 avoid.

## Open questions

1. **Fields.** Proposed: `line_count_max: ?u8` and `overflow: TextOverflow`, independent,
   as GPUI's `line_clamp` and `text_overflow`. CSS's `line-clamp: N` and Tailwind's
   `line-clamp-N` imply the ellipsis, so a clamp alone would end in "…" there and in plain
   text here. Should `line_count_max` imply `.ellipsis`, with `.visible` meaning "clamp
   without ellipsis" only when set explicitly?
2. **Where the clamped line is cut.** Proposed: filled to the cut width and cut at a
   cluster, as GPUI, Flutter, UIKit, and Android do. CSS's `block-ellipsis` instead drops
   whole words back to the last wrap opportunity, which reads better in prose and wastes
   up to a word of width in a narrow cell. A `.words` text could follow CSS and a `.none`
   text keep the character cut.
3. **Floor of an `.ellipsis` text.** Proposed: the ellipsis's width. CSS's is 0 (a flex
   item with `overflow: hidden`), which lets a text vanish entirely; the one-line width
   would cut a text only when its parent is fixed narrower, so a row would push its badge
   out first. The proposal also lets a `.words` `.ellipsis` text without a clamp shrink
   below its widest word and cut that word, where today it would overflow.
4. **Trimming before the ellipsis.** Proposed: spaces and tabs, as CSS. GPUI also trims
   ASCII punctuation ("Hello, wor…" but "Hello…" at a comma), which also turns "3.5" into
   "3…".
5. **Telling the app a text was cut.** Proposed: not in this change. A later
   `cx.wasCut(id)`, read from the last frame as `cx.hovered` is, would let a cell show a
   tooltip only when its text is cut; until then a cell can always set the tooltip, as
   Zed's tabs do.
