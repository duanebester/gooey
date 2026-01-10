//! Charts Demo Example
//!
//! Demonstrates the gooey-charts library with bar, line, and pie charts.

const std = @import("std");
const gooey = @import("gooey");
const charts = @import("gooey-charts");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    frame: u32 = 0,
    use_dark_theme: bool = true,
};

// =============================================================================
// Chart Themes
// =============================================================================

const dark_theme = charts.ChartTheme.dark;
const light_theme = charts.ChartTheme.light;

// =============================================================================
// Chart Data (stored statically so it outlives the paint callback)
// =============================================================================

// Bar chart data
var quarterly_sales: charts.CategorySeries = undefined;
var bar_chart_data: [1]charts.CategorySeries = undefined;

// Line chart data - work directly in array to avoid 304KB copies
var line_chart_data: [2]charts.Series = undefined;

// Pie chart data
var pie_chart_data: [5]charts.CategoryPoint = undefined;
var donut_chart_data: [4]charts.CategoryPoint = undefined;

// Scatter chart data
var scatter_chart_data: [2]charts.Series = undefined;

// Theme-based chart data (uses null colors to let theme palette apply)
var themed_line_data: [3]charts.Series = undefined;

var data_initialized: bool = false;

fn ensureDataInitialized() void {
    if (data_initialized) return;

    // Bar chart: Quarterly sales (explicit color)
    quarterly_sales = charts.CategorySeries.init("Sales 2024", charts.Color.hex(0x4285f4));
    quarterly_sales.addPoint(charts.CategoryPoint.init("Q1", 42));
    quarterly_sales.addPoint(charts.CategoryPoint.init("Q2", 58));
    quarterly_sales.addPoint(charts.CategoryPoint.init("Q3", 35));
    quarterly_sales.addPoint(charts.CategoryPoint.init("Q4", 71));
    bar_chart_data[0] = quarterly_sales;

    // Line chart: Monthly revenue vs expenses
    // Use initInPlace to avoid 304KB return-by-value stack allocation
    line_chart_data[0].initInPlace("Revenue", charts.Color.hex(0x34a853));
    line_chart_data[0].addPoint(charts.DataPoint.init(1, 45));
    line_chart_data[0].addPoint(charts.DataPoint.init(2, 52));
    line_chart_data[0].addPoint(charts.DataPoint.init(3, 48));
    line_chart_data[0].addPoint(charts.DataPoint.init(4, 61));
    line_chart_data[0].addPoint(charts.DataPoint.init(5, 55));
    line_chart_data[0].addPoint(charts.DataPoint.init(6, 67));
    line_chart_data[0].addPoint(charts.DataPoint.init(7, 72));
    line_chart_data[0].addPoint(charts.DataPoint.init(8, 68));
    line_chart_data[0].addPoint(charts.DataPoint.init(9, 79));
    line_chart_data[0].addPoint(charts.DataPoint.init(10, 85));
    line_chart_data[0].addPoint(charts.DataPoint.init(11, 82));
    line_chart_data[0].addPoint(charts.DataPoint.init(12, 91));

    line_chart_data[1].initInPlace("Expenses", charts.Color.hex(0xea4335));
    line_chart_data[1].addPoint(charts.DataPoint.init(1, 38));
    line_chart_data[1].addPoint(charts.DataPoint.init(2, 42));
    line_chart_data[1].addPoint(charts.DataPoint.init(3, 40));
    line_chart_data[1].addPoint(charts.DataPoint.init(4, 45));
    line_chart_data[1].addPoint(charts.DataPoint.init(5, 43));
    line_chart_data[1].addPoint(charts.DataPoint.init(6, 48));
    line_chart_data[1].addPoint(charts.DataPoint.init(7, 52));
    line_chart_data[1].addPoint(charts.DataPoint.init(8, 50));
    line_chart_data[1].addPoint(charts.DataPoint.init(9, 55));
    line_chart_data[1].addPoint(charts.DataPoint.init(10, 58));
    line_chart_data[1].addPoint(charts.DataPoint.init(11, 54));
    line_chart_data[1].addPoint(charts.DataPoint.init(12, 60));

    // Pie chart: Market share
    pie_chart_data[0] = charts.CategoryPoint.initColored("Chrome", 65, charts.Color.hex(0x4285f4));
    pie_chart_data[1] = charts.CategoryPoint.initColored("Safari", 19, charts.Color.hex(0x34a853));
    pie_chart_data[2] = charts.CategoryPoint.initColored("Firefox", 8, charts.Color.hex(0xfbbc05));
    pie_chart_data[3] = charts.CategoryPoint.initColored("Edge", 5, charts.Color.hex(0x46bdc6));
    pie_chart_data[4] = charts.CategoryPoint.initColored("Other", 3, charts.Color.hex(0xea4335));

    // Donut chart: Budget allocation
    donut_chart_data[0] = charts.CategoryPoint.initColored("Engineering", 45, charts.Color.hex(0x7b1fa2));
    donut_chart_data[1] = charts.CategoryPoint.initColored("Marketing", 25, charts.Color.hex(0xff6d01));
    donut_chart_data[2] = charts.CategoryPoint.initColored("Operations", 20, charts.Color.hex(0x00796b));
    donut_chart_data[3] = charts.CategoryPoint.initColored("HR", 10, charts.Color.hex(0xc2185b));

    // Scatter chart: Height vs Weight
    scatter_chart_data[0].initInPlace("Male", charts.Color.hex(0x4285f4));
    scatter_chart_data[0].addPoint(charts.DataPoint.init(165, 68));
    scatter_chart_data[0].addPoint(charts.DataPoint.init(170, 72));
    scatter_chart_data[0].addPoint(charts.DataPoint.init(175, 78));
    scatter_chart_data[0].addPoint(charts.DataPoint.init(180, 82));
    scatter_chart_data[0].addPoint(charts.DataPoint.init(185, 88));
    scatter_chart_data[0].addPoint(charts.DataPoint.init(172, 75));
    scatter_chart_data[0].addPoint(charts.DataPoint.init(178, 80));
    scatter_chart_data[0].addPoint(charts.DataPoint.init(168, 70));

    scatter_chart_data[1].initInPlace("Female", charts.Color.hex(0xea4335));
    scatter_chart_data[1].addPoint(charts.DataPoint.init(155, 52));
    scatter_chart_data[1].addPoint(charts.DataPoint.init(160, 55));
    scatter_chart_data[1].addPoint(charts.DataPoint.init(165, 58));
    scatter_chart_data[1].addPoint(charts.DataPoint.init(170, 62));
    scatter_chart_data[1].addPoint(charts.DataPoint.init(158, 54));
    scatter_chart_data[1].addPoint(charts.DataPoint.init(163, 57));
    scatter_chart_data[1].addPoint(charts.DataPoint.init(168, 60));

    // Theme-based line chart: Uses null colors so theme palette applies
    themed_line_data[0].initInPlace("Series A", null); // Will use theme palette[0]
    themed_line_data[0].addPoint(charts.DataPoint.init(1, 20));
    themed_line_data[0].addPoint(charts.DataPoint.init(2, 35));
    themed_line_data[0].addPoint(charts.DataPoint.init(3, 28));
    themed_line_data[0].addPoint(charts.DataPoint.init(4, 42));
    themed_line_data[0].addPoint(charts.DataPoint.init(5, 38));
    themed_line_data[0].addPoint(charts.DataPoint.init(6, 55));

    themed_line_data[1].initInPlace("Series B", null); // Will use theme palette[1]
    themed_line_data[1].addPoint(charts.DataPoint.init(1, 15));
    themed_line_data[1].addPoint(charts.DataPoint.init(2, 22));
    themed_line_data[1].addPoint(charts.DataPoint.init(3, 30));
    themed_line_data[1].addPoint(charts.DataPoint.init(4, 25));
    themed_line_data[1].addPoint(charts.DataPoint.init(5, 45));
    themed_line_data[1].addPoint(charts.DataPoint.init(6, 40));

    themed_line_data[2].initInPlace("Series C", null); // Will use theme palette[2]
    themed_line_data[2].addPoint(charts.DataPoint.init(1, 30));
    themed_line_data[2].addPoint(charts.DataPoint.init(2, 28));
    themed_line_data[2].addPoint(charts.DataPoint.init(3, 35));
    themed_line_data[2].addPoint(charts.DataPoint.init(4, 32));
    themed_line_data[2].addPoint(charts.DataPoint.init(5, 28));
    themed_line_data[2].addPoint(charts.DataPoint.init(6, 38));

    data_initialized = true;
}

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Gooey Charts Demo",
    .width = 600,
    .height = 500,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// =============================================================================
// Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();

    // Ensure chart data is initialized before rendering
    ensureDataInitialized();

    cx.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 20 },
        .gap = 15,
        .direction = .column,
        .background = ui.Color.hex(0x1a1a2e),
    }, .{
        // Title
        ui.text("Gooey Charts Demo", .{
            .size = 28,
            .color = ui.Color.white,
        }),

        // Scrollable chart content
        ScrollableCharts{},
    });
}

const ScrollableCharts = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const size = cx.windowSize();

        cx.scroll("charts-scroll", .{
            .width = size.width - 40,
            .height = size.height - 100,
            .content_height = 1600, // Increased for themed chart
            .gap = 15,
            .track_color = ui.Color.hex(0x2a3a5e),
            .thumb_color = ui.Color.hex(0x4a6a9e),
        }, .{
            // Bar chart
            ui.text("Quarterly Sales (Bar Chart)", .{
                .size = 16,
                .color = ui.Color.hex(0xaaaaaa),
            }),
            ui.canvas(500, 150, paintBarChart),

            // Line chart
            ui.text("Monthly Revenue vs Expenses (Line Chart)", .{
                .size = 16,
                .color = ui.Color.hex(0xaaaaaa),
            }),
            ui.canvas(500, 150, paintLineChart),

            // Pie chart
            ui.text("Browser Market Share (Pie Chart)", .{
                .size = 16,
                .color = ui.Color.hex(0xaaaaaa),
            }),
            ui.canvas(200, 200, paintPieChart),

            // Donut chart
            ui.text("Budget Allocation (Donut Chart)", .{
                .size = 16,
                .color = ui.Color.hex(0xaaaaaa),
            }),
            ui.canvas(200, 200, paintDonutChart),

            // Scatter chart
            ui.text("Height vs Weight (Scatter Chart)", .{
                .size = 16,
                .color = ui.Color.hex(0xaaaaaa),
            }),
            ui.canvas(500, 200, paintScatterChart),

            // Progress ring
            ui.text("Task Progress (Ring)", .{
                .size = 16,
                .color = ui.Color.hex(0xaaaaaa),
            }),
            ui.canvas(200, 200, paintProgressRing),

            // Themed line chart (dark theme)
            ui.text("Themed Line Chart (Dark Theme - Tableau Palette)", .{
                .size = 16,
                .color = ui.Color.hex(0xaaaaaa),
            }),
            ui.canvas(500, 200, paintThemedLineChart),
        });
    }
};

fn paintBarChart(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();

    // Skip rendering if canvas has no size yet
    if (w <= 0 or h <= 0) return;

    // Background
    ctx.fillRoundedRect(0, 0, w, h, 8, ui.Color.hex(0x16213e));

    // Create bar chart referencing the static data slice
    var chart = charts.BarChart.init(&bar_chart_data);
    chart.width = w;
    chart.height = h;
    chart.margin_top = 20;
    chart.margin_right = 20;
    chart.margin_bottom = 40;
    chart.margin_left = 50;
    chart.corner_radius = 4;
    chart.show_grid = true;
    chart.grid_opts = .{
        .show_horizontal = true,
        .show_vertical = false,
        .color = ui.Color.hex(0x2a3a5e),
        .line_width = 1,
    };
    chart.x_axis_opts = .{
        .orientation = .bottom,
        .color = ui.Color.hex(0x4a5a7e),
        .label_color = ui.Color.hex(0xcccccc),
    };
    chart.y_axis_opts = .{
        .orientation = .left,
        .color = ui.Color.hex(0x4a5a7e),
        .label_color = ui.Color.hex(0xcccccc),
    };

    chart.render(ctx);
}

fn paintThemedLineChart(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();

    if (w <= 0 or h <= 0) return;

    // Background using theme color
    ctx.fillRoundedRect(0, 0, w, h, 8, dark_theme.background);

    // Create line chart with theme - series colors come from theme palette
    var chart = charts.LineChart.init(&themed_line_data);
    chart.width = w;
    chart.height = h;
    chart.margin_top = 20;
    chart.margin_right = 20;
    chart.margin_bottom = 40;
    chart.margin_left = 50;
    chart.line_width = 2.5;
    chart.show_points = true;
    chart.point_radius = 5;
    chart.show_area = true;
    chart.area_opacity = 0.15;
    chart.show_grid = true;
    chart.chart_theme = &dark_theme; // Apply theme for axis/grid/palette colors

    chart.render(ctx);

    // Draw legend with theme colors
    const legend_items = [_]charts.Legend.Item{
        charts.Legend.Item.initWithShape("Series A", dark_theme.palette[0], .line),
        charts.Legend.Item.initWithShape("Series B", dark_theme.palette[1], .line),
        charts.Legend.Item.initWithShape("Series C", dark_theme.palette[2], .line),
    };

    _ = charts.Legend.draw(ctx, .{
        .x = 60,
        .y = 0,
        .width = w - 80,
        .height = 30,
    }, &legend_items, .{
        .position = .top,
        .color = dark_theme.foreground,
        .item_size = 10,
        .font_size = 10,
    });
}

fn paintLineChart(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();

    // Skip rendering if canvas has no size yet
    if (w <= 0 or h <= 0) return;

    // Background
    ctx.fillRoundedRect(0, 0, w, h, 8, ui.Color.hex(0x16213e));

    // Legend items for this chart
    const legend_items = [_]charts.Legend.Item{
        charts.Legend.Item.initWithShape("Revenue", charts.Color.hex(0x34a853), .line),
        charts.Legend.Item.initWithShape("Expenses", charts.Color.hex(0xea4335), .line),
    };

    // Calculate legend dimensions to adjust chart margins
    const legend_opts = charts.Legend.Options{
        .position = .top,
        .color = ui.Color.hex(0xcccccc),
        .spacing = 24,
        .item_size = 16,
        .font_size = 10,
    };
    const legend_dims = charts.Legend.calculateDimensions(&legend_items, legend_opts);

    // Create line chart referencing the static data slice
    var chart = charts.LineChart.init(&line_chart_data);
    chart.width = w;
    chart.height = h;
    chart.margin_top = 10 + legend_dims.height; // Extra space for legend
    chart.margin_right = 20;
    chart.margin_bottom = 40;
    chart.margin_left = 50;
    chart.line_width = 2.5;
    chart.show_points = true;
    chart.point_radius = 3;
    chart.show_area = false;
    chart.show_grid = true;
    chart.grid_opts = .{
        .show_horizontal = true,
        .show_vertical = true,
        .color = ui.Color.hex(0x2a3a5e),
        .line_width = 1,
    };
    chart.x_axis_opts = .{
        .orientation = .bottom,
        .color = ui.Color.hex(0x4a5a7e),
        .label_color = ui.Color.hex(0xcccccc),
    };
    chart.y_axis_opts = .{
        .orientation = .left,
        .color = ui.Color.hex(0x4a5a7e),
        .label_color = ui.Color.hex(0xcccccc),
    };

    chart.render(ctx);

    // Draw legend at the top
    _ = charts.Legend.draw(
        ctx,
        .{ .x = 0, .y = 5, .width = w, .height = legend_dims.height },
        &legend_items,
        legend_opts,
    );
}

fn paintPieChart(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();

    // Skip rendering if canvas has no size yet
    if (w <= 0 or h <= 0) return;

    // Background
    ctx.fillRoundedRect(0, 0, w, h, 8, ui.Color.hex(0x16213e));

    // Create pie chart referencing the static data slice
    var chart = charts.PieChart.init(&pie_chart_data);
    chart.width = w;
    chart.height = h;
    chart.inner_radius_ratio = 0; // Full pie (no hole)
    chart.gap_pixels = 3; // Consistent pixel-based gap between slices

    chart.render(ctx);
}

fn paintDonutChart(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();

    if (w <= 0 or h <= 0) return;

    ctx.fillRoundedRect(0, 0, w, h, 8, ui.Color.hex(0x16213e));

    var chart = charts.PieChart.init(&donut_chart_data);
    chart.width = w;
    chart.height = h;
    chart.inner_radius_ratio = 0.55; // 55% hole for donut
    chart.gap_pixels = 4; // Uniform gap width from inner to outer edge

    chart.render(ctx);
}

fn paintScatterChart(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();

    if (w <= 0 or h <= 0) return;

    ctx.fillRoundedRect(0, 0, w, h, 8, ui.Color.hex(0x16213e));

    // Legend items for scatter chart
    const legend_items = [_]charts.Legend.Item{
        charts.Legend.Item.initWithShape("Male", charts.Color.hex(0x4285f4), .circle),
        charts.Legend.Item.initWithShape("Female", charts.Color.hex(0xea4335), .circle),
    };

    // Calculate legend dimensions
    const legend_opts = charts.Legend.Options{
        .position = .right,
        .color = ui.Color.hex(0xcccccc),
        .spacing = 12,
        .item_size = 12,
        .font_size = 10,
    };
    const legend_dims = charts.Legend.calculateDimensions(&legend_items, legend_opts);

    // Create scatter chart referencing the static data slice
    var chart = charts.ScatterChart.init(&scatter_chart_data);
    chart.width = w;
    chart.height = h;
    chart.margin_top = 20;
    chart.margin_right = 20 + legend_dims.width; // Extra space for legend on right
    chart.margin_bottom = 40;
    chart.margin_left = 50;
    chart.point_radius = 5;
    chart.point_shape = .circle;
    chart.point_opacity = 0.85;
    chart.show_grid = true;
    chart.grid_opts = .{
        .show_horizontal = true,
        .show_vertical = true,
        .color = ui.Color.hex(0x2a3a5e),
        .line_width = 1,
    };
    chart.x_axis_opts = .{
        .orientation = .bottom,
        .color = ui.Color.hex(0x4a5a7e),
        .label_color = ui.Color.hex(0xcccccc),
    };
    chart.y_axis_opts = .{
        .orientation = .left,
        .color = ui.Color.hex(0x4a5a7e),
        .label_color = ui.Color.hex(0xcccccc),
    };

    chart.render(ctx);

    // Draw legend on the right side
    _ = charts.Legend.draw(
        ctx,
        .{ .x = 0, .y = 0, .width = w, .height = h },
        &legend_items,
        legend_opts,
    );
}

fn paintProgressRing(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();

    if (w <= 0 or h <= 0) return;

    ctx.fillRoundedRect(0, 0, w, h, 8, ui.Color.hex(0x16213e));

    // Progress ring: thin donut showing 73% complete
    const progress_data = [_]charts.CategoryPoint{
        charts.CategoryPoint.initColored("Complete", 73, charts.Color.hex(0x34a853)),
        charts.CategoryPoint.initColored("Remaining", 27, charts.Color.hex(0x3a4a6e)),
    };

    var chart = charts.PieChart.init(&progress_data);
    chart.width = w;
    chart.height = h;
    chart.inner_radius_ratio = 0.75; // Thin ring
    chart.pad_angle = 0;

    chart.render(ctx);

    // Center marker (placeholder for "73%" text)
    ctx.fillCircleAdaptive(w / 2, h / 2, 8, ui.Color.hex(0x34a853));
}

// =============================================================================
// Tests
// =============================================================================

test "AppState" {
    const s = AppState{};
    try std.testing.expectEqual(@as(u32, 0), s.frame);
}

test "BarChart struct is small" {
    // Verify the fix worked - BarChart should be < 200 bytes, not ~300KB
    try std.testing.expect(@sizeOf(charts.BarChart) < 200);
}

test "LineChart struct is small" {
    // LineChart should also be small - just a slice pointer + options
    try std.testing.expect(@sizeOf(charts.LineChart) < 300);
}

test "PieChart struct is small" {
    // PieChart should be very small - just a slice pointer + options
    try std.testing.expect(@sizeOf(charts.PieChart) < 100);
}

test "ScatterChart struct is small" {
    // ScatterChart should be small - just a slice pointer + options
    try std.testing.expect(@sizeOf(charts.ScatterChart) < 300);
}
