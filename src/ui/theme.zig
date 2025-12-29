//! Theme - Semantic Color and Style Definitions
//!
//! Provides a standard `Theme` struct that components can use for consistent styling.
//! Components automatically fall back to theme colors when explicit values aren't provided.
//!
//! ## Usage
//!
//! ```zig
//! // Set theme at start of render
//! cx.setTheme(&Theme.dark);
//!
//! // Components automatically inherit theme colors:
//! TextInput{ .id = "name", .placeholder = "Enter name" }
//!
//! // Override specific colors when needed:
//! TextInput{ .id = "special", .background = Color.red }
//! ```

const Color = @import("../core/geometry.zig").Color;

/// Standard theme interface for semantic colors and styling.
/// Components resolve null color fields against the current theme.
pub const Theme = struct {
    // =========================================================================
    // Background Colors
    // =========================================================================

    /// Page/app background - the base layer
    bg: Color,
    /// Card/panel backgrounds - slightly elevated surfaces
    surface: Color,
    /// Dropdowns, tooltips, modals - highest elevation surfaces
    overlay: Color,

    // =========================================================================
    // Accent Colors
    // =========================================================================

    /// Primary actions, links, focus indicators
    primary: Color,
    /// Secondary actions, less emphasis
    secondary: Color,
    /// Highlights, badges, decorative accents
    accent: Color,
    /// Positive feedback, success states
    success: Color,
    /// Caution, warnings
    warning: Color,
    /// Destructive actions, errors
    danger: Color,

    // =========================================================================
    // Text Colors
    // =========================================================================

    /// Primary text - headings, body text
    text: Color,
    /// Secondary text - subtitles, less important info
    subtext: Color,
    /// Muted text - disabled states, placeholders
    muted: Color,

    // =========================================================================
    // Border Colors
    // =========================================================================

    /// Default borders - inputs, cards (derived from muted with alpha)
    border: Color,
    /// Focused input borders (typically primary)
    border_focus: Color,

    // =========================================================================
    // Semantic Sizing
    // =========================================================================

    /// Small corner radius (e.g., buttons, badges)
    radius_sm: f32 = 4,
    /// Medium corner radius (e.g., inputs, cards)
    radius_md: f32 = 8,
    /// Large corner radius (e.g., modals, panels)
    radius_lg: f32 = 16,

    // =========================================================================
    // Built-in Presets - Catppuccin
    // =========================================================================

    /// Catppuccin Latte - light theme
    pub const light = Theme{
        // Backgrounds
        .bg = Color.rgb(0.937, 0.945, 0.961), // #eff1f5
        .surface = Color.rgb(0.902, 0.914, 0.933), // #e6e9ef
        .overlay = Color.rgb(0.804, 0.827, 0.867), // #cdd6f4

        // Accents
        .primary = Color.rgb(0.118, 0.400, 0.961), // #1e66f5
        .secondary = Color.rgb(0.514, 0.580, 0.588), // #8389a8
        .accent = Color.rgb(0.533, 0.239, 0.753), // #8839c0
        .success = Color.rgb(0.251, 0.627, 0.169), // #40a02b
        .warning = Color.rgb(0.871, 0.573, 0.122), // #df8e1d
        .danger = Color.rgb(0.820, 0.239, 0.239), // #d13c3c

        // Text
        .text = Color.rgb(0.298, 0.310, 0.412), // #4c4f69
        .subtext = Color.rgb(0.424, 0.435, 0.522), // #6c6f85
        .muted = Color.rgb(0.608, 0.620, 0.694), // #9ca0b0

        // Borders (muted with alpha for default, primary for focus)
        .border = Color.rgba(0.608, 0.620, 0.694, 0.3),
        .border_focus = Color.rgb(0.118, 0.400, 0.961), // primary

        // Sizing
        .radius_sm = 4,
        .radius_md = 8,
        .radius_lg = 16,
    };

    /// Catppuccin Macchiato - dark theme
    pub const dark = Theme{
        // Backgrounds
        .bg = Color.rgb(0.141, 0.153, 0.227), // #24273a
        .surface = Color.rgb(0.212, 0.227, 0.310), // #363a4f
        .overlay = Color.rgb(0.282, 0.298, 0.384), // #494d64

        // Accents
        .primary = Color.rgb(0.541, 0.678, 0.957), // #8aadf4
        .secondary = Color.rgb(0.427, 0.475, 0.576), // #6e7993
        .accent = Color.rgb(0.769, 0.565, 0.922), // #c490eb
        .success = Color.rgb(0.651, 0.855, 0.584), // #a6da95
        .warning = Color.rgb(0.933, 0.831, 0.525), // #eed486
        .danger = Color.rgb(0.929, 0.486, 0.486), // #ed7c7c

        // Text
        .text = Color.rgb(0.792, 0.827, 0.961), // #cad3f5
        .subtext = Color.rgb(0.718, 0.757, 0.898), // #b8c0e5
        .muted = Color.rgb(0.545, 0.584, 0.729), // #8b95ba

        // Borders (muted with alpha for default, primary for focus)
        .border = Color.rgba(0.545, 0.584, 0.729, 0.3),
        .border_focus = Color.rgb(0.541, 0.678, 0.957), // primary

        // Sizing
        .radius_sm = 4,
        .radius_md = 8,
        .radius_lg = 16,
    };

    // =========================================================================
    // Helper Methods
    // =========================================================================

    /// Returns a color with adjusted alpha, useful for hover/disabled states
    pub fn withAlpha(self: *const Theme, color: Color, alpha: f32) Color {
        _ = self;
        return color.withAlpha(alpha);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = @import("std").testing;

test "Theme.light preset has valid colors" {
    const t = Theme.light;

    // All colors should have full opacity by default (except border)
    try testing.expectEqual(@as(f32, 1.0), t.bg.a);
    try testing.expectEqual(@as(f32, 1.0), t.surface.a);
    try testing.expectEqual(@as(f32, 1.0), t.primary.a);
    try testing.expectEqual(@as(f32, 1.0), t.text.a);

    // Border should have alpha for subtle appearance
    try testing.expect(t.border.a < 1.0);

    // Sizing defaults
    try testing.expectEqual(@as(f32, 4), t.radius_sm);
    try testing.expectEqual(@as(f32, 8), t.radius_md);
    try testing.expectEqual(@as(f32, 16), t.radius_lg);
}

test "Theme.dark preset has valid colors" {
    const t = Theme.dark;

    // All colors should have full opacity by default (except border)
    try testing.expectEqual(@as(f32, 1.0), t.bg.a);
    try testing.expectEqual(@as(f32, 1.0), t.surface.a);
    try testing.expectEqual(@as(f32, 1.0), t.primary.a);
    try testing.expectEqual(@as(f32, 1.0), t.text.a);

    // Border should have alpha for subtle appearance
    try testing.expect(t.border.a < 1.0);
}

test "Theme.withAlpha helper" {
    const t = Theme.light;
    const faded = t.withAlpha(t.primary, 0.5);

    try testing.expectEqual(@as(f32, 0.5), faded.a);
    // RGB should remain unchanged
    try testing.expectEqual(t.primary.r, faded.r);
    try testing.expectEqual(t.primary.g, faded.g);
    try testing.expectEqual(t.primary.b, faded.b);
}

test "Theme light and dark are different" {
    const light = Theme.light;
    const dark = Theme.dark;

    // Background should be different (light vs dark)
    try testing.expect(light.bg.r != dark.bg.r);
    try testing.expect(light.bg.g != dark.bg.g);
    try testing.expect(light.bg.b != dark.bg.b);

    // Text should be different (dark text on light vs light text on dark)
    try testing.expect(light.text.r != dark.text.r);
}
