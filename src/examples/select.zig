//! Select Component Demo
//!
//! Demonstrates the Select component with various configurations.
//! Demonstrates application-controlled open state and index-based selection.

const gooey = @import("gooey");
const std = @import("std");

/// WASM-compatible logging - redirect std.log to console.log via JS imports
pub const std_options = gooey.std_options;
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;

const Select = gooey.components.Select;

// =============================================================================
// State
// =============================================================================

const AppState = struct {
    fruit_selected: ?usize = null,
    country_selected: ?usize = 2, // Pre-selected: "Canada"
    size_selected: ?usize = 1, // Pre-selected: "Medium"
    fruit_open: bool = false,
    country_open: bool = false,
    size_open: bool = false,

    pub fn selectFruit(self: *AppState, index: usize) void {
        std.debug.assert(fruit_options.len > 0);
        std.debug.assert(index < fruit_options.len);
        self.fruit_selected = index;
        self.fruit_open = false;
        std.debug.assert(self.fruit_selected.? == index);
        std.debug.assert(!self.fruit_open);
    }

    pub fn selectCountry(self: *AppState, index: usize) void {
        std.debug.assert(country_options.len > 0);
        std.debug.assert(index < country_options.len);
        self.country_selected = index;
        self.country_open = false;
        std.debug.assert(self.country_selected.? == index);
        std.debug.assert(!self.country_open);
    }

    pub fn selectSize(self: *AppState, index: usize) void {
        std.debug.assert(size_options.len > 0);
        std.debug.assert(index < size_options.len);
        self.size_selected = index;
        self.size_open = false;
        std.debug.assert(self.size_selected.? == index);
        std.debug.assert(!self.size_open);
    }

    pub fn toggleFruit(self: *AppState) void {
        const was_open = self.fruit_open;
        self.fruit_open = !self.fruit_open;
        std.debug.assert(self.fruit_open != was_open);
    }

    pub fn closeFruit(self: *AppState) void {
        self.fruit_open = false;
        std.debug.assert(!self.fruit_open);
    }

    pub fn toggleCountry(self: *AppState) void {
        const was_open = self.country_open;
        self.country_open = !self.country_open;
        std.debug.assert(self.country_open != was_open);
    }

    pub fn closeCountry(self: *AppState) void {
        self.country_open = false;
        std.debug.assert(!self.country_open);
    }

    pub fn toggleSize(self: *AppState) void {
        const was_open = self.size_open;
        self.size_open = !self.size_open;
        std.debug.assert(self.size_open != was_open);
    }

    pub fn closeSize(self: *AppState) void {
        self.size_open = false;
        std.debug.assert(!self.size_open);
    }
};

var state = AppState{};

// =============================================================================
// Options Data
// =============================================================================

const fruit_options = [_][]const u8{ "Apple", "Banana", "Cherry", "Dragon Fruit", "Elderberry" };
const country_options = [_][]const u8{
    "United States",
    "United Kingdom",
    "Canada",
    "Australia",
    "Germany",
    "France",
    "Japan",
};
const size_options = [_][]const u8{ "Small", "Medium", "Large", "Extra Large" };

// =============================================================================
// Entry Points
// =============================================================================

const App = gooey.App(AppState, &state, render, .{
    .title = "Select Component Demo",
    .width = 700,
    .height = 500,
});

comptime {
    _ = App;
}

pub fn main(init: std.process.Init) !void {
    if (platform.is_wasm) unreachable;
    return App.main(init);
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
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 20 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .column,
            .gap = 8,
        }, .{
            ui.text("Select Component Demo", .{ .size = 24 }),
            ui.text("Click a select to open the dropdown. Click outside to close.", .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.5),
            }),
        }));
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
                    .on_toggle = cx.update(AppState.toggleFruit),
                    .on_close = cx.update(AppState.closeFruit),
                    .on_select = cx.onSelect(AppState.selectFruit),
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
                    .width = 250,
                    .is_open = s.country_open,
                    .on_toggle = cx.update(AppState.toggleCountry),
                    .on_close = cx.update(AppState.closeCountry),
                    .on_select = cx.onSelect(AppState.selectCountry),
                },
            },
            // Row 3: Size select (custom colors)
            SelectRow{
                .label = "T-Shirt Size",
                .select = Select{
                    .id = "size-select",
                    .options = &size_options,
                    .selected = s.size_selected,
                    .width = 160,
                    .focus_border_color = ui.Color.rgb(0.4, 0.7, 0.4),
                    .selected_background = ui.Color.rgb(0.9, 1.0, 0.9),
                    .is_open = s.size_open,
                    .on_toggle = cx.update(AppState.toggleSize),
                    .on_close = cx.update(AppState.closeSize),
                    .on_select = cx.onSelect(AppState.selectSize),
                },
            },
        }));
    }
};

const SelectRow = struct {
    label: []const u8,
    select: Select,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .fill_width = true,
            .direction = .row,
            .alignment = .{ .cross = .center },
            .gap = 16,
        }, .{
            LabelBox{ .text = self.label },
            self.select,
        }));
    }
};

const LabelBox = struct {
    text: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .width = 120,
        }, .{
            ui.text(self.text, .{
                .size = 14,
                .color = ui.Color.rgb(0.3, 0.3, 0.3),
            }),
        }));
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

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
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
        }));
    }
};
