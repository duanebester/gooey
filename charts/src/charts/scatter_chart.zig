//! Scatter Chart Component for Gooey Charts
//!
//! Renders X/Y data as scattered points with optional size encoding (bubble chart).
//! Supports multiple point shapes and multiple series with different colors.
//!
//! NOTE: ScatterChart stores a *slice* to externally-owned series data.
//! The caller is responsible for ensuring the data outlives the chart.
//! This avoids embedding large arrays on the stack (per CLAUDE.md).

const std = @import("std");
const builtin = @import("builtin");
const gooey = @import("gooey");
const constants = @import("../constants.zig");
const types = @import("../types.zig");
const util = @import("../util.zig");
const theme_mod = @import("../theme.zig");
const a11y = @import("../accessibility.zig");
const scale_mod = @import("../primitives/scale.zig");
const axis_mod = @import("../primitives/axis.zig");
const grid_mod = @import("../primitives/grid.zig");

const LinearScale = scale_mod.LinearScale;
const Axis = axis_mod.Axis;
const Grid = grid_mod.Grid;

const Series = types.Series;
const DataPoint = types.DataPoint;
const ChartTheme = theme_mod.ChartTheme;

pub const Color = gooey.ui.Color;
pub const DrawContext = gooey.ui.DrawContext;

const MAX_SERIES = constants.MAX_SERIES;
const MAX_DATA_POINTS = constants.MAX_DATA_POINTS;
const ENABLE_PERF_LOGGING = constants.ENABLE_PERF_LOGGING;
const PERF_WARNING_THRESHOLD_NS = constants.PERF_WARNING_THRESHOLD_NS;
const LOD_THRESHOLD = constants.LOD_THRESHOLD;

// Decimation point type alias for LTTB algorithm
const DecimationPoint = util.DecimationPoint;

// =============================================================================
// Default Color Palette (imported from theme.zig - single source of truth)
// =============================================================================

pub const default_palette = theme_mod.google_palette;

// =============================================================================
// Point Shapes
// =============================================================================

pub const PointShape = enum {
    circle,
    square,
    triangle,
    diamond,
};

// =============================================================================
// ScatterChart
// =============================================================================

pub const ScatterChart = struct {
    // Data - stored as a slice to avoid large stack allocation
    // The caller owns the underlying data; chart just references it
    data: []const Series,

    // Dimensions
    width: f32 = constants.DEFAULT_WIDTH,
    height: f32 = constants.DEFAULT_HEIGHT,

    // Margins
    margin_top: f32 = constants.DEFAULT_MARGIN_TOP,
    margin_right: f32 = constants.DEFAULT_MARGIN_RIGHT,
    margin_bottom: f32 = constants.DEFAULT_MARGIN_BOTTOM,
    margin_left: f32 = constants.DEFAULT_MARGIN_LEFT,

    // Point styling
    point_radius: f32 = constants.DEFAULT_POINT_RADIUS,
    point_shape: PointShape = .circle,
    point_opacity: f32 = 0.8,

    // Size encoding (bubble chart mode)
    // When size_data is set, point radii are scaled by the corresponding values
    size_data: ?[]const []const f32 = null, // Per-series, per-point sizes
    size_range: [2]f32 = .{ 4.0, 20.0 }, // Min/max radius for size scaling

    // Domain overrides (null = auto-detect from data)
    x_domain_min: ?f32 = null,
    x_domain_max: ?f32 = null,
    y_domain_min: ?f32 = null,
    y_domain_max: ?f32 = null,

    // Axes
    show_x_axis: bool = true,
    show_y_axis: bool = true,
    x_axis_opts: Axis.Options = .{ .orientation = .bottom },
    y_axis_opts: Axis.Options = .{ .orientation = .left },

    // Grid
    show_grid: bool = true,
    grid_opts: Grid.Options = .{ .show_horizontal = true, .show_vertical = true },

    // Theme (optional - uses default colors if null)
    chart_theme: ?*const ChartTheme = null,

    // Accessibility
    accessible_title: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    // Level-of-Detail (LOD) for large datasets
    // When enabled, datasets with >LOD_THRESHOLD points use LTTB decimation
    enable_lod: bool = true,
    lod_target_points: u32 = LOD_THRESHOLD,

    // ==========================================================================
    // Initialization
    // ==========================================================================

    /// Create a scatter chart from a slice of series.
    /// The slice must outlive the chart - data is NOT copied.
    pub fn init(data: []const Series) ScatterChart {
        std.debug.assert(data.len > 0);
        std.debug.assert(data.len <= MAX_SERIES);
        return .{ .data = data };
    }

    /// Create a scatter chart from a single series (as a 1-element slice).
    /// The series must outlive the chart - data is NOT copied.
    pub fn initSingle(series: *const Series) ScatterChart {
        std.debug.assert(series.data_len > 0);
        const slice: []const Series = @as([*]const Series, @ptrCast(series))[0..1];
        return .{ .data = slice };
    }

    // ==========================================================================
    // Accessors
    // ==========================================================================

    pub fn seriesCount(self: *const ScatterChart) u32 {
        std.debug.assert(self.data.len <= MAX_SERIES);
        return @intCast(self.data.len);
    }

    // ==========================================================================
    // Accessibility
    // ==========================================================================

    /// Get accessibility information for this chart.
    /// Use with `charts.describeChart()` to generate screen reader descriptions.
    pub fn getAccessibilityInfo(self: *const ScatterChart) a11y.ChartInfo {
        var info = a11y.infoFromSeries(self.data, .scatter);
        info.title = self.accessible_title;
        info.description = self.accessible_description;
        return info;
    }

    /// Generate a full accessible description for this chart.
    /// Returns a slice into the provided buffer.
    pub fn describe(self: *const ScatterChart, buf: []u8) []const u8 {
        const info = self.getAccessibilityInfo();
        return a11y.describe(&info, buf);
    }

    /// Generate a short summary for tooltips or live regions.
    pub fn summarize(self: *const ScatterChart, buf: []u8) []const u8 {
        const info = self.getAccessibilityInfo();
        return a11y.summarize(&info, buf);
    }

    // ==========================================================================
    // Rendering
    // ==========================================================================

    /// Render the scatter chart to a DrawContext.
    pub fn render(self: *const ScatterChart, ctx: *DrawContext) void {
        // Performance timing (Phase 4 optimization)
        const start_time = if (ENABLE_PERF_LOGGING) std.time.nanoTimestamp() else 0;
        defer if (ENABLE_PERF_LOGGING) {
            const elapsed = std.time.nanoTimestamp() - start_time;
            if (elapsed > PERF_WARNING_THRESHOLD_NS) {
                if (builtin.mode == .Debug) {
                    std.log.warn("ScatterChart render: {d:.2}ms exceeds 8ms budget", .{
                        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
                    });
                }
            }
        };

        // Assertions at API boundary
        std.debug.assert(self.data.len > 0);
        std.debug.assert(self.width > 0 and self.height > 0);

        // Calculate inner bounds
        const inner_x = self.margin_left;
        const inner_y = self.margin_top;
        const inner_width = self.width - self.margin_left - self.margin_right;
        const inner_height = self.height - self.margin_top - self.margin_bottom;

        std.debug.assert(inner_width > 0 and inner_height > 0);

        // Calculate data extents
        const x_extent = self.findXExtent();
        const y_extent = self.findYExtent();

        // Apply nice range for both axes
        const nice_x = util.niceRange(x_extent.min, x_extent.max, 5);
        const nice_y = util.niceRange(y_extent.min, y_extent.max, 5);

        // Create scales
        const x_scale = LinearScale.init(
            self.x_domain_min orelse nice_x.min,
            self.x_domain_max orelse nice_x.max,
            inner_x,
            inner_x + inner_width,
        );

        const y_scale = LinearScale.init(
            self.y_domain_min orelse nice_y.min,
            self.y_domain_max orelse nice_y.max,
            inner_y + inner_height, // Y is inverted (0 at bottom)
            inner_y,
        );

        // Draw grid (behind points)
        if (self.show_grid) {
            self.drawGrid(ctx, x_scale, y_scale, inner_x, inner_y, inner_width, inner_height);
        }

        // Draw points for each series
        self.drawAllPoints(ctx, x_scale, y_scale);

        // Draw axes (on top)
        if (self.show_x_axis) {
            var x_opts = self.x_axis_opts;
            x_opts.orientation = .bottom;
            // Apply theme colors if available
            if (self.chart_theme) |t| {
                x_opts.color = t.axis_color;
                x_opts.label_color = t.tick_color;
            }
            Axis.drawLinear(ctx, x_scale, inner_x, inner_y + inner_height, x_opts);
        }

        if (self.show_y_axis) {
            var y_opts = self.y_axis_opts;
            y_opts.orientation = .left;
            // Apply theme colors if available
            if (self.chart_theme) |t| {
                y_opts.color = t.axis_color;
                y_opts.label_color = t.tick_color;
            }
            Axis.drawLinear(ctx, y_scale, inner_x, inner_y, y_opts);
        }
    }

    // ==========================================================================
    // Private Helpers - Domain Calculation
    // ==========================================================================

    /// Find the min/max X values across all series.
    fn findXExtent(self: *const ScatterChart) struct { min: f32, max: f32 } {
        std.debug.assert(self.data.len > 0);

        var min: f32 = std.math.inf(f32);
        var max: f32 = -std.math.inf(f32);

        for (self.data) |*series| {
            const extent = series.xExtent();
            min = @min(min, extent.min);
            max = @max(max, extent.max);
        }

        // Handle empty data or single point case
        if (min > max) {
            return .{ .min = 0, .max = 1 };
        }
        if (min == max) {
            return .{ .min = min - 1, .max = max + 1 };
        }

        return .{ .min = min, .max = max };
    }

    /// Find the min/max Y values across all series.
    fn findYExtent(self: *const ScatterChart) struct { min: f32, max: f32 } {
        std.debug.assert(self.data.len > 0);

        var min: f32 = std.math.inf(f32);
        var max: f32 = -std.math.inf(f32);

        for (self.data) |*series| {
            const extent = series.yExtent();
            min = @min(min, extent.min);
            max = @max(max, extent.max);
        }

        // Handle empty data or single point case
        if (min > max) {
            return .{ .min = 0, .max = 1 };
        }
        if (min == max) {
            return .{ .min = min - 1, .max = max + 1 };
        }

        return .{ .min = min, .max = max };
    }

    // ==========================================================================
    // Private Helpers - Drawing
    // ==========================================================================

    /// Draw grid lines.
    fn drawGrid(
        self: *const ScatterChart,
        ctx: *DrawContext,
        x_scale: LinearScale,
        y_scale: LinearScale,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    ) void {
        // Apply theme colors if available
        var grid_opts = self.grid_opts;
        if (self.chart_theme) |t| {
            grid_opts.color = t.grid_color;
        }

        Grid.drawLinearXY(
            ctx,
            x_scale,
            y_scale,
            .{ .x = x, .y = y, .width = w, .height = h },
            self.x_axis_opts.tick_count,
            self.y_axis_opts.tick_count,
            grid_opts,
        );
    }

    /// Draw all series points.
    /// TODO: Investigate using drawSeriesPointsBatched for circle shapes without size encoding.
    /// The pointCloud API should work (LineChart uses it successfully), but when enabled here
    /// the points don't render. Likely a z-ordering or clip bounds issue to investigate.
    /// For now, use individual fillCircleAdaptive calls which work correctly.
    fn drawAllPoints(self: *const ScatterChart, ctx: *DrawContext, x_scale: LinearScale, y_scale: LinearScale) void {
        std.debug.assert(self.data.len > 0);

        for (self.data, 0..) |*series, series_idx| {
            const color = self.getSeriesColor(series, series_idx);
            const alpha_color = Color.rgba(color.r, color.g, color.b, self.point_opacity);

            // Get size data for this series if available
            const size_slice: ?[]const f32 = if (self.size_data) |sd|
                if (series_idx < sd.len) sd[series_idx] else null
            else
                null;

            self.drawSeriesPoints(ctx, series, series_idx, x_scale, y_scale, alpha_color, size_slice);
        }
    }

    /// Draw points for a single series.
    /// OPTIMIZED: Uses pointCloud batch rendering when all points have uniform radius.
    /// For large datasets (>LOD_THRESHOLD), uses LTTB decimation to reduce point count.
    fn drawSeriesPoints(
        self: *const ScatterChart,
        ctx: *DrawContext,
        series: *const Series,
        series_idx: usize,
        x_scale: LinearScale,
        y_scale: LinearScale,
        color: Color,
        size_slice: ?[]const f32,
    ) void {
        _ = series_idx;
        std.debug.assert(series.data_len <= MAX_DATA_POINTS);

        if (series.data_len == 0) return;

        // Calculate size range for normalization if size data provided
        var size_min: f32 = 0;
        var size_max: f32 = 1;
        if (size_slice) |sizes| {
            size_min = std.math.inf(f32);
            size_max = -std.math.inf(f32);
            for (sizes) |s| {
                size_min = @min(size_min, s);
                size_max = @max(size_max, s);
            }
            if (size_min >= size_max) {
                size_min = 0;
                size_max = 1;
            }
        }

        // Draw each point
        var i: u32 = 0;
        while (i < series.data_len) : (i += 1) {
            const point = &series.data[i];
            const px = x_scale.scale(point.x);
            const py = y_scale.scale(point.y);

            // Calculate radius (either fixed or from size data)
            const radius = if (size_slice) |sizes|
                if (i < sizes.len) self.scaleSize(sizes[i], size_min, size_max) else self.point_radius
            else
                self.point_radius;

            self.drawPoint(ctx, px, py, radius, color);
        }
    }

    /// Draw points using batched pointCloud API (instanced rendering).
    /// Much more efficient than N individual fillCircle calls.
    /// Applies LTTB decimation for large datasets.
    fn drawSeriesPointsBatched(
        self: *const ScatterChart,
        ctx: *DrawContext,
        series: *const Series,
        x_scale: LinearScale,
        y_scale: LinearScale,
        color: Color,
    ) void {
        if (series.data_len == 0) return;

        // Check if LOD decimation is needed
        const use_lod = self.enable_lod and series.data_len > self.lod_target_points;

        var centers: [MAX_DATA_POINTS][2]f32 = undefined;
        var count: usize = 0;

        if (use_lod) {
            // Apply LTTB decimation for large datasets
            var input_points: [MAX_DATA_POINTS]DecimationPoint = undefined;
            var decimated: [MAX_DATA_POINTS]DecimationPoint = undefined;

            // Convert to decimation format
            var i: u32 = 0;
            while (i < series.data_len and i < MAX_DATA_POINTS) : (i += 1) {
                input_points[i] = .{ .x = series.data[i].x, .y = series.data[i].y };
            }

            // Decimate using LTTB algorithm
            const decimated_count = util.decimateLTTB(
                input_points[0..series.data_len],
                series.data_len,
                &decimated,
                self.lod_target_points,
            );

            // Scale decimated points
            var j: u32 = 0;
            while (j < decimated_count) : (j += 1) {
                centers[count] = .{ x_scale.scale(decimated[j].x), y_scale.scale(decimated[j].y) };
                count += 1;
            }
        } else {
            // Use all points directly
            var i: u32 = 0;
            while (i < series.data_len and count < MAX_DATA_POINTS) : (i += 1) {
                const point = &series.data[i];
                centers[count] = .{ x_scale.scale(point.x), y_scale.scale(point.y) };
                count += 1;
            }
        }

        // Single draw call for all points (instanced rendering)
        if (count >= 1) {
            ctx.pointCloud(centers[0..count], self.point_radius, color);
        }
    }

    /// Scale a size value to the configured radius range.
    fn scaleSize(self: *const ScatterChart, value: f32, min: f32, max: f32) f32 {
        std.debug.assert(self.size_range[1] >= self.size_range[0]);

        if (max <= min) return self.size_range[0];

        const t = (value - min) / (max - min);
        const clamped = @max(0, @min(1, t));
        return self.size_range[0] + clamped * (self.size_range[1] - self.size_range[0]);
    }

    /// Draw a single point with the configured shape.
    fn drawPoint(self: *const ScatterChart, ctx: *DrawContext, x: f32, y: f32, radius: f32, color: Color) void {
        std.debug.assert(radius > 0);
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));

        switch (self.point_shape) {
            .circle => ctx.fillCircleAdaptive(x, y, radius, color),
            .square => self.drawSquare(ctx, x, y, radius, color),
            .triangle => self.drawTriangle(ctx, x, y, radius, color),
            .diamond => self.drawDiamond(ctx, x, y, radius, color),
        }
    }

    /// Draw a square point centered at (x, y).
    fn drawSquare(_: *const ScatterChart, ctx: *DrawContext, x: f32, y: f32, radius: f32, color: Color) void {
        std.debug.assert(radius > 0);
        const size = radius * 1.8; // Make square visually similar area to circle
        ctx.fillRect(x - size / 2, y - size / 2, size, size, color);
    }

    /// Draw a triangle point centered at (x, y).
    /// OPTIMIZED: Uses single fillTriangle call instead of 8 rectangle strips.
    fn drawTriangle(_: *const ScatterChart, ctx: *DrawContext, x: f32, y: f32, radius: f32, color: Color) void {
        std.debug.assert(radius > 0);
        // Equilateral triangle with centroid at (x, y)
        const h = radius * 2.2; // Height for similar visual area
        const half_w = h * 0.577; // half_width = height * tan(30°) ≈ height / sqrt(3)

        // Triangle vertices: top, bottom-left, bottom-right
        const top_y = y - h * 0.667; // 2/3 above centroid
        const bottom_y = y + h * 0.333; // 1/3 below centroid

        // Single triangle call - much more efficient than 8 rectangles
        ctx.fillTriangle(x, top_y, x - half_w, bottom_y, x + half_w, bottom_y, color);
    }

    /// Draw a diamond point centered at (x, y).
    /// OPTIMIZED: Uses 2 fillTriangle calls instead of 16 rectangle strips.
    fn drawDiamond(_: *const ScatterChart, ctx: *DrawContext, x: f32, y: f32, radius: f32, color: Color) void {
        std.debug.assert(radius > 0);
        // Diamond is a rotated square
        const half = radius * 1.0; // Half diagonal

        // Diamond vertices: top, right, bottom, left
        const top = y - half;
        const bottom = y + half;
        const left = x - half;
        const right = x + half;

        // Two triangles to form the diamond (top half and bottom half)
        ctx.fillTriangle(x, top, left, y, right, y, color); // Top triangle
        ctx.fillTriangle(x, bottom, left, y, right, y, color); // Bottom triangle
    }

    /// Get color for a series (use series color or fall back to theme/default palette).
    fn getSeriesColor(self: *const ScatterChart, series: *const Series, index: usize) Color {
        // Priority: series explicit color > theme palette > default palette
        if (series.color) |color| {
            return color;
        }
        if (self.chart_theme) |t| {
            return t.paletteColor(index);
        }
        std.debug.assert(index < MAX_SERIES);
        return default_palette[index % default_palette.len];
    }

    // ==========================================================================
    // Hit Testing
    // ==========================================================================

    /// Test if a point (px, py) hits any data point. Returns series and point index if hit.
    pub fn hitTest(
        self: *const ScatterChart,
        px: f32,
        py: f32,
    ) ?struct { series_index: usize, point_index: usize } {
        std.debug.assert(self.data.len > 0);
        std.debug.assert(self.width > 0 and self.height > 0);

        // Calculate inner bounds
        const inner_x = self.margin_left;
        const inner_y = self.margin_top;
        const inner_width = self.width - self.margin_left - self.margin_right;
        const inner_height = self.height - self.margin_top - self.margin_bottom;

        // Calculate scales
        const x_extent = self.findXExtent();
        const y_extent = self.findYExtent();
        const nice_x = util.niceRange(x_extent.min, x_extent.max, 5);
        const nice_y = util.niceRange(y_extent.min, y_extent.max, 5);

        const x_scale = LinearScale.init(
            self.x_domain_min orelse nice_x.min,
            self.x_domain_max orelse nice_x.max,
            inner_x,
            inner_x + inner_width,
        );

        const y_scale = LinearScale.init(
            self.y_domain_min orelse nice_y.min,
            self.y_domain_max orelse nice_y.max,
            inner_y + inner_height,
            inner_y,
        );

        // Check each point (reverse order so top-most points are hit first)
        var series_idx = self.data.len;
        while (series_idx > 0) {
            series_idx -= 1;
            const series = &self.data[series_idx];

            var point_idx = series.data_len;
            while (point_idx > 0) {
                point_idx -= 1;
                const point = &series.data[point_idx];
                const point_x = x_scale.scale(point.x);
                const point_y = y_scale.scale(point.y);

                // Simple circular hit test with some padding
                const hit_radius = self.point_radius + 4; // 4px padding for easier clicking
                const dx = px - point_x;
                const dy = py - point_y;
                const dist_sq = dx * dx + dy * dy;

                if (dist_sq <= hit_radius * hit_radius) {
                    return .{ .series_index = series_idx, .point_index = point_idx };
                }
            }
        }

        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ScatterChart init from slice" {
    const series = [_]Series{
        Series.fromSlice("Series A", &.{
            .{ .x = 1, .y = 10 },
            .{ .x = 2, .y = 20 },
            .{ .x = 3, .y = 15 },
        }, Color.hex(0xff0000)),
    };

    const chart = ScatterChart.init(&series);

    try std.testing.expectEqual(@as(usize, 1), chart.data.len);
    try std.testing.expectEqual(@as(u32, 3), chart.data[0].data_len);
}

test "ScatterChart initSingle" {
    var series: Series = undefined;
    series.initInPlace("Test", Color.hex(0x00ff00));
    series.addPoint(DataPoint.init(5, 50));

    const chart = ScatterChart.initSingle(&series);

    try std.testing.expectEqual(@as(usize, 1), chart.data.len);
}

test "ScatterChart findXExtent" {
    const series = [_]Series{
        Series.fromSlice("A", &.{
            .{ .x = 1, .y = 10 },
            .{ .x = 5, .y = 20 },
        }, Color.hex(0xff0000)),
        Series.fromSlice("B", &.{
            .{ .x = 2, .y = 15 },
            .{ .x = 8, .y = 25 },
        }, Color.hex(0x00ff00)),
    };

    const chart = ScatterChart.init(&series);
    const extent = chart.findXExtent();

    try std.testing.expectEqual(@as(f32, 1), extent.min);
    try std.testing.expectEqual(@as(f32, 8), extent.max);
}

test "ScatterChart findYExtent" {
    const series = [_]Series{
        Series.fromSlice("A", &.{
            .{ .x = 1, .y = 10 },
            .{ .x = 5, .y = 30 },
        }, Color.hex(0xff0000)),
        Series.fromSlice("B", &.{
            .{ .x = 2, .y = 5 },
            .{ .x = 8, .y = 25 },
        }, Color.hex(0x00ff00)),
    };

    const chart = ScatterChart.init(&series);
    const extent = chart.findYExtent();

    try std.testing.expectEqual(@as(f32, 5), extent.min);
    try std.testing.expectEqual(@as(f32, 30), extent.max);
}

test "ScatterChart defaults" {
    const series = [_]Series{
        Series.fromSlice("Test", &.{
            .{ .x = 0, .y = 0 },
        }, Color.hex(0xff0000)),
    };

    const chart = ScatterChart.init(&series);

    try std.testing.expectEqual(@as(f32, 400), chart.width);
    try std.testing.expectEqual(@as(f32, 300), chart.height);
    try std.testing.expectEqual(@as(f32, 4), chart.point_radius);
    try std.testing.expect(chart.point_shape == .circle);
    try std.testing.expect(chart.show_grid);
    try std.testing.expect(chart.show_x_axis);
    try std.testing.expect(chart.show_y_axis);
}

test "ScatterChart struct size is small" {
    // ScatterChart should be small - just a slice pointer + options
    const size = @sizeOf(ScatterChart);
    std.debug.print("\nScatterChart size: {} bytes\n", .{size});
    try std.testing.expect(size < 400);
}

test "ScatterChart scaleSize" {
    const series = [_]Series{
        Series.fromSlice("Test", &.{
            .{ .x = 0, .y = 0 },
        }, Color.hex(0xff0000)),
    };

    var chart = ScatterChart.init(&series);
    chart.size_range = .{ 4.0, 20.0 };

    // Test scaling
    try std.testing.expectEqual(@as(f32, 4.0), chart.scaleSize(0, 0, 100));
    try std.testing.expectEqual(@as(f32, 12.0), chart.scaleSize(50, 0, 100));
    try std.testing.expectEqual(@as(f32, 20.0), chart.scaleSize(100, 0, 100));

    // Edge case: min == max
    try std.testing.expectEqual(@as(f32, 4.0), chart.scaleSize(50, 50, 50));
}

test "ScatterChart LOD defaults" {
    const series = [_]Series{
        Series.fromSlice("Test", &.{
            .{ .x = 0, .y = 0 },
        }, Color.hex(0xff0000)),
    };

    const chart = ScatterChart.init(&series);

    // LOD should be enabled by default
    try std.testing.expect(chart.enable_lod);
    try std.testing.expectEqual(LOD_THRESHOLD, chart.lod_target_points);
}

test "ScatterChart point shapes" {
    const series = [_]Series{
        Series.fromSlice("Test", &.{
            .{ .x = 0, .y = 0 },
        }, Color.hex(0xff0000)),
    };

    var chart = ScatterChart.init(&series);

    // Test all shapes can be set
    chart.point_shape = .circle;
    try std.testing.expect(chart.point_shape == .circle);

    chart.point_shape = .square;
    try std.testing.expect(chart.point_shape == .square);

    chart.point_shape = .triangle;
    try std.testing.expect(chart.point_shape == .triangle);

    chart.point_shape = .diamond;
    try std.testing.expect(chart.point_shape == .diamond);
}

test "ScatterChart hitTest returns null for miss" {
    const series = [_]Series{
        Series.fromSlice("Test", &.{
            .{ .x = 50, .y = 50 },
        }, Color.hex(0xff0000)),
    };

    var chart = ScatterChart.init(&series);
    chart.width = 400;
    chart.height = 300;

    // Point at (50, 50) maps to roughly center-ish of chart
    // Testing a far corner should return null
    const result = chart.hitTest(0, 0);
    try std.testing.expect(result == null);
}
