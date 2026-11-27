const std = @import("std");
const assert = std.debug.assert;

const Color = @import("../geometry/geometry.zig").Color;

pub const Theme = struct {
    bg: Color,
    surface: Color,
    overlay: Color,

    primary: Color,
    secondary: Color,
    accent: Color,
    success: Color,
    warning: Color,
    danger: Color,
    on_primary: Color,
    on_danger: Color,

    text: Color,
    subtext: Color,
    muted: Color,

    border: Color,
    border_focus: Color,
    /// Link text in `ui.rich` spans, separate from `primary` so a theme whose accent is not
    /// blue can keep links recognisable.
    link: Color,

    radius_sm: f32 = 4,
    radius_md: f32 = 8,
    radius_lg: f32 = 16,
    font_size_base: u16 = 16,

    pub const light = Theme{
        .bg = Color.rgb(0.937, 0.945, 0.961),
        .surface = Color.rgb(0.902, 0.914, 0.933),
        .overlay = Color.rgb(0.804, 0.827, 0.867),

        .primary = Color.rgb(0.118, 0.400, 0.961),
        .secondary = Color.rgb(0.800, 0.816, 0.855),
        .accent = Color.rgb(0.533, 0.239, 0.753),
        .success = Color.rgb(0.251, 0.627, 0.169),
        .warning = Color.rgb(0.871, 0.573, 0.122),
        .danger = Color.rgb(0.820, 0.239, 0.239),
        .on_primary = Color.white,
        .on_danger = Color.white,

        .text = Color.rgb(0.298, 0.310, 0.412),
        .subtext = Color.rgb(0.424, 0.435, 0.522),
        .muted = Color.rgb(0.608, 0.620, 0.694),

        .border = Color.rgba(0.608, 0.620, 0.694, 0.3),
        .border_focus = Color.rgb(0.118, 0.400, 0.961),
        .link = Color.rgb(0.118, 0.400, 0.961),

        .radius_sm = 4,
        .radius_md = 8,
        .radius_lg = 16,
        .font_size_base = 16,
    };

    pub const dark = Theme{
        .bg = Color.rgb(0.141, 0.153, 0.227),
        .surface = Color.rgb(0.212, 0.227, 0.310),
        .overlay = Color.rgb(0.282, 0.298, 0.384),

        .primary = Color.rgb(0.541, 0.678, 0.957),
        .secondary = Color.rgb(0.286, 0.302, 0.392),
        .accent = Color.rgb(0.769, 0.565, 0.922),
        .success = Color.rgb(0.651, 0.855, 0.584),
        .warning = Color.rgb(0.933, 0.831, 0.525),
        .danger = Color.rgb(0.929, 0.486, 0.486),
        .on_primary = Color.rgb(0.141, 0.153, 0.227),
        .on_danger = Color.rgb(0.141, 0.153, 0.227),

        .text = Color.rgb(0.792, 0.827, 0.961),
        .subtext = Color.rgb(0.718, 0.757, 0.898),
        .muted = Color.rgb(0.545, 0.584, 0.729),

        .border = Color.rgba(0.545, 0.584, 0.729, 0.3),
        .border_focus = Color.rgb(0.541, 0.678, 0.957),
        .link = Color.rgb(0.541, 0.678, 0.957),

        .radius_sm = 4,
        .radius_md = 8,
        .radius_lg = 16,
        .font_size_base = 16,
    };

    pub const catppuccin_macchiato = catppuccin(&macchiato_palette);

    pub const catppuccin_latte = catppuccin(&latte_palette);

    comptime {
        assert(catppuccin_macchiato.isDark());
        assert(!catppuccin_latte.isDark());
        for ([_]*const Theme{ &catppuccin_macchiato, &catppuccin_latte }) |theme| {
            assert(theme.surface.a == 1);
            assert(theme.overlay.a == 1);
        }
        @setEvalBranchQuota(10_000);
        for (built_in) |theme| {
            assert(contrastRatio(theme.on_primary, theme.primary) >= contrast_text_min);
            assert(contrastRatio(theme.on_danger, theme.danger) >= contrast_text_min);
            assert(contrastRatio(theme.text, theme.secondary) >= contrast_text_min);
        }
    }

    const built_in = [_]*const Theme{
        &light,
        &dark,
        &catppuccin_latte,
        &catppuccin_macchiato,
    };

    pub const contrast_text_min: f32 = 4.5;

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
            .on_primary = Color.hex(palette.base),
            .on_danger = Color.hex(palette.base),
            .text = Color.hex(palette.text),
            .subtext = Color.hex(palette.subtext1),
            .muted = Color.hex(palette.overlay0),
            .border = Color.hex(palette.surface2),
            .border_focus = Color.hex(palette.lavender),
            .link = Color.hex(palette.blue),
        };
    }

    pub fn withAlpha(self: *const Theme, color: Color, alpha: f32) Color {
        _ = self;
        return color.withAlpha(alpha);
    }

    pub fn isDark(self: *const Theme) bool {
        return luma(self.bg) < luma(self.text);
    }

    fn luma(color: Color) f32 {
        const value = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
        assert(value >= 0);
        assert(value <= 1.0001);
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
