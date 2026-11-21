//! ScatterChart stores a slice to externally-owned series data; the caller
//! must keep the data alive while the chart renders. Capacities are the
//! app's, fixed at comptime:
//! `const Segments = ScatterChart(.{ .point_count_max = 8, .series_count_max = 3 });`
//! sizes `Segments.Series` and the per-render projection scratch for 8 points.
//! Each render keeps at most one `[point_count_max][2]f32` array (8 bytes per
//! point) plus `projectSeries`' two LTTB arrays of the same size on the stack.

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

pub const PointShape = enum {
    circle,
    square,
    triangle,
    diamond,
};

/// A scatter chart drawing up to `capacity.series_count_max` series, each
/// holding up to `capacity.point_count_max` points.
pub fn ScatterChart(comptime capacity: types.PointCapacity) type {
    capacity.check();
    return struct {
        data: []const Series,

        width: f32 = constants.DEFAULT_WIDTH,
        height: f32 = constants.DEFAULT_HEIGHT,

        margin_top: f32 = constants.DEFAULT_MARGIN_TOP,
        margin_right: f32 = constants.DEFAULT_MARGIN_RIGHT,
        margin_bottom: f32 = constants.DEFAULT_MARGIN_BOTTOM,
        margin_left: f32 = constants.DEFAULT_MARGIN_LEFT,

        point_radius: f32 = constants.DEFAULT_POINT_RADIUS,
        point_shape: PointShape = .circle,
        point_opacity: f32 = 0.8,

        // When size_data is set, point radii are scaled by the corresponding values
        size_data: ?[]const []const f32 = null, // Per-series, per-point sizes
        size_range: [2]f32 = .{ 4.0, 20.0 }, // Min/max radius for size scaling

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

        // Datasets past `LOD_THRESHOLD` points decimate with LTTB.
        enable_lod: bool = true,
        lod_target_points: u32 = LOD_THRESHOLD,

        const Self = @This();

        pub const point_count_max: u32 = capacity.point_count_max;

        pub const series_count_max: u32 = capacity.series_count_max;

        pub const Series = types.Series(point_count_max);

        /// The slice must outlive the chart; the data is not copied.
        pub fn init(data: []const Series) Self {
            std.debug.assert(data.len > 0);
            std.debug.assert(data.len <= series_count_max);
            return .{ .data = data };
        }

        /// The series must outlive the chart; the data is not copied.
        pub fn initSingle(series: *const Series) Self {
            std.debug.assert(series.data_len > 0);
            const slice: []const Series = @as([*]const Series, @ptrCast(series))[0..1];
            return .{ .data = slice };
        }

        pub fn seriesCount(self: *const Self) u32 {
            std.debug.assert(self.data.len <= series_count_max);
            return @intCast(self.data.len);
        }

        pub fn getAccessibilityInfo(self: *const Self) a11y.ChartInfo {
            var info = a11y.infoFromSeries(Series, self.data, .scatter);
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

        /// Render the scatter chart, offset by the paint element's bounds.
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

            self.drawAllPoints(painter, x_scale, y_scale);

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
            std.debug.assert(self.data.len > 0);

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
            if (min == max) {
                return .{ .min = min - 1, .max = max + 1 };
            }

            return .{ .min = min, .max = max };
        }

        fn findYExtent(self: *const Self) struct { min: f32, max: f32 } {
            std.debug.assert(self.data.len > 0);

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
            if (min == max) {
                return .{ .min = min - 1, .max = max + 1 };
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

        /// Draw all series points. Uniform-radius circles go through the batched
        /// point-cloud path in one draw call; other shapes and size-encoded series
        /// draw point by point.
        fn drawAllPoints(
            self: *const Self,
            painter: *Painter,
            x_scale: LinearScale,
            y_scale: LinearScale,
        ) void {
            std.debug.assert(self.data.len > 0);

            // One instanced draw call for every circle: per-point drawing would
            // be N×M calls of N×M×64 tessellated vertices; batching is one call
            // of total_points × 4 quads.
            const can_batch = self.point_shape == .circle and self.size_data == null;

            if (can_batch) {
                self.drawAllPointsBatched(painter, x_scale, y_scale);
            } else {
                // Non-circle shapes or variable sizes draw individually.
                for (self.data, 0..) |*series, series_idx| {
                    const color = self.getSeriesColor(series, series_idx);
                    const alpha_color = Color.rgba(color.r, color.g, color.b, self.point_opacity);

                    const size_slice: ?[]const f32 = if (self.size_data) |sd|
                        if (series_idx < sd.len) sd[series_idx] else null
                    else
                        null;

                    self.drawSeriesPoints(
                        painter,
                        series,
                        series_idx,
                        x_scale,
                        y_scale,
                        alpha_color,
                        size_slice,
                    );
                }
            }
        }

        /// Draw each series as one point cloud at `point_opacity`. Only circles
        /// batch.
        fn drawAllPointsBatched(
            self: *const Self,
            painter: *Painter,
            x_scale: LinearScale,
            y_scale: LinearScale,
        ) void {
            std.debug.assert(self.data.len > 0);
            std.debug.assert(self.point_shape == .circle); // Only circles can be batched
            var centers: [point_count_max][2]f32 = undefined;
            const lod_points: ?u32 = if (self.enable_lod) self.lod_target_points else null;
            for (self.data, 0..) |*series, series_idx| {
                if (series.data_len == 0) continue;
                const count = scale_mod.projectSeries(
                    point_count_max,
                    series,
                    x_scale,
                    y_scale,
                    lod_points,
                    &centers,
                );
                std.debug.assert(count <= series.data_len);
                const color = self.getSeriesColor(series, series_idx);
                const alpha_color = Color.rgba(color.r, color.g, color.b, self.point_opacity);
                painter.pointCloud(centers[0..count], self.point_radius, alpha_color);
            }
        }

        fn drawSeriesPoints(
            self: *const Self,
            painter: *Painter,
            series: *const Series,
            series_idx: usize,
            x_scale: LinearScale,
            y_scale: LinearScale,
            color: Color,
            size_slice: ?[]const f32,
        ) void {
            _ = series_idx;
            std.debug.assert(series.data_len <= point_count_max);

            if (series.data_len == 0) return;

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

            var i: u32 = 0;
            while (i < series.data_len) : (i += 1) {
                const point = &series.data[i];
                const px = x_scale.scale(point.x);
                const py = y_scale.scale(point.y);

                const radius = if (size_slice) |sizes|
                    if (i < sizes.len)
                        self.scaleSize(sizes[i], size_min, size_max)
                    else
                        self.point_radius
                else
                    self.point_radius;

                self.drawPoint(painter, px, py, radius, color);
            }
        }

        fn scaleSize(self: *const Self, value: f32, min: f32, max: f32) f32 {
            std.debug.assert(self.size_range[1] >= self.size_range[0]);

            if (max <= min) return self.size_range[0];

            const t = (value - min) / (max - min);
            const clamped = @max(0, @min(1, t));
            return self.size_range[0] + clamped * (self.size_range[1] - self.size_range[0]);
        }

        fn drawPoint(
            self: *const Self,
            painter: *Painter,
            x: f32,
            y: f32,
            radius: f32,
            color: Color,
        ) void {
            std.debug.assert(radius > 0);
            std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));

            switch (self.point_shape) {
                .circle => painter.circle(.{ x, y }, radius, color),
                .square => self.drawSquare(painter, x, y, radius, color),
                .triangle => self.drawTriangle(painter, x, y, radius, color),
                .diamond => self.drawDiamond(painter, x, y, radius, color),
            }
        }

        fn drawSquare(
            _: *const Self,
            painter: *Painter,
            x: f32,
            y: f32,
            radius: f32,
            color: Color,
        ) void {
            std.debug.assert(radius > 0);
            const size = radius * 1.8; // Make square visually similar area to circle
            painter.fill(
                .{ .x = x - size / 2, .y = y - size / 2, .width = size, .height = size },
                color,
            );
        }

        fn drawTriangle(
            _: *const Self,
            painter: *Painter,
            x: f32,
            y: f32,
            radius: f32,
            color: Color,
        ) void {
            std.debug.assert(radius > 0);
            // Equilateral triangle with centroid at (x, y).
            const h = radius * 2.2; // Height for similar visual area
            const half_w = h * 0.577; // half_width = height * tan(30°) ≈ height / sqrt(3)

            const top_y = y - h * 0.667; // 2/3 above centroid
            const bottom_y = y + h * 0.333; // 1/3 below centroid

            painter.triangles(
                &.{ .{ x, top_y }, .{ x - half_w, bottom_y }, .{ x + half_w, bottom_y } },
                color,
            );
        }

        fn drawDiamond(
            _: *const Self,
            painter: *Painter,
            x: f32,
            y: f32,
            radius: f32,
            color: Color,
        ) void {
            std.debug.assert(radius > 0);
            const half = radius * 1.0; // Half diagonal

            const top = y - half;
            const bottom = y + half;
            const left = x - half;
            const right = x + half;

            painter.triangles(&.{
                .{ x, top }, .{ left, y }, .{ right, y }, // Top triangle
                .{ x, bottom }, .{ left, y }, .{ right, y }, // Bottom triangle
            }, color);
        }

        fn getSeriesColor(self: *const Self, series: *const Series, index: usize) Color {
            // Priority: series explicit color > theme palette > default palette.
            if (series.color) |color| {
                return color;
            }
            if (self.chart_theme) |t| {
                return t.paletteColor(index);
            }
            std.debug.assert(index < series_count_max);
            return default_palette[index % default_palette.len];
        }

        pub fn hitTest(
            self: *const Self,
            px: f32,
            py: f32,
        ) ?struct { series_index: usize, point_index: usize } {
            std.debug.assert(self.data.len > 0);
            std.debug.assert(self.width > 0 and self.height > 0);

            const inner_x = self.margin_left;
            const inner_y = self.margin_top;
            const inner_width = self.width - self.margin_left - self.margin_right;
            const inner_height = self.height - self.margin_top - self.margin_bottom;

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
}

/// A chart with room for two series of 16 points, enough for every test below.
const TestChart = ScatterChart(.{ .point_count_max = 16, .series_count_max = 2 });
const TestSeries = TestChart.Series;

test "ScatterChart init from slice" {
    const series = [_]TestSeries{
        TestSeries.fromSlice("TestSeries A", &.{
            .{ .x = 1, .y = 10 },
            .{ .x = 2, .y = 20 },
            .{ .x = 3, .y = 15 },
        }, Color.hex(0xff0000)),
    };

    const chart = TestChart.init(&series);

    try std.testing.expectEqual(@as(usize, 1), chart.data.len);
    try std.testing.expectEqual(@as(u32, 3), chart.data[0].data_len);
}

test "ScatterChart initSingle" {
    var series: TestSeries = undefined;
    series.initInPlace("Test", Color.hex(0x00ff00));
    series.addPoint(DataPoint.init(5, 50));

    const chart = TestChart.initSingle(&series);

    try std.testing.expectEqual(@as(usize, 1), chart.data.len);
}

test "ScatterChart findXExtent" {
    const series = [_]TestSeries{
        TestSeries.fromSlice("A", &.{
            .{ .x = 1, .y = 10 },
            .{ .x = 5, .y = 20 },
        }, Color.hex(0xff0000)),
        TestSeries.fromSlice("B", &.{
            .{ .x = 2, .y = 15 },
            .{ .x = 8, .y = 25 },
        }, Color.hex(0x00ff00)),
    };

    const chart = TestChart.init(&series);
    const extent = chart.findXExtent();

    try std.testing.expectEqual(@as(f32, 1), extent.min);
    try std.testing.expectEqual(@as(f32, 8), extent.max);
}

test "ScatterChart findYExtent" {
    const series = [_]TestSeries{
        TestSeries.fromSlice("A", &.{
            .{ .x = 1, .y = 10 },
            .{ .x = 5, .y = 30 },
        }, Color.hex(0xff0000)),
        TestSeries.fromSlice("B", &.{
            .{ .x = 2, .y = 5 },
            .{ .x = 8, .y = 25 },
        }, Color.hex(0x00ff00)),
    };

    const chart = TestChart.init(&series);
    const extent = chart.findYExtent();

    try std.testing.expectEqual(@as(f32, 5), extent.min);
    try std.testing.expectEqual(@as(f32, 30), extent.max);
}

test "ScatterChart defaults" {
    const series = [_]TestSeries{
        TestSeries.fromSlice("Test", &.{
            .{ .x = 0, .y = 0 },
        }, Color.hex(0xff0000)),
    };

    const chart = TestChart.init(&series);

    try std.testing.expectEqual(@as(f32, 400), chart.width);
    try std.testing.expectEqual(@as(f32, 300), chart.height);
    try std.testing.expectEqual(@as(f32, 4), chart.point_radius);
    try std.testing.expect(chart.point_shape == .circle);
    try std.testing.expect(chart.show_grid);
    try std.testing.expect(chart.show_x_axis);
    try std.testing.expect(chart.show_y_axis);
}

test "ScatterChart struct size is small" {
    const size = @sizeOf(TestChart);
    std.debug.print("\nScatterChart size: {} bytes\n", .{size});
    try std.testing.expect(size < 400);
}

test "ScatterChart scaleSize" {
    const series = [_]TestSeries{
        TestSeries.fromSlice("Test", &.{
            .{ .x = 0, .y = 0 },
        }, Color.hex(0xff0000)),
    };

    var chart = TestChart.init(&series);
    chart.size_range = .{ 4.0, 20.0 };

    try std.testing.expectEqual(@as(f32, 4.0), chart.scaleSize(0, 0, 100));
    try std.testing.expectEqual(@as(f32, 12.0), chart.scaleSize(50, 0, 100));
    try std.testing.expectEqual(@as(f32, 20.0), chart.scaleSize(100, 0, 100));

    try std.testing.expectEqual(@as(f32, 4.0), chart.scaleSize(50, 50, 50));
}

test "ScatterChart LOD defaults" {
    const series = [_]TestSeries{
        TestSeries.fromSlice("Test", &.{
            .{ .x = 0, .y = 0 },
        }, Color.hex(0xff0000)),
    };

    const chart = TestChart.init(&series);

    try std.testing.expect(chart.enable_lod);
    try std.testing.expectEqual(LOD_THRESHOLD, chart.lod_target_points);
}

test "ScatterChart point shapes" {
    const series = [_]TestSeries{
        TestSeries.fromSlice("Test", &.{
            .{ .x = 0, .y = 0 },
        }, Color.hex(0xff0000)),
    };

    var chart = TestChart.init(&series);

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
    const series = [_]TestSeries{
        TestSeries.fromSlice("Test", &.{
            .{ .x = 50, .y = 50 },
        }, Color.hex(0xff0000)),
    };

    var chart = TestChart.init(&series);
    chart.width = 400;
    chart.height = 300;

    const result = chart.hitTest(0, 0);
    try std.testing.expect(result == null);
}

test "ScatterChart fills exactly its capacity" {
    // Goal: a chart whose series are all full projects and hit-tests every
    // point, with no loss at the boundary. Methodology: two series of exactly
    // point_count_max points; every point projects, the a11y summary counts
    // them all, and the last point of the last series is hit.
    const Full = ScatterChart(.{ .point_count_max = 8, .series_count_max = 2 });
    var series_array: [Full.series_count_max]Full.Series = undefined;
    for (&series_array, 0..) |*series, series_index| {
        series.initInPlace("Full", null);
        for (0..Full.point_count_max) |point_index| {
            const x: f32 = @floatFromInt(point_index * 10);
            series.addPoint(DataPoint.init(x, @floatFromInt(series_index * 50)));
        }
        try std.testing.expectEqual(Full.point_count_max, series.data_len);
    }
    const chart = Full.init(&series_array);
    const x_scale = LinearScale.init(0, 70, 0, 70);
    const y_scale = LinearScale.init(0, 50, 100, 0);
    var centers: [Full.point_count_max][2]f32 = undefined;
    for (&series_array) |*series| {
        const count = scale_mod.projectSeries(
            Full.point_count_max,
            series,
            x_scale,
            y_scale,
            null,
            &centers,
        );
        try std.testing.expectEqual(Full.point_count_max, count);
        try std.testing.expectEqual(@as(f32, 70), centers[count - 1][0]);
    }
    const info = chart.getAccessibilityInfo();
    try std.testing.expectEqual(Full.point_count_max * Full.series_count_max, info.point_count);
    try std.testing.expectEqual(Full.series_count_max, chart.seriesCount());
    // The last point of the last series, (70, 50), placed the way hitTest places it.
    const nice_x = util.niceRange(0, 70, 5);
    const nice_y = util.niceRange(0, 50, 5);
    const right = chart.width - chart.margin_right;
    const bottom = chart.height - chart.margin_bottom;
    const hit_x = LinearScale.init(nice_x.min, nice_x.max, chart.margin_left, right).scale(70);
    const hit_y = LinearScale.init(nice_y.min, nice_y.max, bottom, chart.margin_top).scale(50);
    const hit = chart.hitTest(hit_x, hit_y);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(usize, 1), hit.?.series_index);
    try std.testing.expectEqual(@as(usize, Full.point_count_max - 1), hit.?.point_index);
}
