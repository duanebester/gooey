//! Context Example (Pure State) - Demonstrates Option B pattern
//!
//! This example shows pure state methods with cx.update() for clean,
//! testable code without UI coupling in state.

const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;

// =============================================================================
// Application State (PURE - no cx, no notify!)
// =============================================================================

const Theme = enum {
    light,
    dark,

    fn background(self: Theme) ui.Color {
        return switch (self) {
            .light => ui.Color.rgb(0.95, 0.95, 0.95),
            .dark => ui.Color.rgb(0.15, 0.15, 0.17),
        };
    }

    fn card(self: Theme) ui.Color {
        return switch (self) {
            .light => ui.Color.white,
            .dark => ui.Color.rgb(0.22, 0.22, 0.25),
        };
    }

    fn text(self: Theme) ui.Color {
        return switch (self) {
            .light => ui.Color.rgb(0.1, 0.1, 0.1),
            .dark => ui.Color.rgb(0.9, 0.9, 0.9),
        };
    }
};

const AppState = struct {
    count: i32 = 0,
    theme: Theme = .light,
    name: []const u8 = "",
    initialized: bool = false,

    // Pure methods - no cx parameter, no notify()!
    pub fn increment(self: *AppState) void {
        self.count += 1;
    }

    pub fn decrement(self: *AppState) void {
        self.count -= 1;
    }

    pub fn toggleTheme(self: *AppState) void {
        self.theme = if (self.theme == .light) .dark else .light;
    }

    pub fn reset(self: *AppState) void {
        self.count = 0;
    }
};

// =============================================================================
// Components
// =============================================================================

const Greeting = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const cx = b.getContext(gooey.Context(AppState)) orelse return;
        const s = cx.state();
        if (s.name.len > 0) {
            b.box(.{}, .{
                ui.textFmt("Hello, {s}!", .{s.name}, .{ .size = 14, .color = s.theme.text() }),
            });
        }
    }
};

const CounterRow = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const cx = b.getContext(gooey.Context(AppState)) orelse return;
        const s = cx.state();
        const t = s.theme;

        b.hstack(.{ .gap = 12, .alignment = .center }, .{
            // Pure handlers with cx.update()!
            ui.buttonHandler("-", cx.update(AppState.decrement)),
            ui.textFmt("Count: {}", .{s.count}, .{ .size = 16, .color = t.text() }),
            ui.buttonHandler("+", cx.update(AppState.increment)),
        });
    }
};

const Card = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const cx = b.getContext(gooey.Context(AppState)) orelse return;
        const s = cx.state();
        const t = s.theme;

        b.box(.{
            .padding = .{ .all = 24 },
            .gap = 20,
            .background = t.card(),
            .corner_radius = 12,
            .direction = .column,
        }, .{
            ui.text("Pure State Demo", .{ .size = 20, .color = t.text() }),
            CounterRow{},
            ui.input("name", .{ .placeholder = "Enter your name", .width = 200, .bind = &s.name }),
            Greeting{},
            ui.buttonHandler(
                if (s.theme == .light) "Dark Mode" else "Light Mode",
                cx.update(AppState.toggleTheme), // Pure!
            ),
        });
    }
};

// =============================================================================
// Entry Point
// =============================================================================

pub fn main() !void {
    var app_state = AppState{};

    try gooey.runWithState(AppState, .{
        .title = "Pure State Demo",
        .width = 500,
        .height = 400,
        .state = &app_state,
        .render = render,
    });
}

fn render(cx: *gooey.Context(AppState)) void {
    const s = cx.state();
    const t = s.theme;
    const size = cx.windowSize();

    cx.box(.{
        .width = size.width,
        .height = size.height,
        .background = t.background(),
        .padding = .{ .all = 32 },
        .alignment = .{ .main = .center, .cross = .center },
    }, .{
        Card{},
    });
}
