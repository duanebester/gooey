//! Counter Example using the Cx API
//!
//! Demonstrates:
//! - Unified, non-generic Cx context
//! - Pure state methods with cx.on(method, .{})
//! - State with arguments via cx.on(method, .{ .arg = value })
//! - Methods that take *Window for framework access
//! - Components receiving *Cx
//! - WebApp for browser support

const std = @import("std");

const gooey = @import("gooey");
const components = @import("gooey-components");
const platform = gooey.platform;

/// WASM-compatible logging - redirect std.log to console.log via JS imports
pub const std_options = gooey.std_options;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = components.Button;

// =============================================================================
// Application State
// =============================================================================

/// Public so the goldens (`src/testing/goldens/`) can replay this example.
pub const AppState = struct {
    count: i32 = 0,
    step: i32 = 1,
    message: []const u8 = "",

    pub fn increment(self: *AppState) void {
        self.count += self.step;
    }

    pub fn decrement(self: *AppState) void {
        self.count -= self.step;
    }

    pub fn reset(self: *AppState) void {
        self.count = 0;
        self.message = "Counter reset!";
    }

    pub fn setStep(self: *AppState, new_step: i32) void {
        self.step = new_step;
        self.message = "";
    }

    pub fn setCount(self: *AppState, value: i32) void {
        self.count = value;
    }

    pub fn resetAndBlur(self: *AppState, g: *gooey.Window) void {
        self.count = 0;
        self.message = "Reset and blurred!";
        g.blurAll();
    }
};

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState{};

// For WASM: WebApp with @export; For Native: struct with main()
const App = gooey.App(AppState, &state, render, .{
    .limits = .nano,
    .title = "Counter",
    .width = 500,
    .height = 350,
});
pub const wasm_app = App;

// Force type analysis - triggers @export on WASM
comptime {
    _ = App;
}

// Native entry point
pub fn main(init: std.process.Init) !void {
    if (platform.is_wasm) unreachable;
    return App.main(init);
}

// =============================================================================
// Render Function - receives *Cx
// =============================================================================

pub fn render(cx: *Cx) void {
    const s = cx.state(AppState);

    cx.render(ui.root(.{
        .padding = .{ .all = 32 },
        .gap = 20,
        .direction = .column,
        .background = ui.Color.rgb(0.95, 0.95, 0.95),
    }, .{
        // Title
        ui.text("Counter (Cx API)", .{ .size = 24, .color = ui.Color.rgb(0.2, 0.2, 0.2) }),

        // Counter display
        CounterDisplay{},

        // Control buttons
        ControlButtons{},

        // Step selector
        StepSelector{},

        // Message display
        ui.when(s.message.len > 0, .{
            ui.text(s.message, .{ .size = 14, .color = ui.Color.rgb(0.3, 0.6, 0.3) }),
        }),
    }));
}

// =============================================================================
// Components - Receive *Cx directly
// =============================================================================

const CounterDisplay = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .padding = .{ .all = 24 },
            .background = ui.Color.white,
            .corner_radius = 12,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.textFmt("{}", .{s.count}, .{
                .size = 64,
                .color = if (s.count >= 0)
                    ui.Color.rgb(0.2, 0.5, 0.8)
                else
                    ui.Color.rgb(0.8, 0.3, 0.3),
            }),
        }));
    }
};

const ControlButtons = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.hstack(.{ .gap = 12, .alignment = .{ .cross = .center } }, .{
            // Pure state handlers
            Button{
                .label = "−",
                .size_preset = .large,
                .on_click = cx.on(AppState.decrement, .{}),
            },
            Button{
                .label = "+",
                .size_preset = .large,
                .on_click = cx.on(AppState.increment, .{}),
            },

            ui.spacerMin(20),

            // Pure reset
            Button{
                .label = "Reset",
                .variant = .secondary,
                .on_click = cx.on(AppState.reset, .{}),
            },

            // A method that takes *Window for framework access
            Button{
                .label = "Reset & Blur",
                .variant = .danger,
                .on_click = cx.on(AppState.resetAndBlur, .{}),
            },
        }));
    }
};

const StepSelector = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.hstack(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            ui.text("Step:", .{ .size = 14, .color = ui.Color.rgb(0.5, 0.5, 0.5) }),

            // Passing an argument with .arg
            StepButton{ .value = 1, .current = s.step },
            StepButton{ .value = 5, .current = s.step },
            StepButton{ .value = 10, .current = s.step },
        }));
    }
};

const StepButton = struct {
    value: i32,
    current: i32,

    pub fn render(self: @This(), cx: *Cx) void {
        const is_active = self.value == self.current;

        cx.render(Button{
            .label = switch (self.value) {
                1 => "1",
                5 => "5",
                10 => "10",
                else => "?",
            },
            .size_preset = .small,
            .variant = if (is_active) .primary else .secondary,
            .on_click = cx.on(AppState.setStep, .{ .arg = self.value }),
        });
    }
};

// =============================================================================
// Tests - State methods are pure and testable!
// =============================================================================

test "AppState increment/decrement" {
    var s = AppState{};

    s.increment();
    try std.testing.expectEqual(@as(i32, 1), s.count);

    s.increment();
    try std.testing.expectEqual(@as(i32, 2), s.count);

    s.decrement();
    try std.testing.expectEqual(@as(i32, 1), s.count);
}

test "AppState with custom step" {
    var s = AppState{};
    s.setStep(5);

    s.increment();
    try std.testing.expectEqual(@as(i32, 5), s.count);

    s.increment();
    try std.testing.expectEqual(@as(i32, 10), s.count);

    s.decrement();
    try std.testing.expectEqual(@as(i32, 5), s.count);
}

test "AppState reset" {
    var s = AppState{ .count = 42 };
    s.reset();

    try std.testing.expectEqual(@as(i32, 0), s.count);
    try std.testing.expect(s.message.len > 0);
}
