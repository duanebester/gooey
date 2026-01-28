//! Pie/Donut Chart Component for Gooey Charts
//!
//! Renders categorical data as circular slices where each slice's angle
//! is proportional to its value relative to the total.
//!
//! Set inner_radius > 0 to create a donut chart with a center hole.
//!
//! NOTE: PieChart stores a *slice* to externally-owned category point data.
//! The caller is responsible for ensuring the data outlives the chart.
//! This avoids embedding large arrays on the stack (per CLAUDE.md).

const std = @import("std");
const builtin = @import("builtin");
const gooey = @import("gooey");
const constants = @import("../constants.zig");
const types = @import("../types.zig");
const theme_mod = @import("../theme.zig");
const a11y = @import("../accessibility.zig");

const CategoryPoint = types.CategoryPoint;
const ChartTheme = theme_mod.ChartTheme;

pub const Color = gooey.ui.Color;
pub const DrawContext = gooey.ui.DrawContext;

const MAX_CATEGORIES = constants.MAX_CATEGORIES;
const MAX_SLICES = 64; // Pie charts rarely have more than this
const ENABLE_PERF_LOGGING = constants.ENABLE_PERF_LOGGING;
const PERF_WARNING_THRESHOLD_NS = constants.PERF_WARNING_THRESHOLD_NS;
const ARC_SEGMENTS_PER_FULL_CIRCLE = 64; // Segments for smooth arcs

// =============================================================================
// Default Color Palette (imported from theme.zig - single source of truth)
// =============================================================================

pub const default_palette = theme_mod.google_palette;

// =============================================================================
// PieChart
// =============================================================================

pub const PieChart = struct {
    // Type declarations must come before fields
    pub const LabelPosition = enum {
        inside,
        outside,
        none,
    };

    /// Data - stored as a slice to avoid large stack allocation.
    /// The caller owns the underlying data; chart just references it.
    data: []const CategoryPoint,

    // Dimensions
    width: f32 = 300,
    height: f32 = 300,

    // Donut configuration
    /// Inner radius ratio (0 = full pie, 0.5 = half-size hole, etc.)
    /// This is a ratio of the outer radius, not absolute pixels.
    inner_radius_ratio: f32 = 0,

    // Styling
    /// Gap between slices in pixels. Recommended: 2-4 pixels.
    /// - For donuts: creates parallel edges for consistent visual spacing.
    /// - For full pies: creates an "exploded" effect where slices are offset outward.
    /// When set, takes precedence over pad_angle.
    gap_pixels: ?f32 = null,
    /// Gap between slices in radians (0.02 ≈ 1 degree). Only used if gap_pixels is null.
    /// Note: Angular gaps appear narrower near center and wider at edge.
    pad_angle: f32 = 0.02,
    /// Starting angle in radians (0 = 3 o'clock, -π/2 = 12 o'clock)
    start_angle: f32 = -std.math.pi / 2.0,

    // Labels
    show_labels: bool = false,
    label_position: LabelPosition = .outside,

    // Theme (optional - uses default colors if null)
    chart_theme: ?*const ChartTheme = null,

    // Accessibility
    accessible_title: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    // ==========================================================================
    // Initialization
    // ==========================================================================

    /// Create a pie chart from a slice of category points.
    /// The slice must outlive the chart - data is NOT copied.
    pub fn init(data: []const CategoryPoint) PieChart {
        std.debug.assert(data.len > 0);
        std.debug.assert(data.len <= MAX_SLICES);
        return .{ .data = data };
    }

    // ==========================================================================
    // Accessors
    // ==========================================================================

    pub fn sliceCount(self: *const PieChart) u32 {
        return @intCast(self.data.len);
    }

    /// Returns true if this is a donut chart (has inner hole).
    pub fn isDonut(self: *const PieChart) bool {
        return self.inner_radius_ratio > 0;
    }

    // ==========================================================================
    // Accessibility
    // ==========================================================================

    /// Get accessibility information for this chart.
    /// Use with `charts.describeChart()` to generate screen reader descriptions.
    pub fn getAccessibilityInfo(self: *const PieChart) a11y.ChartInfo {
        var info = a11y.infoFromCategoryPoints(self.data, self.isDonut());
        info.title = self.accessible_title;
        info.description = self.accessible_description;
        return info;
    }

    /// Generate a full accessible description for this chart.
    /// Returns a slice into the provided buffer.
    pub fn describe(self: *const PieChart, buf: []u8) []const u8 {
        const info = self.getAccessibilityInfo();
        return a11y.describe(&info, buf);
    }

    /// Generate a short summary for tooltips or live regions.
    pub fn summarize(self: *const PieChart, buf: []u8) []const u8 {
        const info = self.getAccessibilityInfo();
        return a11y.summarize(&info, buf);
    }

    // ==========================================================================
    // Rendering
    // ==========================================================================

    /// Render the pie chart to a DrawContext.
    pub fn render(self: *const PieChart, ctx: *DrawContext) void {
        // Performance timing (Phase 4 optimization)
        const start_time = if (ENABLE_PERF_LOGGING) std.time.nanoTimestamp() else 0;
        defer if (ENABLE_PERF_LOGGING) {
            const elapsed = std.time.nanoTimestamp() - start_time;
            if (elapsed > PERF_WARNING_THRESHOLD_NS) {
                if (builtin.mode == .Debug) {
                    std.log.warn("PieChart render: {d:.2}ms exceeds 8ms budget", .{
                        @as(f64, @floatFromInt(elapsed)) / 1_000_000.0,
                    });
                }
            }
        };

        // Assertions at API boundary (per CLAUDE.md: minimum 2 per function)
        std.debug.assert(self.data.len > 0);
        std.debug.assert(self.width > 0 and self.height > 0);
        std.debug.assert(self.inner_radius_ratio >= 0 and self.inner_radius_ratio < 1);

        // Calculate center and radius
        const cx = self.width / 2.0;
        const cy = self.height / 2.0;
        const outer_radius = @min(cx, cy) * 0.85; // Leave margin for labels
        const inner_radius = outer_radius * self.inner_radius_ratio;

        std.debug.assert(outer_radius > 0);

        // Calculate total value for angle proportions
        const total = self.calculateTotal();
        if (total <= 0) return; // Nothing to draw

        // Draw slices
        self.drawSlices(ctx, cx, cy, outer_radius, inner_radius, total);

        // Draw labels if enabled
        if (self.show_labels and self.label_position != .none) {
            self.drawLabels(ctx, cx, cy, outer_radius, inner_radius, total);
        }
    }

    // ==========================================================================
    // Private Helpers
    // ==========================================================================

    /// Calculate the total of all values.
    fn calculateTotal(self: *const PieChart) f32 {
        var total: f32 = 0;
        for (self.data) |point| {
            if (point.value > 0) {
                total += point.value;
            }
        }
        return total;
    }

    /// Draw all pie slices.
    fn drawSlices(
        self: *const PieChart,
        ctx: *DrawContext,
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

        // For donuts: use parallel edge gaps (different angular offset at inner vs outer)
        // For full pies: use exploded effect (offset slice center along bisector)
        const half_pad_outer: f32 = if (self.gap_pixels) |gap| gap / (2.0 * outer_radius) else self.pad_angle / 2.0;
        const half_pad_inner: f32 = if (is_donut)
            (if (self.gap_pixels) |gap| gap / (2.0 * inner_radius) else self.pad_angle / 2.0)
        else
            half_pad_outer; // Not used for full pies

        // Explode offset for full pies (half the gap on each side = full gap between slices)
        const explode_offset: f32 = if (!is_donut and self.gap_pixels != null) self.gap_pixels.? else 0;

        for (self.data, 0..) |point, idx| {
            if (point.value <= 0) continue;

            // Calculate slice angle
            const slice_angle = (point.value / total) * 2.0 * std.math.pi;

            // Skip tiny slices
            if (slice_angle < 0.01) {
                current_angle += slice_angle;
                continue;
            }

            // Get color for this slice: point color > theme palette > default palette
            const color = point.color orelse
                (if (self.chart_theme) |t| t.paletteColor(idx) else default_palette[idx % default_palette.len]);

            // Calculate exploded center for full pies
            const bisector = current_angle + slice_angle / 2.0;
            const slice_cx = cx + explode_offset * @cos(bisector);
            const slice_cy = cy + explode_offset * @sin(bisector);

            // Draw the slice
            self.drawSlice(
                ctx,
                slice_cx,
                slice_cy,
                outer_radius - explode_offset, // Reduce radius to keep overall size
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

    /// Draw a single pie slice using triangle fan (avoids Path tessellation limits).
    /// Uses direct fillTriangle calls for efficient GPU rendering.
    /// Supports parallel gap edges via different angular offsets at inner vs outer radius.
    fn drawSlice(
        self: *const PieChart,
        ctx: *DrawContext,
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

        // Effective angles at outer edge (with outer padding)
        const outer_start = base_angle + half_pad_outer;
        const outer_end = base_angle + slice_angle - half_pad_outer;

        // Calculate arc span at outer edge for segment count
        var angle_span = outer_end - outer_start;
        if (angle_span < 0) angle_span += 2.0 * std.math.pi;
        if (angle_span <= 0) return; // Slice too small after padding

        // Number of segments proportional to arc span
        const segments: u32 = @max(2, @as(u32, @intFromFloat(
            @ceil(angle_span / (2.0 * std.math.pi) * @as(f32, ARC_SEGMENTS_PER_FULL_CIRCLE)),
        )));

        if (inner_r > 0.5) {
            // Donut slice: draw as quad strip with parallel edges
            // Inner and outer arcs use different angle ranges for uniform gap width
            const inner_start = base_angle + half_pad_inner;
            const inner_end = base_angle + slice_angle - half_pad_inner;

            const outer_step = (outer_end - outer_start) / @as(f32, @floatFromInt(segments));
            const inner_step = (inner_end - inner_start) / @as(f32, @floatFromInt(segments));

            var i: u32 = 0;
            while (i < segments) : (i += 1) {
                const fi = @as(f32, @floatFromInt(i));
                const fi1 = @as(f32, @floatFromInt(i + 1));

                // Outer edge angles
                const ao1 = outer_start + fi * outer_step;
                const ao2 = outer_start + fi1 * outer_step;
                // Inner edge angles (different progression for parallel gap)
                const ai1 = inner_start + fi * inner_step;
                const ai2 = inner_start + fi1 * inner_step;

                // Four corners of quad
                const outer1_x = cx + outer_r * @cos(ao1);
                const outer1_y = cy + outer_r * @sin(ao1);
                const outer2_x = cx + outer_r * @cos(ao2);
                const outer2_y = cy + outer_r * @sin(ao2);
                const inner1_x = cx + inner_r * @cos(ai1);
                const inner1_y = cy + inner_r * @sin(ai1);
                const inner2_x = cx + inner_r * @cos(ai2);
                const inner2_y = cy + inner_r * @sin(ai2);

                // Two triangles to form quad
                ctx.fillTriangle(inner1_x, inner1_y, outer1_x, outer1_y, outer2_x, outer2_y, color);
                ctx.fillTriangle(inner1_x, inner1_y, outer2_x, outer2_y, inner2_x, inner2_y, color);
            }
        } else {
            // Full pie slice: triangle fan from center
            // Note: For exploded pies, cx/cy are already offset by caller
            const outer_step = (outer_end - outer_start) / @as(f32, @floatFromInt(segments));

            var i: u32 = 0;
            while (i < segments) : (i += 1) {
                const fi = @as(f32, @floatFromInt(i));
                const fi1 = @as(f32, @floatFromInt(i + 1));

                const a1 = outer_start + fi * outer_step;
                const a2 = outer_start + fi1 * outer_step;

                const x1 = cx + outer_r * @cos(a1);
                const y1 = cy + outer_r * @sin(a1);
                const x2 = cx + outer_r * @cos(a2);
                const y2 = cy + outer_r * @sin(a2);

                ctx.fillTriangle(cx, cy, x1, y1, x2, y2, color);
            }
        }
    }

    /// Draw labels for pie slices.
    fn drawLabels(
        self: *const PieChart,
        ctx: *DrawContext,
        cx: f32,
        cy: f32,
        outer_radius: f32,
        inner_radius: f32,
        total: f32,
    ) void {
        std.debug.assert(total > 0);

        var current_angle = self.start_angle;

        // Label radius depends on position
        const label_radius = switch (self.label_position) {
            .inside => (outer_radius + inner_radius) / 2.0,
            .outside => outer_radius * 1.15,
            .none => return,
        };

        for (self.data) |point| {
            if (point.value <= 0) continue;

            const slice_angle = (point.value / total) * 2.0 * std.math.pi;

            // Skip labels for tiny slices
            if (slice_angle < 0.15) {
                current_angle += slice_angle;
                continue;
            }

            // Calculate label position at slice midpoint
            const mid_angle = current_angle + slice_angle / 2.0;
            const label_x = cx + label_radius * @cos(mid_angle);
            const label_y = cy + label_radius * @sin(mid_angle);

            // Draw a small circle as label marker (actual text would need text rendering)
            const marker_color = switch (self.label_position) {
                .inside => Color.white,
                .outside => Color.hex(0x666666),
                .none => Color.white,
            };
            ctx.fillCircleAdaptive(label_x, label_y, 3, marker_color);

            current_angle += slice_angle;
        }
    }

    /// Get the slice index at a given point (for hit testing / tooltips).
    /// Returns null if the point is not within any slice.
    pub fn hitTest(self: *const PieChart, x: f32, y: f32) ?usize {
        const cx = self.width / 2.0;
        const cy = self.height / 2.0;
        const outer_radius = @min(cx, cy) * 0.85;
        const inner_radius = outer_radius * self.inner_radius_ratio;

        // Calculate distance from center
        const dx = x - cx;
        const dy = y - cy;
        const distance = @sqrt(dx * dx + dy * dy);

        // Check if within pie/donut ring
        if (distance < inner_radius or distance > outer_radius) {
            return null;
        }

        // Calculate angle
        var angle = std.math.atan2(dy, dx);
        // Normalize angle relative to start_angle
        angle -= self.start_angle;
        while (angle < 0) angle += 2.0 * std.math.pi;
        while (angle >= 2.0 * std.math.pi) angle -= 2.0 * std.math.pi;

        // Find which slice this angle falls into
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

// =============================================================================
// Tests
// =============================================================================

test "PieChart init" {
    const data = [_]CategoryPoint{
        CategoryPoint.init("A", 30),
        CategoryPoint.init("B", 50),
        CategoryPoint.init("C", 20),
    };

    const chart = PieChart.init(&data);
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

    const chart = PieChart.init(&data);
    const total = chart.calculateTotal();
    try std.testing.expectEqual(@as(f32, 100), total);
}

test "PieChart hitTest center hole" {
    const data = [_]CategoryPoint{
        CategoryPoint.init("A", 50),
        CategoryPoint.init("B", 50),
    };

    var chart = PieChart.init(&data);
    chart.inner_radius_ratio = 0.5;

    // Center should not hit anything (hole)
    const hit = chart.hitTest(150, 150);
    try std.testing.expect(hit == null);
}

test "PieChart struct size is small" {
    // PieChart should be small - just a slice pointer + options + theme ptr
    // Should be < 120 bytes, not embedding large arrays
    const size = @sizeOf(PieChart);
    try std.testing.expect(size < 120);
}

test "PieChart donut configuration" {
    const data = [_]CategoryPoint{
        CategoryPoint.init("A", 100),
    };

    var chart = PieChart.init(&data);
    chart.inner_radius_ratio = 0.6; // 60% hole

    // Verify donut settings
    try std.testing.expectEqual(@as(f32, 0.6), chart.inner_radius_ratio);
}

test "PieChart with custom colors" {
    var data = [_]CategoryPoint{
        CategoryPoint.initColored("Red", 33, Color.hex(0xff0000)),
        CategoryPoint.initColored("Green", 33, Color.hex(0x00ff00)),
        CategoryPoint.initColored("Blue", 34, Color.hex(0x0000ff)),
    };

    const chart = PieChart.init(&data);
    try std.testing.expectEqual(@as(u32, 3), chart.sliceCount());
}
