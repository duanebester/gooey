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

    /// ID for accessibility / hover correlation (PR 11b.2b). Null ⇒ stable
    /// parent-scoped auto id (PR 11b.2a). The old default `"progress"` made
    /// every progress bar on a screen share one id; positional auto-ids keep
    /// them distinct.
    id: ?[]const u8 = null,

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

    // Accessibility overrides
    accessible_name: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    pub fn render(self: ProgressBar, cx: *ui.Cx) void {
        const t = cx.theme();

        // Resolve colors: explicit value OR theme default
        const background = self.background orelse t.muted.withAlpha(0.2);
        const fill = self.fill orelse t.primary;
        const radius = self.corner_radius orelse t.radius_sm;
        const secondary_fill = self.secondary_fill orelse t.primary.withAlpha(0.3);

        const clamped = @max(0.0, @min(1.0, self.progress));
        const fill_width = self.width * clamped;

        // Resolve identity once and use it for *both* the a11y correlation
        // and the box (PR 11b.2b). Previously the a11y call referenced
        // `LayoutId.fromString(self.id)` while the box below used `cx.box`'s
        // auto id — two different ids, so a11y bounds correlation pointed at
        // an element that didn't exist.
        const layout_id = cx.idFor(self.id);

        // Push accessible element (role: progressbar)
        const a11y_pushed = cx.accessible(.{
            .layout_id = layout_id,
            .role = .progressbar,
            .name = self.accessible_name orelse "Progress",
            .description = self.accessible_description,
            .value_min = 0.0,
            .value_max = 100.0,
            .value_now = clamped * 100.0,
        });
        defer if (a11y_pushed) cx.accessibleEnd();

        cx.boxWithLayoutId(layout_id, .{
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

    pub fn render(self: ProgressFillBar, cx: *ui.Cx) void {
        // Secondary fill (e.g., buffer progress) rendered behind primary
        if (self.secondary_width) |sw| {
            if (sw > 0) {
                cx.box(.{
                    .width = sw,
                    .height = self.height,
                    .background = self.secondary_color,
                    .corner_radius = self.radius,
                }, .{});
            }
        }

        // Primary fill
        if (self.width > 0) {
            cx.box(.{
                .width = self.width,
                .height = self.height,
                .background = self.color,
                .corner_radius = self.radius,
            }, .{});
        }
    }
};
