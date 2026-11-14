//! Splitter: resizable panes on `Box.on_pointer_drag` (contract §5).
//!
//! A sidebar of a fixed width beside a content pane that grows, divided by
//! a 6 px splitter, as a terminal multiplexer or an editor's file tree
//! lays out. The content pane splits again, top and bottom, by grow weights
//! that sum to 1, so the split keeps its proportion as the window resizes.
//! Each splitter keeps the size it had at the press, so a drag
//! moves it by the pointer's distance from the press and Escape restores it.
//! Each is also focusable: the arrow keys move it, Shift by more, and Home
//! and End go to its ends; screen readers read its position as a range.

const std = @import("std");
const gooey = @import("gooey");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Effects = gooey.Effects;
const input = gooey.input;

pub const sidebar_width_min: f32 = 120;
pub const sidebar_width_max: f32 = 480;
/// The smallest share of the content pane either half keeps.
pub const share_min: f32 = 0.1;
pub const splitter_size: f32 = 6;
/// Arrow-key steps, in points, and with Shift.
pub const step_small: f32 = 16;
pub const step_large: f32 = 64;

pub const State = struct {
    sidebar_width: f32 = 240,
    /// The top pane's share of the content pane's height, 0 to 1.
    top_share: f32 = 0.6,
    /// The value each splitter had at its press.
    sidebar_width_start: f32 = 240,
    top_share_start: f32 = 0.6,

    pub fn resizeSidebar(self: *State, effects: *Effects) void {
        const drag = effects.pointerDrag().?;
        // Splitters answer the primary button only, as native ones do.
        if (drag.button != .left) return;
        switch (drag.phase) {
            .begin => self.sidebar_width_start = self.sidebar_width,
            .move, .end => self.sidebar_width = clampWidth(
                self.sidebar_width_start + (drag.x - drag.start_x),
            ),
            .cancel => self.sidebar_width = self.sidebar_width_start,
        }
        assert(self.sidebar_width >= sidebar_width_min);
        assert(self.sidebar_width <= sidebar_width_max);
    }

    /// `content` is the pane the top and bottom panes share, whose height
    /// turns the pointer's distance into a share.
    pub fn resizeTop(self: *State, content: gooey.ElementId, effects: *Effects) void {
        const drag = effects.pointerDrag().?;
        if (drag.button != .left) return;
        switch (drag.phase) {
            .begin => self.top_share_start = self.top_share,
            .move, .end => {
                // A pane not on screen leaves the share as it is.
                const content_bounds = effects.bounds(content) orelse return;
                // The weights share the pane's height less the splitter.
                const free = content_bounds.height - splitter_size;
                if (free <= 0) return;
                const moved = (drag.y - drag.start_y) / free;
                self.top_share = clampShare(self.top_share_start + moved);
            },
            .cancel => self.top_share = self.top_share_start,
        }
        assert(self.top_share >= share_min);
        assert(self.top_share <= 1 - share_min);
    }

    pub fn sidebarKey(self: *State, effects: *Effects) void {
        const key = keyDown(effects) orelse return;
        const step: f32 = if (key.modifiers.shift) step_large else step_small;
        const width = switch (key.key) {
            .left => self.sidebar_width - step,
            .right => self.sidebar_width + step,
            .home => sidebar_width_min,
            .end => sidebar_width_max,
            else => return,
        };
        self.sidebar_width = clampWidth(width);
        effects.stopPropagation();
    }

    pub fn topKey(self: *State, effects: *Effects) void {
        const key = keyDown(effects) orelse return;
        const step: f32 = if (key.modifiers.shift) 0.2 else 0.05;
        const share = switch (key.key) {
            .up => self.top_share - step,
            .down => self.top_share + step,
            .home => share_min,
            .end => 1 - share_min,
            else => return,
        };
        self.top_share = clampShare(share);
        effects.stopPropagation();
    }
};

const assert = std.debug.assert;

fn keyDown(effects: *const Effects) ?input.KeyEvent {
    const event = effects.inputEvent() orelse return null;
    if (event.* != .key_down) return null;
    return event.key_down;
}

fn clampWidth(width: f32) f32 {
    assert(std.math.isFinite(width));
    return std.math.clamp(width, sidebar_width_min, sidebar_width_max);
}

fn clampShare(share: f32) f32 {
    assert(std.math.isFinite(share));
    return std.math.clamp(share, share_min, 1 - share_min);
}

pub const App = gooey.App(State, render, .{
    .title = "Splitter",
    .width = 900,
    .height = 600,
    .limits = .nano,
});

/// The generated entry point (contract §7).
pub const main = App.main;

const pane: ui.Style = .{
    .width = .{ .grow = 1 },
    .height = .{ .grow = 1 },
    .padding = .all(16),
    .gap = 8,
};

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    var sidebar = pane;
    sidebar.width = .{ .fixed = s.sidebar_width };
    sidebar.background = .surface;
    var content = pane;
    content.padding = .zero;
    // No gap, so the weights share exactly the height the splitter leaves.
    content.gap = 0;
    var top = pane;
    top.height = .{ .grow = s.top_share };
    var bottom = pane;
    bottom.background = .surface;
    bottom.height = .{ .grow = 1 - s.top_share };
    // Keyed from the root down, so a handler can find the content pane.
    const content_id = cx.id(.{ .name = "panes" }).child(.{ .name = "content" });
    cx.render(ui.box(.{ .key = .{ .name = "panes" }, .style = .{
        .direction = .row,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .background = .bg,
    } }, .{
        // Each pane is a group, so a screen reader finds the panes on
        // either side of a splitter (VoiceOver's previous and next contents).
        ui.box(.{ .style = sidebar, .a11y = .{ .role = .group, .label = "Sidebar" } }, .{
            ui.text("Sidebar", .{ .size = 18 }),
            ui.text("Drag the bar on the right, or focus it and use the arrow keys.", .{
                .wrap = .words,
                .color = .subtext,
            }),
        }),
        Splitter{
            .key = "sidebar splitter",
            .label = "Resize sidebar",
            .range = .{
                .min = sidebar_width_min,
                .max = sidebar_width_max,
                .now = s.sidebar_width,
                .orientation = .vertical,
            },
            .on_drag = cx.on(State.resizeSidebar, .{}),
            .on_key = cx.on(State.sidebarKey, .{}),
        },
        ui.box(.{
            .key = .{ .name = "content" },
            .style = content,
            .a11y = .{ .role = .group, .label = "Content" },
        }, .{
            ui.box(.{ .style = top, .a11y = .{ .role = .group, .label = "Top" } }, .{
                ui.text("Top", .{ .size = 18 }),
            }),
            Splitter{
                .key = "top splitter",
                .label = "Resize top pane",
                .range = .{
                    .min = share_min,
                    .max = 1 - share_min,
                    .now = s.top_share,
                    .orientation = .horizontal,
                },
                .on_drag = cx.on(State.resizeTop, .{ .arg = content_id }),
                .on_key = cx.on(State.topKey, .{}),
            },
            ui.box(.{ .style = bottom, .a11y = .{ .role = .group, .label = "Bottom" } }, .{
                ui.text("Bottom", .{ .size = 18 }),
            }),
        }),
    }));
}

/// A focusable divider. A `vertical` one, by its range's orientation, sits
/// between columns and moves left and right; a `horizontal` one sits
/// between rows.
const Splitter = struct {
    key: []const u8,
    label: []const u8,
    range: ui.A11y.Range,
    on_drag: gooey.Handler,
    on_key: gooey.Handler,

    pub fn render(self: Splitter, cx: *Cx) void {
        const id = cx.id(.{ .name = self.key });
        const lit = cx.hovered(id) or cx.focused(id);
        var style: ui.Style = .{ .background = if (lit) .primary else .border };
        switch (self.range.orientation) {
            .vertical => {
                style.width = .{ .fixed = splitter_size };
                style.height = .{ .grow = 1 };
                style.cursor = .resize_left_right;
            },
            .horizontal => {
                style.width = .{ .grow = 1 };
                style.height = .{ .fixed = splitter_size };
                style.cursor = .resize_up_down;
            },
        }
        cx.render(ui.box(.{
            .key = .{ .name = self.key },
            .style = style,
            .focusable = true,
            .on_pointer_drag = self.on_drag,
            .on_key = self.on_key,
            .a11y = .{ .role = .separator, .label = self.label, .range = self.range },
        }, .{}));
    }
};
