//! Minimal repro: two line charts rendered side-by-side.
//!
//! Tests whether gooey can render polylines in two canvases
//! that are both visible at the same time (no scroll view).

const std = @import("std");
const gooey = @import("gooey");
const charts = @import("gooey-charts");

const ui = gooey.ui;
const Cx = gooey.Cx;

// ─── Static chart data ───────────────────────────────────────────────────────

var series_a: [1]charts.Series = undefined;
var series_b: [1]charts.Series = undefined;
var data_initialized: bool = false;

fn ensureDataInitialized() void {
    if (data_initialized) return;

    series_a[0].initInPlace("Series A", charts.Color.hex(0xfbbc05));
    series_a[0].addPoint(charts.DataPoint.init(1, 10));
    series_a[0].addPoint(charts.DataPoint.init(2, 25));
    series_a[0].addPoint(charts.DataPoint.init(3, 18));
    series_a[0].addPoint(charts.DataPoint.init(4, 32));
    series_a[0].addPoint(charts.DataPoint.init(5, 28));
    series_a[0].addPoint(charts.DataPoint.init(6, 40));

    series_b[0].initInPlace("Series B", charts.Color.hex(0x34a853));
    series_b[0].addPoint(charts.DataPoint.init(1, 50));
    series_b[0].addPoint(charts.DataPoint.init(2, 65));
    series_b[0].addPoint(charts.DataPoint.init(3, 58));
    series_b[0].addPoint(charts.DataPoint.init(4, 72));
    series_b[0].addPoint(charts.DataPoint.init(5, 68));
    series_b[0].addPoint(charts.DataPoint.init(6, 80));

    data_initialized = true;
}

// ─── Paint callbacks ─────────────────────────────────────────────────────────

fn paintChartA(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();
    if (w <= 0 or h <= 0) return;

    ctx.fillRoundedRect(0, 0, w, h, 8, ui.Color.hex(0x16213e));

    var chart = charts.LineChart.init(&series_a);
    chart.width = w;
    chart.height = h;
    chart.margin_top = 20;
    chart.margin_right = 20;
    chart.margin_bottom = 40;
    chart.margin_left = 50;
    chart.line_width = 2.5;
    chart.show_points = true;
    chart.point_radius = 4;
    chart.show_area = false;
    chart.show_grid = true;
    chart.grid_opts = .{
        .show_horizontal = true,
        .show_vertical = false,
        .color = ui.Color.hex(0x2a3a5e),
        .line_width = 1,
    };
    chart.x_axis_opts = .{
        .orientation = .bottom,
        .color = ui.Color.hex(0x4a5a7e),
        .label_color = ui.Color.hex(0xcccccc),
    };
    chart.y_axis_opts = .{
        .orientation = .left,
        .color = ui.Color.hex(0x4a5a7e),
        .label_color = ui.Color.hex(0xcccccc),
    };

    chart.render(ctx);
}

fn paintChartB(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();
    if (w <= 0 or h <= 0) return;

    ctx.fillRoundedRect(0, 0, w, h, 8, ui.Color.hex(0x16213e));

    var chart = charts.LineChart.init(&series_b);
    chart.width = w;
    chart.height = h;
    chart.margin_top = 20;
    chart.margin_right = 20;
    chart.margin_bottom = 40;
    chart.margin_left = 50;
    chart.line_width = 2.5;
    chart.show_points = true;
    chart.point_radius = 4;
    chart.show_area = false;
    chart.show_grid = true;
    chart.grid_opts = .{
        .show_horizontal = true,
        .show_vertical = false,
        .color = ui.Color.hex(0x2a3a5e),
        .line_width = 1,
    };
    chart.x_axis_opts = .{
        .orientation = .bottom,
        .color = ui.Color.hex(0x4a5a7e),
        .label_color = ui.Color.hex(0xcccccc),
    };
    chart.y_axis_opts = .{
        .orientation = .left,
        .color = ui.Color.hex(0x4a5a7e),
        .label_color = ui.Color.hex(0xcccccc),
    };

    chart.render(ctx);
}

// ─── Application ─────────────────────────────────────────────────────────────

const AppState = struct {
    _pad: u8 = 0,
};

var state = AppState{};

fn render(cx: *Cx) void {
    const size = cx.windowSize();

    ensureDataInitialized();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 20 },
        .gap = 15,
        .direction = .column,
        .background = ui.Color.hex(0x1a1a2e),
    }, .{
        ui.text("Two Line Charts — Side by Side", .{
            .size = 24,
            .color = ui.Color.white,
        }),

        ui.hstack(.{ .gap = 16 }, .{
            ui.vstack(.{ .gap = 4 }, .{
                ui.text("Chart A (yellow)", .{
                    .size = 14,
                    .color = ui.Color.hex(0xaaaaaa),
                }),
                ui.canvas(320, 200, paintChartA),
            }),
            ui.vstack(.{ .gap = 4 }, .{
                ui.text("Chart B (green)", .{
                    .size = 14,
                    .color = ui.Color.hex(0xaaaaaa),
                }),
                ui.canvas(320, 200, paintChartB),
            }),
        }),
    }));
}

const App = gooey.App(AppState, &state, render, .{
    .title = "Two Line Charts Repro",
    .width = 720,
    .height = 340,
});

comptime {
    _ = App;
}

pub fn main() !void {
    return App.main();
}
