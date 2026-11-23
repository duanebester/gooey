const std = @import("std");
const paint = @import("../paint.zig");
const constants = @import("../constants.zig");
const types = @import("../types.zig");
const theme_mod = @import("../theme.zig");
const a11y = @import("../accessibility.zig");

const CategoryPoint = types.CategoryPoint;
const ChartTheme = theme_mod.ChartTheme;

pub const Color = paint.Color;
pub const Painter = paint.Painter;

const ARC_SEGMENTS_PER_FULL_CIRCLE = 64;

pub const default_palette = theme_mod.google_palette;

pub fn PieChart(comptime capacity: types.SliceCapacity) type {
    capacity.check();
    return struct {
        pub const LabelPosition = enum {
            inside,
            outside,
            none,
        };

        data: []const CategoryPoint,

        width: f32 = 300,
        height: f32 = 300,

        inner_radius_ratio: f32 = 0,

        gap_pixels: ?f32 = null,
        pad_angle: f32 = 0.02,
        start_angle: f32 = -std.math.pi / 2.0,

        show_labels: bool = false,
        label_position: LabelPosition = .outside,

        chart_theme: ?*const ChartTheme = null,

        accessible_title: ?[]const u8 = null,
        accessible_description: ?[]const u8 = null,

        const Self = @This();

        pub const slice_count_max: u32 = capacity.slice_count_max;

        pub fn init(data: []const CategoryPoint) Self {
            std.debug.assert(data.len > 0);
            if (data.len > slice_count_max) {
                std.debug.panic("pie chart of {d} slices: capacity {d}. " ++
                    "Raise the chart's slice_count_max.", .{ data.len, slice_count_max });
            }
            const chart: Self = .{ .data = data };
            std.debug.assert(chart.sliceCount() <= slice_count_max);
            return chart;
        }

        pub fn sliceCount(self: *const Self) u32 {
            return @intCast(self.data.len);
        }

        pub fn isDonut(self: *const Self) bool {
            return self.inner_radius_ratio > 0;
        }

        pub fn getAccessibilityInfo(self: *const Self) a11y.ChartInfo {
            var info = a11y.infoFromCategoryPoints(self.data, self.isDonut());
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
            std.debug.assert(self.inner_radius_ratio >= 0 and self.inner_radius_ratio < 1);

            const half_width = self.width / 2.0;
            const half_height = self.height / 2.0;
            const cx = painter.bounds.x + half_width;
            const cy = painter.bounds.y + half_height;
            const outer_radius = @min(half_width, half_height) * 0.85;
            const inner_radius = outer_radius * self.inner_radius_ratio;

            std.debug.assert(outer_radius > 0);

            const total = self.calculateTotal();
            if (total <= 0) return;

            self.drawSlices(painter, cx, cy, outer_radius, inner_radius, total);

            if (self.show_labels and self.label_position != .none) {
                self.drawLabels(painter, cx, cy, outer_radius, inner_radius, total);
            }
        }

        fn calculateTotal(self: *const Self) f32 {
            var total: f32 = 0;
            for (self.data) |point| {
                if (point.value > 0) {
                    total += point.value;
                }
            }
            return total;
        }

        fn drawSlices(
            self: *const Self,
            painter: *Painter,
            cx: f32,
            cy: f32,
            outer_radius: f32,
            inner_radius: f32,
            total: f32,
        ) void {
            std.debug.assert(total > 0);
            std.debug.assert(outer_radius >= inner_radius);

            var current_angle = self.start_angle;
            const is_donut = inner_radius > 0.5;

            const half_pad_outer: f32 = if (self.gap_pixels) |gap|
                gap / (2.0 * outer_radius)
            else
                self.pad_angle / 2.0;
            const half_pad_inner: f32 = if (is_donut)
                (if (self.gap_pixels) |gap| gap / (2.0 * inner_radius) else self.pad_angle / 2.0)
            else
                half_pad_outer;

            const explode_offset: f32 = if (is_donut) 0 else self.gap_pixels orelse 0;

            for (self.data, 0..) |point, idx| {
                if (point.value <= 0) continue;

                const slice_angle = (point.value / total) * 2.0 * std.math.pi;

                if (slice_angle < 0.01) {
                    current_angle += slice_angle;
                    continue;
                }

                const color = point.color orelse
                    (if (self.chart_theme) |t|
                        t.paletteColor(idx)
                    else
                        default_palette[idx % default_palette.len]);

                const bisector = current_angle + slice_angle / 2.0;
                const slice_cx = cx + explode_offset * @cos(bisector);
                const slice_cy = cy + explode_offset * @sin(bisector);

                self.drawSlice(
                    painter,
                    slice_cx,
                    slice_cy,
                    outer_radius - explode_offset,
                    inner_radius,
                    current_angle,
                    slice_angle,
                    half_pad_outer,
                    half_pad_inner,
                    color,
                );

                current_angle += slice_angle;
            }
        }

        fn drawSlice(
            self: *const Self,
            painter: *Painter,
            cx: f32,
            cy: f32,
            outer_r: f32,
            inner_r: f32,
            base_angle: f32,
            slice_angle: f32,
            half_pad_outer: f32,
            half_pad_inner: f32,
            color: Color,
        ) void {
            _ = self;

            std.debug.assert(!std.math.isNan(base_angle) and !std.math.isNan(slice_angle));
            std.debug.assert(outer_r >= inner_r);
            std.debug.assert(slice_angle > 0);

            const outer_start = base_angle + half_pad_outer;
            const outer_end = base_angle + slice_angle - half_pad_outer;

            var angle_span = outer_end - outer_start;
            if (angle_span < 0) angle_span += 2.0 * std.math.pi;
            if (angle_span <= 0) return;

            const segments: u32 = @max(2, @as(u32, @intFromFloat(
                @ceil(angle_span / (2.0 * std.math.pi) * @as(f32, ARC_SEGMENTS_PER_FULL_CIRCLE)),
            )));

            if (inner_r > 0.5) {
                const inner_start = base_angle + half_pad_inner;
                const inner_end = base_angle + slice_angle - half_pad_inner;

                const outer_step = (outer_end - outer_start) / @as(f32, @floatFromInt(segments));
                const inner_step = (inner_end - inner_start) / @as(f32, @floatFromInt(segments));

                var i: u32 = 0;
                while (i < segments) : (i += 1) {
                    const fi = @as(f32, @floatFromInt(i));
                    const fi1 = @as(f32, @floatFromInt(i + 1));
                    const outer1 = arcPoint(cx, cy, outer_r, outer_start + fi * outer_step);
                    const outer2 = arcPoint(cx, cy, outer_r, outer_start + fi1 * outer_step);
                    const inner1 = arcPoint(cx, cy, inner_r, inner_start + fi * inner_step);
                    const inner2 = arcPoint(cx, cy, inner_r, inner_start + fi1 * inner_step);
                    painter.triangles(&.{ inner1, outer1, outer2, inner1, outer2, inner2 }, color);
                }
            } else {
                const outer_step = (outer_end - outer_start) / @as(f32, @floatFromInt(segments));

                var i: u32 = 0;
                while (i < segments) : (i += 1) {
                    const fi = @as(f32, @floatFromInt(i));
                    const fi1 = @as(f32, @floatFromInt(i + 1));
                    const point1 = arcPoint(cx, cy, outer_r, outer_start + fi * outer_step);
                    const point2 = arcPoint(cx, cy, outer_r, outer_start + fi1 * outer_step);
                    painter.triangles(&.{ .{ cx, cy }, point1, point2 }, color);
                }
            }
        }

        fn arcPoint(cx: f32, cy: f32, radius: f32, angle: f32) [2]f32 {
            std.debug.assert(radius >= 0);
            std.debug.assert(!std.math.isNan(angle));
            return .{ cx + radius * @cos(angle), cy + radius * @sin(angle) };
        }

        fn drawLabels(
            self: *const Self,
            painter: *Painter,
            cx: f32,
            cy: f32,
            outer_radius: f32,
            inner_radius: f32,
            total: f32,
        ) void {
            std.debug.assert(total > 0);

            var current_angle = self.start_angle;

            const label_radius = switch (self.label_position) {
                .inside => (outer_radius + inner_radius) / 2.0,
                .outside => outer_radius * 1.15,
                .none => return,
            };

            for (self.data) |point| {
                if (point.value <= 0) continue;

                const slice_angle = (point.value / total) * 2.0 * std.math.pi;

                if (slice_angle < 0.15) {
                    current_angle += slice_angle;
                    continue;
                }

                const mid_angle = current_angle + slice_angle / 2.0;
                const label_x = cx + label_radius * @cos(mid_angle);
                const label_y = cy + label_radius * @sin(mid_angle);

                const marker_color = switch (self.label_position) {
                    .inside => Color.white,
                    .outside => Color.hex(0x666666),
                    .none => Color.white,
                };
                painter.circle(.{ label_x, label_y }, 3, marker_color);

                current_angle += slice_angle;
            }
        }

        pub fn hitTest(self: *const Self, x: f32, y: f32) ?usize {
            const cx = self.width / 2.0;
            const cy = self.height / 2.0;
            const outer_radius = @min(cx, cy) * 0.85;
            const inner_radius = outer_radius * self.inner_radius_ratio;

            const dx = x - cx;
            const dy = y - cy;
            const distance = @sqrt(dx * dx + dy * dy);

            if (distance < inner_radius or distance > outer_radius) {
                return null;
            }

            var angle = std.math.atan2(dy, dx);
            angle -= self.start_angle;
            while (angle < 0) angle += 2.0 * std.math.pi;
            while (angle >= 2.0 * std.math.pi) angle -= 2.0 * std.math.pi;

            const total = self.calculateTotal();
            if (total <= 0) return null;

            var current_angle: f32 = 0;
            for (self.data, 0..) |point, idx| {
                if (point.value <= 0) continue;

                const slice_angle = (point.value / total) * 2.0 * std.math.pi;
                if (angle >= current_angle and angle < current_angle + slice_angle) {
                    return idx;
                }
                current_angle += slice_angle;
            }

            return null;
        }
    };
}

const TestChart = PieChart(.{ .slice_count_max = 8 });

test "PieChart init" {
    const data = [_]CategoryPoint{
        CategoryPoint.init("A", 30),
        CategoryPoint.init("B", 50),
        CategoryPoint.init("C", 20),
    };

    const chart = TestChart.init(&data);
    try std.testing.expectEqual(@as(u32, 3), chart.sliceCount());
    try std.testing.expectEqual(@as(f32, 300), chart.width);
    try std.testing.expectEqual(@as(f32, 0), chart.inner_radius_ratio);
}

test "PieChart calculateTotal" {
    const data = [_]CategoryPoint{
        CategoryPoint.init("A", 25),
        CategoryPoint.init("B", 50),
        CategoryPoint.init("C", 25),
    };

    const chart = TestChart.init(&data);
    const total = chart.calculateTotal();
    try std.testing.expectEqual(@as(f32, 100), total);
}

test "PieChart hitTest center hole" {
    const data = [_]CategoryPoint{
        CategoryPoint.init("A", 50),
        CategoryPoint.init("B", 50),
    };

    var chart = TestChart.init(&data);
    chart.inner_radius_ratio = 0.5;

    const hit = chart.hitTest(150, 150);
    try std.testing.expect(hit == null);
}

test "PieChart struct size is small" {
    const size = @sizeOf(TestChart);
    try std.testing.expect(size < 120);
}

test "PieChart donut configuration" {
    const data = [_]CategoryPoint{
        CategoryPoint.init("A", 100),
    };

    var chart = TestChart.init(&data);
    chart.inner_radius_ratio = 0.6;

    try std.testing.expectEqual(@as(f32, 0.6), chart.inner_radius_ratio);
}

test "PieChart with custom colors" {
    var data = [_]CategoryPoint{
        CategoryPoint.initColored("Red", 33, Color.hex(0xff0000)),
        CategoryPoint.initColored("Green", 33, Color.hex(0x00ff00)),
        CategoryPoint.initColored("Blue", 34, Color.hex(0x0000ff)),
    };

    const chart = TestChart.init(&data);
    try std.testing.expectEqual(@as(u32, 3), chart.sliceCount());
}

test "PieChart fills exactly its capacity" {
    const Full = PieChart(.{ .slice_count_max = 4 });
    const data = [Full.slice_count_max]CategoryPoint{
        CategoryPoint.init("A", 25), CategoryPoint.init("B", 25),
        CategoryPoint.init("C", 25), CategoryPoint.init("D", 25),
    };
    var chart = Full.init(&data);
    chart.pad_angle = 0;
    try std.testing.expectEqual(Full.slice_count_max, chart.sliceCount());
    try std.testing.expectEqual(@as(f32, 100), chart.calculateTotal());
    const info = chart.getAccessibilityInfo();
    try std.testing.expectEqual(Full.slice_count_max, info.point_count);
    const hit = chart.hitTest(chart.width / 2 - 50, chart.height / 2 - 50);
    try std.testing.expectEqual(@as(?usize, Full.slice_count_max - 1), hit);
}
