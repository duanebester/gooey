//! Select Component Demo
//!
//! Demonstrates the Select component with various configurations.

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

const Select = gooey.Select;

// =============================================================================
// State
// =============================================================================

const AppState = struct {
    // Fruit select
    fruit_selected: ?usize = null,
    fruit_open: bool = false,

    // Country select
    country_selected: ?usize = 2, // Pre-selected: "Canada"
    country_open: bool = false,

    // Size select
    size_selected: ?usize = 1, // Pre-selected: "Medium"
    size_open: bool = false,

    // Fruit handlers
    pub fn toggleFruit(self: *AppState) void {
        self.fruit_open = !self.fruit_open;
        // Close others
        self.country_open = false;
        self.size_open = false;
    }

    pub fn closeFruit(self: *AppState) void {
        self.fruit_open = false;
    }

    pub fn selectFruit(self: *AppState, index: usize) void {
        self.fruit_selected = index;
        self.fruit_open = false;
    }

    // Country handlers
    pub fn toggleCountry(self: *AppState) void {
        self.country_open = !self.country_open;
        // Close others
        self.fruit_open = false;
        self.size_open = false;
    }

    pub fn closeCountry(self: *AppState) void {
        self.country_open = false;
    }

    pub fn selectCountry(self: *AppState, index: usize) void {
        self.country_selected = index;
        self.country_open = false;
    }

    // Size handlers
    pub fn toggleSize(self: *AppState) void {
        self.size_open = !self.size_open;
        // Close others
        self.fruit_open = false;
        self.country_open = false;
    }

    pub fn closeSize(self: *AppState) void {
        self.size_open = false;
    }

    pub fn selectSize(self: *AppState, index: usize) void {
        self.size_selected = index;
        self.size_open = false;
    }

    // Close all dropdowns
    pub fn closeAll(self: *AppState) void {
        self.fruit_open = false;
        self.country_open = false;
        self.size_open = false;
    }
};

var state = AppState{};

// =============================================================================
// Options Data
// =============================================================================

const fruit_options = [_][]const u8{ "Apple", "Banana", "Cherry", "Dragon Fruit", "Elderberry" };
const country_options = [_][]const u8{ "United States", "United Kingdom", "Canada", "Australia", "Germany", "France", "Japan" };
const size_options = [_][]const u8{ "Small", "Medium", "Large", "Extra Large" };

// =============================================================================
// Entry Points
// =============================================================================

const App = gooey.App(AppState, &state, render, .{
    .title = "Select Component Demo",
    .width = 700,
    .height = 500,
    .on_event = onEvent,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// =============================================================================
// Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = ui.Color.rgb(0.95, 0.95, 0.95),
        .direction = .column,
        .padding = .{ .all = 30 },
        .gap = 30,
    }, .{
        Header{},
        SelectExamples{},
        SelectionStatus{},
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
            .corner_radius = 8,
            .direction = .column,
            .gap = 8,
        }, .{
            ui.text("Select Component Demo", .{ .size = 24 }),
            ui.text("Click a select to open the dropdown. Click outside or press Escape to close.", .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.5),
            }),
        });
    }
};

const SelectExamples = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 20 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .column,
            .gap = 24,
        }, .{
            // Row 1: Fruit select
            SelectRow{
                .label = "Favorite Fruit",
                .select = Select{
                    .id = "fruit-select",
                    .options = &fruit_options,
                    .selected = s.fruit_selected,
                    .placeholder = "Choose a fruit...",
                    .is_open = s.fruit_open,
                    .on_toggle_handler = cx.update(AppState, AppState.toggleFruit),
                    .on_close_handler = cx.update(AppState, AppState.closeFruit),
                    .handlers = &.{
                        cx.updateWith(AppState, @as(usize, 0), AppState.selectFruit),
                        cx.updateWith(AppState, @as(usize, 1), AppState.selectFruit),
                        cx.updateWith(AppState, @as(usize, 2), AppState.selectFruit),
                        cx.updateWith(AppState, @as(usize, 3), AppState.selectFruit),
                        cx.updateWith(AppState, @as(usize, 4), AppState.selectFruit),
                    },
                },
            },
            // Row 2: Country select (wider)
            SelectRow{
                .label = "Country",
                .select = Select{
                    .id = "country-select",
                    .options = &country_options,
                    .selected = s.country_selected,
                    .placeholder = "Select your country...",
                    .is_open = s.country_open,
                    .width = 250,
                    .on_toggle_handler = cx.update(AppState, AppState.toggleCountry),
                    .on_close_handler = cx.update(AppState, AppState.closeCountry),
                    .handlers = &.{
                        cx.updateWith(AppState, @as(usize, 0), AppState.selectCountry),
                        cx.updateWith(AppState, @as(usize, 1), AppState.selectCountry),
                        cx.updateWith(AppState, @as(usize, 2), AppState.selectCountry),
                        cx.updateWith(AppState, @as(usize, 3), AppState.selectCountry),
                        cx.updateWith(AppState, @as(usize, 4), AppState.selectCountry),
                        cx.updateWith(AppState, @as(usize, 5), AppState.selectCountry),
                        cx.updateWith(AppState, @as(usize, 6), AppState.selectCountry),
                    },
                },
            },
            // Row 3: Size select (custom colors)
            SelectRow{
                .label = "T-Shirt Size",
                .select = Select{
                    .id = "size-select",
                    .options = &size_options,
                    .selected = s.size_selected,
                    .is_open = s.size_open,
                    .width = 160,
                    .focus_border_color = ui.Color.rgb(0.4, 0.7, 0.4),
                    .selected_background = ui.Color.rgb(0.9, 1.0, 0.9),
                    .on_toggle_handler = cx.update(AppState, AppState.toggleSize),
                    .on_close_handler = cx.update(AppState, AppState.closeSize),
                    .handlers = &.{
                        cx.updateWith(AppState, @as(usize, 0), AppState.selectSize),
                        cx.updateWith(AppState, @as(usize, 1), AppState.selectSize),
                        cx.updateWith(AppState, @as(usize, 2), AppState.selectSize),
                        cx.updateWith(AppState, @as(usize, 3), AppState.selectSize),
                    },
                },
            },
        }));
    }
};

const SelectRow = struct {
    label: []const u8,
    select: Select,

    pub fn render(self: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .direction = .row,
            .alignment = .{ .cross = .center },
            .gap = 16,
        }, .{
            LabelBox{ .text = self.label },
            self.select,
        });
    }
};

const LabelBox = struct {
    text: []const u8,

    pub fn render(self: @This(), b: *ui.Builder) void {
        b.box(.{
            .width = 120,
        }, .{
            ui.text(self.text, .{
                .size = 14,
                .color = ui.Color.rgb(0.3, 0.3, 0.3),
            }),
        });
    }
};

const SelectionStatus = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 20 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .column,
            .gap = 12,
        }, .{
            ui.text("Current Selections", .{ .size = 18 }),
            StatusLine{
                .label = "Fruit:",
                .value = if (s.fruit_selected) |idx| fruit_options[idx] else "(none)",
            },
            StatusLine{
                .label = "Country:",
                .value = if (s.country_selected) |idx| country_options[idx] else "(none)",
            },
            StatusLine{
                .label = "Size:",
                .value = if (s.size_selected) |idx| size_options[idx] else "(none)",
            },
        }));
    }
};

const StatusLine = struct {
    label: []const u8,
    value: []const u8,

    pub fn render(self: @This(), b: *ui.Builder) void {
        b.box(.{
            .direction = .row,
            .gap = 8,
        }, .{
            ui.text(self.label, .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.5),
            }),
            ui.text(self.value, .{
                .size = 14,
                .color = ui.Color.rgb(0.2, 0.2, 0.2),
            }),
        });
    }
};

// =============================================================================
// Event Handling
// =============================================================================

fn onEvent(cx: *Cx, event: gooey.InputEvent) bool {
    if (event == .key_down) {
        const key = event.key_down;
        const s = cx.state(AppState);

        // Escape closes all dropdowns
        if (key.key == .escape) {
            if (s.fruit_open or s.country_open or s.size_open) {
                state.closeAll();
                return true;
            }
        }
    }
    return false;
}
