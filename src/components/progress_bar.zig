//! Progress Bar Component
//!
//! A visual progress indicator with customizable styling.

const ui = @import("../ui/mod.zig");
const Color = ui.Color;

pub const ProgressBar = struct {
    /// Progress value from 0.0 to 1.0
    progress: f32,

    // Sizing
    width: f32 = 200,
    height: f32 = 8,

    // Styling
    background: Color = Color.rgb(0.9, 0.9, 0.9),
    fill: Color = Color.rgb(0.2, 0.5, 1.0),
    corner_radius: f32 = 4,

    // Optional: secondary fill for buffer/background progress
    secondary_progress: ?f32 = null,
    secondary_fill: Color = Color.rgb(0.7, 0.8, 1.0),

    pub fn render(self: ProgressBar, b: *ui.Builder) void {
        const clamped = @max(0.0, @min(1.0, self.progress));
        const fill_width = self.width * clamped;

        b.box(.{
            .width = self.width,
            .height = self.height,
            .background = self.background,
            .corner_radius = self.corner_radius,
        }, .{
            ProgressFillBar{
                .width = fill_width,
                .height = self.height,
                .color = self.fill,
                .radius = self.corner_radius,
                .secondary_width = if (self.secondary_progress) |sp|
                    self.width * @max(0.0, @min(1.0, sp))
                else
                    null,
                .secondary_color = self.secondary_fill,
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
