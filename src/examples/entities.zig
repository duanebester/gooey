//! Entity System Example - GPUI-style shared state
//!
//! Demonstrates:
//! - Entity(T) as lightweight handles
//! - EntityContext for typed operations
//! - Observer pattern (views auto-update when models change)
//! - Multiple views sharing the same model

const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;

// =============================================================================
// Models (Entities without render - shared state)
// =============================================================================

/// A shared counter model that multiple views can observe
const Counter = struct {
    count: i32 = 0,
    label: []const u8 = "Counter",

    pub fn increment(self: *Counter, cx: *gooey.EntityContext(Counter)) void {
        self.count += 1;
        cx.notify();
    }

    pub fn decrement(self: *Counter, cx: *gooey.EntityContext(Counter)) void {
        self.count -= 1;
        cx.notify();
    }

    pub fn reset(self: *Counter, cx: *gooey.EntityContext(Counter)) void {
        self.count = 0;
        cx.notify();
    }
};

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    // Store entity handles - lightweight IDs, not the data itself
    counter1: gooey.Entity(Counter),
    counter2: gooey.Entity(Counter),
    initialized: bool = false,
};

var g_state: *AppState = undefined;
var g_gooey: *gooey.Gooey = undefined;

// =============================================================================
// Components
// =============================================================================

/// A view that displays and controls a counter
const CounterCard = struct {
    counter: gooey.Entity(Counter),
    color: ui.Color,

    pub fn render(self: @This(), b: *ui.Builder) void {
        // Read the counter data from the entity map
        const data = g_gooey.readEntity(Counter, self.counter) orelse return;

        b.box(.{
            .padding = .{ .all = 20 },
            .gap = 12,
            .background = self.color,
            .corner_radius = 8,
            .direction = .column,
            .min_width = 180,
        }, .{
            ui.text(data.label, .{ .size = 16, .color = ui.Color.rgb(0.3, 0.3, 0.3) }),
            ui.textFmt("{}", .{data.count}, .{ .size = 36 }),

            // Buttons - using the counter's entity handle
            CounterButtons{ .counter = self.counter },
        });
    }
};

/// Button row for a counter
const CounterButtons = struct {
    counter: gooey.Entity(Counter),

    pub fn render(self: @This(), b: *ui.Builder) void {
        // Create an EntityContext to get handlers
        var cx = gooey.EntityContext(Counter){
            .gooey = g_gooey,
            .entities = g_gooey.getEntities(),
            .entity_id = self.counter.id,
        };

        b.hstack(.{ .gap = 8 }, .{
            ui.buttonHandler("-", cx.handler(Counter.decrement)),
            ui.buttonHandler("+", cx.handler(Counter.increment)),
            ui.buttonHandler("Reset", cx.handler(Counter.reset)),
        });
    }
};

/// Shows the sum of all counters
const TotalDisplay = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const c1 = g_gooey.readEntity(Counter, g_state.counter1);
        const c2 = g_gooey.readEntity(Counter, g_state.counter2);

        const total = (if (c1) |c| c.count else 0) + (if (c2) |c| c.count else 0);

        b.box(.{
            .padding = .{ .all = 16 },
            .background = ui.Color.rgb(0.2, 0.2, 0.25),
            .corner_radius = 8,
        }, .{
            ui.textFmt("Total: {}", .{total}, .{ .size = 20, .color = ui.Color.white }),
        });
    }
};

/// Main layout
const MainCard = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .padding = .{ .all = 32 },
            .gap = 24,
            .background = ui.Color.white,
            .corner_radius = 12,
            .direction = .column,
            .shadow = .{ .blur_radius = 20, .color = ui.Color.rgba(0, 0, 0, 0.1) },
        }, .{
            ui.text("Entity System Demo", .{ .size = 24 }),
            ui.text("Multiple views sharing the same model state", .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.5),
            }),

            // Two counter cards showing independent counters
            b.hstack(.{ .gap = 16 }, .{
                CounterCard{ .counter = g_state.counter1, .color = ui.Color.rgb(0.95, 0.95, 1.0) },
                CounterCard{ .counter = g_state.counter2, .color = ui.Color.rgb(1.0, 0.95, 0.95) },
            }),

            // Total display observing both counters
            TotalDisplay{},
        });
    }
};

// =============================================================================
// Entry Point
// =============================================================================

pub fn main() !void {
    var app_state = AppState{
        .counter1 = gooey.Entity(Counter).nil(),
        .counter2 = gooey.Entity(Counter).nil(),
    };
    g_state = &app_state;

    try gooey.run(.{
        .title = "Entity System Demo",
        .width = 500,
        .height = 400,
        .render = render,
    });
}

fn render(g: *gooey.UI) void {
    g_gooey = g.gooey;

    // Initialize entities on first frame
    if (!g_state.initialized) {
        g_state.initialized = true;

        // Create counter entities
        g_state.counter1 = g_gooey.createEntity(Counter, .{
            .count = 0,
            .label = "Counter A",
        }) catch gooey.Entity(Counter).nil();

        g_state.counter2 = g_gooey.createEntity(Counter, .{
            .count = 10,
            .label = "Counter B",
        }) catch gooey.Entity(Counter).nil();
    }

    const size = g.windowSize();

    g.box(.{
        .width = size.width,
        .height = size.height,
        .background = ui.Color.rgb(0.95, 0.95, 0.95),
        .alignment = .{ .main = .center, .cross = .center },
    }, .{
        MainCard{},
    });
}
