//! Checkbox Component
//!
//! A toggleable checkbox built on Box.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.

const std = @import("std");
const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const Theme = ui.Theme;
const Box = ui.Box;
const HandlerRef = ui.HandlerRef;
const Svg = @import("svg.zig").Svg;
const Icons = @import("svg.zig").Icons;

pub const Checkbox = struct {
    // PR 11b.2b — presentational components require no id. When null, the
    // box gets a stable parent-scoped auto id (PR 11b.2a). Pass an explicit
    // id only when you need to address this checkbox from outside its render.
    id: ?[]const u8 = null,
    checked: bool,
    label: ?[]const u8 = null,

    // For simple toggle callback (no bool arg, just toggles) - one or the
    // other, never both (enforced in `render`). As with Button, the
    // `_handler` suffix is retained on `on_click_handler` because the base
    // name `on_click` is already taken by the stateless variant above it.
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
    font_size: ?u16 = null,

    // Accessibility overrides
    accessible_name: ?[]const u8 = null, // Override label for screen readers
    accessible_description: ?[]const u8 = null,

    pub fn render(self: Checkbox, cx: *ui.Cx) void {
        // Enforce the "one or the other" contract documented on the fields.
        // The row box below forwards both click paths unconditionally, so a
        // caller that set both would wire up two competing handlers; assert
        // the invariant here where debug builds can still catch it.
        if (self.on_click != null) std.debug.assert(self.on_click_handler == null);
        if (self.on_click_handler != null) std.debug.assert(self.on_click == null);

        const t = cx.theme();

        // Resolve font size: explicit override OR theme base
        const font_size = self.font_size orelse t.font_size_base;
        std.debug.assert(font_size > 0);

        // Resolve colors: explicit value OR theme default
        const checked_bg = self.checked_background orelse t.primary;
        const unchecked_bg = self.unchecked_background orelse t.surface;
        const border = self.border_color orelse t.border;
        const checkmark = self.checkmark_color orelse Color.white;
        const label_col = self.label_color orelse t.text;
        const radius = self.corner_radius orelse t.radius_sm;

        const layout_id = cx.idFor(self.id);

        // Push accessible element (role: checkbox)
        const a11y_pushed = cx.accessible(.{
            .layout_id = layout_id,
            .role = .checkbox,
            .name = self.accessible_name orelse self.label orelse self.id,
            .description = self.accessible_description,
            .state = .{
                .checked = self.checked,
            },
        });
        defer if (a11y_pushed) cx.accessibleEnd();

        // Outer container - clickable row
        cx.boxWithLayoutId(layout_id, .{
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
                .font_size = font_size,
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

    pub fn render(self: CheckboxBox, cx: *ui.Cx) void {
        cx.box(.{
            .width = self.size,
            .height = self.size,
            .background = if (self.checked) self.checked_background else self.unchecked_background,
            .border_color = self.border_color,
            .border_width = .{ .all = 1 },
            .corner_radius = self.corner_radius,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            Checkmark{ .visible = self.checked, .color = self.checkmark_color, .size = self.size },
        });
    }
};

const Checkmark = struct {
    visible: bool,
    color: Color,
    size: f32,

    pub fn render(self: Checkmark, cx: *ui.Cx) void {
        if (self.visible) {
            cx.box(.{
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                Svg{ .path = Icons.check, .size = self.size * 0.7, .color = self.color },
            });
        }
    }
};

const CheckboxLabel = struct {
    label: ?[]const u8,
    color: Color,
    font_size: u16,

    pub fn render(self: CheckboxLabel, cx: *ui.Cx) void {
        if (self.label) |lbl| {
            cx.box(.{}, .{
                ui.text(lbl, .{ .color = self.color, .size = self.font_size }),
            });
        }
    }
};
