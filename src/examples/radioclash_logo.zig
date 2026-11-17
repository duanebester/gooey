//! RadioClash logo: PNG images on a board panel.
//!
//! The RadioClash wordmark at its decoded size, and the shield drawn 1:1,
//! scaled up, scaled down, and with rounded corners. Written for the EVE
//! backend (`-Dlinux-backend=eve`), where each draws from one ARGB4 copy of
//! the image atlas in `RAM_G`; it runs on every backend. Run it from the
//! repository root, or anywhere with an `assets/` directory beside it.
//!
//! Resource sketch: two images, 360x67 and 103x112, land in the `.embedded`
//! profile's 384² image atlas (about 50 KiB of RGBA, 25 KiB of ARGB4 on the
//! chip), one per frame; each frame draws five image sprites.

const std = @import("std");
const gooey = @import("gooey");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = ui.Color;

const assert = std.debug.assert;

pub const State = struct {};

pub const App = gooey.App(State, render, .{
    .title = "RadioClash",
    .width = 1024,
    .height = 600,
    .limits = .embedded,
});

/// The generated entry point (contract §7).
pub const main = App.main;

pub const wordmark_path = "assets/radioclash-wordmark.png";
pub const shield_path = "assets/radioclash-shield.png";

const background = Color.hex(0x14142a);
const panel = Color.hex(0x1f1f3d);
const label_color = Color.hex(0x9a9ab8);

/// One shield drawing: its box, how it fits, and the label under it.
const Shield = struct {
    label: []const u8,
    side: f32,
    style: ui.PaintImage,
};

const shields = [_]Shield{
    .{ .label = "1:1", .side = 112, .style = .{ .fit = .contain } },
    .{ .label = "1.5x, bilinear", .side = 168, .style = .{ .fit = .contain } },
    .{ .label = "0.5x", .side = 56, .style = .{ .fit = .contain } },
    .{ .label = "rounded, faded", .side = 112, .style = .{
        .fit = .cover,
        .corners = .all(24),
        .opacity = 0.6,
    } },
};

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(32),
        .gap = 32,
        .alignment = .center_cross,
        .background = .{ .rgba = background },
    } }, .{
        ui.paint(State, cx.state(State), paintWordmark, .{
            .width = .{ .fixed = 360 },
            .height = .{ .fixed = 67 },
        }),
        ui.box(.{ .style = .{ .direction = .row, .gap = 24, .alignment = .{ .cross = .end } } }, .{
            ShieldCell{ .shield = &shields[0] },
            ShieldCell{ .shield = &shields[1] },
            ShieldCell{ .shield = &shields[2] },
            ShieldCell{ .shield = &shields[3] },
        }),
        ui.text("PNG images on an EVE panel: ARGB4 in RAM_G, drawn with VERTEX2II", .{
            .size = 16,
            .color = .{ .rgba = label_color },
        }),
    }));
}

const ShieldCell = struct {
    shield: *const Shield,

    pub fn render(self: ShieldCell, cx: *Cx) void {
        assert(self.shield.side > 0);
        cx.render(ui.box(.{ .style = .{
            .padding = .all(12),
            .gap = 8,
            .alignment = .center_cross,
            .background = .{ .rgba = panel },
            .corner_radius = .all(12),
        } }, .{
            ui.paint(Shield, self.shield, paintShield, .{
                .width = .{ .fixed = self.shield.side },
                .height = .{ .fixed = self.shield.side },
            }),
            ui.text(self.shield.label, .{ .size = 14, .color = .{ .rgba = label_color } }),
        }));
    }
};

fn paintWordmark(_: *const State, painter: *ui.Painter) void {
    assert(painter.bounds.width > 0);
    assert(painter.bounds.height > 0);
    painter.image(wordmark_path, painter.bounds, .{ .fit = .contain });
}

fn paintShield(shield: *const Shield, painter: *ui.Painter) void {
    assert(painter.bounds.width > 0);
    assert(shield.side > 0);
    painter.image(shield_path, painter.bounds, shield.style);
}
