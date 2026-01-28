//! Canvas Drawing Example
//!
//! Demonstrates interactive drawing on a canvas:
//! - Click to place colored dots
//! - Access mouse position via Gooey in command handlers
//! - Convert window coordinates to canvas-local coordinates
//! - Clear button to reset the canvas

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Gooey = gooey.Gooey;
const Hsla = gooey.scene.Hsla;

// =============================================================================
// Constants
// =============================================================================

const WINDOW_WIDTH: f32 = 640;
const WINDOW_HEIGHT: f32 = 480;
const CANVAS_WIDTH: f32 = 500;
const CANVAS_HEIGHT: f32 = 320;
const DOT_RADIUS: f32 = 8;
const MAX_DOTS: usize = 512;

// =============================================================================
// Types
// =============================================================================

const Dot = struct {
    x: f32,
    y: f32,
    radius: f32,
    color: ui.Color,
};

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    dots: [MAX_DOTS]Dot = undefined,
    dot_count: usize = 0,

    // Track canvas bounds for coordinate conversion
    canvas_bounds: ?struct { x: f32, y: f32, w: f32, h: f32 } = null,

    const Self = @This();

    /// Add a dot at the current mouse position (called via command handler)
    pub fn addDotAtMouse(self: *Self, g: *Gooey) void {
        if (self.dot_count >= MAX_DOTS) return;

        const bounds = self.canvas_bounds orelse return;

        // Get mouse position from Gooey's tracked state
        const mouse_x = g.last_mouse_x;
        const mouse_y = g.last_mouse_y;

        // Convert to canvas-local coordinates
        const local_x = mouse_x - bounds.x;
        const local_y = mouse_y - bounds.y;

        // Only add if within canvas bounds
        if (local_x >= 0 and local_x <= bounds.w and
            local_y >= 0 and local_y <= bounds.h)
        {
            // Generate a color based on position (creates a nice gradient effect)
            const hue = @mod(local_x / bounds.w + local_y / bounds.h, 1.0);
            const color = Hsla.init(hue, 0.8, 0.6, 1.0).toColor();

            self.dots[self.dot_count] = .{
                .x = local_x,
                .y = local_y,
                .radius = DOT_RADIUS,
                .color = color,
            };
            self.dot_count += 1;
        }
    }

    /// Clear all dots
    pub fn clear(self: *Self) void {
        self.dot_count = 0;
    }
};

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Canvas Drawing",
    .width = WINDOW_WIDTH,
    .height = WINDOW_HEIGHT,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// =============================================================================
// Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();
    const s = cx.state(AppState);

    // Calculate canvas position (accounting for padding and title)
    // This is needed to convert mouse coordinates to canvas-local coords
    const padding: f32 = 20;
    const title_height: f32 = 30; // approximate
    const gap: f32 = 15;

    s.canvas_bounds = .{
        .x = padding,
        .y = padding + title_height + gap,
        .w = CANVAS_WIDTH,
        .h = CANVAS_HEIGHT,
    };

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = padding },
        .gap = gap,
        .direction = .column,
        .background = ui.Color.hex(0x1a1a2e),
    }, .{
        // Title
        ui.text("Canvas Drawing - Click to draw!", .{
            .size = 24,
            .color = ui.Color.white,
        }),

        // Canvas wrapped in clickable container
        ui.box(.{
            .on_click_handler = cx.command(AppState, AppState.addDotAtMouse),
        }, .{
            ui.canvas(CANVAS_WIDTH, CANVAS_HEIGHT, paintCanvas),
        }),

        // Controls row
        ui.hstack(.{ .gap = 15, .alignment = .center }, .{
            gooey.Button{
                .label = "Clear Canvas",
                .on_click_handler = cx.update(AppState, AppState.clear),
                .variant = .secondary,
            },
            ui.text("", .{}), // spacer
            ui.textFmt("Dots: {} / {}", .{ s.dot_count, MAX_DOTS }, .{
                .size = 14,
                .color = ui.Color.rgba(0.7, 0.7, 0.7, 1.0),
            }),
        }),
    }));
}

// =============================================================================
// Canvas Paint Function
// =============================================================================

fn paintCanvas(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();

    // Background with subtle gradient effect
    ctx.fillRect(0, 0, w, h, ui.Color.hex(0x16213e));

    // Draw grid lines for visual reference
    const grid_color = ui.Color.rgba(1.0, 1.0, 1.0, 0.05);
    const grid_spacing: f32 = 40;

    var x: f32 = grid_spacing;
    while (x < w) : (x += grid_spacing) {
        ctx.strokeLine(x, 0, x, h, 1, grid_color);
    }

    var y: f32 = grid_spacing;
    while (y < h) : (y += grid_spacing) {
        ctx.strokeLine(0, y, w, y, 1, grid_color);
    }

    // Draw all dots using optimized single draw call
    // pointCloudColoredArrays renders ALL points with different colors in ONE GPU draw call
    // Before: 200 dots = 200 draw calls, 200 tessellations (~12,800 vertices)
    // After:  200 dots = 1 draw call, 800 vertices (4 per point quad)
    if (state.dot_count > 0) {
        // Build separate position and color arrays for batch rendering
        var centers: [MAX_DOTS][2]f32 = undefined;
        var colors: [MAX_DOTS]ui.Color = undefined;
        for (state.dots[0..state.dot_count], 0..) |dot, i| {
            centers[i] = .{ dot.x, dot.y };
            colors[i] = dot.color;
        }
        ctx.pointCloudColoredArrays(centers[0..state.dot_count], colors[0..state.dot_count], DOT_RADIUS);
    }

    // Draw instructions if canvas is empty
    if (state.dot_count == 0) {
        // Center text
        const text = "Click anywhere to start drawing";
        const text_y = h / 2 - 10;
        _ = ctx.drawText(text, 150, text_y, ui.Color.rgba(1.0, 1.0, 1.0, 0.4), 16);
    }
}

// =============================================================================
// Tests
// =============================================================================

test "AppState init" {
    const s = AppState{};
    try std.testing.expectEqual(@as(usize, 0), s.dot_count);
    try std.testing.expect(s.canvas_bounds == null);
}
