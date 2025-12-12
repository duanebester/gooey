//! Context Example - Demonstrates Level 2 typed state API with handlers
//!
//! This example shows how to use cx.handler() for clean event handling
//! without global variables.

const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;

// =============================================================================
// Application State
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

    fn accent(_: Theme) ui.Color {
        return ui.Color.rgb(0.3, 0.5, 1.0);
    }
};

const AppState = struct {
    count: i32 = 0,
    theme: Theme = .light,
    name: []const u8 = "",
    initialized: bool = false,

    // Methods that receive typed context - no globals needed!
    pub fn increment(self: *AppState, cx: *gooey.Context(AppState)) void {
        self.count += 1;
        cx.notify();
    }

    pub fn decrement(self: *AppState, cx: *gooey.Context(AppState)) void {
        self.count -= 1;
        cx.notify();
    }

    pub fn toggleTheme(self: *AppState, cx: *gooey.Context(AppState)) void {
        self.theme = if (self.theme == .light) .dark else .light;
        cx.notify();
    }
};

// Store handler refs as globals (created once per frame in render)
var g_cx: *gooey.Context(AppState) = undefined;

// =============================================================================
// Components
// =============================================================================

const Greeting = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const s = g_cx.state();
        if (s.name.len > 0) {
            b.box(.{}, .{
                ui.textFmt("Hello, {s}!", .{s.name}, .{ .size = 14, .color = s.theme.accent() }),
            });
        }
    }
};

const CounterRow = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const s = g_cx.state();
        const t = s.theme;

        b.hstack(.{ .gap = 12, .alignment = .center }, .{
            ui.buttonHandler("-", g_cx.handler(AppState.decrement)),
            ui.textFmt("Count: {}", .{s.count}, .{ .size = 16, .color = t.text() }),
            ui.buttonHandler("+", g_cx.handler(AppState.increment)),
        });
    }
};

const Card = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const s = g_cx.state();
        const t = s.theme;

        b.box(.{
            .padding = .{ .all = 24 },
            .gap = 20,
            .background = t.card(),
            .corner_radius = 12,
            .direction = .column,
        }, .{
            ui.text("Context Demo", .{ .size = 20, .color = t.text() }),

            // Counter with handler-based buttons
            CounterRow{},

            // Name input
            ui.input("name", .{
                .placeholder = "Enter your name",
                .width = 200,
                .bind = &s.name,
            }),

            // Greeting (conditional)
            Greeting{},

            // Theme toggle
            ui.buttonHandler(
                if (s.theme == .light) "Dark Mode" else "Light Mode",
                g_cx.handler(AppState.toggleTheme),
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
        .title = "Context Demo",
        .width = 500,
        .height = 400,
        .state = &app_state,
        .render = render,
        .on_event = onEvent,
    });
}

fn render(cx: *gooey.Context(AppState)) void {
    g_cx = cx; // Store for components to access
    const s = cx.state();
    const t = s.theme;

    // Initialize focus on first render
    if (!s.initialized) {
        s.initialized = true;
        cx.focusTextInput("name");
    }

    const size = cx.windowSize();

    // Root container with Card component
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

fn onEvent(cx: *gooey.Context(AppState), event: gooey.InputEvent) bool {
    if (event == .key_down) {
        const k = event.key_down;
        if (k.key == .escape) {
            cx.blurAll();
            return true;
        }
    }
    return false;
}
