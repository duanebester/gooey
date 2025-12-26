//! Tabs Component
//!
//! A tabbed navigation component for switching between views.
//!
//! Usage with Cx (recommended):
//! ```zig
//! const tabs = [_][]const u8{ "Home", "Settings", "About" };
//! cx.box(.{ .direction = .row, .gap = 0 }, .{
//!     Tab{ .label = "Home", .is_active = s.page == 0, .on_click_handler = cx.updateWith(State, @as(u8, 0), State.setPage) },
//!     Tab{ .label = "Settings", .is_active = s.page == 1, .on_click_handler = cx.updateWith(State, @as(u8, 1), State.setPage) },
//!     Tab{ .label = "About", .is_active = s.page == 2, .on_click_handler = cx.updateWith(State, @as(u8, 2), State.setPage) },
//! });
//! ```
//!
//! Or use TabBar for simple cases with fn callback:
//! ```zig
//! TabBar{
//!     .tabs = &.{ "Home", "Settings", "About" },
//!     .active = s.current_tab,
//!     .on_change = setTab,
//! }
//! ```

const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const HandlerRef = ui.HandlerRef;

/// A single tab button. Can be used standalone or composed into a tab bar.
pub const Tab = struct {
    label: []const u8,
    is_active: bool,

    // Click handler - use with cx.updateWith() for index-based navigation
    on_click_handler: ?HandlerRef = null,

    // Styling
    style: Style = .pills,
    active_background: Color = Color.rgb(0.2, 0.5, 1.0),
    inactive_background: Color = Color.transparent,
    active_text_color: Color = Color.white,
    inactive_text_color: Color = Color.rgb(0.3, 0.3, 0.3),
    hover_background: ?Color = null,
    corner_radius: f32 = 6,
    padding_x: f32 = 16,
    padding_y: f32 = 8,
    font_size: u16 = 14,
    grow: bool = false,

    pub const Style = enum {
        /// Rounded pill-style tabs (default)
        pills,
        /// Underlined tabs
        underline,
        /// Boxed/segmented control style
        segmented,
    };

    pub fn render(self: Tab, b: *ui.Builder) void {
        const bg = if (self.is_active) self.active_background else self.inactive_background;
        const text_color = if (self.is_active) self.active_text_color else self.inactive_text_color;

        const hover_bg: ?Color = if (!self.is_active)
            self.hover_background orelse blendColors(self.inactive_background, self.active_background, 0.15)
        else
            null;

        // Style-specific adjustments
        const radius: f32 = switch (self.style) {
            .underline => 0,
            else => self.corner_radius,
        };

        const border_width: f32 = switch (self.style) {
            .underline => if (self.is_active) 2 else 0,
            else => 0,
        };

        const actual_bg: Color = switch (self.style) {
            .underline => Color.transparent,
            else => bg,
        };

        b.box(.{
            .padding = .{ .symmetric = .{ .x = self.padding_x, .y = self.padding_y } },
            .background = actual_bg,
            .hover_background = hover_bg,
            .corner_radius = radius,
            .border_width = border_width,
            .border_color = if (self.style == .underline and self.is_active) self.active_background else Color.transparent,
            .alignment = .{ .main = .center, .cross = .center },
            .grow = self.grow,
            .on_click_handler = self.on_click_handler,
        }, .{
            ui.text(self.label, .{ .color = text_color, .size = self.font_size }),
        });
    }

    /// Create a tab with common styling presets
    pub fn styled(label: []const u8, is_active: bool, handler: ?HandlerRef, style: Style) Tab {
        return .{
            .label = label,
            .is_active = is_active,
            .on_click_handler = handler,
            .style = style,
        };
    }
};

/// A tab bar container that renders multiple tabs with simple fn callback.
/// For more control (especially with Cx handlers), render Tab components directly.
pub const TabBar = struct {
    id: []const u8 = "tabs",
    tabs: []const []const u8,
    active: usize,

    // Simple callback (not for use with Cx.updateWith - use Tab directly for that)
    on_change: ?*const fn (usize) void = null,

    // Layout
    gap: f32 = 0,
    fill_width: bool = false,

    // Styling
    style: Tab.Style = .pills,
    background: Color = Color.transparent,
    active_background: Color = Color.rgb(0.2, 0.5, 1.0),
    inactive_background: Color = Color.transparent,
    active_text_color: Color = Color.white,
    inactive_text_color: Color = Color.rgb(0.3, 0.3, 0.3),
    hover_background: ?Color = null,
    corner_radius: f32 = 6,
    padding_x: f32 = 16,
    padding_y: f32 = 8,
    font_size: u16 = 14,

    pub fn render(self: TabBar, b: *ui.Builder) void {
        const container_bg = switch (self.style) {
            .segmented => Color.rgb(0.9, 0.9, 0.9),
            else => self.background,
        };

        const container_radius: f32 = switch (self.style) {
            .segmented => self.corner_radius + 2,
            else => 0,
        };

        const container_padding: ?ui.Box.PaddingValue = switch (self.style) {
            .segmented => .{ .all = 3 },
            else => null,
        };

        b.boxWithId(self.id, .{
            .direction = .row,
            .gap = self.gap,
            .background = container_bg,
            .corner_radius = container_radius,
            .padding = container_padding,
            .fill_width = self.fill_width,
            .alignment = .{ .cross = .center },
        }, .{
            TabBarItems{
                .tabs = self.tabs,
                .active = self.active,
                .on_change = self.on_change,
                .style = self.style,
                .active_background = self.active_background,
                .inactive_background = self.inactive_background,
                .active_text_color = self.active_text_color,
                .inactive_text_color = self.inactive_text_color,
                .hover_background = self.hover_background,
                .corner_radius = self.corner_radius,
                .padding_x = self.padding_x,
                .padding_y = self.padding_y,
                .font_size = self.font_size,
                .grow = self.fill_width,
            },
        });
    }
};

const TabBarItems = struct {
    tabs: []const []const u8,
    active: usize,
    on_change: ?*const fn (usize) void,
    style: Tab.Style,
    active_background: Color,
    inactive_background: Color,
    active_text_color: Color,
    inactive_text_color: Color,
    hover_background: ?Color,
    corner_radius: f32,
    padding_x: f32,
    padding_y: f32,
    font_size: u16,
    grow: bool,

    pub fn render(self: TabBarItems, b: *ui.Builder) void {
        for (self.tabs, 0..) |label, i| {
            b.with(TabBarItem{
                .label = label,
                .index = i,
                .is_active = i == self.active,
                .on_change = self.on_change,
                .style = self.style,
                .active_background = self.active_background,
                .inactive_background = self.inactive_background,
                .active_text_color = self.active_text_color,
                .inactive_text_color = self.inactive_text_color,
                .hover_background = self.hover_background,
                .corner_radius = self.corner_radius,
                .padding_x = self.padding_x,
                .padding_y = self.padding_y,
                .font_size = self.font_size,
                .grow = self.grow,
            });
        }
    }
};

const TabBarItem = struct {
    label: []const u8,
    index: usize,
    is_active: bool,
    on_change: ?*const fn (usize) void,
    style: Tab.Style,
    active_background: Color,
    inactive_background: Color,
    active_text_color: Color,
    inactive_text_color: Color,
    hover_background: ?Color,
    corner_radius: f32,
    padding_x: f32,
    padding_y: f32,
    font_size: u16,
    grow: bool,

    pub fn render(self: TabBarItem, b: *ui.Builder) void {
        const bg = if (self.is_active) self.active_background else self.inactive_background;
        const text_color = if (self.is_active) self.active_text_color else self.inactive_text_color;

        const hover_bg: ?Color = if (!self.is_active)
            self.hover_background orelse blendColors(self.inactive_background, self.active_background, 0.15)
        else
            null;

        const radius: f32 = switch (self.style) {
            .underline => 0,
            else => self.corner_radius,
        };

        const border_width: f32 = switch (self.style) {
            .underline => if (self.is_active) 2 else 0,
            else => 0,
        };

        const border_color: Color = switch (self.style) {
            .underline => if (self.is_active) self.active_background else Color.transparent,
            else => Color.transparent,
        };

        const actual_bg: Color = switch (self.style) {
            .underline => Color.transparent,
            else => bg,
        };

        // Create click callback that captures index
        const on_click: ?*const fn () void = if (self.on_change) |change_fn| blk: {
            const ClickWrapper = struct {
                var captured_index: usize = 0;
                var captured_fn: *const fn (usize) void = undefined;

                fn call() void {
                    captured_fn(captured_index);
                }
            };
            ClickWrapper.captured_index = self.index;
            ClickWrapper.captured_fn = change_fn;
            break :blk ClickWrapper.call;
        } else null;

        b.box(.{
            .padding = .{ .symmetric = .{ .x = self.padding_x, .y = self.padding_y } },
            .background = actual_bg,
            .hover_background = hover_bg,
            .corner_radius = radius,
            .border_width = border_width,
            .border_color = border_color,
            .alignment = .{ .main = .center, .cross = .center },
            .grow = self.grow,
            .on_click = on_click,
        }, .{
            ui.text(self.label, .{ .color = text_color, .size = self.font_size }),
        });
    }
};

/// Simple color blend helper
fn blendColors(a: Color, b: Color, t: f32) Color {
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
    };
}
