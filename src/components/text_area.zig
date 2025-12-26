//! TextArea Component
//!
//! A styled multi-line text input field. The component handles visual chrome
//! (background, border, padding) while the underlying widget handles text editing.

const ui = @import("../ui/mod.zig");
const Color = ui.Color;

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

    // Visual styling
    background: Color = Color.white,
    border_color: Color = Color.rgb(0.8, 0.8, 0.8),
    border_color_focused: Color = Color.rgb(0.3, 0.5, 1.0),
    border_width: f32 = 1,
    corner_radius: f32 = 4,

    // Text styling
    text_color: Color = Color.black,
    placeholder_color: Color = Color.rgb(0.6, 0.6, 0.6),
    selection_color: Color = Color.rgba(0.3, 0.5, 1.0, 0.3),
    cursor_color: Color = Color.black,

    // Scrollbar styling
    scrollbar_width: f32 = 8,
    scrollbar_track_color: Color = Color.rgba(0, 0, 0, 0.05),
    scrollbar_thumb_color: Color = Color.rgba(0, 0, 0, 0.3),

    // Focus navigation
    tab_index: i32 = 0,
    tab_stop: bool = true,

    pub fn render(self: TextArea, b: *ui.Builder) void {
        b.box(.{}, .{
            ui.textArea(self.id, .{
                .placeholder = self.placeholder,
                .bind = self.bind,
                .width = self.width,
                .height = self.height,
                .rows = self.rows,
                .padding = self.padding,
                .background = self.background,
                .border_color = self.border_color,
                .border_color_focused = self.border_color_focused,
                .border_width = self.border_width,
                .corner_radius = self.corner_radius,
                .text_color = self.text_color,
                .placeholder_color = self.placeholder_color,
                .selection_color = self.selection_color,
                .cursor_color = self.cursor_color,
                .tab_index = self.tab_index,
                .tab_stop = self.tab_stop,
            }),
        });
    }
};
