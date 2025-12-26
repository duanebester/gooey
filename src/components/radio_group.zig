//! Radio Button Components
//!
//! Mutually exclusive selection buttons with circular indicators.
//!
//! Usage with Cx (recommended):
//! ```zig
//! cx.box(.{ .direction = .column, .gap = 10 }, .{
//!     RadioButton{
//!         .label = "Email",
//!         .is_selected = s.contact == 0,
//!         .on_click_handler = cx.updateWith(State, @as(u8, 0), State.setContact),
//!     },
//!     RadioButton{
//!         .label = "Phone",
//!         .is_selected = s.contact == 1,
//!         .on_click_handler = cx.updateWith(State, @as(u8, 1), State.setContact),
//!     },
//! });
//! ```
//!
//! Or use RadioGroup with handler array:
//! ```zig
//! RadioGroup{
//!     .id = "contact",
//!     .options = &.{ "Email", "Phone", "Mail" },
//!     .selected = s.contact,
//!     .handlers = &.{
//!         cx.updateWith(State, @as(u8, 0), State.setContact),
//!         cx.updateWith(State, @as(u8, 1), State.setContact),
//!         cx.updateWith(State, @as(u8, 2), State.setContact),
//!     },
//! }
//! ```

const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const HandlerRef = ui.HandlerRef;

/// A single radio button. Can be used standalone or composed into groups.
pub const RadioButton = struct {
    label: []const u8,
    is_selected: bool,

    // Click handler - use with cx.updateWith() for index-based selection
    on_click_handler: ?HandlerRef = null,

    // Styling
    size: f32 = 18,
    selected_color: Color = Color.rgb(0.2, 0.5, 1.0),
    unselected_color: Color = Color.white,
    border_color: Color = Color.rgb(0.7, 0.7, 0.7),
    label_color: Color = Color.rgb(0.2, 0.2, 0.2),
    font_size: u16 = 14,
    gap: f32 = 8,

    pub fn render(self: RadioButton, b: *ui.Builder) void {
        b.box(.{
            .direction = .row,
            .gap = self.gap,
            .alignment = .{ .cross = .center },
            .on_click_handler = self.on_click_handler,
        }, .{
            RadioCircle{
                .is_selected = self.is_selected,
                .size = self.size,
                .selected_color = self.selected_color,
                .unselected_color = self.unselected_color,
                .border_color = self.border_color,
            },
            ui.text(self.label, .{ .color = self.label_color, .size = self.font_size }),
        });
    }
};

const RadioCircle = struct {
    is_selected: bool,
    size: f32,
    selected_color: Color,
    unselected_color: Color,
    border_color: Color,

    pub fn render(self: RadioCircle, b: *ui.Builder) void {
        b.box(.{
            .width = self.size,
            .height = self.size,
            .background = self.unselected_color,
            .border_color = if (self.is_selected) self.selected_color else self.border_color,
            .border_width = if (self.is_selected) 2 else 1,
            .corner_radius = self.size / 2,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            RadioDot{
                .visible = self.is_selected,
                .size = self.size * 0.5,
                .color = self.selected_color,
            },
        });
    }
};

const RadioDot = struct {
    visible: bool,
    size: f32,
    color: Color,

    pub fn render(self: RadioDot, b: *ui.Builder) void {
        if (self.visible) {
            b.box(.{
                .width = self.size,
                .height = self.size,
                .background = self.color,
                .corner_radius = self.size / 2,
            }, .{});
        }
    }
};

/// A radio group container that renders multiple radio buttons.
/// Each option needs its own handler - use cx.updateWith() to create them.
pub const RadioGroup = struct {
    id: []const u8 = "radio-group",
    options: []const []const u8,
    selected: usize,

    /// Array of handlers, one per option. Use cx.updateWith() to create these.
    /// If null or shorter than options, missing handlers are treated as no-op.
    handlers: ?[]const HandlerRef = null,

    // Layout
    direction: Direction = .column,
    gap: f32 = 10,

    // Styling
    size: f32 = 18,
    selected_color: Color = Color.rgb(0.2, 0.5, 1.0),
    unselected_color: Color = Color.white,
    border_color: Color = Color.rgb(0.7, 0.7, 0.7),
    label_color: Color = Color.rgb(0.2, 0.2, 0.2),
    font_size: u16 = 14,

    pub const Direction = enum { row, column };

    pub fn render(self: RadioGroup, b: *ui.Builder) void {
        b.boxWithId(self.id, .{
            .direction = if (self.direction == .row) .row else .column,
            .gap = self.gap,
            .alignment = .{ .cross = .start },
        }, .{
            RadioGroupItems{
                .options = self.options,
                .selected = self.selected,
                .handlers = self.handlers,
                .size = self.size,
                .selected_color = self.selected_color,
                .unselected_color = self.unselected_color,
                .border_color = self.border_color,
                .label_color = self.label_color,
                .font_size = self.font_size,
            },
        });
    }
};

const RadioGroupItems = struct {
    options: []const []const u8,
    selected: usize,
    handlers: ?[]const HandlerRef,
    size: f32,
    selected_color: Color,
    unselected_color: Color,
    border_color: Color,
    label_color: Color,
    font_size: u16,

    pub fn render(self: RadioGroupItems, b: *ui.Builder) void {
        for (self.options, 0..) |label, i| {
            const handler: ?HandlerRef = if (self.handlers) |h|
                (if (i < h.len) h[i] else null)
            else
                null;

            b.with(RadioButton{
                .label = label,
                .is_selected = i == self.selected,
                .on_click_handler = handler,
                .size = self.size,
                .selected_color = self.selected_color,
                .unselected_color = self.unselected_color,
                .border_color = self.border_color,
                .label_color = self.label_color,
                .font_size = self.font_size,
            });
        }
    }
};
