const std = @import("std");
const gooey = @import("gooey");

const assert = std.debug.assert;

pub const Painter = gooey.Painter;
pub const Color = gooey.ui.Color;

pub fn rect(painter: *Painter, bounds: gooey.ui.Rect, radius: f32, color: Color) void {
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

pub fn text(painter: *Painter, content: []const u8, x: f32, y: f32, color: Color, size: f32) f32 {
    assert(!std.math.isNan(x) and !std.math.isNan(y));
    const baseline = y + painter.fontMetrics().ascender;
    return painter.textOnBaseline(content, x, baseline, style(color, size));
}

pub fn textCentered(
    painter: *Painter,
    content: []const u8,
    x: f32,
    y_center: f32,
    color: Color,
    size: f32,
) f32 {
    assert(!std.math.isNan(x) and !std.math.isNan(y_center));
    const baseline = y_center + painter.fontMetrics().ascender * 0.35;
    return painter.textOnBaseline(content, x, baseline, style(color, size));
}

pub fn measure(painter: *const Painter, content: []const u8) f32 {
    const metrics = painter.fontMetrics();
    assert(metrics.point_size > 0);
    const loaded: u16 = @intFromFloat(@round(metrics.point_size));
    return painter.measureText(content, .{ .size = loaded, .color = Color.black });
}

fn style(color: Color, size: f32) gooey.ui.PaintText {
    assert(size >= 1);
    assert(size <= std.math.maxInt(u16));
    return .{ .size = @intFromFloat(@round(size)), .color = color };
}
