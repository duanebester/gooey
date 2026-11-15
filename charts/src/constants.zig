//! Gooey Charts Constants
//!
//! Hard limits for all chart data structures.
//! Per CLAUDE.md: "Put a limit on everything" - every loop, queue, and buffer needs a hard cap.
//!
//! App data capacities are not set here: every chart type takes its capacities at comptime
//! from the app (`LineChart(.{ .point_count_max = 512, .series_count_max = 4 })`). The
//! `*_ceiling` constants are the framework ceilings those capacities are checked against.

/// Framework ceiling on the points one series may hold (line and scatter charts).
pub const point_count_ceiling: u32 = 4096;

/// Framework ceiling on the series one chart may draw.
pub const series_count_ceiling: u32 = 16;

/// Framework ceiling on the categories one categorical series may hold (bar charts).
pub const category_count_ceiling: u32 = 256;

/// Framework ceiling on the slices one pie or donut chart may draw.
pub const slice_count_ceiling: u32 = 64;

/// Maximum tick marks per axis
pub const MAX_TICKS: u32 = 32;

/// Maximum items in a legend
pub const MAX_LEGEND_ITEMS: u32 = 32;

/// Maximum characters per label (category name, series name, etc.)
pub const MAX_LABEL_LENGTH: u32 = 64;

/// Default chart dimensions (pixels)
pub const DEFAULT_WIDTH: f32 = 400;
pub const DEFAULT_HEIGHT: f32 = 300;

/// Default margins (pixels)
pub const DEFAULT_MARGIN_TOP: f32 = 20;
pub const DEFAULT_MARGIN_RIGHT: f32 = 20;
pub const DEFAULT_MARGIN_BOTTOM: f32 = 40;
pub const DEFAULT_MARGIN_LEFT: f32 = 50;

/// Default axis styling
pub const DEFAULT_TICK_SIZE: f32 = 6;
pub const DEFAULT_TICK_PADDING: f32 = 3;
pub const DEFAULT_TICK_COUNT: u32 = 5;

/// Default bar chart styling
pub const DEFAULT_BAR_PADDING: f32 = 0.1;
pub const DEFAULT_GROUP_PADDING: f32 = 0.2;

/// Default line chart styling
pub const DEFAULT_LINE_WIDTH: f32 = 2.0;
pub const DEFAULT_POINT_RADIUS: f32 = 4.0;

/// Default grid styling
pub const DEFAULT_GRID_LINE_WIDTH: f32 = 1.0;

// =============================================================================
// Performance Tuning
// =============================================================================

/// Level-of-detail threshold for large datasets
/// Charts with more points than this use data decimation (LTTB algorithm)
pub const LOD_THRESHOLD: u32 = 1000;

// =============================================================================
// Compile-time assertions (per CLAUDE.md: assert compile-time constants)
// =============================================================================

comptime {
    // Ensure limits are sensible
    std.debug.assert(point_count_ceiling > 0);
    std.debug.assert(series_count_ceiling > 0);
    std.debug.assert(category_count_ceiling > 0);
    std.debug.assert(slice_count_ceiling > 0);
    std.debug.assert(MAX_TICKS > 0);
    std.debug.assert(MAX_LEGEND_ITEMS > 0);
    std.debug.assert(MAX_LABEL_LENGTH > 0);

    // Ensure ticks fit in category count (for band scales)
    std.debug.assert(MAX_TICKS <= category_count_ceiling);

    // Ensure series count fits in legend
    std.debug.assert(series_count_ceiling <= MAX_LEGEND_ITEMS);

    // Pie slices are categories: a pie never holds more than a bar series.
    std.debug.assert(slice_count_ceiling <= category_count_ceiling);

    // Performance constants validation
    std.debug.assert(LOD_THRESHOLD > 0);
    std.debug.assert(LOD_THRESHOLD <= point_count_ceiling);
}

const std = @import("std");

// =============================================================================
// Tests
// =============================================================================

test "constants are valid" {
    try std.testing.expect(point_count_ceiling == 4096);
    try std.testing.expect(series_count_ceiling == 16);
    try std.testing.expect(category_count_ceiling == 256);
    try std.testing.expect(slice_count_ceiling == 64);
    try std.testing.expect(MAX_TICKS == 32);
    try std.testing.expect(MAX_LABEL_LENGTH == 64);
}

test "performance constants are valid" {
    try std.testing.expect(LOD_THRESHOLD == 1000);
}
