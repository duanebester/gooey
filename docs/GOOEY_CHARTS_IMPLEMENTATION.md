# Gooey Charts — Implementation Plan

> Step-by-step guide to building gooey-charts from scratch

**Status:** Active  
**Based on:** [GOOEY_CHARTS_DESIGN.md](./GOOEY_CHARTS_DESIGN.md)  
**Last Updated:** 2025-01-14

---

## Overview

This document breaks down the gooey-charts implementation into granular, testable phases. Each phase builds on the previous and ends with a working milestone that can be demonstrated.

**Total Estimated Time:** 4-6 weeks  
**Dependencies:** Gooey's `DrawContext` API (canvas.zig)

---

## Phase 0: Project Scaffolding (Day 1)

### Goal
Set up the charts sub-package structure so it builds and integrates with Gooey.

### Tasks

- [ ] **0.1** Create `charts/` directory structure:
  ```
  charts/
  ├── build.zig
  ├── build.zig.zon
  ├── README.md
  └── src/
      ├── root.zig
      ├── types.zig
      ├── constants.zig
      ├── primitives/
      │   └── mod.zig
      └── charts/
          └── mod.zig
  ```

- [ ] **0.2** Create `charts/build.zig.zon`:
  ```zig
  .{
      .name = .@"gooey-charts",
      .version = "0.0.1",
      .fingerprint = 0x...,  // Generate unique
      .dependencies = .{},
      .paths = .{
          "build.zig",
          "build.zig.zon",
          "src",
      },
  }
  ```

- [ ] **0.3** Create `charts/build.zig` that exposes the module

- [ ] **0.4** Update root `build.zig.zon` to include `"charts"` in paths

- [ ] **0.5** Update root `build.zig` to:
  - Add `gooey-charts` module that imports gooey
  - Wire up charts examples

- [ ] **0.6** Create `charts/src/constants.zig` with limits:
  ```zig
  pub const MAX_DATA_POINTS: u32 = 4096;
  pub const MAX_SERIES: u32 = 16;
  pub const MAX_CATEGORIES: u32 = 256;
  pub const MAX_TICKS: u32 = 32;
  pub const MAX_LEGEND_ITEMS: u32 = 32;
  pub const MAX_LABEL_LENGTH: u32 = 64;
  ```

- [ ] **0.7** Create `charts/src/root.zig` with placeholder exports

- [ ] **0.8** Verify `zig build` succeeds with empty charts module

### Acceptance Criteria
- `zig build` completes without errors
- Can import `gooey-charts` in an example file
- Can access `gooey.ui.DrawContext` from within charts code

---

## Phase 1A: Data Types & Utilities (Days 2-3)

### Goal
Define the core data structures that all charts will use.

### Tasks

- [ ] **1A.1** Create `charts/src/types.zig`:
  ```zig
  pub const DataPoint = struct {
      x: f32,
      y: f32,
      label: ?[MAX_LABEL_LENGTH]u8 = null,
      label_len: u8 = 0,
  };

  pub const CategoryPoint = struct {
      label: [MAX_LABEL_LENGTH]u8,
      label_len: u8,
      value: f32,
      color: ?Color = null,
  };

  pub const Series = struct {
      name: [MAX_LABEL_LENGTH]u8,
      name_len: u8,
      data: [MAX_DATA_POINTS]DataPoint,
      data_len: u32,
      color: Color,
  };

  pub const CategorySeries = struct {
      name: [MAX_LABEL_LENGTH]u8,
      name_len: u8,
      data: [MAX_CATEGORIES]CategoryPoint,
      data_len: u32,
      color: Color,
  };
  ```

- [ ] **1A.2** Add helper functions for creating types from slices:
  ```zig
  pub fn dataPointsFromSlice(slice: []const struct { x: f32, y: f32 }) [MAX_DATA_POINTS]DataPoint
  pub fn categoryFromSlice(slice: []const struct { label: []const u8, value: f32 }) [MAX_CATEGORIES]CategoryPoint
  ```

- [ ] **1A.3** Create `charts/src/util.zig`:
  - `niceNumber(value: f32, round: bool) f32` — D3-style nice number algorithm
  - `niceRange(min: f32, max: f32, tick_count: u32) struct { min: f32, max: f32, step: f32 }`
  - `formatNumber(value: f32, buffer: []u8) []const u8` — Number to string

- [ ] **1A.4** Write tests for utility functions

### Acceptance Criteria
- All data types compile
- `niceNumber(0.0, 155.0, 5)` returns sensible tick range
- Can create a `Series` from literal data

---

## Phase 1B: LinearScale (Days 3-4)

### Goal
Implement the foundational scale that maps data values to pixel coordinates.

### Tasks

- [ ] **1B.1** Create `charts/src/primitives/scale.zig`:
  ```zig
  pub const LinearScale = struct {
      domain_min: f32,
      domain_max: f32,
      range_min: f32,
      range_max: f32,

      pub fn init(domain_min: f32, domain_max: f32, range_min: f32, range_max: f32) LinearScale
      pub fn scale(self: LinearScale, value: f32) f32
      pub fn invert(self: LinearScale, pixel: f32) f32
      pub fn ticks(self: LinearScale, count: u32, out: *[MAX_TICKS]f32) u32
  };
  ```

- [ ] **1B.2** Implement `scale()`:
  ```zig
  pub fn scale(self: LinearScale, value: f32) f32 {
      const domain_span = self.domain_max - self.domain_min;
      const range_span = self.range_max - self.range_min;
      std.debug.assert(domain_span != 0); // Per CLAUDE.md: assertions
      const t = (value - self.domain_min) / domain_span;
      return self.range_min + t * range_span;
  }
  ```

- [ ] **1B.3** Implement `invert()` (reverse mapping)

- [ ] **1B.4** Implement `ticks()` using nice numbers:
  - Generate `count` evenly-spaced tick values
  - Snap to "nice" numbers (1, 2, 5, 10, 20, 50, etc.)
  - Return actual number of ticks generated

- [ ] **1B.5** Add edge case handling:
  - Domain min == max (single value)
  - Negative domains
  - Inverted ranges (range_min > range_max for Y-axis)

- [ ] **1B.6** Write comprehensive tests

### Acceptance Criteria
- `LinearScale.init(0, 100, 0, 500).scale(50)` returns `250`
- `ticks(5)` returns values like `[0, 25, 50, 75, 100]`
- Y-axis (inverted range) works correctly

---

## Phase 1C: BandScale (Days 4-5)

### Goal
Implement categorical scale for bar charts.

### Tasks

- [ ] **1C.1** Add to `scale.zig`:
  ```zig
  pub const BandScale = struct {
      labels: [MAX_CATEGORIES][MAX_LABEL_LENGTH]u8,
      label_lens: [MAX_CATEGORIES]u8,
      label_count: u32,
      range_min: f32,
      range_max: f32,
      padding_inner: f32 = 0.1,
      padding_outer: f32 = 0.1,

      pub fn init(labels: []const []const u8, range_min: f32, range_max: f32) BandScale
      pub fn bandwidth(self: BandScale) f32
      pub fn position(self: BandScale, index: u32) f32
  };
  ```

- [ ] **1C.2** Implement `bandwidth()`:
  - Calculate width of each band accounting for padding
  - Formula: `range_span / (n + (n-1)*inner_padding + 2*outer_padding)`

- [ ] **1C.3** Implement `position()`:
  - Return the start X position for category at index
  - Account for outer padding offset

- [ ] **1C.4** Add `Scale` union type:
  ```zig
  pub const Scale = union(enum) {
      linear: LinearScale,
      band: BandScale,
      // log and time added later
  };
  ```

- [ ] **1C.5** Write tests

### Acceptance Criteria
- 4 categories in 400px range with 0.1 padding → each band ~80px wide
- `position(0)` returns left edge of first band
- `position(3)` returns left edge of fourth band

---

## Phase 1D: Axis Rendering (Days 5-7)

### Goal
Render axes with tick marks and labels.

### Tasks

- [ ] **1D.1** Create `charts/src/primitives/axis.zig`:
  ```zig
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
          color: Color = Color.hex(0x666666),
          label_color: Color = Color.hex(0x333333),
      };

      pub fn draw(ctx: *DrawContext, scale: Scale, x: f32, y: f32, opts: Options) void
  };
  ```

- [ ] **1D.2** Implement `draw()` for `.bottom` orientation:
  - Draw axis line from range_min to range_max at y position
  - For each tick: draw tick mark, render label below
  - Keep function under 70 lines — split into helpers

- [ ] **1D.3** Implement `draw()` for `.left` orientation:
  - Vertical axis line
  - Ticks extend left, labels to the left of ticks
  - Handle inverted Y scale (0 at bottom)

- [ ] **1D.4** Add helper `drawTick()`:
  ```zig
  fn drawTick(ctx: *DrawContext, x: f32, y: f32, orientation: Orientation, size: f32, color: Color) void
  ```

- [ ] **1D.5** Add helper `drawLabel()`:
  ```zig
  fn drawLabel(ctx: *DrawContext, text: []const u8, x: f32, y: f32, orientation: Orientation, color: Color) void
  ```

- [ ] **1D.6** Handle axis title rendering (optional label)

- [ ] **1D.7** Add `.top` and `.right` orientations

- [ ] **1D.8** Write visual test (render to canvas, inspect)

### Acceptance Criteria
- Bottom axis shows horizontal line with ticks pointing down
- Left axis shows vertical line with ticks pointing left
- Labels are legible and properly positioned
- Works with both LinearScale and BandScale

---

## Phase 1E: Grid Rendering (Day 8)

### Goal
Render background grid lines.

### Tasks

- [ ] **1E.1** Create `charts/src/primitives/grid.zig`:
  ```zig
  pub const Grid = struct {
      pub const Options = struct {
          show_horizontal: bool = true,
          show_vertical: bool = false,
          color: Color = Color.hex(0xE0E0E0),
          line_width: f32 = 1.0,
      };

      pub fn draw(
          ctx: *DrawContext,
          x_scale: Scale,
          y_scale: Scale,
          bounds: struct { x: f32, y: f32, width: f32, height: f32 },
          opts: Options,
      ) void
  };
  ```

- [ ] **1E.2** Implement horizontal grid lines:
  - Get tick values from y_scale
  - Draw horizontal lines at each tick's Y position
  - Span from x_min to x_max

- [ ] **1E.3** Implement vertical grid lines:
  - Get tick values from x_scale (or band positions)
  - Draw vertical lines at each tick's X position

- [ ] **1E.4** Support dashed lines (optional, use DrawContext.strokePath with dash pattern if available)

### Acceptance Criteria
- Horizontal grid lines align with Y-axis ticks
- Vertical grid lines align with X-axis ticks
- Grid renders behind chart data (draw order)

---

## Phase 1 Milestone: First Bar Chart 🎉 (Days 8-10)

### Goal
Render a complete, simple bar chart combining all primitives.

### Tasks

- [ ] **1M.1** Create `charts/src/charts/bar_chart.zig`:
  ```zig
  pub const BarChart = struct {
      // Data
      data: [MAX_SERIES]CategorySeries,
      series_count: u32 = 1,

      // Dimensions
      width: f32 = 400,
      height: f32 = 300,

      // Margins
      margin_top: f32 = 20,
      margin_right: f32 = 20,
      margin_bottom: f32 = 40,
      margin_left: f32 = 50,

      // Style
      bar_padding: f32 = 0.1,
      corner_radius: f32 = 0,

      // Axes
      show_x_axis: bool = true,
      show_y_axis: bool = true,

      // Grid
      show_grid: bool = true,

      pub fn render(self: BarChart, ctx: *DrawContext) void
  };
  ```

- [ ] **1M.2** Implement `render()`:
  1. Calculate inner bounds (width - margins)
  2. Create BandScale for X (categories)
  3. Find Y domain (0 to max value)
  4. Create LinearScale for Y (inverted for screen coords)
  5. Draw grid (if enabled)
  6. Draw each bar (fillRect)
  7. Draw axes

- [ ] **1M.3** Add color palette for bars:
  - Use category's color if specified
  - Otherwise cycle through default palette

- [ ] **1M.4** Create `examples/charts_demo.zig`:
  ```zig
  const gooey = @import("gooey");
  const charts = @import("gooey-charts");
  const ui = gooey.ui;

  pub fn view(b: *ui.Builder) void {
      const data = charts.categoryFromSlice(&.{
          .{ .label = "Jan", .value = 30 },
          .{ .label = "Feb", .value = 45 },
          .{ .label = "Mar", .value = 28 },
          .{ .label = "Apr", .value = 55 },
      });

      const chart = charts.BarChart{
          .data = .{charts.CategorySeries{
              .data = data,
              .data_len = 4,
              // ...
          }},
          .width = 500,
          .height = 300,
      };

      ui.canvas(500, 300, struct {
          fn paint(ctx: *ui.DrawContext) void {
              chart.render(ctx);
          }
      }.paint).render(b);
  }
  ```

- [ ] **1M.5** Run example and verify visual output

- [ ] **1M.6** Fix any rendering issues

### Acceptance Criteria
- Bar chart renders with proper axes
- Bars are correctly sized and positioned
- Labels are readable
- Grid lines align with ticks
- No dynamic allocation during render

---

## Phase 2A: Line Chart (Days 11-13)

### Goal
Implement line chart with linear interpolation.

### Tasks

- [ ] **2A.1** Create `charts/src/charts/line_chart.zig`:
  ```zig
  pub const LineChart = struct {
      series: [MAX_SERIES]Series,
      series_count: u32 = 1,

      width: f32 = 400,
      height: f32 = 300,

      line_width: f32 = 2,
      show_points: bool = true,
      point_radius: f32 = 4,

      // Area fill
      show_area: bool = false,
      area_opacity: f32 = 0.3,

      // Auto-domain or explicit
      x_domain: ?struct { min: f32, max: f32 } = null,
      y_domain: ?struct { min: f32, max: f32 } = null,

      pub fn render(self: LineChart, ctx: *DrawContext) void
  };
  ```

- [ ] **2A.2** Implement domain calculation:
  - Scan all series to find min/max X and Y
  - Apply nice number rounding
  - Use explicit domain if provided

- [ ] **2A.3** Implement line rendering:
  - Use `ctx.beginPath()` and `lineTo()` for each point
  - `ctx.strokePath()` with series color

- [ ] **2A.4** Implement point markers:
  - Draw circles at each data point
  - Use `ctx.fillCircle()`

- [ ] **2A.5** Implement area fill:
  - Close path to X-axis
  - Fill with semi-transparent color

- [ ] **2A.6** Add multi-series support:
  - Iterate through all series
  - Each series has its own color

- [ ] **2A.7** Add to example

### Acceptance Criteria
- Line connects all points in order
- Points are visible at each data value
- Multiple series render with different colors
- Area fill works correctly

---

## Phase 2B: Pie/Donut Chart (Days 14-16)

### Goal
Implement pie chart with optional donut hole.

### Tasks

- [ ] **2B.1** Create `charts/src/charts/pie_chart.zig`:
  ```zig
  pub const PieChart = struct {
      data: [MAX_CATEGORIES]CategoryPoint,
      data_len: u32,

      width: f32 = 300,
      height: f32 = 300,

      inner_radius: f32 = 0, // >0 for donut
      pad_angle: f32 = 0.02, // Gap between slices

      show_labels: bool = true,
      label_position: enum { inside, outside, none } = .outside,

      pub fn render(self: PieChart, ctx: *DrawContext) void
  };
  ```

- [ ] **2B.2** Calculate slice angles:
  - Sum all values
  - Each slice: `angle = value / total * 2π`
  - Store start/end angles for each slice

- [ ] **2B.3** Implement arc rendering:
  - For each slice, draw arc path
  - Use `ctx.arc()` or manual bezier approximation
  - Fill with category color

- [ ] **2B.4** Implement donut:
  - Draw inner arc in reverse
  - Close path to create ring shape

- [ ] **2B.5** Implement labels:
  - Calculate centroid of each slice
  - Position text at centroid (inside) or outside edge (outside)

- [ ] **2B.6** Handle small slices:
  - Skip label if slice too small
  - Optionally group tiny slices into "Other"

- [ ] **2B.7** Add to example

### Acceptance Criteria
- Pie fills full circle
- Donut has visible hole
- Slices have visible gaps (pad_angle)
- Labels are positioned correctly

---

## Phase 2C: Scatter Chart (Days 17-18)

### Goal
Implement scatter plot for X-Y data.

### Tasks

- [ ] **2C.1** Create `charts/src/charts/scatter_chart.zig`:
  ```zig
  pub const ScatterChart = struct {
      series: [MAX_SERIES]Series,
      series_count: u32 = 1,

      width: f32 = 400,
      height: f32 = 300,

      point_radius: f32 = 5,
      point_shape: enum { circle, square, triangle, diamond } = .circle,

      pub fn render(self: ScatterChart, ctx: *DrawContext) void
  };
  ```

- [ ] **2C.2** Implement basic scatter (circles):
  - Create X and Y linear scales
  - Plot each point as filled circle

- [ ] **2C.3** Implement different shapes:
  - Square: `fillRect` centered on point
  - Triangle: 3-point path
  - Diamond: rotated square path

- [ ] **2C.4** Multi-series with different colors

- [ ] **2C.5** Add to example

### Acceptance Criteria
- Points are correctly positioned
- Different series have different colors
- Shapes render correctly

---

## Phase 2D: Legend Component (Days 19-20)

### Goal
Implement reusable legend for all chart types.

### Tasks

- [ ] **2D.1** Create `charts/src/primitives/legend.zig`:
  ```zig
  pub const Legend = struct {
      pub const Position = enum { top, bottom, left, right };
      pub const Shape = enum { rect, circle, line };

      pub const Item = struct {
          label: [MAX_LABEL_LENGTH]u8,
          label_len: u8,
          color: Color,
          shape: Shape = .rect,
      };

      pub const Options = struct {
          position: Position = .bottom,
          items: [MAX_LEGEND_ITEMS]Item,
          item_count: u32,
          spacing: f32 = 20,
          item_size: f32 = 12,
      };

      pub fn draw(ctx: *DrawContext, x: f32, y: f32, opts: Options) void
      pub fn measure(opts: Options) struct { width: f32, height: f32 }
  };
  ```

- [ ] **2D.2** Implement horizontal layout (top/bottom):
  - Items flow left to right
  - Shape + label + spacing

- [ ] **2D.3** Implement vertical layout (left/right):
  - Items stack vertically

- [ ] **2D.4** Implement `measure()`:
  - Calculate total width/height needed
  - Used by charts to adjust margins

- [ ] **2D.5** Integrate into BarChart, LineChart, etc.

### Acceptance Criteria
- Legend items show correct colors
- Shapes match chart type (rect for bar, line for line chart)
- Positioning works for all 4 positions

---

## Phase 2 Milestone: Multi-Series Dashboard 🎉 (Day 21)

### Goal
Create a demo showing all chart types together.

### Tasks

- [ ] **2M.1** Create `examples/dashboard.zig`:
  - 2x2 grid of charts
  - Bar chart (top-left)
  - Line chart (top-right)
  - Pie chart (bottom-left)
  - Scatter chart (bottom-right)

- [ ] **2M.2** Use consistent theme/colors across charts

- [ ] **2M.3** Add legends to each chart

- [ ] **2M.4** Test with different data sets

### Acceptance Criteria
- All 4 chart types render correctly
- Legends are visible and accurate
- No visual glitches

---

## Phase 3A: Theme Integration (Days 22-23)

### Goal
Integrate with Gooey's theme system.

### Tasks

- [ ] **3A.1** Create `charts/src/theme.zig`:
  ```zig
  pub const ChartTheme = struct {
      background: Color,
      foreground: Color,  // Text, axes
      muted: Color,       // Grid lines

      palette: [12]Color, // Data colors

      positive: Color,    // Green for gains
      negative: Color,    // Red for losses

      pub const default_palette = [12]Color{
          Color.hex(0x2563eb), // Blue
          Color.hex(0xdc2626), // Red
          Color.hex(0x16a34a), // Green
          // ... etc
      };

      pub fn fromGooeyTheme(theme: gooey.ui.Theme) ChartTheme
  };
  ```

- [ ] **3A.2** Add theme parameter to all chart structs

- [ ] **3A.3** Use theme colors for:
  - Axis lines and labels
  - Grid lines
  - Default data palette

- [ ] **3A.4** Add dark mode support

### Acceptance Criteria
- Charts respect Gooey theme
- Dark mode looks good
- Colors are consistent

---

## Phase 3B: Accessibility (Days 24-25)

### Goal
Add screen reader support.

### Tasks

- [ ] **3B.1** Add accessible properties to chart structs:
  ```zig
  accessible_title: ?[]const u8 = null,
  accessible_description: ?[]const u8 = null,
  ```

- [ ] **3B.2** Generate automatic descriptions:
  ```zig
  fn generateDescription(chart: BarChart) []const u8 {
      // "Bar chart showing 4 categories. Highest: Apr at 55. Lowest: Mar at 28."
  }
  ```

- [ ] **3B.3** Integrate with Gooey's accessibility system:
  - Set ARIA role="figure"
  - Set aria-label

- [ ] **3B.4** Add data table fallback option

### Acceptance Criteria
- VoiceOver/screen readers announce chart summary
- Data is accessible without vision

---

## Phase 3C: Additional Features (Days 26-28)

### Goal
Add polish features.

### Tasks

- [ ] **3C.1** Horizontal bar charts:
  - Swap X/Y axes
  - Bars grow left-to-right

- [ ] **3C.2** Stacked bar charts:
  - Stack series on top of each other
  - Calculate cumulative heights

- [ ] **3C.3** Area charts:
  - Line chart with `show_area = true`
  - Support stacked areas

- [ ] **3C.4** Custom axis formatters:
  ```zig
  label_format: ?fn(f32, []u8) []const u8 = null,
  ```

- [ ] **3C.5** Rounded bar corners

- [ ] **3C.6** Line chart curve types:
  - `.linear` (done)
  - `.step` (horizontal then vertical)
  - `.monotone` (smooth, future)

### Acceptance Criteria
- Horizontal bars render correctly
- Stacked bars sum correctly
- Area fills don't overflow

---

## Phase 3 Milestone: Production Ready 🎉 (Day 28)

### Goal
Finalize for initial release.

### Tasks

- [ ] **3M.1** Code review all files for CLAUDE.md compliance:
  - [ ] ≤70 line functions
  - [ ] ≥2 assertions per function
  - [ ] No dynamic allocation
  - [ ] All limits enforced

- [ ] **3M.2** Write documentation:
  - README.md for charts/
  - API examples
  - Common patterns

- [ ] **3M.3** Create comprehensive example set

- [ ] **3M.4** Performance testing:
  - 4096 data points renders <16ms
  - No allocation during render

### Acceptance Criteria
- All charts work reliably
- Documentation complete
- Performance targets met

---

## Phase 4: Future Enhancements (Backlog)

These are not planned for initial release but documented for later.

### 4.1 LogScale
- Logarithmic scale for exponential data
- Base-10 and base-e options

### 4.2 TimeScale
- Date/time aware scale
- Auto-formats: "Jan", "2024", "Mon", etc.

### 4.3 Tooltips
- Requires mouse position from Gooey
- Show value on hover

### 4.4 Animations
- Requires Gooey animation system
- Animate on data change

### 4.5 Interactions
- Click handlers on bars/points
- Zoom and pan

### 4.6 Advanced Charts
- Combo charts (bar + line)
- Sparklines
- Gauge charts
- Heatmaps

---

## File Checklist

### Phase 0-1
- [ ] `charts/build.zig`
- [ ] `charts/build.zig.zon`
- [ ] `charts/README.md`
- [ ] `charts/src/root.zig`
- [ ] `charts/src/constants.zig`
- [ ] `charts/src/types.zig`
- [ ] `charts/src/util.zig`
- [ ] `charts/src/primitives/mod.zig`
- [ ] `charts/src/primitives/scale.zig`
- [ ] `charts/src/primitives/axis.zig`
- [ ] `charts/src/primitives/grid.zig`
- [ ] `charts/src/charts/mod.zig`
- [ ] `charts/src/charts/bar_chart.zig`

### Phase 2
- [ ] `charts/src/charts/line_chart.zig`
- [ ] `charts/src/charts/pie_chart.zig`
- [ ] `charts/src/charts/scatter_chart.zig`
- [ ] `charts/src/primitives/legend.zig`

### Phase 3
- [ ] `charts/src/theme.zig`
- [ ] `charts/src/accessibility.zig`

### Examples
- [ ] `examples/charts_demo.zig`
- [ ] `examples/dashboard.zig`

---

## Testing Strategy

### Unit Tests
- Scale calculations
- Tick generation
- Nice number algorithm
- Domain auto-detection

### Visual Tests
- Render to canvas and inspect
- Compare against reference images
- Test edge cases (empty data, single point, etc.)

### Performance Tests
- Time render with MAX_DATA_POINTS
- Ensure no allocations via allocator tracking
- Profile hot paths

---

## Notes

- Keep PRs focused: one phase = one PR
- Run `zig build test` before each commit
- Visual inspection after each milestone
- Follow CLAUDE.md strictly — no exceptions
