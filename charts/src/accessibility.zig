const std = @import("std");
const gooey = @import("gooey");
const types = @import("types.zig");
const constants = @import("constants.zig");

pub const Role = gooey.accessibility.Role;
pub const State = gooey.accessibility.State;
pub const Live = gooey.accessibility.Live;

pub const MAX_DESCRIPTION_LENGTH: usize = 512;

pub const MAX_SUMMARY_LENGTH: usize = 128;

pub const MAX_POINT_DESCRIPTION_LENGTH: usize = 64;

const point_count_total_max: u32 = constants.point_count_ceiling * constants.series_count_ceiling;

pub const VERBALIZE_THRESHOLD: usize = 8;

pub const ChartInfo = struct {
    chart_type: ChartType,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    series_count: u32 = 1,
    point_count: u32 = 0,
    min_value: ?f32 = null,
    max_value: ?f32 = null,
    min_label: ?[]const u8 = null,
    max_label: ?[]const u8 = null,
    avg_value: ?f32 = null,
    total_value: ?f32 = null,

    pub fn getTitle(self: *const ChartInfo) []const u8 {
        if (self.title) |t| return t;
        return self.chart_type.defaultTitle();
    }
};

pub const ChartType = enum {
    bar,
    line,
    pie,
    donut,
    scatter,

    pub fn defaultTitle(self: ChartType) []const u8 {
        return switch (self) {
            .bar => "Bar Chart",
            .line => "Line Chart",
            .pie => "Pie Chart",
            .donut => "Donut Chart",
            .scatter => "Scatter Chart",
        };
    }

    pub fn roleDescription(self: ChartType) []const u8 {
        return switch (self) {
            .bar => "bar chart",
            .line => "line chart",
            .pie => "pie chart",
            .donut => "donut chart",
            .scatter => "scatter plot",
        };
    }
};

pub fn describe(info: *const ChartInfo, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= MAX_DESCRIPTION_LENGTH);
    std.debug.assert(info.point_count <= point_count_total_max);

    if (info.description) |desc| {
        const len = @min(desc.len, buf.len - 1);
        @memcpy(buf[0..len], desc[0..len]);
        return buf[0..len];
    }

    var writer = std.Io.Writer.fixed(buf);

    writeChartOverview(&writer, info) catch return buf[0..0];

    if (info.point_count > 0) {
        writeDataSummary(&writer, info) catch {};
    }

    return writer.buffered();
}

fn writeChartOverview(writer: anytype, info: *const ChartInfo) !void {
    std.debug.assert(info.series_count <= constants.series_count_ceiling);
    std.debug.assert(@backingInt(info.chart_type) <= @backingInt(ChartType.scatter));

    try writer.print("{s}", .{info.chart_type.defaultTitle()});

    if (info.series_count > 1) {
        try writer.print(" with {d} series", .{info.series_count});
    }

    if (info.point_count > 0) {
        const noun = switch (info.chart_type) {
            .bar => "categories",
            .pie, .donut => "slices",
            .scatter => "points",
            .line => "data points",
        };
        try writer.print(" and {d} {s}", .{ info.point_count, noun });
    }

    try writer.writeAll(". ");
}

fn writeDataSummary(writer: anytype, info: *const ChartInfo) !void {
    if (info.max_value) |max| {
        std.debug.assert(!std.math.isNan(max));
    }
    if (info.min_value) |min| {
        std.debug.assert(!std.math.isNan(min));
    }

    if (info.max_value) |max| {
        try writer.print("Maximum: {d:.1}", .{max});
        if (info.max_label) |label| {
            try writer.print(" ({s})", .{label});
        }
        try writer.writeAll(". ");
    }

    if (info.min_value) |min| {
        try writer.print("Minimum: {d:.1}", .{min});
        if (info.min_label) |label| {
            try writer.print(" ({s})", .{label});
        }
        try writer.writeAll(". ");
    }

    if (info.avg_value) |avg| {
        try writer.print("Average: {d:.1}. ", .{avg});
    }

    if (info.chart_type == .pie or info.chart_type == .donut) {
        if (info.total_value) |total| {
            try writer.print("Total: {d:.1}. ", .{total});
        }
    }
}

pub fn summarize(info: *const ChartInfo, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= MAX_SUMMARY_LENGTH);
    std.debug.assert(info.point_count <= point_count_total_max);

    var writer = std.Io.Writer.fixed(buf);

    writer.print("{s}", .{info.getTitle()}) catch return buf[0..0];

    if (info.point_count > 0 and info.max_value != null) {
        writer.print(": max {d:.1}", .{info.max_value.?}) catch {};
        if (info.min_value) |min| {
            writer.print(", min {d:.1}", .{min}) catch {};
        }
    }

    return writer.buffered();
}

pub fn describePoint(
    label: []const u8,
    value: f32,
    buf: []u8,
) []const u8 {
    std.debug.assert(buf.len >= MAX_POINT_DESCRIPTION_LENGTH);
    std.debug.assert(!std.math.isNan(value));

    var writer = std.Io.Writer.fixed(buf);

    writer.print("{s}: {d:.1}", .{ label, value }) catch return buf[0..0];

    return writer.buffered();
}

pub fn describeSlice(
    label: []const u8,
    value: f32,
    percentage: f32,
    buf: []u8,
) []const u8 {
    std.debug.assert(buf.len >= MAX_POINT_DESCRIPTION_LENGTH);
    std.debug.assert(!std.math.isNan(value));
    std.debug.assert(percentage >= 0 and percentage <= 100);

    var writer = std.Io.Writer.fixed(buf);

    writer.print("{s}: {d:.1} ({d:.0}%)", .{ label, value, percentage }) catch return buf[0..0];

    return writer.buffered();
}

pub fn describeScatterPoint(
    x: f32,
    y: f32,
    label: ?[]const u8,
    buf: []u8,
) []const u8 {
    std.debug.assert(buf.len >= MAX_POINT_DESCRIPTION_LENGTH);
    std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));

    var writer = std.Io.Writer.fixed(buf);

    if (label) |l| {
        writer.print("{s}: ({d:.1}, {d:.1})", .{ l, x, y }) catch return buf[0..0];
    } else {
        writer.print("({d:.1}, {d:.1})", .{ x, y }) catch return buf[0..0];
    }

    return writer.buffered();
}

pub fn infoFromCategorySeries(
    comptime SeriesType: type,
    series: []const SeriesType,
    chart_type: ChartType,
) ChartInfo {
    comptime std.debug.assert(SeriesType == types.CategorySeries(SeriesType.capacity));
    std.debug.assert(series.len > 0);
    std.debug.assert(series.len <= constants.series_count_ceiling);

    var info = ChartInfo{
        .chart_type = chart_type,
        .series_count = @intCast(series.len),
        .point_count = 0,
        .min_value = null,
        .max_value = null,
        .total_value = 0,
    };

    const first = &series[0];
    std.debug.assert(first.data_len <= constants.category_count_ceiling);
    info.point_count = first.data_len;

    var total: f32 = 0;
    var min_idx: u32 = 0;
    var max_idx: u32 = 0;

    for (0..first.data_len) |i| {
        const point = &first.data[i];
        const val = point.value;
        total += val;

        if (info.min_value == null or val < info.min_value.?) {
            info.min_value = val;
            min_idx = @intCast(i);
        }
        if (info.max_value == null or val > info.max_value.?) {
            info.max_value = val;
            max_idx = @intCast(i);
        }
    }

    if (first.data_len > 0) {
        info.min_label = first.data[min_idx].getLabel();
        info.max_label = first.data[max_idx].getLabel();
    }

    if (first.data_len > 0) {
        info.avg_value = total / @as(f32, @floatFromInt(first.data_len));
    }

    info.total_value = total;

    return info;
}

pub fn infoFromSeries(
    comptime SeriesType: type,
    series: []const SeriesType,
    chart_type: ChartType,
) ChartInfo {
    comptime std.debug.assert(SeriesType == types.Series(SeriesType.capacity));
    std.debug.assert(series.len > 0);
    std.debug.assert(series.len <= constants.series_count_ceiling);

    var info = ChartInfo{
        .chart_type = chart_type,
        .series_count = @intCast(series.len),
        .point_count = 0,
        .min_value = null,
        .max_value = null,
    };

    var total: f32 = 0;
    var count: u32 = 0;

    for (series) |*s| {
        std.debug.assert(s.data_len <= constants.point_count_ceiling);
        info.point_count += s.data_len;

        for (0..s.data_len) |i| {
            const point = &s.data[i];
            const val = point.y;
            total += val;
            count += 1;

            if (info.min_value == null or val < info.min_value.?) {
                info.min_value = val;
            }
            if (info.max_value == null or val > info.max_value.?) {
                info.max_value = val;
            }
        }
    }

    if (count > 0) {
        info.avg_value = total / @as(f32, @floatFromInt(count));
    }

    return info;
}

pub fn infoFromCategoryPoints(
    points: []const types.CategoryPoint,
    is_donut: bool,
) ChartInfo {
    std.debug.assert(points.len > 0);
    std.debug.assert(points.len <= constants.slice_count_ceiling);

    var info = ChartInfo{
        .chart_type = if (is_donut) .donut else .pie,
        .series_count = 1,
        .point_count = @intCast(points.len),
        .min_value = null,
        .max_value = null,
        .total_value = 0,
    };

    var min_idx: usize = 0;
    var max_idx: usize = 0;

    for (points, 0..) |point, i| {
        const val = point.value;
        info.total_value.? += val;

        if (info.min_value == null or val < info.min_value.?) {
            info.min_value = val;
            min_idx = i;
        }
        if (info.max_value == null or val > info.max_value.?) {
            info.max_value = val;
            max_idx = i;
        }
    }

    info.min_label = points[min_idx].getLabel();
    info.max_label = points[max_idx].getLabel();

    if (points.len > 0) {
        info.avg_value = info.total_value.? / @as(f32, @floatFromInt(points.len));
    }

    return info;
}

pub const FocusPosition = struct {
    series_idx: u32 = 0,
    point_idx: u32 = 0,

    pub fn next(self: *FocusPosition, points_per_series: u32, series_count: u32) void {
        std.debug.assert(series_count > 0);
        std.debug.assert(points_per_series > 0);

        self.point_idx += 1;
        if (self.point_idx >= points_per_series) {
            self.point_idx = 0;
            self.series_idx = (self.series_idx + 1) % series_count;
        }
    }

    pub fn prev(self: *FocusPosition, points_per_series: u32, series_count: u32) void {
        std.debug.assert(series_count > 0);
        std.debug.assert(points_per_series > 0);

        if (self.point_idx == 0) {
            self.point_idx = points_per_series - 1;
            if (self.series_idx == 0) {
                self.series_idx = series_count - 1;
            } else {
                self.series_idx -= 1;
            }
        } else {
            self.point_idx -= 1;
        }
    }
};

pub const Politeness = enum {
    polite,
    assertive,
};

pub fn announceValueChange(
    label: []const u8,
    old_value: f32,
    new_value: f32,
    buf: []u8,
) []const u8 {
    std.debug.assert(buf.len >= MAX_SUMMARY_LENGTH);
    std.debug.assert(!std.math.isNan(old_value) and !std.math.isNan(new_value));

    var writer = std.Io.Writer.fixed(buf);

    const delta = new_value - old_value;
    const direction: []const u8 = if (delta > 0) "increased" else if (delta < 0) "decreased" else "unchanged";

    writer.print("{s} {s} from {d:.1} to {d:.1}", .{
        label,
        direction,
        old_value,
        new_value,
    }) catch return buf[0..0];

    return writer.buffered();
}

pub fn announceSelection(
    label: []const u8,
    value: f32,
    position: u32,
    total: u32,
    buf: []u8,
) []const u8 {
    std.debug.assert(buf.len >= MAX_SUMMARY_LENGTH);
    std.debug.assert(position < total);
    std.debug.assert(!std.math.isNan(value));

    var writer = std.Io.Writer.fixed(buf);

    writer.print("{s}, {d:.1}, {d} of {d}", .{
        label,
        value,
        position + 1,
        total,
    }) catch return buf[0..0];

    return writer.buffered();
}

comptime {
    std.debug.assert(MAX_DESCRIPTION_LENGTH >= 256);
    std.debug.assert(MAX_SUMMARY_LENGTH >= 64);
    std.debug.assert(MAX_POINT_DESCRIPTION_LENGTH >= 32);

    std.debug.assert(VERBALIZE_THRESHOLD > 0);
    std.debug.assert(VERBALIZE_THRESHOLD <= 20);
}

test "describe generates chart description" {
    var buf: [MAX_DESCRIPTION_LENGTH]u8 = undefined;

    const info = ChartInfo{
        .chart_type = .bar,
        .series_count = 1,
        .point_count = 4,
        .min_value = 100,
        .max_value = 180,
        .min_label = "January",
        .max_label = "April",
        .avg_value = 140,
    };

    const desc = describe(&info, &buf);
    try std.testing.expect(desc.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, desc, "Bar Chart") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "180") != null);
}

test "describe uses user-provided description" {
    var buf: [MAX_DESCRIPTION_LENGTH]u8 = undefined;

    const info = ChartInfo{
        .chart_type = .line,
        .description = "Custom description for testing",
    };

    const desc = describe(&info, &buf);
    try std.testing.expectEqualStrings("Custom description for testing", desc);
}

test "summarize generates short summary" {
    var buf: [MAX_SUMMARY_LENGTH]u8 = undefined;

    const info = ChartInfo{
        .chart_type = .pie,
        .title = "Sales",
        .point_count = 5,
        .max_value = 250,
        .min_value = 50,
    };

    const summary = summarize(&info, &buf);
    try std.testing.expect(summary.len > 0);
    try std.testing.expect(summary.len < MAX_SUMMARY_LENGTH);
}

test "describePoint formats correctly" {
    var buf: [MAX_POINT_DESCRIPTION_LENGTH]u8 = undefined;

    const desc = describePoint("Q1", 150.5, &buf);
    try std.testing.expectEqualStrings("Q1: 150.5", desc);
}

test "describeSlice includes percentage" {
    var buf: [MAX_POINT_DESCRIPTION_LENGTH]u8 = undefined;

    const desc = describeSlice("Marketing", 250, 25, &buf);
    try std.testing.expect(std.mem.indexOf(u8, desc, "25%") != null);
}

test "FocusPosition navigation" {
    var pos = FocusPosition{};

    pos.next(3, 2);
    try std.testing.expectEqual(@as(u32, 1), pos.point_idx);
    try std.testing.expectEqual(@as(u32, 0), pos.series_idx);

    pos.next(3, 2);
    pos.next(3, 2);
    try std.testing.expectEqual(@as(u32, 0), pos.point_idx);
    try std.testing.expectEqual(@as(u32, 1), pos.series_idx);

    pos.prev(3, 2);
    try std.testing.expectEqual(@as(u32, 2), pos.point_idx);
    try std.testing.expectEqual(@as(u32, 0), pos.series_idx);
}

test "announceSelection formats position" {
    var buf: [MAX_SUMMARY_LENGTH]u8 = undefined;

    const ann = announceSelection("Revenue", 500, 2, 5, &buf);
    try std.testing.expect(std.mem.indexOf(u8, ann, "3 of 5") != null);
}

test "ChartType roleDescription" {
    try std.testing.expectEqualStrings("bar chart", ChartType.bar.roleDescription());
    try std.testing.expectEqualStrings("scatter plot", ChartType.scatter.roleDescription());
}
