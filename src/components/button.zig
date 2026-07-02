//! Button Component
//!
//! A clickable button built on Box. Supports variants, sizes, and both
//! simple callbacks and HandlerRef for entity methods.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.

const std = @import("std");
const assert = std.debug.assert;
const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const Theme = ui.Theme;
const Box = ui.Box;
const HandlerRef = ui.HandlerRef;

pub const Button = struct {
    label: []const u8,
    id: ?[]const u8 = null,
    variant: Variant = .primary,
    size: Size = .medium,
    enabled: bool = true,

    // Interaction - one or the other, never both (enforced in `render`).
    // The stateless `on_click` callback and the state-bound `on_click_handler`
    // are mutually exclusive. Unlike the other components in this pass, the
    // `_handler` suffix is retained here because the base name `on_click` is
    // already taken by the stateless variant directly above it.
    on_click: ?*const fn () void = null,
    on_click_handler: ?HandlerRef = null,

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

    pub const Size = enum {
        small,
        medium,
        large,

        fn padding(self: Size) Box.PaddingValue {
            return switch (self) {
                .small => .{ .symmetric = .{ .x = 12, .y = 6 } },
                .medium => .{ .symmetric = .{ .x = 24, .y = 10 } },
                .large => .{ .symmetric = .{ .x = 32, .y = 14 } },
            };
        }

        fn fontSize(self: Size, base: u16) u16 {
            return switch (self) {
                .small => base -| 2,
                .medium => base,
                .large => base + 2,
            };
        }
    };

    pub fn render(self: Button, cx: *ui.Cx) void {
        // Enforce the "one or the other" contract documented on the fields.
        // `render` forwards both to the box unconditionally, so a caller that
        // set both would silently wire up two competing click paths; assert
        // the invariant here where we can still catch it in debug builds.
        if (self.on_click != null) assert(self.on_click_handler == null);
        if (self.on_click_handler != null) assert(self.on_click == null);

        const t = cx.theme();

        // Get theme-based colors for variant
        const variant_colors = self.getVariantColors(t);

        // Resolve colors: explicit override OR variant default
        const bg = self.background orelse variant_colors.bg;
        const hover_bg = self.hover_background orelse variant_colors.hover;
        const fg = self.text_color orelse variant_colors.fg;
        const radius = self.corner_radius orelse t.radius_md;

        // Apply disabled state
        const final_bg = if (self.enabled) bg else bg.withAlpha(0.5);
        const final_hover = if (self.enabled) hover_bg else null;
        const final_fg = if (self.enabled) fg else fg.withAlpha(0.7);

        // Resolve click handler
        const on_click = if (self.enabled) self.on_click else null;
        const on_click_handler = if (self.enabled) self.on_click_handler else null;

        // Resolve identity once (PR 11b.2b). An explicit id hashes through
        // `idFor`; a null id now falls back to the parent-scoped auto id
        // (PR 11b.2a) rather than the label. The old `self.id orelse
        // self.label` fallback made two same-label buttons collide and
        // share hover/press state — the exact footgun PR 11b.2 set out to
        // kill. Positional auto-ids keep sibling buttons distinct.
        const layout_id = cx.idFor(self.id);

        // Push accessible element (role: button)
        const a11y_pushed = cx.accessible(.{
            .layout_id = layout_id,
            .role = .button,
            .name = self.accessible_name orelse self.label,
            .description = self.accessible_description,
            .state = .{
                .disabled = !self.enabled,
            },
        });
        defer if (a11y_pushed) cx.accessibleEnd();

        cx.boxWithLayoutId(layout_id, .{
            .padding = self.size.padding(),
            .background = final_bg,
            .hover_background = final_hover,
            .corner_radius = radius,
            .alignment = .{ .main = .center, .cross = .center },
            .on_click = on_click,
            .on_click_handler = on_click_handler,
        }, .{
            ui.text(self.label, .{
                .color = final_fg,
                .size = self.size.fontSize(t.font_size_base),
            }),
        });
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
