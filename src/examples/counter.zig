const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Effects = gooey.Effects;
const Button = components.Button;

const assert = std.debug.assert;

pub const State = struct {
    count: i32 = 0,
    step: i32 = 1,
    message: []const u8 = "",

    pub fn increment(self: *State) void {
        self.count += self.step;
    }

    pub fn decrement(self: *State) void {
        self.count -= self.step;
    }

    pub fn reset(self: *State) void {
        self.count = 0;
        self.message = "Counter reset!";
    }

    pub fn setStep(self: *State, step: i32) void {
        self.step = step;
        self.message = "";
    }

    pub fn resetAndBlur(self: *State, effects: *Effects) void {
        self.count = 0;
        self.message = "Reset and blurred!";
        effects.blur();
    }
};

pub const App = gooey.App(State, render, .{
    .title = "Counter",
    .width = 580,
    .height = 350,
    // `.embedded`, not `.nano`: it is also the EVE panel demo, and only
    // `.embedded`'s paint limits fit the chip's display list.
    .limits = .embedded,
    .theme = &gooey.Theme.catppuccin_macchiato,
});

pub const main = App.main;

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(32),
        .alignment = .center,
        .background = .bg,
    } }, .{
        ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .width_max = column_max, .gap = 20 } }, .{
            Header{},
            CounterCard{},
            Footer{},
        }),
    }));
}

const column_max: f32 = 560;

const row: ui.Style = .{
    .direction = .row,
    .width = .{ .grow = 1 },
    .gap = 8,
    .alignment = .center_cross,
};
const spacer: ui.Style = .{ .width = .{ .grow = 1 } };

const Header = struct {
    pub fn render(_: Header, cx: *Cx) void {
        const s = cx.state(State);
        cx.render(ui.box(.{ .style = row }, .{
            ui.text("Counter", .{ .size = 22, .color = .text }),
            ui.box(.{ .style = spacer }, .{}),
            ui.text("Step", .{ .size = 13, .color = .subtext }),
            StepButton{ .value = 1, .current = s.step },
            StepButton{ .value = 5, .current = s.step },
            StepButton{ .value = 10, .current = s.step },
        }));
    }
};

const CounterCard = struct {
    pub fn render(_: CounterCard, cx: *Cx) void {
        const s = cx.state(State);
        var digits: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&digits, "{d}", .{s.count}) catch unreachable;
        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .width = .{ .grow = 1 },
            .padding = .symmetric(28, 20),
            .gap = 12,
            .alignment = .center_cross,
            .background = .surface,
            .border = .{},
            .corner_radius = .all(cx.theme().radius_lg),
        } }, .{
            ui.text(count, .{ .size = 64, .color = if (s.count >= 0) .text else .danger }),
            ui.box(.{ .style = spacer }, .{}),
            Button{
                .label = "-",
                .variant = .secondary,
                .size = .large,
                .on_click = cx.on(State.decrement, .{}),
            },
            Button{ .label = "+", .size = .large, .on_click = cx.on(State.increment, .{}) },
        }));
    }
};

const Footer = struct {
    pub fn render(_: Footer, cx: *Cx) void {
        const s = cx.state(State);
        assert(s.message.len < 64);
        cx.render(ui.box(.{ .style = row }, .{
            Button{
                .label = "Reset",
                .variant = .secondary,
                .size = .small,
                .on_click = cx.on(State.reset, .{}),
            },
            Button{
                .label = "Reset & Blur",
                .variant = .danger,
                .size = .small,
                .on_click = cx.on(State.resetAndBlur, .{}),
            },
            ui.box(.{ .style = spacer }, .{}),
            ui.when(s.message.len > 0, message),
        }));
    }
};

fn message(cx: *Cx) void {
    const s = cx.state(State);
    cx.render(ui.text(s.message, .{ .size = 13, .color = .success }));
}

const StepButton = struct {
    value: i32,
    current: i32,

    pub fn render(self: StepButton, cx: *Cx) void {
        cx.render(Button{
            .label = switch (self.value) {
                1 => "1",
                5 => "5",
                10 => "10",
                else => unreachable,
            },
            .size = .small,
            .variant = if (self.value == self.current) .primary else .secondary,
            .on_click = cx.on(State.setStep, .{ .arg = self.value }),
        });
    }
};
