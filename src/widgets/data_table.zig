//! DataTable - Virtualized 2D table with uniform row height
//!
//! Renders only visible cells for O(1) layout regardless of total rows/columns.
//! Built on UniformListState concepts with added horizontal virtualization.
//!
//! Features:
//! - Vertical virtualization (same as UniformList)
//! - Horizontal virtualization (column-aware)
//! - Column resizing with min/max constraints
//! - Single-row or single-cell selection
//! - Sort state management (actual sorting is caller's responsibility)
//! - Frozen columns (sticky left)
//!
//! ## Usage
//!
//! ```zig
//! // In your retained state:
//! var table_state = DataTableState.init(1000, 32.0);
//! table_state.addColumn(.{ .width_px = 200 }) catch unreachable;
//! table_state.addColumn(.{ .width_px = 100, .sortable = true }) catch unreachable;
//!
//! // In your render function:
//! b.dataTable("my-table", &table_state, .{ .height = 400 }, renderCell, renderHeader);
//! ```
//!
//! ## Memory: ~6KB per DataTableState (no per-cell allocation)

const std = @import("std");

// =============================================================================
// Constants (per CLAUDE.md: put a limit on everything)
// =============================================================================

/// Maximum columns per table. 64 columns × ~24 bytes = ~1.5KB.
pub const MAX_COLUMNS: u32 = 64;

/// Maximum visible rows rendered per frame.
/// Matches UniformListState for consistency.
pub const MAX_VISIBLE_ROWS: u32 = 128;

/// Maximum visible columns rendered per frame.
/// 32 columns is generous for most UIs.
pub const MAX_VISIBLE_COLUMNS: u32 = 32;

/// Maximum cells per frame: 128 × 32 = 4096.
/// Prevents runaway rendering.
pub const MAX_VISIBLE_CELLS: u32 = MAX_VISIBLE_ROWS * MAX_VISIBLE_COLUMNS;

/// Default overdraw for smooth scrolling.
pub const DEFAULT_OVERDRAW_ROWS: u32 = 3;
pub const DEFAULT_OVERDRAW_COLS: u32 = 1;

/// Default dimensions.
pub const DEFAULT_ROW_HEIGHT: f32 = 32.0;
pub const DEFAULT_HEADER_HEIGHT: f32 = 36.0;
pub const DEFAULT_COLUMN_WIDTH: f32 = 120.0;
pub const DEFAULT_MIN_COLUMN_WIDTH: f32 = 40.0;
pub const DEFAULT_MAX_COLUMN_WIDTH: f32 = 800.0;
pub const DEFAULT_VIEWPORT_HEIGHT: f32 = 300.0;
pub const DEFAULT_VIEWPORT_WIDTH: f32 = 600.0;

// =============================================================================
// Scroll Strategy (reuse from uniform_list for consistency)
// =============================================================================

/// Strategy for programmatic scrolling to a specific item
pub const ScrollStrategy = enum {
    /// Place item at top/left of viewport
    start,
    /// Place item at center of viewport
    center,
    /// Place item at bottom/right of viewport
    end,
    /// Scroll minimally to make item visible
    nearest,
};

/// Deferred scroll request - resolved during sync when viewport dimensions are accurate.
pub const PendingScrollRequest = union(enum) {
    /// Scroll to absolute pixel offset
    absolute: struct { x: f32, y: f32 },
    /// Scroll to top-left corner
    to_origin,
    /// Scroll to make a row visible
    to_row: struct {
        index: u32,
        strategy: ScrollStrategy,
    },
    /// Scroll to make a cell visible (row + column)
    to_cell: struct {
        row: u32,
        col: u32,
        row_strategy: ScrollStrategy,
        col_strategy: ScrollStrategy,
    },
};

// =============================================================================
// Visible Range (2D)
// =============================================================================

/// Range of visible rows [start, end)
pub const RowRange = struct {
    start: u32,
    end: u32,

    pub inline fn count(self: RowRange) u32 {
        std.debug.assert(self.end >= self.start);
        return self.end - self.start;
    }

    pub inline fn contains(self: RowRange, index: u32) bool {
        std.debug.assert(self.end >= self.start);
        return index >= self.start and index < self.end;
    }
};

/// Range of visible columns [start, end)
pub const ColRange = struct {
    start: u32,
    end: u32,

    pub inline fn count(self: ColRange) u32 {
        std.debug.assert(self.end >= self.start);
        return self.end - self.start;
    }

    pub inline fn contains(self: ColRange, index: u32) bool {
        std.debug.assert(self.end >= self.start);
        return index >= self.start and index < self.end;
    }
};

/// Combined 2D visible range
pub const VisibleRange2D = struct {
    rows: RowRange,
    cols: ColRange,

    pub inline fn cellCount(self: VisibleRange2D) u32 {
        const c = self.rows.count() * self.cols.count();
        std.debug.assert(c <= MAX_VISIBLE_CELLS);
        return c;
    }
};

// =============================================================================
// Column Configuration
// =============================================================================

pub const SortDirection = enum {
    none,
    ascending,
    descending,

    pub fn next(self: SortDirection) SortDirection {
        return switch (self) {
            .none => .ascending,
            .ascending => .descending,
            .descending => .none,
        };
    }
};

/// Column configuration. Stored inline in DataTableState.
/// Size: ~24 bytes per column.
pub const Column = struct {
    /// Current width in pixels
    width_px: f32 = DEFAULT_COLUMN_WIDTH,
    /// Minimum resize width
    min_width_px: f32 = DEFAULT_MIN_COLUMN_WIDTH,
    /// Maximum resize width
    max_width_px: f32 = DEFAULT_MAX_COLUMN_WIDTH,
    /// Can user resize this column?
    resizable: bool = true,
    /// Can user sort by this column?
    sortable: bool = false,
    /// Current sort direction (managed by toggleSort)
    sort_direction: SortDirection = .none,
    /// Frozen columns stick to left edge during horizontal scroll
    frozen: bool = false,

    const Self = @This();

    /// Clamp width to min/max bounds
    pub fn clampWidth(self: *const Self, width: f32) f32 {
        std.debug.assert(self.min_width_px <= self.max_width_px);
        std.debug.assert(self.min_width_px > 0);
        return std.math.clamp(width, self.min_width_px, self.max_width_px);
    }
};

// =============================================================================
// Selection
// =============================================================================

pub const SelectionMode = enum {
    /// No selection allowed
    none,
    /// Select entire rows
    single_row,
    /// Select individual cells
    single_cell,
};

pub const Selection = struct {
    row: ?u32 = null,
    col: ?u32 = null,

    pub fn clear(self: *Selection) void {
        self.row = null;
        self.col = null;
    }

    pub fn isRowSelected(self: Selection, row: u32) bool {
        return self.row != null and self.row.? == row;
    }

    pub fn isCellSelected(self: Selection, row: u32, col: u32) bool {
        return self.row != null and self.col != null and
            self.row.? == row and self.col.? == col;
    }
};

// =============================================================================
// Resize State
// =============================================================================

pub const ResizeState = struct {
    /// Column being resized (null if not resizing)
    column: ?u32 = null,
    /// Mouse X at drag start
    start_mouse_x: f32 = 0,
    /// Column width at drag start
    start_width: f32 = 0,

    pub fn isActive(self: ResizeState) bool {
        return self.column != null;
    }

    pub fn clear(self: *ResizeState) void {
        self.column = null;
    }
};

// =============================================================================
// DataTableState
// =============================================================================

/// Retained state for a virtualized data table.
/// Store this in your component/view state - do NOT recreate each frame.
pub const DataTableState = struct {
    // =========================================================================
    // Row Configuration
    // =========================================================================

    /// Total number of rows in data source
    row_count: u32,
    /// Height of each data row in pixels (uniform)
    row_height_px: f32,
    /// Gap between rows in pixels
    row_gap_px: f32 = 0,
    /// Current vertical scroll offset
    scroll_offset_y: f32 = 0,
    /// Viewport height (updated during layout)
    viewport_height_px: f32 = 0,
    /// Rows to render above/below visible area
    overdraw_rows: u32 = DEFAULT_OVERDRAW_ROWS,

    // =========================================================================
    // Column Configuration
    // =========================================================================

    /// Column definitions (fixed-size array)
    columns: [MAX_COLUMNS]Column = [_]Column{.{}} ** MAX_COLUMNS,
    /// Number of active columns
    column_count: u32 = 0,
    /// Current horizontal scroll offset
    scroll_offset_x: f32 = 0,
    /// Viewport width (updated during layout)
    viewport_width_px: f32 = 0,
    /// Columns to render left/right of visible area
    overdraw_cols: u32 = DEFAULT_OVERDRAW_COLS,

    // =========================================================================
    // Header Configuration
    // =========================================================================

    /// Height of header row (0 to hide)
    header_height_px: f32 = DEFAULT_HEADER_HEIGHT,
    /// Show header row?
    show_header: bool = true,

    // =========================================================================
    // Selection State
    // =========================================================================

    selection: Selection = .{},
    selection_mode: SelectionMode = .single_row,

    // =========================================================================
    // Sort State
    // =========================================================================

    /// Currently sorted column (null if none)
    sort_column: ?u32 = null,

    // =========================================================================
    // Resize State
    // =========================================================================

    resize: ResizeState = .{},

    // =========================================================================
    // Scroll Request (deferred until sync)
    // =========================================================================

    pending_scroll: ?PendingScrollRequest = null,

    const Self = @This();

    // =========================================================================
    // Initialization
    // =========================================================================

    /// Initialize with row count and uniform row height.
    pub fn init(row_count: u32, row_height_px: f32) Self {
        std.debug.assert(row_height_px > 0);
        std.debug.assert(row_count <= 1_000_000); // Sanity limit
        return .{
            .row_count = row_count,
            .row_height_px = row_height_px,
        };
    }

    /// Initialize with row count, row height, and gap.
    pub fn initWithGap(row_count: u32, row_height_px: f32, row_gap_px: f32) Self {
        std.debug.assert(row_height_px > 0);
        std.debug.assert(row_gap_px >= 0);
        std.debug.assert(row_count <= 1_000_000);
        return .{
            .row_count = row_count,
            .row_height_px = row_height_px,
            .row_gap_px = row_gap_px,
        };
    }

    // =========================================================================
    // Column Management
    // =========================================================================

    /// Add a column with the given configuration.
    /// Returns error if MAX_COLUMNS exceeded.
    pub fn addColumn(self: *Self, config: Column) error{TooManyColumns}!u32 {
        std.debug.assert(config.min_width_px <= config.max_width_px);
        std.debug.assert(config.width_px >= config.min_width_px);

        if (self.column_count >= MAX_COLUMNS) {
            return error.TooManyColumns;
        }

        const index = self.column_count;
        self.columns[index] = config;
        self.column_count += 1;

        std.debug.assert(self.column_count <= MAX_COLUMNS);
        return index;
    }

    /// Get column by index (bounds-checked).
    pub fn getColumn(self: *const Self, index: u32) ?*const Column {
        if (index >= self.column_count) return null;
        std.debug.assert(index < MAX_COLUMNS);
        return &self.columns[index];
    }

    /// Get mutable column by index.
    pub fn getColumnMut(self: *Self, index: u32) ?*Column {
        if (index >= self.column_count) return null;
        std.debug.assert(index < MAX_COLUMNS);
        return &self.columns[index];
    }

    // =========================================================================
    // Row Calculations (O(1) - same as UniformListState)
    // =========================================================================

    /// Row stride = row height + gap
    pub inline fn rowStride(self: *const Self) f32 {
        std.debug.assert(self.row_height_px > 0);
        return self.row_height_px + self.row_gap_px;
    }

    /// Total content height (all rows + header if visible)
    pub fn contentHeight(self: *const Self) f32 {
        std.debug.assert(self.row_height_px > 0);

        const header = if (self.show_header) self.header_height_px else 0;
        if (self.row_count == 0) return header;

        const rows = @as(f32, @floatFromInt(self.row_count)) * self.row_height_px;
        const gaps = @as(f32, @floatFromInt(self.row_count -| 1)) * self.row_gap_px;

        std.debug.assert(rows >= 0);
        return header + rows + gaps;
    }

    /// Maximum vertical scroll offset
    pub inline fn maxScrollY(self: *const Self) f32 {
        const max = self.contentHeight() - self.viewport_height_px;
        std.debug.assert(self.row_height_px > 0);
        return @max(0, max);
    }

    /// Get Y position of a row's top edge (relative to content, after header)
    pub fn rowTopY(self: *const Self, index: u32) f32 {
        std.debug.assert(index <= self.row_count);
        std.debug.assert(self.row_height_px > 0);
        const header = if (self.show_header) self.header_height_px else 0;
        return header + @as(f32, @floatFromInt(index)) * self.rowStride();
    }

    /// Get row index at Y position
    pub fn rowAtY(self: *const Self, y: f32) ?u32 {
        std.debug.assert(self.row_height_px > 0);

        const header = if (self.show_header) self.header_height_px else 0;
        if (y < header) return null; // In header area
        if (self.row_count == 0) return null;

        const content_y = y - header;
        const stride = self.rowStride();
        std.debug.assert(stride > 0);

        const index = @as(u32, @intFromFloat(content_y / stride));
        return if (index < self.row_count) index else null;
    }

    /// Calculate visible row range
    pub fn visibleRowRange(self: *const Self) RowRange {
        std.debug.assert(self.row_height_px > 0);

        if (self.row_count == 0) {
            return .{ .start = 0, .end = 0 };
        }

        const header = if (self.show_header) self.header_height_px else 0;
        const stride = self.rowStride();
        std.debug.assert(stride > 0);

        // Adjust scroll offset for header
        const effective_scroll = @max(0, self.scroll_offset_y - header);

        const first_visible = @as(u32, @intFromFloat(@floor(effective_scroll / stride)));
        const visible_count = @as(u32, @intFromFloat(@ceil(self.viewport_height_px / stride))) + 1;

        const start = first_visible -| self.overdraw_rows;
        const raw_end = first_visible +| visible_count +| self.overdraw_rows;
        const end = @min(raw_end, self.row_count);

        std.debug.assert(end >= start);
        std.debug.assert(end - start <= MAX_VISIBLE_ROWS);

        return .{ .start = start, .end = end };
    }

    /// Spacer height for rows above visible range
    pub fn topSpacerHeight(self: *const Self, range: RowRange) f32 {
        std.debug.assert(range.end >= range.start);
        if (range.start == 0) return 0;
        const items = @as(f32, @floatFromInt(range.start)) * self.row_height_px;
        const gaps = @as(f32, @floatFromInt(range.start)) * self.row_gap_px;
        return items + gaps;
    }

    /// Spacer height for rows below visible range
    pub fn bottomSpacerHeight(self: *const Self, range: RowRange) f32 {
        std.debug.assert(range.end >= range.start);
        const items_below = self.row_count -| range.end;
        if (items_below == 0) return 0;
        const items = @as(f32, @floatFromInt(items_below)) * self.row_height_px;
        const gaps = @as(f32, @floatFromInt(items_below)) * self.row_gap_px;
        return items + gaps;
    }

    // =========================================================================
    // Column Calculations (O(n) but n <= MAX_COLUMNS = 64)
    // =========================================================================

    /// Total content width (sum of all column widths)
    pub fn contentWidth(self: *const Self) f32 {
        std.debug.assert(self.column_count <= MAX_COLUMNS);

        var total: f32 = 0;
        for (self.columns[0..self.column_count]) |col| {
            total += col.width_px;
        }
        std.debug.assert(total >= 0);
        return total;
    }

    /// Maximum horizontal scroll offset
    pub inline fn maxScrollX(self: *const Self) f32 {
        const max = self.contentWidth() - self.viewport_width_px;
        std.debug.assert(self.column_count <= MAX_COLUMNS);
        return @max(0, max);
    }

    /// Get X position of a column's left edge
    pub fn columnLeftX(self: *const Self, col_index: u32) f32 {
        std.debug.assert(col_index <= self.column_count);
        std.debug.assert(self.column_count <= MAX_COLUMNS);

        var x: f32 = 0;
        for (self.columns[0..col_index]) |col| {
            x += col.width_px;
        }
        return x;
    }

    /// Get column index at X position (for click handling)
    pub fn columnAtX(self: *const Self, x: f32) ?u32 {
        std.debug.assert(self.column_count <= MAX_COLUMNS);

        if (x < 0) return null;

        var offset: f32 = 0;
        for (self.columns[0..self.column_count], 0..) |col, i| {
            offset += col.width_px;
            if (x < offset) return @intCast(i);
        }
        return null;
    }

    /// Calculate visible column range based on scroll offset
    pub fn visibleColRange(self: *const Self) ColRange {
        std.debug.assert(self.column_count <= MAX_COLUMNS);

        if (self.column_count == 0) {
            return .{ .start = 0, .end = 0 };
        }

        var start: u32 = 0;
        var x: f32 = 0;

        // Find first visible column
        for (self.columns[0..self.column_count], 0..) |col, i| {
            if (x + col.width_px > self.scroll_offset_x) {
                start = @as(u32, @intCast(i)) -| self.overdraw_cols;
                break;
            }
            x += col.width_px;
        }

        // Find last visible column
        var end = start;
        x = self.columnLeftX(start);
        const visible_end = self.scroll_offset_x + self.viewport_width_px;

        for (self.columns[start..self.column_count], start..) |col, i| {
            end = @intCast(i + 1);
            x += col.width_px;
            if (x > visible_end) {
                end = @min(end + self.overdraw_cols, self.column_count);
                break;
            }
        }

        std.debug.assert(end >= start);
        std.debug.assert(end - start <= MAX_VISIBLE_COLUMNS);

        return .{ .start = start, .end = end };
    }

    /// Left spacer width for columns before visible range
    pub fn leftSpacerWidth(self: *const Self, range: ColRange) f32 {
        std.debug.assert(range.end >= range.start);
        return self.columnLeftX(range.start);
    }

    /// Right spacer width for columns after visible range
    pub fn rightSpacerWidth(self: *const Self, range: ColRange) f32 {
        std.debug.assert(range.end >= range.start);
        const total = self.contentWidth();
        const visible_end_x = self.columnLeftX(range.end);
        return total - visible_end_x;
    }

    // =========================================================================
    // Combined 2D Range
    // =========================================================================

    /// Get combined visible range for rows and columns
    pub fn visibleRange(self: *const Self) VisibleRange2D {
        const rows = self.visibleRowRange();
        const cols = self.visibleColRange();

        std.debug.assert(rows.count() * cols.count() <= MAX_VISIBLE_CELLS);

        return .{ .rows = rows, .cols = cols };
    }

    // =========================================================================
    // Selection
    // =========================================================================

    /// Select a row (clears column selection)
    pub fn selectRow(self: *Self, row: u32) void {
        std.debug.assert(self.selection_mode != .none);

        if (row < self.row_count) {
            self.selection.row = row;
            if (self.selection_mode == .single_row) {
                self.selection.col = null;
            }
        }
    }

    /// Select a cell
    pub fn selectCell(self: *Self, row: u32, col: u32) void {
        std.debug.assert(self.selection_mode == .single_cell);

        if (row < self.row_count and col < self.column_count) {
            self.selection.row = row;
            self.selection.col = col;
        }
    }

    /// Clear selection
    pub fn clearSelection(self: *Self) void {
        self.selection.clear();
    }

    // =========================================================================
    // Sorting
    // =========================================================================

    /// Toggle sort on column. Returns new sort direction (or null if not sortable).
    /// Caller is responsible for actually sorting the data.
    pub fn toggleSort(self: *Self, col_index: u32) ?SortDirection {
        std.debug.assert(col_index < MAX_COLUMNS);

        if (col_index >= self.column_count) return null;
        if (!self.columns[col_index].sortable) return null;

        // Clear previous sort column
        if (self.sort_column) |prev| {
            if (prev != col_index and prev < self.column_count) {
                self.columns[prev].sort_direction = .none;
            }
        }

        // Cycle sort direction
        const col = &self.columns[col_index];
        col.sort_direction = col.sort_direction.next();

        self.sort_column = if (col.sort_direction != .none) col_index else null;
        return col.sort_direction;
    }

    // =========================================================================
    // Column Resizing
    // =========================================================================

    /// Start resizing a column
    pub fn startResize(self: *Self, col_index: u32, mouse_x: f32) void {
        std.debug.assert(col_index < MAX_COLUMNS);

        if (col_index >= self.column_count) return;
        if (!self.columns[col_index].resizable) return;

        self.resize = .{
            .column = col_index,
            .start_mouse_x = mouse_x,
            .start_width = self.columns[col_index].width_px,
        };
    }

    /// Update column width during resize drag
    pub fn updateResize(self: *Self, mouse_x: f32) void {
        const col_idx = self.resize.column orelse return;
        std.debug.assert(col_idx < self.column_count);

        const col = &self.columns[col_idx];
        const delta = mouse_x - self.resize.start_mouse_x;
        col.width_px = col.clampWidth(self.resize.start_width + delta);
    }

    /// End column resize
    pub fn endResize(self: *Self) void {
        self.resize.clear();
    }

    /// Check if mouse is near column resize handle
    pub fn hitTestResizeHandle(self: *const Self, x: f32, threshold: f32) ?u32 {
        std.debug.assert(threshold > 0);
        std.debug.assert(self.column_count <= MAX_COLUMNS);

        var col_x: f32 = 0;
        for (self.columns[0..self.column_count], 0..) |col, i| {
            col_x += col.width_px;
            // Check if near right edge of column
            if (@abs(x - col_x + self.scroll_offset_x) < threshold) {
                if (col.resizable) return @intCast(i);
            }
        }
        return null;
    }

    // =========================================================================
    // Scrolling
    // =========================================================================

    /// Scroll by delta (e.g., from scroll wheel)
    pub fn scrollBy(self: *Self, delta_x: f32, delta_y: f32) void {
        const new_x = std.math.clamp(self.scroll_offset_x + delta_x, 0, self.maxScrollX());
        const new_y = std.math.clamp(self.scroll_offset_y + delta_y, 0, self.maxScrollY());

        self.scroll_offset_x = new_x;
        self.scroll_offset_y = new_y;
        self.pending_scroll = .{ .absolute = .{ .x = new_x, .y = new_y } };
    }

    /// Scroll to absolute position
    pub fn scrollTo(self: *Self, x: f32, y: f32) void {
        const clamped_x = std.math.clamp(x, 0, self.maxScrollX());
        const clamped_y = std.math.clamp(y, 0, self.maxScrollY());

        self.scroll_offset_x = clamped_x;
        self.scroll_offset_y = clamped_y;
        self.pending_scroll = .{ .absolute = .{ .x = clamped_x, .y = clamped_y } };
    }

    /// Scroll to top-left corner
    pub fn scrollToOrigin(self: *Self) void {
        self.scroll_offset_x = 0;
        self.scroll_offset_y = 0;
        self.pending_scroll = .to_origin;
    }

    /// Scroll to make row visible with strategy
    pub fn scrollToRow(self: *Self, row: u32, strategy: ScrollStrategy) void {
        std.debug.assert(self.row_height_px > 0);
        if (row >= self.row_count) return;

        // For .start strategy, compute immediately
        if (strategy == .start) {
            const offset = std.math.clamp(self.rowTopY(row), 0, self.maxScrollY());
            self.pending_scroll = .{ .absolute = .{ .x = self.scroll_offset_x, .y = offset } };
            return;
        }

        // Defer other strategies to sync time
        self.pending_scroll = .{ .to_row = .{ .index = row, .strategy = strategy } };
    }

    /// Scroll to make cell visible
    pub fn scrollToCell(
        self: *Self,
        row: u32,
        col: u32,
        row_strategy: ScrollStrategy,
        col_strategy: ScrollStrategy,
    ) void {
        std.debug.assert(self.row_height_px > 0);
        if (row >= self.row_count) return;
        if (col >= self.column_count) return;

        self.pending_scroll = .{ .to_cell = .{
            .row = row,
            .col = col,
            .row_strategy = row_strategy,
            .col_strategy = col_strategy,
        } };
    }

    /// Resolve pending scroll request (called by builder during sync)
    pub fn resolvePendingScroll(self: *Self) void {
        const request = self.pending_scroll orelse return;

        switch (request) {
            .absolute => |pos| {
                self.scroll_offset_x = std.math.clamp(pos.x, 0, self.maxScrollX());
                self.scroll_offset_y = std.math.clamp(pos.y, 0, self.maxScrollY());
            },
            .to_origin => {
                self.scroll_offset_x = 0;
                self.scroll_offset_y = 0;
            },
            .to_row => |req| {
                self.scroll_offset_y = self.resolveRowScroll(req.index, req.strategy);
            },
            .to_cell => |req| {
                self.scroll_offset_y = self.resolveRowScroll(req.row, req.row_strategy);
                self.scroll_offset_x = self.resolveColScroll(req.col, req.col_strategy);
            },
        }

        self.pending_scroll = null;
    }

    /// Resolve row scroll offset for a given strategy
    fn resolveRowScroll(self: *const Self, row: u32, strategy: ScrollStrategy) f32 {
        std.debug.assert(row < self.row_count);
        std.debug.assert(self.row_height_px > 0);

        const row_top = self.rowTopY(row);
        const row_bottom = row_top + self.row_height_px;
        const viewport_bottom = self.scroll_offset_y + self.viewport_height_px;

        const new_offset: f32 = switch (strategy) {
            .start => row_top,
            .center => row_top - (self.viewport_height_px / 2) + (self.row_height_px / 2),
            .end => row_bottom - self.viewport_height_px,
            .nearest => blk: {
                if (row_top >= self.scroll_offset_y and row_bottom <= viewport_bottom) {
                    break :blk self.scroll_offset_y; // Already visible
                }
                if (row_top < self.scroll_offset_y) {
                    break :blk row_top; // Scroll up
                }
                break :blk row_bottom - self.viewport_height_px; // Scroll down
            },
        };

        return std.math.clamp(new_offset, 0, self.maxScrollY());
    }

    /// Resolve column scroll offset for a given strategy
    fn resolveColScroll(self: *const Self, col: u32, strategy: ScrollStrategy) f32 {
        std.debug.assert(col < self.column_count);
        std.debug.assert(self.column_count <= MAX_COLUMNS);

        const col_left = self.columnLeftX(col);
        const col_right = col_left + self.columns[col].width_px;
        const viewport_right = self.scroll_offset_x + self.viewport_width_px;

        const new_offset: f32 = switch (strategy) {
            .start => col_left,
            .center => col_left - (self.viewport_width_px / 2) + (self.columns[col].width_px / 2),
            .end => col_right - self.viewport_width_px,
            .nearest => blk: {
                if (col_left >= self.scroll_offset_x and col_right <= viewport_right) {
                    break :blk self.scroll_offset_x; // Already visible
                }
                if (col_left < self.scroll_offset_x) {
                    break :blk col_left; // Scroll left
                }
                break :blk col_right - self.viewport_width_px; // Scroll right
            },
        };

        return std.math.clamp(new_offset, 0, self.maxScrollX());
    }

    // =========================================================================
    // Scroll State Queries
    // =========================================================================

    /// Get vertical scroll percentage (0.0 - 1.0)
    pub fn scrollPercentY(self: *const Self) f32 {
        const max = self.maxScrollY();
        if (max <= 0) return 0;
        return self.scroll_offset_y / max;
    }

    /// Get horizontal scroll percentage (0.0 - 1.0)
    pub fn scrollPercentX(self: *const Self) f32 {
        const max = self.maxScrollX();
        if (max <= 0) return 0;
        return self.scroll_offset_x / max;
    }

    /// Check if a row is currently visible
    pub fn isRowVisible(self: *const Self, row: u32) bool {
        return self.visibleRowRange().contains(row);
    }

    /// Check if a column is currently visible
    pub fn isColumnVisible(self: *const Self, col: u32) bool {
        return self.visibleColRange().contains(col);
    }

    /// Check if a cell is currently visible
    pub fn isCellVisible(self: *const Self, row: u32, col: u32) bool {
        return self.isRowVisible(row) and self.isColumnVisible(col);
    }

    // =========================================================================
    // Data Updates
    // =========================================================================

    /// Update row count (e.g., when data changes).
    /// Automatically clamps scroll offset and selection.
    pub fn setRowCount(self: *Self, count: u32) void {
        std.debug.assert(count <= 1_000_000);
        self.row_count = count;
        self.scroll_offset_y = @min(self.scroll_offset_y, self.maxScrollY());

        // Clamp selection
        if (self.selection.row) |row| {
            if (row >= count) {
                self.selection.clear();
            }
        }
    }

    /// Update row height (e.g., for zoom).
    /// Maintains scroll position as percentage.
    pub fn setRowHeight(self: *Self, height: f32) void {
        std.debug.assert(height > 0);
        const percent = self.scrollPercentY();
        self.row_height_px = height;
        self.scroll_offset_y = percent * self.maxScrollY();
    }

    /// Update row gap.
    /// Maintains scroll position as percentage.
    pub fn setRowGap(self: *Self, gap: f32) void {
        std.debug.assert(gap >= 0);
        const percent = self.scrollPercentY();
        self.row_gap_px = gap;
        self.scroll_offset_y = percent * self.maxScrollY();
    }

    /// Set column width directly
    pub fn setColumnWidth(self: *Self, col_index: u32, width: f32) void {
        std.debug.assert(col_index < MAX_COLUMNS);
        if (col_index >= self.column_count) return;

        const col = &self.columns[col_index];
        col.width_px = col.clampWidth(width);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "DataTableState init" {
    const state = DataTableState.init(100, 32.0);
    try std.testing.expectEqual(@as(u32, 100), state.row_count);
    try std.testing.expectEqual(@as(f32, 32.0), state.row_height_px);
    try std.testing.expectEqual(@as(u32, 0), state.column_count);
}

test "DataTableState initWithGap" {
    const state = DataTableState.initWithGap(100, 32.0, 4.0);
    try std.testing.expectEqual(@as(f32, 4.0), state.row_gap_px);
}

test "DataTableState addColumn" {
    var state = DataTableState.init(100, 32.0);

    const idx = try state.addColumn(.{ .width_px = 150.0, .sortable = true });
    try std.testing.expectEqual(@as(u32, 0), idx);
    try std.testing.expectEqual(@as(u32, 1), state.column_count);
    try std.testing.expectEqual(@as(f32, 150.0), state.columns[0].width_px);
    try std.testing.expect(state.columns[0].sortable);
}

test "DataTableState addColumn max columns" {
    var state = DataTableState.init(100, 32.0);

    // Fill up columns
    for (0..MAX_COLUMNS) |_| {
        _ = try state.addColumn(.{});
    }

    // Should fail on next add
    try std.testing.expectError(error.TooManyColumns, state.addColumn(.{}));
}

test "DataTableState contentHeight no rows" {
    var state = DataTableState.init(0, 32.0);
    state.show_header = true;
    try std.testing.expectEqual(DEFAULT_HEADER_HEIGHT, state.contentHeight());

    state.show_header = false;
    try std.testing.expectEqual(@as(f32, 0), state.contentHeight());
}

test "DataTableState contentHeight with rows" {
    var state = DataTableState.init(10, 32.0);
    state.show_header = false;

    // 10 rows × 32px = 320px
    try std.testing.expectEqual(@as(f32, 320.0), state.contentHeight());
}

test "DataTableState contentHeight with gap" {
    var state = DataTableState.initWithGap(10, 32.0, 4.0);
    state.show_header = false;

    // (10 × 32) + (9 × 4) = 320 + 36 = 356px
    try std.testing.expectEqual(@as(f32, 356.0), state.contentHeight());
}

test "DataTableState contentHeight with header" {
    var state = DataTableState.init(10, 32.0);
    state.show_header = true;
    state.header_height_px = 40.0;

    // 40 (header) + 10 × 32 = 40 + 320 = 360px
    try std.testing.expectEqual(@as(f32, 360.0), state.contentHeight());
}

test "DataTableState contentWidth" {
    var state = DataTableState.init(100, 32.0);
    _ = try state.addColumn(.{ .width_px = 100.0 });
    _ = try state.addColumn(.{ .width_px = 150.0 });
    _ = try state.addColumn(.{ .width_px = 200.0 });

    try std.testing.expectEqual(@as(f32, 450.0), state.contentWidth());
}

test "DataTableState visibleRowRange at top" {
    var state = DataTableState.init(100, 32.0);
    state.viewport_height_px = 200.0;
    state.show_header = false;
    state.overdraw_rows = 2;

    const range = state.visibleRowRange();
    try std.testing.expectEqual(@as(u32, 0), range.start);
    // ceil(200/32) + 1 = 8, + overdraw 2 = 10
    try std.testing.expectEqual(@as(u32, 10), range.end);
}

test "DataTableState visibleRowRange scrolled" {
    var state = DataTableState.init(100, 32.0);
    state.viewport_height_px = 200.0;
    state.show_header = false;
    state.overdraw_rows = 2;
    state.scroll_offset_y = 320.0; // 10 rows down

    const range = state.visibleRowRange();
    try std.testing.expectEqual(@as(u32, 8), range.start); // 10 - 2 overdraw
    try std.testing.expectEqual(@as(u32, 20), range.end); // 10 + 8 visible + 2 overdraw
}

test "DataTableState visibleColRange" {
    var state = DataTableState.init(100, 32.0);
    _ = try state.addColumn(.{ .width_px = 100.0 });
    _ = try state.addColumn(.{ .width_px = 100.0 });
    _ = try state.addColumn(.{ .width_px = 100.0 });
    _ = try state.addColumn(.{ .width_px = 100.0 });
    state.viewport_width_px = 250.0;
    state.overdraw_cols = 0;

    const range = state.visibleColRange();
    try std.testing.expectEqual(@as(u32, 0), range.start);
    try std.testing.expectEqual(@as(u32, 3), range.end); // 250px shows ~2.5 columns
}

test "DataTableState visibleColRange scrolled" {
    var state = DataTableState.init(100, 32.0);
    _ = try state.addColumn(.{ .width_px = 100.0 });
    _ = try state.addColumn(.{ .width_px = 100.0 });
    _ = try state.addColumn(.{ .width_px = 100.0 });
    _ = try state.addColumn(.{ .width_px = 100.0 });
    state.viewport_width_px = 150.0;
    state.scroll_offset_x = 100.0; // Scroll past first column
    state.overdraw_cols = 0;

    const range = state.visibleColRange();
    try std.testing.expectEqual(@as(u32, 1), range.start);
    try std.testing.expectEqual(@as(u32, 3), range.end);
}

test "DataTableState columnAtX" {
    var state = DataTableState.init(100, 32.0);
    _ = try state.addColumn(.{ .width_px = 100.0 });
    _ = try state.addColumn(.{ .width_px = 150.0 });
    _ = try state.addColumn(.{ .width_px = 200.0 });

    try std.testing.expectEqual(@as(?u32, 0), state.columnAtX(50.0));
    try std.testing.expectEqual(@as(?u32, 1), state.columnAtX(150.0));
    try std.testing.expectEqual(@as(?u32, 2), state.columnAtX(300.0));
    try std.testing.expectEqual(@as(?u32, null), state.columnAtX(500.0));
}

test "DataTableState columnLeftX" {
    var state = DataTableState.init(100, 32.0);
    _ = try state.addColumn(.{ .width_px = 100.0 });
    _ = try state.addColumn(.{ .width_px = 150.0 });
    _ = try state.addColumn(.{ .width_px = 200.0 });

    try std.testing.expectEqual(@as(f32, 0.0), state.columnLeftX(0));
    try std.testing.expectEqual(@as(f32, 100.0), state.columnLeftX(1));
    try std.testing.expectEqual(@as(f32, 250.0), state.columnLeftX(2));
}

test "DataTableState selection" {
    var state = DataTableState.init(100, 32.0);
    _ = try state.addColumn(.{});
    _ = try state.addColumn(.{});

    state.selectRow(5);
    try std.testing.expectEqual(@as(?u32, 5), state.selection.row);
    try std.testing.expect(state.selection.isRowSelected(5));
    try std.testing.expect(!state.selection.isRowSelected(4));

    state.selection_mode = .single_cell;
    state.selectCell(3, 1);
    try std.testing.expect(state.selection.isCellSelected(3, 1));
    try std.testing.expect(!state.selection.isCellSelected(3, 0));

    state.clearSelection();
    try std.testing.expectEqual(@as(?u32, null), state.selection.row);
}

test "DataTableState toggleSort" {
    var state = DataTableState.init(100, 32.0);
    _ = try state.addColumn(.{ .sortable = false });
    _ = try state.addColumn(.{ .sortable = true });
    _ = try state.addColumn(.{ .sortable = true });

    // Non-sortable column returns null
    try std.testing.expectEqual(@as(?SortDirection, null), state.toggleSort(0));

    // First toggle -> ascending
    try std.testing.expectEqual(@as(?SortDirection, .ascending), state.toggleSort(1));
    try std.testing.expectEqual(@as(?u32, 1), state.sort_column);

    // Second toggle -> descending
    try std.testing.expectEqual(@as(?SortDirection, .descending), state.toggleSort(1));

    // Third toggle -> none
    try std.testing.expectEqual(@as(?SortDirection, .none), state.toggleSort(1));
    try std.testing.expectEqual(@as(?u32, null), state.sort_column);

    // Sorting different column clears previous
    _ = state.toggleSort(1); // ascending
    _ = state.toggleSort(2); // ascending on col 2
    try std.testing.expectEqual(SortDirection.none, state.columns[1].sort_direction);
    try std.testing.expectEqual(SortDirection.ascending, state.columns[2].sort_direction);
}

test "DataTableState resize" {
    var state = DataTableState.init(100, 32.0);
    _ = try state.addColumn(.{ .width_px = 100.0, .min_width_px = 50.0, .max_width_px = 200.0 });

    state.startResize(0, 100.0);
    try std.testing.expect(state.resize.isActive());

    state.updateResize(150.0); // +50px
    try std.testing.expectEqual(@as(f32, 150.0), state.columns[0].width_px);

    state.updateResize(400.0); // Would be +300px, but clamped to max
    try std.testing.expectEqual(@as(f32, 200.0), state.columns[0].width_px);

    state.updateResize(-100.0); // Would be -200px from start, but clamped to min
    try std.testing.expectEqual(@as(f32, 50.0), state.columns[0].width_px);

    state.endResize();
    try std.testing.expect(!state.resize.isActive());
}

test "DataTableState scrollToRow" {
    var state = DataTableState.init(100, 32.0);
    state.viewport_height_px = 200.0;
    state.show_header = false;

    state.scrollToRow(10, .start);
    try std.testing.expect(state.pending_scroll != null);

    // Resolve the scroll
    state.resolvePendingScroll();
    try std.testing.expectEqual(@as(f32, 320.0), state.scroll_offset_y); // row 10 × 32px
    try std.testing.expectEqual(@as(?PendingScrollRequest, null), state.pending_scroll);
}

test "DataTableState setRowCount clamps" {
    var state = DataTableState.init(100, 32.0);
    state.viewport_height_px = 200.0;
    state.show_header = false;
    state.scroll_offset_y = 2000.0; // Scrolled way down
    state.selectRow(50);

    state.setRowCount(10); // Shrink data

    // Scroll should be clamped
    try std.testing.expect(state.scroll_offset_y <= state.maxScrollY());

    // Selection should be cleared (was row 50, now only 10 rows)
    try std.testing.expectEqual(@as(?u32, null), state.selection.row);
}

test "DataTableState spacer heights" {
    var state = DataTableState.init(100, 32.0);
    state.viewport_height_px = 200.0;
    state.show_header = false;
    state.overdraw_rows = 0;
    state.scroll_offset_y = 320.0; // Row 10

    const range = state.visibleRowRange();

    // Top spacer: 10 rows × 32px = 320px
    try std.testing.expectEqual(@as(f32, 320.0), state.topSpacerHeight(range));

    // Bottom spacer: remaining rows
    const bottom = state.bottomSpacerHeight(range);
    try std.testing.expect(bottom > 0);
}

test "DataTableState spacer widths" {
    var state = DataTableState.init(100, 32.0);
    _ = try state.addColumn(.{ .width_px = 100.0 });
    _ = try state.addColumn(.{ .width_px = 100.0 });
    _ = try state.addColumn(.{ .width_px = 100.0 });
    _ = try state.addColumn(.{ .width_px = 100.0 });
    state.viewport_width_px = 150.0;
    state.scroll_offset_x = 100.0;
    state.overdraw_cols = 0;

    const range = state.visibleColRange();

    // Left spacer: columns before visible range
    try std.testing.expectEqual(@as(f32, 100.0), state.leftSpacerWidth(range));

    // Right spacer: columns after visible range
    const right = state.rightSpacerWidth(range);
    try std.testing.expect(right >= 0);
}

test "RowRange contains" {
    const range = RowRange{ .start = 5, .end = 15 };
    try std.testing.expect(range.contains(5));
    try std.testing.expect(range.contains(10));
    try std.testing.expect(range.contains(14));
    try std.testing.expect(!range.contains(4));
    try std.testing.expect(!range.contains(15));
}

test "ColRange contains" {
    const range = ColRange{ .start = 2, .end = 6 };
    try std.testing.expect(range.contains(2));
    try std.testing.expect(range.contains(5));
    try std.testing.expect(!range.contains(1));
    try std.testing.expect(!range.contains(6));
}

test "VisibleRange2D cellCount" {
    const range = VisibleRange2D{
        .rows = .{ .start = 0, .end = 10 },
        .cols = .{ .start = 0, .end = 5 },
    };
    try std.testing.expectEqual(@as(u32, 50), range.cellCount());
}

test "SortDirection next" {
    try std.testing.expectEqual(SortDirection.ascending, SortDirection.none.next());
    try std.testing.expectEqual(SortDirection.descending, SortDirection.ascending.next());
    try std.testing.expectEqual(SortDirection.none, SortDirection.descending.next());
}
