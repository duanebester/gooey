//! Animation: tweens, spring motion, and a staggered list on the core.
//!
//! - `animation.tween` fades the window in and staggers the list rows.
//! - `animation.tweenOn` pulses the counter each time its value changes.
//! - `animation.motion` springs the panel and the list in and out, keeping
//!   the spring's velocity when a toggle interrupts it.
//! - `animation.loop` pulses a dot for as long as the pulse is on.
//!
//! The layout, colours, and timings match the 0.3.1 demo. Each helper asks
//! for the next frame only while it moves, and the loop only while it is
//! built, so the window goes idle once everything settles and the pulse is
//! off.

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const animation = gooey.animation;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = ui.Color;
const Button = components.Button;

const assert = std.debug.assert;

pub const State = struct {
    count: i32 = 0,
    show_panel: bool = true,
    show_list: bool = false,
    pulse: bool = false,

    pub fn increment(self: *State) void {
        self.count += 1;
    }

    pub fn decrement(self: *State) void {
        self.count -= 1;
    }

    pub fn togglePanel(self: *State) void {
        self.show_panel = !self.show_panel;
    }

    pub fn toggleList(self: *State) void {
        self.show_list = !self.show_list;
    }

    pub fn togglePulse(self: *State) void {
        self.pulse = !self.pulse;
    }
};

pub const App = gooey.App(State, render, .{
    .title = "Animation Demo",
    .width = 550,
    .height = 550,
    .limits = .nano,
});

/// The generated entry point (contract §7).
pub const main = App.main;

const ListItem = struct {
    name: []const u8,
    color: Color,
};

const list_items = [_]ListItem{
    .{ .name = "Apples", .color = Color.rgb(0.85, 0.25, 0.25) },
    .{ .name = "Bananas", .color = Color.rgb(0.95, 0.80, 0.20) },
    .{ .name = "Cherries", .color = Color.rgb(0.75, 0.15, 0.30) },
    .{ .name = "Dates", .color = Color.rgb(0.60, 0.40, 0.20) },
    .{ .name = "Elderberries", .color = Color.rgb(0.30, 0.20, 0.50) },
    .{ .name = "Figs", .color = Color.rgb(0.50, 0.35, 0.55) },
};

/// 0.3.1's `StaggerConfig.list`: each row starts 50 ms after the one above.
const stagger_ms: u32 = 50;
const row_tween: animation.Tween = .{ .duration_ms = 200, .easing = animation.Easing.easeOutCubic };

/// One breath of the pulsing dot.
const pulse_period_ms: u32 = 1_200;
const pulse_dot_size_max: f32 = 20;

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    const fade_in = animation.tween(cx, .{ .name = "main-fade" }, .{ .duration_ms = 500 });
    assert(fade_in >= 0);
    assert(fade_in <= 1);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(32),
        .gap = 24,
        .background = .{ .rgba = Color.rgb(0.95, 0.95, 0.95).withAlpha(fade_in) },
    } }, .{
        ui.text("Animation Demo", .{
            .size = 28,
            .color = .{ .rgba = Color.rgb(0.2, 0.2, 0.2).withAlpha(fade_in) },
        }),
        ui.box(.{ .style = .{ .direction = .row, .gap = 24, .alignment = .center_cross } }, .{
            CounterDisplay{ .count = s.count },
            Button{
                .label = if (s.pulse) "Stop Pulse" else "Start Pulse",
                .key = "pulse",
                .on_click = cx.on(State.togglePulse, .{}),
            },
            @as(?PulseDot, if (s.pulse) .{} else null),
        }),
        ControlButtons{},
        PanelSection{ .show = s.show_panel },
        ListSection{ .show = s.show_list },
    }));
}

const ControlButtons = struct {
    pub fn render(_: ControlButtons, cx: *Cx) void {
        const s = cx.state(State);
        cx.render(ui.box(.{
            .style = .{ .direction = .row, .gap = 12, .alignment = .center_cross },
        }, .{
            Button{ .label = "-", .size = .large, .on_click = cx.on(State.decrement, .{}) },
            Button{ .label = "+", .size = .large, .on_click = cx.on(State.increment, .{}) },
            Button{
                .label = if (s.show_panel) "Hide Panel" else "Show Panel",
                .key = "panel",
                .on_click = cx.on(State.togglePanel, .{}),
            },
            Button{
                .label = if (s.show_list) "Hide List" else "Show List",
                .key = "list",
                .on_click = cx.on(State.toggleList, .{}),
            },
        }));
    }
};

/// The count, pulsing larger for 200 ms each time it changes.
const CounterDisplay = struct {
    count: i32,

    pub fn render(self: CounterDisplay, cx: *Cx) void {
        const trigger: u32 = @bitCast(self.count);
        const pulse = animation.tweenOn(cx, .{ .name = "count-pulse" }, trigger, .{
            .duration_ms = 200,
            .easing = animation.Easing.easeOutBack,
        });
        assert(pulse >= 0);
        assert(pulse <= 1.5); // easeOutBack overshoots.
        const scale = 1.0 + (1.0 - pulse) * 0.15;
        var digits: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&digits, "{d}", .{self.count}) catch unreachable;
        const color = if (self.count >= 0) Color.rgb(0.2, 0.5, 0.8) else Color.rgb(0.8, 0.3, 0.3);
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = 120 * scale },
            .height = .{ .fixed = 80 * scale },
            .background = .{ .rgba = Color.white },
            .corner_radius = .all(12),
            .alignment = .center,
        } }, .{ui.text(label, .{ .size = 48, .color = .{ .rgba = color } })}));
    }
};

/// A dot that breathes while it is built: built only while the pulse is on,
/// so turning the pulse off stops its frames.
const PulseDot = struct {
    pub fn render(_: PulseDot, cx: *Cx) void {
        const phase = animation.loop(cx, .{ .name = "pulse-dot" }, pulse_period_ms);
        assert(phase >= 0);
        assert(phase < 1);
        // A cosine wave from 0 at the start of each period up to 1 and back.
        const wave = 0.5 - 0.5 * @cos(phase * 2 * std.math.pi);
        const size = pulse_dot_size_max * (0.5 + 0.5 * wave);
        // A fixed frame, so the breathing dot does not move its neighbours.
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = pulse_dot_size_max },
            .height = .{ .fixed = pulse_dot_size_max },
            .alignment = .center,
        } }, .{ui.box(.{ .style = .{
            .width = .{ .fixed = size },
            .height = .{ .fixed = size },
            .background = .{ .rgba = Color.rgb(0.2, 0.7, 0.4).withAlpha(0.4 + 0.6 * wave) },
            .corner_radius = .all(size / 2),
        } }, .{})}));
    }
};

/// A panel that springs open and closed; a toggle mid-flight reverses it
/// without a snap.
const PanelSection = struct {
    show: bool,

    pub fn render(self: PanelSection, cx: *Cx) void {
        const m = animation.motion(cx, .{ .name = "panel-spring" }, self.show, .snappy);
        assert(m.progress >= 0);
        assert(m.progress <= 1);
        if (!m.visible) return;
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = 300 },
            .height = .{ .fixed = 100 * m.progress },
            .padding = .all(16),
            .background = .{ .rgba = Color.rgba(0.2, 0.5, 1.0, m.progress) },
            .corner_radius = .all(8),
            .alignment = .center,
        } }, .{ui.text("Spring Panel!", .{
            .size = 18,
            .color = .{ .rgba = Color.white.withAlpha(m.progress) },
        })}));
    }
};

const ListSection = struct {
    show: bool,

    pub fn render(self: ListSection, cx: *Cx) void {
        const m = animation.motion(cx, .{ .name = "list-container" }, self.show, .snappy);
        assert(m.progress >= 0);
        assert(m.progress <= 1);
        if (!m.visible) return;
        // Keyed, so the rows' tweens keep their ids when the panel above
        // comes and goes.
        cx.render(ui.box(.{ .key = .{ .name = "list" }, .style = .{ .gap = 8 } }, .{
            ui.text("Staggered List", .{
                .size = 18,
                .color = .{ .rgba = Color.rgb(0.3, 0.3, 0.3).withAlpha(m.progress) },
            }),
            ListRows{ .container_progress = m.progress, .exiting = m.phase == .exiting },
        }));
    }
};

const ListRows = struct {
    container_progress: f32,
    exiting: bool,

    pub fn render(self: ListRows, cx: *Cx) void {
        var rows: [list_items.len]ListRow = undefined;
        for (&rows, 0..) |*row, index| {
            row.* = .{
                .index = @intCast(index),
                .container_progress = self.container_progress,
                .exiting = self.exiting,
            };
        }
        cx.render(ui.box(.{ .style = .{ .gap = 6 } }, rows));
    }
};

const ListRow = struct {
    index: u32,
    container_progress: f32,
    exiting: bool,

    pub fn render(self: ListRow, cx: *Cx) void {
        assert(self.index < list_items.len);
        var options = row_tween;
        options.delay_ms = self.index * stagger_ms;
        const enter = animation.tween(cx, .{ .index = self.index }, options);
        assert(enter >= 0);
        assert(enter <= 1);
        // Rows cascade in, capped by the container, and fade out in reverse.
        const alpha = if (self.exiting)
            exitAlpha(self.index, self.container_progress)
        else
            @min(enter, self.container_progress);
        const item = list_items[self.index];
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = 260 },
            .height = .{ .fixed = 36 },
            .padding = .symmetric(12, 0),
            .background = .{ .rgba = item.color.withAlpha(alpha * 0.85) },
            .corner_radius = .all(6),
            .alignment = .center,
        } }, .{ui.text(item.name, .{
            .size = 14,
            .color = .{ .rgba = Color.white.withAlpha(alpha) },
        })}));
    }
};

/// A row's alpha while the list exits: the last row fades first and the
/// first last, staggered over half the exit.
fn exitAlpha(index: u32, container_progress: f32) f32 {
    const last: u32 = list_items.len - 1;
    assert(index <= last);
    assert(container_progress >= 0);
    const spread: f32 = 0.5;
    const window = 1.0 - spread;
    const step = spread / @as(f32, @floatFromInt(last));
    const fade_start = 1.0 - @as(f32, @floatFromInt(last - index)) * step - window;
    return std.math.clamp((container_progress - fade_start) / window, 0, 1);
}
