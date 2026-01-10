//! Scale Primitives for Gooey Charts
//!
//! Scales map data values to pixel coordinates. This module provides:
//! - LinearScale: continuous numeric data → pixels
//! - BandScale: categorical data → pixel bands
//!
//! Based on D3.js scale concepts with zero allocation.

const std = @import("std");
const constants = @import("../constants.zig");
const util = @import("../util.zig");

const MAX_TICKS = constants.MAX_TICKS;
const MAX_CATEGORIES = constants.MAX_CATEGORIES;
const MAX_LABEL_LENGTH = constants.MAX_LABEL_LENGTH;

// =============================================================================
// LinearScale - Continuous numeric data to pixels
// =============================================================================

/// Maps a continuous numeric domain to a pixel range.
/// Supports inverted ranges for Y-axis (where 0 is at bottom).
pub const LinearScale = struct {
    domain_min: f32,
    domain_max: f32,
    range_min: f32,
    range_max: f32,

    /// Initialize a linear scale with domain and range.
    pub fn init(domain_min: f32, domain_max: f32, range_min: f32, range_max: f32) LinearScale {
        // Assertions at API boundary (per CLAUDE.md)
        std.debug.assert(!std.math.isNan(domain_min) and !std.math.isNan(domain_max));
        std.debug.assert(!std.math.isNan(range_min) and !std.math.isNan(range_max));

        return .{
            .domain_min = domain_min,
            .domain_max = domain_max,
            .range_min = range_min,
            .range_max = range_max,
        };
    }

    /// Create a scale for Y-axis (inverted: 0 at bottom, max at top).
    pub fn initYAxis(domain_min: f32, domain_max: f32, height: f32) LinearScale {
        std.debug.assert(height > 0);
        std.debug.assert(!std.math.isNan(domain_min) and !std.math.isNan(domain_max));

        return init(domain_min, domain_max, height, 0);
    }

    /// Map a data value to a pixel coordinate.
    pub fn scale(self: LinearScale, value: f32) f32 {
        std.debug.assert(!std.math.isNan(value));

        const domain_span = self.domain_max - self.domain_min;
        const range_span = self.range_max - self.range_min;

        // Handle degenerate case: single value domain
        if (domain_span == 0) {
            return (self.range_min + self.range_max) / 2.0;
        }

        const t = (value - self.domain_min) / domain_span;
        return self.range_min + t * range_span;
    }

    /// Map a pixel coordinate back to a data value.
    pub fn invert(self: LinearScale, pixel: f32) f32 {
        std.debug.assert(!std.math.isNan(pixel));

        const domain_span = self.domain_max - self.domain_min;
        const range_span = self.range_max - self.range_min;

        // Handle degenerate case
        if (range_span == 0) {
            return (self.domain_min + self.domain_max) / 2.0;
        }

        const t = (pixel - self.range_min) / range_span;
        return self.domain_min + t * domain_span;
    }

    /// Generate tick values for this scale.
    /// Returns the number of ticks written to the output array.
    pub fn ticks(self: LinearScale, count: u32, out: *[MAX_TICKS]f32) u32 {
        std.debug.assert(count > 0 and count <= MAX_TICKS);

        // Get nice range for ticks
        const nice_result = util.niceRange(self.domain_min, self.domain_max, count);

        // Generate tick values
        var tick_idx: u32 = 0;
        var value = nice_result.min;

        while (value <= nice_result.max and tick_idx < MAX_TICKS) : (value += nice_result.step) {
            // Only include ticks within the original domain
            if (value >= self.domain_min and value <= self.domain_max) {
                out[tick_idx] = value;
                tick_idx += 1;
            }
        }

        return tick_idx;
    }

    /// Create a copy with a "nice" domain (rounded to nice numbers).
    pub fn nice(self: LinearScale, tick_count: u32) LinearScale {
        std.debug.assert(tick_count > 0);

        const result = util.niceRange(self.domain_min, self.domain_max, tick_count);
        return .{
            .domain_min = result.min,
            .domain_max = result.max,
            .range_min = self.range_min,
            .range_max = self.range_max,
        };
    }

    /// Get the range span (absolute).
    pub fn rangeSpan(self: LinearScale) f32 {
        return @abs(self.range_max - self.range_min);
    }

    /// Get the domain span (absolute).
    pub fn domainSpan(self: LinearScale) f32 {
        return @abs(self.domain_max - self.domain_min);
    }

    /// Check if this is an inverted scale (range_min > range_max).
    pub fn isInverted(self: LinearScale) bool {
        return self.range_min > self.range_max;
    }
};

// =============================================================================
// BandScale - Categorical data to pixel bands
// =============================================================================

/// Maps categorical labels to equal-width pixel bands.
/// Used for bar charts, grouped data, etc.
pub const BandScale = struct {
    labels: [MAX_CATEGORIES][MAX_LABEL_LENGTH]u8 = undefined,
    label_lens: [MAX_CATEGORIES]u8 = [_]u8{0} ** MAX_CATEGORIES,
    label_count: u32 = 0,
    range_min: f32 = 0,
    range_max: f32 = 0,
    padding_inner: f32 = 0.1,
    padding_outer: f32 = 0.1,

    // Cached computed values
    _bandwidth: f32 = 0,
    _step: f32 = 0,
    _start_offset: f32 = 0,

    /// Initialize a band scale from label slices.
    pub fn init(labels: []const []const u8, range_min: f32, range_max: f32) BandScale {
        std.debug.assert(labels.len > 0 and labels.len <= MAX_CATEGORIES);
        std.debug.assert(!std.math.isNan(range_min) and !std.math.isNan(range_max));

        var band_scale = BandScale{
            .range_min = range_min,
            .range_max = range_max,
        };

        // Copy labels
        for (labels, 0..) |label, i| {
            const len: u8 = @intCast(@min(label.len, MAX_LABEL_LENGTH));
            @memcpy(band_scale.labels[i][0..len], label[0..len]);
            band_scale.label_lens[i] = len;
        }
        band_scale.label_count = @intCast(labels.len);

        band_scale.recalculate();
        return band_scale;
    }

    /// Initialize with custom padding.
    pub fn initWithPadding(
        labels: []const []const u8,
        range_min: f32,
        range_max: f32,
        padding_inner: f32,
        padding_outer: f32,
    ) BandScale {
        std.debug.assert(padding_inner >= 0 and padding_inner <= 1);
        std.debug.assert(padding_outer >= 0 and padding_outer <= 1);

        var band_scale = init(labels, range_min, range_max);
        band_scale.padding_inner = padding_inner;
        band_scale.padding_outer = padding_outer;
        band_scale.recalculate();
        return band_scale;
    }

    /// Recalculate cached values after padding changes.
    fn recalculate(self: *BandScale) void {
        std.debug.assert(self.label_count > 0);

        const n: f32 = @floatFromInt(self.label_count);
        const range_span = @abs(self.range_max - self.range_min);

        // Formula: bandwidth = range / (n + (n-1)*inner + 2*outer)
        // Step = bandwidth + bandwidth * inner
        const denominator = n + (n - 1) * self.padding_inner + 2 * self.padding_outer;

        if (denominator <= 0) {
            self._bandwidth = 0;
            self._step = 0;
            self._start_offset = 0;
            return;
        }

        self._bandwidth = range_span / denominator;
        self._step = self._bandwidth * (1 + self.padding_inner);
        self._start_offset = self._bandwidth * self.padding_outer;
    }

    /// Get the width of each band.
    pub fn bandwidth(self: BandScale) f32 {
        return self._bandwidth;
    }

    /// Get the starting pixel position for a category index.
    pub fn position(self: BandScale, index: u32) f32 {
        std.debug.assert(index < self.label_count);

        const base = @min(self.range_min, self.range_max);
        const idx_f: f32 = @floatFromInt(index);
        return base + self._start_offset + idx_f * self._step;
    }

    /// Get the center position for a category index.
    pub fn center(self: BandScale, index: u32) f32 {
        return self.position(index) + self._bandwidth / 2.0;
    }

    /// Find the index for a given pixel position (for hit testing).
    /// Returns null if outside all bands.
    pub fn indexAt(self: BandScale, pixel: f32) ?u32 {
        std.debug.assert(!std.math.isNan(pixel));

        const base = @min(self.range_min, self.range_max);
        const relative = pixel - base - self._start_offset;

        if (relative < 0) return null;

        const raw_index = relative / self._step;
        const index: u32 = @intFromFloat(@floor(raw_index));

        if (index >= self.label_count) return null;

        // Check if within the band (not in the gap)
        const within_band = relative - @as(f32, @floatFromInt(index)) * self._step;
        if (within_band > self._bandwidth) return null;

        return index;
    }

    /// Get the label for a category index.
    pub fn getLabel(self: *const BandScale, index: u32) []const u8 {
        std.debug.assert(index < self.label_count);
        return self.labels[index][0..self.label_lens[index]];
    }

    /// Set padding (triggers recalculation).
    pub fn setPadding(self: *BandScale, inner: f32, outer: f32) void {
        std.debug.assert(inner >= 0 and inner <= 1);
        std.debug.assert(outer >= 0 and outer <= 1);

        self.padding_inner = inner;
        self.padding_outer = outer;
        self.recalculate();
    }
};

// =============================================================================
// Scale Union
// =============================================================================

/// A scale that can be either linear or band.
/// Useful for axis rendering that needs to work with both types.
pub const Scale = union(enum) {
    linear: LinearScale,
    band: BandScale,

    /// Map a numeric value to pixels (only valid for linear scale).
    pub fn scaleValue(self: Scale, value: f32) f32 {
        return switch (self) {
            .linear => |s| s.scale(value),
            .band => unreachable, // Use scaleCategoryIndex for band scale
        };
    }

    /// Map a category index to pixels (only valid for band scale).
    pub fn scaleCategoryIndex(self: Scale, index: u32) f32 {
        return switch (self) {
            .linear => unreachable, // Use scaleValue for linear scale
            .band => |s| s.center(index),
        };
    }

    /// Get the range extent.
    pub fn rangeExtent(self: Scale) struct { min: f32, max: f32 } {
        return switch (self) {
            .linear => |s| .{ .min = s.range_min, .max = s.range_max },
            .band => |s| .{ .min = s.range_min, .max = s.range_max },
        };
    }

    /// Check if this is a band scale.
    pub fn isBand(self: Scale) bool {
        return self == .band;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "LinearScale basic scaling" {
    const s = LinearScale.init(0, 100, 0, 500);
    try std.testing.expectApproxEqAbs(@as(f32, 0), s.scale(0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 250), s.scale(50), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 500), s.scale(100), 0.001);
}

test "LinearScale inverted (Y-axis)" {
    const s = LinearScale.initYAxis(0, 100, 500);
    // 0 should map to 500 (bottom), 100 should map to 0 (top)
    try std.testing.expectApproxEqAbs(@as(f32, 500), s.scale(0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), s.scale(100), 0.001);
    try std.testing.expect(s.isInverted());
}

test "LinearScale invert" {
    const s = LinearScale.init(0, 100, 0, 500);
    try std.testing.expectApproxEqAbs(@as(f32, 50), s.invert(250), 0.001);
}

test "LinearScale ticks" {
    const s = LinearScale.init(0, 100, 0, 500);
    var tick_values: [MAX_TICKS]f32 = undefined;
    const count = s.ticks(5, &tick_values);
    try std.testing.expect(count > 0);
    try std.testing.expect(count <= MAX_TICKS);
}

test "LinearScale handles degenerate domain" {
    const s = LinearScale.init(50, 50, 0, 500);
    // Single value should map to center of range
    const result = s.scale(50);
    try std.testing.expectApproxEqAbs(@as(f32, 250), result, 0.001);
}

test "BandScale basic positioning" {
    const labels = [_][]const u8{ "A", "B", "C", "D" };
    const s = BandScale.init(&labels, 0, 400);

    try std.testing.expect(s.bandwidth() > 0);
    try std.testing.expect(s.position(0) >= 0);
    try std.testing.expect(s.position(3) < 400);

    // Positions should be monotonically increasing
    try std.testing.expect(s.position(1) > s.position(0));
    try std.testing.expect(s.position(2) > s.position(1));
}

test "BandScale getLabel" {
    const labels = [_][]const u8{ "January", "February", "March" };
    const s = BandScale.init(&labels, 0, 300);

    try std.testing.expectEqualStrings("January", s.getLabel(0));
    try std.testing.expectEqualStrings("February", s.getLabel(1));
    try std.testing.expectEqualStrings("March", s.getLabel(2));
}

test "BandScale indexAt" {
    const labels = [_][]const u8{ "A", "B", "C" };
    const s = BandScale.init(&labels, 0, 300);

    // First band should be hit near start
    const idx = s.indexAt(s.position(0) + s.bandwidth() / 2);
    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(u32, 0), idx.?);

    // Outside range should return null
    try std.testing.expect(s.indexAt(-10) == null);
}

test "Scale union" {
    const linear = Scale{ .linear = LinearScale.init(0, 100, 0, 500) };
    const extent = linear.rangeExtent();
    try std.testing.expectApproxEqAbs(@as(f32, 0), extent.min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 500), extent.max, 0.001);
    try std.testing.expect(!linear.isBand());
}
