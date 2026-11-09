//! Layout: a header with a floating dropdown menu over a content card, on
//! the core.
//!
//! The menu is a `.popover` layer anchored 4 px below its trigger, as 0.3.1's
//! `Floating.dropdown()` placed it. A click outside the trigger and menu
//! closes it, and so does Escape, through a keymap action. The layout,
//! colours, and text match the 0.3.1 example.

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const core = gooey.core;
const ui = core.ui;
const Cx = core.Cx;
const Key = core.Key;
const Color = ui.Color;
const Button = components.core.Button;

const assert = std.debug.assert;

const CloseMenu = struct {};

pub const State = struct {
    show_dropdown: bool = false,

    pub fn toggleDropdown(self: *State) void {
        self.show_dropdown = !self.show_dropdown;
    }

    pub fn closeDropdown(self: *State) void {
        self.show_dropdown = false;
        assert(!self.show_dropdown);
    }
};

pub const App = core.App(State, render, .{
    .title = "Floating Dropdown Test",
    .width = 600,
    .height = 400,
    .limits = .nano,
    .keymap = &.{.{ .keys = "escape", .action = ui.action(CloseMenu) }},
});

/// The generated entry point (contract §7).
pub const main = App.main;

/// The gap between the trigger and the menu, from `Floating.dropdown()`.
const menu_gap: f32 = 4;
const menu_width: f32 = 160;
/// The core `Button`'s medium vertical padding, top plus bottom.
const button_padding_vertical: f32 = 20;

const text_dark: Color = .rgb(0.2, 0.2, 0.2);
const text_bullet: Color = .rgb(0.4, 0.4, 0.4);
const text_muted: Color = .rgb(0.5, 0.5, 0.5);
const hover_gray: Color = .rgb(0.95, 0.95, 0.95);
const divider_gray: Color = .rgb(0.9, 0.9, 0.9);

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{
        .actions = &.{.{
            .action = ui.action(CloseMenu),
            .handler = cx.on(State.closeDropdown, .{}),
        }},
        .style = .{
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .background = .{ .rgba = .rgb(0.95, 0.95, 0.95) },
            .padding = .all(20),
            .gap = 20,
        },
    }, .{
        Header{},
        ContentArea{},
    }));
}

const Header = struct {
    pub fn render(_: Header, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .padding = .all(16),
            .background = .{ .rgba = .white },
            .corner_radius = .all(8),
            .direction = .row,
            .alignment = .{ .main = .space_between, .cross = .center },
        } }, .{
            ui.text("Floating Dropdown Test", .{ .size = 24 }),
            DropdownTrigger{},
        }));
    }
};

/// The button and, while open, the menu it anchors. The click-outside
/// handler sits on their shared box, so pressing the button while the menu
/// is open toggles it closed instead of closing and reopening it.
const DropdownTrigger = struct {
    pub fn render(_: DropdownTrigger, cx: *Cx) void {
        const s = cx.state(State);
        const metrics = cx.fontMetrics();
        assert(metrics.point_size > 0);
        // The button's label is one line at the base size.
        const font_size: f32 = @floatFromInt(cx.theme().font_size_base);
        const label_height = metrics.line_height * font_size / metrics.point_size;
        const button_height = label_height + button_padding_vertical;
        assert(button_height > button_padding_vertical);
        cx.render(ui.box(.{
            .key = .{ .name = "dropdown" },
            .on_click_outside = if (s.show_dropdown) cx.on(State.closeDropdown, .{}) else null,
        }, .{
            Button{
                .key = "menu",
                .label = if (s.show_dropdown) "Close ▲" else "Menu ▼",
                .on_click = cx.on(State.toggleDropdown, .{}),
            },
            if (s.show_dropdown) DropdownMenu{ .offset_y = button_height + menu_gap } else null,
        }));
    }
};

const DropdownMenu = struct {
    offset_y: f32,

    pub fn render(self: DropdownMenu, cx: *Cx) void {
        assert(self.offset_y > menu_gap);
        cx.render(ui.box(.{
            .layer = .{
                .kind = .popover,
                .anchor = .{ .parent = .{ .y = self.offset_y } },
                .clip = .escape,
            },
            .style = .{
                .width = .{ .fixed = menu_width },
                .padding = .all(8),
                .background = .{ .rgba = .white },
                .corner_radius = .all(8),
                .gap = 2,
                .shadow = .{ .blur = 12, .offset_y = 4 },
            },
        }, .{
            MenuItem{ .label = "Profile" },
            MenuItem{ .label = "Settings" },
            MenuItem{ .label = "Help" },
            MenuDivider{},
            MenuItem{ .label = "Logout" },
        }));
    }
};

const MenuItem = struct {
    label: []const u8,

    pub fn render(self: MenuItem, cx: *Cx) void {
        assert(self.label.len > 0);
        const key = Key{ .name = self.label };
        const hovered = cx.hovered(cx.id(key));
        cx.render(ui.box(.{
            .key = key,
            .style = .{
                .width = .{ .grow = 1 },
                .padding = .symmetric(12, 8),
                .corner_radius = .all(4),
                .background = .{ .rgba = if (hovered) hover_gray else .white },
            },
        }, .{
            ui.text(self.label, .{ .size = 14, .color = .{ .rgba = text_dark } }),
        }));
    }
};

const MenuDivider = struct {
    pub fn render(_: MenuDivider, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .height = .{ .fixed = 1 },
            .background = .{ .rgba = divider_gray },
        } }, .{}));
    }
};

const bullets = [_][]const u8{
    "Appear below the button",
    "Have a white background",
    "Show a subtle shadow",
    "Not gray out other content",
    "Close when clicking outside",
    "Close with Escape key",
};

const ContentArea = struct {
    pub fn render(_: ContentArea, cx: *Cx) void {
        var points: [bullets.len]BulletPoint = undefined;
        for (&points, bullets) |*point, text| point.* = .{ .text = text };
        cx.render(ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .all(20),
            .background = .{ .rgba = .white },
            .corner_radius = .all(8),
            .gap = 16,
        } }, .{
            ui.text("Content Area", .{ .size = 20 }),
            ui.text("Click the Menu button above to toggle the dropdown.", .{
                .size = 14,
                .color = .{ .rgba = text_muted },
            }),
            ui.text("The dropdown should:", .{
                .size = 14,
                .color = .{ .rgba = .rgb(0.3, 0.3, 0.3) },
            }),
            points,
        }));
    }
};

const BulletPoint = struct {
    text: []const u8,

    pub fn render(self: BulletPoint, cx: *Cx) void {
        assert(self.text.len > 0);
        cx.render(ui.box(.{ .style = .{ .direction = .row, .gap = 8 } }, .{
            ui.text("•", .{ .size = 14, .color = .{ .rgba = text_bullet } }),
            ui.text(self.text, .{ .size = 14, .color = .{ .rgba = text_bullet } }),
        }));
    }
};
