//! Line Chart Component for Gooey Charts
//!
//! Renders continuous X/Y data as connected lines with optional point markers
//! and area fill. Supports multiple series with different colors.
//!
//! NOTE: LineChart stores a *slice* to externally-owned series data.
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
// NOTE: Path is ~70KB on the stack, so we avoid it and use strokeLine instead

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
// LineChart
// =============================================================================

pub const LineChart = struct {
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

    // Line styling
    line_width: f32 = constants.DEFAULT_LINE_WIDTH,

    // Point markers
    show_points: bool = true,
    point_radius: f32 = constants.DEFAULT_POINT_RADIUS,

    // Area fill
    show_area: bool = false,
    area_opacity: f32 = 0.3,

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

    /// Create a line chart from a slice of series.
    /// The slice must outlive the chart - data is NOT copied.
    pub fn init(data: []const Series) LineChart {
        std.debug.assert(data.len > 0);
        std.debug.assert(data.len <= MAX_SERIES);
        return .{ .data = data };
    }

    /// Create a line chart from a single series (as a 1-element slice).
    /// The series must outlive the chart - data is NOT copied.
    pub fn initSingle(series: *const Series) LineChart {
        const slice: []const Series = @as([*]const Series, @ptrCast(series))[0..1];
        return .{ .data = slice };
    }

    // ==========================================================================
    // Accessors
    // ==========================================================================

    pub fn seriesCount(self: *const LineChart) u32 {
        return @intCast(self.data.len);
    }

    // ==========================================================================
    // Accessibility
    // ==========================================================================

    /// Get accessibility information for this chart.
    /// Use with `charts.describeChart()` to generate screen reader descriptions.
    pub fn getAccessibilityInfo(self: *const LineChart) a11y.ChartInfo {
        var info = a11y.infoFromSeries(self.data, .line);
        info.title = self.accessible_title;
        info.description = self.accessible_description;
        return info;
    }

    /// Generate a full accessible description for this chart.
    /// Returns a slice into the provided buffer.
    pub fn describe(self: *const LineChart, buf: []u8) []const u8 {
        const info = self.getAccessibilityInfo();
        return a11y.describe(&info, buf);
    }

    /// Generate a short summary for tooltips or live regions.
    pub fn summarize(self: *const LineChart, buf: []u8) []const u8 {
        const info = self.getAccessibilityInfo();
        return a11y.summarize(&info, buf);
    }

    // ==========================================================================
    // Rendering
    // ==========================================================================

    /// Render the line chart to a DrawContext.
    pub fn render(self: *const LineChart, ctx: *DrawContext) void {
        // Performance timing (Phase 4 optimization)
        const start_time = if (ENABLE_PERF_LOGGING) std.time.nanoTimestamp() else 0;
        defer if (ENABLE_PERF_LOGGING) {
            const elapsed = std.time.nanoTimestamp() - start_time;
            if (elapsed > PERF_WARNING_THRESHOLD_NS) {
                if (builtin.mode == .Debug) {
                    std.log.warn("LineChart render: {d:.2}ms exceeds 8ms budget", .{
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

        // Apply nice range for Y axis
        const nice_y = util.niceRange(y_extent.min, y_extent.max, 5);

        // Create scales
        const x_scale = LinearScale.init(
            self.x_domain_min orelse x_extent.min,
            self.x_domain_max orelse x_extent.max,
            inner_x,
            inner_x + inner_width,
        );

        const y_scale = LinearScale.init(
            self.y_domain_min orelse nice_y.min,
            self.y_domain_max orelse nice_y.max,
            inner_y + inner_height, // Y is inverted (0 at bottom)
            inner_y,
        );

        // Draw grid (behind lines)
        if (self.show_grid) {
            self.drawGrid(ctx, x_scale, y_scale, inner_x, inner_y, inner_width, inner_height);
        }

        // Draw area fills first (behind lines)
        if (self.show_area) {
            self.drawAreas(ctx, x_scale, y_scale, inner_y + inner_height);
        }

        // Draw lines
        self.drawLines(ctx, x_scale, y_scale);

        // Draw point markers (on top of lines)
        if (self.show_points) {
            self.drawPoints(ctx, x_scale, y_scale);
        }

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
    fn findXExtent(self: *const LineChart) struct { min: f32, max: f32 } {
        var min: f32 = std.math.inf(f32);
        var max: f32 = -std.math.inf(f32);

        for (self.data) |*series| {
            const extent = series.xExtent();
            min = @min(min, extent.min);
            max = @max(max, extent.max);
        }

        // Handle empty data case
        if (min > max) {
            return .{ .min = 0, .max = 1 };
        }

        return .{ .min = min, .max = max };
    }

    /// Find the min/max Y values across all series.
    fn findYExtent(self: *const LineChart) struct { min: f32, max: f32 } {
        var min: f32 = std.math.inf(f32);
        var max: f32 = -std.math.inf(f32);

        for (self.data) |*series| {
            const extent = series.yExtent();
            min = @min(min, extent.min);
            max = @max(max, extent.max);
        }

        // Handle empty data case
        if (min > max) {
            return .{ .min = 0, .max = 1 };
        }

        // For line charts, often want to include 0 in Y range
        if (min > 0 and self.show_area) {
            min = 0;
        }

        return .{ .min = min, .max = max };
    }

    // ==========================================================================
    // Private Helpers - Drawing
    // ==========================================================================

    /// Draw grid lines.
    fn drawGrid(
        self: *const LineChart,
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

    /// Draw filled areas under lines.
    fn drawAreas(
        self: *const LineChart,
        ctx: *DrawContext,
        x_scale: LinearScale,
        y_scale: LinearScale,
        baseline: f32,
    ) void {
        for (self.data, 0..) |*series, series_idx| {
            if (series.data_len < 2) continue;

            const color = self.getSeriesColor(series, series_idx);
            // Debug: use full opacity to test if triangles render
            const area_color = Color.rgba(color.r, color.g, color.b, 0.3);

            self.drawSeriesArea(ctx, series, x_scale, y_scale, baseline, area_color);
        }
    }

    /// Draw area for a single series using multiple rectangles for smoother fills.
    /// Subdivides each segment into smaller strips with interpolated heights.
    fn drawSeriesArea(
        self: *const LineChart,
        ctx: *DrawContext,
        series: *const Series,
        x_scale: LinearScale,
        y_scale: LinearScale,
        baseline: f32,
        color: Color,
    ) void {
        _ = self;

        if (series.data_len < 2) return;

        const SUBDIVISIONS: u32 = 4; // 4 rectangles per segment for smoother appearance

        var i: u32 = 0;
        while (i < series.data_len - 1) : (i += 1) {
            const p1 = &series.data[i];
            const p2 = &series.data[i + 1];

            const x1 = x_scale.scale(p1.x);
            const y1 = y_scale.scale(p1.y);
            const x2 = x_scale.scale(p2.x);
            const y2 = y_scale.scale(p2.y);

            const segment_width = x2 - x1;
            if (segment_width <= 0) continue;

            const sub_width = segment_width / @as(f32, @floatFromInt(SUBDIVISIONS));

            // Draw multiple rectangles with interpolated heights
            var j: u32 = 0;
            while (j < SUBDIVISIONS) : (j += 1) {
                const t = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(SUBDIVISIONS));
                const sub_x = x1 + t * segment_width;
                const sub_y = y1 + t * (y2 - y1);
                const h = baseline - sub_y;

                if (h > 0) {
                    ctx.fillRect(sub_x, sub_y, sub_width, h, color);
                }
            }
        }
    }

    /// Draw all series lines.
    fn drawLines(self: *const LineChart, ctx: *DrawContext, x_scale: LinearScale, y_scale: LinearScale) void {
        for (self.data, 0..) |*series, series_idx| {
            if (series.data_len < 2) continue;

            const color = self.getSeriesColor(series, series_idx);
            self.drawSeriesLine(ctx, series, x_scale, y_scale, color);
        }
    }

    /// Draw line for a single series using polyline API (single draw call).
    /// This is much more efficient than N strokeLine calls:
    /// - Before: N draw calls, N tessellations, N GPU uploads
    /// - After: 1 draw call, 0 tessellations, 1 GPU upload
    ///
    /// For large datasets (>LOD_THRESHOLD), uses LTTB decimation to reduce
    /// point count while preserving visual shape.
    fn drawSeriesLine(
        self: *const LineChart,
        ctx: *DrawContext,
        series: *const Series,
        x_scale: LinearScale,
        y_scale: LinearScale,
        color: Color,
    ) void {
        if (series.data_len < 2) return;

        // Check if LOD decimation is needed
        const use_lod = self.enable_lod and series.data_len > self.lod_target_points;

        // Build points array (stack allocation is fine - just f32 pairs, ~32KB max)
        var points: [MAX_DATA_POINTS][2]f32 = undefined;
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
                points[count] = .{ x_scale.scale(decimated[j].x), y_scale.scale(decimated[j].y) };
                count += 1;
            }
        } else {
            // Use all points directly
            var i: u32 = 0;
            while (i < series.data_len and count < MAX_DATA_POINTS) : (i += 1) {
                const point = &series.data[i];
                points[count] = .{ x_scale.scale(point.x), y_scale.scale(point.y) };
                count += 1;
            }
        }

        // Single draw call for entire line
        if (count >= 2) {
            ctx.polyline(points[0..count], self.line_width, color);
        }
    }

    /// Draw point markers for all series.
    fn drawPoints(self: *const LineChart, ctx: *DrawContext, x_scale: LinearScale, y_scale: LinearScale) void {
        for (self.data, 0..) |*series, series_idx| {
            const color = self.getSeriesColor(series, series_idx);
            self.drawSeriesPoints(ctx, series, x_scale, y_scale, color);
        }
    }

    /// Draw point markers for a single series using pointCloud API (instanced rendering).
    /// This is much more efficient than N fillCircle calls:
    /// - Before: N draw calls, N path tessellations
    /// - After: 1 draw call, instanced GPU rendering
    ///
    /// For large datasets (>LOD_THRESHOLD), uses LTTB decimation to reduce
    /// point count while preserving visual shape.
    fn drawSeriesPoints(
        self: *const LineChart,
        ctx: *DrawContext,
        series: *const Series,
        x_scale: LinearScale,
        y_scale: LinearScale,
        color: Color,
    ) void {
        if (series.data_len == 0) return;

        // Check if LOD decimation is needed
        const use_lod = self.enable_lod and series.data_len > self.lod_target_points;

        // Build centers array (stack allocation is fine - just f32 pairs, ~32KB max)
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

    /// Get color for a series (use series color or fall back to theme/default palette).
    fn getSeriesColor(self: *const LineChart, series: *const Series, index: usize) Color {
        // Priority: series explicit color > theme palette > default palette
        if (series.color) |color| {
            return color;
        }
        if (self.chart_theme) |t| {
            return t.paletteColor(index);
        }
        return default_palette[index % default_palette.len];
    }
};

// =============================================================================
// Tests
// =============================================================================

test "LineChart init from slice" {
    var series_array = [_]Series{
        Series.fromSlice("Test", &.{
            .{ .x = 0, .y = 10 },
            .{ .x = 1, .y = 20 },
            .{ .x = 2, .y = 15 },
        }, Color.hex(0xff0000)),
    };

    const chart = LineChart.init(&series_array);
    try std.testing.expectEqual(@as(u32, 1), chart.seriesCount());
    try std.testing.expectEqual(@as(f32, 400), chart.width);
    try std.testing.expectEqual(@as(f32, 300), chart.height);
}

test "LineChart initSingle" {
    const series = Series.fromSlice("Revenue", &.{
        .{ .x = 0, .y = 100 },
        .{ .x = 1, .y = 150 },
        .{ .x = 2, .y = 125 },
    }, Color.hex(0x0000ff));

    const chart = LineChart.initSingle(&series);
    try std.testing.expectEqual(@as(u32, 1), chart.seriesCount());
}

test "LineChart findXExtent" {
    var series_array = [_]Series{
        Series.fromSlice("A", &.{
            .{ .x = 5, .y = 10 },
            .{ .x = 15, .y = 20 },
        }, Color.hex(0xff0000)),
        Series.fromSlice("B", &.{
            .{ .x = 0, .y = 30 },
            .{ .x = 10, .y = 40 },
        }, Color.hex(0x00ff00)),
    };

    const chart = LineChart.init(&series_array);
    const extent = chart.findXExtent();
    try std.testing.expectEqual(@as(f32, 0), extent.min);
    try std.testing.expectEqual(@as(f32, 15), extent.max);
}

test "LineChart findYExtent" {
    var series_array = [_]Series{
        Series.fromSlice("A", &.{
            .{ .x = 0, .y = 10 },
            .{ .x = 1, .y = 50 },
        }, Color.hex(0xff0000)),
        Series.fromSlice("B", &.{
            .{ .x = 0, .y = 25 },
            .{ .x = 1, .y = 75 },
        }, Color.hex(0x00ff00)),
    };

    const chart = LineChart.init(&series_array);
    const extent = chart.findYExtent();
    try std.testing.expectEqual(@as(f32, 10), extent.min);
    try std.testing.expectEqual(@as(f32, 75), extent.max);
}

test "LineChart defaults" {
    var series_array = [_]Series{Series.init("Test", Color.hex(0x000000))};
    series_array[0].addPoint(DataPoint.init(0, 10));
    series_array[0].addPoint(DataPoint.init(1, 20));

    const chart = LineChart.init(&series_array);
    try std.testing.expect(chart.show_x_axis);
    try std.testing.expect(chart.show_y_axis);
    try std.testing.expect(chart.show_grid);
    try std.testing.expect(chart.show_points);
    try std.testing.expect(!chart.show_area);
    try std.testing.expectEqual(@as(f32, 2.0), chart.line_width);
    try std.testing.expectEqual(@as(f32, 4.0), chart.point_radius);
}

test "LineChart struct size is small" {
    // Ensure LineChart itself is small (just a slice + options + theme ptr)
    // Should be < 400 bytes (increased due to LOD fields), not ~300KB
    const size = @sizeOf(LineChart);
    try std.testing.expect(size < 400);
}

test "LineChart LOD defaults" {
    var series_array = [_]Series{Series.init("Test", Color.hex(0xff0000))};
    const chart = LineChart.init(&series_array);

    // LOD should be enabled by default
    try std.testing.expect(chart.enable_lod);
    try std.testing.expectEqual(LOD_THRESHOLD, chart.lod_target_points);
}
