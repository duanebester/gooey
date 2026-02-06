//! Lucide Icons Demo — All Icons Showcase
//!
//! Displays all Lucide icons in a virtualized, scrollable grid.
//! Uses UniformList for O(1) layout — only visible rows are rendered.
//! Each icon is 24x24 in a 32x32 cell, 16 icons per row.

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;
const UniformListState = gooey.UniformListState;

// =============================================================================
// Grid Layout Constants
// =============================================================================

/// Icons per row in the grid.
const COLS: u32 = 16;

/// Cell dimensions (pixels). Icons are centered within cells.
const CELL_SIZE: f32 = 32;

/// Lucide canonical icon size (pixels).
const ICON_SIZE: f32 = 24;

/// Vertical gap between rows (pixels).
const ROW_GAP: f32 = 4;

/// Horizontal gap between cells (pixels).
const COL_GAP: f32 = 4;

// =============================================================================
// Comptime Icon Lookup Table
// =============================================================================

const IconEntry = struct {
    name: []const u8,
    path: []const u8,
};

/// All Lucide icon entries, generated at comptime from struct declarations.
/// Enables runtime indexing into comptime icon data for virtualized rendering.
const icon_entries = blk: {
    @setEvalBranchQuota(20000);
    const decls = @typeInfo(Lucide).@"struct".decls;
    var entries: [decls.len]IconEntry = undefined;
    for (decls, 0..) |decl, i| {
        entries[i] = .{
            .name = decl.name,
            .path = @field(Lucide, decl.name),
        };
    }
    break :blk entries;
};

const TOTAL_ICONS: u32 = icon_entries.len;
const TOTAL_ROWS: u32 = (TOTAL_ICONS + COLS - 1) / COLS;

comptime {
    std.debug.assert(TOTAL_ICONS > 0);
    std.debug.assert(TOTAL_ROWS > 0);
    std.debug.assert(COLS > 0);
    std.debug.assert(CELL_SIZE >= ICON_SIZE);
}

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    list_state: UniformListState = UniformListState.initWithGap(
        TOTAL_ROWS,
        CELL_SIZE,
        ROW_GAP,
    ),
};

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Lucide Icons — All " ++ std.fmt.comptimePrint("{d}", .{TOTAL_ICONS}) ++ " Icons",
    .width = 700,
    .height = 850,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// =============================================================================
// Row Content Component
// =============================================================================

/// Renders a horizontal slice of icon cells [start, end).
/// Used inside each uniform-list row to emit the actual SVGs.
const RowContent = struct {
    start: u32,
    end: u32,

    pub fn render(self: RowContent, b: *ui.Builder) void {
        std.debug.assert(self.start <= self.end);
        std.debug.assert(self.end <= TOTAL_ICONS);

        var i = self.start;
        while (i < self.end) : (i += 1) {
            b.box(.{
                .width = CELL_SIZE,
                .height = CELL_SIZE,
                .alignment = .{ .main = .center, .cross = .center },
                .corner_radius = 4,
                .background = ui.Color.hex(0x1e293b),
                .hover_background = ui.Color.hex(0x334155),
            }, .{
                Svg{
                    .path = icon_entries[i].path,
                    .size = ICON_SIZE,
                    .no_fill = true,
                    .stroke_color = ui.Color.hex(0xe2e8f0),
                    .stroke_width = 1.5,
                },
            });
        }
    }
};

// =============================================================================
// Icon Grid Component (virtualized)
// =============================================================================

const IconGrid = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        std.debug.assert(TOTAL_ROWS > 0);
        std.debug.assert(state.list_state.item_count == TOTAL_ROWS);

        cx.uniformList("icon-grid", &state.list_state, .{
            .fill_width = true,
            .grow_height = true,
            .background = ui.Color.hex(0x0f172a),
            .padding = .{ .all = 0 },
            .gap = ROW_GAP,
        }, renderRow);
    }
};

/// Callback for UniformList — renders a single row of icons.
fn renderRow(row_index: u32, cx: *Cx) void {
    std.debug.assert(row_index < TOTAL_ROWS);

    const start = row_index * COLS;
    const end: u32 = @min(start + COLS, TOTAL_ICONS);
    std.debug.assert(start < end);

    cx.render(ui.box(.{
        .height = CELL_SIZE,
        .direction = .row,
        .gap = COL_GAP,
        .alignment = .{ .main = .start, .cross = .center },
    }, .{
        RowContent{ .start = start, .end = end },
    }));
}

// =============================================================================
// Main Render
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();
    std.debug.assert(size.width > 0);
    std.debug.assert(size.height > 0);

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 24 },
        .gap = 12,
        .direction = .column,
        .background = ui.Color.hex(0x0f172a),
    }, .{
        // Title
        ui.text("Lucide Icons", .{
            .size = 24,
            .color = ui.Color.white,
            .weight = .bold,
        }),

        // Subtitle with icon count
        ui.text(
            std.fmt.comptimePrint("All {d} icons - 24x24 stroke-based SVGs from lucide.dev", .{TOTAL_ICONS}),
            .{
                .size = 12,
                .color = ui.Color.hex(0x94a3b8),
            },
        ),

        // Scrollable virtualized icon grid
        IconGrid{},
    }));
}

// =============================================================================
// Tests
// =============================================================================

test "icon_entries populated" {
    try std.testing.expect(icon_entries.len > 1600);
    try std.testing.expect(icon_entries.len < 2000);
}

test "grid dimensions" {
    try std.testing.expect(TOTAL_ROWS > 0);
    try std.testing.expectEqual(TOTAL_ROWS, (TOTAL_ICONS + COLS - 1) / COLS);
}

test "last row partial or full" {
    const last_row_start = (TOTAL_ROWS - 1) * COLS;
    const last_row_count = TOTAL_ICONS - last_row_start;
    try std.testing.expect(last_row_start < TOTAL_ICONS);
    try std.testing.expect(last_row_count >= 1);
    try std.testing.expect(last_row_count <= COLS);
}

test "AppState defaults valid" {
    const s = AppState{};
    try std.testing.expectEqual(s.list_state.item_count, TOTAL_ROWS);
    try std.testing.expect(s.list_state.item_height_px == CELL_SIZE);
    try std.testing.expect(s.list_state.gap_px == ROW_GAP);
}
