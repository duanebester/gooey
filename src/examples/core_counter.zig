//! Counter on the 0.4.0 core (milestone 1).
//!
//! A port of `counter.zig` written against the core contract: `ui.box`,
//! `ui.text`, `cx.on`, and components that render through `cx.render`. The
//! layout and colours match the 0.3.1 counter, so its golden can be compared
//! with the 0.3.1 golden (`src/testing/goldens/`).

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const core = gooey.core;
const ui = core.ui;
const Cx = core.Cx;
const Effects = core.Effects;
const Button = components.core.Button;

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

pub const App = core.App(State, render, .{
    .title = "Counter",
    .width = 500,
    .height = 350,
    .limits = .nano,
    .theme = &core.Theme.light,
    .keymap = &.{},
    .entities = &.{},
    .on_init = null,
});

/// The generated entry point (contract §7).
pub const main = App.main;

const background = ui.Color.rgb(0.95, 0.95, 0.95);

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(32),
        .gap = 20,
        .background = .{ .rgba = background },
    } }, .{
        ui.text("Counter (Cx API)", .{ .size = 24, .color = .{ .rgba = .rgb(0.2, 0.2, 0.2) } }),
        CounterDisplay{},
        ControlButtons{},
        StepSelector{},
        ui.when(s.message.len > 0, message),
    }));
}

fn message(cx: *Cx) void {
    const s = cx.state(State);
    cx.render(ui.text(s.message, .{ .size = 14, .color = .{ .rgba = .rgb(0.3, 0.6, 0.3) } }));
}

const row: ui.Style = .{ .direction = .row, .gap = 12, .alignment = .center_cross };

const CounterDisplay = struct {
    pub fn render(_: CounterDisplay, cx: *Cx) void {
        const s = cx.state(State);
        var digits: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&digits, "{d}", .{s.count}) catch unreachable;
        const color = if (s.count >= 0) ui.Color.rgb(
            0.2,
            0.5,
            0.8,
        ) else ui.Color.rgb(0.8, 0.3, 0.3);
        cx.render(ui.box(.{ .style = .{
            .padding = .all(24),
            .background = .{ .rgba = ui.Color.white },
            .corner_radius = .all(12),
            .alignment = .center,
        } }, .{
            ui.text(count, .{ .size = 64, .color = .{ .rgba = color } }),
        }));
    }
};

const ControlButtons = struct {
    pub fn render(_: ControlButtons, cx: *Cx) void {
        cx.render(ui.box(.{ .style = row }, .{
            Button{ .label = "\u{2212}", .size = .large, .on_click = cx.on(State.decrement, .{}) },
            Button{ .label = "+", .size = .large, .on_click = cx.on(State.increment, .{}) },
            ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } } }, .{}),
            Button{ .label = "Reset", .variant = .secondary, .on_click = cx.on(State.reset, .{}) },
            Button{
                .label = "Reset & Blur",
                .variant = .danger,
                .on_click = cx.on(State.resetAndBlur, .{}),
            },
        }));
    }
};

const StepSelector = struct {
    pub fn render(_: StepSelector, cx: *Cx) void {
        const s = cx.state(State);
        cx.render(ui.box(.{
            .style = .{ .direction = .row, .gap = 8, .alignment = .center_cross },
        }, .{
            ui.text("Step:", .{ .size = 14, .color = .{ .rgba = .rgb(0.5, 0.5, 0.5) } }),
            StepButton{ .value = 1, .current = s.step },
            StepButton{ .value = 5, .current = s.step },
            StepButton{ .value = 10, .current = s.step },
        }));
    }
};

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
