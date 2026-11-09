//! Drawing on the core `Painter` the way 0.3.1's canvas `DrawContext` drew.
//!
//! Charts draw in window coordinates: a chart offsets its plot area by the
//! paint element's `painter.bounds`. Rectangles and lines map straight onto
//! the painter. Text keeps 0.3.1's placement, which the axis and legend
//! layouts are tuned for: the baseline sits one ascender of the app font
//! below the requested top (or 0.35 ascender below a centre line), measured
//! at the font's loaded size whatever the label's size, and widths are
//! measured at that size too.

const std = @import("std");
const gooey = @import("gooey");

const assert = std.debug.assert;

pub const Painter = gooey.core.Painter;
pub const Color = gooey.core.ui.Color;

/// A filled rectangle, with rounded corners when `radius` is positive.
pub fn rect(painter: *Painter, bounds: gooey.core.ui.Rect, radius: f32, color: Color) void {
    assert(bounds.width >= 0);
    assert(bounds.height >= 0);
    assert(radius >= 0);
    painter.quad(.{
        .bounds = bounds,
        .fill = color,
        .border = .none,
        .corners = .all(radius),
        .blur = 0,
    });
}

/// One line of text with its top at `y`; returns its width.
pub fn text(painter: *Painter, content: []const u8, x: f32, y: f32, color: Color, size: f32) f32 {
    assert(!std.math.isNan(x) and !std.math.isNan(y));
    const baseline = y + painter.fontMetrics().ascender;
    return painter.textOnBaseline(content, x, baseline, style(color, size));
}

/// One line of text whose visual centre is at `y_center`; returns its width.
pub fn textCentered(
    painter: *Painter,
    content: []const u8,
    x: f32,
    y_center: f32,
    color: Color,
    size: f32,
) f32 {
    assert(!std.math.isNan(x) and !std.math.isNan(y_center));
    // Cap height is about 0.7 ascender, so its centre is 0.35 above the baseline.
    const baseline = y_center + painter.fontMetrics().ascender * 0.35;
    return painter.textOnBaseline(content, x, baseline, style(color, size));
}

/// The width of `content` at the app font's loaded size.
pub fn measure(painter: *const Painter, content: []const u8) f32 {
    const metrics = painter.fontMetrics();
    assert(metrics.point_size > 0);
    const loaded: u16 = @intFromFloat(@round(metrics.point_size));
    return painter.measureText(content, .{ .size = loaded, .color = Color.black });
}

fn style(color: Color, size: f32) gooey.core.ui.PaintText {
    assert(size >= 1);
    assert(size <= std.math.maxInt(u16));
    return .{ .size = @intFromFloat(@round(size)), .color = color };
}
