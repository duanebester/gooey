//! Nested overlay regression example, on the core.
//!
//! The modal and its nested Select's menu start open. The menu must paint
//! above the modal and take clicks over it: a layer opened inside a modal
//! comes after the modal's fragment (contract §6). In 0.3.1, floating
//! z-indexes that replaced inherited values painted the modal over the menu.

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const core = gooey.core;
const ui = core.ui;
const Cx = core.Cx;
const Handler = core.Handler;
const Modal = components.core.Modal;
const Select = components.core.Select;

const assert = std.debug.assert;

pub const options = [_][]const u8{ "Alpha", "Bravo", "Charlie" };

pub const State = struct {
    selected: ?usize = null,
    select_open: bool = true,

    pub fn toggleSelect(self: *State) void {
        self.select_open = !self.select_open;
    }

    pub fn selectOption(self: *State, index: u32) void {
        assert(index < options.len);
        self.selected = index;
        self.select_open = false;
        assert(self.selected.? == index);
    }

    pub fn closeSelect(self: *State) void {
        self.select_open = false;
        assert(!self.select_open);
    }
};

pub const App = core.App(State, render, .{
    .title = "Nested Overlay Z-Index Repro",
    .width = 700,
    .height = 500,
    .limits = .small,
});

/// The generated entry point (contract §7).
pub const main = App.main;

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .background = .{ .rgba = .rgb(0.15, 0.24, 0.38) },
        .alignment = .center,
    } }, .{
        ui.text("Background content", .{ .size = 28, .color = .{ .rgba = .white } }),
        Modal(ModalContent){
            .key = "nested-overlay-modal",
            .open = true,
            .close_on_backdrop = false,
            .content_max_width = 360,
            .child = .{},
        },
    }));
}

const ModalContent = struct {
    pub fn render(_: ModalContent, cx: *Cx) void {
        const state = cx.state(State);
        if (state.selected) |index| assert(index < options.len);
        var on_select: [options.len]Handler = undefined;
        for (&on_select, 0..) |*handler, index| {
            handler.* = cx.on(State.selectOption, .{ .arg = @as(u32, @intCast(index)) });
        }
        cx.render(ui.box(.{ .style = .{ .width = .{ .fixed = 312 }, .gap = 16 } }, .{
            ui.text("Modal with nested Select", .{ .size = 22 }),
            ui.text("The open dropdown should be visible above this modal.", .{
                .size = 14,
                .color = .{ .rgba = .rgb(0.35, 0.35, 0.4) },
                .wrap = .words,
            }),
            Select{
                .key = "nested-select",
                .options = &options,
                .on_select = &on_select,
                .on_toggle = cx.on(State.toggleSelect, .{}),
                .on_close = cx.on(State.closeSelect, .{}),
                .selected = state.selected,
                .open = state.select_open,
                .width = 280,
            },
            // Keyed, so the menu covering it has a modal record beneath.
            ui.box(.{ .key = .{ .name = "expected-area" }, .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .fixed = 120 },
                .background = .{ .rgba = .rgb(1.0, 0.93, 0.72) },
                .padding = .all(16),
                .corner_radius = .all(8),
            } }, .{
                ui.text("Expected: Alpha / Bravo / Charlie overlay this yellow area.", .{
                    .size = 14,
                    .wrap = .words,
                }),
            }),
        }));
    }
};
