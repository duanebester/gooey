//! Window Features Demo - Demonstrates window configuration options
//!
//! This example shows:
//! - Minimum and maximum window size constraints
//! - Centered window on startup
//! - Close callback (with confirmation dialog simulation)
//! - Resize callback (displays current window size)

const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = ui.Color;
const Button = gooey.Button;
const Size = gooey.Size;

const AppState = struct {
    window_width: f64 = 600,
    window_height: f64 = 400,
    resize_count: u32 = 0,
    close_attempts: u32 = 0,
    allow_close: bool = false,

    pub fn toggleAllowClose(self: *AppState) void {
        self.allow_close = !self.allow_close;
    }
};

var state = AppState{};

fn render(cx: *Cx) void {
    // Need cx for handlers
    _ = renderContent(cx);
}

fn renderContent(cx: *Cx) void {
    const s = cx.state(AppState);
    const size = cx.windowSize();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 32 },
        .direction = .column,
        .gap = 24,
        .alignment = .{ .main = .center, .cross = .center },
        .background = Color.rgb(0.95, 0.95, 0.95),
    }, .{
        // Title
        ui.text("Window Features Demo", .{
            .size = 28,
            .weight = .bold,
            .color = Color.rgb(0.2, 0.2, 0.25),
        }),

        // Info card
        ui.box(.{
            .padding = .{ .all = 24 },
            .corner_radius = 12,
            .background = Color.white,
            .shadow = .{
                .color = Color.black.withAlpha(0.1),
                .blur_radius = 10,
                .offset_y = 2,
            },
            .direction = .column,
            .gap = 16,
        }, .{
            // Window size info
            ui.hstack(.{ .gap = 8 }, .{
                ui.text("Current Size:", .{
                    .size = 16,
                    .weight = .semibold,
                    .color = Color.rgb(0.4, 0.4, 0.45),
                }),
                ui.textFmt("{d:.0} × {d:.0} px", .{ s.window_width, s.window_height }, .{
                    .size = 16,
                    .weight = .bold,
                    .color = Color.rgb(0.2, 0.6, 0.4),
                }),
            }),
            // Resize count
            ui.hstack(.{ .gap = 8 }, .{
                ui.text("Resize Events:", .{
                    .size = 16,
                    .weight = .semibold,
                    .color = Color.rgb(0.4, 0.4, 0.45),
                }),
                ui.textFmt("{d}", .{s.resize_count}, .{
                    .size = 16,
                    .weight = .bold,
                    .color = Color.rgb(0.3, 0.5, 0.8),
                }),
            }),
            // Close attempts
            ui.hstack(.{ .gap = 8 }, .{
                ui.text("Close Attempts:", .{
                    .size = 16,
                    .weight = .semibold,
                    .color = Color.rgb(0.4, 0.4, 0.45),
                }),
                ui.textFmt("{d}", .{s.close_attempts}, .{
                    .size = 16,
                    .weight = .bold,
                    .color = Color.rgb(0.8, 0.4, 0.3),
                }),
            }),
            // Constraints info
            ui.box(.{
                .padding = .{ .symmetric = .{ .x = 0, .y = 8 } },
                .direction = .column,
                .gap = 4,
            }, .{
                ui.text("Window Constraints:", .{
                    .size = 14,
                    .weight = .semibold,
                    .color = Color.rgb(0.5, 0.5, 0.55),
                }),
                ui.text("• Min: 400 × 300 px", .{
                    .size = 13,
                    .color = Color.rgb(0.5, 0.5, 0.55),
                }),
                ui.text("• Max: 1200 × 900 px", .{
                    .size = 13,
                    .color = Color.rgb(0.5, 0.5, 0.55),
                }),
                ui.text("• Centered on launch", .{
                    .size = 13,
                    .color = Color.rgb(0.5, 0.5, 0.55),
                }),
            }),
        }),

        // Close behavior toggle
        ui.box(.{
            .padding = .{ .all = 16 },
            .corner_radius = 8,
            .background = if (s.allow_close)
                Color.rgb(0.9, 0.95, 0.9)
            else
                Color.rgb(0.95, 0.9, 0.9),
            .direction = .row,
            .gap = 12,
            .alignment = .{ .main = .start, .cross = .center },
        }, .{
            Button{
                .label = if (s.allow_close) "Close Enabled ✓" else "Close Blocked ✗",
                .variant = if (s.allow_close) .primary else .secondary,
                .on_click_handler = cx.update(AppState.toggleAllowClose),
            },
            ui.text(
                if (s.allow_close)
                    "Window will close normally"
                else
                    "Close attempts will be blocked",
                .{
                    .size = 13,
                    .color = Color.rgb(0.4, 0.4, 0.45),
                },
            ),
        }),

        // Instructions
        ui.text("Try resizing the window or clicking the close button!", .{
            .size = 14,
            .color = Color.rgb(0.5, 0.5, 0.55),
        }),
    }));
}

fn onClose(cx: *Cx) bool {
    const s = cx.state(AppState);
    s.close_attempts += 1;

    if (s.allow_close) {
        std.debug.print("Window close allowed (attempt #{d})\n", .{s.close_attempts});
        return true; // Allow close
    } else {
        std.debug.print("Window close prevented (attempt #{d}) - toggle 'allow_close' to enable\n", .{s.close_attempts});
        return false; // Prevent close
    }
}

fn onResize(cx: *Cx, width: f64, height: f64) void {
    const s = cx.state(AppState);
    s.window_width = width;
    s.window_height = height;
    s.resize_count += 1;
    std.debug.print("Window resized to {d:.0} × {d:.0} (resize #{d})\n", .{ width, height, s.resize_count });
}

pub fn main() !void {
    try gooey.runCx(AppState, &state, render, .{
        .title = "Window Features Demo",
        .width = 600,
        .height = 400,

        // Size constraints - try resizing the window!
        .min_size = Size(f64).init(400, 300),
        .max_size = Size(f64).init(1200, 900),

        // Window starts centered on screen
        .centered = true,

        // Lifecycle callbacks
        .on_close = onClose,
        .on_resize = onResize,
    });
}
