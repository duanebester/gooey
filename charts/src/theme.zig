const std = @import("std");
const gooey = @import("gooey");
const Color = gooey.Color;
const Theme = gooey.Theme;

pub const MAX_PALETTE_COLORS = 12;

pub const ChartTheme = struct {
    background: Color,

    foreground: Color,

    muted: Color,

    surface: Color,

    border: Color,

    palette: [MAX_PALETTE_COLORS]Color = default_palette,

    positive: Color,

    negative: Color,

    neutral: Color,

    axis_color: Color,

    grid_color: Color,

    tick_color: Color,

    label_color: Color,

    pub const light = ChartTheme{
        .background = Color.rgb(0.937, 0.945, 0.961),
        .foreground = Color.rgb(0.298, 0.310, 0.412),
        .muted = Color.rgba(0.608, 0.620, 0.694, 0.5),
        .surface = Color.rgb(0.902, 0.914, 0.933),
        .border = Color.rgba(0.608, 0.620, 0.694, 0.3),

        .palette = google_light_palette,

        .positive = Color.rgb(0.251, 0.627, 0.169),
        .negative = Color.rgb(0.820, 0.239, 0.239),
        .neutral = Color.rgb(0.608, 0.620, 0.694),

        .axis_color = Color.rgb(0.424, 0.435, 0.522),
        .grid_color = Color.rgba(0.608, 0.620, 0.694, 0.25),
        .tick_color = Color.rgb(0.424, 0.435, 0.522),
        .label_color = Color.rgb(0.298, 0.310, 0.412),
    };

    pub const dark = ChartTheme{
        .background = Color.rgb(0.141, 0.153, 0.227),
        .foreground = Color.rgb(0.792, 0.827, 0.961),
        .muted = Color.rgba(0.545, 0.584, 0.729, 0.5),
        .surface = Color.rgb(0.212, 0.227, 0.310),
        .border = Color.rgba(0.545, 0.584, 0.729, 0.3),

        .palette = google_dark_palette,

        .positive = Color.rgb(0.651, 0.855, 0.584),
        .negative = Color.rgb(0.929, 0.486, 0.486),
        .neutral = Color.rgb(0.545, 0.584, 0.729),

        .axis_color = Color.rgb(0.718, 0.757, 0.898),
        .grid_color = Color.rgba(0.545, 0.584, 0.729, 0.2),
        .tick_color = Color.rgb(0.718, 0.757, 0.898),
        .label_color = Color.rgb(0.792, 0.827, 0.961),
    };

    pub fn fromTheme(theme: *const Theme) ChartTheme {
        std.debug.assert(theme.bg.a > 0);

        return ChartTheme{
            .background = theme.bg,
            .foreground = theme.text,
            .muted = theme.muted.withAlpha(0.5),
            .surface = theme.surface,
            .border = theme.border,

            .positive = theme.success,
            .negative = theme.danger,
            .neutral = theme.muted,

            .axis_color = theme.subtext,
            .grid_color = theme.muted.withAlpha(0.25),
            .tick_color = theme.subtext,
            .label_color = theme.text,
        };
    }

    pub fn paletteColor(self: *const ChartTheme, index: usize) Color {
        return self.palette[index % MAX_PALETTE_COLORS];
    }

    pub fn withAlpha(self: *const ChartTheme, color: Color, alpha: f32) Color {
        _ = self;
        std.debug.assert(alpha >= 0.0 and alpha <= 1.0);
        return color.withAlpha(alpha);
    }

    pub fn isDark(self: *const ChartTheme) bool {
        const luminance = 0.299 * self.background.r +
            0.587 * self.background.g +
            0.114 * self.background.b;
        return luminance < 0.5;
    }

    pub fn contrastingText(self: *const ChartTheme, bg: Color) Color {
        const luminance = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b;
        if (luminance > 0.5) {
            return if (self.isDark()) self.foreground else Color.rgb(0.1, 0.1, 0.1);
        } else {
            return if (self.isDark()) Color.rgb(0.95, 0.95, 0.95) else self.background;
        }
    }
};

pub const google_light_palette = [MAX_PALETTE_COLORS]Color{
    Color.hex(0x1a73e8),
    Color.hex(0xd93025),
    Color.hex(0xf9ab00),
    Color.hex(0x1e8e3e),
    Color.hex(0xe65100),
    Color.hex(0x00838f),
    Color.hex(0x6a1b9a),
    Color.hex(0xad1457),
    Color.hex(0x00695c),
    Color.hex(0x4e342e),
    Color.hex(0x37474f),
    Color.hex(0xbf360c),
};

pub const google_dark_palette = [MAX_PALETTE_COLORS]Color{
    Color.hex(0x8ab4f8),
    Color.hex(0xf28b82),
    Color.hex(0xfdd663),
    Color.hex(0x81c995),
    Color.hex(0xfcad70),
    Color.hex(0x78d9ec),
    Color.hex(0xc58af9),
    Color.hex(0xf48fb1),
    Color.hex(0x4db6ac),
    Color.hex(0xa1887f),
    Color.hex(0x90a4ae),
    Color.hex(0xffab91),
};

pub const google_palette = [MAX_PALETTE_COLORS]Color{
    Color.hex(0x4285f4),
    Color.hex(0xea4335),
    Color.hex(0xfbbc05),
    Color.hex(0x34a853),
    Color.hex(0xff6d01),
    Color.hex(0x46bdc6),
    Color.hex(0x7b1fa2),
    Color.hex(0xc2185b),
    Color.hex(0x00796b),
    Color.hex(0x5d4037),
    Color.hex(0x455a64),
    Color.hex(0xe65100),
};

pub const default_palette = google_light_palette;

pub const colorblind_palette = [MAX_PALETTE_COLORS]Color{
    Color.hex(0x0077BB),
    Color.hex(0xEE7733),
    Color.hex(0x009988),
    Color.hex(0xCC3311),
    Color.hex(0x33BBEE),
    Color.hex(0xEE3377),
    Color.hex(0xBBBBBB),
    Color.hex(0x000000),
    Color.hex(0x44AA99),
    Color.hex(0x882255),
    Color.hex(0x999933),
    Color.hex(0xDDCC77),
};

pub const monochrome_blue_palette = [MAX_PALETTE_COLORS]Color{
    Color.hex(0x08306b),
    Color.hex(0x08519c),
    Color.hex(0x2171b5),
    Color.hex(0x4292c6),
    Color.hex(0x6baed6),
    Color.hex(0x9ecae1),
    Color.hex(0xc6dbef),
    Color.hex(0xdeebf7),
    Color.hex(0x3182bd),
    Color.hex(0x9ecae1),
    Color.hex(0x6baed6),
    Color.hex(0x4292c6),
};

const testing = std.testing;

test "ChartTheme.light has valid colors" {
    const t = ChartTheme.light;

    try testing.expect(t.background.r > 0.5);
    try testing.expect(!t.isDark());

    for (t.palette) |color| {
        try testing.expectEqual(@as(f32, 1.0), color.a);
    }
}

test "ChartTheme.dark has valid colors" {
    const t = ChartTheme.dark;

    try testing.expect(t.background.r < 0.5);
    try testing.expect(t.isDark());
}

test "ChartTheme.fromTheme maps colors correctly" {
    const t = ChartTheme.fromTheme(&Theme.dark);

    try testing.expectEqual(Theme.dark.bg.r, t.background.r);
    try testing.expectEqual(Theme.dark.bg.g, t.background.g);
    try testing.expectEqual(Theme.dark.bg.b, t.background.b);

    try testing.expectEqual(Theme.dark.success.r, t.positive.r);
    try testing.expectEqual(Theme.dark.danger.r, t.negative.r);
}

test "ChartTheme.paletteColor wraps around" {
    const t = ChartTheme.light;

    try testing.expectEqual(t.palette[0].r, t.paletteColor(0).r);
    try testing.expectEqual(t.palette[5].r, t.paletteColor(5).r);

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

    const dark_bg = Color.rgb(0.1, 0.1, 0.1);
    const light_text = t.contrastingText(dark_bg);
    const light_lum = 0.299 * light_text.r + 0.587 * light_text.g + 0.114 * light_text.b;
    try testing.expect(light_lum > 0.5);

    const light_bg = Color.rgb(0.9, 0.9, 0.9);
    const dark_text = t.contrastingText(light_bg);
    const dark_lum = 0.299 * dark_text.r + 0.587 * dark_text.g + 0.114 * dark_text.b;
    try testing.expect(dark_lum < 0.5);
}

test "default_palette has 12 distinct colors" {
    try testing.expectEqual(@as(usize, 12), default_palette.len);

    try testing.expect(default_palette[0].r != default_palette[11].r or
        default_palette[0].g != default_palette[11].g or
        default_palette[0].b != default_palette[11].b);
}

test "ChartTheme struct size is reasonable" {
    try testing.expect(@sizeOf(ChartTheme) < 512);
}
