# Gooey Charts Documentation

Gooey Charts (`gooey-charts`) is an optional data visualization library built on Gooey's Canvas API. It provides high-performance, GPU-accelerated charting components with zero allocation during rendering, theme integration, and accessibility support.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Memory Safety](#memory-safety)
- [Core Data Types](#core-data-types)
- [Chart Components](#chart-components)
- [Primitives](#primitives)
- [Theming](#theming)
- [Accessibility](#accessibility)
- [Performance](#performance)
- [API Reference](#api-reference)
- [Examples](#examples)
- [References](#references)

---

## Overview

### What Is This?

`gooey-charts` is an **optional sub-package** within the Gooey monorepo that provides data visualization components built on top of Gooey's `DrawContext` API. Users opt-in by importing the `gooey-charts` module.

### Why Separate?

| Reason                | Explanation                                           |
| --------------------- | ----------------------------------------------------- |
| **Keeps core small**  | Not every app needs charts                            |
| **Different cadence** | Charts evolve faster (new types, features)            |
| **Industry standard** | SwiftUI Charts, Qt Charts, ImPlot — all separate      |
| **Domain-specific**   | Data viz has unique concerns (scales, large datasets) |
| **Zig philosophy**    | Minimal, composable pieces                            |

### Goals

1. **Simple API** — Common charts in 1-3 lines of code
2. **Composable** — Mix chart types, customize axes, layer annotations
3. **Performant** — Static allocation, GPU-accelerated via Canvas
4. **Accessible** — Screen reader support for chart data
5. **Themed** — Inherit Gooey's theme system

### Non-Goals

- Real-time streaming data (future)
- 3D charts
- Geographic/map visualizations
- Complex statistical plots (box plots, violin plots)

---

## Quick Start

### Installation

Import both gooey and gooey-charts in your build:

```gooey/docs/charts.md#L50-58
// build.zig
const gooey_dep = b.dependency("gooey", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("gooey", gooey_dep.module("gooey"));
exe.root_module.addImport("gooey-charts", gooey_dep.module("gooey-charts"));

// your_app.zig
const gooey = @import("gooey");
const charts = @import("gooey-charts");
```

### Simple Bar Chart

```gooey/docs/charts.md#L62-89
const std = @import("std");
const gooey = @import("gooey");
const charts = @import("gooey-charts");
const ui = gooey.ui;

// Data stored in static memory (survives paint callback)
var quarterly_sales: charts.CategorySeries = undefined;
var chart_data: [1]charts.CategorySeries = undefined;
var data_initialized: bool = false;

fn ensureDataInitialized() void {
    if (data_initialized) return;
    quarterly_sales = charts.CategorySeries.init("Sales 2024", charts.Color.hex(0x4285f4));
    quarterly_sales.addPoint(charts.CategoryPoint.init("Q1", 42));
    quarterly_sales.addPoint(charts.CategoryPoint.init("Q2", 58));
    quarterly_sales.addPoint(charts.CategoryPoint.init("Q3", 35));
    quarterly_sales.addPoint(charts.CategoryPoint.init("Q4", 71));
    chart_data[0] = quarterly_sales;
    data_initialized = true;
}

fn paintBarChart(ctx: *ui.DrawContext) void {
    ensureDataInitialized();
    var chart = charts.BarChart.init(&chart_data);
    chart.width = ctx.width();
    chart.height = ctx.height();
    chart.render(ctx);
}
```

### Simple Line Chart

```gooey/docs/charts.md#L93-118
var line_data: [2]charts.Series = undefined;

fn ensureLineDataInitialized() void {
    // Use initInPlace to avoid 304KB return-by-value stack allocation
    line_data[0].initInPlace("Revenue", charts.Color.hex(0x34a853));
    line_data[0].addPoint(charts.DataPoint.init(1, 45));
    line_data[0].addPoint(charts.DataPoint.init(2, 52));
    line_data[0].addPoint(charts.DataPoint.init(3, 61));
    // ... more points

    line_data[1].initInPlace("Expenses", charts.Color.hex(0xea4335));
    line_data[1].addPoint(charts.DataPoint.init(1, 38));
    line_data[1].addPoint(charts.DataPoint.init(2, 42));
    line_data[1].addPoint(charts.DataPoint.init(3, 45));
}

fn paintLineChart(ctx: *ui.DrawContext) void {
    var chart = charts.LineChart.init(&line_data);
    chart.width = ctx.width();
    chart.height = ctx.height();
    chart.line_width = 2.5;
    chart.show_points = true;
    chart.show_area = true;
    chart.render(ctx);
}
```

### Using Canvas

Charts are rendered via Gooey's canvas system:

```gooey/docs/charts.md#L124-132
fn render(cx: *gooey.Cx) void {
    cx.render(ui.box(.{ .padding = .{ .all = 20 } }, .{
        // Bar chart at 400x300 pixels
        ui.canvas(400, 300, paintBarChart),

        // Line chart at 500x200 pixels
        ui.canvas(500, 200, paintLineChart),
    }));
}
```

---

## Architecture

### Layered Design

```
┌─────────────────────────────────────────────────────────┐
│  Layer 3: Chart Components                              │
│  BarChart, LineChart, PieChart, ScatterChart            │
│  (High-level, data-driven)                              │
├─────────────────────────────────────────────────────────┤
│  Layer 2: Chart Primitives                              │
│  Axis, Grid, Legend, Scale (Linear, Band)               │
│  (Reusable across chart types)                          │
├─────────────────────────────────────────────────────────┤
│  Layer 1: Gooey Canvas (EXTERNAL)                       │
│  DrawContext: fillRect, polyline, pointCloud, etc.      │
│  (Foundation — NOT part of this package)                │
└─────────────────────────────────────────────────────────┘
```

### Key Components

| Component      | File                       | Purpose                    |
| -------------- | -------------------------- | -------------------------- |
| `BarChart`     | `charts/bar_chart.zig`     | Categorical bar charts     |
| `LineChart`    | `charts/line_chart.zig`    | XY line/area charts        |
| `PieChart`     | `charts/pie_chart.zig`     | Pie and donut charts       |
| `ScatterChart` | `charts/scatter_chart.zig` | XY scatter plots           |
| `LinearScale`  | `primitives/scale.zig`     | Numeric data → pixels      |
| `BandScale`    | `primitives/scale.zig`     | Categories → pixels        |
| `Axis`         | `primitives/axis.zig`      | Tick marks and labels      |
| `Grid`         | `primitives/grid.zig`      | Background grid lines      |
| `Legend`       | `primitives/legend.zig`    | Series color key           |
| `ChartTheme`   | `theme.zig`                | Color palettes and styling |

### Project Structure

```
gooey/
├── charts/
│   ├── build.zig
│   ├── build.zig.zon
│   └── src/
│       ├── root.zig           # Public exports
│       ├── constants.zig      # Limits and config
│       ├── types.zig          # DataPoint, Series, etc.
│       ├── util.zig           # Nice numbers, tick generation
│       ├── theme.zig          # ChartTheme
│       ├── accessibility.zig  # Screen reader support
│       ├── primitives/
│       │   ├── scale.zig
│       │   ├── axis.zig
│       │   ├── grid.zig
│       │   └── legend.zig
│       └── charts/
│           ├── bar_chart.zig
│           ├── line_chart.zig
│           ├── pie_chart.zig
│           └── scatter_chart.zig
└── src/examples/
    ├── charts_demo.zig        # Chart types showcase
    └── dashboard.zig          # Multi-chart dashboard
```

---

## Memory Safety

Following Gooey's `CLAUDE.md` principles, the charts library is designed to prevent stack overflow and ensure predictable performance.

### Design Principles

1. **Static Allocation** — Pre-allocate arrays for data points, legend items
2. **Hard Limits** — `MAX_DATA_POINTS = 4096`, `MAX_SERIES = 16`
3. **No Recursion** — Iterative rendering
4. **Fail Fast** — Assert on invalid data, don't silently clamp
5. **Slice-Based Data** — Charts reference external data, not embed it

### Common Stack Overflow Patterns (And Fixes)

#### Problem 1: Large Embedded Arrays

Embedding `[MAX_SERIES]CategorySeries` (~305KB) directly in chart structs causes stack overflow.

```gooey/docs/charts.md#L226-237
// ❌ BAD: Embeds ~305KB in struct
pub const BarChart = struct {
    data: [MAX_SERIES]CategorySeries = undefined,  // ~305KB!
    // ...
};

// ✅ GOOD: Just a 16-byte slice pointer
pub const BarChart = struct {
    data: []const CategorySeries,  // 16 bytes (pointer + length)
    // ...
};
```

**Solution:** Charts store **slices** to externally-owned data instead of embedding arrays. Callers own data in static/global memory; charts reference via slice.

#### Problem 2: For Loop Value Capture

Using `|series|` in a for loop copies the entire struct onto the stack each iteration.

```gooey/docs/charts.md#L245-254
// Series is 304KB! This copies 304KB per iteration:
for (self.data) |series| {        // ❌ BAD: copies 304KB to stack
    const extent = series.xExtent();
}

// ✅ GOOD: No copy, just a pointer (8 bytes)
for (self.data) |*series| {
    const extent = series.xExtent();
}
```

**Rule:** When iterating over slices of large structs, ALWAYS use `|*item|` pointer capture.

#### Problem 3: Return-by-Value Copies

`Series.init()` returns a 304KB struct by value, causing stack overflow.

```gooey/docs/charts.md#L262-273
// Series is 304KB! This puts 304KB on the stack:
var series = Series.init("Revenue", color);  // ❌ BAD

// Assigning to static memory still uses stack as intermediate:
line_chart_data[0] = Series.init("Revenue", color);  // ❌ BAD

// ✅ GOOD: Initialize directly into static/heap memory
line_chart_data[0].initInPlace("Revenue", color);

// Implementation must be noinline to prevent stack frame combining
pub noinline fn initInPlace(self: *Series, name: []const u8, color: Color) void { ... }
```

**Rule:** For structs > 50KB, use `initInPlace()` methods marked `noinline`.

#### Problem 4: Path Struct is ~70KB

The `Path` struct used for arbitrary vector graphics is ~70KB. Charts avoid it.

```gooey/docs/charts.md#L281-293
// ❌ BAD: 70KB Path on stack
var path = Path.init();
_ = path.moveTo(x1, y1);
_ = path.lineTo(x2, y2);
ctx.strokePath(&path, stroke_width, color);

// ✅ GOOD: Use optimized chart primitives
ctx.polyline(points[0..count], line_width, color);  // Line charts
ctx.pointCloud(centers[0..count], radius, color);   // Scatter/markers
ctx.fillCircle(cx, cy, radius, color);              // Individual points
```

### Struct Size Targets

| Struct         | Max Size    | Rationale                           |
| -------------- | ----------- | ----------------------------------- |
| BarChart       | < 300 bytes | Safe on stack in paint callbacks    |
| LineChart      | < 300 bytes | Same                                |
| PieChart       | < 100 bytes | Same                                |
| ScatterChart   | < 300 bytes | Same                                |
| CategorySeries | ~19KB       | Store in static/heap, pass by slice |
| Series         | ~304KB      | Store in static/heap, pass by slice |

---

## Core Data Types

### DataPoint

For XY charts (line, scatter):

```gooey/docs/charts.md#L313-320
pub const DataPoint = struct {
    x: f32,
    y: f32,
    label: ?[]const u8 = null,  // For tooltips

    pub fn init(x: f32, y: f32) DataPoint;
};
```

### CategoryPoint

For categorical charts (bar, pie):

```gooey/docs/charts.md#L326-335
pub const CategoryPoint = struct {
    label: [MAX_LABEL_LENGTH]u8,
    label_len: u32,
    value: f32,
    color: ?Color = null,  // Override series color

    pub fn init(label: []const u8, value: f32) CategoryPoint;
    pub fn initColored(label: []const u8, value: f32, color: Color) CategoryPoint;
};
```

### Series

For XY data with multiple points:

```gooey/docs/charts.md#L341-354
pub const Series = struct {
    name: [MAX_LABEL_LENGTH]u8,
    data: [MAX_DATA_POINTS]DataPoint,
    data_len: u32,
    color: ?Color = null,  // null = use theme palette

    pub fn init(name: []const u8, color: ?Color) Series;       // ❌ Returns 304KB
    pub fn initInPlace(self: *Series, name: []const u8, color: ?Color) void;  // ✅ Safe

    pub fn addPoint(self: *Series, point: DataPoint) void;
    pub fn xExtent(self: *const Series) struct { min: f32, max: f32 };
    pub fn yExtent(self: *const Series) struct { min: f32, max: f32 };
};
```

### CategorySeries

For categorical data with multiple points:

```gooey/docs/charts.md#L360-371
pub const CategorySeries = struct {
    name: [MAX_LABEL_LENGTH]u8,
    data: [MAX_CATEGORIES]CategoryPoint,
    data_len: u32,
    color: ?Color = null,

    pub fn init(name: []const u8, color: ?Color) CategorySeries;
    pub fn initInPlace(self: *CategorySeries, name: []const u8, color: ?Color) void;

    pub fn addPoint(self: *CategorySeries, point: CategoryPoint) void;
    pub fn maxValue(self: *const CategorySeries) f32;
};
```

---

## Chart Components

### BarChart

Renders categorical data as vertical bars.

```gooey/docs/charts.md#L381-420
pub const BarChart = struct {
    // Data (slice to external storage)
    data: []const CategorySeries,

    // Dimensions
    width: f32 = 400,
    height: f32 = 300,

    // Margins
    margin_top: f32 = 20,
    margin_right: f32 = 20,
    margin_bottom: f32 = 40,
    margin_left: f32 = 50,

    // Style
    bar_padding: f32 = 0.1,      // Inner padding (0-1)
    group_padding: f32 = 0.2,    // Between groups (0-1)
    corner_radius: f32 = 0,

    // Axes
    show_x_axis: bool = true,
    show_y_axis: bool = true,
    x_axis_opts: Axis.Options = .{ .orientation = .bottom },
    y_axis_opts: Axis.Options = .{ .orientation = .left },

    // Grid
    show_grid: bool = true,
    grid_opts: Grid.Options = .{},

    // Theme
    chart_theme: ?*const ChartTheme = null,

    pub fn init(data: []const CategorySeries) BarChart;
    pub fn initSingle(series: *const CategorySeries) BarChart;
    pub fn render(self: *const BarChart, ctx: *DrawContext) void;

    // Accessibility
    pub fn getAccessibilityInfo(self: *const BarChart) accessibility.ChartInfo;
    pub fn describe(self: *const BarChart, buf: []u8) []const u8;
};
```

**Example:**

```gooey/docs/charts.md#L424-438
fn paintBarChart(ctx: *ui.DrawContext) void {
    var chart = charts.BarChart.init(&bar_data);
    chart.width = ctx.width();
    chart.height = ctx.height();
    chart.corner_radius = 4;
    chart.show_grid = true;
    chart.grid_opts = .{
        .show_horizontal = true,
        .show_vertical = false,
        .color = ui.Color.hex(0x2a3a5e),
    };
    chart.chart_theme = &charts.ChartTheme.dark;
    chart.render(ctx);
}
```

### LineChart

Renders XY data as connected lines with optional area fill and point markers.

```gooey/docs/charts.md#L446-499
pub const LineChart = struct {
    // Data (slice to external storage)
    data: []const Series,

    // Dimensions
    width: f32 = 400,
    height: f32 = 300,

    // Margins
    margin_top: f32 = 20,
    margin_right: f32 = 20,
    margin_bottom: f32 = 40,
    margin_left: f32 = 50,

    // Line styling
    line_width: f32 = 2.0,

    // Point markers
    show_points: bool = true,
    point_radius: f32 = 4.0,

    // Area fill
    show_area: bool = false,
    area_opacity: f32 = 0.3,

    // Domain overrides (null = auto-detect)
    x_domain_min: ?f32 = null,
    x_domain_max: ?f32 = null,
    y_domain_min: ?f32 = null,
    y_domain_max: ?f32 = null,

    // Axes & Grid
    show_x_axis: bool = true,
    show_y_axis: bool = true,
    show_grid: bool = true,
    x_axis_opts: Axis.Options = .{},
    y_axis_opts: Axis.Options = .{ .orientation = .left },
    grid_opts: Grid.Options = .{},

    // Theme
    chart_theme: ?*const ChartTheme = null,

    // Level-of-detail (for large datasets)
    enable_lod: bool = true,
    lod_target_points: u32 = 1000,

    pub fn init(data: []const Series) LineChart;
    pub fn initSingle(series: *const Series) LineChart;
    pub fn render(self: *const LineChart, ctx: *DrawContext) void;

    // Accessibility
    pub fn getAccessibilityInfo(self: *const LineChart) accessibility.ChartInfo;
    pub fn describe(self: *const LineChart, buf: []u8) []const u8;
};
```

**Example with Legend:**

```gooey/docs/charts.md#L503-532
fn paintLineChart(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();

    // Legend items
    const legend_items = [_]charts.Legend.Item{
        charts.Legend.Item.initWithShape("Revenue", charts.Color.hex(0x34a853), .line),
        charts.Legend.Item.initWithShape("Expenses", charts.Color.hex(0xea4335), .line),
    };

    const legend_opts = charts.Legend.Options{
        .position = .top,
        .color = ui.Color.hex(0xcccccc),
    };
    const legend_dims = charts.Legend.calculateDimensions(&legend_items, legend_opts);

    // Create chart with room for legend
    var chart = charts.LineChart.init(&line_data);
    chart.width = w;
    chart.height = h;
    chart.margin_top = 10 + legend_dims.height;
    chart.line_width = 2.5;
    chart.show_points = true;
    chart.show_area = true;
    chart.render(ctx);

    // Draw legend
    _ = charts.Legend.draw(ctx,
        .{ .x = 0, .y = 5, .width = w, .height = legend_dims.height },
        &legend_items, legend_opts);
}
```

### PieChart

Renders categorical data as pie or donut charts.

```gooey/docs/charts.md#L540-579
pub const PieChart = struct {
    pub const LabelPosition = enum { inside, outside, none };

    // Data (slice to external storage)
    data: []const CategoryPoint,

    // Dimensions
    width: f32 = 300,
    height: f32 = 300,

    // Donut configuration
    inner_radius_ratio: f32 = 0,  // 0 = pie, 0.5 = donut with 50% hole

    // Styling
    /// Pixel-based gap (recommended) - creates parallel slice edges
    gap_pixels: ?f32 = null,
    /// Angular gap (legacy) - wedge-shaped gaps
    pad_angle: f32 = 0.02,
    /// Start angle (-π/2 = 12 o'clock)
    start_angle: f32 = -1.5708,

    // Labels
    show_labels: bool = false,
    label_position: LabelPosition = .outside,

    // Theme
    chart_theme: ?*const ChartTheme = null,

    pub fn init(data: []const CategoryPoint) PieChart;
    pub fn render(self: *const PieChart, ctx: *DrawContext) void;
    pub fn hitTest(self: *const PieChart, x: f32, y: f32) ?usize;

    // Accessibility
    pub fn getAccessibilityInfo(self: *const PieChart) accessibility.ChartInfo;
    pub fn describe(self: *const PieChart, buf: []u8) []const u8;
};
```

**Gap Modes:**

| Mode                          | Field              | Behavior                                |
| ----------------------------- | ------------------ | --------------------------------------- |
| **Pixel-based (recommended)** | `gap_pixels = 3`   | Parallel slice edges, uniform gap width |
| **Angular (legacy)**          | `pad_angle = 0.02` | Wedge-shaped gaps, narrower near center |

**Example (Pie vs Donut):**

```gooey/docs/charts.md#L593-610
fn paintPieChart(ctx: *ui.DrawContext) void {
    var chart = charts.PieChart.init(&pie_data);
    chart.width = ctx.width();
    chart.height = ctx.height();
    chart.inner_radius_ratio = 0;  // Full pie (no hole)
    chart.gap_pixels = 3;
    chart.render(ctx);
}

fn paintDonutChart(ctx: *ui.DrawContext) void {
    var chart = charts.PieChart.init(&donut_data);
    chart.width = ctx.width();
    chart.height = ctx.height();
    chart.inner_radius_ratio = 0.55;  // 55% hole
    chart.gap_pixels = 4;
    chart.render(ctx);
}
```

### ScatterChart

Renders XY data as individual points with multiple shape options.

```gooey/docs/charts.md#L618-665
pub const ScatterChart = struct {
    // Data (slice to external storage)
    data: []const Series,

    // Dimensions
    width: f32 = 400,
    height: f32 = 300,

    // Margins
    margin_top: f32 = 20,
    margin_right: f32 = 20,
    margin_bottom: f32 = 40,
    margin_left: f32 = 50,

    // Point styling
    point_radius: f32 = 4,
    point_shape: PointShape = .circle,
    point_opacity: f32 = 0.8,

    // Size encoding (bubble chart mode)
    size_data: ?[]const []const f32 = null,
    size_range: [2]f32 = .{ 4.0, 20.0 },

    // Domain overrides
    x_domain_min: ?f32 = null,
    x_domain_max: ?f32 = null,
    y_domain_min: ?f32 = null,
    y_domain_max: ?f32 = null,

    // Axes & Grid
    show_x_axis: bool = true,
    show_y_axis: bool = true,
    show_grid: bool = true,
    x_axis_opts: Axis.Options = .{},
    y_axis_opts: Axis.Options = .{ .orientation = .left },
    grid_opts: Grid.Options = .{},

    // Theme
    chart_theme: ?*const ChartTheme = null,

    pub fn init(data: []const Series) ScatterChart;
    pub fn initSingle(series: *const Series) ScatterChart;
    pub fn render(self: *const ScatterChart, ctx: *DrawContext) void;
    pub fn hitTest(self: *const ScatterChart, px: f32, py: f32) ?HitResult;
};

pub const PointShape = enum { circle, square, triangle, diamond };
```

---

## Primitives

### LinearScale

Transforms numeric data values ↔ pixel positions.

```gooey/docs/charts.md#L677-691
pub const LinearScale = struct {
    domain_min: f32,  // Data space min
    domain_max: f32,  // Data space max
    range_min: f32,   // Pixel space min
    range_max: f32,   // Pixel space max

    pub fn init(domain_min: f32, domain_max: f32, range_min: f32, range_max: f32) LinearScale;
    pub fn scale(self: LinearScale, value: f32) f32;     // Data → Pixel
    pub fn invert(self: LinearScale, pixel: f32) f32;    // Pixel → Data
    pub fn ticks(self: LinearScale, count: u32, out: *[MAX_TICKS]f32) u32;
};

// Example
const y_scale = LinearScale.init(0, 100, plot_height, 0);  // Note: Y inverted
const pixel_y = y_scale.scale(50);  // Returns middle of plot area
```

### BandScale

Transforms categorical data to pixel positions (for bar charts).

```gooey/docs/charts.md#L699-714
pub const BandScale = struct {
    labels: [MAX_CATEGORIES][]const u8,
    label_count: u32,
    range_min: f32,
    range_max: f32,
    padding_inner: f32,  // Between bars (0.0 - 1.0)
    padding_outer: f32,  // At edges

    pub fn init(labels: []const []const u8, range_min: f32, range_max: f32) BandScale;
    pub fn initWithPadding(...) BandScale;
    pub fn bandwidth(self: BandScale) f32;
    pub fn position(self: BandScale, index: u32) f32;   // Left edge of band
    pub fn center(self: BandScale, index: u32) f32;     // Center of band
};
```

### Axis

Renders tick marks, labels, and axis line.

```gooey/docs/charts.md#L720-746
pub const Axis = struct {
    pub const Orientation = enum { top, bottom, left, right };

    pub const Options = struct {
        orientation: Orientation = .bottom,
        label: ?[]const u8 = null,
        tick_count: u32 = 5,
        tick_size: f32 = 6,
        tick_padding: f32 = 3,
        show_line: bool = true,
        show_ticks: bool = true,
        show_labels: bool = true,
        color: Color = Color.hex(0x333333),
        label_color: Color = Color.hex(0x666666),
        line_width: f32 = 1.0,
        font_size: f32 = 12.0,
    };

    pub fn drawLinear(ctx: *DrawContext, scale: LinearScale, x: f32, y: f32, opts: Options) void;
    pub fn drawBand(ctx: *DrawContext, scale: BandScale, x: f32, y: f32, opts: Options) void;
};

// Example
Axis.drawLinear(ctx, y_scale, margin_left, margin_top, .{
    .orientation = .left,
    .color = ui.Color.hex(0x4a5a7e),
    .label_color = ui.Color.hex(0xcccccc),
});
```

### Grid

Renders background grid lines.

```gooey/docs/charts.md#L772-794
pub const Grid = struct {
    pub const Options = struct {
        show_horizontal: bool = true,
        show_vertical: bool = false,
        color: Color = Color.hex(0xE0E0E0),
        line_width: f32 = 1.0,
    };

    pub const Bounds = struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    };

    pub fn drawLinear(ctx: *DrawContext, x_scale: LinearScale, y_scale: LinearScale,
                      bounds: Bounds, tick_count: u32, opts: Options) void;
    pub fn drawMixed(ctx: *DrawContext, x_band: BandScale, y_linear: LinearScale,
                     bounds: Bounds, tick_count: u32, opts: Options) void;
    pub fn drawLinearXY(ctx: *DrawContext, x_scale: LinearScale, y_scale: LinearScale,
                        bounds: Bounds, x_ticks: u32, y_ticks: u32, opts: Options) void;
};
```

### Legend

Displays series names and colors.

```gooey/docs/charts.md#L802-838
pub const Legend = struct {
    pub const Position = enum { top, bottom, left, right };
    pub const Shape = enum { rect, circle, line };

    pub const Item = struct {
        label: []const u8,
        color: Color,
        shape: Shape = .rect,

        pub fn init(label: []const u8, color: Color) Item;
        pub fn initWithShape(label: []const u8, color: Color, shape: Shape) Item;
    };

    pub const Options = struct {
        position: Position = .bottom,
        spacing: f32 = 16.0,
        item_size: f32 = 12.0,
        font_size: f32 = 12.0,
        color: Color = Color.hex(0x333333),
        background: ?Color = null,
        padding: f32 = 8.0,
        item_gap: f32 = 8.0,
    };

    pub const Bounds = struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    };

    pub fn draw(ctx: *DrawContext, bounds: Bounds, items: []const Item, opts: Options) DrawResult;
    pub fn calculateDimensions(items: []const Item, opts: Options) struct { width: f32, height: f32 };
};
```

**Example:**

```gooey/docs/charts.md#L844-860
const legend_items = [_]charts.Legend.Item{
    charts.Legend.Item.initWithShape("Revenue", charts.Color.hex(0x34a853), .line),
    charts.Legend.Item.initWithShape("Expenses", charts.Color.hex(0xea4335), .line),
};

const legend_opts = charts.Legend.Options{
    .position = .top,
    .color = ui.Color.hex(0xcccccc),
    .spacing = 24,
    .item_size = 16,
    .font_size = 10,
};

// Calculate dimensions for layout
const dims = charts.Legend.calculateDimensions(&legend_items, legend_opts);

// Draw legend
_ = charts.Legend.draw(ctx, .{ .x = 0, .y = 5, .width = w, .height = dims.height }, &legend_items, legend_opts);
```

---

## Theming

### ChartTheme

Charts support theming via the `ChartTheme` struct:

```gooey/docs/charts.md#L872-912
pub const ChartTheme = struct {
    // Base colors (inherited from Gooey theme)
    background: Color,
    foreground: Color,
    muted: Color,
    surface: Color,
    border: Color,

    // Categorical palette (12 colors)
    palette: [12]Color = default_palette,

    // Semantic colors
    positive: Color,  // Green (profit, growth)
    negative: Color,  // Red (loss, decline)
    neutral: Color,   // Gray

    // Axis & grid styling
    axis_color: Color,
    grid_color: Color,
    tick_color: Color,
    label_color: Color,

    // Built-in presets
    pub const light = ChartTheme{ ... };
    pub const dark = ChartTheme{ ... };

    // Construction from Gooey theme
    pub fn fromTheme(theme: *const ui.Theme) ChartTheme;

    // Helpers
    pub fn paletteColor(self: *const ChartTheme, index: usize) Color;
    pub fn isDark(self: *const ChartTheme) bool;
    pub fn contrastingText(self: *const ChartTheme, bg: Color) Color;
};
```

### Available Palettes

- `default_palette` — Tableau 10-inspired (12 colors)
- `google_palette` — Google brand colors
- `colorblind_palette` — Deuteranopia/protanopia friendly
- `monochrome_blue_palette` — Single hue variations

### Theme Usage

```gooey/docs/charts.md#L922-945
// Use built-in presets
const dark_theme = charts.ChartTheme.dark;
const light_theme = charts.ChartTheme.light;

// Apply to chart
var chart = charts.LineChart.init(&data);
chart.chart_theme = &dark_theme;

// Series without explicit colors use theme palette
themed_data[0].initInPlace("Series A", null);  // Uses palette[0]
themed_data[1].initInPlace("Series B", null);  // Uses palette[1]

// Or override explicitly
explicit_data[0].initInPlace("Revenue", charts.Color.hex(0x34a853));

// Derive from Gooey theme
fn currentTheme() *const charts.ChartTheme {
    return if (state.is_dark) &dark_theme else &light_theme;
}

fn backgroundColor() ui.Color {
    return if (state.is_dark) ui.Color.hex(0x0f0f1a) else ui.Color.hex(0xf5f5f7);
}
```

---

## Accessibility

### Overview

Charts support screen readers through auto-generated descriptions and metadata extraction.

### ChartInfo

```gooey/docs/charts.md#L959-985
pub const ChartInfo = struct {
    chart_type: ChartType,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    series_count: u32 = 1,
    point_count: u32 = 0,
    min_value: ?f32 = null,
    max_value: ?f32 = null,
    min_label: ?[]const u8 = null,
    max_label: ?[]const u8 = null,
    avg_value: ?f32 = null,
    total_value: ?f32 = null,
};

pub const ChartType = enum {
    bar,
    line,
    pie,
    donut,
    scatter,

    pub fn defaultTitle(self: ChartType) []const u8;
    pub fn roleDescription(self: ChartType) []const u8;
};
```

### Description Generators

```gooey/docs/charts.md#L991-998
pub fn describe(info: *const ChartInfo, buf: []u8) []const u8;
pub fn summarize(info: *const ChartInfo, buf: []u8) []const u8;
pub fn describePoint(label: []const u8, value: f32, buf: []u8) []const u8;
pub fn describeSlice(label: []const u8, value: f32, percentage: f32, buf: []u8) []const u8;
pub fn describeScatterPoint(x: f32, y: f32, label: ?[]const u8, buf: []u8) []const u8;
pub fn announceValueChange(label: []const u8, old_value: f32, new_value: f32, buf: []u8) []const u8;
pub fn announceSelection(label: []const u8, value: f32, position: u32, total: u32, buf: []u8) []const u8;
```

### Usage Example

```gooey/docs/charts.md#L1004-1027
fn renderAccessibleChart(b: *ui.Builder) void {
    const chart = charts.BarChart.init(&bar_data);

    // Generate accessible description
    var desc_buf: [charts.accessibility.MAX_DESCRIPTION_LENGTH]u8 = undefined;
    const description = chart.describe(&desc_buf);

    // Push accessible element before canvas
    if (b.accessible(.{
        .role = .img,
        .name = chart.accessible_title orelse "Bar Chart",
        .description = description,
    })) {
        defer b.accessibleEnd();
    }

    ui.canvas(400, 300, struct {
        fn paint(ctx: *ui.DrawContext) void {
            chart.render(ctx);
        }
    }.paint).render(b);
}
```

### Chart Methods

All charts provide accessibility methods:

```gooey/docs/charts.md#L1035-1038
pub fn getAccessibilityInfo(self: *const Chart) accessibility.ChartInfo;
pub fn describe(self: *const Chart, buf: []u8) []const u8;
pub fn summarize(self: *const Chart, buf: []u8) []const u8;
```

---

## Performance

### Design Wins

| Optimization            | Location         | Impact                                 |
| ----------------------- | ---------------- | -------------------------------------- |
| **Zero allocations**    | All charts       | No GC pressure, consistent frame times |
| **Batched polylines**   | `line_chart.zig` | 1 draw call for N points (was N calls) |
| **Instanced points**    | `line_chart.zig` | `pointCloud()` for markers             |
| **Triangle fan slices** | `pie_chart.zig`  | Avoids 70KB Path struct                |
| **Slice-based data**    | All charts       | 16-byte pointer vs 300KB embedded      |
| **O(n) algorithms**     | All charts       | No nested loops over data              |
| **LOD decimation**      | `line_chart.zig` | LTTB algorithm for >1000 points        |

### Batched Rendering

**Line Chart — Polyline API:**

```gooey/docs/charts.md#L1063-1070
// Before: N draw calls, N tessellations
for (points) |p| ctx.strokeLine(prev, p, ...);

// After: 1 draw call for up to 4096 points
ctx.polyline(points[0..count], line_width, color);

// Point markers: 1 draw call with GPU instancing
ctx.pointCloud(centers[0..count], radius, color);
```

### Performance Comparison

| Scenario          | Before                              | After                        |
| ----------------- | ----------------------------------- | ---------------------------- |
| 1000-point line   | 1000 draw calls, 1000 tessellations | 1 draw call, 0 tessellations |
| Stack usage       | ~67 MB (1000 × 67KB Path)           | ~8 KB (1000 × 8 bytes)       |
| GPU buffer writes | 1000 separate uploads               | 1 contiguous upload          |

### Estimated Frame Budget

For a complex dashboard (4 charts, axes, legends):

| Component             | Draw Calls | Notes                       |
| --------------------- | ---------- | --------------------------- |
| Bar chart (10×3)      | ~30        | Individual rects            |
| Line chart (500pts×2) | ~4         | 2 polylines + 2 pointClouds |
| Pie chart (8 slices)  | ~128       | Triangle fans               |
| Scatter (200pts)      | ~1         | Single pointCloud           |
| Axes + labels         | ~80        | Ticks and text              |
| **Total**             | **~250**   | Well under 16.6ms budget    |

### Performance Instrumentation

Enable timing warnings in `constants.zig`:

```gooey/docs/charts.md#L1106-1109
pub const ENABLE_PERF_LOGGING: bool = false;  // Set to true to enable
pub const PERF_WARNING_THRESHOLD_NS: i128 = 8_000_000;  // 8ms warning threshold
```

### Level-of-Detail for Large Datasets

LTTB (Largest-Triangle-Three-Buckets) algorithm enables smooth rendering of 10K+ point datasets:

```gooey/docs/charts.md#L1117-1122
// LineChart LOD support
var chart = charts.LineChart.init(&large_data);
chart.enable_lod = true;           // Enable automatic decimation
chart.lod_target_points = 1000;    // Target point count after decimation
chart.render(ctx);
```

---

## Constants & Limits

```gooey/docs/charts.md#L1130-1141
// Per CLAUDE.md — hard limits on everything
pub const MAX_DATA_POINTS: u32 = 4096;     // Per series
pub const MAX_SERIES: u32 = 16;             // Per chart
pub const MAX_CATEGORIES: u32 = 256;        // For bar/pie charts
pub const MAX_TICKS: u32 = 32;              // Per axis
pub const MAX_LEGEND_ITEMS: u32 = 32;
pub const MAX_LABEL_LENGTH: u32 = 64;       // Characters

// LOD
pub const LOD_THRESHOLD: u32 = 1000;        // Auto-decimate above this

// Accessibility
pub const MAX_DESCRIPTION_LENGTH: u32 = 512;
```

---

## API Reference

### Exports from `gooey-charts`

```gooey/docs/charts.md#L1153-1182
// Primitives (Layer 2)
pub const LinearScale = @import("primitives/scale.zig").LinearScale;
pub const BandScale = @import("primitives/scale.zig").BandScale;
pub const Axis = @import("primitives/axis.zig").Axis;
pub const Grid = @import("primitives/grid.zig").Grid;
pub const Legend = @import("primitives/legend.zig").Legend;

// Charts (Layer 3)
pub const BarChart = @import("charts/bar_chart.zig").BarChart;
pub const LineChart = @import("charts/line_chart.zig").LineChart;
pub const PieChart = @import("charts/pie_chart.zig").PieChart;
pub const ScatterChart = @import("charts/scatter_chart.zig").ScatterChart;
pub const PointShape = @import("charts/scatter_chart.zig").PointShape;

// Data types
pub const DataPoint = @import("types.zig").DataPoint;
pub const CategoryPoint = @import("types.zig").CategoryPoint;
pub const Series = @import("types.zig").Series;
pub const CategorySeries = @import("types.zig").CategorySeries;

// Theme
pub const ChartTheme = @import("theme.zig").ChartTheme;

// Accessibility
pub const accessibility = @import("accessibility.zig");

// Re-exports from gooey for convenience
pub const Color = gooey.ui.Color;
pub const DrawContext = gooey.ui.DrawContext;
```

---

## Examples

### Charts Demo

See `src/examples/charts_demo.zig` for a complete showcase of all chart types:

- Bar chart with custom styling
- Multi-series line chart with legend
- Pie and donut charts
- Scatter plot with multiple series
- Progress ring (thin donut)
- Themed line chart with palette colors

### Dashboard Example

See `src/examples/dashboard.zig` for a multi-chart analytics dashboard:

- KPI cards with metrics
- Revenue trend (line chart with legend)
- Sales by category (bar chart)
- Traffic sources (pie chart)
- Customer segments (scatter chart)
- Conversion rate (progress ring)
- Theme toggle with `[T]` key

Run examples with:

```gooey/docs/charts.md#L1217-1219
zig build run-charts      # Charts demo
zig build run-dashboard   # Dashboard example
```

---

## References

- [SwiftUI Charts](https://developer.apple.com/documentation/charts) — Composable API inspiration
- [Recharts](https://recharts.org/) — React component patterns
- [D3.js Scales](https://d3js.org/d3-scale) — Scale implementation reference
- [Vega-Lite](https://vega.github.io/vega-lite/) — Grammar of graphics concepts
- [ImPlot](https://github.com/epezent/implot) — Immediate mode charting
- [LTTB Algorithm](https://skemman.is/bitstream/1946/15343/3/SS_MSthesis.pdf) — Downsampling for large datasets
