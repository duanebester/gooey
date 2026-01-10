//! Grid Primitive for Gooey Charts
//!
//! Renders background grid lines aligned with axis ticks.
//! Grid lines help users read values from the chart.

const std = @import("std");
const gooey = @import("gooey");
const constants = @import("../constants.zig");
const scale_mod = @import("scale.zig");

const LinearScale = scale_mod.LinearScale;
const BandScale = scale_mod.BandScale;
const Scale = scale_mod.Scale;

pub const Color = gooey.ui.Color;
pub const DrawContext = gooey.ui.DrawContext;

const MAX_TICKS = constants.MAX_TICKS;

// =============================================================================
// Grid
// =============================================================================

pub const Grid = struct {
    /// Configuration options for grid rendering.
    pub const Options = struct {
        show_horizontal: bool = true,
        show_vertical: bool = false,
        color: Color = Color.hex(0xE0E0E0),
        line_width: f32 = constants.DEFAULT_GRID_LINE_WIDTH,
    };

    /// Bounds for the chart area.
    pub const Bounds = struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    };

    /// Draw grid lines for linear scales on both axes.
    pub fn drawLinear(
        ctx: *DrawContext,
        x_scale: LinearScale,
        y_scale: LinearScale,
        bounds: Bounds,
        tick_count: u32,
        opts: Options,
    ) void {
        drawLinearXY(ctx, x_scale, y_scale, bounds, tick_count, tick_count, opts);
    }

    /// Draw grid lines for linear scales with separate X and Y tick counts.
    /// Useful for line charts where X and Y axes may have different tick densities.
    pub fn drawLinearXY(
        ctx: *DrawContext,
        x_scale: LinearScale,
        y_scale: LinearScale,
        bounds: Bounds,
        x_tick_count: u32,
        y_tick_count: u32,
        opts: Options,
    ) void {
        // Assertions at API boundary
        std.debug.assert(bounds.width >= 0 and bounds.height >= 0);
        std.debug.assert(!std.math.isNan(bounds.x) and !std.math.isNan(bounds.y));
        std.debug.assert(x_tick_count > 0 and x_tick_count <= MAX_TICKS);
        std.debug.assert(y_tick_count > 0 and y_tick_count <= MAX_TICKS);

        // Draw horizontal grid lines (aligned with Y-axis ticks)
        if (opts.show_horizontal) {
            drawHorizontalLines(ctx, y_scale, bounds, y_tick_count, opts);
        }

        // Draw vertical grid lines (aligned with X-axis ticks)
        if (opts.show_vertical) {
            drawVerticalLinesLinear(ctx, x_scale, bounds, x_tick_count, opts);
        }
    }

    /// Draw grid lines with band scale on X-axis and linear scale on Y-axis.
    /// Common for bar charts.
    pub fn drawMixed(
        ctx: *DrawContext,
        x_scale: BandScale,
        y_scale: LinearScale,
        bounds: Bounds,
        tick_count: u32,
        opts: Options,
    ) void {
        // Assertions at API boundary
        std.debug.assert(bounds.width >= 0 and bounds.height >= 0);
        std.debug.assert(!std.math.isNan(bounds.x) and !std.math.isNan(bounds.y));
        std.debug.assert(tick_count > 0 and tick_count <= MAX_TICKS);

        // Draw horizontal grid lines (aligned with Y-axis ticks)
        if (opts.show_horizontal) {
            drawHorizontalLines(ctx, y_scale, bounds, tick_count, opts);
        }

        // Draw vertical grid lines (at band centers)
        if (opts.show_vertical) {
            drawVerticalLinesBand(ctx, x_scale, bounds, opts);
        }
    }

    /// Draw grid with Scale union types.
    pub fn draw(
        ctx: *DrawContext,
        x_scale: Scale,
        y_scale: Scale,
        bounds: Bounds,
        tick_count: u32,
        opts: Options,
    ) void {
        switch (y_scale) {
            .linear => |ys| {
                switch (x_scale) {
                    .linear => |xs| drawLinear(ctx, xs, ys, bounds, tick_count, opts),
                    .band => |xs| drawMixed(ctx, xs, ys, bounds, tick_count, opts),
                }
            },
            .band => {
                // Band scale on Y-axis is unusual; fall back to simple grid
                if (opts.show_horizontal) {
                    drawSimpleHorizontalLines(ctx, bounds, tick_count, opts);
                }
                if (opts.show_vertical) {
                    switch (x_scale) {
                        .linear => |xs| drawVerticalLinesLinear(ctx, xs, bounds, tick_count, opts),
                        .band => |xs| drawVerticalLinesBand(ctx, xs, bounds, opts),
                    }
                }
            },
        }
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Draw horizontal grid lines aligned with Y-axis tick positions.
fn drawHorizontalLines(
    ctx: *DrawContext,
    y_scale: LinearScale,
    bounds: Grid.Bounds,
    tick_count: u32,
    opts: Grid.Options,
) void {
    std.debug.assert(tick_count <= MAX_TICKS);

    var tick_values: [MAX_TICKS]f32 = undefined;
    const actual_count = y_scale.ticks(tick_count, &tick_values);

    const x1 = bounds.x;
    const x2 = bounds.x + bounds.width;

    for (tick_values[0..actual_count]) |value| {
        const y_pos = y_scale.scale(value);

        // Skip if outside bounds
        if (y_pos < bounds.y or y_pos > bounds.y + bounds.height) continue;

        ctx.strokeLine(x1, y_pos, x2, y_pos, opts.line_width, opts.color);
    }
}

/// Draw vertical grid lines aligned with X-axis tick positions (linear scale).
fn drawVerticalLinesLinear(
    ctx: *DrawContext,
    x_scale: LinearScale,
    bounds: Grid.Bounds,
    tick_count: u32,
    opts: Grid.Options,
) void {
    std.debug.assert(tick_count <= MAX_TICKS);

    var tick_values: [MAX_TICKS]f32 = undefined;
    const actual_count = x_scale.ticks(tick_count, &tick_values);

    const y1 = bounds.y;
    const y2 = bounds.y + bounds.height;

    for (tick_values[0..actual_count]) |value| {
        const x_pos = x_scale.scale(value);

        // Skip if outside bounds
        if (x_pos < bounds.x or x_pos > bounds.x + bounds.width) continue;

        ctx.strokeLine(x_pos, y1, x_pos, y2, opts.line_width, opts.color);
    }
}

/// Draw vertical grid lines at band centers (for categorical X-axis).
fn drawVerticalLinesBand(
    ctx: *DrawContext,
    x_scale: BandScale,
    bounds: Grid.Bounds,
    opts: Grid.Options,
) void {
    const y1 = bounds.y;
    const y2 = bounds.y + bounds.height;

    var i: u32 = 0;
    while (i < x_scale.label_count) : (i += 1) {
        const x_pos = x_scale.center(i);

        // Skip if outside bounds
        if (x_pos < bounds.x or x_pos > bounds.x + bounds.width) continue;

        ctx.strokeLine(x_pos, y1, x_pos, y2, opts.line_width, opts.color);
    }
}

/// Draw simple evenly-spaced horizontal lines (fallback).
fn drawSimpleHorizontalLines(
    ctx: *DrawContext,
    bounds: Grid.Bounds,
    line_count: u32,
    opts: Grid.Options,
) void {
    std.debug.assert(line_count > 0);

    const x1 = bounds.x;
    const x2 = bounds.x + bounds.width;
    const step = bounds.height / @as(f32, @floatFromInt(line_count));

    var i: u32 = 1;
    while (i < line_count) : (i += 1) {
        const y_pos = bounds.y + step * @as(f32, @floatFromInt(i));
        ctx.strokeLine(x1, y_pos, x2, y_pos, opts.line_width, opts.color);
    }
}

// =============================================================================
// Tests
// =============================================================================

test "Grid.Options defaults" {
    const opts = Grid.Options{};
    try std.testing.expect(opts.show_horizontal);
    try std.testing.expect(!opts.show_vertical);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), opts.line_width, 0.001);
}

test "Grid.Bounds creation" {
    const bounds = Grid.Bounds{
        .x = 10,
        .y = 20,
        .width = 400,
        .height = 300,
    };
    try std.testing.expectEqual(@as(f32, 10), bounds.x);
    try std.testing.expectEqual(@as(f32, 20), bounds.y);
    try std.testing.expectEqual(@as(f32, 400), bounds.width);
    try std.testing.expectEqual(@as(f32, 300), bounds.height);
}
