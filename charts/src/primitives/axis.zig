//! Axis Primitive for Gooey Charts
//!
//! Renders axis lines, tick marks, and labels for chart scales.
//! Supports all four orientations (top, bottom, left, right) and
//! works with both LinearScale and BandScale.

const std = @import("std");
const gooey = @import("gooey");
const constants = @import("../constants.zig");
const util = @import("../util.zig");
const scale_mod = @import("scale.zig");

const LinearScale = scale_mod.LinearScale;
const BandScale = scale_mod.BandScale;
const Scale = scale_mod.Scale;

pub const Color = gooey.ui.Color;
pub const DrawContext = gooey.ui.DrawContext;

const MAX_TICKS = constants.MAX_TICKS;
const MAX_LABEL_LENGTH = constants.MAX_LABEL_LENGTH;

// =============================================================================
// Axis
// =============================================================================

pub const Axis = struct {
    /// Axis orientation relative to the chart area.
    pub const Orientation = enum {
        top,
        bottom,
        left,
        right,
    };

    /// Configuration options for axis rendering.
    pub const Options = struct {
        orientation: Orientation = .bottom,
        label: ?[]const u8 = null,
        tick_count: u32 = constants.DEFAULT_TICK_COUNT,
        tick_size: f32 = constants.DEFAULT_TICK_SIZE,
        tick_padding: f32 = constants.DEFAULT_TICK_PADDING,
        show_line: bool = true,
        show_ticks: bool = true,
        show_labels: bool = true,
        color: Color = Color.hex(0x666666),
        label_color: Color = Color.hex(0x333333),
        line_width: f32 = 1.0,
        font_size: f32 = 12.0,
    };

    /// Draw an axis for a linear scale.
    pub fn drawLinear(
        ctx: *DrawContext,
        s: LinearScale,
        x: f32,
        y: f32,
        opts: Options,
    ) void {
        // Assertions at API boundary
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        std.debug.assert(opts.tick_count > 0 and opts.tick_count <= MAX_TICKS);

        // Draw axis line
        if (opts.show_line) {
            drawAxisLine(ctx, s.range_min, s.range_max, x, y, opts);
        }

        // Generate and draw ticks
        if (opts.show_ticks or opts.show_labels) {
            var tick_values: [MAX_TICKS]f32 = undefined;
            const tick_count = s.ticks(opts.tick_count, &tick_values);

            for (tick_values[0..tick_count]) |value| {
                const pos = s.scale(value);
                drawTickWithLabel(ctx, pos, value, x, y, opts);
            }
        }

        // Draw axis title if provided
        if (opts.label) |label| {
            drawAxisTitle(ctx, label, s.range_min, s.range_max, x, y, opts);
        }
    }

    /// Draw an axis for a band scale.
    pub fn drawBand(
        ctx: *DrawContext,
        s: BandScale,
        x: f32,
        y: f32,
        opts: Options,
    ) void {
        // Assertions at API boundary
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        std.debug.assert(s.label_count > 0);

        // Draw axis line
        if (opts.show_line) {
            drawAxisLine(ctx, s.range_min, s.range_max, x, y, opts);
        }

        // Draw tick for each category
        if (opts.show_ticks or opts.show_labels) {
            var i: u32 = 0;
            while (i < s.label_count) : (i += 1) {
                const pos = s.center(i);
                const label = s.getLabel(i);
                drawTickWithBandLabel(ctx, pos, label, x, y, opts);
            }
        }

        // Draw axis title if provided
        if (opts.label) |label| {
            drawAxisTitle(ctx, label, s.range_min, s.range_max, x, y, opts);
        }
    }

    /// Draw axis for a Scale union type.
    pub fn draw(ctx: *DrawContext, s: Scale, x: f32, y: f32, opts: Options) void {
        switch (s) {
            .linear => |ls| drawLinear(ctx, ls, x, y, opts),
            .band => |bs| drawBand(ctx, bs, x, y, opts),
        }
    }
};

// =============================================================================
// Helper Functions (kept under 70 lines each per CLAUDE.md)
// =============================================================================

/// Draw the main axis line.
fn drawAxisLine(
    ctx: *DrawContext,
    range_start: f32,
    range_end: f32,
    x: f32,
    y: f32,
    opts: Axis.Options,
) void {
    std.debug.assert(!std.math.isNan(range_start) and !std.math.isNan(range_end));

    const start = @min(range_start, range_end);
    const end = @max(range_start, range_end);

    switch (opts.orientation) {
        .bottom, .top => {
            ctx.strokeLine(start, y, end, y, opts.line_width, opts.color);
        },
        .left, .right => {
            ctx.strokeLine(x, start, x, end, opts.line_width, opts.color);
        },
    }
}

/// Draw a tick mark and numeric label for linear scales.
fn drawTickWithLabel(
    ctx: *DrawContext,
    pos: f32,
    value: f32,
    x: f32,
    y: f32,
    opts: Axis.Options,
) void {
    std.debug.assert(!std.math.isNan(pos) and !std.math.isNan(value));

    // Draw tick mark
    if (opts.show_ticks) {
        drawTickMark(ctx, pos, x, y, opts);
    }

    // Draw label
    if (opts.show_labels) {
        var buf: [MAX_LABEL_LENGTH]u8 = undefined;
        const label_text = util.formatNumber(value, &buf);
        drawLabelText(ctx, label_text, pos, x, y, opts);
    }
}

/// Draw a tick mark and text label for band scales.
fn drawTickWithBandLabel(
    ctx: *DrawContext,
    pos: f32,
    label: []const u8,
    x: f32,
    y: f32,
    opts: Axis.Options,
) void {
    std.debug.assert(!std.math.isNan(pos));

    // Draw tick mark
    if (opts.show_ticks) {
        drawTickMark(ctx, pos, x, y, opts);
    }

    // Draw label
    if (opts.show_labels) {
        drawLabelText(ctx, label, pos, x, y, opts);
    }
}

/// Draw a single tick mark.
fn drawTickMark(
    ctx: *DrawContext,
    pos: f32,
    x: f32,
    y: f32,
    opts: Axis.Options,
) void {
    const size = opts.tick_size;

    switch (opts.orientation) {
        .bottom => {
            ctx.strokeLine(pos, y, pos, y + size, opts.line_width, opts.color);
        },
        .top => {
            ctx.strokeLine(pos, y, pos, y - size, opts.line_width, opts.color);
        },
        .left => {
            ctx.strokeLine(x, pos, x - size, pos, opts.line_width, opts.color);
        },
        .right => {
            ctx.strokeLine(x, pos, x + size, pos, opts.line_width, opts.color);
        },
    }
}

/// Draw label text at the appropriate position.
fn drawLabelText(
    ctx: *DrawContext,
    text: []const u8,
    pos: f32,
    x: f32,
    y: f32,
    opts: Axis.Options,
) void {
    // Approximate text width (rough estimate)
    const char_width: f32 = opts.font_size * 0.6;
    const text_width = char_width * @as(f32, @floatFromInt(text.len));
    const text_height = opts.font_size;

    // Calculate label position based on orientation
    const label_offset = opts.tick_size + opts.tick_padding;

    var label_x: f32 = 0;
    var label_y: f32 = 0;

    switch (opts.orientation) {
        .bottom => {
            label_x = pos - text_width / 2;
            label_y = y + label_offset;
        },
        .top => {
            label_x = pos - text_width / 2;
            label_y = y - label_offset - text_height;
        },
        .left => {
            label_x = x - label_offset - text_width;
            label_y = pos - text_height / 2;
        },
        .right => {
            label_x = x + label_offset;
            label_y = pos - text_height / 2;
        },
    }

    // Draw text using simple rectangle approximation (actual text rendering
    // would use ctx.drawText when available)
    drawTextSimple(ctx, text, label_x, label_y, opts.label_color, opts.font_size);
}

/// Draw axis title.
fn drawAxisTitle(
    ctx: *DrawContext,
    title: []const u8,
    range_start: f32,
    range_end: f32,
    x: f32,
    y: f32,
    opts: Axis.Options,
) void {
    const char_width: f32 = opts.font_size * 0.6;
    const text_width = char_width * @as(f32, @floatFromInt(title.len));
    const text_height = opts.font_size;
    const title_offset = opts.tick_size + opts.tick_padding + text_height + 8;

    const range_center = (range_start + range_end) / 2;

    var title_x: f32 = 0;
    var title_y: f32 = 0;

    switch (opts.orientation) {
        .bottom => {
            title_x = range_center - text_width / 2;
            title_y = y + title_offset;
        },
        .top => {
            title_x = range_center - text_width / 2;
            title_y = y - title_offset - text_height;
        },
        .left => {
            // For left axis, title is rotated (we approximate with offset)
            title_x = x - title_offset - text_width;
            title_y = range_center - text_height / 2;
        },
        .right => {
            title_x = x + title_offset;
            title_y = range_center - text_height / 2;
        },
    }

    drawTextSimple(ctx, title, title_x, title_y, opts.label_color, opts.font_size);
}

/// Render text using DrawContext.
/// Uses real text rendering when TextSystem is available, otherwise
/// falls back to placeholder rectangles for backwards compatibility.
fn drawTextSimple(
    ctx: *DrawContext,
    text: []const u8,
    x: f32,
    y: f32,
    color: Color,
    font_size: f32,
) void {
    // Use DrawContext's drawText which handles TextSystem availability
    _ = ctx.drawText(text, x, y, color, font_size);
}

// =============================================================================
// Tests
// =============================================================================

test "Axis.Options defaults" {
    const opts = Axis.Options{};
    try std.testing.expectEqual(Axis.Orientation.bottom, opts.orientation);
    try std.testing.expect(opts.show_line);
    try std.testing.expect(opts.show_ticks);
    try std.testing.expect(opts.show_labels);
    try std.testing.expect(opts.label == null);
}

test "Axis orientations" {
    try std.testing.expectEqual(@intFromEnum(Axis.Orientation.top), 0);
    try std.testing.expectEqual(@intFromEnum(Axis.Orientation.bottom), 1);
    try std.testing.expectEqual(@intFromEnum(Axis.Orientation.left), 2);
    try std.testing.expectEqual(@intFromEnum(Axis.Orientation.right), 3);
}
