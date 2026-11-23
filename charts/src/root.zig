const std = @import("std");
pub const gooey = @import("gooey");

pub const primitives = @import("primitives/mod.zig");
pub const constants = @import("constants.zig");
pub const types = @import("types.zig");
pub const util = @import("util.zig");
pub const theme = @import("theme.zig");
pub const accessibility = @import("accessibility.zig");
pub const paint = @import("paint.zig");

pub const LinearScale = primitives.LinearScale;

pub const BandScale = primitives.BandScale;

pub const Scale = primitives.Scale;

pub const Axis = primitives.Axis;

pub const Grid = primitives.Grid;

pub const Legend = primitives.Legend;

const bar_chart = @import("charts/bar_chart.zig");
const line_chart = @import("charts/line_chart.zig");
const pie_chart = @import("charts/pie_chart.zig");
const scatter_chart = @import("charts/scatter_chart.zig");

pub const BarChart = bar_chart.BarChart;

pub const LineChart = line_chart.LineChart;

pub const PieChart = pie_chart.PieChart;

pub const ScatterChart = scatter_chart.ScatterChart;

pub const PointShape = scatter_chart.PointShape;

pub const ChartTheme = theme.ChartTheme;

pub const MAX_PALETTE_COLORS = theme.MAX_PALETTE_COLORS;

pub const default_palette = theme.default_palette;

pub const google_light_palette = theme.google_light_palette;

pub const google_dark_palette = theme.google_dark_palette;

pub const google_palette = theme.google_palette;

pub const colorblind_palette = theme.colorblind_palette;

pub const monochrome_blue_palette = theme.monochrome_blue_palette;

pub const DataPoint = types.DataPoint;

pub const CategoryPoint = types.CategoryPoint;

pub const Series = types.Series;

pub const CategorySeries = types.CategorySeries;

pub const PointCapacity = types.PointCapacity;

pub const CategoryCapacity = types.CategoryCapacity;

pub const SliceCapacity = types.SliceCapacity;

pub const Color = paint.Color;
pub const Painter = paint.Painter;

pub const point_count_ceiling = constants.point_count_ceiling;
pub const series_count_ceiling = constants.series_count_ceiling;
pub const category_count_ceiling = constants.category_count_ceiling;
pub const slice_count_ceiling = constants.slice_count_ceiling;

pub const MAX_TICKS = constants.MAX_TICKS;
pub const MAX_LEGEND_ITEMS = constants.MAX_LEGEND_ITEMS;
pub const MAX_LABEL_LENGTH = constants.MAX_LABEL_LENGTH;

pub const niceNumber = util.niceNumber;

pub const niceRange = util.niceRange;

pub const formatNumber = util.formatNumber;

pub const formatCompact = util.formatCompact;

pub const ChartInfo = accessibility.ChartInfo;

pub const ChartType = accessibility.ChartType;

pub const FocusPosition = accessibility.FocusPosition;

pub const describeChart = accessibility.describe;

pub const summarizeChart = accessibility.summarize;

pub const infoFromCategorySeries = accessibility.infoFromCategorySeries;

pub const infoFromSeries = accessibility.infoFromSeries;

pub const infoFromCategoryPoints = accessibility.infoFromCategoryPoints;

test {
    std.testing.refAllDecls(@This());
}
