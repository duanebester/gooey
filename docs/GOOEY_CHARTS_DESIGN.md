# Gooey Charts — Design Document

> A charting library built on Gooey's Canvas API

**Status:** Draft  
**Author:** (your name)  
**Date:** 2025-01-14

---

## 1. Overview

### 1.1 What Is This?

`gooey-charts` is an **optional sub-package** within the Gooey monorepo that provides data visualization components built on top of Gooey's `DrawContext` API. It lives in `charts/` and is NOT part of core Gooey — users opt-in by importing the `gooey-charts` module.

### 1.2 Why Separate (But Same Repo)?

| Reason                | Explanation                                           |
| --------------------- | ----------------------------------------------------- |
| **Keeps core small**  | Not every app needs charts                            |
| **Different cadence** | Charts evolve faster (new types, features)            |
| **Industry standard** | SwiftUI Charts, Qt Charts, ImPlot — all separate      |
| **Domain-specific**   | Data viz has unique concerns (scales, large datasets) |
| **Zig philosophy**    | Minimal, composable pieces                            |
| **Monorepo benefits** | Coordinated changes, shared CI, simpler maintenance   |

### 1.3 Goals

1. **Simple API** — Common charts in 1-3 lines of code
2. **Composable** — Mix chart types, customize axes, layer annotations
3. **Performant** — Static allocation, GPU-accelerated via Canvas
4. **Accessible** — Screen reader support for chart data
5. **Themed** — Inherit Gooey's theme system

### 1.4 Non-Goals

- Real-time streaming data (use case for v2)
- 3D charts
- Geographic/map visualizations
- Complex statistical plots (box plots, violin plots)

---

## 2. Design Principles

Following Gooey's `CLAUDE.md`:

1. **Static Allocation** — Pre-allocate arrays for data points, legend items
2. **Hard Limits** — `MAX_DATA_POINTS = 4096`, `MAX_SERIES = 16`
3. **No Recursion** — Iterative rendering
4. **Fail Fast** — Assert on invalid data, don't silently clamp
5. **70-Line Functions** — Split complex rendering into phases

---

## 3. Architecture

### 3.1 Layered Design

```
┌─────────────────────────────────────────────────────────┐
│  Layer 3: Chart Components                              │
│  BarChart, LineChart, PieChart, ScatterChart            │
│  (High-level, data-driven)                              │
├─────────────────────────────────────────────────────────┤
│  Layer 2: Chart Primitives                              │
│  Axis, Grid, Legend, Tooltip, Scale                     │
│  (Reusable across chart types)                          │
├─────────────────────────────────────────────────────────┤
│  Layer 1: Gooey Canvas (EXTERNAL)                       │
│  DrawContext: fillRect, strokeLine, fillPath, gradients │
│  (Foundation — NOT part of this package)                │
└─────────────────────────────────────────────────────────┘
```

### 3.2 Monorepo Structure

Charts lives inside the gooey repo as an optional sub-package:

```
gooey/
├── build.zig              # Root build (exports both modules)
├── build.zig.zon          # Includes charts/ in paths
├── src/                   # Core gooey (unchanged)
│   ├── root.zig
│   ├── ui/
│   ├── components/
│   └── ...
│
├── charts/                # Optional charts sub-package
│   ├── build.zig          # Charts-specific build
│   ├── build.zig.zon      # Depends on parent gooey
│   └── src/
│       ├── root.zig
│       ├── primitives/
│       └── charts/
│
└── examples/
    ├── showcase.zig
    ├── canvas_demo.zig
    └── charts_demo.zig    # Charts example
```

### 3.3 User Dependency

Users import from a single gooey dependency:

```zig
// user's build.zig.zon
.dependencies = .{
    .gooey = .{ .url = "https://github.com/user/gooey/..." },
}

// user's build.zig
const gooey_dep = b.dependency("gooey", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("gooey", gooey_dep.module("gooey"));

// Optional: only if they need charts
exe.root_module.addImport("gooey-charts", gooey_dep.module("gooey-charts"));
```

```zig
// user's app.zig
const gooey = @import("gooey");
const charts = @import("gooey-charts");  // Optional

fn render(cx: *gooey.Cx) void {
    charts.BarChart{ .data = &data }.render(cx.builder());
}
```

---

## 4. Core Primitives (Layer 2)

### 4.1 Scale

Transforms data values ↔ pixel positions.

```zig
pub const Scale = union(enum) {
    linear: LinearScale,
    log: LogScale,
    band: BandScale,      // Categorical (bar charts)
    time: TimeScale,      // Date/time axes
};

pub const LinearScale = struct {
    domain_min: f32,      // Data space
    domain_max: f32,
    range_min: f32,       // Pixel space
    range_max: f32,

    pub fn init(domain_min: f32, domain_max: f32, range_min: f32, range_max: f32) LinearScale;
    pub fn scale(self: *const LinearScale, value: f32) f32;      // Data → Pixel
    pub fn invert(self: *const LinearScale, pixel: f32) f32;     // Pixel → Data
    pub fn ticks(self: *const LinearScale, count: u32) FixedArray(f32, 32);
};

pub const BandScale = struct {
    labels: []const []const u8,
    range_min: f32,
    range_max: f32,
    padding_inner: f32,   // Between bars (0.0 - 1.0)
    padding_outer: f32,   // At edges

    pub fn bandwidth(self: *const BandScale) f32;
    pub fn position(self: *const BandScale, index: usize) f32;  // Center of band
};
```

### 4.2 Axis

Renders tick marks, labels, and axis line.

```zig
pub const Axis = struct {
    pub const Orientation = enum { top, bottom, left, right };

    pub const Options = struct {
        orientation: Orientation = .bottom,
        label: ?[]const u8 = null,
        tick_count: u32 = 5,
        tick_size: f32 = 6,
        tick_padding: f32 = 4,
        show_line: bool = true,
        show_ticks: bool = true,
        show_labels: bool = true,
        label_format: ?*const fn(f32) []const u8 = null,  // Custom formatter
        color: ?Color = null,         // null = use theme
        label_color: ?Color = null,
    };

    pub fn draw(ctx: *DrawContext, scale: Scale, bounds: Bounds, opts: Options) void;
};
```

### 4.3 Grid

Background grid lines.

```zig
pub const Grid = struct {
    pub const Options = struct {
        show_horizontal: bool = true,
        show_vertical: bool = true,
        color: ?Color = null,         // null = theme.muted with alpha
        line_width: f32 = 1,
        dash_pattern: ?[]const f32 = null,  // For dashed lines (future)
    };

    pub fn draw(
        ctx: *DrawContext,
        x_scale: Scale,
        y_scale: Scale,
        bounds: Bounds,
        opts: Options,
    ) void;
};
```

### 4.4 Legend

Key for multiple series.

```zig
pub const Legend = struct {
    pub const Position = enum { top, bottom, left, right, floating };

    pub const Item = struct {
        label: []const u8,
        color: Color,
        shape: Shape = .rect,

        pub const Shape = enum { rect, circle, line };
    };

    pub const Options = struct {
        position: Position = .bottom,
        items: []const Item,
        spacing: f32 = 16,
        item_size: f32 = 12,
    };

    pub fn draw(ctx: *DrawContext, bounds: Bounds, opts: Options) Bounds;  // Returns consumed space
};
```

### 4.5 Tooltip (Future)

Hover information display — requires mouse position from Gooey.

```zig
pub const Tooltip = struct {
    pub fn draw(ctx: *DrawContext, position: Vec2, content: []const u8) void;
};
```

---

## 5. Chart Components (Layer 3)

### 5.1 Data Types

```zig
/// Single data point for XY charts
pub const DataPoint = struct {
    x: f32,
    y: f32,
    label: ?[]const u8 = null,  // For tooltips
};

/// Categorical data point (bar charts, pie charts)
pub const CategoryPoint = struct {
    label: []const u8,
    value: f32,
    color: ?Color = null,  // Override series color
};

/// Data series (multiple points with shared style)
pub const Series = struct {
    name: []const u8,
    data: []const DataPoint,
    color: ?Color = null,
};

/// Categorical series
pub const CategorySeries = struct {
    name: []const u8,
    data: []const CategoryPoint,
    color: ?Color = null,
};
```

### 5.2 BarChart

```zig
pub const BarChart = struct {
    // Required
    data: []const CategorySeries,

    // Dimensions
    width: f32 = 400,
    height: f32 = 300,

    // Margins (auto-calculated if null)
    margin_top: ?f32 = null,
    margin_right: ?f32 = null,
    margin_bottom: ?f32 = null,
    margin_left: ?f32 = null,

    // Orientation
    horizontal: bool = false,

    // Grouping
    stacked: bool = false,
    bar_padding: f32 = 0.2,      // Inner padding (0-1)
    group_padding: f32 = 0.1,    // Between groups (0-1)

    // Styling
    corner_radius: f32 = 0,

    // Axes
    show_x_axis: bool = true,
    show_y_axis: bool = true,
    x_axis: Axis.Options = .{},
    y_axis: Axis.Options = .{ .orientation = .left },

    // Grid
    show_grid: bool = true,
    grid: Grid.Options = .{},

    // Legend
    show_legend: bool = true,
    legend: Legend.Options = .{},

    // Accessibility
    accessible_title: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    pub fn render(self: BarChart, b: *ui.Builder) void;
};
```

### 5.3 LineChart

```zig
pub const LineChart = struct {
    // Required
    series: []const Series,

    // Dimensions
    width: f32 = 400,
    height: f32 = 300,

    // Line style
    line_width: f32 = 2,
    curve: Curve = .linear,

    pub const Curve = enum {
        linear,         // Straight lines between points
        monotone,       // Smooth, monotonic interpolation
        step,           // Step function
        step_after,     // Step after point
    };

    // Points
    show_points: bool = false,
    point_radius: f32 = 4,

    // Area fill
    show_area: bool = false,
    area_opacity: f32 = 0.3,

    // Axes
    show_x_axis: bool = true,
    show_y_axis: bool = true,
    x_axis: Axis.Options = .{},
    y_axis: Axis.Options = .{ .orientation = .left },

    // Domain (auto-calculated if null)
    x_domain: ?[2]f32 = null,
    y_domain: ?[2]f32 = null,

    // Grid
    show_grid: bool = true,
    grid: Grid.Options = .{},

    // Legend
    show_legend: bool = true,
    legend: Legend.Options = .{},

    pub fn render(self: LineChart, b: *ui.Builder) void;
};
```

### 5.4 PieChart

```zig
pub const PieChart = struct {
    // Required
    data: []const CategoryPoint,

    // Dimensions
    width: f32 = 300,
    height: f32 = 300,

    // Donut
    inner_radius: f32 = 0,  // 0 = pie, >0 = donut

    // Styling
    pad_angle: f32 = 0.02,  // Gap between slices (radians)
    corner_radius: f32 = 0,

    // Labels
    show_labels: bool = true,
    label_position: LabelPosition = .outside,

    pub const LabelPosition = enum { inside, outside, none };

    // Legend
    show_legend: bool = true,
    legend: Legend.Options = .{ .position = .right },

    pub fn render(self: PieChart, b: *ui.Builder) void;
};
```

### 5.5 ScatterChart

```zig
pub const ScatterChart = struct {
    // Required
    series: []const Series,

    // Dimensions
    width: f32 = 400,
    height: f32 = 300,

    // Points
    point_radius: f32 = 4,
    point_shape: PointShape = .circle,

    pub const PointShape = enum { circle, square, triangle, diamond };

    // Size encoding (bubble chart)
    size_field: ?[]const f32 = null,  // Map to point radius
    size_range: [2]f32 = .{ 4, 20 },

    // Axes
    show_x_axis: bool = true,
    show_y_axis: bool = true,
    x_axis: Axis.Options = .{},
    y_axis: Axis.Options = .{ .orientation = .left },

    // Grid
    show_grid: bool = true,
    grid: Grid.Options = .{},

    // Legend
    show_legend: bool = true,
    legend: Legend.Options = .{},

    pub fn render(self: ScatterChart, b: *ui.Builder) void;
};
```

---

## 6. API Examples

### 6.1 Simple Bar Chart

```zig
const gooey = @import("gooey");
const charts = @import("gooey-charts");

fn render(cx: *gooey.Cx) void {
    const data = [_]charts.CategoryPoint{
        .{ .label = "Jan", .value = 100 },
        .{ .label = "Feb", .value = 150 },
        .{ .label = "Mar", .value = 120 },
        .{ .label = "Apr", .value = 180 },
    };

    cx.box(.{ .padding = .{ .all = 20 } }, .{
        charts.BarChart{
            .data = &.{.{ .name = "Sales", .data = &data }},
            .width = 400,
            .height = 300,
        },
    });
}
```

### 6.2 Multi-Series Line Chart

```zig
fn render(cx: *gooey.Cx) void {
    const revenue = [_]charts.DataPoint{
        .{ .x = 0, .y = 100 },
        .{ .x = 1, .y = 120 },
        .{ .x = 2, .y = 140 },
        .{ .x = 3, .y = 160 },
    };

    const expenses = [_]charts.DataPoint{
        .{ .x = 0, .y = 80 },
        .{ .x = 1, .y = 90 },
        .{ .x = 2, .y = 85 },
        .{ .x = 3, .y = 95 },
    };

    cx.box(.{}, .{
        charts.LineChart{
            .series = &.{
                .{ .name = "Revenue", .data = &revenue, .color = ui.Color.green },
                .{ .name = "Expenses", .data = &expenses, .color = ui.Color.red },
            },
            .show_area = true,
            .curve = .monotone,
        },
    });
}
```

### 6.3 Donut Chart

```zig
fn render(cx: *gooey.Cx) void {
    const data = [_]charts.CategoryPoint{
        .{ .label = "Desktop", .value = 45, .color = ui.Color.hex(0x4CAF50) },
        .{ .label = "Mobile", .value = 35, .color = ui.Color.hex(0x2196F3) },
        .{ .label = "Tablet", .value = 20, .color = ui.Color.hex(0xFF9800) },
    };

    cx.box(.{}, .{
        charts.PieChart{
            .data = &data,
            .inner_radius = 60,  // Donut hole
            .width = 300,
            .height = 300,
        },
    });
}
```

### 6.4 Composing Primitives Directly

For custom charts, use Layer 2 primitives:

```zig
fn paintCustomChart(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();
    const margin = charts.Margin{ .top = 20, .right = 20, .bottom = 40, .left = 50 };
    const plot_area = margin.apply(w, h);

    // Create scales
    const x_scale = charts.LinearScale.init(0, 100, plot_area.x, plot_area.x + plot_area.width);
    const y_scale = charts.LinearScale.init(0, 100, plot_area.y + plot_area.height, plot_area.y);

    // Draw grid
    charts.Grid.draw(ctx, .{ .linear = x_scale }, .{ .linear = y_scale }, plot_area, .{});

    // Draw axes
    charts.Axis.draw(ctx, .{ .linear = x_scale }, .{ .orientation = .bottom }, plot_area);
    charts.Axis.draw(ctx, .{ .linear = y_scale }, .{ .orientation = .left }, plot_area);

    // Draw custom data
    for (my_data) |point| {
        const px = x_scale.scale(point.x);
        const py = y_scale.scale(point.y);
        ctx.fillCircle(px, py, 5, ui.Color.blue);
    }
}

// Usage
ui.canvas(500, 400, paintCustomChart)
```

---

## 7. Theming

### 7.1 Color Palette

Charts inherit Gooey's theme but add chart-specific colors:

```zig
pub const ChartTheme = struct {
    // Inherited from Gooey theme
    background: Color,
    foreground: Color,      // Text, axis lines
    muted: Color,           // Grid lines

    // Chart-specific palette (categorical colors)
    palette: [12]Color = default_palette,

    // Semantic colors
    positive: Color,        // Green (profit, up)
    negative: Color,        // Red (loss, down)
    neutral: Color,         // Gray

    pub const default_palette = [12]Color{
        Color.hex(0x4E79A7),  // Blue
        Color.hex(0xF28E2B),  // Orange
        Color.hex(0xE15759),  // Red
        Color.hex(0x76B7B2),  // Teal
        Color.hex(0x59A14F),  // Green
        Color.hex(0xEDC948),  // Yellow
        Color.hex(0xB07AA1),  // Purple
        Color.hex(0xFF9DA7),  // Pink
        Color.hex(0x9C755F),  // Brown
        Color.hex(0xBAB0AC),  // Gray
        Color.hex(0x6B9AC4),  // Light blue
        Color.hex(0xD4A6C8),  // Light purple
    };

    pub fn fromGooeyTheme(theme: *const ui.Theme) ChartTheme;
};
```

### 7.2 Theme Integration

```zig
// Charts automatically pick up the current theme
charts.BarChart{
    .data = &data,
    // Colors default to theme.palette[0], theme.palette[1], etc.
}

// Or override explicitly
charts.BarChart{
    .data = &.{
        .{ .name = "Sales", .data = &data, .color = ui.Color.hex(0xFF0000) },
    },
}
```

---

## 8. Accessibility

### 8.1 Screen Reader Support

Each chart component pushes an accessible element:

```zig
pub fn render(self: BarChart, b: *ui.Builder) void {
    // Push accessible container
    b.accessible(.{
        .role = .figure,
        .name = self.accessible_title orelse "Bar Chart",
        .description = self.accessible_description orelse self.generateDescription(),
    });

    // Render the canvas
    b.add(ui.canvas(self.width, self.height, self.paint));

    b.accessibleEnd();
}

fn generateDescription(self: *const BarChart) []const u8 {
    // "Bar chart with 4 categories. Maximum value: 180 (April). Minimum value: 100 (January)."
    // Generated at render time
}
```

### 8.2 Data Table Fallback

For complex charts, provide a hidden data table:

```zig
// Option to render an accessible data table alongside chart
charts.LineChart{
    .series = &series,
    .accessible_data_table = true,  // Adds <table> for screen readers
}
```

---

## 9. Project Structure

### 9.1 Full Monorepo Layout

```
gooey/
├── build.zig                   # Root build (exports gooey + gooey-charts)
├── build.zig.zon               # Package manifest
├── CLAUDE.md
├── README.md
│
├── src/                        # Core gooey (UNCHANGED)
│   ├── root.zig
│   ├── ui/
│   │   ├── canvas.zig          # DrawContext (foundation for charts)
│   │   └── ...
│   ├── components/
│   ├── scene/
│   └── ...
│
├── charts/                     # NEW: Optional charts sub-package
│   ├── build.zig
│   ├── build.zig.zon
│   ├── README.md
│   │
│   └── src/
│       ├── root.zig            # Public exports
│       │
│       ├── primitives/
│       │   ├── mod.zig
│       │   ├── scale.zig       # LinearScale, LogScale, BandScale, TimeScale
│       │   ├── axis.zig        # Axis rendering
│       │   ├── grid.zig        # Grid lines
│       │   ├── legend.zig      # Legend component
│       │   └── tooltip.zig     # Tooltip (future)
│       │
│       ├── charts/
│       │   ├── mod.zig
│       │   ├── bar_chart.zig
│       │   ├── line_chart.zig
│       │   ├── pie_chart.zig
│       │   └── scatter_chart.zig
│       │
│       ├── theme.zig           # ChartTheme
│       ├── types.zig           # DataPoint, Series, etc.
│       └── util.zig            # Helpers (nice numbers, tick generation)
│
├── examples/                   # All examples (moved to top level)
│   ├── showcase.zig
│   ├── counter.zig
│   ├── canvas_demo.zig
│   ├── charts_demo.zig         # NEW: Charts example
│   └── dashboard.zig           # NEW: Multi-chart dashboard
│
├── docs/
│   └── GOOEY_CHARTS_DESIGN.md  # This document
│
└── web/
```

### 9.2 Root `build.zig.zon`

```zig
.{
    .name = .gooey,
    .version = "0.0.3",
    .fingerprint = 0xfcad6172ee59f0b8,
    .minimum_zig_version = "0.15.2",
    .dependencies = .{
        .zig_objc = .{
            .url = "git+https://github.com/mitchellh/zig-objc.git#...",
            .hash = "...",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "charts",       // Include charts sub-package
    },
}
```

### 9.3 Root `build.zig` (additions)

```zig
// After creating the gooey module...

// =======================================================================
// Charts Module (Optional)
// =======================================================================

const charts_mod = b.addModule("gooey-charts", .{
    .root_source_file = b.path("charts/src/root.zig"),
    .target = target,
    .optimize = optimize,
});
charts_mod.addImport("gooey", mod);  // Charts depends on core gooey

// Charts example
addNativeExample(b, mod, charts_mod, objc_dep.module("objc"), target, optimize,
    "charts-demo", "examples/charts_demo.zig", false);
```

### 9.4 `charts/build.zig.zon`

```zig
.{
    .name = .@"gooey-charts",
    .version = "0.0.1",
    .minimum_zig_version = "0.15.2",
    .dependencies = .{
        .gooey = .{ .path = ".." },  // Reference parent
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

### 9.5 `charts/build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get gooey from parent
    const gooey_dep = b.dependency("gooey", .{
        .target = target,
        .optimize = optimize,
    });

    // Create charts module
    const charts_mod = b.addModule("gooey-charts", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    charts_mod.addImport("gooey", gooey_dep.module("gooey"));

    // Tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("gooey", gooey_dep.module("gooey"));

    const test_step = b.step("test", "Run charts tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
```

### 9.6 `charts/src/root.zig`

````zig
//! Gooey Charts — Data visualization components
//!
//! Built on Gooey's Canvas API. Import alongside gooey:
//!
//! ```zig
//! const gooey = @import("gooey");
//! const charts = @import("gooey-charts");
//!
//! fn render(cx: *gooey.Cx) void {
//!     charts.BarChart{ .data = &data }.render(cx.builder());
//! }
//! ```

// Primitives (Layer 2)
pub const Scale = @import("primitives/scale.zig").Scale;
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

// Data types
pub const DataPoint = @import("types.zig").DataPoint;
pub const CategoryPoint = @import("types.zig").CategoryPoint;
pub const Series = @import("types.zig").Series;
pub const CategorySeries = @import("types.zig").CategorySeries;

// Theme
pub const ChartTheme = @import("theme.zig").ChartTheme;

// Re-export gooey types for convenience
const gooey = @import("gooey");
pub const Color = gooey.ui.Color;
pub const DrawContext = gooey.ui.DrawContext;
````

---

## 10. Implementation Roadmap

### Phase 1: Foundation (1 week)

- [ ] Project setup (build.zig, gooey dependency)
- [ ] `LinearScale` with ticks generation
- [ ] `BandScale` for categorical data
- [ ] `Axis` rendering (bottom, left orientations)
- [ ] `Grid` rendering
- [ ] Basic `BarChart` (single series, vertical)

**Milestone:** Render a simple bar chart

### Phase 2: Core Charts (1-2 weeks)

- [ ] `LineChart` (linear interpolation)
- [ ] `PieChart` / `DonutChart`
- [ ] `ScatterChart`
- [ ] Multi-series support for all charts
- [ ] `Legend` component
- [ ] Stacked bar charts

**Milestone:** All 4 core chart types working

### Phase 3: Polish (1 week)

- [ ] Theme integration
- [ ] Accessibility (figure role, descriptions)
- [ ] Horizontal bar charts
- [ ] Area charts (filled line charts)
- [ ] `LogScale` for exponential data
- [ ] Custom axis formatters

**Milestone:** Production-ready for common use cases

### Phase 4: Advanced (Future)

- [ ] `TimeScale` for date axes
- [ ] Tooltips (requires mouse position from Gooey)
- [ ] Animations (requires Gooey animation system)
- [ ] Zoom/pan interactions
- [ ] Combo charts (bar + line)
- [ ] Sparklines (tiny inline charts)

---

## 11. Constants & Limits

```zig
// Per CLAUDE.md — hard limits on everything

pub const MAX_DATA_POINTS: u32 = 4096;      // Per series
pub const MAX_SERIES: u32 = 16;              // Per chart
pub const MAX_CATEGORIES: u32 = 256;         // For bar/pie charts
pub const MAX_TICKS: u32 = 32;               // Per axis
pub const MAX_LEGEND_ITEMS: u32 = 32;
pub const MAX_LABEL_LENGTH: u32 = 64;        // Characters
```

---

## 12. Open Questions

1. **Tooltip positioning** — How to get mouse position from Gooey? Need `DrawContext.mousePosition()` or callback.

2. **Click handling** — How to detect clicks on chart elements? Need hit testing.

3. **Animation** — Should charts animate on data change? Requires Gooey animation primitives.

4. **Large datasets** — Should we support data decimation/sampling for >10k points?

5. **Responsive sizing** — Should charts auto-resize with container, or always explicit width/height?

---

## 13. References

- [SwiftUI Charts](https://developer.apple.com/documentation/charts) — Composable API inspiration
- [Recharts](https://recharts.org/) — React component patterns
- [D3.js Scales](https://d3js.org/d3-scale) — Scale implementation reference
- [Vega-Lite](https://vega.github.io/vega-lite/) — Grammar of graphics concepts
- [ImPlot](https://github.com/epezent/implot) — Immediate mode charting

---

## 14. Summary

`gooey-charts` is a **separate, optional package** that builds on Gooey's Canvas API to provide:

- **4 core chart types:** Bar, Line, Pie, Scatter
- **Composable primitives:** Scale, Axis, Grid, Legend
- **Theme integration:** Inherits Gooey colors, allows overrides
- **Accessibility:** Screen reader descriptions, data table fallback
- **Static allocation:** No dynamic allocation after init

The layered architecture allows simple one-liner charts while enabling full customization via primitives.
