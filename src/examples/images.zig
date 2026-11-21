const std = @import("std");
const gooey = @import("gooey");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = ui.Color;

const assert = std.debug.assert;

pub const State = struct {};

pub const App = gooey.App(State, render, .{
    .title = "Image Component Example",
    .width = 900,
    .height = 700,
    .limits = .large,
});

pub const main = App.main;

pub const logo_path = "assets/ziglang_logo.png";

const background = Color.hex(0x1a1a2e);
const panel = Color.hex(0x16213e);
const heading_color = Color.hex(0x888888);
const label_color = Color.hex(0x666666);

pub const Item = struct {
    label: []const u8,
    width: f32,
    height: f32,
    style: ui.PaintImage,

    fn square(label: []const u8, size: f32, style: ui.PaintImage) Item {
        return .{ .label = label, .width = size, .height = size, .style = style };
    }
};

const plain: ui.PaintImage = .{ .fit = .contain };

fn rounded(radius: f32) ui.PaintImage {
    return .{ .fit = .contain, .corners = .all(radius) };
}

pub const sizing = [_]Item{
    .square("32x32", 32, plain),
    .square("64x64", 64, plain),
    .square("128x128", 128, plain),
    .{ .label = "200x80", .width = 200, .height = 80, .style = plain },
};

pub const fit_modes = [_]Item{
    .square("contain", 100, .{ .fit = .contain }),
    .square("cover", 100, .{ .fit = .cover }),
    .square("fill", 100, .{ .fit = .fill }),
    .square("none", 100, .{ .fit = .none }),
};

pub const corner_radius = [_]Item{
    .square("none", 80, plain),
    .square("8px", 80, rounded(8)),
    .square("20px", 80, rounded(20)),
    .square("circle", 80, rounded(40)),
};

pub const effects = [_]Item{
    .square("normal", 80, rounded(8)),
    .square("tint (multiply)", 80, .{
        .fit = .contain,
        .corners = .all(8),
        .tint = Color.hex(0x4488ff),
    }),
    .square("grayscale", 80, .{ .fit = .contain, .corners = .all(8), .grayscale = 1 }),
    .square("50% gray", 80, .{ .fit = .contain, .corners = .all(8), .grayscale = 0.5 }),
    .square("50% opacity", 80, .{ .fit = .contain, .corners = .all(8), .opacity = 0.5 }),
    .square("combined", 80, .{
        .fit = .contain,
        .corners = .all(40),
        .tint = Color.hex(0xff6644),
        .grayscale = 0.8,
        .opacity = 0.9,
    }),
};

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(24),
        .gap = 16,
        .background = .{ .rgba = background },
    } }, .{
        ui.text("Image Component Demo", .{
            .size = 24,
            .weight = .bold,
            .color = .{ .rgba = Color.white },
        }),
        ui.box(.{ .key = .{ .name = "images-scroll" }, .style = .{
            .width = .{ .fixed = 852 },
            .height = .{ .grow = 1 },
            .padding = .all(4),
            .gap = 24,
            .background = .{ .rgba = background },
            .scroll = .{},
        } }, .{
            Section{ .title = "Sizing", .items = &sizing },
            Section{ .title = "Object Fit Modes", .items = &fit_modes },
            Section{ .title = "Corner Radius", .items = &corner_radius },
            Section{ .title = "Visual Effects", .items = &effects },
        }),
    }));
}

const Section = struct {
    title: []const u8,
    items: []const Item,

    pub fn render(self: Section, cx: *Cx) void {
        assert(self.items.len > 0);
        assert(self.title.len > 0);
        cx.render(ui.box(.{ .style = .{ .gap = 12, .width = .{ .grow = 1 } } }, .{
            ui.text(self.title, .{
                .size = 16,
                .weight = .medium,
                .color = .{ .rgba = heading_color },
            }),
            ui.box(.{ .style = .{
                .direction = .row,
                .gap = 16,
                .padding = .all(16),
                .background = .{ .rgba = panel },
                .corner_radius = .all(8),
            } }, .{Cells{ .items = self.items }}),
        }));
    }
};

const Cells = struct {
    items: []const Item,

    pub fn render(self: Cells, cx: *Cx) void {
        assert(self.items.len > 0);
        assert(self.items.len <= effects.len);
        for (self.items) |*item| {
            cx.render(ui.box(.{ .style = .{ .gap = 8, .alignment = .center_cross } }, .{
                ui.paint(Item, item, paintImage, .{
                    .width = .{ .fixed = item.width },
                    .height = .{ .fixed = item.height },
                }),
                ui.text(item.label, .{ .size = 12, .color = .{ .rgba = label_color } }),
            }));
        }
    }
};

fn paintImage(item: *const Item, painter: *ui.Painter) void {
    assert(item.width > 0);
    assert(item.height > 0);
    painter.image(logo_path, painter.bounds, item.style);
}
