# Deep Dive: Gooey Charts Library Analysis

## Summary

Your chart library is **well-designed** and follows the CLAUDE.md guidelines excellently. The architecture is solid with proper static memory allocation, slice-based data ownership, and performance instrumentation. However, I found several areas for improvement and a few potential bugs.

---

## ✅ Fixed Issues

### 1. ~~**Duplicated Default Palettes (DRY Violation)**~~ ✅ FIXED

All chart files now import the palette from `theme.zig` as the single source of truth:

```gooey/charts/src/charts/bar_chart.zig#L42
pub const default_palette = theme_mod.google_palette;
```

Additionally, `theme.zig` now provides light/dark mode optimized Google palettes:

- `google_light_palette` - Darker, more saturated colors for light backgrounds
- `google_dark_palette` - Brighter colors for better visibility on dark backgrounds
- `google_palette` - Standard balanced palette for general use

The `ChartTheme.light` and `ChartTheme.dark` presets automatically use the appropriate palette.

---

### 2. ~~**Conflicting Palette Exports in `root.zig`**~~ ✅ FIXED

Cleaned up exports with clear naming:

```gooey/charts/src/root.zig#L113-127
pub const default_palette = theme.default_palette;
pub const google_light_palette = theme.google_light_palette;
pub const google_dark_palette = theme.google_dark_palette;
pub const google_palette = theme.google_palette;
```

Removed the confusing `default_chart_palette` export.

---

### 3. ~~**Triangle/Diamond Drawing Uses Horizontal Strips (Inefficient)**~~ ✅ FIXED

ScatterChart now uses `fillTriangle` directly instead of 8+ rectangle strips:

```gooey/charts/src/charts/scatter_chart.zig#L506-518
fn drawTriangle(_: *const ScatterChart, ctx: *DrawContext, x: f32, y: f32, radius: f32, color: Color) void {
    std.debug.assert(radius > 0);
    const h = radius * 2.2;
    const half_w = h * 0.577;
    const top_y = y - h * 0.667;
    const bottom_y = y + h * 0.333;
    ctx.fillTriangle(x, top_y, x - half_w, bottom_y, x + half_w, bottom_y, color);
}
```

Diamond now uses 2 triangles instead of 16 rectangle strips. This significantly reduces draw calls for scatter charts with triangle/diamond shapes.

---

### 4. ~~**Missing `bindRender` Method (Docs vs. Implementation)**~~ ✅ FIXED

Updated documentation to show the actual API pattern (using a free function for canvas):

```gooey/charts/src/root.zig#L14-35
//! fn paintChart(ctx: *charts.DrawContext) void {
//!     const chart = charts.BarChart.init(&bar_data);
//!     chart.render(ctx);
//! }
//!
//! fn render(cx: *gooey.Cx) void {
//!     cx.render(ui.box(.{}, .{
//!         ui.canvas(400, 300, paintChart),
//!     }));
//! }
```

---

## 🐛 Issues to Fix

---

### 1. **Unused `half_pad_inner` Parameter in `PieChart.drawSlice`**

```gooey/charts/src/charts/pie_chart.zig#L269-281
fn drawSlice(
    self: *const PieChart,
    // ...
    half_pad_outer: f32,
    half_pad_inner: f32,  // <-- Passed but marked unused!
    color: Color,
) void {
    _ = half_pad_inner; // Only used for actual donuts, not full pies with gap_pixels
```

The `half_pad_inner` is calculated in `drawSlices()` but never actually used - it's immediately discarded. For donuts, the code recalculates it inline:

```gooey/charts/src/charts/pie_chart.zig#L302-303
const inner_start = base_angle + (if (self.gap_pixels) |gap| gap / (2.0 * inner_r) else half_pad_outer);
const inner_end = base_angle + slice_angle - (if (self.gap_pixels) |gap| gap / (2.0 * inner_r) else half_pad_outer);
```

**Fix:** Either use the pre-calculated `half_pad_inner` or remove it from the signature.

---

### 2. **Dead Code: Division by Zero Check in `BandScale.recalculate()`**

```gooey/charts/src/primitives/scale.zig#L193-203
fn recalculate(self: *BandScale) void {
    std.debug.assert(self.label_count > 0);

    const n: f32 = @floatFromInt(self.label_count);
    // ...
    const denominator = n + (n - 1) * self.padding_inner + 2 * self.padding_outer;

    if (denominator <= 0) {  // <-- Dead code
```

With `n >= 1`, `padding_inner` and `padding_outer` in `[0, 1]`, the minimum denominator is `1 + 0 + 0 = 1`. The `denominator <= 0` check can never be true.

**Fix:** Replace with `unreachable` with a comment explaining why, or remove entirely.

---

### 5. **ScatterChart `drawSeriesPointsBatched` Is Never Called**

There's a TODO comment and dead code:

```gooey/charts/src/charts/scatter_chart.zig#L359-365
/// Draw all series points.
/// TODO: Investigate using drawSeriesPointsBatched for circle shapes without size encoding.
/// The pointCloud API should work (LineChart uses it successfully), but when enabled here
/// the points don't render. Likely a z-ordering or clip bounds issue to investigate.
fn drawAllPoints(self: *const ScatterChart, ctx: *DrawContext, x_scale: LinearScale, y_scale: LinearScale) void {
```

The `drawSeriesPointsBatched` function exists but is never used.

**Recommendation:** Either fix and enable batch rendering, or remove the dead code. LineChart uses `pointCloud` successfully, so it should work for ScatterChart too.

---

### 6. **Missing Assertions in `invLerp` and Other Functions**

Per CLAUDE.md's "minimum 2 assertions per function" guideline:

```gooey/charts/src/util.zig#L272-276
pub fn invLerp(a: f32, b: f32, value: f32) f32 {
    const range = b - a;
    std.debug.assert(range != 0);
    return (value - a) / range;
}
```

Good that `range != 0` is asserted, but inputs aren't validated for NaN/Inf.

**Fix:** Add comprehensive assertions:

```/dev/null/suggestion.zig#L1-6
pub fn invLerp(a: f32, b: f32, value: f32) f32 {
    std.debug.assert(!std.math.isNan(a) and !std.math.isNan(b) and !std.math.isNan(value));
    const range = b - a;
    std.debug.assert(range != 0);
    return (value - a) / range;
}
```

---

## ⚡ Performance Improvements

### 5. **LineChart Area Fill Uses 4× Segments**

```gooey/charts/src/charts/line_chart.zig#L380-411
fn drawSeriesArea(...) void {
    const SUBDIVISIONS: u32 = 4; // 4 rectangles per segment
    // ...
    while (j < SUBDIVISIONS) : (j += 1) {
        ctx.fillRect(sub_x, sub_y, sub_width, h, color);
    }
```

For N data points, this creates `4 × (N-1)` rectangles. The comment in constants.zig mentions:

```gooey/charts/src/constants.zig#L54-56
/// Maximum polygon vertices for area fill optimization
/// Area fill uses single polygon instead of 4×(N-1) rectangles
pub const MAX_AREA_POLYGON_VERTICES: u32 = MAX_DATA_POINTS * 2 + 2;
```

The optimization is defined but not implemented!

**Fix:** Consider using a polygon fill API if available in DrawContext, or use actual triangles forming an efficient fan/strip.

---

### 10. **Duplicated LTTB Decimation Logic**

The LTTB decimation code is duplicated in `drawSeriesLine` and `drawSeriesPoints` (LineChart), and again in `drawSeriesPointsBatched` (ScatterChart). Each creates temporary `input_points` and `decimated` arrays.

**Fix:** Extract a helper function:

```/dev/null/suggestion.zig#L1-10
fn decimateAndScaleSeries(
    series: *const Series,
    x_scale: LinearScale,
    y_scale: LinearScale,
    output: *[MAX_DATA_POINTS][2]f32,
    enable_lod: bool,
    lod_target: u32,
) usize {
    // Shared logic for LOD + scaling
}
```

---

## 🎨 API/Design Suggestions

### 11. **Light/Dark Theme-Optimized Palettes**

The theme system already has excellent light/dark presets in `theme.zig`:

```gooey/charts/src/theme.zig#L94-133
pub const light = ChartTheme{ ... };  // Catppuccin Latte
pub const dark = ChartTheme{ ... };   // Catppuccin Macchiato
```

**However**, the categorical palettes (`default_palette`, `google_palette`, `colorblind_palette`) are identical for both themes. Some colors work better on dark vs. light backgrounds.

**Suggestion:** Add theme-optimized palettes:

```/dev/null/suggestion.zig#L1-20
// Light theme palette (darker, more saturated for light backgrounds)
pub const light_palette = [MAX_PALETTE_COLORS]Color{
    Color.hex(0x1f77b4), // Darker blue
    Color.hex(0xd62728), // Darker red
    // ...
};

// Dark theme palette (brighter, slightly desaturated for dark backgrounds)
pub const dark_palette = [MAX_PALETTE_COLORS]Color{
    Color.hex(0x6baed6), // Lighter blue
    Color.hex(0xfc9272), // Lighter red
    // ...
};

// Then integrate into ChartTheme presets:
pub const light = ChartTheme{
    .palette = light_palette,
    // ...
};
```

---

### 12. **Base Chart Interface - Not Needed (Zig Idiom)**

In Zig, a base interface/trait isn't idiomatic. The current approach is correct. All charts share:

- `render(ctx: *DrawContext)`
- `describe(buf) / summarize(buf)` (accessibility)
- `getAccessibilityInfo()`

If runtime polymorphism is needed later, use a tagged union:

```/dev/null/suggestion.zig#L1-18
pub const AnyChart = union(enum) {
    bar: *const BarChart,
    line: *const LineChart,
    pie: *const PieChart,
    scatter: *const ScatterChart,

    pub fn render(self: AnyChart, ctx: *DrawContext) void {
        switch (self) {
            inline else => |chart| chart.render(ctx),
        }
    }

    pub fn hitTest(self: AnyChart, x: f32, y: f32) ?HitResult {
        // Dispatch to each chart's hitTest (if implemented)
    }
};
```

**Recommendation:** Current struct-per-chart approach is fine. Only add `AnyChart` if a use case requires it.

---

### 13. **`hitTest` Only in PieChart and ScatterChart**

`PieChart.hitTest()` and `ScatterChart.hitTest()` exist, but `BarChart` and `LineChart` don't have hit testing. For interactivity (tooltips, selection), these would be valuable.

**Fix:** Add `hitTest` to BarChart and LineChart:

```/dev/null/suggestion.zig#L1-15
// BarChart
pub fn hitTest(self: *const BarChart, x: f32, y: f32) ?struct { series: usize, category: usize } {
    // Check if (x, y) falls within any bar's bounding rect
}

// LineChart
pub fn hitTest(self: *const LineChart, x: f32, y: f32) ?struct { series: usize, point: usize } {
    // Check if (x, y) is within radius of any point
    // Or check proximity to line segments
}
```

---

### 14. **Missing: Data Update Strategy**

Charts store `data: []const Series` (slices to external data). For animations or live updates, how should data change?

Currently you'd:

1. Mutate the underlying array
2. Call `render()` again

**Suggestion:** Consider a `setData()` method with bounds checking:

```/dev/null/suggestion.zig#L1-8
pub fn setData(self: *LineChart, new_data: []const Series) void {
    std.debug.assert(new_data.len <= MAX_SERIES);
    for (new_data) |series| {
        std.debug.assert(series.point_count <= MAX_DATA_POINTS);
    }
    self.data = new_data;
}
```

---

### 15. **Missing: Tooltip/Crosshair Rendering Primitives**

The code has `hitTest` and `summarize` for tooltip content, but no actual tooltip drawing. This is probably intentional (let Gooey handle UI overlays), but worth documenting as the expected pattern.

---

### 16. **No `fromSlice` Convenience for Charts**

`CategorySeries` and `Series` have `fromSlice` methods for easy initialization:

```gooey/charts/src/types.zig#L126-137
pub fn fromSlice(
    name: []const u8,
    points: []const struct { x: f32, y: f32 },
    color: ?Color,
) Series { ... }
```

But creating a BarChart from inline data still requires multiple steps. Consider adding chart-level convenience:

```/dev/null/suggestion.zig#L1-8
// Current (verbose):
var series_array = [_]CategorySeries{
    CategorySeries.fromSlice("Sales", &.{...}, color),
};
const chart = BarChart.init(&series_array);

// Could add:
const chart = BarChart.fromSlice("Sales", &.{...}, color);
```

---

### 17. **Accessibility: Keyboard Navigation Not Wired**

The `FocusPosition` struct exists for keyboard navigation:

```gooey/charts/src/accessibility.zig#L454-488
pub const FocusPosition = struct {
    series_idx: u32 = 0,
    point_idx: u32 = 0,

    pub fn next(...) FocusPosition { ... }
    pub fn prev(...) FocusPosition { ... }
};
```

But it's not actually wired into any chart's event handling. This is fine for MVP, but worth tracking.

---

## 📐 Minor Code Quality

### 18. **Inconsistent Theme Application**

In `drawBars`, the color priority is:

```gooey/charts/src/charts/bar_chart.zig#L254-256
const color = point.color orelse series.color orelse
    (if (self.chart_theme) |t| t.paletteColor(series_idx) else default_palette[series_idx % 12]);
```

But in `getSeriesColor` (LineChart/ScatterChart):

```gooey/charts/src/charts/line_chart.zig#L562-571
fn getSeriesColor(self: *const LineChart, series: *const Series, index: usize) Color {
    if (series.color) |color| return color;
    if (self.chart_theme) |t| return t.paletteColor(index);
    return default_palette[index % default_palette.len];
}
```

BarChart checks **point** color first, others don't. This is intentional (bar slices can have individual colors), but the different patterns make it easy to miss.

**Suggestion:** Add a comment explaining the intentional difference.

---

### 19. **Magic Numbers**

Some magic numbers could be constants:

```gooey/charts/src/charts/pie_chart.zig#L185-186
const outer_radius = @min(cx, cy) * 0.85; // Leave margin for labels
```

```gooey/charts/src/charts/scatter_chart.zig#L651
const hit_radius = self.point_radius + 4; // 4px padding for easier clicking
```

**Fix:** Extract to named constants in `constants.zig`:

```/dev/null/suggestion.zig#L1-5
pub const PIE_CHART_RADIUS_RATIO: f32 = 0.85;
pub const HIT_TEST_PADDING_PX: f32 = 4.0;
```

---

## ✅ What's Done Well

1. **Slice-based data ownership** - Charts don't embed large arrays, avoiding stack overflow
2. **`initInPlace` with `noinline`** - Correctly handles large struct initialization
3. **Performance timing instrumentation** - `ENABLE_PERF_LOGGING` with threshold warnings
4. **LTTB decimation for large datasets** - Proper LOD implementation
5. **Comprehensive accessibility module** - Screen reader descriptions, ARIA roles
6. **Hard limits on everything** - `MAX_DATA_POINTS`, `MAX_SERIES`, etc.
7. **Comptime assertions** - Validate constants at compile time
8. **Struct size tests** - Prevent accidental bloat
9. **`*const` pointer iteration** - Avoids copying large structs in loops
10. **Colorblind-safe palette option** - Good accessibility thinking
11. **Light/dark theme presets** - Catppuccin-based themes with semantic colors
12. **`ChartTheme.fromTheme()`** - Integrates with Gooey's theme system
13. **`contrastingText()` helper** - For readable labels on colored backgrounds

---

## 🎯 Priority Recommendations

### ✅ Completed (High Priority)

1. ~~**Fix duplicate palettes + export confusion**~~ ✅ - All charts now import from `theme.zig`
2. ~~**Use `fillTriangle` for scatter shapes**~~ ✅ - Triangle uses 1 call, diamond uses 2 calls (was 8-16 rectangles)
3. ~~**Update docs for actual API**~~ ✅ - Documentation now shows correct canvas + paint function pattern
4. ~~**Add light/dark-optimized palettes**~~ ✅ - Added `google_light_palette` and `google_dark_palette`

### Medium Priority (Feature Parity)

5. **Add `hitTest` to BarChart/LineChart** - Enables interactivity
6. **Fix/remove unused `half_pad_inner`** - Code clarity

### Lower Priority (Nice to Have)

7. **Add NaN assertions per CLAUDE.md** - Robustness
8. **Remove dead code** - `denominator <= 0` check, unused batch render
9. **Investigate ScatterChart batch rendering** - Potential performance win
10. **Extract LTTB decimation helper** - DRY improvement
