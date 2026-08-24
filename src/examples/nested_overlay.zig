//! Nested floating overlay regression example.
//!
//! The modal (z=1000) and its nested Select dropdown (z=100) start open.
//! The dropdown should paint above the modal content. If floating z-indexes
//! replace inherited values, the modal paints over the dropdown instead.

const gooey = @import("gooey");
const std = @import("std");

pub const std_options = gooey.std_options;

const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Modal = gooey.components.Modal;
const Select = gooey.components.Select;

const options = [_][]const u8{ "Alpha", "Bravo", "Charlie" };

const AppState = struct {
    selected: ?usize = null,
    select_open: bool = true,

    pub fn toggleSelect(self: *AppState) void {
        std.debug.assert(options.len > 0);
        std.debug.assert(options.len <= 4096);
        self.select_open = !self.select_open;
    }

    pub fn selectOption(self: *AppState, index: usize) void {
        std.debug.assert(index < options.len);
        std.debug.assert(options.len == 3);
        self.selected = index;
    }
};

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Nested Overlay Z-Index Repro",
    .width = 700,
    .height = 500,
});

comptime {
    _ = App;
}

pub fn main(init: std.process.Init) !void {
    if (platform.is_wasm) unreachable;
    return App.main(init);
}

fn render(cx: *Cx) void {
    const size = cx.windowSize();
    std.debug.assert(size.width > 0);
    std.debug.assert(size.height > 0);

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = ui.Color.rgb(0.15, 0.24, 0.38),
        .alignment = .{ .main = .center, .cross = .center },
    }, .{
        ui.text("Background content", .{ .size = 28, .color = ui.Color.white }),
        Modal(ModalContent){
            .id = "nested-overlay-modal",
            .is_open = true,
            .animate = false,
            .close_on_backdrop = false,
            .content_max_width = 360,
            .child = ModalContent{},
        },
    }));
}

const ModalContent = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const app_state = cx.state(AppState);
        std.debug.assert(options.len > 0);
        if (app_state.selected) |index| std.debug.assert(index < options.len);

        cx.render(ui.box(.{
            .width = 312,
            .direction = .column,
            .gap = 16,
        }, .{
            ui.text("Modal with nested Select", .{ .size = 22 }),
            ui.text("The open dropdown should be visible above this modal.", .{
                .size = 14,
                .color = ui.Color.rgb(0.35, 0.35, 0.4),
                .wrap = .words,
            }),
            Select{
                .id = "nested-select",
                .options = &options,
                .selected = app_state.selected,
                .is_open = app_state.select_open,
                .on_select = cx.onSelect(AppState.selectOption),
                // Supplying a toggle handler selects the controlled mode so
                // this repro can launch with the dropdown already open.
                .on_toggle = cx.update(AppState.toggleSelect),
                .width = 280,
            },
            ui.box(.{
                .fill_width = true,
                .height = 120,
                .background = ui.Color.rgb(1.0, 0.93, 0.72),
                .padding = .{ .all = 16 },
                .corner_radius = 8,
            }, .{
                ui.text("Expected: Alpha / Bravo / Charlie overlay this yellow area.", .{
                    .size = 14,
                    .wrap = .words,
                }),
            }),
        }));
    }
};
