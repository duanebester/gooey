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
const Axis = axis_mod.Axis;
const Grid = grid_mod.Grid;

const DataPoint = types.DataPoint;
const ChartTheme = theme_mod.ChartTheme;

pub const Color = paint.Color;
pub const Painter = paint.Painter;

const LOD_THRESHOLD = constants.LOD_THRESHOLD;

pub const default_palette = theme_mod.google_palette;

pub fn LineChart(comptime capacity: types.PointCapacity) type {
    capacity.check();
    return struct {
        data: []const Series,

        width: f32 = constants.DEFAULT_WIDTH,
        height: f32 = constants.DEFAULT_HEIGHT,

        margin_top: f32 = constants.DEFAULT_MARGIN_TOP,
        margin_right: f32 = constants.DEFAULT_MARGIN_RIGHT,
        margin_bottom: f32 = constants.DEFAULT_MARGIN_BOTTOM,
        margin_left: f32 = constants.DEFAULT_MARGIN_LEFT,

        line_width: f32 = constants.DEFAULT_LINE_WIDTH,

        show_points: bool = true,
        point_radius: f32 = constants.DEFAULT_POINT_RADIUS,

        show_area: bool = false,
        area_opacity: f32 = 0.3,

        x_domain_min: ?f32 = null,
        x_domain_max: ?f32 = null,
        y_domain_min: ?f32 = null,
        y_domain_max: ?f32 = null,

        show_x_axis: bool = true,
        show_y_axis: bool = true,
        x_axis_opts: Axis.Options = .{ .orientation = .bottom },
        y_axis_opts: Axis.Options = .{ .orientation = .left },

        show_grid: bool = true,
        grid_opts: Grid.Options = .{ .show_horizontal = true, .show_vertical = true },

        chart_theme: ?*const ChartTheme = null,

        accessible_title: ?[]const u8 = null,
        accessible_description: ?[]const u8 = null,

        enable_lod: bool = true,
        lod_target_points: u32 = LOD_THRESHOLD,

        const Self = @This();

        pub const point_count_max: u32 = capacity.point_count_max;

        pub const series_count_max: u32 = capacity.series_count_max;

        pub const Series = types.Series(point_count_max);

        pub fn init(data: []const Series) Self {
            std.debug.assert(data.len > 0);
            std.debug.assert(data.len <= series_count_max);
            return .{ .data = data };
        }

        pub fn initSingle(series: *const Series) Self {
            const slice: []const Series = @as([*]const Series, @ptrCast(series))[0..1];
            return .{ .data = slice };
        }

        pub fn seriesCount(self: *const Self) u32 {
            return @intCast(self.data.len);
        }

        pub fn getAccessibilityInfo(self: *const Self) a11y.ChartInfo {
            var info = a11y.infoFromSeries(Series, self.data, .line);
            info.title = self.accessible_title;
            info.description = self.accessible_description;
            return info;
        }

        pub fn describe(self: *const Self, buf: []u8) []const u8 {
            const info = self.getAccessibilityInfo();
            return a11y.describe(&info, buf);
        }

        pub fn summarize(self: *const Self, buf: []u8) []const u8 {
            const info = self.getAccessibilityInfo();
            return a11y.summarize(&info, buf);
        }

        pub fn render(self: *const Self, painter: *Painter) void {
            std.debug.assert(self.data.len > 0);
            std.debug.assert(self.width > 0 and self.height > 0);

            const inner_x = painter.bounds.x + self.margin_left;
            const inner_y = painter.bounds.y + self.margin_top;
            const inner_width = self.width - self.margin_left - self.margin_right;
            const inner_height = self.height - self.margin_top - self.margin_bottom;

            std.debug.assert(inner_width > 0 and inner_height > 0);

            const x_extent = self.findXExtent();
            const y_extent = self.findYExtent();

            const nice_y = util.niceRange(y_extent.min, y_extent.max, 5);

            const x_scale = LinearScale.init(
                self.x_domain_min orelse x_extent.min,
                self.x_domain_max orelse x_extent.max,
                inner_x,
                inner_x + inner_width,
            );

            const y_scale = LinearScale.init(
                self.y_domain_min orelse nice_y.min,
                self.y_domain_max orelse nice_y.max,
                inner_y + inner_height,
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

            if (self.show_area) {
                self.drawAreas(painter, x_scale, y_scale, inner_y + inner_height);
            }

            self.drawLines(painter, x_scale, y_scale);

            if (self.show_points) {
                self.drawPoints(painter, x_scale, y_scale);
            }

            if (self.show_x_axis) {
                const x_opts = Axis.themed(self.x_axis_opts, .bottom, self.chart_theme);
                Axis.drawLinear(painter, x_scale, inner_x, inner_y + inner_height, x_opts);
            }

            if (self.show_y_axis) {
                const y_opts = Axis.themed(self.y_axis_opts, .left, self.chart_theme);
                Axis.drawLinear(painter, y_scale, inner_x, inner_y, y_opts);
            }
        }

        fn findXExtent(self: *const Self) struct { min: f32, max: f32 } {
            var min: f32 = std.math.inf(f32);
            var max: f32 = -std.math.inf(f32);

            for (self.data) |*series| {
                const extent = series.xExtent();
                min = @min(min, extent.min);
                max = @max(max, extent.max);
            }

            if (min > max) {
                return .{ .min = 0, .max = 1 };
            }

            return .{ .min = min, .max = max };
        }

        fn findYExtent(self: *const Self) struct { min: f32, max: f32 } {
            var min: f32 = std.math.inf(f32);
            var max: f32 = -std.math.inf(f32);

            for (self.data) |*series| {
                const extent = series.yExtent();
                min = @min(min, extent.min);
                max = @max(max, extent.max);
            }

            if (min > max) {
                return .{ .min = 0, .max = 1 };
            }

            if (min > 0 and self.show_area) {
                min = 0;
            }

            return .{ .min = min, .max = max };
        }

        fn drawGrid(
            self: *const Self,
            painter: *Painter,
            x_scale: LinearScale,
            y_scale: LinearScale,
            x: f32,
            y: f32,
            w: f32,
            h: f32,
        ) void {
            var grid_opts = self.grid_opts;
            if (self.chart_theme) |t| {
                grid_opts.color = t.grid_color;
            }

            Grid.drawLinearXY(
                painter,
                x_scale,
                y_scale,
                .{ .x = x, .y = y, .width = w, .height = h },
                self.x_axis_opts.tick_count,
                self.y_axis_opts.tick_count,
                grid_opts,
            );
        }

        fn drawAreas(
            self: *const Self,
            painter: *Painter,
            x_scale: LinearScale,
            y_scale: LinearScale,
            baseline: f32,
        ) void {
            for (self.data, 0..) |*series, series_idx| {
                if (series.data_len < 2) continue;

                const color = self.getSeriesColor(series, series_idx);
                const area_color = Color.rgba(color.r, color.g, color.b, 0.3);

                self.drawSeriesArea(painter, series, x_scale, y_scale, baseline, area_color);
            }
        }

        fn drawSeriesArea(
            self: *const Self,
            painter: *Painter,
            series: *const Series,
            x_scale: LinearScale,
            y_scale: LinearScale,
            baseline: f32,
            color: Color,
        ) void {
            std.debug.assert(series.data_len >= 2);
            std.debug.assert(!std.math.isNan(baseline));
            var points: [point_count_max][2]f32 = undefined;
            const count = self.project(series, x_scale, y_scale, &points);
            std.debug.assert(count <= point_count_max);
            var index: u32 = 1;
            while (index < count) : (index += 1) {
                var triangles: [area_segment_points_max][2]f32 = undefined;
                const used = areaSegment(&triangles, points[index - 1], points[index], baseline);
                if (used > 0) painter.triangles(triangles[0..used], color);
            }
        }

        fn drawLines(
            self: *const Self,
            painter: *Painter,
            x_scale: LinearScale,
            y_scale: LinearScale,
        ) void {
            for (self.data, 0..) |*series, series_idx| {
                if (series.data_len < 2) continue;

                const color = self.getSeriesColor(series, series_idx);
                self.drawSeriesLine(painter, series, x_scale, y_scale, color);
            }
        }

        fn drawSeriesLine(
            self: *const Self,
            painter: *Painter,
            series: *const Series,
            x_scale: LinearScale,
            y_scale: LinearScale,
            color: Color,
        ) void {
            std.debug.assert(series.data_len >= 2);
            var points: [point_count_max][2]f32 = undefined;
            const count = self.project(series, x_scale, y_scale, &points);
            if (count >= 2) painter.polyline(points[0..count], self.line_width, color);
        }

        fn drawPoints(
            self: *const Self,
            painter: *Painter,
            x_scale: LinearScale,
            y_scale: LinearScale,
        ) void {
            std.debug.assert(self.data.len > 0);
            std.debug.assert(self.point_radius > 0);
            var centers: [point_count_max][2]f32 = undefined;
            for (self.data, 0..) |*series, series_idx| {
                if (series.data_len == 0) continue;
                const count = self.project(series, x_scale, y_scale, &centers);
                const color = self.getSeriesColor(series, series_idx);
                painter.pointCloud(centers[0..count], self.point_radius, color);
            }
        }

        fn project(
            self: *const Self,
            series: *const Series,
            x_scale: LinearScale,
            y_scale: LinearScale,
            out: *[point_count_max][2]f32,
        ) u32 {
            const lod_points: ?u32 = if (self.enable_lod) self.lod_target_points else null;
            std.debug.assert(series.data_len <= point_count_max);
            const count = scale_mod.projectSeries(
                point_count_max,
                series,
                x_scale,
                y_scale,
                lod_points,
                out,
            );
            std.debug.assert(count <= series.data_len);
            return count;
        }

        fn getSeriesColor(self: *const Self, series: *const Series, index: usize) Color {
            if (series.color) |color| {
                return color;
            }
            if (self.chart_theme) |t| {
                return t.paletteColor(index);
            }
            return default_palette[index % default_palette.len];
        }
    };
}

const area_segment_points_max: u32 = 6;

fn areaSegment(
    out: *[area_segment_points_max][2]f32,
    from: [2]f32,
    to: [2]f32,
    baseline: f32,
) u32 {
    std.debug.assert(!std.math.isNan(from[1]));
    std.debug.assert(!std.math.isNan(to[1]));
    const height_from = baseline - from[1];
    const height_to = baseline - to[1];
    const base_from = [2]f32{ from[0], baseline };
    const base_to = [2]f32{ to[0], baseline };
    if (to[0] <= from[0]) return 0;
    if (height_from >= 0 and height_to >= 0) {
        var count: u32 = 0;
        if (height_to > 0) {
            out[0..3].* = .{ from, to, base_to };
            count += 3;
        }
        if (height_from > 0) {
            out[count..][0..3].* = .{ from, base_to, base_from };
            count += 3;
        }
        return count;
    }
    if (height_from <= 0 and height_to <= 0) return 0;
    const t = height_from / (height_from - height_to);
    std.debug.assert(t > 0);
    std.debug.assert(t < 1);
    const crossing = [2]f32{ from[0] + t * (to[0] - from[0]), baseline };
    out[0..3].* = if (height_from > 0)
        .{ from, crossing, base_from }
    else
        .{ crossing, to, base_to };
    return 3;
}

const TestChart = LineChart(.{ .point_count_max = 16, .series_count_max = 2 });
const TestSeries = TestChart.Series;

test "LineChart init from slice" {
    var series_array = [_]TestSeries{
        TestSeries.fromSlice("Test", &.{
            .{ .x = 0, .y = 10 },
            .{ .x = 1, .y = 20 },
            .{ .x = 2, .y = 15 },
        }, Color.hex(0xff0000)),
    };

    const chart = TestChart.init(&series_array);
    try std.testing.expectEqual(@as(u32, 1), chart.seriesCount());
    try std.testing.expectEqual(@as(f32, 400), chart.width);
    try std.testing.expectEqual(@as(f32, 300), chart.height);
}

test "LineChart initSingle" {
    const series = TestSeries.fromSlice("Revenue", &.{
        .{ .x = 0, .y = 100 },
        .{ .x = 1, .y = 150 },
        .{ .x = 2, .y = 125 },
    }, Color.hex(0x0000ff));

    const chart = TestChart.initSingle(&series);
    try std.testing.expectEqual(@as(u32, 1), chart.seriesCount());
}

test "LineChart findXExtent" {
    var series_array = [_]TestSeries{
        TestSeries.fromSlice("A", &.{
            .{ .x = 5, .y = 10 },
            .{ .x = 15, .y = 20 },
        }, Color.hex(0xff0000)),
        TestSeries.fromSlice("B", &.{
            .{ .x = 0, .y = 30 },
            .{ .x = 10, .y = 40 },
        }, Color.hex(0x00ff00)),
    };

    const chart = TestChart.init(&series_array);
    const extent = chart.findXExtent();
    try std.testing.expectEqual(@as(f32, 0), extent.min);
    try std.testing.expectEqual(@as(f32, 15), extent.max);
}

test "LineChart findYExtent" {
    var series_array = [_]TestSeries{
        TestSeries.fromSlice("A", &.{
            .{ .x = 0, .y = 10 },
            .{ .x = 1, .y = 50 },
        }, Color.hex(0xff0000)),
        TestSeries.fromSlice("B", &.{
            .{ .x = 0, .y = 25 },
            .{ .x = 1, .y = 75 },
        }, Color.hex(0x00ff00)),
    };

    const chart = TestChart.init(&series_array);
    const extent = chart.findYExtent();
    try std.testing.expectEqual(@as(f32, 10), extent.min);
    try std.testing.expectEqual(@as(f32, 75), extent.max);
}

test "LineChart defaults" {
    var series_array = [_]TestSeries{TestSeries.init("Test", Color.hex(0x000000))};
    series_array[0].addPoint(DataPoint.init(0, 10));
    series_array[0].addPoint(DataPoint.init(1, 20));

    const chart = TestChart.init(&series_array);
    try std.testing.expect(chart.show_x_axis);
    try std.testing.expect(chart.show_y_axis);
    try std.testing.expect(chart.show_grid);
    try std.testing.expect(chart.show_points);
    try std.testing.expect(!chart.show_area);
    try std.testing.expectEqual(@as(f32, 2.0), chart.line_width);
    try std.testing.expectEqual(@as(f32, 4.0), chart.point_radius);
}

test "LineChart struct size is small" {
    const size = @sizeOf(TestChart);
    try std.testing.expect(size < 400);
}

test "LineChart LOD defaults" {
    var series_array = [_]TestSeries{TestSeries.init("Test", Color.hex(0xff0000))};
    const chart = TestChart.init(&series_array);

    try std.testing.expect(chart.enable_lod);
    try std.testing.expectEqual(LOD_THRESHOLD, chart.lod_target_points);
}

test "LineChart fills exactly its capacity" {
    const Full = LineChart(.{ .point_count_max = 8, .series_count_max = 2 });
    var series_array: [Full.series_count_max]Full.Series = undefined;
    for (&series_array, 0..) |*series, series_index| {
        series.initInPlace("Full", null);
        for (0..Full.point_count_max) |point_index| {
            const x: f32 = @floatFromInt(point_index);
            series.addPoint(DataPoint.init(x, @floatFromInt(series_index)));
        }
        try std.testing.expectEqual(Full.point_count_max, series.data_len);
    }
    var chart = Full.init(&series_array);
    const x_scale = LinearScale.init(0, 7, 0, 70);
    const y_scale = LinearScale.init(0, 1, 100, 0);
    var points: [Full.point_count_max][2]f32 = undefined;
    for (&series_array) |*series| {
        const count = chart.project(series, x_scale, y_scale, &points);
        try std.testing.expectEqual(Full.point_count_max, count);
        try std.testing.expectEqual(@as(f32, 70), points[Full.point_count_max - 1][0]);
    }
    chart.enable_lod = false;
    const count = chart.project(&series_array[1], x_scale, y_scale, &points);
    try std.testing.expectEqual(Full.point_count_max, count);
    const info = chart.getAccessibilityInfo();
    try std.testing.expectEqual(Full.point_count_max * Full.series_count_max, info.point_count);
    try std.testing.expectEqual(Full.series_count_max, info.series_count);
}

test "LineChart decimates a full series to its LOD target" {
    const Full = LineChart(.{ .point_count_max = 8, .series_count_max = 1 });
    var series = Full.Series.init("Full", null);
    for (0..Full.point_count_max) |point_index| {
        series.addPoint(DataPoint.init(@floatFromInt(point_index), @floatFromInt(point_index % 3)));
    }
    var chart = Full.initSingle(&series);
    chart.lod_target_points = 4;
    var points: [Full.point_count_max][2]f32 = undefined;
    const x_scale = LinearScale.init(0, 7, 0, 70);
    const y_scale = LinearScale.init(0, 2, 100, 0);
    try std.testing.expectEqual(@as(u32, 4), chart.project(&series, x_scale, y_scale, &points));
    try std.testing.expectEqual(@as(f32, 0), points[0][0]);
    try std.testing.expectEqual(@as(f32, 70), points[3][0]);
}

test "areaSegment tiles a trapezoid, cuts at the baseline, and skips the rest" {
    var out: [area_segment_points_max][2]f32 = undefined;
    var count = areaSegment(&out, .{ 0, 90 }, .{ 40, 70 }, 100);
    try std.testing.expectEqual(@as(u32, 6), count);
    try std.testing.expectEqual(@as(f32, 800), trianglesArea(out[0..count]));
    try std.testing.expectEqual([2]f32{ 40, 100 }, out[2]);
    try std.testing.expectEqual([2]f32{ 0, 100 }, out[5]);
    count = areaSegment(&out, .{ 0, 100 }, .{ 10, 80 }, 100);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual(@as(f32, 100), trianglesArea(out[0..count]));
    count = areaSegment(&out, .{ 0, 80 }, .{ 40, 160 }, 100);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual([2]f32{ 10, 100 }, out[1]);
    try std.testing.expectEqual(@as(f32, 100), trianglesArea(out[0..count]));
    count = areaSegment(&out, .{ 0, 160 }, .{ 40, 80 }, 100);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual([2]f32{ 30, 100 }, out[0]);
    try std.testing.expectEqual(@as(f32, 100), trianglesArea(out[0..count]));
    try std.testing.expectEqual(@as(u32, 0), areaSegment(&out, .{ 0, 100 }, .{ 40, 120 }, 100));
    try std.testing.expectEqual(@as(u32, 0), areaSegment(&out, .{ 5, 50 }, .{ 5, 60 }, 100));
    try std.testing.expectEqual(@as(u32, 0), areaSegment(&out, .{ 40, 50 }, .{ 0, 60 }, 100));
}

fn trianglesArea(points: []const [2]f32) f32 {
    std.debug.assert(points.len % 3 == 0);
    var total: f32 = 0;
    var index: usize = 0;
    while (index < points.len) : (index += 3) {
        const a = points[index];
        const b = points[index + 1];
        const c = points[index + 2];
        const cross = (b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1]);
        std.debug.assert(cross >= 0);
        total += cross / 2;
    }
    return total;
}
