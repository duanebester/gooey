//! Button Component
//!
//! A clickable button built on Box. Supports variants, sizes, and both
//! simple callbacks and HandlerRef for entity methods.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.

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

    // Interaction - one or the other
    on_click: ?*const fn () void = null,
    on_click_handler: ?HandlerRef = null,

    // Optional color overrides (null = use theme-based variant colors)
    background: ?Color = null,
    hover_background: ?Color = null,
    text_color: ?Color = null,
    corner_radius: ?f32 = null,

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

        fn fontSize(self: Size) u16 {
            return switch (self) {
                .small => 12,
                .medium => 14,
                .large => 16,
            };
        }
    };

    pub fn render(self: Button, b: *ui.Builder) void {
        const t = b.theme();

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

        // Use explicit ID or derive from label
        const id = self.id orelse self.label;

        b.boxWithId(id, .{
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
                .size = self.size.fontSize(),
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
