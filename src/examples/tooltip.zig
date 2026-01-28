//! Tooltip Example
//!
//! Demonstrates the Tooltip component with various positions and styles.

const std = @import("std");
const builtin = @import("builtin");
const gooey = @import("gooey");

/// WASM-compatible logging - redirect std.log to console.log via JS imports
pub const std_options: std.Options = if (builtin.os.tag == .freestanding)
    .{ .logFn = gooey.wasmLogFn }
else
    .{};
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;

const Button = gooey.Button;
const Tooltip = gooey.Tooltip;

// =============================================================================
// State
// =============================================================================

const AppState = struct {};

var state = AppState{};

// =============================================================================
// Entry Points
// =============================================================================

const App = gooey.App(AppState, &state, render, .{
    .title = "Tooltip Examples",
    .width = 700,
    .height = 500,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// =============================================================================
// Render
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = ui.Color.rgb(0.95, 0.95, 0.95),
        .direction = .column,
        .padding = .{ .all = 32 },
        .gap = 32,
    }, .{
        Header{},
        PositionDemo{},
        StyleDemo{},
    }));
}

// =============================================================================
// Components
// =============================================================================

const Header = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .padding = .{ .all = 20 },
            .background = ui.Color.white,
            .corner_radius = 12,
            .direction = .column,
            .gap = 8,
        }, .{
            ui.text("Tooltip Component", .{
                .size = 28,
                .color = ui.Color.rgb(0.1, 0.1, 0.1),
            }),
            ui.text("Hover over the buttons to see tooltips in different positions.", .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.5),
            }),
        });
    }
};

const PositionDemo = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .padding = .{ .all = 24 },
            .background = ui.Color.white,
            .corner_radius = 12,
            .direction = .column,
            .gap = 16,
        }, .{
            ui.text("Positions", .{
                .size = 18,
                .color = ui.Color.rgb(0.2, 0.2, 0.2),
            }),
            PositionButtons{},
        });
    }
};

const PositionButtons = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .direction = .row,
            .gap = 24,
            .alignment = .{ .main = .center },
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 0, .y = 20 } },
        }, .{
            // Top tooltip
            Tooltip(Button){
                .text = "I appear above the button",
                .position = .top,
                .child = Button{
                    .label = "Top ↑",
                    .variant = .primary,
                },
            },
            // Bottom tooltip
            Tooltip(Button){
                .text = "I appear below the button",
                .position = .bottom,
                .child = Button{
                    .label = "Bottom ↓",
                    .variant = .primary,
                },
            },
            // Left tooltip
            Tooltip(Button){
                .text = "I appear to the left",
                .position = .left,
                .child = Button{
                    .label = "← Left",
                    .variant = .primary,
                },
            },
            // Right tooltip
            Tooltip(Button){
                .text = "I appear to the right",
                .position = .right,
                .child = Button{
                    .label = "Right →",
                    .variant = .primary,
                },
            },
        });
    }
};

const StyleDemo = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .padding = .{ .all = 24 },
            .background = ui.Color.white,
            .corner_radius = 12,
            .direction = .column,
            .gap = 16,
        }, .{
            ui.text("Custom Styles", .{
                .size = 18,
                .color = ui.Color.rgb(0.2, 0.2, 0.2),
            }),
            StyleButtons{},
        });
    }
};

const StyleButtons = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .direction = .row,
            .gap = 24,
            .alignment = .{ .main = .center },
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 0, .y = 20 } },
        }, .{
            // Default dark style
            Tooltip(Button){
                .text = "Default dark tooltip style",
                .child = Button{
                    .label = "Default",
                    .variant = .secondary,
                },
            },
            // Light style
            Tooltip(Button){
                .id = "light-tooltip",
                .text = "Light tooltip with dark text",
                .background = ui.Color.white,
                .text_color = ui.Color.rgb(0.2, 0.2, 0.2),
                .child = Button{
                    .label = "Light",
                    .variant = .secondary,
                },
            },
            // Colored style
            Tooltip(Button){
                .id = "blue-tooltip",
                .text = "Colorful tooltip!",
                .background = ui.Color.rgb(0.2, 0.5, 1.0),
                .text_color = ui.Color.white,
                .corner_radius = 12,
                .child = Button{
                    .label = "Blue",
                    .variant = .secondary,
                },
            },
            // Danger style
            Tooltip(Button){
                .id = "danger-tooltip",
                .text = "Warning: This action cannot be undone!",
                .background = ui.Color.rgb(0.9, 0.2, 0.2),
                .text_color = ui.Color.white,
                .max_width = 200,
                .child = Button{
                    .label = "Danger",
                    .variant = .danger,
                },
            },
        });
    }
};
