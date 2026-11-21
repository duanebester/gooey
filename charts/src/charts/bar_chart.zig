//! BarChart stores a slice to externally-owned series data; the caller must
//! keep the data alive while the chart renders. Capacities are the app's,
//! fixed at comptime:
//! `const Sales = BarChart(.{ .category_count_max = 8, .series_count_max = 1 });`
//! sizes `Sales.Series` for 8 categories. Each render keeps one
//! `[category_count_max][]const u8` label array and one `BandScale` (sized by
//! the framework's category ceiling) on the stack.

const std = @import("std");
const paint = @import("../paint.zig");
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

const CategoryPoint = types.CategoryPoint;
const ChartTheme = theme_mod.ChartTheme;

pub const Color = paint.Color;
pub const Painter = paint.Painter;

pub const default_palette = theme_mod.google_palette;

/// A bar chart drawing up to `capacity.series_count_max` series, each holding
/// up to `capacity.category_count_max` categories.
pub fn BarChart(comptime capacity: types.CategoryCapacity) type {
    capacity.check();
    return struct {
        data: []const Series,

        width: f32 = constants.DEFAULT_WIDTH,
        height: f32 = constants.DEFAULT_HEIGHT,

        margin_top: f32 = constants.DEFAULT_MARGIN_TOP,
        margin_right: f32 = constants.DEFAULT_MARGIN_RIGHT,
        margin_bottom: f32 = constants.DEFAULT_MARGIN_BOTTOM,
        margin_left: f32 = constants.DEFAULT_MARGIN_LEFT,

        bar_padding: f32 = constants.DEFAULT_BAR_PADDING,
        group_padding: f32 = constants.DEFAULT_GROUP_PADDING,
        corner_radius: f32 = 0,

        horizontal: bool = false,

        show_x_axis: bool = true,
        show_y_axis: bool = true,
        x_axis_opts: Axis.Options = .{ .orientation = .bottom },
        y_axis_opts: Axis.Options = .{ .orientation = .left },

        show_grid: bool = true,
        grid_opts: Grid.Options = .{ .show_horizontal = true, .show_vertical = false },

        chart_theme: ?*const ChartTheme = null,

        accessible_title: ?[]const u8 = null,
        accessible_description: ?[]const u8 = null,

        const Self = @This();

        pub const category_count_max: u32 = capacity.category_count_max;

        pub const series_count_max: u32 = capacity.series_count_max;

        pub const Series = types.CategorySeries(category_count_max);

        /// The slice must outlive the chart; the data is not copied.
        pub fn init(data: []const Series) Self {
            std.debug.assert(data.len > 0);
            std.debug.assert(data.len <= series_count_max);
            return .{ .data = data };
        }

        /// The series must outlive the chart; the data is not copied.
        pub fn initSingle(series: *const Series) Self {
            const slice: []const Series = @as([*]const Series, @ptrCast(series))[0..1];
            return .{ .data = slice };
        }

        pub fn seriesCount(self: *const Self) u32 {
            return @intCast(self.data.len);
        }

        pub fn getAccessibilityInfo(self: *const Self) a11y.ChartInfo {
            var info = a11y.infoFromCategorySeries(Series, self.data, .bar);
            info.title = self.accessible_title;
            info.description = self.accessible_description;
            return info;
        }

        /// Writes into `buf` and returns a slice of it.
        pub fn describe(self: *const Self, buf: []u8) []const u8 {
            const info = self.getAccessibilityInfo();
            return a11y.describe(&info, buf);
        }

        pub fn summarize(self: *const Self, buf: []u8) []const u8 {
            const info = self.getAccessibilityInfo();
            return a11y.summarize(&info, buf);
        }

        /// Render the bar chart, offset by the paint element's bounds.
        pub fn render(self: *const Self, painter: *Painter) void {
            std.debug.assert(self.data.len > 0);
            std.debug.assert(self.width > 0 and self.height > 0);

            const inner_x = painter.bounds.x + self.margin_left;
            const inner_y = painter.bounds.y + self.margin_top;
            const inner_width = self.width - self.margin_left - self.margin_right;
            const inner_height = self.height - self.margin_top - self.margin_bottom;

            std.debug.assert(inner_width > 0 and inner_height > 0);

            var labels: [category_count_max][]const u8 = undefined;
            const label_count = self.categoryLabels(&labels);

            const y_max = self.findMaxValue();
            const nice_range = util.niceRange(0, y_max, 5);

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

            if (self.show_grid) {
                self.drawGrid(
                    painter,
                    x_scale,
                    y_scale,
                    inner_x,
                    inner_y,
                    inner_width,
                    inner_height,
                );
            }

            self.drawBars(painter, x_scale, y_scale, inner_y + inner_height);

            if (self.show_x_axis) {
                const x_opts = Axis.themed(self.x_axis_opts, .bottom, self.chart_theme);
                Axis.drawBand(painter, x_scale, inner_x, inner_y + inner_height, x_opts);
            }

            if (self.show_y_axis) {
                const y_opts = Axis.themed(self.y_axis_opts, .left, self.chart_theme);
                Axis.drawLinear(painter, y_scale, inner_x, inner_y, y_opts);
            }
        }

        /// The category labels, from the first series, written to `out`; returns their count.
        fn categoryLabels(self: *const Self, out: *[category_count_max][]const u8) u32 {
            const first = &self.data[0];
            std.debug.assert(first.data_len > 0);
            std.debug.assert(first.data_len <= category_count_max);
            for (first.getData(), out[0..first.data_len]) |*point, *label| {
                label.* = point.getLabel();
            }
            return first.data_len;
        }

        fn findMaxValue(self: *const Self) f32 {
            var max: f32 = 0;

            for (self.data) |series| {
                const series_max = series.maxValue();
                max = @max(max, series_max);
            }

            // Non-zero max keeps scaling sane.
            return if (max > 0) max else 1;
        }

        fn drawGrid(
            self: *const Self,
            painter: *Painter,
            x_scale: BandScale,
            y_scale: LinearScale,
            x: f32,
            y: f32,
            width: f32,
            height: f32,
        ) void {
            _ = x_scale; // Band scale doesn't use x ticks for horizontal lines

            var grid_opts = self.grid_opts;
            if (self.chart_theme) |t| {
                grid_opts.color = t.grid_color;
            }

            Grid.drawMixed(
                painter,
                BandScale.init(&[_][]const u8{""}, x, x + width), // Dummy band scale
                y_scale,
                .{ .x = x, .y = y, .width = width, .height = height },
                self.y_axis_opts.tick_count,
                grid_opts,
            );
        }

        fn drawBars(
            self: *const Self,
            painter: *Painter,
            x_scale: BandScale,
            y_scale: LinearScale,
            baseline: f32,
        ) void {
            const bandwidth = x_scale.bandwidth();
            const series_count: f32 = @floatFromInt(self.data.len);

            const bar_width = if (self.data.len > 1)
                bandwidth / series_count * (1 - self.bar_padding)
            else
                bandwidth;

            var cat_idx: u32 = 0;
            while (cat_idx < self.data[0].data_len) : (cat_idx += 1) {
                const cat_x = x_scale.position(cat_idx);

                for (self.data, 0..) |*series, series_idx| {
                    const point = &series.data[cat_idx];
                    // Color priority: point color > series color > theme palette.
                    const color = point.color orelse series.color orelse
                        (if (self.chart_theme) |t|
                            t.paletteColor(series_idx)
                        else
                            default_palette[series_idx % 12]);

                    const bar_x = if (self.data.len > 1)
                        cat_x + @as(f32, @floatFromInt(series_idx)) * (bandwidth / series_count)
                    else
                        cat_x;

                    const y_pos = y_scale.scale(point.value);
                    const bar_height = baseline - y_pos;

                    if (bar_height > 0) {
                        paint.rect(painter, .{
                            .x = bar_x,
                            .y = y_pos,
                            .width = bar_width,
                            .height = bar_height,
                        }, self.corner_radius, color);
                    }
                }
            }
        }
    };
}

/// A chart with room for two series of 8 categories, enough for every test below.
const TestChart = BarChart(.{ .category_count_max = 8, .series_count_max = 2 });
const TestSeries = TestChart.Series;

test "BarChart init from slice" {
    var series_array = [_]TestSeries{
        TestSeries.fromSlice("Test", &.{
            .{ .label = "A", .value = 10 },
            .{ .label = "B", .value = 20 },
        }, Color.hex(0xff0000)),
    };

    const chart = TestChart.init(&series_array);
    try std.testing.expectEqual(@as(u32, 1), chart.seriesCount());
    try std.testing.expectEqual(@as(f32, 400), chart.width);
    try std.testing.expectEqual(@as(f32, 300), chart.height);
}

test "BarChart initSingle" {
    const series = TestSeries.fromSlice("Sales", &.{
        .{ .label = "Q1", .value = 100 },
        .{ .label = "Q2", .value = 150 },
    }, Color.hex(0x0000ff));

    const chart = TestChart.initSingle(&series);
    try std.testing.expectEqual(@as(u32, 1), chart.seriesCount());
}

test "BarChart findMaxValue" {
    var series_array = [_]TestSeries{
        TestSeries.fromSlice("A", &.{
            .{ .label = "X", .value = 50 },
        }, Color.hex(0xff0000)),
        TestSeries.fromSlice("B", &.{
            .{ .label = "X", .value = 75 },
        }, Color.hex(0x00ff00)),
    };

    const chart = TestChart.init(&series_array);
    const max = chart.findMaxValue();
    try std.testing.expectEqual(@as(f32, 75), max);
}

test "BarChart defaults" {
    var series_array = [_]TestSeries{TestSeries.init("Test", Color.hex(0x000000))};
    series_array[0].addPoint(CategoryPoint.init("A", 10));

    const chart = TestChart.init(&series_array);
    try std.testing.expect(chart.show_x_axis);
    try std.testing.expect(chart.show_y_axis);
    try std.testing.expect(chart.show_grid);
    try std.testing.expect(!chart.horizontal);
}

test "BarChart struct size is small" {
    const size = @sizeOf(TestChart);
    try std.testing.expect(size < 350);
}

test "BarChart fills exactly its capacity" {
    // Goal: a chart whose series are all full labels and summarizes every
    // category, with no loss at the boundary. Methodology: two series of
    // exactly category_count_max categories, labelled the way render labels
    // them, then built into the band scale render uses.
    const Full = BarChart(.{ .category_count_max = 4, .series_count_max = 2 });
    const names = [Full.category_count_max][]const u8{ "Q1", "Q2", "Q3", "Q4" };
    var series_array: [Full.series_count_max]Full.Series = undefined;
    for (&series_array, 0..) |*series, series_index| {
        series.initInPlace("Full", null);
        for (names, 0..) |name, category_index| {
            const value: f32 = @floatFromInt(10 * category_index + series_index);
            series.addPoint(CategoryPoint.init(name, value));
        }
        try std.testing.expectEqual(Full.category_count_max, series.data_len);
    }
    const chart = Full.init(&series_array);
    var labels: [Full.category_count_max][]const u8 = undefined;
    const label_count = chart.categoryLabels(&labels);
    try std.testing.expectEqual(Full.category_count_max, label_count);
    try std.testing.expectEqualStrings("Q4", labels[label_count - 1]);
    const band = BandScale.init(labels[0..label_count], 0, 400);
    try std.testing.expectEqual(Full.category_count_max, band.label_count);
    try std.testing.expectEqual(@as(f32, 31), chart.findMaxValue());
    const info = chart.getAccessibilityInfo();
    try std.testing.expectEqual(Full.category_count_max, info.point_count);
    try std.testing.expectEqual(Full.series_count_max, info.series_count);
}
