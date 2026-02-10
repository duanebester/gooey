//! AI Canvas Spike (Phase 0)
//!
//! Validates the comptime paint callback → runtime command buffer → DrawContext
//! bridge end-to-end before building any AI canvas infrastructure.
//!
//! This is throwaway spike code. It proves:
//! - canvas(w, h, paintFn) → paintFn(ctx: *DrawContext) → ctx.fillRect(...) chain works
//! - A global `var state` can hold draw data that the paint callback reads
//! - The pattern from canvas_drawing.zig generalizes to a command-buffer approach
//!
//! What this does NOT have:
//! - No DrawCommand tagged union, no TextPool, no JSON parsing
//! - No threading, no triple-buffering
//! - No tests, no assertions, no size budgets

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;

// =============================================================================
// Constants
// =============================================================================

const WINDOW_WIDTH: f32 = 800;
const WINDOW_HEIGHT: f32 = 600;
const CANVAS_WIDTH: f32 = 760;
const CANVAS_HEIGHT: f32 = 520;

const MAX_RECTS: usize = 64;
const MAX_CIRCLES: usize = 64;
const MAX_LINES: usize = 64;
const MAX_TEXTS: usize = 32;
const MAX_TEXT_BUF: usize = 4096;

// =============================================================================
// Minimal Command Structs (spike-only, not the real DrawCommand)
// =============================================================================

const RectCmd = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: ui.Color,
    rounded: bool = false,
    radius: f32 = 0,
    stroke: bool = false,
    stroke_width: f32 = 0,
};

const CircleCmd = struct {
    cx: f32,
    cy: f32,
    r: f32,
    color: ui.Color,
    stroke: bool = false,
    stroke_width: f32 = 0,
};

const LineCmd = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    width: f32,
    color: ui.Color,
};

const TextCmd = struct {
    buf_offset: u16,
    buf_len: u16,
    x: f32,
    y: f32,
    color: ui.Color,
    font_size: f32,
};

// =============================================================================
// Application State — the "command buffer"
// =============================================================================

const AppState = struct {
    rects: [MAX_RECTS]RectCmd = undefined,
    rect_count: usize = 0,

    circles: [MAX_CIRCLES]CircleCmd = undefined,
    circle_count: usize = 0,

    lines: [MAX_LINES]LineCmd = undefined,
    line_count: usize = 0,

    texts: [MAX_TEXTS]TextCmd = undefined,
    text_count: usize = 0,

    text_buf: [MAX_TEXT_BUF]u8 = undefined,
    text_buf_used: usize = 0,

    background: ui.Color = ui.Color.hex(0x1a1a2e),

    const Self = @This();

    fn addRect(self: *Self, cmd: RectCmd) void {
        if (self.rect_count >= MAX_RECTS) return;
        self.rects[self.rect_count] = cmd;
        self.rect_count += 1;
    }

    fn addCircle(self: *Self, cmd: CircleCmd) void {
        if (self.circle_count >= MAX_CIRCLES) return;
        self.circles[self.circle_count] = cmd;
        self.circle_count += 1;
    }

    fn addLine(self: *Self, cmd: LineCmd) void {
        if (self.line_count >= MAX_LINES) return;
        self.lines[self.line_count] = cmd;
        self.line_count += 1;
    }

    fn addText(self: *Self, text: []const u8, x: f32, y: f32, color: ui.Color, font_size: f32) void {
        if (self.text_count >= MAX_TEXTS) return;
        if (self.text_buf_used + text.len > MAX_TEXT_BUF) return;

        const offset = self.text_buf_used;
        @memcpy(self.text_buf[offset .. offset + text.len], text);
        self.text_buf_used += text.len;

        self.texts[self.text_count] = .{
            .buf_offset = @intCast(offset),
            .buf_len = @intCast(text.len),
            .x = x,
            .y = y,
            .color = color,
            .font_size = font_size,
        };
        self.text_count += 1;
    }

    fn getText(self: *const Self, cmd: TextCmd) []const u8 {
        return self.text_buf[cmd.buf_offset .. cmd.buf_offset + cmd.buf_len];
    }

    fn clear(self: *Self) void {
        self.rect_count = 0;
        self.circle_count = 0;
        self.line_count = 0;
        self.text_count = 0;
        self.text_buf_used = 0;
    }
};

// =============================================================================
// Global State
// =============================================================================

var state = AppState{};

// Populate hardcoded "AI commands" at startup
fn populateHardcodedScene() void {
    state.clear();

    // Background canvas fill
    state.background = ui.Color.hex(0x0f0f23);

    // --- A dashboard-like scene an AI might generate ---

    // Title bar background
    state.addRect(.{ .x = 0, .y = 0, .w = CANVAS_WIDTH, .h = 50, .color = ui.Color.hex(0x1e1e3f) });

    // Title text
    state.addText("AI Canvas Spike - Phase 0", 20, 15, ui.Color.hex(0xe0e0ff), 22);

    // Status indicator (green dot)
    state.addCircle(.{ .cx = CANVAS_WIDTH - 30, .cy = 25, .r = 8, .color = ui.Color.hex(0x00ff88) });

    // Separator line
    state.addLine(.{ .x1 = 0, .y1 = 52, .x2 = CANVAS_WIDTH, .y2 = 52, .width = 2, .color = ui.Color.hex(0x3a3a6a) });

    // --- Card 1: Stats ---
    state.addRect(.{
        .x = 20,
        .y = 70,
        .w = 220,
        .h = 140,
        .color = ui.Color.hex(0x1a1a3e),
        .rounded = true,
        .radius = 8,
    });
    state.addText("Render Calls", 40, 90, ui.Color.hex(0x8888cc), 14);
    state.addText("1,247", 40, 115, ui.Color.hex(0xffffff), 32);
    state.addLine(.{ .x1 = 40, .y1 = 160, .x2 = 220, .y2 = 160, .width = 1, .color = ui.Color.hex(0x3a3a6a) });
    state.addText("+12% from last frame", 40, 172, ui.Color.hex(0x00ff88), 12);

    // --- Card 2: Memory ---
    state.addRect(.{
        .x = 260,
        .y = 70,
        .w = 220,
        .h = 140,
        .color = ui.Color.hex(0x1a1a3e),
        .rounded = true,
        .radius = 8,
    });
    state.addText("Memory Usage", 280, 90, ui.Color.hex(0x8888cc), 14);
    state.addText("280 KB", 280, 115, ui.Color.hex(0xffffff), 32);
    // Memory bar background
    state.addRect(.{
        .x = 280,
        .y = 165,
        .w = 180,
        .h = 12,
        .color = ui.Color.hex(0x2a2a4e),
        .rounded = true,
        .radius = 6,
    });
    // Memory bar fill (65%)
    state.addRect(.{
        .x = 280,
        .y = 165,
        .w = 117,
        .h = 12,
        .color = ui.Color.hex(0x5588ff),
        .rounded = true,
        .radius = 6,
    });

    // --- Card 3: Status circles ---
    state.addRect(.{
        .x = 500,
        .y = 70,
        .w = 240,
        .h = 140,
        .color = ui.Color.hex(0x1a1a3e),
        .rounded = true,
        .radius = 8,
    });
    state.addText("Systems", 520, 90, ui.Color.hex(0x8888cc), 14);
    // Status circles
    state.addCircle(.{ .cx = 545, .cy = 140, .r = 18, .color = ui.Color.hex(0x00ff88) }); // OK
    state.addCircle(.{ .cx = 610, .cy = 140, .r = 18, .color = ui.Color.hex(0x00ff88) }); // OK
    state.addCircle(.{ .cx = 675, .cy = 140, .r = 18, .color = ui.Color.hex(0xffaa00) }); // Warning
    state.addText("GPU", 533, 168, ui.Color.hex(0x8888cc), 11);
    state.addText("CPU", 598, 168, ui.Color.hex(0x8888cc), 11);
    state.addText("MEM", 662, 168, ui.Color.hex(0x8888cc), 11);

    // --- Chart area ---
    state.addRect(.{
        .x = 20,
        .y = 230,
        .w = 720,
        .h = 270,
        .color = ui.Color.hex(0x1a1a3e),
        .rounded = true,
        .radius = 8,
    });
    state.addText("Frame Time (ms)", 40, 245, ui.Color.hex(0x8888cc), 14);

    // Chart grid lines
    const chart_left: f32 = 60;
    const chart_right: f32 = 720;
    const chart_top: f32 = 275;
    const chart_bottom: f32 = 480;
    const grid_color = ui.Color.hex(0x2a2a4e);

    var row: usize = 0;
    while (row <= 4) : (row += 1) {
        const y = chart_top + @as(f32, @floatFromInt(row)) * (chart_bottom - chart_top) / 4.0;
        state.addLine(.{ .x1 = chart_left, .y1 = y, .x2 = chart_right, .y2 = y, .width = 1, .color = grid_color });
    }

    // Simulated chart data — a jagged line
    const data_points = [_]f32{ 0.3, 0.5, 0.4, 0.7, 0.6, 0.35, 0.45, 0.8, 0.55, 0.4, 0.5, 0.65, 0.3, 0.45, 0.5, 0.7 };
    const num_points = data_points.len;
    const chart_w = chart_right - chart_left;
    const chart_h = chart_bottom - chart_top;

    var i: usize = 0;
    while (i < num_points - 1) : (i += 1) {
        const x1 = chart_left + @as(f32, @floatFromInt(i)) * chart_w / @as(f32, @floatFromInt(num_points - 1));
        const y1 = chart_bottom - data_points[i] * chart_h;
        const x2 = chart_left + @as(f32, @floatFromInt(i + 1)) * chart_w / @as(f32, @floatFromInt(num_points - 1));
        const y2 = chart_bottom - data_points[i + 1] * chart_h;
        state.addLine(.{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .width = 2, .color = ui.Color.hex(0x5588ff) });
    }

    // Data point dots
    i = 0;
    while (i < num_points) : (i += 1) {
        const px = chart_left + @as(f32, @floatFromInt(i)) * chart_w / @as(f32, @floatFromInt(num_points - 1));
        const py = chart_bottom - data_points[i] * chart_h;
        state.addCircle(.{ .cx = px, .cy = py, .r = 4, .color = ui.Color.hex(0x88bbff) });
    }

    // Y-axis labels
    state.addText("16", 35, 270, ui.Color.hex(0x6666aa), 11);
    state.addText("12", 35, 321, ui.Color.hex(0x6666aa), 11);
    state.addText("8", 40, 372, ui.Color.hex(0x6666aa), 11);
    state.addText("4", 40, 423, ui.Color.hex(0x6666aa), 11);
    state.addText("0", 40, 474, ui.Color.hex(0x6666aa), 11);

    // Stroke rect demo (border around the whole canvas)
    state.addRect(.{
        .x = 1,
        .y = 1,
        .w = CANVAS_WIDTH - 2,
        .h = CANVAS_HEIGHT - 2,
        .color = ui.Color.hex(0x3a3a6a),
        .stroke = true,
        .stroke_width = 1,
    });
}

var scene_populated: bool = false;

// =============================================================================
// Entry Points
// =============================================================================

const App = gooey.App(AppState, &state, render, .{
    .title = "AI Canvas Spike (Phase 0)",
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

    // Populate scene once (simulates receiving commands from AI)
    if (!scene_populated) {
        populateHardcodedScene();
        scene_populated = true;
    }

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 20 },
        .gap = 10,
        .direction = .column,
        .background = ui.Color.hex(0x111122),
    }, .{
        ui.canvas(CANVAS_WIDTH, CANVAS_HEIGHT, paintAiCanvas),
    }));
}

// =============================================================================
// Paint Callback — The comptime/runtime bridge
//
// This is the key thing Phase 0 validates:
// A comptime fn pointer reads runtime global state and drives DrawContext.
// =============================================================================

fn paintAiCanvas(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();

    // Background
    ctx.fillRect(0, 0, w, h, state.background);

    // Replay rectangles
    for (state.rects[0..state.rect_count]) |cmd| {
        if (cmd.stroke) {
            ctx.strokeRect(cmd.x, cmd.y, cmd.w, cmd.h, cmd.color, cmd.stroke_width);
        } else if (cmd.rounded) {
            ctx.fillRoundedRect(cmd.x, cmd.y, cmd.w, cmd.h, cmd.radius, cmd.color);
        } else {
            ctx.fillRect(cmd.x, cmd.y, cmd.w, cmd.h, cmd.color);
        }
    }

    // Replay circles
    for (state.circles[0..state.circle_count]) |cmd| {
        if (cmd.stroke) {
            ctx.strokeCircle(cmd.cx, cmd.cy, cmd.r, cmd.stroke_width, cmd.color);
        } else {
            ctx.fillCircle(cmd.cx, cmd.cy, cmd.r, cmd.color);
        }
    }

    // Replay lines
    for (state.lines[0..state.line_count]) |cmd| {
        ctx.line(cmd.x1, cmd.y1, cmd.x2, cmd.y2, cmd.width, cmd.color);
    }

    // Replay text
    for (state.texts[0..state.text_count]) |cmd| {
        const text = state.getText(cmd);
        _ = ctx.drawText(text, cmd.x, cmd.y, cmd.color, cmd.font_size);
    }
}
