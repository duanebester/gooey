//! Checkbox Component
//!
//! A toggleable checkbox built on Box.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.

const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const Theme = ui.Theme;
const Box = ui.Box;
const HandlerRef = ui.HandlerRef;

pub const Checkbox = struct {
    id: []const u8,
    checked: bool,
    label: ?[]const u8 = null,

    // For simple toggle callback (no bool arg, just toggles)
    on_click: ?*const fn () void = null,
    on_click_handler: ?HandlerRef = null,

    // Styling (null = use theme)
    size: f32 = 18,
    checked_background: ?Color = null,
    unchecked_background: ?Color = null,
    border_color: ?Color = null,
    checkmark_color: ?Color = null,
    label_color: ?Color = null,
    corner_radius: ?f32 = null,

    pub fn render(self: Checkbox, b: *ui.Builder) void {
        const t = b.theme();

        // Resolve colors: explicit value OR theme default
        const checked_bg = self.checked_background orelse t.primary;
        const unchecked_bg = self.unchecked_background orelse t.surface;
        const border = self.border_color orelse t.border;
        const checkmark = self.checkmark_color orelse Color.white;
        const label_col = self.label_color orelse t.text;
        const radius = self.corner_radius orelse t.radius_sm;

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
                .checked_background = checked_bg,
                .unchecked_background = unchecked_bg,
                .border_color = border,
                .checkmark_color = checkmark,
                .corner_radius = radius,
            },
            CheckboxLabel{
                .label = self.label,
                .color = label_col,
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
    corner_radius: f32,

    pub fn render(self: CheckboxBox, b: *ui.Builder) void {
        b.box(.{
            .width = self.size,
            .height = self.size,
            .background = if (self.checked) self.checked_background else self.unchecked_background,
            .border_color = self.border_color,
            .border_width = 1,
            .corner_radius = self.corner_radius,
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
