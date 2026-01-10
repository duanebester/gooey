//! Gooey Charts Constants
//!
//! Hard limits for all chart data structures.
//! Per CLAUDE.md: "Put a limit on everything" - every loop, queue, and buffer needs a hard cap.

/// Maximum data points per series (e.g., line chart points)
pub const MAX_DATA_POINTS: u32 = 4096;

/// Maximum number of series per chart (e.g., multiple lines on a line chart)
pub const MAX_SERIES: u32 = 16;

/// Maximum categories for categorical charts (e.g., bar chart labels)
pub const MAX_CATEGORIES: u32 = 256;

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

/// Enable render timing debug logs (Phase 4 optimization)
/// When true, warns if chart render exceeds 8ms budget
pub const ENABLE_PERF_LOGGING: bool = false;

/// Performance warning threshold in nanoseconds (8ms = 8_000_000ns)
pub const PERF_WARNING_THRESHOLD_NS: i128 = 8_000_000;

/// Level-of-detail threshold for large datasets
/// Charts with more points than this use data decimation (LTTB algorithm)
pub const LOD_THRESHOLD: u32 = 1000;

/// Maximum polygon vertices for area fill optimization
/// Area fill uses single polygon instead of 4×(N-1) rectangles
pub const MAX_AREA_POLYGON_VERTICES: u32 = MAX_DATA_POINTS * 2 + 2;

// =============================================================================
// Compile-time assertions (per CLAUDE.md: assert compile-time constants)
// =============================================================================

comptime {
    // Ensure limits are sensible
    std.debug.assert(MAX_DATA_POINTS > 0);
    std.debug.assert(MAX_SERIES > 0);
    std.debug.assert(MAX_CATEGORIES > 0);
    std.debug.assert(MAX_TICKS > 0);
    std.debug.assert(MAX_LEGEND_ITEMS > 0);
    std.debug.assert(MAX_LABEL_LENGTH > 0);

    // Ensure ticks fit in category count (for band scales)
    std.debug.assert(MAX_TICKS <= MAX_CATEGORIES);

    // Ensure series count fits in legend
    std.debug.assert(MAX_SERIES <= MAX_LEGEND_ITEMS);

    // Performance constants validation
    std.debug.assert(LOD_THRESHOLD > 0);
    std.debug.assert(LOD_THRESHOLD <= MAX_DATA_POINTS);
    std.debug.assert(PERF_WARNING_THRESHOLD_NS > 0);
    std.debug.assert(MAX_AREA_POLYGON_VERTICES >= 4); // Minimum for a quad
}

const std = @import("std");

// =============================================================================
// Tests
// =============================================================================

test "constants are valid" {
    try std.testing.expect(MAX_DATA_POINTS == 4096);
    try std.testing.expect(MAX_SERIES == 16);
    try std.testing.expect(MAX_CATEGORIES == 256);
    try std.testing.expect(MAX_TICKS == 32);
    try std.testing.expect(MAX_LABEL_LENGTH == 64);
}

test "performance constants are valid" {
    try std.testing.expect(LOD_THRESHOLD == 1000);
    try std.testing.expect(PERF_WARNING_THRESHOLD_NS == 8_000_000);
    try std.testing.expect(MAX_AREA_POLYGON_VERTICES == MAX_DATA_POINTS * 2 + 2);
}
