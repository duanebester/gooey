//! Tooltip Component
//!
//! A tooltip that appears on hover over a trigger element.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.
//!
//! Usage:
//! ```zig
//! Tooltip(Button){
//!     .text = "Click to save your changes",
//!     .child = Button{ .label = "Save" },
//! }
//! ```
//!
//! With positioning:
//! ```zig
//! Tooltip(HelpIcon){
//!     .text = "This field is required",
//!     .child = HelpIcon{},
//!     .position = .right,
//! }
//! ```

const ui = @import("../ui/mod.zig");
const layout_mod = @import("../layout/layout.zig");
const Color = ui.Color;
const Theme = ui.Theme;
const LayoutId = layout_mod.LayoutId;

/// Creates a Tooltip component that wraps a child element.
/// The tooltip appears when the user hovers over the child.
pub fn Tooltip(comptime ChildType: type) type {
    return struct {
        /// The tooltip text to display
        text: []const u8,

        /// The child element that triggers the tooltip on hover
        child: ChildType,

        /// Unique identifier (defaults to text content)
        id: ?[]const u8 = null,

        /// Position of the tooltip relative to the trigger
        position: Position = .top,

        /// Maximum width before text wraps
        max_width: ?f32 = 250,

        // === Styling (null = use theme) ===

        /// Background color of the tooltip
        background: ?Color = null,

        /// Text color
        text_color: ?Color = null,

        /// Font size
        font_size: u16 = 13,

        /// Padding inside the tooltip
        padding: f32 = 8,

        /// Corner radius (null = use theme)
        corner_radius: ?f32 = null,

        /// Gap between trigger and tooltip
        gap: f32 = 6,

        pub const Position = enum {
            top,
            bottom,
            left,
            right,
        };

        const Self = @This();

        pub fn render(self: Self, b: *ui.Builder) void {
            const t = b.theme();

            // Resolve colors: explicit value OR theme default
            // Tooltips typically use overlay/inverted colors
            const background = self.background orelse t.overlay;
            const text_col = self.text_color orelse t.text;
            const radius = self.corner_radius orelse t.radius_md;

            // Use provided ID or derive from text
            const id = self.id orelse self.text;
            const layout_id = LayoutId.fromString(id);

            // Check if this tooltip's hover area OR any descendant is hovered
            const is_hovered = if (b.getGooey()) |g|
                g.isHoveredOrDescendant(layout_id.id)
            else
                false;

            // HoverArea contains both the child and the tooltip popup.
            // This ensures the floating popup's parent IS the hover area,
            // so attach_to_parent positions correctly relative to the trigger.
            b.boxWithId(id, .{}, .{
                self.child,
                // Tooltip popup (only visible when hovered)
                TooltipPopup{
                    .text = self.text,
                    .visible = is_hovered,
                    .position = self.position,
                    .max_width = self.max_width,
                    .background = background,
                    .text_color = text_col,
                    .font_size = self.font_size,
                    .padding = self.padding,
                    .corner_radius = radius,
                    .gap = self.gap,
                },
            });
        }
    };
}

/// Internal component that renders the floating tooltip content
const TooltipPopup = struct {
    text: []const u8,
    visible: bool,
    position: Tooltip(void).Position,
    max_width: ?f32,
    background: Color,
    text_color: Color,
    font_size: u16,
    padding: f32,
    corner_radius: f32,
    gap: f32,

    pub fn render(self: TooltipPopup, b: *ui.Builder) void {
        if (!self.visible) return;

        b.box(.{
            .max_width = self.max_width,
            .padding = .{ .symmetric = .{ .x = self.padding, .y = self.padding * 0.75 } },
            .background = self.background,
            .corner_radius = self.corner_radius,
            .shadow = .{
                .blur_radius = 8,
                .offset_y = 2,
                .color = Color.rgba(0, 0, 0, 0.25),
            },
            .floating = self.floatingConfig(),
        }, .{
            ui.text(self.text, .{
                .color = self.text_color,
                .size = self.font_size,
                .wrap = .words,
            }),
        });
    }

    fn floatingConfig(self: TooltipPopup) ui.Floating {
        return switch (self.position) {
            .top => .{
                .element_anchor = .center_bottom,
                .parent_anchor = .center_top,
                .offset_y = -self.gap,
            },
            .bottom => .{
                .element_anchor = .center_top,
                .parent_anchor = .center_bottom,
                .offset_y = self.gap,
            },
            .left => .{
                .element_anchor = .right_center,
                .parent_anchor = .left_center,
                .offset_x = -self.gap,
            },
            .right => .{
                .element_anchor = .left_center,
                .parent_anchor = .right_center,
                .offset_x = self.gap,
            },
        };
    }
};
