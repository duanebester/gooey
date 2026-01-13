//! Dashboard Example
//!
//! A polished analytics dashboard demonstrating gooey-charts with modern styling.
//! Features a consistent color palette, refined typography, and cohesive theming.
//!
//! Features demonstrated:
//!   - Multiple chart types in grid layout
//!   - Consistent color palette across all visualizations
//!   - Theme integration (dark/light toggle with [T])
//!   - Professional KPI cards with gradient accents
//!   - Real-world data patterns

const std = @import("std");
const gooey = @import("gooey");
const charts = @import("gooey-charts");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Theme = gooey.Theme;

// =============================================================================
// Constants (per CLAUDE.md — hard limits on everything)
// =============================================================================

const MAX_MONTHS: u32 = 12;
const MAX_CATEGORIES: u32 = 8;
const MAX_SERIES: u32 = 4;

// =============================================================================
// Consistent Color Palette
// =============================================================================

/// Modern color palette - all chart colors derive from this
const Palette = struct {
    // Primary accent - vibrant cyan/teal
    const primary = ui.Color.hex(0x06b6d4);
    const primary_light = ui.Color.hex(0x22d3ee);
    const primary_dark = ui.Color.hex(0x0891b2);

    // Secondary - purple/violet
    const secondary = ui.Color.hex(0x8b5cf6);
    const secondary_light = ui.Color.hex(0xa78bfa);

    // Success - emerald green
    const success = ui.Color.hex(0x10b981);
    const success_light = ui.Color.hex(0x34d399);

    // Warning - amber
    const warning = ui.Color.hex(0xf59e0b);
    const warning_light = ui.Color.hex(0xfbbf24);

    // Danger - rose/red
    const danger = ui.Color.hex(0xf43f5e);
    const danger_light = ui.Color.hex(0xfb7185);

    // Neutral tones
    const neutral = ui.Color.hex(0x64748b);
    const neutral_light = ui.Color.hex(0x94a3b8);

    // Chart series colors (consistent order)
    const series = [_]ui.Color{
        primary, // Cyan
        secondary, // Purple
        success, // Green
        warning, // Amber
        danger, // Rose
        neutral, // Slate
    };

    fn chartColor(c: ui.Color) charts.Color {
        return charts.Color{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
    }
};

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    is_dark_theme: bool = true,
    selected_period: u8 = 0, // 0=YTD, 1=Q4, 2=Q3
};

// =============================================================================
// Theme Configuration
// =============================================================================

const dark_theme = charts.ChartTheme.dark;
const light_theme = charts.ChartTheme.light;

fn currentTheme() *const charts.ChartTheme {
    return if (state.is_dark_theme) &dark_theme else &light_theme;
}

fn backgroundColor() ui.Color {
    return if (state.is_dark_theme) ui.Color.hex(0x0f172a) else ui.Color.hex(0xf1f5f9);
}

fn cardBackground() ui.Color {
    return if (state.is_dark_theme) ui.Color.hex(0x1e293b) else ui.Color.hex(0xffffff);
}

fn cardBackgroundHover() ui.Color {
    return if (state.is_dark_theme) ui.Color.hex(0x334155) else ui.Color.hex(0xf8fafc);
}

fn textColor() ui.Color {
    return if (state.is_dark_theme) ui.Color.hex(0xf1f5f9) else ui.Color.hex(0x1e293b);
}

fn mutedTextColor() ui.Color {
    return if (state.is_dark_theme) ui.Color.hex(0x94a3b8) else ui.Color.hex(0x64748b);
}

fn gridColor() ui.Color {
    return if (state.is_dark_theme) ui.Color.hex(0x334155) else ui.Color.hex(0xe2e8f0);
}

fn axisColor() ui.Color {
    return if (state.is_dark_theme) ui.Color.hex(0x475569) else ui.Color.hex(0xcbd5e1);
}

fn accentGlow() ui.Color {
    return if (state.is_dark_theme)
        Palette.primary.withAlpha(0.15)
    else
        Palette.primary.withAlpha(0.08);
}

// =============================================================================
// Chart Data (stored statically to avoid stack overflow)
// =============================================================================

// Revenue trend (line chart) - monthly data
var revenue_data: [2]charts.Series = undefined;

// Sales by category (bar chart)
var category_sales: charts.CategorySeries = undefined;
var category_data: [1]charts.CategorySeries = undefined;

// Traffic sources (pie chart)
var traffic_data: [5]charts.CategoryPoint = undefined;

// Conversion funnel (horizontal bar concept via pie)
var funnel_data: [4]charts.CategoryPoint = undefined;

// Customer segments (scatter - spend vs visits)
var segment_data: [3]charts.Series = undefined;

// KPI values
var kpi_revenue: f32 = 0;
var kpi_revenue_change: f32 = 0;
var kpi_customers: u32 = 0;
var kpi_customers_change: f32 = 0;
var kpi_conversion: f32 = 0;
var kpi_conversion_change: f32 = 0;
var kpi_avg_order: f32 = 0;
var kpi_avg_order_change: f32 = 0;

var data_initialized: bool = false;

fn ensureDataInitialized() void {
    if (data_initialized) return;

    // KPI values
    kpi_revenue = 1_247_832;
    kpi_revenue_change = 12.4;
    kpi_customers = 8_432;
    kpi_customers_change = 8.7;
    kpi_conversion = 3.24;
    kpi_conversion_change = -0.3;
    kpi_avg_order = 148.05;
    kpi_avg_order_change = 5.2;

    // Revenue trend: Revenue vs Target (12 months) - Using primary color
    revenue_data[0].initInPlace("Revenue", Palette.chartColor(Palette.primary));
    revenue_data[0].addPoint(charts.DataPoint.init(1, 89));
    revenue_data[0].addPoint(charts.DataPoint.init(2, 94));
    revenue_data[0].addPoint(charts.DataPoint.init(3, 102));
    revenue_data[0].addPoint(charts.DataPoint.init(4, 98));
    revenue_data[0].addPoint(charts.DataPoint.init(5, 112));
    revenue_data[0].addPoint(charts.DataPoint.init(6, 118));
    revenue_data[0].addPoint(charts.DataPoint.init(7, 108));
    revenue_data[0].addPoint(charts.DataPoint.init(8, 125));
    revenue_data[0].addPoint(charts.DataPoint.init(9, 132));
    revenue_data[0].addPoint(charts.DataPoint.init(10, 128));
    revenue_data[0].addPoint(charts.DataPoint.init(11, 142));
    revenue_data[0].addPoint(charts.DataPoint.init(12, 156));

    revenue_data[1].initInPlace("Target", Palette.chartColor(Palette.neutral_light));
    revenue_data[1].addPoint(charts.DataPoint.init(1, 85));
    revenue_data[1].addPoint(charts.DataPoint.init(2, 90));
    revenue_data[1].addPoint(charts.DataPoint.init(3, 95));
    revenue_data[1].addPoint(charts.DataPoint.init(4, 100));
    revenue_data[1].addPoint(charts.DataPoint.init(5, 105));
    revenue_data[1].addPoint(charts.DataPoint.init(6, 110));
    revenue_data[1].addPoint(charts.DataPoint.init(7, 115));
    revenue_data[1].addPoint(charts.DataPoint.init(8, 120));
    revenue_data[1].addPoint(charts.DataPoint.init(9, 125));
    revenue_data[1].addPoint(charts.DataPoint.init(10, 130));
    revenue_data[1].addPoint(charts.DataPoint.init(11, 135));
    revenue_data[1].addPoint(charts.DataPoint.init(12, 140));

    // Sales by category - Using palette colors
    category_sales = charts.CategorySeries.init("Sales", null);
    category_sales.addPoint(charts.CategoryPoint.init("Electronics", 342));
    category_sales.addPoint(charts.CategoryPoint.init("Clothing", 256));
    category_sales.addPoint(charts.CategoryPoint.init("Home", 189));
    category_sales.addPoint(charts.CategoryPoint.init("Sports", 145));
    category_sales.addPoint(charts.CategoryPoint.init("Books", 98));
    category_data[0] = category_sales;

    // Traffic sources - Using consistent palette
    traffic_data[0] = charts.CategoryPoint.initColored("Organic", 42, Palette.chartColor(Palette.success));
    traffic_data[1] = charts.CategoryPoint.initColored("Paid", 28, Palette.chartColor(Palette.primary));
    traffic_data[2] = charts.CategoryPoint.initColored("Social", 15, Palette.chartColor(Palette.warning));
    traffic_data[3] = charts.CategoryPoint.initColored("Direct", 10, Palette.chartColor(Palette.secondary));
    traffic_data[4] = charts.CategoryPoint.initColored("Referral", 5, Palette.chartColor(Palette.neutral));

    // Conversion funnel - Using palette progression
    funnel_data[0] = charts.CategoryPoint.initColored("Visitors", 100, Palette.chartColor(Palette.primary));
    funnel_data[1] = charts.CategoryPoint.initColored("Engaged", 45, Palette.chartColor(Palette.secondary));
    funnel_data[2] = charts.CategoryPoint.initColored("Cart", 18, Palette.chartColor(Palette.warning));
    funnel_data[3] = charts.CategoryPoint.initColored("Purchased", 8, Palette.chartColor(Palette.success));

    // Customer segments: Average Order Value vs Visit Frequency
    segment_data[0].initInPlace("Premium", Palette.chartColor(Palette.secondary));
    segment_data[0].addPoint(charts.DataPoint.init(2.1, 285));
    segment_data[0].addPoint(charts.DataPoint.init(3.2, 320));
    segment_data[0].addPoint(charts.DataPoint.init(2.8, 298));
    segment_data[0].addPoint(charts.DataPoint.init(4.1, 345));
    segment_data[0].addPoint(charts.DataPoint.init(3.5, 312));

    segment_data[1].initInPlace("Regular", Palette.chartColor(Palette.primary));
    segment_data[1].addPoint(charts.DataPoint.init(1.2, 125));
    segment_data[1].addPoint(charts.DataPoint.init(1.8, 148));
    segment_data[1].addPoint(charts.DataPoint.init(2.2, 165));
    segment_data[1].addPoint(charts.DataPoint.init(1.5, 138));
    segment_data[1].addPoint(charts.DataPoint.init(2.5, 175));
    segment_data[1].addPoint(charts.DataPoint.init(1.9, 155));
    segment_data[1].addPoint(charts.DataPoint.init(2.8, 182));

    segment_data[2].initInPlace("Casual", Palette.chartColor(Palette.neutral));
    segment_data[2].addPoint(charts.DataPoint.init(0.3, 45));
    segment_data[2].addPoint(charts.DataPoint.init(0.5, 62));
    segment_data[2].addPoint(charts.DataPoint.init(0.8, 78));
    segment_data[2].addPoint(charts.DataPoint.init(0.4, 55));
    segment_data[2].addPoint(charts.DataPoint.init(0.6, 68));
    segment_data[2].addPoint(charts.DataPoint.init(0.9, 85));

    data_initialized = true;
}

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Analytics Dashboard",
    .width = 1200,
    .height = 800,
    .on_event = onEvent,
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
    ensureDataInitialized();

    const size = cx.windowSize();
    const bg = backgroundColor();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 24 },
        .gap = 20,
        .direction = .column,
        .background = bg,
    }, .{
        // Header
        DashboardHeader{},

        // Main content area
        DashboardContent{},
    }));
}

// =============================================================================
// Dashboard Header
// =============================================================================

const DashboardHeader = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const text_col = textColor();
        const muted_col = mutedTextColor();

        cx.render(ui.box(.{
            .direction = .row,
            .alignment = .{ .main = .space_between, .cross = .center },
        }, .{
            // Title with accent
            ui.box(.{ .gap = 4, .direction = .column }, .{
                ui.box(.{ .direction = .row, .gap = 12, .alignment = .{ .cross = .center } }, .{
                    // Accent dot
                    ui.canvas(8, 8, paintAccentDot),
                    ui.text("Analytics Dashboard", .{
                        .size = 26,
                        .color = text_col,
                    }),
                }),
                ui.text("Real-time business metrics & insights", .{
                    .size = 13,
                    .color = muted_col,
                }),
            }),

            // Theme toggle badge
            ui.box(.{
                .padding = .{ .symmetric = .{ .x = 12, .y = 6 } },
                .corner_radius = 6,
                .background = cardBackground(),
            }, .{
                ui.text("[T] Toggle theme", .{
                    .size = 11,
                    .color = muted_col,
                }),
            }),
        }));
    }
};

fn paintAccentDot(ctx: *ui.DrawContext) void {
    ctx.fillCircleAdaptive(4, 4, 4, Palette.primary);
}

// =============================================================================
// Dashboard Content
// =============================================================================

const DashboardContent = struct {
    // Content height constants for scroll calculation
    const kpi_row_height: f32 = 110;
    const revenue_chart_height: f32 = 240;
    const category_chart_height: f32 = 220;
    const traffic_chart_height: f32 = 240;
    const segments_chart_height: f32 = 240;
    const conversion_chart_height: f32 = 220;
    const section_label_height: f32 = 28;
    const gap: f32 = 20;

    // Total content height calculation
    const total_content_height: f32 = kpi_row_height +
        revenue_chart_height + category_chart_height + traffic_chart_height +
        segments_chart_height + conversion_chart_height +
        (5 * section_label_height) + (11 * gap);

    pub fn render(_: @This(), cx: *Cx) void {
        const size = cx.windowSize();
        const content_height = size.height - 130;

        cx.render(ui.scroll("dashboard-scroll", .{
            .width = size.width - 48,
            .height = content_height,
            .content_height = total_content_height,
            .gap = gap,
            .track_color = gridColor(),
            .thumb_color = Palette.primary.withAlpha(0.5),
        }, .{
            // KPI Cards Row
            ui.canvas(780, kpi_row_height, paintKPIRow),

            // Revenue Trend Section
            SectionLabel{ .title = "Revenue Trend", .subtitle = "Monthly performance vs target" },
            ui.canvas(720, revenue_chart_height, paintRevenueTrend),

            // Sales by Category Section
            SectionLabel{ .title = "Sales by Category", .subtitle = "Top performing categories" },
            ui.canvas(520, category_chart_height, paintCategorySales),

            // Traffic Sources Section
            SectionLabel{ .title = "Traffic Sources", .subtitle = "Visitor acquisition channels" },
            ui.canvas(300, traffic_chart_height, paintTrafficSources),

            // Customer Segments Section
            SectionLabel{ .title = "Customer Segments", .subtitle = "Order value vs visit frequency" },
            ui.canvas(520, segments_chart_height, paintCustomerSegments),

            // Conversion Rate Section
            SectionLabel{ .title = "Conversion Rate", .subtitle = "Overall funnel performance" },
            ui.canvas(220, conversion_chart_height, paintConversionRing),
        }));
    }
};

// =============================================================================
// Section Label Component
// =============================================================================

const SectionLabel = struct {
    title: []const u8,
    subtitle: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{ .direction = .row, .gap = 8, .alignment = .{ .cross = .end } }, .{
            ui.text(self.title, .{
                .size = 15,
                .color = textColor(),
            }),
            ui.text(self.subtitle, .{
                .size = 11,
                .color = mutedTextColor(),
            }),
        }));
    }
};

// =============================================================================
// KPI Row Paint Function
// =============================================================================

fn paintKPIRow(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();

    if (w <= 0 or h <= 0) return;

    const card_bg = cardBackground();
    const text_col = textColor();
    const muted_col = mutedTextColor();

    const card_width: f32 = 185;
    const card_height: f32 = h - 10;
    const card_gap: f32 = 16;

    const kpis = [_]struct {
        label: []const u8,
        value: []const u8,
        change: []const u8,
        positive: bool,
        accent: ui.Color,
    }{
        .{ .label = "Total Revenue", .value = "$1.25M", .change = "+12.4%", .positive = true, .accent = Palette.primary },
        .{ .label = "Customers", .value = "8,432", .change = "+8.7%", .positive = true, .accent = Palette.secondary },
        .{ .label = "Conversion", .value = "3.24%", .change = "-0.3%", .positive = false, .accent = Palette.warning },
        .{ .label = "Avg Order", .value = "$148", .change = "+5.2%", .positive = true, .accent = Palette.success },
    };

    for (kpis, 0..) |kpi, i| {
        const x = @as(f32, @floatFromInt(i)) * (card_width + card_gap);

        // Card background with subtle shadow effect
        ctx.fillRoundedRect(x + 2, 4, card_width, card_height, 12, card_bg.withAlpha(0.3));
        ctx.fillRoundedRect(x, 0, card_width, card_height, 12, card_bg);

        // Top accent line
        ctx.fillRoundedRect(x + 16, 12, 40, 3, 2, kpi.accent);

        // Label placeholder
        ctx.fillRect(x + 16, 24, 70, 9, muted_col.withAlpha(0.25));

        // Value placeholder (larger)
        ctx.fillRect(x + 16, 44, 90, 22, text_col.withAlpha(0.25));

        // Change indicator with background pill
        const change_color = if (kpi.positive) Palette.success else Palette.danger;
        ctx.fillRoundedRect(x + 16, 76, 52, 18, 9, change_color.withAlpha(0.15));
        ctx.fillRect(x + 24, 81, 36, 8, change_color.withAlpha(0.6));
    }
}

// =============================================================================
// Chart Paint Functions
// =============================================================================

fn paintRevenueTrend(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();
    if (w <= 0 or h <= 0) return;

    // Card with subtle glow effect
    ctx.fillRoundedRect(2, 4, w - 2, h - 2, 12, cardBackground().withAlpha(0.3));
    ctx.fillRoundedRect(0, 0, w, h, 12, cardBackground());

    const theme = currentTheme();

    // Legend
    const legend_items = [_]charts.Legend.Item{
        charts.Legend.Item.initWithShape("Revenue", Palette.chartColor(Palette.primary), .line),
        charts.Legend.Item.initWithShape("Target", Palette.chartColor(Palette.neutral_light), .line),
    };

    const legend_opts = charts.Legend.Options{
        .position = .top,
        .color = theme.foreground,
        .spacing = 24,
        .item_size = 14,
        .font_size = 11,
    };
    const legend_dims = charts.Legend.calculateDimensions(&legend_items, legend_opts);

    var chart = charts.LineChart.init(&revenue_data);
    chart.width = w;
    chart.height = h;
    chart.margin_top = 16 + legend_dims.height;
    chart.margin_right = 20;
    chart.margin_bottom = 40;
    chart.margin_left = 50;
    chart.line_width = 2.5;
    chart.show_points = true;
    chart.point_radius = 4;
    chart.show_area = true;
    chart.area_opacity = 0.15;
    chart.show_grid = true;
    chart.chart_theme = theme;
    chart.grid_opts = .{
        .show_horizontal = true,
        .show_vertical = false,
        .color = gridColor(),
        .line_width = 1,
    };
    chart.x_axis_opts = .{
        .orientation = .bottom,
        .color = axisColor(),
        .label_color = theme.foreground,
    };
    chart.y_axis_opts = .{
        .orientation = .left,
        .color = axisColor(),
        .label_color = theme.foreground,
    };

    chart.render(ctx);

    // Draw legend
    _ = charts.Legend.draw(
        ctx,
        .{ .x = 16, .y = 14, .width = w - 32, .height = legend_dims.height },
        &legend_items,
        legend_opts,
    );
}

fn paintCategorySales(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();
    if (w <= 0 or h <= 0) return;

    ctx.fillRoundedRect(2, 4, w - 2, h - 2, 12, cardBackground().withAlpha(0.3));
    ctx.fillRoundedRect(0, 0, w, h, 12, cardBackground());

    const theme = currentTheme();

    var chart = charts.BarChart.init(&category_data);
    chart.width = w;
    chart.height = h;
    chart.margin_top = 20;
    chart.margin_right = 20;
    chart.margin_bottom = 50;
    chart.margin_left = 50;
    chart.corner_radius = 4;
    chart.bar_padding = 0.35;
    chart.show_grid = true;
    chart.chart_theme = theme;
    chart.grid_opts = .{
        .show_horizontal = true,
        .show_vertical = false,
        .color = gridColor(),
        .line_width = 1,
    };
    chart.x_axis_opts = .{
        .orientation = .bottom,
        .color = axisColor(),
        .label_color = theme.foreground,
    };
    chart.y_axis_opts = .{
        .orientation = .left,
        .color = axisColor(),
        .label_color = theme.foreground,
    };

    chart.render(ctx);
}

fn paintTrafficSources(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();
    if (w <= 0 or h <= 0) return;

    ctx.fillRoundedRect(2, 4, w - 2, h - 2, 12, cardBackground().withAlpha(0.3));
    ctx.fillRoundedRect(0, 0, w, h, 12, cardBackground());

    var chart = charts.PieChart.init(&traffic_data);
    chart.width = w;
    chart.height = h - 30; // Account for visual padding
    chart.inner_radius_ratio = 0.55;
    chart.gap_pixels = 3;

    chart.render(ctx);
}

fn paintCustomerSegments(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();
    if (w <= 0 or h <= 0) return;

    ctx.fillRoundedRect(2, 4, w - 2, h - 2, 12, cardBackground().withAlpha(0.3));
    ctx.fillRoundedRect(0, 0, w, h, 12, cardBackground());

    const theme = currentTheme();

    // Legend at top
    const legend_items = [_]charts.Legend.Item{
        charts.Legend.Item.initWithShape("Premium", Palette.chartColor(Palette.secondary), .circle),
        charts.Legend.Item.initWithShape("Regular", Palette.chartColor(Palette.primary), .circle),
        charts.Legend.Item.initWithShape("Casual", Palette.chartColor(Palette.neutral), .circle),
    };

    const legend_opts = charts.Legend.Options{
        .position = .top,
        .color = theme.foreground,
        .spacing = 20,
        .item_size = 12,
        .font_size = 11,
    };
    const legend_dims = charts.Legend.calculateDimensions(&legend_items, legend_opts);

    var chart = charts.ScatterChart.init(&segment_data);
    chart.width = w;
    chart.height = h;
    chart.margin_top = 16 + legend_dims.height;
    chart.margin_right = 20;
    chart.margin_bottom = 45;
    chart.margin_left = 50;
    chart.point_radius = 7;
    chart.point_shape = .circle;
    chart.point_opacity = 0.85;
    chart.show_grid = true;
    chart.chart_theme = theme;
    chart.grid_opts = .{
        .show_horizontal = true,
        .show_vertical = true,
        .color = gridColor(),
        .line_width = 1,
    };
    chart.x_axis_opts = .{
        .orientation = .bottom,
        .color = axisColor(),
        .label_color = theme.foreground,
    };
    chart.y_axis_opts = .{
        .orientation = .left,
        .color = axisColor(),
        .label_color = theme.foreground,
    };

    chart.render(ctx);

    // Draw legend
    _ = charts.Legend.draw(
        ctx,
        .{ .x = 16, .y = 14, .width = w - 32, .height = legend_dims.height },
        &legend_items,
        legend_opts,
    );
}

fn paintConversionRing(ctx: *ui.DrawContext) void {
    const w = ctx.width();
    const h = ctx.height();
    if (w <= 0 or h <= 0) return;

    ctx.fillRoundedRect(2, 4, w - 2, h - 2, 12, cardBackground().withAlpha(0.3));
    ctx.fillRoundedRect(0, 0, w, h, 12, cardBackground());

    // Conversion rate progress ring
    const conversion_percent: f32 = 3.24;
    const max_scale: f32 = 10.0;
    const ring_data = [_]charts.CategoryPoint{
        charts.CategoryPoint.initColored("Converted", conversion_percent, Palette.chartColor(Palette.success)),
        charts.CategoryPoint.initColored("Remaining", max_scale - conversion_percent, Palette.chartColor(gridColor())),
    };

    var chart = charts.PieChart.init(&ring_data);
    chart.width = w;
    chart.height = h - 40; // Account for visual padding
    chart.inner_radius_ratio = 0.72;
    chart.pad_angle = 0;
    chart.start_angle = -std.math.pi / 2.0; // Start from top

    chart.render(ctx);

    // Center indicator - layered circles for depth
    const cx_pos = w / 2;
    const cy_pos = h / 2;
    ctx.fillCircleAdaptive(cx_pos, cy_pos, 14, Palette.success.withAlpha(0.15));
    ctx.fillCircleAdaptive(cx_pos, cy_pos, 10, Palette.success.withAlpha(0.3));
    ctx.fillCircleAdaptive(cx_pos, cy_pos, 6, Palette.success);
}

// =============================================================================
// Event Handling
// =============================================================================

fn onEvent(cx: *Cx, event: gooey.InputEvent) bool {
    // Handle keyboard shortcuts
    if (event == .key_down) {
        const key = event.key_down;

        // T toggles theme
        if (key.key == .t) {
            state.is_dark_theme = !state.is_dark_theme;
            cx.notify();
            return true;
        }
    }

    return false;
}

// =============================================================================
// Tests
// =============================================================================

test "AppState defaults" {
    const s = AppState{};
    try std.testing.expect(s.is_dark_theme);
    try std.testing.expectEqual(@as(u8, 0), s.selected_period);
}

test "Chart struct sizes are bounded" {
    // Per CLAUDE.md — verify chart structs stay small
    try std.testing.expect(@sizeOf(charts.BarChart) < 200);
    try std.testing.expect(@sizeOf(charts.LineChart) < 350);
    try std.testing.expect(@sizeOf(charts.PieChart) < 100);
    try std.testing.expect(@sizeOf(charts.ScatterChart) < 350);
}

test "Data arrays have bounded sizes" {
    // Verify our static arrays respect limits
    try std.testing.expect(revenue_data.len <= MAX_SERIES);
    try std.testing.expect(traffic_data.len <= MAX_CATEGORIES);
    try std.testing.expect(segment_data.len <= MAX_SERIES);
}

test "Palette colors are valid" {
    // Verify palette colors have full opacity by default
    try std.testing.expectEqual(@as(u8, 255), Palette.primary.a);
    try std.testing.expectEqual(@as(u8, 255), Palette.success.a);
    try std.testing.expectEqual(@as(u8, 255), Palette.danger.a);
}
