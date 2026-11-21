const std = @import("std");
const constants = @import("../constants.zig");
const util = @import("../util.zig");
const scale_mod = @import("scale.zig");
const ChartTheme = @import("../theme.zig").ChartTheme;

const LinearScale = scale_mod.LinearScale;
const BandScale = scale_mod.BandScale;
const Scale = scale_mod.Scale;

const paint = @import("../paint.zig");

pub const Color = paint.Color;
pub const Painter = paint.Painter;

const MAX_TICKS = constants.MAX_TICKS;
const MAX_LABEL_LENGTH = constants.MAX_LABEL_LENGTH;

pub const Axis = struct {
    pub const Orientation = enum {
        top,
        bottom,
        left,
        right,
    };

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

    /// `opts` faces `orientation`, themed when a chart theme is set.
    pub fn themed(
        opts: Options,
        orientation: Orientation,
        chart_theme: ?*const ChartTheme,
    ) Options {
        var result = opts;
        result.orientation = orientation;
        if (chart_theme) |theme| {
            result.color = theme.axis_color;
            result.label_color = theme.tick_color;
        }
        return result;
    }

    pub fn drawLinear(
        painter: *Painter,
        s: LinearScale,
        x: f32,
        y: f32,
        opts: Options,
    ) void {
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        std.debug.assert(opts.tick_count > 0 and opts.tick_count <= MAX_TICKS);

        if (opts.show_line) {
            drawAxisLine(painter, s.range_min, s.range_max, x, y, opts);
        }

        if (opts.show_ticks or opts.show_labels) {
            var tick_values: [MAX_TICKS]f32 = undefined;
            const tick_count = s.ticks(opts.tick_count, &tick_values);

            for (tick_values[0..tick_count]) |value| {
                const pos = s.scale(value);
                drawTickWithLabel(painter, pos, value, x, y, opts);
            }
        }

        if (opts.label) |label| {
            drawAxisTitle(painter, label, s.range_min, s.range_max, x, y, opts);
        }
    }

    pub fn drawBand(
        painter: *Painter,
        s: BandScale,
        x: f32,
        y: f32,
        opts: Options,
    ) void {
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        std.debug.assert(s.label_count > 0);

        if (opts.show_line) {
            drawAxisLine(painter, s.range_min, s.range_max, x, y, opts);
        }

        if (opts.show_ticks or opts.show_labels) {
            var i: u32 = 0;
            while (i < s.label_count) : (i += 1) {
                const pos = s.center(i);
                const label = s.getLabel(i);
                drawTickWithBandLabel(painter, pos, label, x, y, opts);
            }
        }

        if (opts.label) |label| {
            drawAxisTitle(painter, label, s.range_min, s.range_max, x, y, opts);
        }
    }

    pub fn draw(painter: *Painter, s: Scale, x: f32, y: f32, opts: Options) void {
        switch (s) {
            .linear => |ls| drawLinear(painter, ls, x, y, opts),
            .band => |bs| drawBand(painter, bs, x, y, opts),
        }
    }
};

fn drawAxisLine(
    painter: *Painter,
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
            painter.line(.{ start, y }, .{ end, y }, opts.line_width, opts.color);
        },
        .left, .right => {
            painter.line(.{ x, start }, .{ x, end }, opts.line_width, opts.color);
        },
    }
}

fn drawTickWithLabel(
    painter: *Painter,
    pos: f32,
    value: f32,
    x: f32,
    y: f32,
    opts: Axis.Options,
) void {
    std.debug.assert(!std.math.isNan(pos) and !std.math.isNan(value));

    if (opts.show_ticks) {
        drawTickMark(painter, pos, x, y, opts);
    }

    if (opts.show_labels) {
        var buf: [MAX_LABEL_LENGTH]u8 = undefined;
        const label_text = util.formatNumber(value, &buf);
        drawLabelText(painter, label_text, pos, x, y, opts);
    }
}

fn drawTickWithBandLabel(
    painter: *Painter,
    pos: f32,
    label: []const u8,
    x: f32,
    y: f32,
    opts: Axis.Options,
) void {
    std.debug.assert(!std.math.isNan(pos));

    if (opts.show_ticks) {
        drawTickMark(painter, pos, x, y, opts);
    }

    if (opts.show_labels) {
        drawLabelText(painter, label, pos, x, y, opts);
    }
}

fn drawTickMark(
    painter: *Painter,
    pos: f32,
    x: f32,
    y: f32,
    opts: Axis.Options,
) void {
    const size = opts.tick_size;

    switch (opts.orientation) {
        .bottom => {
            painter.line(.{ pos, y }, .{ pos, y + size }, opts.line_width, opts.color);
        },
        .top => {
            painter.line(.{ pos, y }, .{ pos, y - size }, opts.line_width, opts.color);
        },
        .left => {
            painter.line(.{ x, pos }, .{ x - size, pos }, opts.line_width, opts.color);
        },
        .right => {
            painter.line(.{ x, pos }, .{ x + size, pos }, opts.line_width, opts.color);
        },
    }
}

fn drawLabelText(
    painter: *Painter,
    text: []const u8,
    pos: f32,
    x: f32,
    y: f32,
    opts: Axis.Options,
) void {
    // Rough estimate.
    const char_width: f32 = opts.font_size * 0.6;
    const text_width = char_width * @as(f32, @floatFromInt(text.len));
    const text_height = opts.font_size;

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

    _ = paint.text(painter, text, label_x, label_y, opts.label_color, opts.font_size);
}

fn drawAxisTitle(
    painter: *Painter,
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

    _ = paint.text(painter, title, title_x, title_y, opts.label_color, opts.font_size);
}

test "Axis.Options defaults" {
    const opts = Axis.Options{};
    try std.testing.expectEqual(Axis.Orientation.bottom, opts.orientation);
    try std.testing.expect(opts.show_line);
    try std.testing.expect(opts.show_ticks);
    try std.testing.expect(opts.show_labels);
    try std.testing.expect(opts.label == null);
}

test "Axis orientations" {
    try std.testing.expectEqual(@backingInt(Axis.Orientation.top), 0);
    try std.testing.expectEqual(@backingInt(Axis.Orientation.bottom), 1);
    try std.testing.expectEqual(@backingInt(Axis.Orientation.left), 2);
    try std.testing.expectEqual(@backingInt(Axis.Orientation.right), 3);
}
