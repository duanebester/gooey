# Gooey Charts

A GPU-accelerated charting library for Gooey.

## Overview

Gooey Charts provides declarative, high-performance chart components that integrate seamlessly with Gooey's UI system. Charts render directly to the GPU via Gooey's canvas API, with zero dynamic allocation during render.

## Features

- **Bar Charts** — Vertical/horizontal, grouped, stacked
- **Line Charts** — Multi-series with points, areas, curves
- **Pie/Donut Charts** — With labels and legends
- **Scatter Charts** — With multiple point shapes

## Quick Start

Charts draw inside a `ui.canvas` paint callback. Series hold fixed-capacity arrays, so keep
chart data in static storage (a stack copy is too large for the WASM stack) and fill it once
at startup. This is the pattern `src/examples/dashboard.zig` uses.

```zig
const gooey = @import("gooey");
const charts = @import("gooey-charts");
const ui = gooey.ui;

var sales_data: [1]charts.CategorySeries = undefined;

fn initSales(_: *gooey.Cx) void {
    sales_data[0] = charts.CategorySeries.init("Sales", charts.Color.hex(0x4285f4));
    sales_data[0].addPoint(charts.CategoryPoint.init("Q1", 30));
    sales_data[0].addPoint(charts.CategoryPoint.init("Q2", 45));
    sales_data[0].addPoint(charts.CategoryPoint.init("Q3", 28));
    sales_data[0].addPoint(charts.CategoryPoint.init("Q4", 55));
}

fn paintSales(ctx: *ui.DrawContext) void {
    var chart = charts.BarChart.init(&sales_data);
    chart.width = ctx.width();
    chart.height = ctx.height();
    chart.render(ctx);
}

fn render(cx: *gooey.Cx) void {
    cx.render(ui.box(.{}, .{
        ui.canvas(400, 300, paintSales),
    }));
}

// Pass `.on_init = initSales` in the `gooey.App` config.
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
