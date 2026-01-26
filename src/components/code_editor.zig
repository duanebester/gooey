//! CodeEditor Component
//!
//! A styled code editor with line numbers and syntax highlighting support.
//! The component handles visual chrome (background, border, gutter) while
//! the underlying widget handles text editing and rendering.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.
//!
//! ## Example
//!
//! ```zig
//! const gooey = @import("gooey");
//!
//! gooey.CodeEditor{
//!     .id = "source",
//!     .placeholder = "Enter code here...",
//!     .bind = &state.source_code,
//!     .show_line_numbers = true,
//!     .tab_size = 4,
//! }
//! ```

const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const Theme = ui.Theme;
const HandlerRef = ui.HandlerRef;
const layout_mod = @import("../layout/layout.zig");
const LayoutId = layout_mod.LayoutId;

pub const CodeEditor = struct {
    /// Unique identifier for the code editor (required for state retention)
    id: []const u8,

    // =========================================================================
    // Content
    // =========================================================================

    placeholder: []const u8 = "",
    bind: ?*[]const u8 = null,

    // =========================================================================
    // Layout
    // =========================================================================

    width: ?f32 = null,
    height: ?f32 = null, // null = auto-size based on rows
    rows: usize = 10, // Default visible rows (used when height is null)
    padding: f32 = 8,

    // =========================================================================
    // Visual styling (null = use theme)
    // =========================================================================

    background: ?Color = null,
    border_color: ?Color = null,
    border_color_focused: ?Color = null,
    border_width: f32 = 1,
    corner_radius: ?f32 = null,

    // =========================================================================
    // Text styling (null = use theme)
    // =========================================================================

    text_color: ?Color = null,
    placeholder_color: ?Color = null,
    selection_color: ?Color = null,
    cursor_color: ?Color = null,

    // =========================================================================
    // Scrollbar styling (null = use theme-derived defaults)
    // =========================================================================

    scrollbar_width: f32 = 8,
    scrollbar_track_color: ?Color = null,
    scrollbar_thumb_color: ?Color = null,

    // =========================================================================
    // Code editor specific
    // =========================================================================

    /// Show line numbers in the gutter
    show_line_numbers: bool = true,

    /// Width of the line number gutter in pixels
    gutter_width: f32 = 50,

    /// Gutter background color (null = use theme)
    gutter_background: ?Color = null,

    /// Line number text color (null = use theme)
    line_number_color: ?Color = null,

    /// Current line number highlight color (null = use theme)
    current_line_number_color: ?Color = null,

    /// Gutter/content separator color (null = use theme)
    gutter_separator_color: ?Color = null,

    /// Current line background highlight (null = use theme)
    current_line_background: ?Color = null,

    // =========================================================================
    // Status bar
    // =========================================================================

    /// Show status bar at bottom of editor
    show_status_bar: bool = true,

    /// Status bar height in pixels
    status_bar_height: f32 = 22,

    /// Status bar background color (null = use theme)
    status_bar_background: ?Color = null,

    /// Status bar text color (null = use theme)
    status_bar_text_color: ?Color = null,

    /// Status bar separator color (null = use theme)
    status_bar_separator_color: ?Color = null,

    /// Language mode displayed in status bar
    language_mode: []const u8 = "Plain Text",

    /// File encoding displayed in status bar
    encoding: []const u8 = "UTF-8",

    // =========================================================================
    // Tab behavior
    // =========================================================================

    /// Number of spaces per tab
    tab_size: u8 = 4,

    /// Use hard tabs (true) or spaces (false)
    use_hard_tabs: bool = false,

    // =========================================================================
    // Focus navigation
    // =========================================================================

    tab_index: i32 = 0,
    tab_stop: bool = true,

    // =========================================================================
    // Handlers
    // =========================================================================

    on_blur_handler: ?HandlerRef = null,

    // =========================================================================
    // Accessibility overrides
    // =========================================================================

    accessible_name: ?[]const u8 = null, // Label for screen readers
    accessible_description: ?[]const u8 = null,

    pub fn render(self: CodeEditor, b: *ui.Builder) void {
        const t = b.theme();

        // Resolve colors: explicit value OR theme default (dark theme for code)
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

        // Gutter colors (darker than main background)
        const gutter_background = self.gutter_background orelse t.surface;
        const line_number_color = self.line_number_color orelse t.muted;
        const current_line_number_color = self.current_line_number_color orelse t.text;
        const gutter_separator_color = self.gutter_separator_color orelse t.border;

        // Current line highlight (subtle)
        const current_line_background = self.current_line_background orelse t.primary.withAlpha(0.08);

        // Status bar colors
        const status_bar_background = self.status_bar_background orelse t.surface;
        const status_bar_text_color = self.status_bar_text_color orelse t.muted;
        const status_bar_separator_color = self.status_bar_separator_color orelse t.border;

        const layout_id = LayoutId.fromString(self.id);

        // Push accessible element (role: textarea for code editor)
        const a11y_pushed = b.accessible(.{
            .layout_id = layout_id,
            .role = .textarea,
            .name = self.accessible_name orelse if (self.placeholder.len > 0) self.placeholder else "Code editor",
            .description = self.accessible_description,
        });
        defer if (a11y_pushed) b.accessibleEnd();

        b.box(.{}, .{
            ui.codeEditor(self.id, .{
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
                .show_line_numbers = self.show_line_numbers,
                .gutter_width = self.gutter_width,
                .gutter_background = gutter_background,
                .line_number_color = line_number_color,
                .current_line_number_color = current_line_number_color,
                .gutter_separator_color = gutter_separator_color,
                .current_line_background = current_line_background,
                .tab_size = self.tab_size,
                .use_hard_tabs = self.use_hard_tabs,
                .show_status_bar = self.show_status_bar,
                .status_bar_height = self.status_bar_height,
                .status_bar_background = status_bar_background,
                .status_bar_text_color = status_bar_text_color,
                .status_bar_separator_color = status_bar_separator_color,
                .language_mode = self.language_mode,
                .encoding = self.encoding,
                .tab_index = self.tab_index,
                .tab_stop = self.tab_stop,
                .on_blur_handler = self.on_blur_handler,
            }),
        });
    }
};
