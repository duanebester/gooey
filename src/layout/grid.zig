//! Grid layout (`docs/layout-grid.md`): a grid box places its children in
//! cells, row-major, sizes its columns once from all of them, and stacks its
//! rows, so every row shares the same column lines. A row box is a child that
//! spans a whole row and lays its own children on the grid's columns.
//!
//! The passes call in here at four points: the minimum pass places the cells
//! and takes each column's minimum (`measure`), the sizing pass resolves the
//! columns and sizes every cell's width (`sizeCells`), the heights pass sizes
//! the rows (`sizeRows`), and the position pass reads the columns' edges and
//! the rows' heights. Placement is stored in each child's `cell_column` and
//! `line_start`, so no later pass places a cell differently.
//!
//! Work per grid of C children and T columns, with no allocation: one
//! placement walk and two minimum walks over C, at most 2 × T² steps to
//! resolve the columns, one walk over C to size the cells, three to size the
//! rows, and one per row start while placing. Storage is one `GridSlot` per
//! grid, claimed from the engine's reservation of
//! `build.grid_count_frame_max` slots.

const std = @import("std");

const engine_mod = @import("engine.zig");
const sizing_pass = @import("sizing_pass.zig");
const types = @import("types.zig");

const LayoutEngine = engine_mod.LayoutEngine;
const LayoutElement = engine_mod.LayoutElement;
const Track = types.Track;
const SizingAxis = types.SizingAxis;
const track_count_max = types.grid_track_count_max;
const UNCONSTRAINED_MAX = engine_mod.UNCONSTRAINED_MAX;

/// One grid's tracks, copied when it opens, and its columns once resolved.
/// Every field is written before it is read in a frame; `claim` zeroes the
/// whole slot so no grid reads another's leftovers.
pub const GridSlot = struct {
    columns: [track_count_max]Track,
    rows: [track_count_max]Track,
    row_implicit: Track,
    row_gap: f32,
    column_count: u8,
    row_count: u8,
    /// Rows the placement made, set by `measure`.
    row_total: u32,
    /// Each column's content minimum and floor, from its cells.
    column_min: [track_count_max]f32,
    column_floor: [track_count_max]f32,
    /// Each column's left edge from the content box's left, and its width.
    column_left: [track_count_max]f32,
    column_width: [track_count_max]f32,
    /// The position pass's place in the grid: the row it places next, how
    /// the rows share the height, and the current row's alignment down it.
    /// Kept here rather than in every `PositionFrame`, so a box that is not
    /// a grid copies no grid state.
    position_row: u32,
    position_row_plan: RowPlan,
    position_row_alignment: types.TrackAlignment,

    /// Copy `config`'s tracks into this slot, zeroed first.
    pub fn claim(self: *GridSlot, config: *const types.GridConfig) void {
        std.debug.assert(config.columns.len > 0);
        std.debug.assert(config.columns.len <= track_count_max);
        std.debug.assert(config.rows.len <= track_count_max);
        std.debug.assert(config.row_gap >= 0);
        @memset(std.mem.asBytes(self), 0);
        @memcpy(self.columns[0..config.columns.len], config.columns);
        @memcpy(self.rows[0..config.rows.len], config.rows);
        self.row_implicit = config.row_implicit;
        self.row_gap = config.row_gap;
        self.column_count = @intCast(config.columns.len);
        self.row_count = @intCast(config.rows.len);
    }

    pub fn rowTrack(self: *const GridSlot, row: u32) Track {
        if (row < self.row_count) return self.rows[row];
        return self.row_implicit;
    }

    /// The width of `span` columns from `column`, with the gaps between them.
    pub fn cellWidth(self: *const GridSlot, column: u8, span: u8) f32 {
        std.debug.assert(span >= 1);
        std.debug.assert(@as(u32, column) + span <= self.column_count);
        const last = column + span - 1;
        const width = self.column_left[last] + self.column_width[last] - self.column_left[column];
        std.debug.assert(width >= 0);
        return width;
    }

    /// The columns' extent: the last column's right edge.
    pub fn columnsWidth(self: *const GridSlot) f32 {
        std.debug.assert(self.column_count > 0);
        const last = self.column_count - 1;
        return self.column_left[last] + self.column_width[last];
    }
};

/// The slot of grid box `grid`.
pub fn slotOf(engine: *const LayoutEngine, grid: *const LayoutElement) *GridSlot {
    std.debug.assert(grid.config.layout.grid == .grid);
    std.debug.assert(grid.grid_slot < engine.grid_count);
    return &engine.grid_slots[grid.grid_slot];
}

/// The grid whose columns `child` sits on: its parent, or its row box's.
pub fn gridOfCell(engine: *const LayoutEngine, child: *const LayoutElement) *const LayoutElement {
    const parent = engine.elements.getConst(child.parent_index.?);
    if (parent.config.layout.grid == .grid) return parent;
    std.debug.assert(parent.config.layout.grid == .row);
    const grid = engine.elements.getConst(parent.parent_index.?);
    std.debug.assert(grid.config.layout.grid == .grid);
    return grid;
}

/// The width of the cell `child` was placed in.
pub fn cellWidthOf(engine: *const LayoutEngine, child: *const LayoutElement) f32 {
    std.debug.assert(child.config.floating == null);
    const slot = slotOf(engine, gridOfCell(engine, child));
    return slot.cellWidth(child.cell_column, child.cell_span);
}

// Minimum pass.

pub const Minimums = struct { width: f32, floor: f32, height: f32 };

/// Place `grid_index`'s cells, then take its content minimums: its columns'
/// minimums and gaps across, and its rows' down. Runs once its children's
/// minimums are known, as `widestChildMin` runs for a wrapping row.
pub fn measure(engine: *LayoutEngine, grid_index: u32) Minimums {
    const grid = engine.elements.getConst(grid_index);
    const slot = slotOf(engine, grid);
    slot.row_total = placeCells(engine, grid_index);
    columnMinimums(engine, grid, slot);
    const gap: f32 = @floatFromInt(grid.config.layout.child_gap);
    const gap_total = gap * @as(f32, @floatFromInt(slot.column_count - 1));
    var width: f32 = gap_total;
    var floor: f32 = gap_total;
    var column: u8 = 0;
    while (column < slot.column_count) : (column += 1) {
        switch (slot.columns[column].axis.value) {
            .fixed => |mm| {
                width += mm.min;
                floor += mm.min;
            },
            .percent => {}, // Its width is a fraction of the grid's, not of its content.
            .fit, .grow => {
                width += slot.column_min[column];
                floor += slot.column_floor[column];
            },
        }
    }
    std.debug.assert(floor <= width);
    return .{ .width = width, .floor = floor, .height = rowsMinHeight(engine, grid) };
}

/// Place each flow child in declaration order, row-major, as CSS
/// `grid-auto-flow: row` without `dense`: a child takes the cursor's column
/// when it fits there, else starts the next row; a row box takes a row of
/// its own. Rows never hold a hole a later child fills, so visual, Tab and
/// accessibility order stay the declaration order. Returns the row count.
fn placeCells(engine: *LayoutEngine, grid_index: u32) u32 {
    const grid = engine.elements.getConst(grid_index);
    const column_count = slotOf(engine, grid).column_count;
    var column: u32 = 0;
    var row_open = false;
    var row_total: u32 = 0;
    var cursor = grid.first_child_index;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.get(index);
        cursor = child.next_sibling_index;
        if (child.config.floating != null) continue;
        if (child.config.layout.grid == .row) {
            child.line_start = true;
            child.cell_column = 0;
            child.cell_span = column_count;
            placeRowBoxCells(engine, child, column_count);
            row_total += 1;
            row_open = false;
            column = 0;
        } else {
            column = placeCell(child, column, row_open, column_count);
            if (child.line_start) row_total += 1;
            row_open = true;
        }
    }
    return row_total;
}

/// Place one cell at the cursor's `column` of the open row when it fits
/// there, else at the start of a new row. Returns the column after it.
fn placeCell(child: *LayoutElement, column: u32, row_open: bool, column_count: u8) u32 {
    const span: u32 = child.cell_span;
    std.debug.assert(span >= 1);
    std.debug.assert(span <= column_count);
    const requested = child.cell_column;
    const is_auto = requested == types.cell_column_auto;
    const start: u32 = if (is_auto) column else requested;
    const fits = start >= column and start + span <= column_count;
    if (row_open and fits) {
        child.line_start = false;
        child.cell_column = @intCast(start);
    } else {
        child.line_start = true;
        child.cell_column = if (is_auto) 0 else requested;
    }
    std.debug.assert(@as(u32, child.cell_column) + span <= column_count);
    return child.cell_column + span;
}

/// Place a row box's cells on one row of the grid's columns, with the same
/// rules; a cell that does not fit the row is a programming error.
fn placeRowBoxCells(engine: *LayoutEngine, row_box: *const LayoutElement, column_count: u8) void {
    std.debug.assert(row_box.config.layout.grid == .row);
    var column: u32 = 0;
    var cursor = row_box.first_child_index;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.get(index);
        cursor = child.next_sibling_index;
        if (child.config.floating != null) continue;
        const requested = child.cell_column;
        const start: u32 = if (requested == types.cell_column_auto) column else requested;
        const end = start + child.cell_span;
        if (start < column or end > column_count) {
            std.debug.panic("Cell.column {d} with span {d}: a row box holds one row of " ++
                "{d} columns, and its cells go left to right", .{
                start,
                child.cell_span,
                column_count,
            });
        }
        child.line_start = column == 0;
        child.cell_column = @intCast(start);
        column = end;
    }
}

/// Each column's minimum and floor: the widest of the cells that start in
/// it with a span of 1, clamped to the track, then widened by one walk over
/// the spanning cells, each giving what its columns lack to their `.fit`
/// columns, else their `.grow` ones. Fixed columns hold their size, and a
/// percent column has no content minimum.
fn columnMinimums(engine: *const LayoutEngine, grid: *const LayoutElement, slot: *GridSlot) void {
    const count = slot.column_count;
    @memset(slot.column_min[0..count], 0);
    @memset(slot.column_floor[0..count], 0);
    forEachCell(engine, grid, slot, addSingleColumn);
    var column: u8 = 0;
    while (column < count) : (column += 1) {
        const axis = slot.columns[column].axis;
        const fixed = axis.value == .fixed;
        const percent = axis.value == .percent;
        const content = if (percent) 0 else sizing_pass.applyMinMax(slot.column_min[column], axis);
        const floor = if (percent) 0 else sizing_pass.applyMinMax(slot.column_floor[column], axis);
        slot.column_min[column] = if (fixed) axis.getMin() else content;
        slot.column_floor[column] = if (fixed) axis.getMin() else @min(floor, content);
    }
    forEachCell(engine, grid, slot, widenSpanned);
    column = 0;
    while (column < count) : (column += 1) {
        std.debug.assert(slot.column_floor[column] <= slot.column_min[column]);
    }
}

/// Call `visit` with every cell of `grid`, a row box's cells included.
fn forEachCell(
    engine: *const LayoutEngine,
    grid: *const LayoutElement,
    slot: *GridSlot,
    comptime visit: fn (slot: *GridSlot, gap: f32, cell: *const LayoutElement) void,
) void {
    const gap: f32 = @floatFromInt(grid.config.layout.child_gap);
    var cursor = grid.first_child_index;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.getConst(index);
        cursor = child.next_sibling_index;
        if (child.config.floating != null) continue;
        if (child.config.layout.grid != .row) {
            visit(slot, gap, child);
            continue;
        }
        var inner = child.first_child_index;
        var inner_visited: u32 = 0;
        while (inner) |cell_index| : (inner_visited += 1) {
            std.debug.assert(inner_visited < engine.elements.len()); // Each sibling once.
            const cell = engine.elements.getConst(cell_index);
            inner = cell.next_sibling_index;
            if (cell.config.floating == null) visit(slot, gap, cell);
        }
    }
}

fn addSingleColumn(slot: *GridSlot, gap: f32, cell: *const LayoutElement) void {
    std.debug.assert(gap >= 0);
    std.debug.assert(cell.cell_column < slot.column_count);
    if (cell.cell_span != 1) return;
    const column = cell.cell_column;
    slot.column_min[column] = @max(slot.column_min[column], cell.computed.min_width);
    slot.column_floor[column] = @max(slot.column_floor[column], cell.computed.floor_width);
}

/// Give a spanning cell what its columns and the gaps between them lack:
/// equal parts to its `.fit` columns, or its `.grow` ones when it spans no
/// `.fit` column; fixed and percent columns keep their size.
fn widenSpanned(slot: *GridSlot, gap: f32, cell: *const LayoutElement) void {
    std.debug.assert(gap >= 0);
    if (cell.cell_span == 1) return;
    const first = cell.cell_column;
    const end = first + cell.cell_span;
    std.debug.assert(end <= slot.column_count);
    const gaps = gap * @as(f32, @floatFromInt(cell.cell_span - 1));
    var min_total: f32 = gaps;
    var floor_total: f32 = gaps;
    var fit_count: u32 = 0;
    var grow_count: u32 = 0;
    var column = first;
    while (column < end) : (column += 1) {
        min_total += slot.column_min[column];
        floor_total += slot.column_floor[column];
        switch (slot.columns[column].axis.value) {
            .fit => fit_count += 1,
            .grow => grow_count += 1,
            .fixed, .percent => {},
        }
    }
    const takes_fit = fit_count > 0;
    const taker_count = if (takes_fit) fit_count else grow_count;
    if (taker_count == 0) return; // Fixed and percent columns only: it overflows them.
    const takers: f32 = @floatFromInt(taker_count);
    const min_part = @max(0, cell.computed.min_width - min_total) / takers;
    const floor_part = @max(0, cell.computed.floor_width - floor_total) / takers;
    column = first;
    while (column < end) : (column += 1) {
        const kind = slot.columns[column].axis.value;
        if ((takes_fit and kind == .fit) or (!takes_fit and kind == .grow)) {
            slot.column_floor[column] += floor_part;
            const widened = slot.column_min[column] + min_part;
            slot.column_min[column] = @max(widened, slot.column_floor[column]);
        }
    }
}

/// The grid's rows at their minimums, `row_gap` apart: each row as tall as
/// its tallest child's minimum, clamped to its track, or its fixed size.
pub fn rowsMinHeight(engine: *const LayoutEngine, grid: *const LayoutElement) f32 {
    const slot = slotOf(engine, grid);
    const plan: RowPlan = .{ .per_weight = 0, .percent_basis = 0, .definite = false };
    var total: f32 = 0;
    var row: u32 = 0;
    var first = firstFlowChild(engine, grid);
    while (first) |row_first| : (row += 1) {
        std.debug.assert(row < slot.row_total); // Placement counted every row.
        const extent = rowExtent(engine, row_first, .minimum);
        total += trackHeight(slot.rowTrack(row), extent.tallest, plan);
        first = extent.end;
    }
    std.debug.assert(row == slot.row_total);
    if (row > 1) total += slot.row_gap * @as(f32, @floatFromInt(row - 1));
    return total;
}

// Sizing pass.

/// Resolve `grid_index`'s columns in `width`, its content width, then size
/// every cell's width: a row box takes the whole width, any other child its
/// cell's. Heights stay provisional, from one-line text, until the heights
/// pass sizes the rows (`sizeRows`): this marks the grid for it. Returns
/// whether any flow child has children.
pub fn sizeCells(engine: *LayoutEngine, parent_index: u32, width: f32, height: f32) bool {
    const parent = engine.elements.get(parent_index);
    std.debug.assert(parent.config.layout.grid != .none);
    std.debug.assert(height >= 0);
    if (parent.config.layout.grid == .grid) {
        const gap: f32 = @floatFromInt(parent.config.layout.child_gap);
        resolveColumns(slotOf(engine, parent), width, gap);
    }
    // The rows are sized once text has wrapped, as every height is.
    engine.heights_derived = true;
    parent.min_height_dirty = true;
    parent.heights_dirty = true;

    var has_grandchildren = false;
    var cursor = parent.first_child_index;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.get(index);
        cursor = child.next_sibling_index;
        if (child.config.floating != null) continue;
        const cell_width = if (child.config.layout.grid == .row)
            width
        else
            cellWidthOf(engine, child);
        sizeCell(child, cell_width, height);
        if (child.first_child_index != null) has_grandchildren = true;
    }
    return has_grandchildren;
}

/// One child's width in its cell, and a provisional height. `.fit` and
/// `.fixed` keep their width, cut to the cell when the columns shrank but
/// never below its floor; `.grow` fills the cell; `.percent` is a fraction
/// of it. A row box fills the grid's width.
fn sizeCell(child: *LayoutElement, cell_width: f32, height: f32) void {
    std.debug.assert(cell_width >= 0);
    const sizing = child.config.layout.sizing;
    const floor = child.computed.floor_width;
    const width = switch (sizing.width.value) {
        .fixed => |mm| mm.min,
        .grow => sizing_pass.applyMinMax(@max(floor, cell_width), sizing.width),
        .fit => @min(
            sizing_pass.computeAxisSize(sizing.width, child.computed.min_width, cell_width),
            @max(floor, cell_width),
        ),
        .percent => sizing_pass.computeAxisSize(sizing.width, 0, cell_width),
    };
    child.computed.sized_width = if (child.config.layout.grid == .row) cell_width else width;
    if (child.config.layout.aspect_ratio) |ratio| {
        child.computed.sized_height = child.computed.sized_width / ratio;
        child.min_height_dirty = true;
    } else {
        child.computed.sized_height = switch (sizing.height.value) {
            .grow => child.computed.min_height,
            else => sizing_pass.computeAxisSize(sizing.height, child.computed.min_height, height),
        };
    }
    std.debug.assert(child.computed.sized_width >= 0);
}

/// Resolve the columns' widths and left edges in `width`, as
/// `docs/layout-grid.md` "Column widths" orders them: fixed and percent
/// columns take their size, fit columns their minimum, grow columns share
/// the free width by weight from their floors up to their maximums, as CSS
/// `1fr` grows from min-content, so equal weights give equal columns, and
/// when the columns overflow, fit and grow columns shrink largest first,
/// none below its floor or its track's minimum.
fn resolveColumns(slot: *GridSlot, width: f32, gap: f32) void {
    std.debug.assert(width >= 0);
    std.debug.assert(gap >= 0);
    const count = slot.column_count;
    const unbounded = width >= UNCONSTRAINED_MAX; // A horizontal scroll grid.
    const gap_total = gap * @as(f32, @floatFromInt(count - 1));
    const basis = if (unbounded) 0 else @max(0, width - gap_total);
    var widths: [track_count_max]f32 = undefined;
    var others: f32 = 0;
    var column: u8 = 0;
    while (column < count) : (column += 1) {
        const axis = slot.columns[column].axis;
        widths[column] = switch (axis.value) {
            .percent => sizing_pass.computeAxisSize(axis, 0, basis),
            .grow => slot.column_floor[column],
            else => slot.column_min[column],
        };
        if (axis.value != .grow) others += widths[column];
    }
    if (!unbounded) growColumns(slot, &widths, basis - others);
    const target = if (unbounded) std.math.floatMax(f32) else basis;
    var total: f32 = 0;
    for (widths[0..count]) |column_width| total += column_width;
    if (total > target) shrinkColumns(slot, &widths, target);

    var left: f32 = 0;
    column = 0;
    while (column < count) : (column += 1) {
        slot.column_left[column] = left;
        slot.column_width[column] = widths[column];
        left += widths[column] + gap;
    }
}

/// Share `target` among the grow columns by weight, each between its
/// floor and its track's maximum, as CSS flexbox resolves flexible
/// lengths: size every unfrozen column at the common share per weight, then
/// freeze the columns its bounds moved, in the direction they moved most,
/// and repeat. Each round freezes a column, so at most T rounds of T steps.
fn growColumns(slot: *const GridSlot, widths: *[track_count_max]f32, target: f32) void {
    const count = slot.column_count;
    var frozen: [track_count_max]bool = @splat(false);
    var round: u32 = 0;
    while (round <= count) : (round += 1) {
        var remaining = target;
        var weight_total: f32 = 0;
        var column: u8 = 0;
        while (column < count) : (column += 1) {
            switch (slot.columns[column].axis.value) {
                .grow => |grow| {
                    if (frozen[column]) {
                        remaining -= widths[column];
                    } else {
                        weight_total += grow.weight;
                    }
                },
                else => {},
            }
        }
        if (weight_total == 0) return;
        const per_weight = @max(0, remaining) / weight_total;
        const violation = shareGrowth(slot, widths, &frozen, per_weight);
        if (violation == 0) return;
        freezeViolations(slot, widths, &frozen, per_weight, violation > 0);
    }
}

/// Size each unfrozen grow column at `per_weight` times its weight, within
/// its bounds; returns the bounds' total correction.
fn shareGrowth(
    slot: *const GridSlot,
    widths: *[track_count_max]f32,
    frozen: *const [track_count_max]bool,
    per_weight: f32,
) f32 {
    std.debug.assert(per_weight >= 0);
    var violation: f32 = 0;
    var column: u8 = 0;
    while (column < slot.column_count) : (column += 1) {
        if (frozen[column]) continue;
        const axis = slot.columns[column].axis;
        switch (axis.value) {
            .grow => |grow| {
                const share = per_weight * grow.weight;
                const bounded = @min(axis.getMax(), @max(slot.column_floor[column], share));
                widths[column] = bounded;
                violation += bounded - share;
            },
            else => {},
        }
    }
    return violation;
}

fn freezeViolations(
    slot: *const GridSlot,
    widths: *const [track_count_max]f32,
    frozen: *[track_count_max]bool,
    per_weight: f32,
    raised: bool,
) void {
    var frozen_count: u32 = 0;
    var column: u8 = 0;
    while (column < slot.column_count) : (column += 1) {
        if (frozen[column]) continue;
        switch (slot.columns[column].axis.value) {
            .grow => |grow| {
                const share = per_weight * grow.weight;
                const moved = if (raised) widths[column] > share else widths[column] < share;
                if (moved) {
                    frozen[column] = true;
                    frozen_count += 1;
                }
            },
            else => {},
        }
    }
    std.debug.assert(frozen_count > 0); // A nonzero correction moved a column.
}

/// Shrink the fit and grow columns to a common level, largest first, until
/// the columns fit `target`, none below its floor: `sizing_pass.shrinkLevel`
/// over columns. At most 2 × T rounds: each lowers the level to the next
/// width or floor below it.
fn shrinkColumns(slot: *const GridSlot, widths: *[track_count_max]f32, target: f32) void {
    std.debug.assert(target >= 0);
    const count = slot.column_count;
    var level: f32 = 0;
    for (widths[0..count]) |column_width| level = @max(level, column_width);
    var round: u32 = 0;
    while (round < 2 * @as(u32, count) + 1) : (round += 1) {
        var total: f32 = 0;
        var active_count: u32 = 0;
        var breakpoint: f32 = 0;
        var column: u8 = 0;
        while (column < count) : (column += 1) {
            if (!isShrinkable(slot, column)) {
                total += widths[column];
                continue;
            }
            const floor = slot.column_floor[column];
            total += @min(widths[column], @max(floor, level));
            if (widths[column] < level) {
                breakpoint = @max(breakpoint, widths[column]);
            } else if (floor < level) {
                active_count += 1;
                breakpoint = @max(breakpoint, floor);
            }
        }
        const excess = total - target;
        if (excess <= 0 or active_count == 0) break;
        const next = level - excess / @as(f32, @floatFromInt(active_count));
        if (next >= breakpoint) {
            level = next;
            break;
        }
        level = breakpoint;
    }
    var column: u8 = 0;
    while (column < count) : (column += 1) {
        if (isShrinkable(slot, column)) {
            widths[column] = @min(widths[column], @max(slot.column_floor[column], level));
        }
    }
}

fn isShrinkable(slot: *const GridSlot, column: u8) bool {
    std.debug.assert(column < slot.column_count);
    return switch (slot.columns[column].axis.value) {
        .fit, .grow => true,
        .fixed, .percent => false,
    };
}

// Heights pass and position pass.

/// How a grid's rows share its height: grow rows take `per_weight` times
/// their weight, percent rows a fraction of `percent_basis`, both only when
/// the grid's height is `definite`; otherwise they size as `.fit`.
pub const RowPlan = struct { per_weight: f32, percent_basis: f32, definite: bool };

pub fn rowPlan(engine: *const LayoutEngine, grid: *const LayoutElement, height: f32) RowPlan {
    const slot = slotOf(engine, grid);
    const definite = grid.config.layout.sizing.height.value != .fit and height < UNCONSTRAINED_MAX;
    const gaps = if (slot.row_total > 1)
        slot.row_gap * @as(f32, @floatFromInt(slot.row_total - 1))
    else
        0;
    var plan: RowPlan = .{
        .per_weight = 0,
        .percent_basis = @max(0, height - gaps),
        .definite = definite,
    };
    if (!definite) return plan;
    var others: f32 = 0;
    var weight_total: f32 = 0;
    var row: u32 = 0;
    var first = firstFlowChild(engine, grid);
    while (first) |row_first| : (row += 1) {
        std.debug.assert(row < slot.row_total);
        const extent = rowExtent(engine, row_first, .natural);
        const track = slot.rowTrack(row);
        switch (track.axis.value) {
            .grow => |grow| weight_total += grow.weight,
            else => others += trackHeight(track, extent.tallest, plan),
        }
        first = extent.end;
    }
    if (weight_total > 0) plan.per_weight = @max(0, plan.percent_basis - others) / weight_total;
    std.debug.assert(plan.per_weight >= 0);
    return plan;
}

/// Size `grid_index`'s rows in `height`, its content height, once text has
/// wrapped, and each cell's height in its row. Three walks over the cells:
/// the plan's, then each row's extent and its heights.
pub fn sizeRows(engine: *LayoutEngine, grid_index: u32, height: f32) void {
    std.debug.assert(height >= 0);
    const grid = engine.elements.getConst(grid_index);
    const slot = slotOf(engine, grid);
    const plan = rowPlan(engine, grid, height);
    var row: u32 = 0;
    var first = firstFlowChild(engine, grid);
    while (first) |row_first| : (row += 1) {
        std.debug.assert(row < slot.row_total);
        const extent = rowExtent(engine, row_first, .natural);
        const row_height = trackHeight(slot.rowTrack(row), extent.tallest, plan);
        var cursor: ?u32 = row_first;
        var visited: u32 = 0;
        while (cursor) |index| : (visited += 1) {
            std.debug.assert(visited < engine.elements.len()); // Each sibling once.
            if (extent.end) |end| if (index == end) break;
            const child = engine.elements.get(index);
            cursor = child.next_sibling_index;
            if (child.config.floating == null) {
                sizing_pass.setHeight(child, heightInRow(child, row_height));
            }
        }
        first = extent.end;
    }
    std.debug.assert(row == slot.row_total);
}

/// One row's height from its track and its tallest child.
pub fn trackHeight(track: Track, tallest: f32, plan: RowPlan) f32 {
    std.debug.assert(tallest >= 0);
    const axis = track.axis;
    return switch (axis.value) {
        .fixed => |mm| mm.min,
        .fit => sizing_pass.applyMinMax(tallest, axis),
        .percent => |p| if (plan.definite)
            sizing_pass.applyMinMax(plan.percent_basis * p.value, axis)
        else
            sizing_pass.applyMinMax(tallest, axis),
        .grow => |grow| if (plan.definite)
            sizing_pass.applyMinMax(@max(tallest, plan.per_weight * grow.weight), axis)
        else
            sizing_pass.applyMinMax(tallest, axis),
    };
}

pub const RowExtent = struct { end: ?u32, tallest: f32 };

/// Which height a row measures its children by: their minimums, before
/// rows are sized, or the height each takes before stretching.
pub const RowMeasure = enum { minimum, natural };

/// The row starting at `first`: its tallest child and the next row's first
/// child, or null for the last row.
pub fn rowExtent(
    engine: *const LayoutEngine,
    first: u32,
    comptime measure_by: RowMeasure,
) RowExtent {
    std.debug.assert(engine.elements.getConst(first).line_start);
    var tallest: f32 = 0;
    var cursor: ?u32 = first;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.getConst(index);
        if (child.config.floating == null) {
            if (child.line_start and index != first) return .{ .end = index, .tallest = tallest };
            const height = switch (measure_by) {
                .minimum => child.computed.min_height,
                .natural => naturalHeight(child),
            };
            tallest = @max(tallest, height);
        }
        cursor = child.next_sibling_index;
    }
    return .{ .end = null, .tallest = tallest };
}

/// A cell's height before its row stretches it: its aspect height, its
/// fixed size, or its minimum; a grow or percent height follows its row.
pub fn naturalHeight(child: *const LayoutElement) f32 {
    std.debug.assert(child.config.floating == null);
    if (child.config.layout.aspect_ratio) |ratio| return child.computed.sized_width / ratio;
    const axis = child.config.layout.sizing.height;
    return switch (axis.value) {
        .fixed => |mm| mm.min,
        .fit => sizing_pass.computeAxisSize(axis, child.computed.min_height, 0),
        .grow, .percent => child.computed.min_height,
    };
}

/// A cell's height in a row of `row_height`: a grow height fills the row,
/// as CSS grid stretches its items, a percent height is a fraction of it,
/// and a row box is the row.
pub fn heightInRow(child: *const LayoutElement, row_height: f32) f32 {
    std.debug.assert(row_height >= 0);
    if (child.config.layout.grid == .row) return row_height;
    const axis = child.config.layout.sizing.height;
    if (child.config.layout.aspect_ratio != null) return naturalHeight(child);
    return switch (axis.value) {
        .grow => sizing_pass.applyMinMax(row_height, axis),
        .percent => sizing_pass.computeAxisSize(axis, 0, row_height),
        .fit, .fixed => naturalHeight(child),
    };
}

pub fn firstFlowChild(engine: *const LayoutEngine, parent: *const LayoutElement) ?u32 {
    var cursor = parent.first_child_index;
    var visited: u32 = 0;
    while (cursor) |index| : (visited += 1) {
        std.debug.assert(visited < engine.elements.len()); // Each sibling once.
        const child = engine.elements.getConst(index);
        if (child.config.floating == null) return index;
        cursor = child.next_sibling_index;
    }
    return null;
}

/// Where the row holding flow child `target` starts below the content top,
/// and how tall it is; with `target` null, the height of all rows.
pub fn rowSpan(
    engine: *const LayoutEngine,
    grid: *const LayoutElement,
    plan: RowPlan,
    target: ?u32,
) sizing_pass.LineSpan {
    const slot = slotOf(engine, grid);
    var top: f32 = 0;
    var row: u32 = 0;
    var first = firstFlowChild(engine, grid);
    while (first) |row_first| : (row += 1) {
        std.debug.assert(row < slot.row_total);
        const extent = rowExtent(engine, row_first, .natural);
        const height = trackHeight(slot.rowTrack(row), extent.tallest, plan);
        if (target) |target_index| {
            if (target_index >= row_first and (extent.end == null or target_index < extent.end.?)) {
                return .{ .start = top, .size = height };
            }
        }
        top += height;
        if (extent.end != null) top += slot.row_gap;
        first = extent.end;
    }
    std.debug.assert(target == null);
    return .{ .start = 0, .size = top };
}
