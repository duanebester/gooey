//! Logo: one PNG, centred on a themed background.
//!
//! The smallest image app: `Painter.image` draws Gooey's logo from
//! `assets/gooey-logo-320.png` (a 320x200 copy of `gooey-logo-final.png`)
//! at 160x100, so 2x displays sample it 1:1 and 1x displays scale it down.
//! It runs on every backend; on a board (`-Dlinux-backend=fbdev` or `eve`)
//! it uses the `.embedded` budget, and on EVE the logo draws from the ARGB4
//! image mirror in `RAM_G`. Run it from the repository root, or anywhere
//! with an `assets/` directory beside it.
//!
//! Resource sketch: one 320x200 image (250 KiB of RGBA, decoded once on the
//! image worker) in the `.embedded` image atlas; each frame draws one image
//! sprite, one quad, and the caption's glyphs.

const std = @import("std");
const gooey = @import("gooey");

const ui = gooey.ui;
const Cx = gooey.Cx;

const assert = std.debug.assert;

pub const State = struct {};

pub const App = gooey.App(State, render, .{
    .title = "Gooey",
    .width = 640,
    .height = 400,
    .limits = .embedded,
    .theme = &gooey.Theme.dark,
});

/// The generated entry point (contract §7).
pub const main = App.main;

pub const logo_path = "assets/gooey-logo-320.png";
const logo_width: f32 = 160;
const logo_height: f32 = 100;

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .gap = 20,
        .alignment = .center,
        .background = .bg,
    } }, .{
        ui.paint(State, cx.state(State), paintLogo, .{
            .width = .{ .fixed = logo_width },
            .height = .{ .fixed = logo_height },
        }),
        ui.text("Gooey", .{ .size = 14, .color = .subtext }),
    }));
}

fn paintLogo(_: *const State, painter: *ui.Painter) void {
    assert(painter.bounds.width > 0);
    assert(painter.bounds.height > 0);
    painter.image(logo_path, painter.bounds, .{ .fit = .contain });
}
