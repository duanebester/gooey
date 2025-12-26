//! Select Component
//!
//! A dropdown select menu for choosing from a list of options.
//! Supports keyboard navigation, configurable styling, and proper floating behavior.
//!
//! Usage with Cx (recommended):
//! ```zig
//! const State = struct {
//!     selected_option: ?usize = null,
//!     select_open: bool = false,
//!
//!     pub fn toggleSelect(self: *State) void {
//!         self.select_open = !self.select_open;
//!     }
//!
//!     pub fn closeSelect(self: *State) void {
//!         self.select_open = false;
//!     }
//!
//!     pub fn selectOption(self: *State, index: usize) void {
//!         self.selected_option = index;
//!         self.select_open = false;
//!     }
//! };
//!
//! // In render:
//! Select{
//!     .id = "my-select",
//!     .options = &.{ "Apple", "Banana", "Cherry" },
//!     .selected = s.selected_option,
//!     .is_open = s.select_open,
//!     .on_toggle_handler = cx.update(State, State.toggleSelect),
//!     .on_close_handler = cx.update(State, State.closeSelect),
//!     .handlers = &.{
//!         cx.updateWith(State, @as(usize, 0), State.selectOption),
//!         cx.updateWith(State, @as(usize, 1), State.selectOption),
//!         cx.updateWith(State, @as(usize, 2), State.selectOption),
//!     },
//! }
//! ```

const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const HandlerRef = ui.HandlerRef;

/// A dropdown select component for single-option selection.
pub const Select = struct {
    /// Unique identifier for the select (used for element IDs)
    id: []const u8 = "select",

    /// List of options to display
    options: []const []const u8,

    /// Currently selected option index (null = nothing selected)
    selected: ?usize = null,

    /// Placeholder text when nothing is selected
    placeholder: []const u8 = "Select...",

    /// Whether the dropdown is currently open
    is_open: bool = false,

    /// Handler to toggle open/closed state (called when trigger is clicked)
    on_toggle_handler: ?HandlerRef = null,

    /// Handler to close the dropdown (called on click-outside)
    on_close_handler: ?HandlerRef = null,

    /// Array of handlers, one per option. Use cx.updateWith() to create these.
    handlers: ?[]const HandlerRef = null,

    // === Layout ===

    /// Fixed width for the select (null = auto-size to content)
    width: ?f32 = 200,

    /// Minimum width for the dropdown menu
    min_dropdown_width: ?f32 = null,

    // === Styling ===

    /// Background color for the trigger button
    background: Color = Color.white,

    /// Background color when hovering the trigger
    hover_background: Color = Color.rgb(0.98, 0.98, 0.98),

    /// Background color for selected/highlighted option
    selected_background: Color = Color.rgb(0.93, 0.95, 1.0),

    /// Background color for option on hover
    option_hover_background: Color = Color.rgb(0.95, 0.95, 0.95),

    /// Border color
    border_color: Color = Color.rgb(0.8, 0.8, 0.8),

    /// Border color when open/focused
    focus_border_color: Color = Color.rgb(0.2, 0.5, 1.0),

    /// Text color
    text_color: Color = Color.rgb(0.2, 0.2, 0.2),

    /// Placeholder text color
    placeholder_color: Color = Color.rgb(0.6, 0.6, 0.6),

    /// Font size
    font_size: u16 = 14,

    /// Corner radius
    corner_radius: f32 = 6,

    /// Padding inside the trigger
    padding: f32 = 10,

    /// Whether the select is disabled
    disabled: bool = false,

    pub fn render(self: Select, b: *ui.Builder) void {
        const current_border = if (self.is_open) self.focus_border_color else self.border_color;

        // Container that holds both trigger and dropdown
        b.boxWithId(self.id, .{
            .width = self.width,
        }, .{
            // Trigger button
            SelectTrigger{
                .text = self.getDisplayText(),
                .is_placeholder = self.selected == null,
                .is_open = self.is_open,
                .on_click_handler = if (!self.disabled) self.on_toggle_handler else null,
                .background = self.background,
                .hover_background = if (!self.disabled) self.hover_background else self.background,
                .border_color = current_border,
                .text_color = if (self.selected == null) self.placeholder_color else self.text_color,
                .font_size = self.font_size,
                .corner_radius = self.corner_radius,
                .padding = self.padding,
                .disabled = self.disabled,
            },
            // Dropdown menu (only rendered when open)
            SelectDropdown{
                .is_open = self.is_open,
                .options = self.options,
                .selected = self.selected,
                .handlers = self.handlers,
                .on_close_handler = self.on_close_handler,
                .min_width = self.min_dropdown_width orelse self.width,
                .background = self.background,
                .selected_background = self.selected_background,
                .hover_background = self.option_hover_background,
                .text_color = self.text_color,
                .font_size = self.font_size,
                .corner_radius = self.corner_radius,
                .padding = self.padding,
            },
        });
    }

    fn getDisplayText(self: Select) []const u8 {
        if (self.selected) |idx| {
            if (idx < self.options.len) {
                return self.options[idx];
            }
        }
        return self.placeholder;
    }
};

/// The clickable trigger that shows current selection
const SelectTrigger = struct {
    text: []const u8,
    is_placeholder: bool,
    is_open: bool,
    on_click_handler: ?HandlerRef,
    background: Color,
    hover_background: Color,
    border_color: Color,
    text_color: Color,
    font_size: u16,
    corner_radius: f32,
    padding: f32,
    disabled: bool,

    pub fn render(self: SelectTrigger, b: *ui.Builder) void {
        const opacity: f32 = if (self.disabled) 0.6 else 1.0;

        b.box(.{
            .fill_width = true,
            .height = @as(f32, @floatFromInt(self.font_size)) + self.padding * 2 + 4,
            .padding = .{ .symmetric = .{ .x = self.padding, .y = self.padding / 2 } },
            .background = self.background.withAlpha(opacity),
            .hover_background = self.hover_background.withAlpha(opacity),
            .border_color = self.border_color,
            .border_width = 1,
            .corner_radius = self.corner_radius,
            .direction = .row,
            .alignment = .{ .main = .space_between, .cross = .center },
            .on_click_handler = self.on_click_handler,
        }, .{
            // Selected text
            ui.text(self.text, .{
                .color = self.text_color.withAlpha(opacity),
                .size = self.font_size,
            }),
            // Dropdown arrow
            ChevronIcon{
                .is_open = self.is_open,
                .color = self.text_color.withAlpha(opacity),
                .size = 10,
            },
        });
    }
};

/// Chevron indicator that rotates when open
const ChevronIcon = struct {
    is_open: bool,
    color: Color,
    size: f32,

    pub fn render(self: ChevronIcon, b: *ui.Builder) void {
        // Simple text-based chevron (could be replaced with SVG)
        const arrow = if (self.is_open) "▲" else "▼";
        b.box(.{}, .{
            ui.text(arrow, .{
                .color = self.color,
                .size = @intFromFloat(self.size),
            }),
        });
    }
};

/// The floating dropdown menu containing options
const SelectDropdown = struct {
    is_open: bool,
    options: []const []const u8,
    selected: ?usize,
    handlers: ?[]const HandlerRef,
    on_close_handler: ?HandlerRef,
    min_width: ?f32,
    background: Color,
    selected_background: Color,
    hover_background: Color,
    text_color: Color,
    font_size: u16,
    corner_radius: f32,
    padding: f32,

    pub fn render(self: SelectDropdown, b: *ui.Builder) void {
        if (!self.is_open) return;

        b.box(.{
            .width = self.min_width,
            .padding = .{ .all = 4 },
            .background = self.background,
            .border_color = Color.rgb(0.85, 0.85, 0.85),
            .border_width = 1,
            .corner_radius = self.corner_radius,
            .direction = .column,
            .gap = 2,
            .shadow = .{
                .blur_radius = 12,
                .offset_y = 4,
                .color = Color.rgba(0, 0, 0, 0.15),
            },
            .floating = ui.Floating.dropdown(),
            .on_click_outside_handler = self.on_close_handler,
        }, .{
            SelectOptions{
                .options = self.options,
                .selected = self.selected,
                .handlers = self.handlers,
                .selected_background = self.selected_background,
                .hover_background = self.hover_background,
                .text_color = self.text_color,
                .font_size = self.font_size,
                .corner_radius = self.corner_radius - 2,
                .padding = self.padding,
            },
        });
    }
};

/// Renders all option items
const SelectOptions = struct {
    options: []const []const u8,
    selected: ?usize,
    handlers: ?[]const HandlerRef,
    selected_background: Color,
    hover_background: Color,
    text_color: Color,
    font_size: u16,
    corner_radius: f32,
    padding: f32,

    pub fn render(self: SelectOptions, b: *ui.Builder) void {
        for (self.options, 0..) |label, i| {
            const handler: ?HandlerRef = if (self.handlers) |h|
                (if (i < h.len) h[i] else null)
            else
                null;

            const is_selected = if (self.selected) |sel| sel == i else false;

            b.with(SelectOption{
                .label = label,
                .is_selected = is_selected,
                .on_click_handler = handler,
                .selected_background = self.selected_background,
                .hover_background = self.hover_background,
                .text_color = self.text_color,
                .font_size = self.font_size,
                .corner_radius = self.corner_radius,
                .padding = self.padding,
            });
        }
    }
};

/// A single option in the dropdown
const SelectOption = struct {
    label: []const u8,
    is_selected: bool,
    on_click_handler: ?HandlerRef,
    selected_background: Color,
    hover_background: Color,
    text_color: Color,
    font_size: u16,
    corner_radius: f32,
    padding: f32,

    pub fn render(self: SelectOption, b: *ui.Builder) void {
        const bg = if (self.is_selected) self.selected_background else Color.transparent;

        b.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = self.padding, .y = self.padding * 0.7 } },
            .background = bg,
            .hover_background = self.hover_background,
            .corner_radius = self.corner_radius,
            .direction = .row,
            .alignment = .{ .cross = .center },
            .gap = 8,
            .on_click_handler = self.on_click_handler,
        }, .{
            // Checkmark for selected item
            SelectCheckmark{
                .visible = self.is_selected,
                .color = Color.rgb(0.2, 0.5, 1.0),
            },
            // Option text
            ui.text(self.label, .{
                .color = self.text_color,
                .size = self.font_size,
            }),
        });
    }
};

/// Checkmark indicator for selected option
const SelectCheckmark = struct {
    visible: bool,
    color: Color,

    pub fn render(self: SelectCheckmark, b: *ui.Builder) void {
        if (self.visible) {
            b.box(.{
                .width = 16,
            }, .{
                ui.text("✓", .{
                    .color = self.color,
                    .size = 14,
                }),
            });
        } else {
            // Empty space to maintain alignment
            b.box(.{
                .width = 16,
            }, .{});
        }
    }
};
