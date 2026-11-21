const std = @import("std");
const assert = std.debug.assert;

const Color = @import("../geometry/geometry.zig").Color;

// Components resolve null color fields against the current theme.
pub const Theme = struct {
    /// Page/app background - the base layer
    bg: Color,
    /// Card/panel backgrounds - slightly elevated surfaces
    surface: Color,
    /// Dropdowns, tooltips, modals - highest elevation surfaces
    overlay: Color,

    /// Primary actions, links, focus indicators
    primary: Color,
    /// Fill of secondary actions (secondary buttons), drawn under `text`. At
    /// least 4.5:1 against `text` in every built-in theme.
    secondary: Color,
    /// Highlights, badges, decorative accents
    accent: Color,
    /// Positive feedback, success states
    success: Color,
    /// Caution, warnings
    warning: Color,
    /// Destructive actions, errors
    danger: Color,
    /// Text and marks drawn on a `primary` fill: primary button labels and
    /// the checkbox's check. At least 4.5:1 against `primary` in every
    /// built-in theme.
    on_primary: Color,
    /// Text drawn on a `danger` fill: danger button labels. At least 4.5:1
    /// against `danger` in every built-in theme.
    on_danger: Color,

    /// Primary text - headings, body text
    text: Color,
    /// Secondary text - subtitles, less important info
    subtext: Color,
    /// Muted text - disabled states, placeholders
    muted: Color,

    /// Default borders - inputs, cards (derived from muted with alpha)
    border: Color,
    /// Focused input borders (typically primary)
    border_focus: Color,

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

    /// Catppuccin Latte - light theme
    pub const light = Theme{
        .bg = Color.rgb(0.937, 0.945, 0.961), // #eff1f5
        .surface = Color.rgb(0.902, 0.914, 0.933), // #e6e9ef
        .overlay = Color.rgb(0.804, 0.827, 0.867), // #cdd6f4

        .primary = Color.rgb(0.118, 0.400, 0.961), // #1e66f5
        .secondary = Color.rgb(0.800, 0.816, 0.855), // #ccd0da, 5.2:1 under text
        .accent = Color.rgb(0.533, 0.239, 0.753), // #8839c0
        .success = Color.rgb(0.251, 0.627, 0.169), // #40a02b
        .warning = Color.rgb(0.871, 0.573, 0.122), // #df8e1d
        .danger = Color.rgb(0.820, 0.239, 0.239), // #d13c3c
        .on_primary = Color.white, // 4.9:1 on primary
        .on_danger = Color.white, // 4.7:1 on danger

        .text = Color.rgb(0.298, 0.310, 0.412), // #4c4f69
        .subtext = Color.rgb(0.424, 0.435, 0.522), // #6c6f85
        .muted = Color.rgb(0.608, 0.620, 0.694), // #9ca0b0

        .border = Color.rgba(0.608, 0.620, 0.694, 0.3),
        .border_focus = Color.rgb(0.118, 0.400, 0.961), // primary

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

        .primary = Color.rgb(0.541, 0.678, 0.957), // #8aadf4
        .secondary = Color.rgb(0.286, 0.302, 0.392), // #494d64, 5.6:1 under text
        .accent = Color.rgb(0.769, 0.565, 0.922), // #c490eb
        .success = Color.rgb(0.651, 0.855, 0.584), // #a6da95
        .warning = Color.rgb(0.933, 0.831, 0.525), // #eed486
        .danger = Color.rgb(0.929, 0.486, 0.486), // #ed7c7c
        // Base, not white: white on these pastels is 2.2:1 and 2.7:1.
        .on_primary = Color.rgb(0.141, 0.153, 0.227), // #24273a, 6.6:1
        .on_danger = Color.rgb(0.141, 0.153, 0.227), // #24273a, 5.5:1

        .text = Color.rgb(0.792, 0.827, 0.961), // #cad3f5
        .subtext = Color.rgb(0.718, 0.757, 0.898), // #b8c0e5
        .muted = Color.rgb(0.545, 0.584, 0.729), // #8b95ba

        .border = Color.rgba(0.545, 0.584, 0.729, 0.3),
        .border_focus = Color.rgb(0.541, 0.678, 0.957), // primary

        .radius_sm = 4,
        .radius_md = 8,
        .radius_lg = 16,
        .font_size_base = 16,
    };

    // From the published palette (catppuccin/palette, `palette.json`) with
    // mauve as the primary accent; `dark` instead derives from Macchiato with
    // a blue primary and translucent borders.
    pub const catppuccin_macchiato = catppuccin(&macchiato_palette);

    // Catppuccin Latte, mapped as `catppuccin_macchiato` is.
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
        // Button labels are body-size text (14 to 18 px), so every built-in
        // theme meets WCAG's 4.5:1 for normal text, not the 3:1 large-text
        // floor.
        @setEvalBranchQuota(10_000);
        for (built_in) |theme| {
            assert(contrastRatio(theme.on_primary, theme.primary) >= contrast_text_min);
            assert(contrastRatio(theme.on_danger, theme.danger) >= contrast_text_min);
            assert(contrastRatio(theme.text, theme.secondary) >= contrast_text_min);
        }
    }

    /// Every preset Gooey ships, for the comptime checks.
    const built_in = [_]*const Theme{
        &light,
        &dark,
        &catppuccin_latte,
        &catppuccin_macchiato,
    };

    /// WCAG 2's minimum contrast ratio for normal-size text (success
    /// criterion 1.4.3).
    pub const contrast_text_min: f32 = 4.5;

    /// WCAG 2 contrast ratio of two opaque colours, from 1 (identical
    /// luminance) to 21 (black on white). Order does not matter.
    pub fn contrastRatio(foreground: Color, background: Color) f32 {
        assert(foreground.a == 1);
        assert(background.a == 1);
        const a = relativeLuminance(foreground);
        const b = relativeLuminance(background);
        const ratio = (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
        assert(ratio >= 1);
        assert(ratio <= 21.0001);
        return ratio;
    }

    /// WCAG 2 relative luminance: each sRGB component linearized, then the
    /// Rec. 709 weights.
    fn relativeLuminance(color: Color) f32 {
        const value = 0.2126 * linearize(color.r) + 0.7152 * linearize(color.g) +
            0.0722 * linearize(color.b);
        assert(value >= 0);
        assert(value <= 1.0001);
        return value;
    }

    fn linearize(component: f32) f32 {
        assert(component >= 0);
        assert(component <= 1);
        if (component <= 0.04045) return component / 12.92;
        return std.math.pow(f32, (component + 0.055) / 1.055, 2.4);
    }

    // The Catppuccin colours the built-in themes take, as 0xRRGGBB, named as
    // in `palette.json`.
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

    // One role mapping for every flavour: base is the window; mantle fills
    // raised panes; surface1 marks hovered rows; surface2 outlines inputs and
    // cards; overlay0 is the faintest readable text. Secondary buttons fill
    // with surface1 on dark flavours and surface0 on light ones: Latte's text
    // on surface1 is 4.4:1, under the 4.5:1 the comptime check requires.
    // Accents: mauve primary, blue as the second accent, lavender for focus,
    // and green, yellow, and red for success, warning, and danger.
    fn catppuccin(palette: *const CatppuccinPalette) Theme {
        assert(palette.base != palette.text);
        assert(palette.mantle != palette.base);
        const is_dark = luma(Color.hex(palette.base)) < luma(Color.hex(palette.text));
        const secondary = if (is_dark) palette.surface1 else palette.surface0;
        return .{
            .bg = Color.hex(palette.base),
            .surface = Color.hex(palette.mantle),
            .overlay = Color.hex(palette.surface1),
            .primary = Color.hex(palette.mauve),
            .secondary = Color.hex(secondary),
            .accent = Color.hex(palette.blue),
            .success = Color.hex(palette.green),
            .warning = Color.hex(palette.yellow),
            .danger = Color.hex(palette.red),
            // Catppuccin puts base-coloured text on its accents.
            .on_primary = Color.hex(palette.base),
            .on_danger = Color.hex(palette.base),
            .text = Color.hex(palette.text),
            .subtext = Color.hex(palette.subtext1),
            .muted = Color.hex(palette.overlay0),
            .border = Color.hex(palette.surface2),
            .border_focus = Color.hex(palette.lavender),
        };
    }

    pub fn withAlpha(self: *const Theme, color: Color, alpha: f32) Color {
        _ = self;
        return color.withAlpha(alpha);
    }

    // Whether the host's own chrome (the macOS title bar) should be dark. A
    // theme is dark when its background is darker than its text: the relation
    // every legible theme states, with no threshold to tune, so a dim grey
    // theme with white text counts as dark. Ties count as light.
    pub fn isDark(self: *const Theme) bool {
        return luma(self.bg) < luma(self.text);
    }

    // Rec. 709 luma of the stored (gamma-encoded) components, enough to order
    // two colours by lightness. Components outside 0 to 1 are a malformed
    // theme, which the bounds catch.
    fn luma(color: Color) f32 {
        const value = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
        assert(value >= 0);
        assert(value <= 1.0001); // The weights sum to 1 within f32 rounding.
        return value;
    }
};

const testing = @import("std").testing;

test "contrastRatio matches WCAG's published endpoints and a known pair" {
    const ratio = Theme.contrastRatio;
    try testing.expectApproxEqAbs(@as(f32, 21), ratio(Color.black, Color.white), 0.01);
    const primary = Theme.light.primary;
    try testing.expectApproxEqAbs(@as(f32, 1), ratio(primary, primary), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 4.91), ratio(Color.white, Color.hex(0x1e66f5)), 0.01);
}

test "Theme.light preset has valid colors" {
    const t = Theme.light;

    try testing.expectEqual(@as(f32, 1.0), t.bg.a);
    try testing.expectEqual(@as(f32, 1.0), t.surface.a);
    try testing.expectEqual(@as(f32, 1.0), t.primary.a);
    try testing.expectEqual(@as(f32, 1.0), t.text.a);
    try testing.expect(t.border.a < 1.0);
    try testing.expectEqual(@as(f32, 4), t.radius_sm);
    try testing.expectEqual(@as(f32, 8), t.radius_md);
    try testing.expectEqual(@as(f32, 16), t.radius_lg);
    try testing.expectEqual(@as(u16, 16), t.font_size_base);
}

test "Theme.dark preset has valid colors" {
    const t = Theme.dark;

    try testing.expectEqual(@as(f32, 1.0), t.bg.a);
    try testing.expectEqual(@as(f32, 1.0), t.surface.a);
    try testing.expectEqual(@as(f32, 1.0), t.primary.a);
    try testing.expectEqual(@as(f32, 1.0), t.text.a);
    try testing.expect(t.border.a < 1.0);
}

test "Theme.withAlpha helper" {
    const t = Theme.light;
    const faded = t.withAlpha(t.primary, 0.5);

    try testing.expectEqual(@as(f32, 0.5), faded.a);
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

    try testing.expect(light.bg.r != dark.bg.r);
    try testing.expect(light.bg.g != dark.bg.g);
    try testing.expect(light.bg.b != dark.bg.b);
    try testing.expect(light.text.r != dark.text.r);
}
