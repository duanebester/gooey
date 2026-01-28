//! Dynamic Counters Example (Cx API)
//!
//! Demonstrates:
//! - Pure state methods with cx.update() for simple mutations
//! - Command methods with cx.command() when entity ops needed
//! - Dynamic entity creation and deletion
//! - Entity-scoped operations with cx.entityCx()
//! - Auto-cleanup when entities are removed

const std = @import("std");
const builtin = @import("builtin");
const gooey = @import("gooey");
const platform = gooey.platform;

/// WASM-compatible logging - redirect std.log to console.log via JS imports
pub const std_options: std.Options = if (builtin.os.tag == .freestanding)
    .{ .logFn = gooey.wasmLogFn }
else
    .{};
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;

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

    // =========================================================================
    // Command methods - use with cx.command() (need Gooey access)
    // =========================================================================

    pub fn addCounter(self: *AppState, g: *gooey.Gooey) void {
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

        const counter = g.createEntity(Counter, .{ .count = 0, .label = label }) catch return;
        self.counters[self.counter_count] = counter;
        self.counter_count += 1;
        self.next_label += 1;
    }

    pub fn removeCounter(self: *AppState, g: *gooey.Gooey) void {
        if (self.counter_count == 0) return;

        self.counter_count -= 1;
        const entity = self.counters[self.counter_count];
        g.getEntities().remove(entity.id);
        self.next_label -= 1;
    }

    // =========================================================================
    // Helper methods (no context needed)
    // =========================================================================

    fn countersSlice(self: *const AppState) []const gooey.Entity(Counter) {
        return self.counters[0..self.counter_count];
    }
};

// =============================================================================
// Components - Now receive *Cx directly!
// =============================================================================

/// Individual counter card - uses pure methods via EntityContext
const CounterCard = struct {
    counter: gooey.Entity(Counter),

    pub fn render(self: @This(), cx: *Cx) void {
        const g = cx.gooey();
        const data = g.readEntity(Counter, self.counter) orelse return;

        cx.render(ui.box(.{
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
            CounterButtons{ .counter = self.counter },
        }));
    }
};

const CounterButtons = struct {
    counter: gooey.Entity(Counter),

    pub fn render(self: @This(), cx: *Cx) void {
        var entity_cx = cx.entityCx(Counter, self.counter) orelse return;

        var dec_id_buf: [32]u8 = undefined;
        var inc_id_buf: [32]u8 = undefined;
        const dec_id = std.fmt.bufPrint(&dec_id_buf, "dec_{d}", .{self.counter.id.id}) catch "-";
        const inc_id = std.fmt.bufPrint(&inc_id_buf, "inc_{d}", .{self.counter.id.id}) catch "+";

        cx.render(ui.hstack(.{ .gap = 8 }, .{
            Button{ .id = dec_id, .label = "-", .size = .small, .on_click_handler = entity_cx.update(Counter.decrement) },
            Button{ .id = inc_id, .label = "+", .size = .small, .on_click_handler = entity_cx.update(Counter.increment) },
        }));
    }
};

/// Shows total of all counters
const TotalDisplay = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);
        const g = cx.gooey();

        var total: i32 = 0;
        for (s.countersSlice()) |counter_entity| {
            if (g.readEntity(Counter, counter_entity)) |counter| {
                total += counter.count;
            }
        }

        cx.render(ui.box(.{
            .padding = .{ .all = 16 },
            .background = ui.Color.rgb(0.2, 0.6, 0.9),
            .corner_radius = 8,
        }, .{
            ui.textFmt("Total: {}", .{total}, .{ .size = 24, .color = ui.Color.white }),
        }));
    }
};

/// Control buttons - uses command() because addCounter needs entity creation
const ControlPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        cx.render(ui.hstack(.{ .gap = 12, .alignment = .center }, .{
            // These need command() because they create/remove entities
            Button{ .label = "+ Add Counter", .on_click_handler = cx.command(AppState, AppState.addCounter) },
            Button{ .label = "- Remove Counter", .variant = .secondary, .on_click_handler = cx.command(AppState, AppState.removeCounter) },
            ui.textFmt("({}/10)", .{s.countersSlice().len}, .{ .size = 14, .color = ui.Color.rgb(0.5, 0.5, 0.5) }),
        }));
    }
};

/// Grid of counter cards
const CounterGrid = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.hstack(.{ .gap = 12 }, .{
            CounterItems{},
        }));
    }
};

const CounterItems = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(AppState);

        for (s.countersSlice()) |counter_entity| {
            cx.render(ui.box(.{}, .{
                CounterCard{ .counter = counter_entity },
            }));
        }
    }
};

// =============================================================================
// Entry Point
// =============================================================================

var app_state = AppState{};

const App = gooey.App(AppState, &app_state, render, .{
    .title = "Dynamic Counters",
    .width = 600,
    .height = 400,
});

// Force type analysis - triggers @export on WASM
comptime {
    _ = App;
}

// Native entry point
pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

fn render(cx: *Cx) void {
    const size = cx.windowSize();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = ui.Color.rgb(0.95, 0.95, 0.95),
        .padding = .{ .all = 24 },
        .gap = 24,
        .direction = .column,
    }, .{
        ui.text("Dynamic Counters", .{ .size = 24 }),
        ui.text("Pure state: Counter.increment/decrement use entity cx.update()", .{ .size = 14, .color = ui.Color.rgb(0.5, 0.5, 0.5) }),

        ControlPanel{},
        CounterGrid{},
        TotalDisplay{},
    }));
}

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
