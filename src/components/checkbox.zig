//! Checkbox Component
//!
//! A toggleable checkbox built on Box.

const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const Box = ui.Box;
const HandlerRef = ui.HandlerRef;

pub const Checkbox = struct {
    id: []const u8,
    checked: bool,
    label: ?[]const u8 = null,

    // For simple toggle callback (no bool arg, just toggles)
    on_click: ?*const fn () void = null,
    on_click_handler: ?HandlerRef = null,

    // Styling
    size: f32 = 18,
    checked_background: Color = Color.rgb(0.2, 0.5, 1.0),
    unchecked_background: Color = Color.white,
    border_color: Color = Color.rgb(0.7, 0.7, 0.7),
    checkmark_color: Color = Color.white,
    label_color: Color = Color.rgb(0.2, 0.2, 0.2),

    pub fn render(self: Checkbox, b: *ui.Builder) void {
        // Outer container - clickable row
        b.boxWithId(self.id, .{
            .direction = .row,
            .gap = 8,
            .alignment = .{ .cross = .center },
            .on_click = self.on_click,
            .on_click_handler = self.on_click_handler,
        }, .{
            CheckboxBox{
                .checked = self.checked,
                .size = self.size,
                .checked_background = self.checked_background,
                .unchecked_background = self.unchecked_background,
                .border_color = self.border_color,
                .checkmark_color = self.checkmark_color,
            },
            CheckboxLabel{
                .label = self.label,
                .color = self.label_color,
            },
        });
    }
};

const CheckboxBox = struct {
    checked: bool,
    size: f32,
    checked_background: Color,
    unchecked_background: Color,
    border_color: Color,
    checkmark_color: Color,

    pub fn render(self: CheckboxBox, b: *ui.Builder) void {
        b.box(.{
            .width = self.size,
            .height = self.size,
            .background = if (self.checked) self.checked_background else self.unchecked_background,
            .border_color = self.border_color,
            .border_width = 1,
            .corner_radius = 4,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            Checkmark{ .visible = self.checked, .color = self.checkmark_color },
        });
    }
};

const Checkmark = struct {
    visible: bool,
    color: Color,

    pub fn render(self: Checkmark, b: *ui.Builder) void {
        if (self.visible) {
            b.box(.{}, .{
                ui.text("✓", .{ .color = self.color, .size = 12 }),
            });
        }
    }
};

const CheckboxLabel = struct {
    label: ?[]const u8,
    color: Color,

    pub fn render(self: CheckboxLabel, b: *ui.Builder) void {
        if (self.label) |lbl| {
            b.box(.{}, .{
                ui.text(lbl, .{ .color = self.color, .size = 14 }),
            });
        }
    }
};
