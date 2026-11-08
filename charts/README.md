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
element's `painter.bounds`. Series hold fixed-capacity arrays (a `Series` is about
300 KiB), so keep chart data in app state and fill it in place from `on_init`. This
is the pattern `src/examples/dashboard.zig` uses.

```zig
const gooey = @import("gooey");
const charts = @import("gooey-charts");
const core = gooey.core;
const ui = core.ui;

const State = struct { sales: [1]charts.CategorySeries = undefined };

fn initSales(state: *State, _: *core.Effects) void {
    const sales = &state.sales[0];
    sales.* = charts.CategorySeries.init("Sales", charts.Color.hex(0x4285f4));
    sales.addPoint(charts.CategoryPoint.init("Q1", 30));
    sales.addPoint(charts.CategoryPoint.init("Q2", 45));
    sales.addPoint(charts.CategoryPoint.init("Q3", 28));
    sales.addPoint(charts.CategoryPoint.init("Q4", 55));
}

fn paintSales(state: *const State, painter: *ui.Painter) void {
    var chart = charts.BarChart.init(&state.sales);
    chart.width = painter.bounds.width;
    chart.height = painter.bounds.height;
    chart.render(painter);
}

fn render(cx: *core.Cx) void {
    cx.render(ui.paint(State, cx.state(State), paintSales, .{
        .width = .{ .fixed = 400 },
        .height = .{ .fixed = 300 },
    }));
}

pub const App = core.App(State, render, .{
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

## Limits

Per CLAUDE.md engineering guidelines, all structures have hard limits:

| Constant         | Value | Description                   |
| ---------------- | ----- | ----------------------------- |
| MAX_DATA_POINTS  | 4096  | Points per series             |
| MAX_SERIES       | 16    | Series per chart              |
| MAX_CATEGORIES   | 256   | Categories (bar chart labels) |
| MAX_TICKS        | 32    | Tick marks per axis           |
| MAX_LEGEND_ITEMS | 32    | Items in legend               |
| MAX_LABEL_LENGTH | 64    | Characters per label          |

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
