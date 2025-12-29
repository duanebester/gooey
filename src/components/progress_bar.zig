//! Progress Bar Component
//!
//! A visual progress indicator with customizable styling.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.

const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const Theme = ui.Theme;

pub const ProgressBar = struct {
    /// Progress value from 0.0 to 1.0
    progress: f32,

    // Sizing
    width: f32 = 200,
    height: f32 = 8,

    // Styling (null = use theme)
    background: ?Color = null,
    fill: ?Color = null,
    corner_radius: ?f32 = null,

    // Optional: secondary fill for buffer/background progress
    secondary_progress: ?f32 = null,
    secondary_fill: ?Color = null,

    pub fn render(self: ProgressBar, b: *ui.Builder) void {
        const t = b.theme();

        // Resolve colors: explicit value OR theme default
        const background = self.background orelse t.muted.withAlpha(0.2);
        const fill = self.fill orelse t.primary;
        const radius = self.corner_radius orelse t.radius_sm;
        const secondary_fill = self.secondary_fill orelse t.primary.withAlpha(0.3);

        const clamped = @max(0.0, @min(1.0, self.progress));
        const fill_width = self.width * clamped;

        b.box(.{
            .width = self.width,
            .height = self.height,
            .background = background,
            .corner_radius = radius,
        }, .{
            ProgressFillBar{
                .width = fill_width,
                .height = self.height,
                .color = fill,
                .radius = radius,
                .secondary_width = if (self.secondary_progress) |sp|
                    self.width * @max(0.0, @min(1.0, sp))
                else
                    null,
                .secondary_color = secondary_fill,
            },
        });
    }
};

const ProgressFillBar = struct {
    width: f32,
    height: f32,
    color: Color,
    radius: f32,
    secondary_width: ?f32,
    secondary_color: Color,

    pub fn render(self: ProgressFillBar, b: *ui.Builder) void {
        // Secondary fill (e.g., buffer progress) rendered behind primary
        if (self.secondary_width) |sw| {
            if (sw > 0) {
                b.box(.{
                    .width = sw,
                    .height = self.height,
                    .background = self.secondary_color,
                    .corner_radius = self.radius,
                }, .{});
            }
        }

        // Primary fill
        if (self.width > 0) {
            b.box(.{
                .width = self.width,
                .height = self.height,
                .background = self.color,
                .corner_radius = self.radius,
            }, .{});
        }
    }
};
