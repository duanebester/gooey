//! Hard limits for chart data structures. App data capacities are not set
//! here: every chart type takes them at comptime from the app, checked
//! against the `*_ceiling` constants.

pub const point_count_ceiling: u32 = 4096;

pub const series_count_ceiling: u32 = 16;

pub const category_count_ceiling: u32 = 256;

pub const slice_count_ceiling: u32 = 64;

pub const MAX_TICKS: u32 = 32;

pub const MAX_LEGEND_ITEMS: u32 = 32;

pub const MAX_LABEL_LENGTH: u32 = 64;

pub const DEFAULT_WIDTH: f32 = 400;
pub const DEFAULT_HEIGHT: f32 = 300;

pub const DEFAULT_MARGIN_TOP: f32 = 20;
pub const DEFAULT_MARGIN_RIGHT: f32 = 20;
pub const DEFAULT_MARGIN_BOTTOM: f32 = 40;
pub const DEFAULT_MARGIN_LEFT: f32 = 50;

pub const DEFAULT_TICK_SIZE: f32 = 6;
pub const DEFAULT_TICK_PADDING: f32 = 3;
pub const DEFAULT_TICK_COUNT: u32 = 5;

pub const DEFAULT_BAR_PADDING: f32 = 0.1;
pub const DEFAULT_GROUP_PADDING: f32 = 0.2;

pub const DEFAULT_LINE_WIDTH: f32 = 2.0;
pub const DEFAULT_POINT_RADIUS: f32 = 4.0;

pub const DEFAULT_GRID_LINE_WIDTH: f32 = 1.0;

/// Charts with more points than this decimate with LTTB.
pub const LOD_THRESHOLD: u32 = 1000;

comptime {
    std.debug.assert(point_count_ceiling > 0);
    std.debug.assert(series_count_ceiling > 0);
    std.debug.assert(category_count_ceiling > 0);
    std.debug.assert(slice_count_ceiling > 0);
    std.debug.assert(MAX_TICKS > 0);
    std.debug.assert(MAX_LEGEND_ITEMS > 0);
    std.debug.assert(MAX_LABEL_LENGTH > 0);

    // Band scales index ticks into categories.
    std.debug.assert(MAX_TICKS <= category_count_ceiling);

    // Every series appears in the legend.
    std.debug.assert(series_count_ceiling <= MAX_LEGEND_ITEMS);

    // Pie slices are categories: a pie never holds more than a bar series.
    std.debug.assert(slice_count_ceiling <= category_count_ceiling);

    std.debug.assert(LOD_THRESHOLD > 0);
    std.debug.assert(LOD_THRESHOLD <= point_count_ceiling);
}

const std = @import("std");

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
