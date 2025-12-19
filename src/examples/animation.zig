//! Animation Demo - Shows various animation features including animateOn
const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = ui.Color;
const Easing = gooey.Easing;
const Button = gooey.Button;

const AppState = struct {
    count: i32 = 0,
    show_panel: bool = true,

    pub fn increment(self: *AppState) void {
        self.count += 1;
    }

    pub fn decrement(self: *AppState) void {
        self.count -= 1;
    }

    pub fn togglePanel(self: *AppState) void {
        self.show_panel = !self.show_panel;
    }
};

fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    const size = cx.windowSize();

    // Fade in the entire UI on load
    const fade_in = cx.animate("main-fade", .{ .duration_ms = 500 });

    cx.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 32 },
        .direction = .column,
        .gap = 24,
        .background = Color.rgb(0.95, 0.95, 0.95).withAlpha(fade_in.progress),
    }, .{
        // Title
        ui.text("Animation Demo", .{
            .size = 28,
            .color = Color.rgb(0.2, 0.2, 0.2).withAlpha(fade_in.progress),
        }),

        // Counter with pulse on change - NOW USING animateOn!
        CounterDisplay{ .count = s.count },

        // Control buttons
        ControlButtons{},

        // Animated panel (uses animateOn for show state)
        PanelSection{ .show = s.show_panel },

        // Loading spinner (continuous animation)
        LoadingSpinner{},
    });
}

const ControlButtons = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        cx.hstack(.{ .gap = 12, .alignment = .center }, .{
            Button{ .label = "-", .size = .large, .on_click_handler = cx.update(AppState, AppState.decrement) },
            Button{ .label = "+", .size = .large, .on_click_handler = cx.update(AppState, AppState.increment) },
            Button{
                .label = if (s.show_panel) "Hide" else "Show",
                .on_click_handler = cx.update(AppState, AppState.togglePanel),
            },
        });
    }
};

const CounterDisplay = struct {
    count: i32,

    pub fn render(self: @This(), cx: *Cx) void {
        // NEW: Using animateOn - automatically restarts when count changes!
        // No more manual ID formatting with embedded values
        const pulse = cx.animateOn("count-pulse", self.count, .{
            .duration_ms = 200,
            .easing = Easing.easeOutBack,
        });

        // Scale effect: starts big, settles to normal
        const scale = 1.0 + (1.0 - pulse.progress) * 0.15;

        cx.box(.{
            .width = 120 * scale,
            .height = 80 * scale,
            .background = Color.white,
            .corner_radius = 12,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.textFmt("{d}", .{self.count}, .{
                .size = 48,
                .color = if (self.count >= 0) Color.rgb(0.2, 0.5, 0.8) else Color.rgb(0.8, 0.3, 0.3),
            }),
        });
    }
};

const PanelSection = struct {
    show: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        // NEW: Using animateOn with a boolean trigger!
        // Animation restarts each time show_panel toggles to true
        const slide = cx.animateOn("panel-slide", self.show, .{
            .duration_ms = 400,
            .easing = Easing.easeOutCubic,
        });

        // Only render when visible or animating
        if (self.show or slide.running) {
            // When hiding, we want reverse progress
            const progress = if (self.show) slide.progress else 1.0 - slide.progress;

            cx.box(.{
                .width = 300,
                .height = 100,
                .padding = .{ .all = 16 },
                .background = Color.rgba(0.2, 0.5, 1.0, progress),
                .corner_radius = 8,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                ui.text("Animated Panel!", .{
                    .size = 18,
                    .color = Color.white.withAlpha(progress),
                }),
            });
        }
    }
};

const LoadingSpinner = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const pulse = cx.animate("spinner", .{
            .duration_ms = 1000,
            .easing = Easing.easeInOut,
            .mode = .ping_pong,
        });

        cx.hstack(.{ .gap = 8, .alignment = .center }, .{
            ui.text("Loading:", .{ .size = 14, .color = Color.rgb(0.5, 0.5, 0.5) }),
            SpinnerBall{ .progress = pulse.progress },
        });
    }
};

const SpinnerBall = struct {
    progress: f32,

    pub fn render(self: @This(), cx: *Cx) void {
        const spinner_size = gooey.lerp(30.0, 40.0, self.progress);
        const opacity = gooey.lerp(0.4, 1.0, self.progress);

        cx.box(.{
            .width = spinner_size,
            .height = spinner_size,
            .background = Color.rgba(0.3, 0.6, 1.0, opacity),
            .corner_radius = spinner_size / 2,
        }, .{});
    }
};

var state = AppState{};

pub fn main() !void {
    try gooey.runCx(AppState, &state, render, .{
        .title = "Animation Demo",
        .width = 500,
        .height = 450,
    });
}
