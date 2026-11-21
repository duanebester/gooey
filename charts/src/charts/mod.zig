pub const bar_chart = @import("bar_chart.zig");
pub const line_chart = @import("line_chart.zig");
pub const pie_chart = @import("pie_chart.zig");

pub const BarChart = bar_chart.BarChart;
pub const LineChart = line_chart.LineChart;
pub const PieChart = pie_chart.PieChart;

pub const bar_palette = bar_chart.default_palette;
pub const line_palette = line_chart.default_palette;
pub const pie_palette = pie_chart.default_palette;

pub const Color = bar_chart.Color;
pub const Painter = bar_chart.Painter;

test {
    @import("std").testing.refAllDecls(@This());
}
