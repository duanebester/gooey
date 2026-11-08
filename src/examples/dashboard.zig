//! Analytics dashboard on the 0.4.0 core: gooey-charts drawn into
//! `ui.paint` elements in a scrolling column.
//!
//! The line, bar, pie, and scatter charts, the legends, and the KPI cards
//! draw through each paint element's `Painter`; `T` toggles the dark and
//! light chart themes. All chart data lives in `State` and is filled by
//! `on_init`, so nothing is built or allocated while rendering.

const std = @import("std");
const gooey = @import("gooey");
const charts = @import("gooey-charts");

const core = gooey.core;
const ui = core.ui;
const Cx = core.Cx;
const Color = ui.Color;
const Painter = ui.Painter;

const assert = std.debug.assert;

/// The chart colours, in series order.
const Palette = struct {
    const primary = Color.hex(0x06b6d4);
    const secondary = Color.hex(0x8b5cf6);
    const success = Color.hex(0x10b981);
    const warning = Color.hex(0xf59e0b);
    const danger = Color.hex(0xf43f5e);
    const neutral = Color.hex(0x64748b);
    const neutral_light = Color.hex(0x94a3b8);
};

const ToggleTheme = struct {};

pub const State = struct {
    is_dark_theme: bool = true,
    revenue: [2]charts.Series = undefined,
    categories: [1]charts.CategorySeries = undefined,
    traffic: [5]charts.CategoryPoint = undefined,
    segments: [3]charts.Series = undefined,

    pub fn toggleTheme(self: *State) void {
        self.is_dark_theme = !self.is_dark_theme;
    }

    fn pick(self: *const State, dark: u32, light: u32) Color {
        return Color.hex(if (self.is_dark_theme) dark else light);
    }

    fn chartTheme(self: *const State) *const charts.ChartTheme {
        return if (self.is_dark_theme) &charts.ChartTheme.dark else &charts.ChartTheme.light;
    }

    fn background(self: *const State) Color {
        return self.pick(0x0f172a, 0xf1f5f9);
    }

    fn card(self: *const State) Color {
        return self.pick(0x1e293b, 0xffffff);
    }

    fn textColor(self: *const State) Color {
        return self.pick(0xf1f5f9, 0x1e293b);
    }

    fn mutedText(self: *const State) Color {
        return self.pick(0x94a3b8, 0x64748b);
    }

    fn grid(self: *const State) Color {
        return self.pick(0x334155, 0xe2e8f0);
    }
};

pub const App = core.App(State, render, .{
    .title = "Analytics Dashboard",
    .width = 1200,
    .height = 800,
    .limits = .standard,
    .keymap = &.{.{ .keys = "t", .action = ui.action(ToggleTheme) }},
    .on_init = fillData,
});

/// The generated entry point (contract §7).
pub const main = App.main;

/// Revenue against target, monthly; then spend against visits per segment.
const revenue_points = [_]f32{ 89, 94, 102, 98, 112, 118, 108, 125, 132, 128, 142, 156 };
const target_points = [_]f32{ 85, 90, 95, 100, 105, 110, 115, 120, 125, 130, 135, 140 };
const premium_points = [_][2]f32{
    .{ 2.1, 285 }, .{ 3.2, 320 }, .{ 2.8, 298 }, .{ 4.1, 345 }, .{ 3.5, 312 },
};
const regular_points = [_][2]f32{
    .{ 1.2, 125 }, .{ 1.8, 148 }, .{ 2.2, 165 }, .{ 1.5, 138 },
    .{ 2.5, 175 }, .{ 1.9, 155 }, .{ 2.8, 182 },
};
const casual_points = [_][2]f32{
    .{ 0.3, 45 }, .{ 0.5, 62 }, .{ 0.8, 78 }, .{ 0.4, 55 }, .{ 0.6, 68 }, .{ 0.9, 85 },
};

/// Fill the chart data in place: a `Series` is about 300 KiB.
fn fillData(state: *State, _: *core.Effects) void {
    state.revenue[0].initInPlace("Revenue", Palette.primary);
    state.revenue[1].initInPlace("Target", Palette.neutral_light);
    for (revenue_points, target_points, 1..) |revenue, target, month| {
        const x: f32 = @floatFromInt(month);
        state.revenue[0].addPoint(charts.DataPoint.init(x, revenue));
        state.revenue[1].addPoint(charts.DataPoint.init(x, target));
    }

    var sales = &state.categories[0];
    sales.* = charts.CategorySeries.init("Sales", null);
    const sales_names = [_][]const u8{ "Electronics", "Clothing", "Home", "Sports", "Books" };
    const sales_values = [_]f32{ 342, 256, 189, 145, 98 };
    for (sales_names, sales_values) |name, value| {
        sales.addPoint(charts.CategoryPoint.init(name, value));
    }

    const traffic_names = [_][]const u8{ "Organic", "Paid", "Social", "Direct", "Referral" };
    const traffic_values = [_]f32{ 42, 28, 15, 10, 5 };
    const traffic_colors = [_]Color{
        Palette.success, Palette.primary, Palette.warning, Palette.secondary, Palette.neutral,
    };
    for (&state.traffic, traffic_names, traffic_values, traffic_colors) |*slot, name, v, c| {
        slot.* = charts.CategoryPoint.initColored(name, v, c);
    }

    fillSegment(&state.segments[0], "Premium", Palette.secondary, &premium_points);
    fillSegment(&state.segments[1], "Regular", Palette.primary, &regular_points);
    fillSegment(&state.segments[2], "Casual", Palette.neutral, &casual_points);
    assert(state.revenue[0].data_len == revenue_points.len);
    assert(state.categories[0].data_len == sales_values.len);
}

fn fillSegment(
    series: *charts.Series,
    name: []const u8,
    color: Color,
    points: []const [2]f32,
) void {
    assert(points.len > 0);
    series.initInPlace(name, color);
    for (points) |point| series.addPoint(charts.DataPoint.init(point[0], point[1]));
    assert(series.data_len == points.len);
}

pub fn render(cx: *Cx) void {
    const state = cx.state(State);
    const toggle = cx.on(State.toggleTheme, .{});
    cx.render(ui.box(.{
        .actions = &.{.{ .action = ui.action(ToggleTheme), .handler = toggle }},
        .style = .{
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .all(24),
            .gap = 20,
            .background = .{ .rgba = state.background() },
        },
    }, .{ Header{}, Content{} }));
}

const Header = struct {
    pub fn render(_: Header, cx: *Cx) void {
        const state = cx.state(State);
        const title_row: ui.Style = .{ .direction = .row, .gap = 12, .alignment = .center_cross };
        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .alignment = .{ .main = .space_between, .cross = .center },
        } }, .{
            ui.box(.{ .style = .{ .gap = 4 } }, .{
                ui.box(.{ .style = title_row }, .{
                    paintBox(state, paintAccentDot, 8, 8),
                    ui.text("Analytics Dashboard", .{
                        .size = 26,
                        .color = .{ .rgba = state.textColor() },
                    }),
                }),
                ui.text("Real-time business metrics & insights", .{
                    .size = 13,
                    .color = .{ .rgba = state.mutedText() },
                }),
            }),
            ui.box(.{ .style = .{
                .padding = .symmetric(12, 6),
                .corner_radius = .all(6),
                .background = .{ .rgba = state.card() },
            } }, .{
                ui.text("[T] Toggle theme", .{
                    .size = 11,
                    .color = .{ .rgba = state.mutedText() },
                }),
            }),
        }));
    }
};

const Content = struct {
    pub fn render(_: Content, cx: *Cx) void {
        const state = cx.state(State);
        cx.render(ui.box(.{
            .key = .{ .name = "dashboard-scroll" },
            .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
                .gap = 20,
                .scroll = .{},
            },
        }, .{
            paintBox(state, paintKpiRow, 780, 110),
            Section{ .title = "Revenue Trend", .subtitle = "Monthly performance vs target" },
            paintBox(state, paintRevenue, 720, 240),
            Section{ .title = "Sales by Category", .subtitle = "Top performing categories" },
            paintBox(state, paintCategories, 520, 220),
            Section{ .title = "Traffic Sources", .subtitle = "Visitor acquisition channels" },
            paintBox(state, paintTraffic, 300, 240),
            Section{ .title = "Customer Segments", .subtitle = "Order value vs visit frequency" },
            paintBox(state, paintSegments, 520, 240),
            Section{ .title = "Conversion Rate", .subtitle = "Overall funnel performance" },
            paintBox(state, paintConversion, 220, 220),
        }));
    }
};

const Section = struct {
    title: []const u8,
    subtitle: []const u8,

    pub fn render(self: Section, cx: *Cx) void {
        const state = cx.state(State);
        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .gap = 8,
            .alignment = .{ .cross = .end },
        } }, .{
            ui.text(self.title, .{ .size = 15, .color = .{ .rgba = state.textColor() } }),
            ui.text(self.subtitle, .{ .size = 11, .color = .{ .rgba = state.mutedText() } }),
        }));
    }
};

fn paintBox(
    state: *const State,
    comptime paint_fn: fn (state: *const State, painter: *Painter) void,
    width: f32,
    height: f32,
) core.internals.element.Paint(State) {
    return ui.paint(State, state, paint_fn, .{
        .width = .{ .fixed = width },
        .height = .{ .fixed = height },
    });
}

fn paintAccentDot(_: *const State, painter: *Painter) void {
    const bounds = painter.bounds;
    painter.circle(.{ bounds.x + 4, bounds.y + 4 }, 4, Palette.primary);
}

/// A card under a chart: a soft offset shadow, then the card.
fn paintCard(state: *const State, painter: *Painter) void {
    const b = painter.bounds;
    const shadow: ui.Rect = .{
        .x = b.x + 2,
        .y = b.y + 4,
        .width = b.width - 2,
        .height = b.height - 2,
    };
    charts.paint.rect(painter, shadow, 12, state.card().withAlpha(0.3));
    charts.paint.rect(painter, b, 12, state.card());
}

/// One rectangle of a KPI card, relative to the card's top left.
const KpiPart = struct { x: f32, y: f32, width: f32, height: f32, radius: f32, color: Color };

/// Four KPI cards with placeholder bars for label, value, and change.
fn paintKpiRow(state: *const State, painter: *Painter) void {
    const accents = [_]Color{
        Palette.primary, Palette.secondary, Palette.warning, Palette.success,
    };
    const positive = [_]bool{ true, true, false, true };
    for (accents, positive, 0..) |accent, up, index| {
        const left = @as(f32, @floatFromInt(index)) * (kpi_card_width + kpi_card_gap);
        const change = if (up) Palette.success else Palette.danger;
        paintKpiCard(state, painter, .{ .left = left, .accent = accent, .change = change });
    }
}

const kpi_card_width: f32 = 185;
const kpi_card_gap: f32 = 16;

const KpiCard = struct { left: f32, accent: Color, change: Color };

fn paintKpiCard(state: *const State, painter: *Painter, kpi: KpiCard) void {
    assert(kpi.left >= 0);
    const width = kpi_card_width;
    const height = painter.bounds.height - 10;
    const card = state.card();
    const shadow = card.withAlpha(0.3);
    const muted = state.mutedText().withAlpha(0.25);
    const value = state.textColor().withAlpha(0.25);
    const pill = kpi.change.withAlpha(0.15);
    const change = kpi.change.withAlpha(0.6);
    const parts = [_]KpiPart{
        .{ .x = 2, .y = 4, .width = width, .height = height, .radius = 12, .color = shadow },
        .{ .x = 0, .y = 0, .width = width, .height = height, .radius = 12, .color = card },
        .{ .x = 16, .y = 12, .width = 40, .height = 3, .radius = 2, .color = kpi.accent },
        .{ .x = 16, .y = 24, .width = 70, .height = 9, .radius = 0, .color = muted },
        .{ .x = 16, .y = 44, .width = 90, .height = 22, .radius = 0, .color = value },
        .{ .x = 16, .y = 76, .width = 52, .height = 18, .radius = 9, .color = pill },
        .{ .x = 24, .y = 81, .width = 36, .height = 8, .radius = 0, .color = change },
    };
    for (parts) |part| {
        const bounds: ui.Rect = .{
            .x = painter.bounds.x + kpi.left + part.x,
            .y = painter.bounds.y + part.y,
            .width = part.width,
            .height = part.height,
        };
        charts.paint.rect(painter, bounds, part.radius, part.color);
    }
}

fn paintRevenue(state: *const State, painter: *Painter) void {
    paintCard(state, painter);
    const theme = state.chartTheme();
    const items = [_]charts.Legend.Item{
        .initWithShape("Revenue", Palette.primary, .line),
        .initWithShape("Target", Palette.neutral_light, .line),
    };
    const legend: charts.Legend.Options = .{
        .position = .top,
        .color = theme.foreground,
        .spacing = 24,
        .item_size = 14,
        .font_size = 11,
    };
    const legend_height = charts.Legend.calculateDimensions(&items, legend).height;
    var chart = charts.LineChart.init(&state.revenue);
    chart.width = painter.bounds.width;
    chart.height = painter.bounds.height;
    chart.margin_top = 16 + legend_height;
    chart.margin_right = 20;
    chart.margin_bottom = 40;
    chart.margin_left = 50;
    chart.line_width = 2.5;
    chart.point_radius = 4;
    chart.show_area = true;
    chart.area_opacity = 0.15;
    chart.chart_theme = theme;
    chart.grid_opts = .{ .show_horizontal = true, .show_vertical = false };
    chart.render(painter);
    drawLegend(painter, &items, legend, legend_height);
}

fn paintCategories(state: *const State, painter: *Painter) void {
    paintCard(state, painter);
    var chart = charts.BarChart.init(&state.categories);
    chart.width = painter.bounds.width;
    chart.height = painter.bounds.height;
    chart.margin_top = 20;
    chart.margin_right = 20;
    chart.margin_bottom = 50;
    chart.margin_left = 50;
    chart.corner_radius = 4;
    chart.bar_padding = 0.35;
    chart.chart_theme = state.chartTheme();
    chart.grid_opts = .{ .show_horizontal = true, .show_vertical = false };
    chart.render(painter);
}

fn paintTraffic(state: *const State, painter: *Painter) void {
    paintCard(state, painter);
    var chart = charts.PieChart.init(&state.traffic);
    chart.width = painter.bounds.width;
    chart.height = painter.bounds.height - 30;
    chart.inner_radius_ratio = 0.55;
    chart.gap_pixels = 3;
    chart.render(painter);
}

fn paintSegments(state: *const State, painter: *Painter) void {
    paintCard(state, painter);
    const theme = state.chartTheme();
    const items = [_]charts.Legend.Item{
        .initWithShape("Premium", Palette.secondary, .circle),
        .initWithShape("Regular", Palette.primary, .circle),
        .initWithShape("Casual", Palette.neutral, .circle),
    };
    const legend: charts.Legend.Options = .{
        .position = .top,
        .color = theme.foreground,
        .spacing = 20,
        .item_size = 12,
        .font_size = 11,
    };
    const legend_height = charts.Legend.calculateDimensions(&items, legend).height;
    var chart = charts.ScatterChart.init(&state.segments);
    chart.width = painter.bounds.width;
    chart.height = painter.bounds.height;
    chart.margin_top = 16 + legend_height;
    chart.margin_right = 20;
    chart.margin_bottom = 45;
    chart.margin_left = 50;
    chart.point_radius = 7;
    chart.point_opacity = 0.85;
    chart.chart_theme = theme;
    chart.grid_opts = .{ .show_horizontal = true, .show_vertical = true };
    chart.render(painter);
    drawLegend(painter, &items, legend, legend_height);
}

fn drawLegend(
    painter: *Painter,
    items: []const charts.Legend.Item,
    options: charts.Legend.Options,
    height: f32,
) void {
    const bounds = painter.bounds;
    _ = charts.Legend.draw(painter, .{
        .x = bounds.x + 16,
        .y = bounds.y + 14,
        .width = bounds.width - 32,
        .height = height,
    }, items, options);
}

/// A progress ring of the conversion rate out of 10%, with a centre marker.
fn paintConversion(state: *const State, painter: *Painter) void {
    paintCard(state, painter);
    const conversion_percent: f32 = 3.24;
    const scale_max_percent: f32 = 10;
    const ring = [_]charts.CategoryPoint{
        .initColored("Converted", conversion_percent, Palette.success),
        .initColored("Remaining", scale_max_percent - conversion_percent, state.grid()),
    };
    var chart = charts.PieChart.init(&ring);
    chart.width = painter.bounds.width;
    chart.height = painter.bounds.height - 40;
    chart.inner_radius_ratio = 0.72;
    chart.pad_angle = 0;
    chart.start_angle = -std.math.pi / 2.0;
    chart.render(painter);

    const center = [2]f32{
        painter.bounds.x + painter.bounds.width / 2,
        painter.bounds.y + painter.bounds.height / 2,
    };
    painter.circle(center, 14, Palette.success.withAlpha(0.15));
    painter.circle(center, 10, Palette.success.withAlpha(0.3));
    painter.circle(center, 6, Palette.success);
}
