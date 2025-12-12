//! Dynamic Counters Example
//!
//! Demonstrates:
//! - Pure state methods with cx.update() for simple mutations
//! - Context methods with cx.handler() when entity ops needed
//! - Dynamic entity creation and deletion
//! - Auto-cleanup when entities are removed
//! - Aggregate observer (total watches all counters)

const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;

// =============================================================================
// Models
// =============================================================================

const Counter = struct {
    count: i32 = 0,
    label: []const u8 = "Counter",

    // Pure methods - no cx, no notify!
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

// =============================================================================
// Application State
// =============================================================================

const MaxCounters = 10;

const AppState = struct {
    counters: [MaxCounters]gooey.Entity(Counter) = [_]gooey.Entity(Counter){gooey.Entity(Counter).nil()} ** MaxCounters,
    counter_count: usize = 0,
    next_label: u8 = 'A',

    // These need cx because they create/remove entities
    pub fn addCounter(self: *AppState, cx: *gooey.EntityContext(AppState)) void {
        if (self.counter_count >= 10) return;

        const label: []const u8 = switch (self.next_label) {
            'A' => "Counter A",
            'B' => "Counter B",
            'C' => "Counter C",
            'D' => "Counter D",
            'E' => "Counter E",
            'F' => "Counter F",
            'G' => "Counter G",
            'H' => "Counter H",
            'I' => "Counter I",
            'J' => "Counter J",
            else => "Counter",
        };

        const counter = cx.create(Counter, .{ .count = 0, .label = label }) catch return;
        self.counters[self.counter_count] = counter;
        self.counter_count += 1;
        self.next_label += 1;
        cx.notify();
    }

    pub fn removeCounter(self: *AppState, cx: *gooey.EntityContext(AppState)) void {
        if (self.counter_count == 0) return;

        self.counter_count -= 1;
        const entity = self.counters[self.counter_count];
        cx.remove(entity.id);
        self.next_label -= 1;
        cx.notify();
    }

    fn countersSlice(self: *const AppState) []const gooey.Entity(Counter) {
        return self.counters[0..self.counter_count];
    }
};

var app_state_entity: gooey.Entity(AppState) = gooey.Entity(AppState).nil();
var initialized = false;

// =============================================================================
// Components
// =============================================================================

/// Individual counter card - uses pure methods!
const CounterCard = struct {
    counter: gooey.Entity(Counter),

    pub fn render(self: @This(), b: *ui.Builder) void {
        const data = b.readEntity(Counter, self.counter) orelse return;
        var cx = b.entityContext(Counter, self.counter) orelse return;

        b.box(.{
            .padding = .{ .all = 16 },
            .gap = 8,
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .column,
            .min_width = 120,
            .shadow = .{ .blur_radius = 8, .color = ui.Color.rgba(0, 0, 0, 0.1) },
        }, .{
            ui.text(data.label, .{ .size = 12, .color = ui.Color.rgb(0.5, 0.5, 0.5) }),
            ui.textFmt("{}", .{data.count}, .{ .size = 32 }),
            b.hstack(.{ .gap = 8 }, .{
                // Pure handlers - no cx.notify() needed!
                ui.buttonHandler("-", cx.update(Counter.decrement)),
                ui.buttonHandler("+", cx.update(Counter.increment)),
            }),
        });
    }
};

/// Shows total of all counters
const TotalDisplay = struct {
    app: gooey.Entity(AppState),

    pub fn render(self: @This(), b: *ui.Builder) void {
        const g = b.getGooey() orelse return;
        const s = g.readEntity(AppState, self.app) orelse return;

        var total: i32 = 0;
        for (s.countersSlice()) |counter_entity| {
            if (g.readEntity(Counter, counter_entity)) |counter| {
                total += counter.count;
            }
        }

        b.box(.{
            .padding = .{ .all = 16 },
            .background = ui.Color.rgb(0.2, 0.6, 0.9),
            .corner_radius = 8,
        }, .{
            ui.textFmt("Total: {}", .{total}, .{ .size = 24, .color = ui.Color.white }),
        });
    }
};

/// Control buttons - uses handler() because addCounter needs cx.create()
const ControlPanel = struct {
    app: gooey.Entity(AppState),

    pub fn render(self: @This(), b: *ui.Builder) void {
        var cx = b.entityContext(AppState, self.app) orelse return;
        const s = b.readEntity(AppState, self.app) orelse return;

        b.hstack(.{ .gap = 12, .alignment = .center }, .{
            // These need handler() because they use cx.create()/cx.remove()
            ui.buttonHandler("+ Add Counter", cx.handler(AppState.addCounter)),
            ui.buttonHandler("- Remove Counter", cx.handler(AppState.removeCounter)),
            ui.textFmt("({}/10)", .{s.countersSlice().len}, .{ .size = 14, .color = ui.Color.rgb(0.5, 0.5, 0.5) }),
        });
    }
};

// =============================================================================
// Entry Point
// =============================================================================

pub fn main() !void {
    try gooey.run(.{
        .title = "Dynamic Counters",
        .width = 600,
        .height = 400,
        .render = render,
    });
}

fn render(g: *gooey.UI) void {
    const gooey_ctx = g.gooey;

    if (!initialized) {
        initialized = true;
        app_state_entity = gooey_ctx.createEntity(AppState, .{}) catch return;
    }

    const size = g.windowSize();

    g.box(.{
        .width = size.width,
        .height = size.height,
        .background = ui.Color.rgb(0.95, 0.95, 0.95),
        .padding = .{ .all = 24 },
        .gap = 24,
        .direction = .column,
    }, .{
        ui.text("Dynamic Counters", .{ .size = 24 }),
        ui.text("Pure state: Counter.increment/decrement use cx.update()", .{ .size = 14, .color = ui.Color.rgb(0.5, 0.5, 0.5) }),

        ControlPanel{ .app = app_state_entity },
        CounterGrid{ .app = app_state_entity },
        TotalDisplay{ .app = app_state_entity },
    });
}

/// Grid of counter cards
const CounterGrid = struct {
    app: gooey.Entity(AppState),

    pub fn render(self: @This(), b: *ui.Builder) void {
        b.hstack(.{ .gap = 12 }, .{
            CounterItems{ .app = self.app },
        });
    }
};

const CounterItems = struct {
    app: gooey.Entity(AppState),

    pub fn render(self: @This(), b: *ui.Builder) void {
        const g = b.getGooey() orelse return;
        const s = g.readEntity(AppState, self.app) orelse return;

        for (s.countersSlice()) |counter_entity| {
            b.box(.{}, .{
                CounterCard{ .counter = counter_entity },
            });
        }
    }
};

// =============================================================================
// Tests - Counter is pure and testable!
// =============================================================================

test "Counter increment/decrement" {
    var c = Counter{};
    c.increment();
    c.increment();
    try std.testing.expectEqual(@as(i32, 2), c.count);

    c.decrement();
    try std.testing.expectEqual(@as(i32, 1), c.count);

    c.reset();
    try std.testing.expectEqual(@as(i32, 0), c.count);
}
