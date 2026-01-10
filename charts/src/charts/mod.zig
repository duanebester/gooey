//! Chart Components Module
//!
//! High-level chart components built on top of primitives:
//! - BarChart: Categorical data as vertical/horizontal bars
//! - LineChart: Continuous X/Y data as connected lines
//! - PieChart: Categorical data as circular slices (pie/donut)
//!
//! Additional charts (ScatterChart) will be added in Phase 2C.

pub const bar_chart = @import("bar_chart.zig");
pub const line_chart = @import("line_chart.zig");
pub const pie_chart = @import("pie_chart.zig");

// Re-export main types for convenience
pub const BarChart = bar_chart.BarChart;
pub const LineChart = line_chart.LineChart;
pub const PieChart = pie_chart.PieChart;

// Re-export palettes
pub const bar_palette = bar_chart.default_palette;
pub const line_palette = line_chart.default_palette;
pub const pie_palette = pie_chart.default_palette;

// Re-export Color and DrawContext
pub const Color = bar_chart.Color;
pub const DrawContext = bar_chart.DrawContext;

// =============================================================================
// Tests
// =============================================================================

test {
    @import("std").testing.refAllDecls(@This());
}
