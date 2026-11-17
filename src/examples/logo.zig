//! Logo: Gooey's logo bouncing around the window, like a DVD screensaver.
//!
//! The smallest image app with motion: `Painter.image` draws Gooey's logo
//! from `assets/gooey-logo-320.png` (a 320x200 copy of
//! `gooey-logo-final.png`) at 160x100. Its position is a function of the
//! frame clock alone: each axis moves at a constant speed and reflects off
//! the window's edges, so the path is the same at any frame rate and no
//! per-frame state drifts. Each bounce moves the tint one step through a
//! small set of warm shades. It runs on every backend; on a board
//! (`-Dlinux-backend=fbdev` or `eve`) it uses the `.embedded` budget, and on
//! EVE the logo draws from the ARGB4 image mirror in `RAM_G`. Run it from
//! the repository root, or anywhere with an `assets/` directory beside it.
//!
//! Resource sketch: one 320x200 image (250 KiB of RGBA, decoded once on the
//! image worker) in the `.embedded` image atlas; each frame draws one image
//! sprite over one quad and asks for the next frame.

const std = @import("std");
const gooey = @import("gooey");

const ui = gooey.ui;
const Cx = gooey.Cx;

const assert = std.debug.assert;

pub const State = struct {
    /// The frame clock of the build being painted, in nanoseconds. Render
    /// stamps it so the paint function, which has no `Cx`, sees the same time.
    frame_ns: u64 = 0,
};

pub const App = gooey.App(State, render, .{
    .title = "Gooey",
    .width = 640,
    .height = 400,
    .limits = .embedded,
    .theme = &gooey.Theme.catppuccin_macchiato,
});

/// The generated entry point (contract §7).
pub const main = App.main;

pub const logo_path = "assets/gooey-logo-320.png";
const logo_width: f32 = 160;
const logo_height: f32 = 100;
/// Speeds in logical pixels per second; unequal so the path covers the window.
const speed_x: f64 = 130;
const speed_y: f64 = 95;

/// Multiplied with the logo's colours, one step per bounce. All stay close to
/// white so the orange logo only warms or cools a little.
const tints = [_]ui.Color{
    .rgb(1.0, 1.0, 1.0),
    .rgb(1.0, 0.80, 0.86),
    .rgb(1.0, 0.94, 0.72),
    .rgb(1.0, 0.74, 0.68),
};

pub fn render(cx: *Cx) void {
    const s = cx.state(State);
    s.frame_ns = cx.now();
    // The position follows the clock, so every frame renders.
    cx.requestRenderAfter(0);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .background = .bg,
    } }, .{
        ui.paint(State, s, paintLogo, .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } }),
    }));
}

/// One axis of the bounce: the offset along a span of `range` pixels after
/// travelling `distance` pixels, and how many edges it has reflected off.
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
    // A window smaller than the logo has nowhere to bounce.
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
