# Gooey Charts

A GPU-accelerated charting library for Gooey.

## Overview

Gooey Charts provides declarative, high-performance chart components for Gooey's core UI.
Charts draw through the `Painter` of a `ui.paint` element, with zero dynamic allocation
during render.

## Features

- **Bar Charts** — Vertical/horizontal, grouped, stacked
- **Line Charts** — Multi-series with points, areas, curves
- **Pie/Donut Charts** — With labels and legends
- **Scatter Charts** — With multiple point shapes

## Quick Start

Charts draw inside a `ui.paint` element, in window coordinates offset by the
element's `painter.bounds`. Every chart type takes required comptime capacities that
the app declares from its data, and exposes the series type they size: a
`LineChart(.{ .point_count_max = 64, .series_count_max = 2 }).Series` holds 64 points
in about 4.8 KiB. Keep chart data in app state and fill it in place from `on_init`.
This is the pattern `src/examples/dashboard.zig` uses.

```zig
const gooey = @import("gooey");
const charts = @import("gooey-charts");
const ui = gooey.ui;

/// Four quarters in one series.
const SalesChart = charts.BarChart(.{ .category_count_max = 4, .series_count_max = 1 });

const State = struct { sales: [SalesChart.series_count_max]SalesChart.Series = undefined };

fn initSales(state: *State, _: *gooey.Effects) void {
    const sales = &state.sales[0];
    sales.* = SalesChart.Series.init("Sales", charts.Color.hex(0x4285f4));
    sales.addPoint(charts.CategoryPoint.init("Q1", 30));
    sales.addPoint(charts.CategoryPoint.init("Q2", 45));
    sales.addPoint(charts.CategoryPoint.init("Q3", 28));
    sales.addPoint(charts.CategoryPoint.init("Q4", 55));
}

fn paintSales(state: *const State, painter: *ui.Painter) void {
    var chart = SalesChart.init(&state.sales);
    chart.width = painter.bounds.width;
    chart.height = painter.bounds.height;
    chart.render(painter);
}

fn render(cx: *gooey.Cx) void {
    cx.render(ui.paint(State, cx.state(State), paintSales, .{
        .width = .{ .fixed = 400 },
        .height = .{ .fixed = 300 },
    }));
}

pub const App = gooey.App(State, render, .{
    .title = "Sales",
    .width = 440,
    .height = 340,
    .limits = .standard,
    .on_init = initSales,
});
```

## Design Principles

1. **Zero allocation during render** — All data structures use fixed-capacity arrays
2. **Composable primitives** — Build custom charts from Scale, Axis, Grid, Legend
3. **Theme-aware** — Automatically adapts to Gooey's theme system
4. **Accessible** — Screen reader descriptions for all chart types

## Capacities

Per CLAUDE.md engineering guidelines, the app declares every data capacity. Each chart
type is a function of its capacities, which are required and checked at compile time
against a framework ceiling:

| Chart          | Capacity struct                               | Series type                    |
| -------------- | --------------------------------------------- | ------------------------------ |
| `LineChart`    | `.{ .point_count_max, .series_count_max }`    | `Series(point_count_max)`      |
| `ScatterChart` | `.{ .point_count_max, .series_count_max }`    | `Series(point_count_max)`      |
| `BarChart`     | `.{ .category_count_max, .series_count_max }` | `CategorySeries(category_...)` |
| `PieChart`     | `.{ .slice_count_max }`                       | `[]const CategoryPoint`        |

Filling a series past its capacity is a capacity-planning error: it panics with the
series name and the field to raise, for example `chart series 'Revenue' full: capacity
512 points, 1 requested. Raise the chart's point_count_max.`

## Limits

| Constant                 | Value | Description                                  |
| ------------------------ | ----- | -------------------------------------------- |
| `point_count_ceiling`    | 4096  | Most `point_count_max` (points per series)   |
| `series_count_ceiling`   | 16    | Most `series_count_max` (series per chart)   |
| `category_count_ceiling` | 256   | Most `category_count_max` (bar categories)   |
| `slice_count_ceiling`    | 64    | Most `slice_count_max` (pie slices)          |
| `MAX_TICKS`              | 32    | Tick marks per axis                          |
| `MAX_LEGEND_ITEMS`       | 32    | Items in legend                              |
| `MAX_LABEL_LENGTH`       | 64    | Characters per label                         |

## API Reference

### Primitives (Layer 2)

- `LinearScale` — Maps continuous data to pixel coordinates
- `BandScale` — Maps categorical data to pixel bands
- `Axis` — Renders axis line, ticks, and labels
- `Grid` — Renders background grid lines
- `Legend` — Renders chart legend

### Charts (Layer 3)

- `BarChart` — Category data as bars
- `LineChart` — Time series or continuous data
- `PieChart` — Proportional data as slices
- `ScatterChart` — X/Y point data

## License

Same license as Gooey (see root LICENSE file).
