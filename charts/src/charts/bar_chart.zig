//! Bar Chart Component for Gooey Charts
//!
//! Renders categorical data as vertical or horizontal bars.
//! Supports single and multi-series data, with customizable styling.
//!
//! NOTE: BarChart stores a *slice* to externally-owned series data.
//! The caller is responsible for ensuring the data outlives the chart.
//! This avoids embedding ~300KB of data on the stack (per CLAUDE.md).

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
const BandScale = scale_mod.BandScale;
const Axis = axis_mod.Axis;
const Grid = grid_mod.Grid;

const CategorySeries = types.CategorySeries;
const CategoryPoint = types.CategoryPoint;
const ChartTheme = theme_mod.ChartTheme;

pub const Color = gooey.ui.Color;
pub const DrawContext = gooey.ui.DrawContext;

const MAX_SERIES = constants.MAX_SERIES;
const MAX_CATEGORIES = constants.MAX_CATEGORIES;
const ENABLE_PERF_LOGGING = constants.ENABLE_PERF_LOGGING;
const PERF_WARNING_THRESHOLD_NS = constants.PERF_WARNING_THRESHOLD_NS;

// =============================================================================
// Default Color Palette (imported from theme.zig - single source of truth)
// =============================================================================

pub const default_palette = theme_mod.google_palette;

// =============================================================================
// BarChart
// =============================================================================

pub const BarChart = struct {
    // Data - stored as a slice to avoid ~300KB stack allocation
    // The caller owns the underlying data; chart just references it
    data: []const CategorySeries,

    // Dimensions
    width: f32 = constants.DEFAULT_WIDTH,
    height: f32 = constants.DEFAULT_HEIGHT,

    // Margins
    margin_top: f32 = constants.DEFAULT_MARGIN_TOP,
    margin_right: f32 = constants.DEFAULT_MARGIN_RIGHT,
    margin_bottom: f32 = constants.DEFAULT_MARGIN_BOTTOM,
    margin_left: f32 = constants.DEFAULT_MARGIN_LEFT,

    // Bar styling
    bar_padding: f32 = constants.DEFAULT_BAR_PADDING,
    group_padding: f32 = constants.DEFAULT_GROUP_PADDING,
    corner_radius: f32 = 0,

    // Orientation
    horizontal: bool = false,

    // Axes
    show_x_axis: bool = true,
    show_y_axis: bool = true,
    x_axis_opts: Axis.Options = .{ .orientation = .bottom },
    y_axis_opts: Axis.Options = .{ .orientation = .left },

    // Grid
    show_grid: bool = true,
    grid_opts: Grid.Options = .{ .show_horizontal = true, .show_vertical = false },

    // Theme (optional - uses default colors if null)
    chart_theme: ?*const ChartTheme = null,

    // Accessibility
    accessible_title: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    // ==========================================================================
    // Initialization
    // ==========================================================================

    /// Create a bar chart from a slice of series.
    /// The slice must outlive the chart - data is NOT copied.
    pub fn init(data: []const CategorySeries) BarChart {
        std.debug.assert(data.len > 0);
        std.debug.assert(data.len <= MAX_SERIES);
        return .{ .data = data };
    }

    /// Create a bar chart from a single series (as a 1-element slice).
    /// The series must outlive the chart - data is NOT copied.
    pub fn initSingle(series: *const CategorySeries) BarChart {
        // Create a slice from a single pointer
        const slice: []const CategorySeries = @as([*]const CategorySeries, @ptrCast(series))[0..1];
        return .{ .data = slice };
    }

    // ==========================================================================
    // Accessors
    // ==========================================================================

    pub fn seriesCount(self: *const BarChart) u32 {
        return @intCast(self.data.len);
    }

    // ==========================================================================
    // Accessibility
    // ==========================================================================

    /// Get accessibility information for this chart.
    /// Use with `charts.describeChart()` to generate screen reader descriptions.
    pub fn getAccessibilityInfo(self: *const BarChart) a11y.ChartInfo {
        var info = a11y.infoFromCategorySeries(self.data, .bar);
        info.title = self.accessible_title;
        info.description = self.accessible_description;
        return info;
    }

    /// Generate a full accessible description for this chart.
    /// Returns a slice into the provided buffer.
    pub fn describe(self: *const BarChart, buf: []u8) []const u8 {
        const info = self.getAccessibilityInfo();
        return a11y.describe(&info, buf);
    }

    /// Generate a short summary for tooltips or live regions.
    pub fn summarize(self: *const BarChart, buf: []u8) []const u8 {
        const info = self.getAccessibilityInfo();
        return a11y.summarize(&info, buf);
    }

    // ==========================================================================
    // Rendering
    // ==========================================================================

    /// Render the bar chart to a DrawContext.
    pub fn render(self: *const BarChart, ctx: *DrawContext) void {
        // Performance timing (Phase 4 optimization)
        const start_time = if (ENABLE_PERF_LOGGING) std.time.nanoTimestamp() else 0;
        defer if (ENABLE_PERF_LOGGING) {
            const elapsed = std.time.nanoTimestamp() - start_time;
            if (elapsed > PERF_WARNING_THRESHOLD_NS) {
                if (builtin.mode == .Debug) {
                    std.log.warn("BarChart render: {d:.2}ms exceeds 8ms budget", .{
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

        // Build category labels from first series
        var labels: [MAX_CATEGORIES][]const u8 = undefined;
        const label_count = self.data[0].data_len;

        for (0..label_count) |i| {
            labels[i] = self.data[0].data[i].getLabel();
        }

        // Find Y-axis domain (0 to max value)
        const y_max = self.findMaxValue();
        const nice_range = util.niceRange(0, y_max, 5);

        // Create scales
        const x_scale = BandScale.initWithPadding(
            labels[0..label_count],
            inner_x,
            inner_x + inner_width,
            self.bar_padding,
            self.group_padding,
        );

        const y_scale = LinearScale.init(
            nice_range.min,
            nice_range.max,
            inner_y + inner_height, // Y is inverted (0 at bottom)
            inner_y,
        );

        // Draw grid (behind bars)
        if (self.show_grid) {
            self.drawGrid(ctx, x_scale, y_scale, inner_x, inner_y, inner_width, inner_height);
        }

        // Draw bars
        self.drawBars(ctx, x_scale, y_scale, inner_y + inner_height);

        // Draw axes (on top)
        if (self.show_x_axis) {
            var x_opts = self.x_axis_opts;
            x_opts.orientation = .bottom;
            // Apply theme colors if available
            if (self.chart_theme) |t| {
                x_opts.color = t.axis_color;
                x_opts.label_color = t.tick_color;
            }
            Axis.drawBand(ctx, x_scale, inner_x, inner_y + inner_height, x_opts);
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
    // Private Helpers
    // ==========================================================================

    /// Find the maximum value across all series.
    fn findMaxValue(self: *const BarChart) f32 {
        var max: f32 = 0;

        for (self.data) |series| {
            const series_max = series.maxValue();
            max = @max(max, series_max);
        }

        // Ensure we have a non-zero max for proper scaling
        return if (max > 0) max else 1;
    }

    /// Draw grid lines.
    fn drawGrid(
        self: *const BarChart,
        ctx: *DrawContext,
        x_scale: BandScale,
        y_scale: LinearScale,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    ) void {
        _ = x_scale; // Band scale doesn't use x ticks for horizontal lines

        // Apply theme colors if available
        var grid_opts = self.grid_opts;
        if (self.chart_theme) |t| {
            grid_opts.color = t.grid_color;
        }

        Grid.drawMixed(
            ctx,
            BandScale.init(&[_][]const u8{""}, x, x + width), // Dummy band scale
            y_scale,
            .{ .x = x, .y = y, .width = width, .height = height },
            self.y_axis_opts.tick_count,
            grid_opts,
        );
    }

    /// Draw all bars.
    fn drawBars(
        self: *const BarChart,
        ctx: *DrawContext,
        x_scale: BandScale,
        y_scale: LinearScale,
        baseline: f32,
    ) void {
        const bandwidth = x_scale.bandwidth();
        const series_count: f32 = @floatFromInt(self.data.len);

        // Calculate bar width for grouped bars
        const bar_width = if (self.data.len > 1)
            bandwidth / series_count * (1 - self.bar_padding)
        else
            bandwidth;

        // Draw each category
        var cat_idx: u32 = 0;
        while (cat_idx < self.data[0].data_len) : (cat_idx += 1) {
            const cat_x = x_scale.position(cat_idx);

            // Draw each series within this category
            for (self.data, 0..) |*series, series_idx| {
                const point = &series.data[cat_idx];
                // Color priority: point color > series color > theme palette
                const color = point.color orelse series.color orelse
                    (if (self.chart_theme) |t| t.paletteColor(series_idx) else default_palette[series_idx % 12]);

                // Calculate bar position
                const bar_x = if (self.data.len > 1)
                    cat_x + @as(f32, @floatFromInt(series_idx)) * (bandwidth / series_count)
                else
                    cat_x;

                // Calculate bar height
                const y_pos = y_scale.scale(point.value);
                const bar_height = baseline - y_pos;

                // Draw the bar
                if (bar_height > 0) {
                    if (self.corner_radius > 0) {
                        ctx.fillRoundedRect(
                            bar_x,
                            y_pos,
                            bar_width,
                            bar_height,
                            self.corner_radius,
                            color,
                        );
                    } else {
                        ctx.fillRect(bar_x, y_pos, bar_width, bar_height, color);
                    }
                }
            }
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "BarChart init from slice" {
    var series_array = [_]CategorySeries{
        CategorySeries.fromSlice("Test", &.{
            .{ .label = "A", .value = 10 },
            .{ .label = "B", .value = 20 },
        }, Color.hex(0xff0000)),
    };

    const chart = BarChart.init(&series_array);
    try std.testing.expectEqual(@as(u32, 1), chart.seriesCount());
    try std.testing.expectEqual(@as(f32, 400), chart.width);
    try std.testing.expectEqual(@as(f32, 300), chart.height);
}

test "BarChart initSingle" {
    const series = CategorySeries.fromSlice("Sales", &.{
        .{ .label = "Q1", .value = 100 },
        .{ .label = "Q2", .value = 150 },
    }, Color.hex(0x0000ff));

    const chart = BarChart.initSingle(&series);
    try std.testing.expectEqual(@as(u32, 1), chart.seriesCount());
}

test "BarChart findMaxValue" {
    var series_array = [_]CategorySeries{
        CategorySeries.fromSlice("A", &.{
            .{ .label = "X", .value = 50 },
        }, Color.hex(0xff0000)),
        CategorySeries.fromSlice("B", &.{
            .{ .label = "X", .value = 75 },
        }, Color.hex(0x00ff00)),
    };

    const chart = BarChart.init(&series_array);
    const max = chart.findMaxValue();
    try std.testing.expectEqual(@as(f32, 75), max);
}

test "BarChart defaults" {
    var series_array = [_]CategorySeries{CategorySeries.init("Test", Color.hex(0x000000))};
    series_array[0].addPoint(CategoryPoint.init("A", 10));

    const chart = BarChart.init(&series_array);
    try std.testing.expect(chart.show_x_axis);
    try std.testing.expect(chart.show_y_axis);
    try std.testing.expect(chart.show_grid);
    try std.testing.expect(!chart.horizontal);
}

test "BarChart struct size is small" {
    // Ensure BarChart itself is small (just a slice + options + theme ptr)
    // Should be < 350 bytes, not ~300KB
    const size = @sizeOf(BarChart);
    try std.testing.expect(size < 350);
}
