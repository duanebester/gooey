//! Core Data Types for Gooey Charts
//!
//! These types use fixed-capacity arrays to ensure zero dynamic allocation
//! during chart rendering (per CLAUDE.md guidelines). Series capacities are
//! comptime parameters the app declares, each checked against its framework
//! ceiling in `constants.zig`.

const std = @import("std");
const gooey = @import("gooey");
const constants = @import("constants.zig");

pub const Color = gooey.ui.Color;

const point_count_ceiling = constants.point_count_ceiling;
const series_count_ceiling = constants.series_count_ceiling;
const category_count_ceiling = constants.category_count_ceiling;
const slice_count_ceiling = constants.slice_count_ceiling;
const MAX_LABEL_LENGTH = constants.MAX_LABEL_LENGTH;

// =============================================================================
// DataPoint - For continuous X/Y data (line, scatter charts)
// =============================================================================

/// A single data point with continuous X and Y values.
/// Used for line charts, scatter charts, and other continuous data.
pub const DataPoint = struct {
    x: f32,
    y: f32,
    label: [MAX_LABEL_LENGTH]u8 = @splat(0),
    label_len: u8 = 0,

    pub fn init(x: f32, y: f32) DataPoint {
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        std.debug.assert(!std.math.isInf(x) and !std.math.isInf(y));
        return .{ .x = x, .y = y };
    }

    pub fn initLabeled(x: f32, y: f32, label: []const u8) DataPoint {
        std.debug.assert(!std.math.isNan(x) and !std.math.isNan(y));
        std.debug.assert(label.len <= MAX_LABEL_LENGTH);

        var point = DataPoint{ .x = x, .y = y };
        const len: u8 = @intCast(@min(label.len, MAX_LABEL_LENGTH));
        @memcpy(point.label[0..len], label[0..len]);
        point.label_len = len;
        return point;
    }

    pub fn getLabel(self: *const DataPoint) []const u8 {
        return self.label[0..self.label_len];
    }
};

// =============================================================================
// CategoryPoint - For categorical data (bar, pie charts)
// =============================================================================

/// A data point with a categorical label and numeric value.
/// Used for bar charts, pie charts, and other categorical data.
pub const CategoryPoint = struct {
    label: [MAX_LABEL_LENGTH]u8 = @splat(0),
    label_len: u8 = 0,
    value: f32,
    color: ?Color = null,

    pub fn init(label: []const u8, value: f32) CategoryPoint {
        std.debug.assert(!std.math.isNan(value));
        std.debug.assert(label.len <= MAX_LABEL_LENGTH);

        var point = CategoryPoint{ .value = value };
        const len: u8 = @intCast(@min(label.len, MAX_LABEL_LENGTH));
        @memcpy(point.label[0..len], label[0..len]);
        point.label_len = len;
        return point;
    }

    pub fn initColored(label: []const u8, value: f32, color: Color) CategoryPoint {
        var point = init(label, value);
        point.color = color;
        return point;
    }

    pub fn getLabel(self: *const CategoryPoint) []const u8 {
        return self.label[0..self.label_len];
    }
};

// =============================================================================
// Capacities - declared by the app, checked against the framework ceilings
// =============================================================================

/// Capacities of a line or scatter chart: the points each series holds and the
/// series one chart draws. Example: `.{ .point_count_max = 512, .series_count_max = 4 }`.
pub const PointCapacity = struct {
    point_count_max: u32,
    series_count_max: u32,

    /// Fail compilation when a capacity is zero or past its framework ceiling.
    pub fn check(comptime capacity: PointCapacity) void {
        checkCapacity("point_count_max", capacity.point_count_max, point_count_ceiling);
        checkCapacity("series_count_max", capacity.series_count_max, series_count_ceiling);
    }
};

/// Capacities of a bar chart: the categories each series holds and the series
/// one chart draws. Example: `.{ .category_count_max = 12, .series_count_max = 2 }`.
pub const CategoryCapacity = struct {
    category_count_max: u32,
    series_count_max: u32,

    /// Fail compilation when a capacity is zero or past its framework ceiling.
    pub fn check(comptime capacity: CategoryCapacity) void {
        checkCapacity("category_count_max", capacity.category_count_max, category_count_ceiling);
        checkCapacity("series_count_max", capacity.series_count_max, series_count_ceiling);
    }
};

/// Capacity of a pie or donut chart: the slices one chart draws.
/// Example: `.{ .slice_count_max = 8 }`.
pub const SliceCapacity = struct {
    slice_count_max: u32,

    /// Fail compilation when the capacity is zero or past its framework ceiling.
    pub fn check(comptime capacity: SliceCapacity) void {
        checkCapacity("slice_count_max", capacity.slice_count_max, slice_count_ceiling);
    }
};

/// Every capacity is at least one, so empty storage never compiles, and at most
/// its framework ceiling, so no app can size a chart past what the framework
/// was designed and tested for.
fn checkCapacity(comptime field: []const u8, comptime value: u32, comptime ceiling: u32) void {
    if (value < 1) {
        @compileError("chart capacity " ++ field ++ " must be at least 1");
    }
    if (value > ceiling) {
        @compileError(std.fmt.comptimePrint(
            "chart capacity {s} = {d} exceeds its framework ceiling of {d}",
            .{ field, value, ceiling },
        ));
    }
}

/// A full series is a capacity-planning error, not an operating error: the app
/// declared too small a capacity for its data. Fail fast and name the capacity
/// to raise rather than silently drop data.
fn panicSeriesFull(
    name: []const u8,
    capacity: u32,
    requested: usize,
    comptime unit: []const u8,
    comptime field: []const u8,
) noreturn {
    std.debug.assert(name.len <= MAX_LABEL_LENGTH);
    std.debug.assert(requested > 0);
    std.debug.panic("chart series '{s}' full: capacity {d} " ++ unit ++
        ", {d} requested. Raise the chart's " ++ field ++ ".", .{ name, capacity, requested });
}

/// Copy `name` into a fixed label buffer; returns its length.
fn copyName(target: *[MAX_LABEL_LENGTH]u8, name: []const u8) u8 {
    std.debug.assert(name.len <= MAX_LABEL_LENGTH);
    const len: u8 = @intCast(name.len);
    @memcpy(target[0..len], name);
    std.debug.assert(len <= MAX_LABEL_LENGTH);
    return len;
}

// =============================================================================
// Series - Collection of DataPoints for continuous data
// =============================================================================

/// A named series of up to `point_count_max` data points with a color, for
/// multi-series line and scatter charts. Charts expose the matching type as
/// `LineChart(...).Series`, so apps rarely name this directly.
pub fn Series(comptime point_count_max: u32) type {
    checkCapacity("point_count_max", point_count_max, point_count_ceiling);
    return struct {
        name: [MAX_LABEL_LENGTH]u8 = @splat(0),
        name_len: u8 = 0,
        data: [point_count_max]DataPoint = undefined,
        data_len: u32 = 0,
        color: ?Color = null,

        const Self = @This();

        /// The points this series holds: its chart's `point_count_max`.
        pub const capacity: u32 = point_count_max;

        /// Initialize a Series by value: the whole series is copied on return,
        /// so prefer initInPlace() when `@sizeOf(Self)` is large.
        pub fn init(name: []const u8, color: ?Color) Self {
            std.debug.assert(name.len <= MAX_LABEL_LENGTH);
            var series = Self{ .color = color };
            series.name_len = copyName(&series.name, name);
            std.debug.assert(series.data_len == 0);
            return series;
        }

        /// Initialize a Series in place, without a stack temporary of the data.
        /// Use this when initializing into static/global memory or heap.
        pub noinline fn initInPlace(self: *Self, name: []const u8, color: ?Color) void {
            std.debug.assert(name.len <= MAX_LABEL_LENGTH);

            // Field by field, no struct literal: a literal can build a stack temporary.
            self.name = @splat(0);
            self.data = undefined;
            self.data_len = 0;
            self.color = color;
            self.name_len = copyName(&self.name, name);
            std.debug.assert(self.name_len == name.len);
        }

        /// Create a series from a slice of x/y tuples; more points than
        /// `capacity` is a capacity-planning error and panics.
        pub fn fromSlice(
            name: []const u8,
            points: []const struct { x: f32, y: f32 },
            color: ?Color,
        ) Self {
            var series = init(name, color);
            if (points.len > capacity) {
                panicSeriesFull(name, capacity, points.len, "points", "point_count_max");
            }
            for (points, 0..) |p, i| {
                series.data[i] = DataPoint.init(p.x, p.y);
            }
            series.data_len = @intCast(points.len);
            std.debug.assert(series.data_len <= capacity);
            return series;
        }

        pub fn getName(self: *const Self) []const u8 {
            std.debug.assert(self.name_len <= MAX_LABEL_LENGTH);
            return self.name[0..self.name_len];
        }

        pub fn getData(self: *const Self) []const DataPoint {
            std.debug.assert(self.data_len <= capacity);
            return self.data[0..self.data_len];
        }

        /// Append a point; a full series is a capacity-planning error and panics.
        pub fn addPoint(self: *Self, point: DataPoint) void {
            std.debug.assert(self.data_len <= capacity);
            if (self.data_len < capacity) {
                self.data[self.data_len] = point;
                self.data_len += 1;
            } else {
                panicSeriesFull(self.getName(), capacity, 1, "points", "point_count_max");
            }
        }

        /// Find the min/max X values in this series.
        pub fn xExtent(self: *const Self) struct { min: f32, max: f32 } {
            std.debug.assert(self.data_len <= capacity);
            if (self.data_len == 0) return .{ .min = 0, .max = 0 };

            var min: f32 = self.data[0].x;
            var max: f32 = self.data[0].x;

            for (self.data[1..self.data_len]) |p| {
                min = @min(min, p.x);
                max = @max(max, p.x);
            }
            std.debug.assert(min <= max);
            return .{ .min = min, .max = max };
        }

        /// Find the min/max Y values in this series.
        pub fn yExtent(self: *const Self) struct { min: f32, max: f32 } {
            std.debug.assert(self.data_len <= capacity);
            if (self.data_len == 0) return .{ .min = 0, .max = 0 };

            var min: f32 = self.data[0].y;
            var max: f32 = self.data[0].y;

            for (self.data[1..self.data_len]) |p| {
                min = @min(min, p.y);
                max = @max(max, p.y);
            }
            std.debug.assert(min <= max);
            return .{ .min = min, .max = max };
        }
    };
}

// =============================================================================
// CategorySeries - Collection of CategoryPoints
// =============================================================================

/// A named series of up to `category_count_max` category points with a color,
/// for bar charts with one or more series (grouped bars). Charts expose the
/// matching type as `BarChart(...).Series`.
pub fn CategorySeries(comptime category_count_max: u32) type {
    checkCapacity("category_count_max", category_count_max, category_count_ceiling);
    return struct {
        name: [MAX_LABEL_LENGTH]u8 = @splat(0),
        name_len: u8 = 0,
        data: [category_count_max]CategoryPoint = undefined,
        data_len: u32 = 0,
        color: ?Color = null,

        const Self = @This();

        /// The categories this series holds: its chart's `category_count_max`.
        pub const capacity: u32 = category_count_max;

        /// Initialize a CategorySeries by value: the whole series is copied on
        /// return, so prefer initInPlace() when `@sizeOf(Self)` is large.
        pub fn init(name: []const u8, color: ?Color) Self {
            std.debug.assert(name.len <= MAX_LABEL_LENGTH);
            var series = Self{ .color = color };
            series.name_len = copyName(&series.name, name);
            std.debug.assert(series.data_len == 0);
            return series;
        }

        /// Initialize a CategorySeries in place, without a stack temporary.
        /// Use this when initializing into static/global memory or heap.
        pub noinline fn initInPlace(self: *Self, name: []const u8, color: ?Color) void {
            std.debug.assert(name.len <= MAX_LABEL_LENGTH);

            // Field by field, no struct literal: a literal can build a stack temporary.
            self.name = @splat(0);
            self.data = undefined;
            self.data_len = 0;
            self.color = color;
            self.name_len = copyName(&self.name, name);
            std.debug.assert(self.name_len == name.len);
        }

        /// Create a series from a slice of label/value tuples; more categories
        /// than `capacity` is a capacity-planning error and panics.
        pub fn fromSlice(
            name: []const u8,
            points: []const struct { label: []const u8, value: f32 },
            color: ?Color,
        ) Self {
            var series = init(name, color);
            if (points.len > capacity) {
                panicSeriesFull(name, capacity, points.len, "categories", "category_count_max");
            }
            for (points, 0..) |p, i| {
                series.data[i] = CategoryPoint.init(p.label, p.value);
            }
            series.data_len = @intCast(points.len);
            std.debug.assert(series.data_len <= capacity);
            return series;
        }

        pub fn getName(self: *const Self) []const u8 {
            std.debug.assert(self.name_len <= MAX_LABEL_LENGTH);
            return self.name[0..self.name_len];
        }

        pub fn getData(self: *const Self) []const CategoryPoint {
            std.debug.assert(self.data_len <= capacity);
            return self.data[0..self.data_len];
        }

        /// Append a category; a full series is a capacity-planning error and panics.
        pub fn addPoint(self: *Self, point: CategoryPoint) void {
            std.debug.assert(self.data_len <= capacity);
            if (self.data_len < capacity) {
                self.data[self.data_len] = point;
                self.data_len += 1;
            } else {
                panicSeriesFull(self.getName(), capacity, 1, "categories", "category_count_max");
            }
        }

        /// Find the max value in this series (for Y-axis domain).
        pub fn maxValue(self: *const Self) f32 {
            std.debug.assert(self.data_len <= capacity);
            if (self.data_len == 0) return 0;

            var max: f32 = self.data[0].value;
            for (self.data[1..self.data_len]) |p| {
                max = @max(max, p.value);
            }
            std.debug.assert(!std.math.isNan(max));
            return max;
        }

        /// Find the min value in this series.
        pub fn minValue(self: *const Self) f32 {
            std.debug.assert(self.data_len <= capacity);
            if (self.data_len == 0) return 0;

            var min: f32 = self.data[0].value;
            for (self.data[1..self.data_len]) |p| {
                min = @min(min, p.value);
            }
            std.debug.assert(!std.math.isNan(min));
            return min;
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "DataPoint init" {
    const p = DataPoint.init(10.0, 20.0);
    try std.testing.expectEqual(@as(f32, 10.0), p.x);
    try std.testing.expectEqual(@as(f32, 20.0), p.y);
    try std.testing.expectEqual(@as(u8, 0), p.label_len);
}

test "DataPoint labeled" {
    const p = DataPoint.initLabeled(5.0, 15.0, "Point A");
    try std.testing.expectEqual(@as(f32, 5.0), p.x);
    try std.testing.expectEqualStrings("Point A", p.getLabel());
}

test "CategoryPoint init" {
    const p = CategoryPoint.init("January", 42.5);
    try std.testing.expectEqualStrings("January", p.getLabel());
    try std.testing.expectEqual(@as(f32, 42.5), p.value);
    try std.testing.expect(p.color == null);
}

test "Series addPoint" {
    // Heap-allocate the ceiling-sized Series (~304KB - too large for stack per CLAUDE.md).
    const series = try std.testing.allocator.create(Series(point_count_ceiling));
    defer std.testing.allocator.destroy(series);

    series.initInPlace("Revenue", Color.hex(0xff0000));
    series.addPoint(DataPoint.init(0, 10));
    series.addPoint(DataPoint.init(1, 20));
    series.addPoint(DataPoint.init(2, 15));

    try std.testing.expectEqualStrings("Revenue", series.getName());
    try std.testing.expectEqual(@as(u32, 3), series.data_len);

    const extent = series.yExtent();
    try std.testing.expectEqual(@as(f32, 10), extent.min);
    try std.testing.expectEqual(@as(f32, 20), extent.max);
}

test "Series fills exactly its capacity" {
    // Goal: the last slot below the capacity is usable, by both fromSlice and
    // addPoint. One more point panics: the `chart-points` mode of
    // src/testing/fail_fast_check.zig checks that in a child process.
    const Small = Series(4);
    const full = Small.fromSlice("Full", &.{
        .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 3 }, .{ .x = 3, .y = 4 },
    }, null);
    try std.testing.expectEqual(Small.capacity, full.data_len);
    try std.testing.expectEqual(@as(f32, 4), full.getData()[3].y);

    var grown = Small.init("Grown", null);
    for (0..Small.capacity) |index| {
        grown.addPoint(DataPoint.init(@floatFromInt(index), 1));
    }
    try std.testing.expectEqual(Small.capacity, grown.data_len);
    try std.testing.expectEqual(@as(f32, 3), grown.xExtent().max);
}

test "CategorySeries addPoint" {
    // Heap-allocate the ceiling-sized CategorySeries (~23KB) like an app would.
    const series = try std.testing.allocator.create(CategorySeries(category_count_ceiling));
    defer std.testing.allocator.destroy(series);

    series.initInPlace("Sales", Color.hex(0x0000ff));
    series.addPoint(CategoryPoint.init("Q1", 30));
    series.addPoint(CategoryPoint.init("Q2", 45));
    series.addPoint(CategoryPoint.init("Q3", 28));

    try std.testing.expectEqualStrings("Sales", series.getName());
    try std.testing.expectEqual(@as(u32, 3), series.data_len);
    try std.testing.expectEqual(@as(f32, 45), series.maxValue());
    try std.testing.expectEqual(@as(f32, 28), series.minValue());
}

test "CategorySeries fills exactly its capacity" {
    // Goal: the last category below the capacity is usable, by fromSlice and addPoint.
    const Small = CategorySeries(2);
    const full = Small.fromSlice("Full", &.{
        .{ .label = "A", .value = 1 }, .{ .label = "B", .value = 2 },
    }, null);
    try std.testing.expectEqual(Small.capacity, full.data_len);
    try std.testing.expectEqualStrings("B", full.getData()[1].getLabel());

    var grown = Small.init("Grown", null);
    grown.addPoint(CategoryPoint.init("A", 5));
    grown.addPoint(CategoryPoint.init("B", 7));
    try std.testing.expectEqual(Small.capacity, grown.data_len);
    try std.testing.expectEqual(@as(f32, 7), grown.maxValue());
}

test "series sizes follow their capacity" {
    // Goal: storage scales with the app's capacity, not a global constant.
    // Methodology: the data array dominates, so a series is its capacity times
    // the point size plus a small fixed header (name, lengths, color).
    const header_bytes_max = 128;
    try std.testing.expect(@sizeOf(DataPoint) <= 80);
    try std.testing.expect(@sizeOf(CategoryPoint) <= 96);

    inline for (.{ 8, point_count_ceiling }) |capacity| {
        const data_bytes = capacity * @sizeOf(DataPoint);
        try std.testing.expect(@sizeOf(Series(capacity)) >= data_bytes);
        try std.testing.expect(@sizeOf(Series(capacity)) <= data_bytes + header_bytes_max);
    }
    inline for (.{ 8, category_count_ceiling }) |capacity| {
        const data_bytes = capacity * @sizeOf(CategoryPoint);
        try std.testing.expect(@sizeOf(CategorySeries(capacity)) >= data_bytes);
        try std.testing.expect(@sizeOf(CategorySeries(capacity)) <= data_bytes + header_bytes_max);
    }
    // The ceiling series is the ~300 KiB the capacities exist to avoid.
    try std.testing.expect(@sizeOf(Series(point_count_ceiling)) > 300_000);
    try std.testing.expect(@sizeOf(Series(8)) < 1_024);
}

test "Series initInPlace" {
    const series = try std.testing.allocator.create(Series(point_count_ceiling));
    defer std.testing.allocator.destroy(series);

    series.initInPlace("Test", Color.hex(0xff0000));

    try std.testing.expectEqualStrings("Test", series.getName());
    try std.testing.expectEqual(@as(u32, 0), series.data_len);
}

test "CategorySeries initInPlace" {
    const series = try std.testing.allocator.create(CategorySeries(category_count_ceiling));
    defer std.testing.allocator.destroy(series);

    series.initInPlace("Test", Color.hex(0x00ff00));

    try std.testing.expectEqualStrings("Test", series.getName());
    try std.testing.expectEqual(@as(u32, 0), series.data_len);
}
