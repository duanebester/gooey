const std = @import("std");
const gooey = @import("gooey");

const ui = gooey.ui;
const Cx = gooey.Cx;

const assert = std.debug.assert;

pub const State = struct {
    frame_ns: u64 = 0,
};

pub const App = gooey.App(State, render, .{
    .title = "Gooey",
    .width = 640,
    .height = 400,
    .limits = .embedded,
    .theme = &gooey.Theme.catppuccin_macchiato,
});

pub const main = App.main;

pub const logo_path = "assets/gooey-logo-320.png";
const logo_width: f32 = 160;
const logo_height: f32 = 100;
const speed_x: f64 = 130;
const speed_y: f64 = 95;

const tints = [_]ui.Color{
    .rgb(1.0, 1.0, 1.0),
    .rgb(1.0, 0.80, 0.86),
    .rgb(1.0, 0.94, 0.72),
    .rgb(1.0, 0.74, 0.68),
};

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    s.frame_ns = cx.now();
    cx.requestRenderAfter(0);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .background = .bg,
    } }, .{
        ui.paint(State, s, paintLogo, .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } }),
    }));
}

const Axis = struct {
    offset: f32,
    bounces: u64,

    fn at(distance: f64, range: f64) Axis {
        assert(distance >= 0);
        assert(range > 0);
        const bounces: u64 = @intFromFloat(@floor(distance / range));
        const along = distance - @as(f64, @floatFromInt(bounces)) * range;
        const offset = if (bounces % 2 == 0) along else range - along;
        return .{ .offset = @floatCast(offset), .bounces = bounces };
    }
};

fn paintLogo(s: *const State, painter: *ui.Painter) void {
    const bounds = painter.bounds;
    assert(bounds.width >= 0);
    assert(bounds.height >= 0);
    const range_x: f64 = bounds.width - logo_width;
    const range_y: f64 = bounds.height - logo_height;
    if (range_x <= 0 or range_y <= 0) return;
    const seconds = @as(f64, @floatFromInt(s.frame_ns)) / std.time.ns_per_s;
    const x = Axis.at(seconds * speed_x, range_x);
    const y = Axis.at(seconds * speed_y, range_y);
    const rect: ui.Rect = .{
        .x = bounds.x + x.offset,
        .y = bounds.y + y.offset,
        .width = logo_width,
        .height = logo_height,
    };
    const tint = tints[@intCast((x.bounces + y.bounces) % tints.len)];
    painter.image(logo_path, rect, .{ .fit = .contain, .tint = tint });
}
