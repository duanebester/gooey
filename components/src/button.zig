//! Button Component
//!
//! A clickable button built on Box. Supports variants and sizes; `on_click`
//! takes a `Handler` built with `cx.on`.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.

const std = @import("std");
const assert = std.debug.assert;
const gooey = @import("gooey");
const ui = gooey.ui;
const Color = ui.Color;
const Theme = ui.Theme;
const Box = ui.Box;
const Handler = ui.Handler;

pub const Button = struct {
    label: []const u8,
    id: ?[]const u8 = null,
    variant: Variant = .primary,

    // Named `size_preset` (not `size`) because bare `size` means an f32
    // pixel dimension everywhere else (Checkbox/RadioButton/Image/Svg);
    // reusing it here for a .small/.medium/.large enum overloaded one name
    // with two meanings (rule 9). The qualifier comes last per convention.
    size_preset: SizePreset = .medium,

    // `disabled: bool = false` is the house polarity for interactivity
    // (TextInput/Select/MenuItem, and a11y `State.disabled` all use it), so
    // the resting state of every widget is spelled the same way: all-defaults
    // means"interactive".
    disabled: bool = false,

    on_click: ?Handler = null,

    // Optional color overrides (null = use theme-based variant colors)
    background: ?Color = null,
    hover_background: ?Color = null,
    text_color: ?Color = null,
    corner_radius: ?f32 = null,

    // Accessibility overrides
    accessible_name: ?[]const u8 = null, // Override label for screen readers
    accessible_description: ?[]const u8 = null,

    pub const Variant = enum {
        primary,
        secondary,
        danger,
    };

    pub const SizePreset = enum {
        small,
        medium,
        large,

        fn padding(self: SizePreset) Box.PaddingValue {
            return switch (self) {
                .small => .{ .symmetric = .{ .x = 12, .y = 6 } },
                .medium => .{ .symmetric = .{ .x = 24, .y = 10 } },
                .large => .{ .symmetric = .{ .x = 32, .y = 14 } },
            };
        }

        fn fontSize(self: SizePreset, base: u16) u16 {
            return switch (self) {
                .small => base -| 2,
                .medium => base,
                .large => base + 2,
            };
        }
    };

    pub fn render(self: Button, cx: *ui.Cx) void {
        const t = cx.theme();

        // Get theme-based colors for variant
        const variant_colors = self.getVariantColors(t);

        // Resolve colors: explicit override OR variant default
        const bg = self.background orelse variant_colors.bg;
        const hover_bg = self.hover_background orelse variant_colors.hover;
        const fg = self.text_color orelse variant_colors.fg;
        const radius = self.corner_radius orelse t.radius_md;

        // Apply disabled state
        const final_bg = if (self.disabled) bg.withAlpha(0.5) else bg;
        const final_hover = if (self.disabled) null else hover_bg;
        const final_fg = if (self.disabled) fg.withAlpha(0.7) else fg;

        // Disabled buttons do not click.
        const on_click = if (self.disabled) null else self.on_click;

        // Resolve identity once. An explicit id hashes through `idFor`; a
        // null id falls back to the parent-scoped auto id rather than the
        // label, because a label-derived id would make two same-label
        // buttons collide and share hover/press state. Positional auto-ids
        // keep sibling buttons distinct.
        const layout_id = cx.idFor(self.id);

        // Push accessible element (role: button)
        const a11y_pushed = cx.accessible(.{
            .layout_id = layout_id,
            .role = .button,
            .name = self.accessible_name orelse self.label,
            .description = self.accessible_description,
            .state = .{
                .disabled = self.disabled,
            },
        });
        defer if (a11y_pushed) cx.accessibleEnd();

        cx.render(ui.box_with_layout_id(layout_id, .{
            .padding = self.size_preset.padding(),
            .background = final_bg,
            .hover_background = final_hover,
            .corner_radius = radius,
            .alignment = .{ .main = .center, .cross = .center },
            .on_click = on_click,
        }, .{
            ui.text(self.label, .{
                .color = final_fg,
                .size = self.size_preset.fontSize(t.font_size_base),
            }),
        }));
    }

    fn getVariantColors(self: Button, t: *const Theme) struct { bg: Color, hover: Color, fg: Color } {
        return switch (self.variant) {
            .primary => .{
                .bg = t.primary,
                .hover = t.primary.withAlpha(0.85),
                .fg = Color.white,
            },
            .secondary => .{
                .bg = t.secondary,
                .hover = t.secondary.withAlpha(0.85),
                .fg = t.text,
            },
            .danger => .{
                .bg = t.danger,
                .hover = t.danger.withAlpha(0.85),
                .fg = Color.white,
            },
        };
    }
};
