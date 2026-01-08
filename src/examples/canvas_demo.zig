//! Canvas Demo Example - Minimal
//!
//! Tests basic canvas rendering.

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;

// Gradient types
const LinearGradient = ui.LinearGradient;
const RadialGradient = ui.RadialGradient;
const Hsla = gooey.scene.Hsla;

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    frame: u32 = 0,
};

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Canvas Demo",
    .width = 550,
    .height = 400,
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

    cx.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 20 },
        .gap = 15,
        .direction = .column,
        .background = ui.Color.hex(0x1a1a2e),
    }, .{
        ui.text("Canvas Demo", .{
            .size = 24,
            .color = ui.Color.white,
        }),

        ui.canvas(500, 320, paintSimple),
    });
}

fn paintSimple(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();

    // Background
    ctx.fillRect(0, 0, w, h, ui.Color.hex(0x16213e));

    // Rectangles - plain and rounded
    ctx.fillRect(20, 15, 60, 35, ui.Color.rgb(0.9, 0.3, 0.3));
    ctx.fillRoundedRect(100, 15, 60, 35, 8, ui.Color.rgb(0.3, 0.9, 0.3));
    ctx.fillRoundedRect(180, 15, 60, 35, 17, ui.Color.rgb(0.3, 0.3, 0.9));

    // Circles and ellipses
    ctx.fillCircle(50, 85, 22, ui.Color.rgb(1.0, 0.7, 0.2));
    ctx.fillCircle(130, 85, 18, ui.Color.rgb(0.7, 0.2, 1.0));
    ctx.fillEllipse(210, 85, 30, 18, ui.Color.rgb(0.2, 0.8, 0.8));

    // Triangle
    ctx.fillTriangle(280, 20, 320, 55, 260, 55, ui.Color.rgb(1.0, 0.4, 0.6));

    // Strokes
    ctx.strokeRect(280, 70, 50, 35, ui.Color.rgb(1.0, 0.5, 0.0), 2);
    ctx.strokeCircle(360, 40, 20, 3, ui.Color.rgb(0.0, 1.0, 0.5));
    ctx.strokeEllipse(360, 95, 25, 15, 2, ui.Color.rgb(1.0, 0.3, 0.7));

    // Lines
    ctx.strokeLine(20, 130, 100, 130, 2, ui.Color.white);
    ctx.strokeLine(110, 130, 190, 130, 4, ui.Color.rgb(1.0, 0.6, 0.2));
    ctx.strokeLine(200, 130, 280, 130, 6, ui.Color.rgb(0.2, 0.6, 1.0));

    // === Gradient 1: Rainbow horizontal ===
    var hGrad = LinearGradient.horizontal(200);
    _ = hGrad.addStop(0.0, Hsla.fromRgba(1.0, 0.0, 0.0, 1.0));
    _ = hGrad.addStop(0.5, Hsla.fromRgba(1.0, 1.0, 0.0, 1.0));
    _ = hGrad.addStop(1.0, Hsla.fromRgba(0.0, 0.0, 1.0, 1.0));
    ctx.fillRectLinearGradient(20, 150, 200, 60, &hGrad);

    // === Gradient 2: Vertical sky-purple ===
    var vGrad = LinearGradient.vertical(60);
    _ = vGrad.addStop(0.0, Hsla.fromRgba(0.2, 0.6, 1.0, 1.0));
    _ = vGrad.addStop(1.0, Hsla.fromRgba(0.8, 0.2, 1.0, 1.0));
    ctx.fillRectLinearGradient(240, 150, 80, 60, &vGrad);

    // Bottom row - solid shapes
    ctx.fillRoundedRect(20, 220, 100, 40, 10, ui.Color.rgb(0.5, 0.8, 0.4));
    ctx.fillCircle(170, 240, 22, ui.Color.rgb(0.9, 0.5, 0.3));
    ctx.strokeCircle(230, 240, 22, 3, ui.Color.rgb(0.8, 0.8, 0.2));
    ctx.fillEllipse(300, 240, 32, 18, ui.Color.rgb(0.4, 0.6, 0.9));
}

// =============================================================================
// Tests
// =============================================================================

test "AppState" {
    const s = AppState{};
    try std.testing.expectEqual(@as(u32, 0), s.frame);
}
