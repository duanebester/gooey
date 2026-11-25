const std = @import("std");
const gooey = @import("gooey");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = gooey.Color;

const assert = std.debug.assert;

pub const Shimmer = gooey.Shader(.{
    .name = "shimmer",
    .Params = ShimmerParams,
    .animated = true,
    .source = .{ .msl = @embedFile("shaders/shimmer.metal") },
});

pub const ShimmerParams = extern struct {
    base: [4]f32,
    highlight: [4]f32,
    speed: f32,
    band_width: f32,
    _pad: [2]f32 = .{ 0, 0 },
};

pub const State = struct {};

pub const App = gooey.App(State, render, .{
    .title = "Shaders",
    .width = 640,
    .height = 680,
    .limits = .small,
    .theme = &gooey.Theme.catppuccin_macchiato,
    .shaders = &.{ gooey.shaders.LinearGradient, Shimmer },
});

pub const main = App.main;

pub const card_width: f32 = 320;
pub const card_height: f32 = 140;
pub const card_radius: f32 = 16;
pub const clip_width: f32 = 240;
pub const shimmer_width: f32 = 320;
pub const shimmer_height: f32 = 56;
pub const swatch_count: u32 = 6;
pub const compare_bar_width: f32 = 280;
pub const compare_bar_height: f32 = 40;
pub const fade_bar_width: f32 = 168;
pub const fade_bar_height: f32 = 40;
pub const fade_panel_color = Color.white;

pub const gradient_start = Color.rgba(0.20, 0.45, 1.00, 1);
pub const gradient_end = Color.rgba(0.85, 0.25, 0.75, 1);

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(32),
        .gap = 24,
        .background = .bg,
    } }, .{
        GradientCard{},
        ShimmerStrip{},
        Swatches{},
        Comparison{},
        Fades{},
    }));
}

const GradientCard = struct {
    pub fn render(_: GradientCard, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = card_width },
            .height = .{ .fixed = card_height },
            .padding = .all(20),
            .fill = gooey.shaders.linearGradient(.{
                .start = gradient_start,
                .end = gradient_end,
                .angle_degrees = 0,
            }),
            .corner_radius = .all(card_radius),
            .border = .{ .width = 2, .color = .{ .rgba = Color.rgba(1, 1, 1, 0.35) } },
        } }, .{ui.text("Linear gradient fill", .{
            .size = 18,
            .color = .{ .rgba = Color.white },
        })}));
    }
};

const ShimmerStrip = struct {
    pub fn render(_: ShimmerStrip, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = clip_width },
            .height = .{ .fixed = shimmer_height },
            .clip = .clip,
        } }, .{ui.box(.{ .style = .{
            .width = .{ .fixed = shimmer_width },
            .height = .{ .fixed = shimmer_height },
            .fill = Shimmer.fill(.{
                .base = .{ 0.30, 0.32, 0.40, 1 },
                .highlight = .{ 0.62, 0.65, 0.78, 1 },
                .speed = 0.6,
                .band_width = 0.25,
            }),
            .corner_radius = .all(12),
        } }, .{})}));
    }
};

const Swatches = struct {
    pub fn render(_: Swatches, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{ .direction = .row, .gap = 12 } }, .{
            Swatch{ .index = 0 }, Swatch{ .index = 1 }, Swatch{ .index = 2 },
            Swatch{ .index = 3 }, Swatch{ .index = 4 }, Swatch{ .index = 5 },
        }));
    }
};

const swatch_fills = fills: {
    var fills: [swatch_count]ui.Fill = undefined;
    for (&fills, 0..) |*fill, index| {
        const step: f32 = @floatFromInt(index);
        fill.* = gooey.shaders.linearGradient(.{
            .start = Color.rgba(1, 0.80 - step * 0.1, 0.2, 1),
            .end = Color.rgba(0.1, 0.3 + step * 0.1, 0.9, 1),
            .angle_degrees = step * 30,
        });
    }
    break :fills fills;
};

const Swatch = struct {
    index: u32,

    pub fn render(self: Swatch, cx: *Cx) void {
        assert(self.index < swatch_count);
        const step: f32 = @floatFromInt(self.index);
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = 72 },
            .height = .{ .fixed = 72 },
            .fill = swatch_fills[self.index],
            .corner_radius = .all(8 + step * 4),
        } }, .{}));
    }
};

pub const compare_pairs = [_][2]Color{
    .{ Color.rgba(1, 1, 0, 1), Color.rgba(0, 0, 1, 1) },
    .{ Color.rgba(1, 0, 0, 1), Color.rgba(0, 1, 1, 1) },
};

const Comparison = struct {
    pub fn render(_: Comparison, cx: *Cx) void {
        const label: ui.Text = .{ .size = 13, .color = .{ .rgba = Color.white } };
        cx.render(ui.box(.{ .style = .{ .direction = .column, .gap = 8 } }, .{
            ui.box(.{ .style = .{ .direction = .row, .gap = 16 } }, .{
                ui.box(.{ .style = .{ .width = .{ .fixed = compare_bar_width } } }, .{
                    ui.text("sRGB (default)", label),
                }),
                ui.text("OKLab", label),
            }),
            ComparisonRow{ .pair = 0 },
            ComparisonRow{ .pair = 1 },
        }));
    }
};

const ComparisonRow = struct {
    pair: u32,

    pub fn render(self: ComparisonRow, cx: *Cx) void {
        assert(self.pair < compare_pairs.len);
        cx.render(ui.box(.{ .style = .{ .direction = .row, .gap = 16 } }, .{
            ComparisonBar{ .pair = self.pair, .interpolation = .srgb },
            ComparisonBar{ .pair = self.pair, .interpolation = .oklab },
        }));
    }
};

const ComparisonBar = struct {
    pair: u32,
    interpolation: gooey.shaders.GradientInterpolation,

    pub fn render(self: ComparisonBar, cx: *Cx) void {
        assert(self.pair < compare_pairs.len);
        const stops = compare_pairs[self.pair];
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = compare_bar_width },
            .height = .{ .fixed = compare_bar_height },
            .fill = gooey.shaders.linearGradient(.{
                .start = stops[0],
                .end = stops[1],
                .angle_degrees = 0,
                .interpolation = self.interpolation,
            }),
            .corner_radius = .all(8),
        } }, .{}));
    }
};

pub const fade_pairs = [_][2]Color{
    .{ Color.rgba(1, 0, 0, 1), Color.rgba(0, 0, 0, 0) },
    .{ Color.rgba(1, 1, 1, 1), Color.rgba(0, 0, 1, 0) },
    .{ Color.rgba(1, 1, 0, 0.3), Color.rgba(0, 0, 1, 0.3) },
};

const Fades = struct {
    pub fn render(_: Fades, cx: *Cx) void {
        const label: ui.Text = .{ .size = 13, .color = .{ .rgba = Color.white } };
        cx.render(ui.box(.{ .style = .{ .direction = .column, .gap = 8 } }, .{
            ui.text("Fades over white: sRGB row, then OKLab row", label),
            ui.box(.{ .style = .{
                .direction = .column,
                .gap = 8,
                .padding = .all(12),
                .background = .{ .rgba = fade_panel_color },
                .corner_radius = .all(12),
            } }, .{
                FadeRow{ .interpolation = .srgb },
                FadeRow{ .interpolation = .oklab },
            }),
        }));
    }
};

const FadeRow = struct {
    interpolation: gooey.shaders.GradientInterpolation,

    pub fn render(self: FadeRow, cx: *Cx) void {
        cx.render(ui.box(.{ .style = .{ .direction = .row, .gap = 12 } }, .{
            FadeBar{ .pair = 0, .interpolation = self.interpolation },
            FadeBar{ .pair = 1, .interpolation = self.interpolation },
            FadeBar{ .pair = 2, .interpolation = self.interpolation },
        }));
    }
};

const FadeBar = struct {
    pair: u32,
    interpolation: gooey.shaders.GradientInterpolation,

    pub fn render(self: FadeBar, cx: *Cx) void {
        assert(self.pair < fade_pairs.len);
        const stops = fade_pairs[self.pair];
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = fade_bar_width },
            .height = .{ .fixed = fade_bar_height },
            .fill = gooey.shaders.linearGradient(.{
                .start = stops[0],
                .end = stops[1],
                .angle_degrees = 0,
                .interpolation = self.interpolation,
            }),
            .corner_radius = .all(8),
        } }, .{}));
    }
};
