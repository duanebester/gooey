//! Button Component
//!
//! A clickable button built on Box. Supports variants, sizes, and both
//! simple callbacks and HandlerRef for entity methods.

const ui = @import("../ui/mod.zig");
const Color = ui.Color;
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

    pub const Variant = enum {
        primary,
        secondary,
        danger,

        fn colors(self: Variant, enabled: bool) struct { bg: Color, hover: Color, fg: Color } {
            return switch (self) {
                .primary => .{
                    .bg = if (enabled) Color.rgb(0.2, 0.5, 1.0) else Color.rgb(0.5, 0.7, 1.0),
                    .hover = Color.rgb(0.3, 0.6, 1.0),
                    .fg = Color.white,
                },
                .secondary => .{
                    .bg = Color.rgb(0.9, 0.9, 0.9),
                    .hover = Color.rgb(0.82, 0.82, 0.82),
                    .fg = Color.rgb(0.3, 0.3, 0.3),
                },
                .danger => .{
                    .bg = Color.rgb(0.9, 0.3, 0.3),
                    .hover = Color.rgb(1.0, 0.4, 0.4),
                    .fg = Color.white,
                },
            };
        }
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
        const colors = self.variant.colors(self.enabled);

        // Resolve click handler
        const on_click = if (self.enabled) self.on_click else null;
        const on_click_handler = if (self.enabled) self.on_click_handler else null;

        // Use explicit ID or derive from label
        const id = self.id orelse self.label;

        b.boxWithId(id, .{
            .padding = self.size.padding(),
            .background = colors.bg,
            .hover_background = if (self.enabled) colors.hover else null,
            .corner_radius = 6,
            .alignment = .{ .main = .center, .cross = .center },
            .on_click = on_click,
            .on_click_handler = on_click_handler,
        }, .{
            ui.text(self.label, .{
                .color = colors.fg,
                .size = self.size.fontSize(),
            }),
        });
    }
};
