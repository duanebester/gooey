//! Chart Theme — Color and Style Definitions for Charts
//!
//! Provides a `ChartTheme` struct that integrates with Gooey's theme system
//! while adding chart-specific colors like categorical palettes and semantic
//! colors for data visualization.
//!
//! ## Usage
//!
//! ```zig
//! const gooey = @import("gooey");
//! const charts = @import("gooey-charts");
//!
//! // Create theme from Gooey's theme
//! const chart_theme = charts.ChartTheme.fromTheme(&gooey.ui.Theme.dark);
//!
//! // Or use built-in presets
//! const light_theme = charts.ChartTheme.light;
//! const dark_theme = charts.ChartTheme.dark;
//!
//! // Get colors from palette
//! const series_color = chart_theme.palette[0];
//! ```

const std = @import("std");
const gooey = @import("gooey");
const Color = gooey.ui.Color;
const Theme = gooey.ui.Theme;

// =============================================================================
// Constants
// =============================================================================

/// Maximum colors in the categorical palette
pub const MAX_PALETTE_COLORS = 12;

// =============================================================================
// ChartTheme
// =============================================================================

/// Theme for chart components with colors optimized for data visualization.
/// Inherits base colors from Gooey's Theme and adds chart-specific palettes.
pub const ChartTheme = struct {
    // =========================================================================
    // Base Colors (inherited from Gooey theme)
    // =========================================================================

    /// Chart background color
    background: Color,

    /// Primary foreground (text, axis lines, tick marks)
    foreground: Color,

    /// Secondary foreground (grid lines, muted elements)
    muted: Color,

    /// Surface color for chart cards/containers
    surface: Color,

    /// Border color for chart containers
    border: Color,

    // =========================================================================
    // Categorical Palette (for series differentiation)
    // =========================================================================

    /// 12-color palette for categorical data and multi-series charts.
    /// Colors are chosen for visual distinction and accessibility.
    palette: [MAX_PALETTE_COLORS]Color = default_palette,

    // =========================================================================
    // Semantic Colors (for meaning-carrying data)
    // =========================================================================

    /// Positive values: profit, growth, success (green)
    positive: Color,

    /// Negative values: loss, decline, error (red)
    negative: Color,

    /// Neutral values: unchanged, baseline (gray)
    neutral: Color,

    // =========================================================================
    // Axis & Grid Styling
    // =========================================================================

    /// Axis line color (defaults to foreground)
    axis_color: Color,

    /// Grid line color (defaults to muted with alpha)
    grid_color: Color,

    /// Tick label color (defaults to foreground)
    tick_color: Color,

    /// Axis label color (defaults to foreground)
    label_color: Color,

    // =========================================================================
    // Built-in Presets
    // =========================================================================

    /// Light theme optimized for charts (based on Catppuccin Latte)
    /// Uses Google light palette (darker colors for light backgrounds)
    pub const light = ChartTheme{
        // Base colors from light theme
        .background = Color.rgb(0.937, 0.945, 0.961), // #eff1f5
        .foreground = Color.rgb(0.298, 0.310, 0.412), // #4c4f69
        .muted = Color.rgba(0.608, 0.620, 0.694, 0.5), // #9ca0b0 @ 50%
        .surface = Color.rgb(0.902, 0.914, 0.933), // #e6e9ef
        .border = Color.rgba(0.608, 0.620, 0.694, 0.3),

        // Use Google light palette (darker colors for light backgrounds)
        .palette = google_light_palette,

        // Semantic colors
        .positive = Color.rgb(0.251, 0.627, 0.169), // #40a02b (green)
        .negative = Color.rgb(0.820, 0.239, 0.239), // #d13c3c (red)
        .neutral = Color.rgb(0.608, 0.620, 0.694), // #9ca0b0 (gray)

        // Axis & grid
        .axis_color = Color.rgb(0.424, 0.435, 0.522), // #6c6f85
        .grid_color = Color.rgba(0.608, 0.620, 0.694, 0.25), // muted @ 25%
        .tick_color = Color.rgb(0.424, 0.435, 0.522), // #6c6f85
        .label_color = Color.rgb(0.298, 0.310, 0.412), // #4c4f69
    };

    /// Dark theme optimized for charts (based on Catppuccin Macchiato)
    /// Uses Google dark palette (brighter colors for dark backgrounds)
    pub const dark = ChartTheme{
        // Base colors from dark theme
        .background = Color.rgb(0.141, 0.153, 0.227), // #24273a
        .foreground = Color.rgb(0.792, 0.827, 0.961), // #cad3f5
        .muted = Color.rgba(0.545, 0.584, 0.729, 0.5), // #8b95ba @ 50%
        .surface = Color.rgb(0.212, 0.227, 0.310), // #363a4f
        .border = Color.rgba(0.545, 0.584, 0.729, 0.3),

        // Use Google dark palette (brighter colors for dark backgrounds)
        .palette = google_dark_palette,

        // Semantic colors (brighter for dark backgrounds)
        .positive = Color.rgb(0.651, 0.855, 0.584), // #a6da95 (light green)
        .negative = Color.rgb(0.929, 0.486, 0.486), // #ed7c7c (light red)
        .neutral = Color.rgb(0.545, 0.584, 0.729), // #8b95ba (gray)

        // Axis & grid
        .axis_color = Color.rgb(0.718, 0.757, 0.898), // #b8c0e5
        .grid_color = Color.rgba(0.545, 0.584, 0.729, 0.2), // muted @ 20%
        .tick_color = Color.rgb(0.718, 0.757, 0.898), // #b8c0e5
        .label_color = Color.rgb(0.792, 0.827, 0.961), // #cad3f5
    };

    // =========================================================================
    // Construction
    // =========================================================================

    /// Create a ChartTheme from a Gooey Theme.
    /// Maps semantic colors appropriately for chart visualization.
    pub fn fromTheme(theme: *const Theme) ChartTheme {
        std.debug.assert(theme.bg.a > 0); // Valid theme

        return ChartTheme{
            // Map Gooey theme colors to chart colors
            .background = theme.bg,
            .foreground = theme.text,
            .muted = theme.muted.withAlpha(0.5),
            .surface = theme.surface,
            .border = theme.border,

            // Semantic colors from theme
            .positive = theme.success,
            .negative = theme.danger,
            .neutral = theme.muted,

            // Axis & grid derived from theme
            .axis_color = theme.subtext,
            .grid_color = theme.muted.withAlpha(0.25),
            .tick_color = theme.subtext,
            .label_color = theme.text,
        };
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// Get a color from the palette by index (wraps around).
    pub fn paletteColor(self: *const ChartTheme, index: usize) Color {
        return self.palette[index % MAX_PALETTE_COLORS];
    }

    /// Get a color with modified alpha, useful for hover/area fills.
    pub fn withAlpha(self: *const ChartTheme, color: Color, alpha: f32) Color {
        _ = self;
        std.debug.assert(alpha >= 0.0 and alpha <= 1.0);
        return color.withAlpha(alpha);
    }

    /// Determine if this is a dark theme (for contrast decisions).
    pub fn isDark(self: *const ChartTheme) bool {
        // Calculate perceived luminance of background
        const luminance = 0.299 * self.background.r +
            0.587 * self.background.g +
            0.114 * self.background.b;
        return luminance < 0.5;
    }

    /// Get contrasting text color for a given background.
    /// Useful for labels placed on colored bars/slices.
    pub fn contrastingText(self: *const ChartTheme, bg: Color) Color {
        const luminance = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b;
        if (luminance > 0.5) {
            // Light background -> dark text
            return if (self.isDark()) self.foreground else Color.rgb(0.1, 0.1, 0.1);
        } else {
            // Dark background -> light text
            return if (self.isDark()) Color.rgb(0.95, 0.95, 0.95) else self.background;
        }
    }
};

// =============================================================================
// Default Palette (Google-style, the single source of truth)
// =============================================================================

/// Google-style palette optimized for light backgrounds.
/// Darker, more saturated colors for better contrast on light backgrounds.
/// This is the canonical Google palette - all chart files should reference this.
pub const google_light_palette = [MAX_PALETTE_COLORS]Color{
    Color.hex(0x1a73e8), // Google Blue (darker)
    Color.hex(0xd93025), // Google Red (darker)
    Color.hex(0xf9ab00), // Google Yellow (darker)
    Color.hex(0x1e8e3e), // Google Green (darker)
    Color.hex(0xe65100), // Orange (darker)
    Color.hex(0x00838f), // Teal (darker)
    Color.hex(0x6a1b9a), // Purple (darker)
    Color.hex(0xad1457), // Pink (darker)
    Color.hex(0x00695c), // Dark Teal
    Color.hex(0x4e342e), // Brown (darker)
    Color.hex(0x37474f), // Blue Grey (darker)
    Color.hex(0xbf360c), // Deep Orange (darker)
};

/// Google-style palette optimized for dark backgrounds.
/// Brighter colors for better visibility on dark backgrounds.
pub const google_dark_palette = [MAX_PALETTE_COLORS]Color{
    Color.hex(0x8ab4f8), // Google Blue (lighter)
    Color.hex(0xf28b82), // Google Red (lighter)
    Color.hex(0xfdd663), // Google Yellow (lighter)
    Color.hex(0x81c995), // Google Green (lighter)
    Color.hex(0xfcad70), // Orange (lighter)
    Color.hex(0x78d9ec), // Teal (lighter)
    Color.hex(0xc58af9), // Purple (lighter)
    Color.hex(0xf48fb1), // Pink (lighter)
    Color.hex(0x4db6ac), // Dark Teal (lighter)
    Color.hex(0xa1887f), // Brown (lighter)
    Color.hex(0x90a4ae), // Blue Grey (lighter)
    Color.hex(0xffab91), // Deep Orange (lighter)
};

/// Standard Google palette (balanced for general use).
/// For theme-specific rendering, prefer google_light_palette or google_dark_palette.
pub const google_palette = [MAX_PALETTE_COLORS]Color{
    Color.hex(0x4285f4), // Google Blue
    Color.hex(0xea4335), // Google Red
    Color.hex(0xfbbc05), // Google Yellow
    Color.hex(0x34a853), // Google Green
    Color.hex(0xff6d01), // Orange
    Color.hex(0x46bdc6), // Teal
    Color.hex(0x7b1fa2), // Purple
    Color.hex(0xc2185b), // Pink
    Color.hex(0x00796b), // Dark Teal
    Color.hex(0x5d4037), // Brown
    Color.hex(0x455a64), // Blue Grey
    Color.hex(0xe65100), // Deep Orange
};

/// Default palette - use Google light palette as the default.
/// This is the single source of truth that chart files should import.
pub const default_palette = google_light_palette;

// =============================================================================
// Alternative Palettes
// =============================================================================

/// Colorblind-safe palette (deuteranopia/protanopia friendly)
pub const colorblind_palette = [MAX_PALETTE_COLORS]Color{
    Color.hex(0x0077BB), // Blue
    Color.hex(0xEE7733), // Orange
    Color.hex(0x009988), // Teal
    Color.hex(0xCC3311), // Red
    Color.hex(0x33BBEE), // Cyan
    Color.hex(0xEE3377), // Magenta
    Color.hex(0xBBBBBB), // Gray
    Color.hex(0x000000), // Black
    Color.hex(0x44AA99), // Teal 2
    Color.hex(0x882255), // Wine
    Color.hex(0x999933), // Olive
    Color.hex(0xDDCC77), // Sand
};

/// Monochrome palette (single hue, varying lightness)
pub const monochrome_blue_palette = [MAX_PALETTE_COLORS]Color{
    Color.hex(0x08306b), // Darkest
    Color.hex(0x08519c),
    Color.hex(0x2171b5),
    Color.hex(0x4292c6),
    Color.hex(0x6baed6),
    Color.hex(0x9ecae1),
    Color.hex(0xc6dbef),
    Color.hex(0xdeebf7), // Lightest
    Color.hex(0x3182bd),
    Color.hex(0x9ecae1),
    Color.hex(0x6baed6),
    Color.hex(0x4292c6),
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "ChartTheme.light has valid colors" {
    const t = ChartTheme.light;

    // Background should be light
    try testing.expect(t.background.r > 0.5);
    try testing.expect(!t.isDark());

    // All palette colors should have full opacity
    for (t.palette) |color| {
        try testing.expectEqual(@as(f32, 1.0), color.a);
    }
}

test "ChartTheme.dark has valid colors" {
    const t = ChartTheme.dark;

    // Background should be dark
    try testing.expect(t.background.r < 0.5);
    try testing.expect(t.isDark());
}

test "ChartTheme.fromTheme maps colors correctly" {
    const t = ChartTheme.fromTheme(&Theme.dark);

    // Should inherit background from theme
    try testing.expectEqual(Theme.dark.bg.r, t.background.r);
    try testing.expectEqual(Theme.dark.bg.g, t.background.g);
    try testing.expectEqual(Theme.dark.bg.b, t.background.b);

    // Should map semantic colors
    try testing.expectEqual(Theme.dark.success.r, t.positive.r);
    try testing.expectEqual(Theme.dark.danger.r, t.negative.r);
}

test "ChartTheme.paletteColor wraps around" {
    const t = ChartTheme.light;

    // Index within bounds
    try testing.expectEqual(t.palette[0].r, t.paletteColor(0).r);
    try testing.expectEqual(t.palette[5].r, t.paletteColor(5).r);

    // Index wraps around
    try testing.expectEqual(t.palette[0].r, t.paletteColor(12).r);
    try testing.expectEqual(t.palette[1].r, t.paletteColor(13).r);
}

test "ChartTheme.withAlpha adjusts alpha" {
    const t = ChartTheme.light;
    const color = t.palette[0];
    const faded = t.withAlpha(color, 0.5);

    try testing.expectEqual(@as(f32, 0.5), faded.a);
    try testing.expectEqual(color.r, faded.r);
    try testing.expectEqual(color.g, faded.g);
    try testing.expectEqual(color.b, faded.b);
}

test "ChartTheme.contrastingText returns readable color" {
    const t = ChartTheme.light;

    // Dark background should get light text
    const dark_bg = Color.rgb(0.1, 0.1, 0.1);
    const light_text = t.contrastingText(dark_bg);
    const light_lum = 0.299 * light_text.r + 0.587 * light_text.g + 0.114 * light_text.b;
    try testing.expect(light_lum > 0.5);

    // Light background should get dark text
    const light_bg = Color.rgb(0.9, 0.9, 0.9);
    const dark_text = t.contrastingText(light_bg);
    const dark_lum = 0.299 * dark_text.r + 0.587 * dark_text.g + 0.114 * dark_text.b;
    try testing.expect(dark_lum < 0.5);
}

test "default_palette has 12 distinct colors" {
    try testing.expectEqual(@as(usize, 12), default_palette.len);

    // Check first and last are different
    try testing.expect(default_palette[0].r != default_palette[11].r or
        default_palette[0].g != default_palette[11].g or
        default_palette[0].b != default_palette[11].b);
}

test "ChartTheme struct size is reasonable" {
    // ChartTheme should be small enough to pass by value
    // 12 colors * 16 bytes + ~16 base colors * 16 bytes = ~448 bytes max
    try testing.expect(@sizeOf(ChartTheme) < 512);
}
