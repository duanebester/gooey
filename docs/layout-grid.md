# Grid layout

## Status

Proposed on 2026-11-21 against v0.6.7 and approved on 2026-11-22, with the answers under
"Resolved questions"; not implemented. It builds on decision 27, which sizes heights after
text wraps. When it lands it becomes decision 28 in `docs/core-contract.md`, `ui.Style` in
§1 gains the fields below, and `src/layout/layout.md` documents the engine side. Until then
nothing here is API.

## Why

Rows, columns, weighted grow, and wrapping rows (decision 24) lay out one axis at a time.
None of them lines children up on both axes:

- **Forms.** A label column as wide as its widest label, beside fields that fill the rest.
  Today each row guesses a fixed label width or the labels do not line up.
- **Tables.** `examples/data_table_example.zig` gives every cell a fixed width so the
  header and the rows agree. A column cannot fit its content, and a right-aligned number
  column needs a wrapper box per cell.
- **Dashboards.** Cards on a 12-column grid that span 3, 4, or 6 columns, with every card's
  edges on the same lines.

A grid sizes its columns once from all its children, then places every child in a cell,
so every row shares the same column lines.

## Prior art

The engine is Clay-shaped (`src/layout/`), so the grid keeps Clay's model of sizing and
borrows the parts of CSS grid and other toolkits that tables and forms need.

- **Clay (`clay.h`).** Every sizing axis has a `min` and a `max`. Percent is of the
  parent's size less its padding and child gaps. Overflow shrinks the largest children
  first, down to their content minimum; free space grows the smallest grow children first,
  up to their `max`. Clay has no grid. Taken: track `min` and `max`, percent less gaps,
  largest-first shrink, and grow as smallest-first leveling, scaled by weight.
- **CSS grid.** Tracks with `minmax`, `fr`, and `min-content`; row-major auto placement;
  spanning children; items stretched by default. Taken: the track kinds, sparse row-major
  placement, spans, and stretch.
- **GPUI on Taffy.** `.grid()` and `grid_cols(n)`, which is `n` equal `minmax(0, 1fr)`
  tracks, with `_min_content` and `_max_content` variants; `col_span`, `col_start`, and
  `row_span`; separate `gap_x` and `gap_y`. Taffy implements CSS's full track sizing.
  Taken: the separate row gap; "Open questions" compares the rest.
- **Zed's `ui::Table`, on GPUI.** Not a grid: each row is an `h_flex` box with a hover
  background, and columns are explicit widths or equal shares, kept in retained state when
  resizable. Taken: row boxes, so a table row stays one keyed, hoverable box; resizable
  columns stay app state that feeds `.fixed` tracks.
- **SwiftUI `Grid`.** `GridRow` children, columns as wide as their widest cell,
  `gridColumnAlignment` per column, and `gridCellColumns` spans. Taken: row boxes and
  per-track cell alignment.
- **Flutter `Table`.** Per-column `FixedColumnWidth`, `FlexColumnWidth`,
  `IntrinsicColumnWidth`, and `FractionColumnWidth`, with `Min` and `Max` combinators.
  Confirms a closed set of track kinds with a min and a max each.
- **Dear ImGui tables and egui `Grid`.** Immediate mode: widths from the previous frame,
  sizing policies per column, and user resizing. Not taken: Gooey's passes size in the
  same frame.

## API

```zig
pub const Style = struct {
    // ... every field in §1, unchanged ...
    grid: ?Grid = null,   // this box lays its children out on a grid (decision 28)
    cell: Cell = .{},     // where this box sits in its parent's grid (decision 28)
};

pub const Grid = struct {
    columns: []const Track,                  // 1 to `grid_track_count_max`
    rows: []const Track = &.{},              // the first rows; at most `grid_track_count_max`
    row_implicit: Track = .fit,              // every row past `rows`
    row_gap: ?f32 = null,                    // null: `Style.gap`; columns are `Style.gap` apart
};

/// One column or row. `sizing` means what the same `Sizing` means for a child:
/// `.fixed` pixels, `.fit` content, `.grow` a weighted share of free space, and
/// `.percent` a fraction of the grid's content size less its gaps.
pub const Track = struct {
    sizing: Sizing = .fit,
    min: f32 = 0,
    max: f32 = std.math.floatMax(f32),
    /// Where a child that does not fill its cell sits: along a column, or down a row.
    /// null: the grid's `alignment` (`main` for columns, `cross` for rows).
    cell_alignment: ?Alignment.Cross = null,

    pub const fit: Track = .{};
    pub fn fixed(size: f32) Track;
    pub fn grow(weight: f32) Track;
    pub fn percent(fraction: f32) Track;
};

pub const Cell = struct {
    column: ?u8 = null,                      // the first column, from 0; null: the next free
    column_span: u8 = 1,                     // 1 to the grid's column count
    row: bool = false,                       // a row box: see "Row boxes"
};

pub const grid_track_count_max: u8 = 32;
```

A form, a table with a header and keyed rows, and a dashboard:

```zig
const form: ui.Style = .{
    .grid = .{ .columns = &.{ .fit, .grow(1) }, .row_gap = 8 },
    .gap = 12,
    .alignment = .center_cross, // each label centred on its field's row
};

const table: ui.Style = .{
    .grid = .{ .columns = &.{
        .fit,
        .{ .sizing = .{ .grow = 2 }, .min = 160 },
        .grow(1),
        .{ .sizing = .{ .fixed = 96 }, .cell_alignment = .end }, // numbers right-aligned
    } },
    .gap = 8,
    .width = .{ .grow = 1 },
};
const table_row: ui.Style = .{ .cell = .{ .row = true }, .padding = .{ .top = 4, .bottom = 4 } };

const twelve_columns: [12]ui.Track = @splat(.grow(1));
const dashboard: ui.Style = .{ .grid = .{ .columns = &twelve_columns }, .gap = 16 };
const wide_card: ui.Style = .{ .cell = .{ .column_span = 6 }, .width = .{ .grow = 1 } };
```

Each table row is then `ui.box(.{ .key = ..., .style = if (hovered) row_hover else
table_row, .on_click = ..., .a11y = .{ .role = .row } }, cells)`, and its cells line up
with the header's.

The core copies `columns` and `rows` into storage the layout reserved when the box is
declared, so a slice need only live until `ui.box` returns (contract rule 6). A shared
`Style` constant points at comptime track arrays; a responsive layout may build its slice
on the stack. The track syntax above compiles on Zig 0.17.

## Semantics

### Placement

Children are placed in declaration order, row-major, as CSS `grid-auto-flow: row` without
`dense`. A cursor holds the current row and column, starting at row 0, column 0:

- A child with `column = null` takes the cursor's column when its `column_span` fits in the
  row; otherwise it starts the next row at column 0.
- A child with `column = k` takes column `k` of the cursor's row when `k` is at or after the
  cursor; otherwise it starts the next row at column `k`. The columns it skips stay empty.
- A row box starts a row of its own and the next child starts the row after it.
- The cursor then moves to the column after the child's span.

Rows never hold a hole that a later child fills, so the visual order, the Tab order, and
the accessibility order all stay the declaration order. Floating children (layers) take no
cell, as in every other box.

Placement depends only on spans and the column count, never on sizes, so it runs once per
frame and every later pass reads its result.

### Row boxes

A child with `cell.row = true` is a row box: one box that spans every column of one row and
lays its own children on the grid's columns, with the same placement rules. It is what a
table needs a row to be: a box with a key, a hover background, a click handler, and the
`.row` role, whose cells still share the grid's column lines. It is SwiftUI's `GridRow`;
CSS reaches the same result only with subgrid.

A row box's children size the grid's columns as direct children do. A row box takes the
grid's content width; its height is its tallest child plus its vertical padding. It has no
horizontal padding, so its cells sit exactly on the columns. A row box's children are
cells, not row boxes, and a row box has no `grid` or `wrap` of its own.

### Column widths

Each column's minimum is the widest content minimum of the children that start in it with
a span of 1, clamped to the track's `min` and `max`. A `.fixed` track's minimum is its size;
a `.percent` track's is its width.

1. **Fixed and percent.** A `.fixed` column takes its size. A `.percent` column takes its
   fraction of the content width less the gaps, as Clay sizes percent children, so columns
   of 25 % each fill a row of four exactly. Both are clamped to `min` and `max`.
2. **Fit.** A `.fit` column takes its minimum.
3. **Grow.** The free width is the content width less every other column and the gaps.
   Grow columns start at their minimums and the free width fills them smallest first, as
   Clay grows children, scaled by weight: a column of weight 2 rises twice as fast. A
   column stops at its `max`. When the free width runs out, every grow column that rose is
   at the same width per weight. With equal weights this is CSS `1fr` (`minmax(auto,
   1fr)`), and a grow column never ends below its content, which a grow child in a row can
   (decision 24).
4. **Overflow.** When the columns' minimums and the gaps are wider than the content width,
   `.fit` and `.grow` columns shrink largest first, as Clay shrinks children: the widest
   gives way until it reaches the next widest, then both, and so on, never below a track's
   `min`. A long description column gives way before an icon or a number column does.
   `.fixed` and `.percent` columns never shrink, and what is left overflows.

Steps 3 and 4 each run at most two rounds per column (a round either brings the moving
columns level with the next or stops one at its bound), so at most `2 × T²` steps for `T`
columns.

A spanning child does not change step 1's minimums. After them, one walk over the spanning
children in declaration order checks each against the columns it spans: when its minimum
is wider than those columns and their gaps, the excess goes to the spanned `.fit` columns
equally, or to the spanned `.grow` columns when there are none, and never to `.fixed` or
`.percent` columns. A header cell spanning two columns therefore keeps its text whole.

### Row heights

Row `i` is sized by `rows[i]`, or by `row_implicit` past the end of `rows`, by the same
rules on the vertical axis:

- `.fit`: the tallest child in the row, clamped to the track's `min` and `max`.
- `.fixed`: its size; taller children overflow it.
- `.percent`: the fraction of the grid's content height less the row gaps when the grid's
  height is not `.fit`; otherwise as `.fit`.
- `.grow = w`: its weighted share of the free height, at least its tallest child, when the
  grid's height is not `.fit`; otherwise as `.fit`.

Row heights are taken after text wraps, as a wrapping row's lines are, so a cell whose text
wraps to more lines makes its row, and a `.fit`-height grid, taller.

### Children in cells

A cell is the area of the columns a child spans, in its row. Inside it a child sizes as it
would in a box of that size: `.fit` and `.fixed` keep their width, `.grow` fills the cell's
width whatever its weight, `.percent` is a fraction of the cell's width, and an
`aspect_ratio` derives its height from that width. A child whose height is `.grow` fills
its row's height, as CSS grid stretches its items by default. A text child wraps at its
cell's width.

A child that does not fill its cell is placed by its column's `cell_alignment` across and
its row's `cell_alignment` down, each defaulting to the grid's `alignment.main` and
`alignment.cross`. A grid ignores `Style.direction`, as Taffy ignores `flex-direction` in a
grid.

### The grid's own size

A `.fit`-width grid is as wide as its column minimums plus the gaps, where a `.grow`
column's minimum is its content minimum and a `.percent` column's is 0. A `.fit`-height
grid is as tall as its rows plus the row gaps. Padding, `width_min`, `width_max`, and their
height counterparts apply as on any box.

### With other fields

- **`wrap`**: a grid does not also wrap; setting both panics.
- **`scroll`**: a grid scrolls like any box. `Scroll.anchor = .end` and `effects.scrollTo`
  find a child's row and column, as they find a wrapping row's line.
- **Nested grids**: a cell may hold a grid with columns of its own. Only a row box shares
  its parent's column lines.
- **`aspect_ratio` on the grid**: allowed. The grid's height follows its width, so its
  height is definite and `.grow` rows share it.

## Validation

Each misuse panics at declaration, naming the box's `source` when it is set:

- `columns` empty or longer than `grid_track_count_max`: "Grid.columns: {d} columns; a
  grid has 1 to 32".
- `rows` longer than `grid_track_count_max`: "Grid.rows: {d} rows; a grid lists at most
  32".
- A track whose `min` is above its `max`, or either is negative or NaN: "Grid track {d}:
  min {d} and max {d} must satisfy 0 <= min <= max".
- `grid` with `wrap`: "Style.grid: a grid box does not also wrap".
- `column_span` 0 or wider than the grid: "Cell.column_span {d}: the grid has {d}
  columns".
- `column + column_span` past the last column: "Cell.column {d} with span {d}: the grid
  has {d} columns".
- `cell` set on a box whose parent is neither a grid nor a row box: "Style.cell: only a
  child of a grid box sits in a cell".
- A row box with `column`, `column_span`, `grid`, `wrap`, or horizontal padding, or inside
  another row box: "Cell.row: a row box spans every column and holds only cells".
- `alignment.main` set to a `space_*` value on a grid: "Style.alignment.main .{s}: a grid
  places a child in its cell with start, center, or end".
- More grids in a frame than the budget: the capacity failure under "Storage".

Track sizes are checked as `Sizing` already is: a grow weight must be finite and greater
than 0, a fixed size at least 0, and a percent between 0 and 1.

## Engine design

### Storage

- `LayoutConfig.grid: ?u16` indexes a per-frame `GridSlot`; `null` is every box today.
  `LayoutConfig.cell` holds the child's `column`, `column_span`, and `row` in three bytes.
- `GridSlot` holds the copied tracks (`[grid_track_count_max]Track` for columns and for the
  listed rows, 20 bytes each), the counts, `row_implicit`, the row gap, the placement
  cursor, each column's minimum, and each column's resolved left edge
  (`[grid_track_count_max + 1]f32`). About 1.6 KB.
- The slots are one reservation of `build.grid_count_frame_max`, claimed in declaration
  order and reset by `beginFrame`. Exhaustion fails fast as every pool does: `layout grids:
  capacity {d} (ResourceLimits.build.grid_count_frame_max), requested {d}, frame {d}`.
- `LayoutElement` gains `grid_column: u8`. It fits in the padding after the heights pass's
  two flags (offset 404 of the 408-byte element on x86_64, measured), so the element does
  not grow. A child's row start reuses `line_start`, as a wrapping row's lines do.

### Passes

1. **Declaration (core).** `cx.declaration` validates the grid, claims a slot, and copies
   the tracks. A child with a `cell` checks its open parent is a grid or a row box.
2. **Minimums (`computeMinSizes`).** When a grid finishes, as `widestChildMin` runs when a
   wrapping row finishes, one walk over its children, and over a row box's children one
   level down, places them (sets `line_start` and `grid_column`), records each column's
   minimum, applies the spanning children, and sums the rows' minimums. Boxes that are not
   grids pay one branch per parent, not per child.
3. **Final sizes (`planChildSizes`).** A grid resolves its column edges into its slot, then
   sizes every child in its cell, then takes each row's height and stretches the row's
   `.grow`-height children to it: three walks over its children, rule `.assigned`, as
   `sizeWrappedChildren` does. A row box plans its children the same way against its
   parent's slot. A `.fit`-height grid takes its rows' height. These heights are from
   one-line text, as every height in this pass is.
4. **Text wrapping and heights (decision 27).** `textContainerWidth` returns the cell's
   width for a child of a grid or a row box. A grid marks itself `min_height_dirty`, as a
   wrapping row does, so the heights pass runs: `childrenMinHeight` sums a grid's rows, each
   its tallest cell's minimum, and `sizeChildHeights` sizes each row from the wrapped text,
   stretches its `.grow`-height cells to it, and shares a definite height among `.grow`
   and `.percent` rows. A cell's stretched height is therefore never short.
5. **Positions (`placeSiblings`).** A comptime `grid` variant beside `wrap` starts a row at
   each `line_start` child: one walk over the row takes its height, then each child goes to
   its column's left edge, aligned in its cell. A row box places its children at its
   parent's column edges. `resolveScrollTarget` reads a child's row span the way it reads
   `wrapLineSpan`.

The engine's `wrap: bool` becomes `flow: enum { line, wrap, grid, grid_row }`, so the
passes switch once per parent instead of testing flags. `ui.Style` keeps `wrap: bool`.

## Capacities

| Profile    | `build.grid_count_frame_max` | Reserved |
| ---------- | ---------------------------: | -------: |
| `nano`     | 8                            | 13 KB    |
| `small`    | 32                           | 51 KB    |
| `standard` | 128                          | 203 KB   |
| `large`    | 512                          | 811 KB   |
| `ceiling`  | 1,024                        | 1.6 MB   |

`grid_count_frame_max` must be at most `element_count_frame_max`, checked at comptime with
the other build relationships. The reservation comes from fresh pages, so only the slots a
frame claims become resident, and `deinit` zeroes up to the high-water mark (rule 21).
`grid_track_count_max` is a framework constant like `box_depth_ceiling`, not a budget field:
it sizes `GridSlot`, and no layout needs more than 32 columns.

## Performance sketch

Per grid of `C` children and `T` columns, with no allocation:

- **Visits per child:** one in the minimum pass, three while sizing, two while placing:
  six, against four for a child of a row. Spanning children get one more. Each visit reads
  the child and its slot, which stay in cache across one grid.
- **Track resolution:** at most `2 × T²` steps per axis, 2,048 at 32 columns and 288 at 12,
  once per frame per grid. Rows resolve the same way only in a grid of definite height
  with `.grow` rows; other rows are one pass.
- **Worst case at `standard`:** 4,096 elements, all cells: about 24,600 child visits and
  128 resolutions, about 260,000 steps at 32 columns. Layout measured 38 to 70 ns per node
  on 0.3.1; the estimate for an all-grid frame is under 0.5 ms, to be measured.
- **Layouts with no grid:** one branch per parent in each pass, folded into the existing
  `wrap` test by the `flow` enum. Target: within 0.5 % instructions in the Cachegrind gate.

Taffy's full CSS algorithm measures items several times per frame and may size the columns
twice; this design measures each text once, as the engine does now.

## Tests

- **Engine (`engine_tests.zig`):** placement with spans and explicit columns, including a
  span exactly as wide as the grid, one column too many (panic), and a `column` before the
  cursor starting a new row; `.fit` columns lining up across rows of different contents;
  grow columns with weights 1 and 3 where the weight-3 column's content minimum is above
  its share; overflow where columns of 300, 100, and 40 px minimums must lose 120 px (the
  300 px column gives it all; a proportional shrink would cut all three); four `.percent`
  columns of 0.25 with a gap filling the row exactly; track `min` and `max` on every kind;
  a spanning header wider than its two `.fit` columns; `.grow` and `.percent` rows in a
  fixed-height grid and the same rows falling back to `.fit` in a `.fit`-height grid; a
  wrapped text cell raising its row and its grid; an aspect child in a spanning cell; a
  nested grid; a floating child taking no cell; a grid with only floating children.
- **Row boxes:** a header of plain cells and row boxes below share column edges; a row
  box's widest cell widens the column for the header; per-column `cell_alignment = .end`.
- **Capacity:** declare exactly `grid_count_frame_max` grids, check the last lays out,
  declare one more, and check the failure names the pool, capacity, request, and frame.
- **Fail-fast modes** in `src/testing/fail_fast_check.zig` for each panic in "Validation",
  with their messages in `build.zig`.
- **Goldens:** a `GridApp` through the core: a form and a table with hovered row boxes, at
  two widths.
- **Fuzzing:** `fuzz.zig` generates grids and row boxes. Every frame checks that cells in
  one row do not overlap, every child stays inside its columns' edges unless its width is
  fixed, rows start at increasing heights, and slots are zero past the high-water mark
  after `deinit`.
- **Benchmarks:** `grid_table` (300 row boxes of 6 cells) and `grid_cards` (nested grids)
  in `src/layout/benchmarks.zig`; the Cachegrind gate on every existing layout benchmark.
- **Example:** `data_table_example.zig` lays out its header and its rows on one grid, with
  `.fit` columns where it uses fixed widths today.

## Later

- **Auto-fill columns.** `Grid.column_width_min: ?f32`: as many equal `.grow` columns as
  fit at least that wide, as CSS `repeat(auto-fill, minmax(w, 1fr))` and Compose's
  `GridCells.Adaptive`. Placement then waits for the grid's width, so it moves from the
  minimum pass to the sizing pass.
- **Row spans and explicit rows.** Row-major placement with row spans needs, per column,
  the row it is occupied until: storage bounded by the column count, not the row count.
- **`components.Table`.** A header and a `List` of row boxes on one grid, with resizable
  columns kept in retained state as Zed's table keeps them, feeding `.fixed` tracks. A
  virtualized table sizes `.fit` columns from the visible rows only, so it should use
  `.fixed` and `.grow` columns to keep widths steady while scrolling.

## Rejected

- **All of CSS grid.** Template-area strings, named lines, `dense` packing, and subgrid each
  add parsing, storage, or out-of-order placement that no Gooey caller needs. Row boxes
  cover the subgrid case tables have.
- **GPUI's equal-track-only API.** `grid_cols(n)` covers dashboards, but not forms or
  tables, which need `.fit` columns beside `.grow` ones.
- **Previous-frame column widths** (egui, Dear ImGui). They lag a frame on every change and
  need retained state per grid; Gooey's minimum pass knows the widths in the same frame.
- **Tracks stored inline in `Style`.** 32 tracks per axis would add over 1 KB to every
  `Style`. The slot table pays only for grids.
- **Equal widths on a wrapping row.** Cards of one width line up, but `.fit` columns and
  spans cannot, because a wrapping row never sees two lines at once.

## Resolved questions

Approved on 2026-11-22. Each states what GPUI does, from its source
(`crates/gpui/src/style.rs`, `styled.rs`, `taffy.rs`) and Taffy's.

1. **Row gap.** GPUI's `gap` has a width and a height (`gap_x`, `gap_y`), as CSS has
   `column-gap` and `row-gap`. Decided: `Grid.row_gap`, defaulting to `Style.gap`, as in
   the API above.
2. **`Style.direction`.** GPUI selects a grid with `display: grid`, and Taffy ignores
   `flex-direction` there. Decided: a grid ignores `direction` the same way; a
   `Direction.grid` beside `Style.grid` would set the mode twice. A grid that sets
   `direction` does not panic: `.row` is the default, so the core cannot tell it apart
   from an unset field.
3. **Spanning children.** Taffy runs CSS's algorithm: items batched by span, smallest span
   first, each batch's extra size spread over its tracks. Decided: the one walk in
   "Column widths", which keeps a spanning header's text whole at one extra visit per
   spanning child, without the batching. Overlapping spans may come out wider than CSS
   would make them.
4. **Stretch after wrapping.** Taffy measures every item at its column's width while it
   sizes the rows, then stretches items to the final row height (`align-items: stretch` is
   its grid default), so a stretched cell is never short. Gooey sized every height before
   text wrapped, so a stretched child in a row, wrapping or not, stayed one line tall, and
   a grow child in a fixed column took space its wrapped sibling then overflowed into.
   Decided: decision 27 sizes heights after text wraps, as Clay orders its passes, for
   every box; the grid's rows are sized in that pass and need no fix of their own.

## Related changes outside grids

Each lands separately from the grid, as its own change: decisions 25, 26, and 27 in the
core contract.

- **Percent less gaps.** A child's `.percent` becomes a fraction of its parent's content
  size less the gaps along the parent's direction, as Clay sizes it, so grid tracks and
  children mean the same thing by a percent.
- **Largest-first shrink.** A row or column that overflows shrinks its children largest
  first, as Clay does, down to their content minimum rather than below their text.
- **Heights after widths.** Every height is sized after text wraps at its final width, as
  Clay orders its passes, so the grid's row heights and stretched cells count every
  wrapped line.
