const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Handler = gooey.Handler;
const Modal = components.Modal;
const Button = components.Button;
const Select = components.Select;

const assert = std.debug.assert;

pub const options = [_][]const u8{ "Alpha", "Bravo", "Charlie" };

pub const State = struct {
    selected: ?usize = null,
    dialog_open: bool = false,

    pub fn openDialog(self: *State) void {
        self.dialog_open = true;
    }

    pub fn closeDialog(self: *State) void {
        self.dialog_open = false;
    }

    pub fn selectOption(self: *State, index: u32) void {
        assert(index < options.len);
        self.selected = index;
        assert(self.selected.? == index);
    }
};

pub const App = gooey.App(State, render, .{
    .title = "Nested Overlay Z-Index Repro",
    .width = 700,
    .height = 500,
    .limits = .small,
});

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
            ui.text("Modal with nested Select", .{ .size = 22, .wrap = .words }),
            ui.text("Open the dropdown: its options should show above this modal.", .{
                .size = 14,
                .color = .{ .rgba = .rgb(0.35, 0.35, 0.4) },
                .wrap = .words,
            }),
            Select{
                .key = "nested-select",
                .options = &options,
                .on_select = &on_select,
                .selected = state.selected,
                .width = 280,
            },
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
            Button{ .label = "Open dialog", .on_click = cx.on(State.openDialog, .{}) },
            Modal(DialogContent){
                .key = "nested-dialog",
                .open = state.dialog_open,
                .on_close = cx.on(State.closeDialog, .{}),
                .content_max_width = 240,
                .child = .{},
            },
        }));
    }
};

const DialogContent = struct {
    pub fn render(_: DialogContent, cx: *Cx) void {
        assert(cx.state(State).dialog_open);
        cx.render(ui.box(.{ .style = .{ .gap = 12 } }, .{
            ui.text("A dialog over the menu", .{ .size = 16, .wrap = .words }),
            Button{ .label = "Close", .on_click = cx.on(State.closeDialog, .{}) },
        }));
    }
};
