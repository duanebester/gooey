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

const assert = @import("std").debug.assert;

const Color = @import("../geometry/geometry.zig").Color;

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
    /// Base font size in points. Components scale relative to this value.
    /// e.g. Button.SizePreset.small = base - 2, .medium = base, .large = base + 2
    /// Aligned with FontConfig.font_size (16pt) so UI text matches rasterization size.
    font_size_base: u16 = 16,

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
        .font_size_base = 16,
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
        .font_size_base = 16,
    };

    /// Catppuccin Macchiato, from the published palette (catppuccin/palette,
    /// `palette.json`) with mauve as the primary accent. `dark` is a
    /// Macchiato-derived theme with a blue primary and translucent borders;
    /// this one uses palette colours only, and every token is opaque.
    pub const catppuccin_macchiato = catppuccin(&macchiato_palette);

    /// Catppuccin Latte, mapped as `catppuccin_macchiato` is.
    pub const catppuccin_latte = catppuccin(&latte_palette);

    comptime {
        assert(catppuccin_macchiato.isDark());
        assert(!catppuccin_latte.isDark());
        for ([_]*const Theme{ &catppuccin_macchiato, &catppuccin_latte }) |theme| {
            // `Select` paints its menu (`surface`) and hovered rows
            // (`overlay`) over other controls, so neither may show through.
            assert(theme.surface.a == 1);
            assert(theme.overlay.a == 1);
        }
    }

    /// The Catppuccin colours the built-in themes take, as 0xRRGGBB, named
    /// as in `palette.json`. The same palettes as chat-zig's `theme.zig`,
    /// plus yellow for `warning`.
    const CatppuccinPalette = struct {
        base: u32,
        mantle: u32,
        crust: u32,
        surface0: u32,
        surface1: u32,
        surface2: u32,
        overlay0: u32,
        overlay1: u32,
        overlay2: u32,
        subtext0: u32,
        subtext1: u32,
        text: u32,
        mauve: u32,
        lavender: u32,
        blue: u32,
        red: u32,
        green: u32,
        yellow: u32,
    };

    const latte_palette = CatppuccinPalette{
        .base = 0xeff1f5,
        .mantle = 0xe6e9ef,
        .crust = 0xdce0e8,
        .surface0 = 0xccd0da,
        .surface1 = 0xbcc0cc,
        .surface2 = 0xacb0be,
        .overlay0 = 0x9ca0b0,
        .overlay1 = 0x8c8fa1,
        .overlay2 = 0x7c7f93,
        .subtext0 = 0x6c6f85,
        .subtext1 = 0x5c5f77,
        .text = 0x4c4f69,
        .mauve = 0x8839ef,
        .lavender = 0x7287fd,
        .blue = 0x1e66f5,
        .red = 0xd20f39,
        .green = 0x40a02b,
        .yellow = 0xdf8e1d,
    };

    const macchiato_palette = CatppuccinPalette{
        .base = 0x24273a,
        .mantle = 0x1e2030,
        .crust = 0x181926,
        .surface0 = 0x363a4f,
        .surface1 = 0x494d64,
        .surface2 = 0x5b6078,
        .overlay0 = 0x6e738d,
        .overlay1 = 0x8087a2,
        .overlay2 = 0x939ab7,
        .subtext0 = 0xa5adcb,
        .subtext1 = 0xb8c0e0,
        .text = 0xcad3f5,
        .mauve = 0xc6a0f6,
        .lavender = 0xb7bdf8,
        .blue = 0x8aadf4,
        .red = 0xed8796,
        .green = 0xa6da95,
        .yellow = 0xeed49f,
    };

    /// One role mapping for every flavour, following chat-zig's
    /// `gooeyTheme`: base is the window; mantle fills raised panes; surface1
    /// marks hovered rows; surface2 outlines inputs and cards; overlay1 is
    /// the secondary (icon) colour; overlay0 is the faintest readable text.
    /// Accents: mauve primary, blue as the second accent, lavender for
    /// focus, and green, yellow, and red for success, warning, and danger.
    fn catppuccin(palette: *const CatppuccinPalette) Theme {
        assert(palette.base != palette.text);
        assert(palette.mantle != palette.base);
        return .{
            .bg = Color.hex(palette.base),
            .surface = Color.hex(palette.mantle),
            .overlay = Color.hex(palette.surface1),
            .primary = Color.hex(palette.mauve),
            .secondary = Color.hex(palette.overlay1),
            .accent = Color.hex(palette.blue),
            .success = Color.hex(palette.green),
            .warning = Color.hex(palette.yellow),
            .danger = Color.hex(palette.red),
            .text = Color.hex(palette.text),
            .subtext = Color.hex(palette.subtext1),
            .muted = Color.hex(palette.overlay0),
            .border = Color.hex(palette.surface2),
            .border_focus = Color.hex(palette.lavender),
        };
    }

    // =========================================================================
    // Helper Methods
    // =========================================================================

    /// Returns a color with adjusted alpha, useful for hover/disabled states
    pub fn withAlpha(self: *const Theme, color: Color, alpha: f32) Color {
        _ = self;
        return color.withAlpha(alpha);
    }

    /// Whether the host's own chrome (the macOS title bar) should be dark.
    /// A theme is dark when its background is darker than its text: the
    /// relation every legible theme states, with no threshold to tune, so a
    /// dim grey theme with white text counts as dark. Ties count as light.
    pub fn isDark(self: *const Theme) bool {
        return luma(self.bg) < luma(self.text);
    }

    /// Rec. 709 luma of the stored (gamma-encoded) components, enough to
    /// order two colours by lightness. Components outside 0 to 1 are a
    /// malformed theme, which the bounds catch.
    fn luma(color: Color) f32 {
        const value = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
        assert(value >= 0);
        assert(value <= 1.0001); // The weights sum to 1 within f32 rounding.
        return value;
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
    try testing.expectEqual(@as(u16, 16), t.font_size_base);
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

test "Theme.isDark compares background with text, not a fixed threshold" {
    // The presets pin both answers; the dim theme's mid-grey background
    // (luma 0.55) would read as light under a 0.5 threshold, but its white
    // text makes it dark. Its inverse, grey text on white, stays light.
    try testing.expect(!Theme.light.isDark());
    try testing.expect(Theme.dark.isDark());
    var dim = Theme.light;
    dim.bg = Color.rgb(0.55, 0.55, 0.55);
    dim.text = Color.rgb(1, 1, 1);
    try testing.expect(dim.isDark());
    dim.bg = Color.rgb(1, 1, 1);
    dim.text = Color.rgb(0.55, 0.55, 0.55);
    try testing.expect(!dim.isDark());
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
