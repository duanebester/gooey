//! TextArea Component
//!
//! A styled multi-line text input field. The component handles visual chrome
//! (background, border, padding) while the underlying widget handles text editing.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.

const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const Theme = ui.Theme;

pub const TextArea = struct {
    /// Unique identifier for the textarea (required for state retention)
    id: []const u8,

    // Content
    placeholder: []const u8 = "",
    bind: ?*[]const u8 = null,

    // Layout
    width: ?f32 = null,
    height: ?f32 = null, // null = auto-size based on rows
    rows: usize = 4, // Default visible rows (used when height is null)
    padding: f32 = 8,

    // Visual styling (null = use theme)
    background: ?Color = null,
    border_color: ?Color = null,
    border_color_focused: ?Color = null,
    border_width: f32 = 1,
    corner_radius: ?f32 = null,

    // Text styling (null = use theme)
    text_color: ?Color = null,
    placeholder_color: ?Color = null,
    selection_color: ?Color = null,
    cursor_color: ?Color = null,

    // Scrollbar styling (null = use theme-derived defaults)
    scrollbar_width: f32 = 8,
    scrollbar_track_color: ?Color = null,
    scrollbar_thumb_color: ?Color = null,

    // Focus navigation
    tab_index: i32 = 0,
    tab_stop: bool = true,

    pub fn render(self: TextArea, b: *ui.Builder) void {
        const t = b.theme();

        // Resolve colors: explicit value OR theme default
        const background = self.background orelse t.surface;
        const border_color = self.border_color orelse t.border;
        const border_color_focused = self.border_color_focused orelse t.border_focus;
        const corner_radius = self.corner_radius orelse t.radius_md;
        const text_color = self.text_color orelse t.text;
        const placeholder_color = self.placeholder_color orelse t.muted;
        const selection_color = self.selection_color orelse t.primary.withAlpha(0.3);
        const cursor_color = self.cursor_color orelse t.text;

        // Scrollbar colors derived from theme
        const scrollbar_track_color = self.scrollbar_track_color orelse t.muted.withAlpha(0.1);
        const scrollbar_thumb_color = self.scrollbar_thumb_color orelse t.muted.withAlpha(0.4);

        b.box(.{}, .{
            ui.textArea(self.id, .{
                .placeholder = self.placeholder,
                .bind = self.bind,
                .width = self.width,
                .height = self.height,
                .rows = self.rows,
                .padding = self.padding,
                .background = background,
                .border_color = border_color,
                .border_color_focused = border_color_focused,
                .border_width = self.border_width,
                .corner_radius = corner_radius,
                .text_color = text_color,
                .placeholder_color = placeholder_color,
                .selection_color = selection_color,
                .cursor_color = cursor_color,
                .scrollbar_width = self.scrollbar_width,
                .scrollbar_track_color = scrollbar_track_color,
                .scrollbar_thumb_color = scrollbar_thumb_color,
                .tab_index = self.tab_index,
                .tab_stop = self.tab_stop,
            }),
        });
    }
};
