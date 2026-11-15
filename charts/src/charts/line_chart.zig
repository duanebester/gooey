//! Line Chart Component for Gooey Charts
//!
//! Renders continuous X/Y data as connected lines with optional point markers
//! and area fill. Supports multiple series with different colors.
//!
//! NOTE: LineChart stores a *slice* to externally-owned series data.
//! The caller is responsible for ensuring the data outlives the chart.
//! This avoids embedding large arrays on the stack (per CLAUDE.md).

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

const Series = types.Series;
const DataPoint = types.DataPoint;
const ChartTheme = theme_mod.ChartTheme;

pub const Color = paint.Color;
pub const Painter = paint.Painter;
// NOTE: Path is ~70KB on the stack, so we avoid it and use strokeLine instead

const MAX_SERIES = constants.MAX_SERIES;
const MAX_DATA_POINTS = constants.MAX_DATA_POINTS;
const LOD_THRESHOLD = constants.LOD_THRESHOLD;

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

    /// Render the line chart, offset by the paint element's bounds.
    pub fn render(self: *const LineChart, painter: *Painter) void {
        // Assertions at API boundary
        std.debug.assert(self.data.len > 0);
        std.debug.assert(self.width > 0 and self.height > 0);

        // Calculate inner bounds
        const inner_x = painter.bounds.x + self.margin_left;
        const inner_y = painter.bounds.y + self.margin_top;
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
            self.drawGrid(painter, x_scale, y_scale, inner_x, inner_y, inner_width, inner_height);
        }

        // Draw area fills first (behind lines)
        if (self.show_area) {
            self.drawAreas(painter, x_scale, y_scale, inner_y + inner_height);
        }

        // Draw lines
        self.drawLines(painter, x_scale, y_scale);

        // Draw point markers (on top of lines)
        if (self.show_points) {
            self.drawPoints(painter, x_scale, y_scale);
        }

        // Axes on top.
        if (self.show_x_axis) {
            const x_opts = Axis.themed(self.x_axis_opts, .bottom, self.chart_theme);
            Axis.drawLinear(painter, x_scale, inner_x, inner_y + inner_height, x_opts);
        }

        if (self.show_y_axis) {
            const y_opts = Axis.themed(self.y_axis_opts, .left, self.chart_theme);
            Axis.drawLinear(painter, y_scale, inner_x, inner_y, y_opts);
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
        painter: *Painter,
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
            painter,
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

    /// Fill the area between a series' line and `baseline` as one triangle
    /// mesh: two triangles per segment, under the same projected (and
    /// LTTB-decimated) points the line draws, so the fill meets the line.
    /// Neighbouring segments share their vertical edge bit for bit, and the
    /// two triangles of a segment share its diagonal, so the renderers
    /// classify those edges as interior (`platform/mesh_edges.zig`) and the
    /// fill tiles without the anti-aliased seams that abutting quads leave.
    fn drawSeriesArea(
        self: *const LineChart,
        painter: *Painter,
        series: *const Series,
        x_scale: LinearScale,
        y_scale: LinearScale,
        baseline: f32,
        color: Color,
    ) void {
        std.debug.assert(series.data_len >= 2);
        std.debug.assert(!std.math.isNan(baseline));
        var points: [MAX_DATA_POINTS][2]f32 = undefined;
        const count = scale_mod.projectSeries(series, x_scale, y_scale, self.lodPoints(), &points);
        std.debug.assert(count <= MAX_DATA_POINTS);
        var index: u32 = 1;
        while (index < count) : (index += 1) {
            var triangles: [area_segment_points_max][2]f32 = undefined;
            const used = areaSegment(&triangles, points[index - 1], points[index], baseline);
            if (used > 0) painter.triangles(triangles[0..used], color);
        }
    }

    /// Draw all series lines.
    fn drawLines(
        self: *const LineChart,
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

    /// Draw a series as one polyline, decimated with LTTB past `lod_target_points`.
    fn drawSeriesLine(
        self: *const LineChart,
        painter: *Painter,
        series: *const Series,
        x_scale: LinearScale,
        y_scale: LinearScale,
        color: Color,
    ) void {
        std.debug.assert(series.data_len >= 2);
        var points: [MAX_DATA_POINTS][2]f32 = undefined;
        const count = scale_mod.projectSeries(series, x_scale, y_scale, self.lodPoints(), &points);
        if (count >= 2) painter.polyline(points[0..count], self.line_width, color);
    }

    /// Draw each series' markers as one point cloud, after every line.
    fn drawPoints(
        self: *const LineChart,
        painter: *Painter,
        x_scale: LinearScale,
        y_scale: LinearScale,
    ) void {
        std.debug.assert(self.data.len > 0);
        std.debug.assert(self.point_radius > 0);
        var centers: [MAX_DATA_POINTS][2]f32 = undefined;
        for (self.data, 0..) |*series, series_idx| {
            if (series.data_len == 0) continue;
            const count = scale_mod.projectSeries(
                series,
                x_scale,
                y_scale,
                self.lodPoints(),
                &centers,
            );
            const color = self.getSeriesColor(series, series_idx);
            painter.pointCloud(centers[0..count], self.point_radius, color);
        }
    }

    /// The point count series decimate to, or null with LOD off.
    fn lodPoints(self: *const LineChart) ?u32 {
        return if (self.enable_lod) self.lod_target_points else null;
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

/// A segment's area is a trapezoid of two triangles, or one triangle on the
/// side of a crossing that lies above the baseline.
const area_segment_points_max: u32 = 6;

/// The triangles filling the area between the segment `from`-`to` and the
/// horizontal `baseline` (screen y grows down, so "above" is a smaller y),
/// written to `out`; returns their point count, a multiple of three. A
/// segment that crosses the baseline keeps only its part above it, and one
/// at or below it fills nothing, and so does one that runs backwards in x.
/// Triangles wind clockwise on screen.
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
    // One end lies above the baseline and the other below: cut at the crossing.
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

test "areaSegment tiles a trapezoid, cuts at the baseline, and skips the rest" {
    // Goal: the area under a segment is covered exactly once, and only above
    // the baseline. Methodology: the triangle areas must sum to the area the
    // segment encloses with the baseline, worked out by hand, and a segment
    // crossing the baseline must keep the side above it, cut at its crossing.
    var out: [area_segment_points_max][2]f32 = undefined;
    // From 10 to 30 above a baseline at 100, 40 wide: (10 + 30) / 2 * 40.
    var count = areaSegment(&out, .{ 0, 90 }, .{ 40, 70 }, 100);
    try std.testing.expectEqual(@as(u32, 6), count);
    try std.testing.expectEqual(@as(f32, 800), trianglesArea(out[0..count]));
    // The two triangles share the vertical edges' corners exactly.
    try std.testing.expectEqual([2]f32{ 40, 100 }, out[2]);
    try std.testing.expectEqual([2]f32{ 0, 100 }, out[5]);
    // One end on the baseline: one triangle, 20 * 10 / 2.
    count = areaSegment(&out, .{ 0, 100 }, .{ 10, 80 }, 100);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual(@as(f32, 100), trianglesArea(out[0..count]));
    // 20 above, then 60 below: crosses at a quarter of 40 px, so 10 * 20 / 2.
    count = areaSegment(&out, .{ 0, 80 }, .{ 40, 160 }, 100);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual([2]f32{ 10, 100 }, out[1]);
    try std.testing.expectEqual(@as(f32, 100), trianglesArea(out[0..count]));
    // The mirror image keeps the other end.
    count = areaSegment(&out, .{ 0, 160 }, .{ 40, 80 }, 100);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual([2]f32{ 30, 100 }, out[0]);
    try std.testing.expectEqual(@as(f32, 100), trianglesArea(out[0..count]));
    // At or below the baseline, vertical, or backwards: nothing.
    try std.testing.expectEqual(@as(u32, 0), areaSegment(&out, .{ 0, 100 }, .{ 40, 120 }, 100));
    try std.testing.expectEqual(@as(u32, 0), areaSegment(&out, .{ 5, 50 }, .{ 5, 60 }, 100));
    try std.testing.expectEqual(@as(u32, 0), areaSegment(&out, .{ 40, 50 }, .{ 0, 60 }, 100));
}

/// The summed areas of a triangle list, each counted positive.
fn trianglesArea(points: []const [2]f32) f32 {
    std.debug.assert(points.len % 3 == 0);
    var total: f32 = 0;
    var index: usize = 0;
    while (index < points.len) : (index += 3) {
        const a = points[index];
        const b = points[index + 1];
        const c = points[index + 2];
        const cross = (b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1]);
        // Clockwise on screen, where y grows down, is a positive cross product.
        std.debug.assert(cross >= 0);
        total += cross / 2;
    }
    return total;
}
