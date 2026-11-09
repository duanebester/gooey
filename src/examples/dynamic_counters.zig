//! Dynamic counters: entities on the core (contract §7, decision 17).
//!
//! - Each counter is an entity in the `Counter` pool. Its buttons bind the
//!   pure `Counter.increment` and `decrement` to it with `.entity`.
//! - `addCounter` and `removeCounter` create and remove entities through
//!   `Effects`; a removed counter's slot is freed after the drain.
//! - The layout, colours, and limits match the 0.3.1 example.

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Effects = gooey.Effects;
const Entity = gooey.Entity;
const Color = ui.Color;
const Button = components.Button;

const assert = std.debug.assert;

pub const Counter = struct {
    count: i32 = 0,
    label: []const u8 = "Counter",

    pub fn increment(self: *Counter) void {
        self.count += 1;
    }

    pub fn decrement(self: *Counter) void {
        self.count -= 1;
    }

    pub fn reset(self: *Counter) void {
        self.count = 0;
    }
};

/// Most counters at once, as in 0.3.1; the `.nano` pool holds 16.
pub const counter_count_max = 10;

const labels = [counter_count_max][]const u8{
    "Counter A", "Counter B", "Counter C", "Counter D", "Counter E",
    "Counter F", "Counter G", "Counter H", "Counter I", "Counter J",
};

pub const State = struct {
    counters: [counter_count_max]Entity(Counter) = undefined,
    counter_count: u32 = 0,

    pub fn addCounter(self: *State, effects: *Effects) void {
        assert(self.counter_count <= counter_count_max);
        if (self.counter_count == counter_count_max) return;
        const label = labels[self.counter_count];
        self.counters[self.counter_count] = effects.create(Counter, .{ .label = label });
        self.counter_count += 1;
    }

    pub fn removeCounter(self: *State, effects: *Effects) void {
        assert(self.counter_count <= counter_count_max);
        if (self.counter_count == 0) return;
        self.counter_count -= 1;
        effects.remove(Counter, self.counters[self.counter_count]);
    }

    pub fn live(self: *const State) []const Entity(Counter) {
        assert(self.counter_count <= counter_count_max);
        return self.counters[0..self.counter_count];
    }
};

pub const App = gooey.App(State, render, .{
    .title = "Dynamic Counters",
    .width = 600,
    .height = 400,
    .limits = .nano,
    .entities = &.{Counter},
});

/// The generated entry point (contract §7).
pub const main = App.main;

const muted: Color = .rgb(0.5, 0.5, 0.5);

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .background = .{ .rgba = .rgb(0.95, 0.95, 0.95) },
        .padding = .all(24),
        .gap = 24,
    } }, .{
        ui.text("Dynamic Counters", .{ .size = 24 }),
        ui.text("Pure state: Counter.increment/decrement bind to their entity with .entity", .{
            .size = 14,
            .color = .{ .rgba = muted },
        }),
        ControlPanel{},
        CounterGrid{},
        TotalDisplay{},
    }));
}

const ControlPanel = struct {
    pub fn render(_: ControlPanel, cx: *Cx) void {
        const s = cx.state(State);
        var buffer: [8]u8 = undefined;
        const count = std.fmt.bufPrint(&buffer, "({d}/10)", .{s.counter_count}) catch unreachable;
        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .gap = 12,
            .alignment = .{ .cross = .center },
        } }, .{
            Button{ .label = "+ Add Counter", .on_click = cx.on(State.addCounter, .{}) },
            Button{
                .label = "- Remove Counter",
                .variant = .secondary,
                .on_click = cx.on(State.removeCounter, .{}),
            },
            ui.text(count, .{ .size = 14, .color = .{ .rgba = muted } }),
        }));
    }
};

const CounterGrid = struct {
    pub fn render(_: CounterGrid, cx: *Cx) void {
        const s = cx.state(State);
        var cards: [counter_count_max]CounterCard = undefined;
        for (s.live(), 0..) |counter, index| cards[index] = .{ .counter = counter };
        const live: []const CounterCard = cards[0..s.counter_count];
        cx.render(ui.box(.{ .style = .{ .direction = .row, .gap = 12 } }, live));
    }
};

const CounterCard = struct {
    counter: Entity(Counter),

    pub fn render(self: CounterCard, cx: *Cx) void {
        const data = cx.get(Counter, self.counter);
        var buffer: [12]u8 = undefined;
        const count = std.fmt.bufPrint(&buffer, "{d}", .{data.count}) catch unreachable;
        // Keyed by slot and generation, so a reused slot starts fresh
        // (decision 17).
        const key: u64 = (@as(u64, self.counter.generation) << 32) | self.counter.slot;
        cx.render(ui.box(.{
            .key = .{ .index = key },
            .style = .{
                .padding = .all(16),
                .gap = 8,
                .background = .{ .rgba = .white },
                .corner_radius = .all(8),
                .width_min = 120,
                // 0.3.1's shadow defaulted to a 4 px drop.
                .shadow = .{ .blur = 8, .offset_y = 4, .color = .{ .rgba = .rgba(0, 0, 0, 0.1) } },
            },
        }, .{
            ui.text(data.label, .{ .size = 12, .color = .{ .rgba = muted } }),
            ui.text(count, .{ .size = 32 }),
            ui.box(.{ .style = .{ .direction = .row, .gap = 8 } }, .{
                Button{
                    .label = "-",
                    .size = .small,
                    .on_click = cx.on(Counter.decrement, .{ .entity = self.counter }),
                },
                Button{
                    .label = "+",
                    .size = .small,
                    .on_click = cx.on(Counter.increment, .{ .entity = self.counter }),
                },
            }),
        }));
    }
};

const TotalDisplay = struct {
    pub fn render(_: TotalDisplay, cx: *Cx) void {
        const s = cx.state(State);
        var total: i32 = 0;
        for (s.live()) |counter| total += cx.get(Counter, counter).count;
        var buffer: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "Total: {d}", .{total}) catch unreachable;
        cx.render(ui.box(.{ .style = .{
            .padding = .all(16),
            .background = .{ .rgba = .rgb(0.2, 0.6, 0.9) },
            .corner_radius = .all(8),
        } }, .{
            ui.text(text, .{ .size = 24, .color = .{ .rgba = .white } }),
        }));
    }
};

test "Counter increments, decrements, and resets" {
    var counter = Counter{};
    counter.increment();
    counter.increment();
    try std.testing.expectEqual(@as(i32, 2), counter.count);
    counter.decrement();
    try std.testing.expectEqual(@as(i32, 1), counter.count);
    counter.reset();
    try std.testing.expectEqual(@as(i32, 0), counter.count);
}
