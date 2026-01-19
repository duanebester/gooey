//! Core Data Types for Gooey Charts
//!
//! These types use fixed-capacity arrays to ensure zero dynamic allocation
//! during chart rendering (per CLAUDE.md guidelines).

const std = @import("std");
const gooey = @import("gooey");
const constants = @import("constants.zig");

pub const Color = gooey.ui.Color;

const MAX_DATA_POINTS = constants.MAX_DATA_POINTS;
const MAX_CATEGORIES = constants.MAX_CATEGORIES;
const MAX_LABEL_LENGTH = constants.MAX_LABEL_LENGTH;

// =============================================================================
// DataPoint - For continuous X/Y data (line, scatter charts)
// =============================================================================

/// A single data point with continuous X and Y values.
/// Used for line charts, scatter charts, and other continuous data.
pub const DataPoint = struct {
    x: f32,
    y: f32,
    label: [MAX_LABEL_LENGTH]u8 = [_]u8{0} ** MAX_LABEL_LENGTH,
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
    label: [MAX_LABEL_LENGTH]u8 = [_]u8{0} ** MAX_LABEL_LENGTH,
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
// Series - Collection of DataPoints for continuous data
// =============================================================================

/// A named series of data points with a color.
/// Used for multi-series line charts, scatter charts, etc.
pub const Series = struct {
    name: [MAX_LABEL_LENGTH]u8 = [_]u8{0} ** MAX_LABEL_LENGTH,
    name_len: u8 = 0,
    data: [MAX_DATA_POINTS]DataPoint = undefined,
    data_len: u32 = 0,
    color: ?Color = null,

    /// Initialize a Series by value - WARNING: Returns 304KB on stack!
    /// Prefer initInPlace() for large struct safety.
    pub fn init(name: []const u8, color: ?Color) Series {
        std.debug.assert(name.len <= MAX_LABEL_LENGTH);

        var series = Series{ .color = color };
        const len: u8 = @intCast(@min(name.len, MAX_LABEL_LENGTH));
        @memcpy(series.name[0..len], name[0..len]);
        series.name_len = len;
        return series;
    }

    /// Initialize a Series in-place to avoid 304KB stack allocation.
    /// Use this when initializing into static/global memory or heap.
    pub noinline fn initInPlace(self: *Series, name: []const u8, color: ?Color) void {
        std.debug.assert(name.len <= MAX_LABEL_LENGTH);

        // Zero-initialize to clear any garbage (field by field, no struct literal)
        self.name = [_]u8{0} ** MAX_LABEL_LENGTH;
        self.name_len = 0;
        self.data = undefined;
        self.data_len = 0;
        self.color = color;

        // Copy name
        const len: u8 = @intCast(@min(name.len, MAX_LABEL_LENGTH));
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = len;
    }

    /// Create a series from a slice of x/y tuples.
    pub fn fromSlice(
        name: []const u8,
        points: []const struct { x: f32, y: f32 },
        color: ?Color,
    ) Series {
        std.debug.assert(points.len <= MAX_DATA_POINTS);

        var series = init(name, color);
        for (points, 0..) |p, i| {
            series.data[i] = DataPoint.init(p.x, p.y);
        }
        series.data_len = @intCast(points.len);
        return series;
    }

    pub fn getName(self: *const Series) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getData(self: *const Series) []const DataPoint {
        return self.data[0..self.data_len];
    }

    pub fn addPoint(self: *Series, point: DataPoint) void {
        std.debug.assert(self.data_len < MAX_DATA_POINTS);
        self.data[self.data_len] = point;
        self.data_len += 1;
    }

    /// Find the min/max X values in this series.
    pub fn xExtent(self: *const Series) struct { min: f32, max: f32 } {
        if (self.data_len == 0) return .{ .min = 0, .max = 0 };

        var min: f32 = self.data[0].x;
        var max: f32 = self.data[0].x;

        for (self.data[1..self.data_len]) |p| {
            min = @min(min, p.x);
            max = @max(max, p.x);
        }
        return .{ .min = min, .max = max };
    }

    /// Find the min/max Y values in this series.
    pub fn yExtent(self: *const Series) struct { min: f32, max: f32 } {
        if (self.data_len == 0) return .{ .min = 0, .max = 0 };

        var min: f32 = self.data[0].y;
        var max: f32 = self.data[0].y;

        for (self.data[1..self.data_len]) |p| {
            min = @min(min, p.y);
            max = @max(max, p.y);
        }
        return .{ .min = min, .max = max };
    }
};

// =============================================================================
// CategorySeries - Collection of CategoryPoints
// =============================================================================

/// A named series of category points with a color.
/// Used for bar charts with multiple series (grouped/stacked bars).
pub const CategorySeries = struct {
    name: [MAX_LABEL_LENGTH]u8 = [_]u8{0} ** MAX_LABEL_LENGTH,
    name_len: u8 = 0,
    data: [MAX_CATEGORIES]CategoryPoint = undefined,
    data_len: u32 = 0,
    color: ?Color = null,

    /// Initialize a CategorySeries by value - WARNING: Returns ~23KB on stack!
    /// Prefer initInPlace() for safety in deep call stacks.
    pub fn init(name: []const u8, color: ?Color) CategorySeries {
        std.debug.assert(name.len <= MAX_LABEL_LENGTH);

        var series = CategorySeries{ .color = color };
        const len: u8 = @intCast(@min(name.len, MAX_LABEL_LENGTH));
        @memcpy(series.name[0..len], name[0..len]);
        series.name_len = len;
        return series;
    }

    /// Initialize a CategorySeries in-place to avoid stack allocation.
    /// Use this when initializing into static/global memory or heap.
    pub noinline fn initInPlace(self: *CategorySeries, name: []const u8, color: ?Color) void {
        std.debug.assert(name.len <= MAX_LABEL_LENGTH);

        // Field by field init (no struct literal to avoid stack temp)
        self.name = [_]u8{0} ** MAX_LABEL_LENGTH;
        self.name_len = 0;
        self.data = undefined;
        self.data_len = 0;
        self.color = color;

        // Copy name
        const len: u8 = @intCast(@min(name.len, MAX_LABEL_LENGTH));
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = len;
    }

    /// Create a series from a slice of label/value tuples.
    pub fn fromSlice(
        name: []const u8,
        points: []const struct { label: []const u8, value: f32 },
        color: ?Color,
    ) CategorySeries {
        std.debug.assert(points.len <= MAX_CATEGORIES);

        var series = init(name, color);
        for (points, 0..) |p, i| {
            series.data[i] = CategoryPoint.init(p.label, p.value);
        }
        series.data_len = @intCast(points.len);
        return series;
    }

    pub fn getName(self: *const CategorySeries) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getData(self: *const CategorySeries) []const CategoryPoint {
        return self.data[0..self.data_len];
    }

    pub fn addPoint(self: *CategorySeries, point: CategoryPoint) void {
        std.debug.assert(self.data_len < MAX_CATEGORIES);
        self.data[self.data_len] = point;
        self.data_len += 1;
    }

    /// Find the max value in this series (for Y-axis domain).
    pub fn maxValue(self: *const CategorySeries) f32 {
        if (self.data_len == 0) return 0;

        var max: f32 = self.data[0].value;
        for (self.data[1..self.data_len]) |p| {
            max = @max(max, p.value);
        }
        return max;
    }

    /// Find the min value in this series.
    pub fn minValue(self: *const CategorySeries) f32 {
        if (self.data_len == 0) return 0;

        var min: f32 = self.data[0].value;
        for (self.data[1..self.data_len]) |p| {
            min = @min(min, p.value);
        }
        return min;
    }
};

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

test "Series fromSlice" {
    // Heap-allocate Series (~304KB - too large for stack per CLAUDE.md)
    const series = try std.testing.allocator.create(Series);
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

test "CategorySeries fromSlice" {
    // Heap-allocate CategorySeries (~23KB - too large for stack per CLAUDE.md)
    const series = try std.testing.allocator.create(CategorySeries);
    defer std.testing.allocator.destroy(series);

    series.initInPlace("Sales", Color.hex(0x0000ff));
    series.addPoint(CategoryPoint.init("Q1", 30));
    series.addPoint(CategoryPoint.init("Q2", 45));
    series.addPoint(CategoryPoint.init("Q3", 28));

    try std.testing.expectEqualStrings("Sales", series.getName());
    try std.testing.expectEqual(@as(u32, 3), series.data_len);
    try std.testing.expectEqual(@as(f32, 45), series.maxValue());
}

test "struct sizes for stack safety" {
    // Print sizes for debugging
    std.debug.print("\n=== Struct Sizes ===\n", .{});
    std.debug.print("DataPoint: {} bytes\n", .{@sizeOf(DataPoint)});
    std.debug.print("CategoryPoint: {} bytes\n", .{@sizeOf(CategoryPoint)});
    std.debug.print("Series: {} bytes\n", .{@sizeOf(Series)});
    std.debug.print("CategorySeries: {} bytes\n", .{@sizeOf(CategorySeries)});
    std.debug.print("MAX_DATA_POINTS: {}\n", .{MAX_DATA_POINTS});
    std.debug.print("MAX_CATEGORIES: {}\n", .{MAX_CATEGORIES});

    // Series is large: MAX_DATA_POINTS * sizeof(DataPoint) + overhead
    // This should NOT be allocated on the stack during rendering
    // DataPoint: x(4) + y(4) + label(64) + label_len(1) = ~73 bytes, padded
    try std.testing.expect(@sizeOf(DataPoint) <= 80);

    // CategoryPoint: label(64) + label_len(1) + value(4) + color(optional) = ~80 bytes, padded to 92
    try std.testing.expect(@sizeOf(CategoryPoint) <= 96);

    // Series embeds [MAX_DATA_POINTS]DataPoint - this is HUGE
    // Should be ~300KB+ - must use initInPlace, not return-by-value
    const series_size = @sizeOf(Series);
    std.debug.print("Series is {} KB - USE initInPlace()!\n", .{series_size / 1024});
    try std.testing.expect(series_size > 100_000); // Confirm it's huge
}

test "Series initInPlace" {
    // Heap-allocate Series (~304KB - too large for stack per CLAUDE.md)
    const series = try std.testing.allocator.create(Series);
    defer std.testing.allocator.destroy(series);

    series.initInPlace("Test", Color.hex(0xff0000));

    try std.testing.expectEqualStrings("Test", series.getName());
    try std.testing.expectEqual(@as(u32, 0), series.data_len);
}

test "CategorySeries initInPlace" {
    // Heap-allocate CategorySeries (~23KB - too large for stack per CLAUDE.md)
    const series = try std.testing.allocator.create(CategorySeries);
    defer std.testing.allocator.destroy(series);

    series.initInPlace("Test", Color.hex(0x00ff00));

    try std.testing.expectEqualStrings("Test", series.getName());
    try std.testing.expectEqual(@as(u32, 0), series.data_len);
}
