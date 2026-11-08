//! Lucide icons on the 0.4.0 core: every icon in a scrollable grid.
//!
//! A `List` builds only the rows in view; each row holds 16 icons, each 24 px
//! icon in a 32 px cell that lights up under the pointer. This is the measured
//! reference for the `large` profile (780 quads, 480 SVGs), kept to phase 5.

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const core = gooey.core;
const ui = core.ui;
const Cx = core.Cx;
const Color = ui.Color;
const List = components.core.List;
const Lucide = components.Lucide;

const assert = std.debug.assert;

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

pub const IconEntry = struct {
    name: []const u8,
    path: []const u8,
};

/// All Lucide icon entries, generated at comptime from struct declarations.
/// Enables runtime indexing into comptime icon data for virtualized rendering.
pub const icon_entries = blk: {
    @setEvalBranchQuota(20000);
    const decl_names = @typeInfo(Lucide).@"struct".decl_names;
    var entries: [decl_names.len]IconEntry = undefined;
    for (decl_names, 0..) |decl_name, i| {
        entries[i] = .{
            .name = decl_name,
            .path = @field(Lucide, decl_name),
        };
    }
    break :blk entries;
};

pub const TOTAL_ICONS: u32 = icon_entries.len;
pub const TOTAL_ROWS: u32 = (TOTAL_ICONS + COLS - 1) / COLS;

comptime {
    std.debug.assert(TOTAL_ICONS > 0);
    std.debug.assert(TOTAL_ROWS > 0);
    std.debug.assert(COLS > 0);
    std.debug.assert(CELL_SIZE >= ICON_SIZE);
}

pub const State = struct {};

pub const App = core.App(State, render, .{
    .title = "Lucide Icons — All " ++ std.fmt.comptimePrint("{d}", .{TOTAL_ICONS}) ++ " Icons",
    .width = 700,
    .height = 850,
    .limits = .large,
});

/// The generated entry point (contract §7).
pub const main = App.main;

const background = Color.hex(0x0f172a);
const cell_color = Color.hex(0x1e293b);
const cell_hover_color = Color.hex(0x334155);
const stroke_color = Color.hex(0xe2e8f0);

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(24),
        .gap = 12,
        .background = .{ .rgba = background },
    } }, .{
        ui.text("Lucide Icons", .{
            .size = 24,
            .weight = .bold,
            .color = .{ .rgba = Color.white },
        }),
        ui.text(std.fmt.comptimePrint(
            "All {d} icons - 24x24 stroke-based SVGs from lucide.dev",
            .{TOTAL_ICONS},
        ), .{ .size = 12, .color = .{ .rgba = Color.hex(0x94a3b8) } }),
        List(IconRow){
            .key = "icon-grid",
            .count = TOTAL_ROWS,
            .gap = ROW_GAP,
            .style = .{ .background = .{ .rgba = background } },
        },
    }));
}

/// One row of up to `COLS` icons.
pub const IconRow = struct {
    index: u32,

    pub const row_height: f32 = CELL_SIZE;

    pub fn render(self: IconRow, cx: *Cx) void {
        assert(self.index < TOTAL_ROWS);
        const start = self.index * COLS;
        const end: u32 = @min(start + COLS, TOTAL_ICONS);
        assert(start < end);
        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .gap = COL_GAP,
            .alignment = .center_cross,
        } }, .{IconCells{ .start = start, .end = end }}));
    }
};

const IconCells = struct {
    start: u32,
    end: u32,

    pub fn render(self: IconCells, cx: *Cx) void {
        assert(self.start < self.end);
        assert(self.end <= TOTAL_ICONS);
        var index = self.start;
        while (index < self.end) : (index += 1) {
            // Keyed by position in the row, so hover follows the cell.
            const key = core.Key{ .index = index - self.start };
            const hovered = cx.hovered(cx.id(key));
            cx.render(ui.box(.{ .key = key, .style = .{
                .width = .{ .fixed = CELL_SIZE },
                .height = .{ .fixed = CELL_SIZE },
                .alignment = .center,
                .corner_radius = .all(4),
                .background = .{ .rgba = if (hovered) cell_hover_color else cell_color },
            } }, .{ui.paint(IconEntry, &icon_entries[index], paintIcon, .{
                .width = .{ .fixed = ICON_SIZE },
                .height = .{ .fixed = ICON_SIZE },
            })}));
        }
    }
};

fn paintIcon(entry: *const IconEntry, painter: *ui.Painter) void {
    assert(entry.path.len > 0);
    painter.svg(entry.path, painter.bounds, .{
        .fill = null,
        .stroke = stroke_color,
        .stroke_width = 1.5,
    });
}

// =============================================================================
// Tests
// =============================================================================

test "icon_entries populated" {
    try std.testing.expect(icon_entries.len > 1600);
    try std.testing.expect(icon_entries.len < 2000);
}

test "last row partial or full" {
    const last_row_start = (TOTAL_ROWS - 1) * COLS;
    const last_row_count = TOTAL_ICONS - last_row_start;
    try std.testing.expect(last_row_start < TOTAL_ICONS);
    try std.testing.expect(last_row_count >= 1);
    try std.testing.expect(last_row_count <= COLS);
}
