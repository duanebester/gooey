//! TextInput Component
//!
//! A styled text input field. The component handles visual chrome (background,
//! border, padding) while the underlying widget handles text editing.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.

const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const Theme = ui.Theme;
const HandlerRef = ui.HandlerRef;
const layout_mod = @import("../layout/layout.zig");
const LayoutId = layout_mod.LayoutId;

pub const TextInput = struct {
    /// Unique identifier for the input (required for state retention)
    id: []const u8,

    // Content
    placeholder: []const u8 = "",
    secure: bool = false,
    bind: ?*[]const u8 = null,

    // Layout
    width: ?f32 = null,
    height: ?f32 = null, // null = auto-size based on font metrics + padding
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

    // Focus navigation
    tab_index: i32 = 0,
    tab_stop: bool = true,

    // Handlers
    on_blur_handler: ?HandlerRef = null,

    // Accessibility overrides
    accessible_name: ?[]const u8 = null, // Label for screen readers
    accessible_description: ?[]const u8 = null,

    pub fn render(self: TextInput, b: *ui.Builder) void {
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

        const layout_id = LayoutId.fromString(self.id);

        // Push accessible element (role: textbox)
        // Phase 3.1: Expose value to screen readers (masked for secure inputs)
        const a11y_value: ?[]const u8 = if (self.secure)
            null // Don't expose secure input values
        else if (self.bind) |binding|
            if (binding.len > 0) binding.* else null
        else
            null;

        const a11y_pushed = b.accessible(.{
            .layout_id = layout_id,
            .role = .textbox,
            .name = self.accessible_name orelse self.placeholder,
            .description = self.accessible_description,
            .value = a11y_value,
        });
        defer if (a11y_pushed) b.accessibleEnd();

        b.box(.{}, .{
            ui.input(self.id, .{
                .placeholder = self.placeholder,
                .secure = self.secure,
                .bind = self.bind,
                .width = self.width,
                .height = self.height,
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
                .tab_index = self.tab_index,
                .tab_stop = self.tab_stop,
                .on_blur_handler = self.on_blur_handler,
            }),
        });
    }
};
