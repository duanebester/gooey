//! DataTable Example - Virtualized 2D Table with Sorting
//!
//! This example demonstrates how to use DataTable for efficient rendering
//! of large tabular datasets with column sorting. Only visible cells are
//! rendered, regardless of total row/column count.
//!
//! Run with: zig build run-data-table

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;

const Cx = gooey.Cx;
const Builder = gooey.Builder;
const Color = gooey.Color;
const DataTableState = gooey.DataTableState;
const SortDirection = gooey.SortDirection;
const Button = gooey.Button;

const ui = gooey.ui;

// =============================================================================
// Constants
// =============================================================================

const ROW_COUNT: u32 = 10_000;
const ROW_HEIGHT: f32 = 32.0;

/// Column indices
const COL_ID = 0;
const COL_NAME = 1;
const COL_STATUS = 2;
const COL_SIZE = 3;
const COL_MODIFIED = 4;

/// Column names
const COLUMN_NAMES = [_][]const u8{
    "ID",
    "Name",
    "Status",
    "Size",
    "Modified",
};

// =============================================================================
// Data Model
// =============================================================================

/// A single row of data
const RowData = struct {
    id: u32,
    name_idx: u8, // Index into NAMES array
    status_idx: u8, // Index into STATUSES array
    size_bytes: u64,
    modified_days_ago: u16,
};

/// Pre-defined names (to avoid per-row string allocation)
const NAMES = [_][]const u8{
    "document.pdf",
    "image.png",
    "data.json",
    "script.zig",
    "config.toml",
    "readme.md",
    "notes.txt",
    "backup.zip",
    "report.xlsx",
    "video.mp4",
};

/// Pre-defined statuses
const STATUSES = [_][]const u8{
    "Active",
    "Pending",
    "Archived",
};

/// Format size as human readable string
fn formatSize(buf: []u8, bytes: u64) []const u8 {
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
    } else if (bytes < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{kb}) catch "?";
    } else if (bytes < 1024 * 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch "?";
    } else {
        const gb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.2} GB", .{gb}) catch "?";
    }
}

/// Format modified time
fn formatModified(buf: []u8, days_ago: u16) []const u8 {
    if (days_ago == 0) {
        return "Today";
    } else if (days_ago == 1) {
        return "Yesterday";
    } else if (days_ago < 7) {
        return std.fmt.bufPrint(buf, "{d} days ago", .{days_ago}) catch "?";
    } else if (days_ago < 30) {
        const weeks = days_ago / 7;
        return std.fmt.bufPrint(buf, "{d} week{s} ago", .{ weeks, if (weeks > 1) "s" else "" }) catch "?";
    } else {
        const months = days_ago / 30;
        return std.fmt.bufPrint(buf, "{d} month{s} ago", .{ months, if (months > 1) "s" else "" }) catch "?";
    }
}

// =============================================================================
// Application Data (static allocation, runtime initialization)
// =============================================================================

/// All row data - initialized at runtime
var row_data: [ROW_COUNT]RowData = undefined;
var data_initialized: bool = false;

/// Initialize row data (called once at startup)
fn initRowData() void {
    if (data_initialized) return;

    var prng_state: u64 = 12345; // Seed for deterministic "random" data

    for (0..ROW_COUNT) |i| {
        // Simple LCG for pseudo-random values
        prng_state = prng_state *% 6364136223846793005 +% 1442695040888963407;
        const rand1 = prng_state >> 33;
        prng_state = prng_state *% 6364136223846793005 +% 1442695040888963407;
        const rand2 = prng_state >> 33;
        prng_state = prng_state *% 6364136223846793005 +% 1442695040888963407;
        const rand3 = prng_state >> 33;

        row_data[i] = .{
            .id = @intCast(i + 1),
            .name_idx = @intCast(rand1 % NAMES.len),
            .status_idx = @intCast(rand2 % STATUSES.len),
            .size_bytes = (rand1 % 10_000_000_000) + 100, // 100 B to 10 GB
            .modified_days_ago = @intCast(rand3 % 365),
        };
    }

    data_initialized = true;
}

// =============================================================================
// Sort Index (runtime - maps display row to data row)
// =============================================================================

var sort_indices: [ROW_COUNT]u32 = undefined;
var indices_initialized: bool = false;

fn initSortIndices() void {
    if (indices_initialized) return;

    for (0..ROW_COUNT) |i| {
        sort_indices[i] = @intCast(i);
    }

    indices_initialized = true;
}

/// Get the actual data row for a display row
fn getDataRow(display_row: u32) *const RowData {
    // Ensure data is initialized
    initRowData();
    initSortIndices();

    const data_idx = sort_indices[display_row];
    return &row_data[data_idx];
}

// =============================================================================
// Sorting Implementation
// =============================================================================

fn sortByColumn(col: u32, direction: SortDirection) void {
    // Ensure data is initialized before sorting
    initRowData();
    initSortIndices();

    if (direction == .none) {
        // Reset to original order
        for (0..ROW_COUNT) |i| {
            sort_indices[i] = @intCast(i);
        }
        return;
    }

    const is_ascending = direction == .ascending;

    // Use insertion sort for stability (and it's fast for nearly-sorted data)
    // For 10k rows this is acceptable; for larger datasets use a better algorithm
    switch (col) {
        COL_ID => sortWithCompare(is_ascending, struct {
            fn cmp(a_idx: u32, b_idx: u32) i32 {
                const a = row_data[a_idx].id;
                const b = row_data[b_idx].id;
                if (a < b) return -1;
                if (a > b) return 1;
                return 0;
            }
        }.cmp),
        COL_NAME => sortWithCompare(is_ascending, struct {
            fn cmp(a_idx: u32, b_idx: u32) i32 {
                const a = NAMES[row_data[a_idx].name_idx];
                const b = NAMES[row_data[b_idx].name_idx];
                return switch (std.mem.order(u8, a, b)) {
                    .lt => -1,
                    .gt => 1,
                    .eq => 0,
                };
            }
        }.cmp),
        COL_STATUS => sortWithCompare(is_ascending, struct {
            fn cmp(a_idx: u32, b_idx: u32) i32 {
                const a = row_data[a_idx].status_idx;
                const b = row_data[b_idx].status_idx;
                if (a < b) return -1;
                if (a > b) return 1;
                return 0;
            }
        }.cmp),
        COL_SIZE => sortWithCompare(is_ascending, struct {
            fn cmp(a_idx: u32, b_idx: u32) i32 {
                const a = row_data[a_idx].size_bytes;
                const b = row_data[b_idx].size_bytes;
                if (a < b) return -1;
                if (a > b) return 1;
                return 0;
            }
        }.cmp),
        COL_MODIFIED => sortWithCompare(is_ascending, struct {
            fn cmp(a_idx: u32, b_idx: u32) i32 {
                const a = row_data[a_idx].modified_days_ago;
                const b = row_data[b_idx].modified_days_ago;
                if (a < b) return -1;
                if (a > b) return 1;
                return 0;
            }
        }.cmp),
        else => {},
    }
}

fn sortWithCompare(ascending: bool, comptime cmpFn: fn (u32, u32) i32) void {
    // Heap sort for O(n log n) worst case
    const len = sort_indices.len;

    // Build max heap
    var i: usize = len / 2;
    while (i > 0) {
        i -= 1;
        siftDown(i, len, ascending, cmpFn);
    }

    // Extract elements
    var end: usize = len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(u32, &sort_indices[0], &sort_indices[end]);
        siftDown(0, end, ascending, cmpFn);
    }
}

fn siftDown(start: usize, end: usize, ascending: bool, comptime cmpFn: fn (u32, u32) i32) void {
    var root = start;
    while (true) {
        const left_child = 2 * root + 1;
        if (left_child >= end) break;

        var swap_idx = root;

        // Compare with left child
        const left_val = sort_indices[left_child];
        const cmp_left = cmpFn(left_val, sort_indices[swap_idx]);
        const should_swap_left = if (ascending) cmp_left > 0 else cmp_left < 0;
        if (should_swap_left) {
            swap_idx = left_child;
        }

        // Compare with right child
        const right_child = left_child + 1;
        if (right_child < end) {
            const right_val = sort_indices[right_child];
            const swap_current = sort_indices[swap_idx];
            const cmp_right = cmpFn(right_val, swap_current);
            const should_swap_right = if (ascending) cmp_right > 0 else cmp_right < 0;
            if (should_swap_right) {
                swap_idx = right_child;
            }
        }

        if (swap_idx == root) break;

        std.mem.swap(u32, &sort_indices[root], &sort_indices[swap_idx]);
        root = swap_idx;
    }
}

// =============================================================================
// Event Callbacks (module-level for function pointer compatibility)
// =============================================================================

fn onHeaderClick(col: u32) void {
    const dir = state.table_state.toggleSort(col);
    state.sort_col = if (dir != null and dir.? != .none) col else null;
    state.sort_dir = dir orelse .none;

    // Actually sort the data
    sortByColumn(col, state.sort_dir);

    // Clear selection since row indices no longer map to the same data
    state.table_state.clearSelection();
}

fn onRowClick(row: u32) void {
    state.table_state.selectRow(row);
}

// =============================================================================
// Application State
// =============================================================================

const State = struct {
    /// Retained state for the data table
    table_state: DataTableState = initTable(),

    /// Currently sorted column for display
    sort_col: ?u32 = null,
    sort_dir: SortDirection = .none,

    fn initTable() DataTableState {
        var table = DataTableState.init(ROW_COUNT, ROW_HEIGHT);

        // Add columns with varying widths
        _ = table.addColumn(.{ .width_px = 80, .sortable = true }) catch unreachable; // ID
        _ = table.addColumn(.{ .width_px = 200, .sortable = true }) catch unreachable; // Name
        _ = table.addColumn(.{ .width_px = 100, .sortable = true }) catch unreachable; // Status
        _ = table.addColumn(.{ .width_px = 120, .sortable = true }) catch unreachable; // Size
        _ = table.addColumn(.{ .width_px = 150, .sortable = true }) catch unreachable; // Modified

        return table;
    }

    // =========================================================================
    // Event Handlers
    // =========================================================================

    pub fn scrollToTop(self: *State) void {
        self.table_state.scrollToOrigin();
    }

    pub fn scrollToBottom(self: *State) void {
        self.table_state.scrollToRow(ROW_COUNT - 1, .end);
    }

    pub fn jumpToMiddle(self: *State) void {
        self.table_state.selectRow(5000);
        self.table_state.scrollToRow(5000, .center);
    }

    pub fn selectNext(self: *State) void {
        const current = self.table_state.selection.row orelse 0;
        if (current < self.table_state.row_count - 1) {
            self.table_state.selectRow(current + 1);
            self.table_state.scrollToRow(current + 1, .nearest);
        }
    }

    pub fn selectPrevious(self: *State) void {
        if (self.table_state.selection.row) |row| {
            if (row > 0) {
                self.table_state.selectRow(row - 1);
                self.table_state.scrollToRow(row - 1, .nearest);
            }
        } else {
            self.table_state.selectRow(0);
        }
    }

    pub fn clearSelection(self: *State) void {
        self.table_state.clearSelection();
    }
};

// =============================================================================
// Global State
// =============================================================================

var state = State{};

// =============================================================================
// Components
// =============================================================================

const Header = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const theme = cx.builder().theme();

        cx.hstack(.{ .gap = 8 }, .{
            ui.text("DataTable Demo", .{
                .size = 18,
                .weight = .bold,
                .color = theme.text,
            }),
            ui.spacer(),
            ui.text("10,000 rows × 5 columns - click headers to sort!", .{
                .size = 12,
                .color = theme.muted,
            }),
        });
    }
};

const StatsBar = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(State);
        const b = cx.builder();
        const theme = b.theme();
        const range = s.table_state.visibleRange();

        // Format stats
        var rows_buf: [64]u8 = undefined;
        const rows_text = std.fmt.bufPrint(&rows_buf, "Rows {d}-{d}", .{
            range.rows.start,
            range.rows.end,
        }) catch "?";

        var cells_buf: [32]u8 = undefined;
        const cells_text = std.fmt.bufPrint(&cells_buf, "Cells: {d}", .{
            range.cellCount(),
        }) catch "?";

        // Format sort state
        var sort_buf: [64]u8 = undefined;
        const sort_text: []const u8 = if (s.sort_col) |col|
            std.fmt.bufPrint(&sort_buf, "Sort: {s} {s}", .{
                if (col < COLUMN_NAMES.len) COLUMN_NAMES[col] else "???",
                switch (s.sort_dir) {
                    .ascending => "↑",
                    .descending => "↓",
                    .none => "",
                },
            }) catch "?"
        else
            "Sort: none";

        cx.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .background = theme.surface,
            .corner_radius = 4,
            .direction = .row,
            .gap = 16,
        }, .{
            ui.text(rows_text, .{ .size = 12, .color = theme.muted }),
            ui.text(cells_text, .{ .size = 12, .color = theme.muted }),
            ui.text(sort_text, .{ .size = 12, .color = if (s.sort_col != null) theme.primary else theme.muted }),
        });
    }
};

/// Context passed to cell/header renderers
const TableRenderContext = struct {
    selected_row: ?u32,
    theme: *const gooey.Theme,
    sort_col: ?u32,
    sort_dir: SortDirection,
};

const DataTable = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(State);
        var b = cx.builder();
        const theme = b.theme();

        const ctx = TableRenderContext{
            .selected_row = s.table_state.selection.row,
            .theme = theme,
            .sort_col = s.sort_col,
            .sort_dir = s.sort_dir,
        };

        b.dataTableWithContext(
            "main-table",
            &s.table_state,
            .{
                .fill_width = true,
                .grow_height = true,
                .background = theme.surface,
                .corner_radius = 8,
                .padding = .{ .all = 0 },
                .header_background = Color.rgba(0, 0, 0, 0.05),
                .row_alternate_background = Color.rgba(0, 0, 0, 0.02),
                .row_selected_background = theme.primary,
                .row_hover_background = theme.overlay,
                .on_header_click = onHeaderClick,
                .on_row_click = onRowClick,
            },
            ctx,
            renderCell,
            renderHeader,
        );
    }

    fn renderHeader(col: u32, ctx: TableRenderContext, b: *Builder) void {
        const theme = ctx.theme;
        const name = if (col < COLUMN_NAMES.len) COLUMN_NAMES[col] else "???";

        // Show sort indicator if this column is sorted
        var label_buf: [64]u8 = undefined;
        const label = if (ctx.sort_col != null and ctx.sort_col.? == col)
            switch (ctx.sort_dir) {
                .ascending => std.fmt.bufPrint(&label_buf, "{s} ▲", .{name}) catch name,
                .descending => std.fmt.bufPrint(&label_buf, "{s} ▼", .{name}) catch name,
                .none => name,
            }
        else
            name;

        b.box(.{
            .fill_width = true,
            .fill_height = true,
            .padding = .{ .symmetric = .{ .x = 8, .y = 0 } },
            .alignment = .{ .main = .center, .cross = .start },
        }, .{
            ui.text(label, .{
                .size = 13,
                .weight = .semibold,
                .color = theme.text,
            }),
        });
    }

    fn renderCell(display_row: u32, col: u32, ctx: TableRenderContext, b: *Builder) void {
        const theme = ctx.theme;
        const is_selected = if (ctx.selected_row) |sel| sel == display_row else false;
        const text_color = if (is_selected) Color.white else theme.text;

        // Get actual data row via sort index
        const data = getDataRow(display_row);

        // Format cell content based on column
        var buf: [64]u8 = undefined;
        const content: []const u8 = switch (col) {
            COL_ID => std.fmt.bufPrint(&buf, "{d}", .{data.id}) catch "?",
            COL_NAME => NAMES[data.name_idx],
            COL_STATUS => STATUSES[data.status_idx],
            COL_SIZE => formatSize(&buf, data.size_bytes),
            COL_MODIFIED => formatModified(&buf, data.modified_days_ago),
            else => "—",
        };

        b.box(.{
            .fill_width = true,
            .fill_height = true,
            .padding = .{ .symmetric = .{ .x = 8, .y = 0 } },
            .alignment = .{ .main = .center, .cross = .start },
        }, .{
            ui.text(content, .{
                .size = 13,
                .color = text_color,
            }),
        });
    }
};

const Controls = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.hstack(.{ .gap = 8 }, .{
            Button{
                .label = "Top",
                .on_click_handler = cx.update(State, State.scrollToTop),
            },
            Button{
                .label = "Bottom",
                .on_click_handler = cx.update(State, State.scrollToBottom),
            },
            Button{
                .label = "Jump to #5000",
                .on_click_handler = cx.update(State, State.jumpToMiddle),
            },
            ui.spacer(),
            Button{
                .label = "↑ Prev",
                .on_click_handler = cx.update(State, State.selectPrevious),
            },
            Button{
                .label = "↓ Next",
                .on_click_handler = cx.update(State, State.selectNext),
            },
            Button{
                .label = "Clear",
                .on_click_handler = cx.update(State, State.clearSelection),
            },
        });
    }
};

// =============================================================================
// Main Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();
    const theme = cx.builder().theme();

    cx.box(.{
        .width = size.width,
        .height = size.height,
        .background = theme.bg,
        .padding = .{ .all = 16 },
        .direction = .column,
        .gap = 12,
    }, .{
        Header{},
        StatsBar{},
        DataTable{},
        Controls{},
    });
}

// =============================================================================
// Entry Point
// =============================================================================

const App = gooey.App(State, &state, render, .{
    .title = "DataTable Example - 10,000 Rows",
    .width = 900,
    .height = 600,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}
