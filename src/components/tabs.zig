//! Tabs Component
//!
//! A tabbed navigation component for switching between views.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.
//!
//! Usage with Cx (recommended):
//! ```zig
//! cx.render(ui.box(.{ .direction = .row, .gap = 0 }, .{
//!     Tab{ .label = "Home", .is_active = s.page == 0, .on_click_handler = cx.updateWith(State, @as(u8, 0), State.setPage) },
//!     Tab{ .label = "Settings", .is_active = s.page == 1, .on_click_handler = cx.updateWith(State, @as(u8, 1), State.setPage) },
//!     Tab{ .label = "About", .is_active = s.page == 2, .on_click_handler = cx.updateWith(State, @as(u8, 2), State.setPage) },
//! }));
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
const Theme = ui.Theme;
const HandlerRef = ui.HandlerRef;
const layout_mod = @import("../layout/layout.zig");
const LayoutId = layout_mod.LayoutId;

/// A single tab button. Can be used standalone or composed into a tab bar.
pub const Tab = struct {
    label: []const u8,
    is_active: bool,

    // Click handler - use with cx.updateWith() for index-based navigation
    on_click_handler: ?HandlerRef = null,

    // Styling (null = use theme)
    style: Style = .pills,
    active_background: ?Color = null,
    inactive_background: ?Color = null,
    active_text_color: ?Color = null,
    inactive_text_color: ?Color = null,
    hover_background: ?Color = null,
    corner_radius: ?f32 = null,
    padding_x: f32 = 16,
    padding_y: f32 = 8,
    font_size: u16 = 14,
    grow: bool = false,

    // Accessibility
    accessible_name: ?[]const u8 = null,
    pos_in_set: ?u16 = null, // 1-based position in tab list
    set_size: ?u16 = null, // Total tabs in list

    pub const Style = enum {
        /// Rounded pill-style tabs (default)
        pills,
        /// Underlined tabs
        underline,
        /// Boxed/segmented control style
        segmented,
    };

    pub fn render(self: Tab, b: *ui.Builder) void {
        const t = b.theme();

        // Resolve colors: explicit value OR theme default
        const active_bg = self.active_background orelse t.primary;
        const inactive_bg = self.inactive_background orelse Color.transparent;
        const active_text = self.active_text_color orelse Color.white;
        const inactive_text = self.inactive_text_color orelse t.text;
        const radius = self.corner_radius orelse t.radius_md;

        const layout_id = LayoutId.fromString(self.label);

        // Push accessible element (role: tab)
        const a11y_pushed = b.accessible(.{
            .layout_id = layout_id,
            .role = .tab,
            .name = self.accessible_name orelse self.label,
            .state = .{
                .selected = self.is_active,
            },
            .pos_in_set = self.pos_in_set,
            .set_size = self.set_size,
        });
        defer if (a11y_pushed) b.accessibleEnd();

        const bg = if (self.is_active) active_bg else inactive_bg;
        const text_color = if (self.is_active) active_text else inactive_text;

        const hover_bg: ?Color = if (!self.is_active)
            self.hover_background orelse blendColors(inactive_bg, active_bg, 0.15)
        else
            null;

        // Style-specific adjustments
        const style_radius: f32 = switch (self.style) {
            .underline => 0,
            else => radius,
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
            .corner_radius = style_radius,
            .border_width = border_width,
            .border_color = if (self.style == .underline and self.is_active) active_bg else Color.transparent,
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

    // Styling (null = use theme)
    style: Tab.Style = .pills,
    background: ?Color = null,
    active_background: ?Color = null,
    inactive_background: ?Color = null,
    active_text_color: ?Color = null,
    inactive_text_color: ?Color = null,
    hover_background: ?Color = null,
    corner_radius: ?f32 = null,
    padding_x: f32 = 16,
    padding_y: f32 = 8,
    font_size: u16 = 14,

    // Accessibility
    accessible_name: ?[]const u8 = null,

    pub fn render(self: TabBar, b: *ui.Builder) void {
        const t = b.theme();

        // Resolve colors: explicit value OR theme default
        const active_bg = self.active_background orelse t.primary;
        const inactive_bg = self.inactive_background orelse Color.transparent;
        const active_text = self.active_text_color orelse Color.white;
        const inactive_text = self.inactive_text_color orelse t.text;
        const radius = self.corner_radius orelse t.radius_md;
        const bg = self.background orelse Color.transparent;

        const container_bg = switch (self.style) {
            .segmented => t.muted.withAlpha(0.2),
            else => bg,
        };

        const container_radius: f32 = switch (self.style) {
            .segmented => radius + 2,
            else => 0,
        };

        const container_padding: ?ui.Box.PaddingValue = switch (self.style) {
            .segmented => .{ .all = 3 },
            else => null,
        };

        const layout_id = LayoutId.fromString(self.id);

        // Push accessible element (role: tablist)
        const a11y_pushed = b.accessible(.{
            .layout_id = layout_id,
            .role = .tablist,
            .name = self.accessible_name orelse self.id,
        });
        defer if (a11y_pushed) b.accessibleEnd();

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
                .active_background = active_bg,
                .inactive_background = inactive_bg,
                .active_text_color = active_text,
                .inactive_text_color = inactive_text,
                .hover_background = self.hover_background,
                .corner_radius = radius,
                .padding_x = self.padding_x,
                .padding_y = self.padding_y,
                .font_size = self.font_size,
                .grow = self.fill_width,
                .set_size = @intCast(self.tabs.len),
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
    set_size: u16,

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
                .pos_in_set = @intCast(i + 1), // 1-based
                .set_size = self.set_size,
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
    pos_in_set: u16,
    set_size: u16,

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

        const layout_id = LayoutId.fromString(self.label);

        // Push accessible element (role: tab)
        const a11y_pushed = b.accessible(.{
            .layout_id = layout_id,
            .role = .tab,
            .name = self.label,
            .state = .{
                .selected = self.is_active,
            },
            .pos_in_set = self.pos_in_set,
            .set_size = self.set_size,
        });
        defer if (a11y_pushed) b.accessibleEnd();

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
