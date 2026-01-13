//! Gooey Charts — GPU-Accelerated Charting Library
//!
//! A declarative, high-performance charting library that integrates
//! seamlessly with Gooey's UI system. Charts render directly to the GPU
//! via Gooey's canvas API, with zero dynamic allocation during render.
//!
//! ## Quick Start
//!
//! ```zig
//! const gooey = @import("gooey");
//! const charts = @import("gooey-charts");
//! const ui = gooey.ui;
//!
//! // Chart data (must outlive the paint callback)
//! var bar_data: [1]charts.CategorySeries = undefined;
//! var initialized = false;
//!
//! fn paintChart(ctx: *charts.DrawContext) void {
//!     const chart = charts.BarChart.init(&bar_data);
//!     chart.render(ctx);
//! }
//!
//! fn render(cx: *gooey.Cx) void {
//!     if (!initialized) {
//!         bar_data[0] = charts.CategorySeries.init("Sales", charts.Color.hex(0x4285f4));
//!         bar_data[0].addPoint(charts.CategoryPoint.init("Q1", 30));
//!         bar_data[0].addPoint(charts.CategoryPoint.init("Q2", 45));
//!         bar_data[0].addPoint(charts.CategoryPoint.init("Q3", 28));
//!         bar_data[0].addPoint(charts.CategoryPoint.init("Q4", 55));
//!         initialized = true;
//!     }
//!
//!     cx.render(ui.box(.{}, .{
//!         ui.canvas(400, 300, paintChart),
//!     }));
//! }
//! ```
//!
//! ## Module Organization
//!
//! - `primitives` — Low-level building blocks (Scale, Axis, Grid)
//! - `charts` — High-level chart components (BarChart, LineChart, etc.)
//! - `types` — Data structures (DataPoint, Series, etc.)
//! - `util` — Utility functions (niceNumber, formatNumber, etc.)

const std = @import("std");
pub const gooey = @import("gooey");

// =============================================================================
// Sub-modules
// =============================================================================

pub const primitives = @import("primitives/mod.zig");
pub const constants = @import("constants.zig");
pub const types = @import("types.zig");
pub const util = @import("util.zig");
pub const theme = @import("theme.zig");
pub const accessibility = @import("accessibility.zig");

// =============================================================================
// Primitives (Layer 2)
// =============================================================================

/// Maps continuous numeric data to pixel coordinates.
pub const LinearScale = primitives.LinearScale;

/// Maps categorical labels to equal-width pixel bands.
pub const BandScale = primitives.BandScale;

/// A scale that can be either linear or band.
pub const Scale = primitives.Scale;

/// Renders axis lines, tick marks, and labels.
pub const Axis = primitives.Axis;

/// Renders background grid lines.
pub const Grid = primitives.Grid;

/// Renders legend showing series names and colors.
pub const Legend = primitives.Legend;

// =============================================================================
// Charts (Layer 3)
// =============================================================================

const bar_chart = @import("charts/bar_chart.zig");
const line_chart = @import("charts/line_chart.zig");
const pie_chart = @import("charts/pie_chart.zig");
const scatter_chart = @import("charts/scatter_chart.zig");

/// Renders categorical data as vertical or horizontal bars.
pub const BarChart = bar_chart.BarChart;

/// Renders continuous X/Y data as connected lines with optional markers.
pub const LineChart = line_chart.LineChart;

/// Renders categorical data as circular slices (pie) or ring segments (donut).
pub const PieChart = pie_chart.PieChart;

/// Renders X/Y data as scattered points with optional size encoding (bubble chart).
pub const ScatterChart = scatter_chart.ScatterChart;

/// Point shapes available for scatter charts.
pub const PointShape = scatter_chart.PointShape;

// =============================================================================
// Theming
// =============================================================================

/// Theme for chart components with colors optimized for data visualization.
pub const ChartTheme = theme.ChartTheme;

/// Maximum colors in the categorical palette.
pub const MAX_PALETTE_COLORS = theme.MAX_PALETTE_COLORS;

/// Default color palette for charts (Google-style, 12 colors).
/// For theme-specific rendering, use google_light_palette or google_dark_palette.
pub const default_palette = theme.default_palette;

/// Google-style palette optimized for light backgrounds.
/// Darker, more saturated colors for better contrast on light backgrounds.
pub const google_light_palette = theme.google_light_palette;

/// Google-style palette optimized for dark backgrounds.
/// Brighter colors for better visibility on dark backgrounds.
pub const google_dark_palette = theme.google_dark_palette;

/// Standard Google-style color palette (balanced for general use).
pub const google_palette = theme.google_palette;

/// Colorblind-safe palette (deuteranopia/protanopia friendly).
pub const colorblind_palette = theme.colorblind_palette;

/// Monochrome blue palette (single hue, varying lightness).
pub const monochrome_blue_palette = theme.monochrome_blue_palette;

// =============================================================================
// Data Types
// =============================================================================

/// A single data point with continuous X and Y values.
pub const DataPoint = types.DataPoint;

/// A data point with a categorical label and numeric value.
pub const CategoryPoint = types.CategoryPoint;

/// A named series of data points with a color.
pub const Series = types.Series;

/// A named series of category points with a color.
pub const CategorySeries = types.CategorySeries;

// =============================================================================
// Core Types (from Gooey)
// =============================================================================

pub const Color = gooey.ui.Color;
pub const DrawContext = gooey.ui.DrawContext;

// =============================================================================
// Constants
// =============================================================================

pub const MAX_DATA_POINTS = constants.MAX_DATA_POINTS;
pub const MAX_SERIES = constants.MAX_SERIES;
pub const MAX_CATEGORIES = constants.MAX_CATEGORIES;
pub const MAX_TICKS = constants.MAX_TICKS;
pub const MAX_LEGEND_ITEMS = constants.MAX_LEGEND_ITEMS;
pub const MAX_LABEL_LENGTH = constants.MAX_LABEL_LENGTH;

// =============================================================================
// Utility Functions
// =============================================================================

/// Calculate a "nice" number close to the given value.
pub const niceNumber = util.niceNumber;

/// Calculate a "nice" range for axis display.
pub const niceRange = util.niceRange;

/// Format a number into a fixed buffer.
pub const formatNumber = util.formatNumber;

/// Format a number with SI prefix (K, M, B, T).
pub const formatCompact = util.formatCompact;

// =============================================================================
// Accessibility
// =============================================================================

/// Metadata about a chart for accessibility purposes.
pub const ChartInfo = accessibility.ChartInfo;

/// Chart type for accessibility descriptions.
pub const ChartType = accessibility.ChartType;

/// Focus position for keyboard navigation within charts.
pub const FocusPosition = accessibility.FocusPosition;

/// Generate a full accessible description for a chart.
pub const describeChart = accessibility.describe;

/// Generate a short summary for tooltips or live regions.
pub const summarizeChart = accessibility.summarize;

/// Build ChartInfo from CategorySeries (for bar charts).
pub const infoFromCategorySeries = accessibility.infoFromCategorySeries;

/// Build ChartInfo from Series (for line/scatter charts).
pub const infoFromSeries = accessibility.infoFromSeries;

/// Build ChartInfo from CategoryPoints (for pie charts).
pub const infoFromCategoryPoints = accessibility.infoFromCategoryPoints;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
