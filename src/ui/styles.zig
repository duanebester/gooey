//! UI Style Types
//!
//! Style configurations for UI elements: Box, TextStyle, InputStyle, etc.
//! These define the visual appearance and layout behavior of UI elements.

const std = @import("std");

// Layout types
const layout_types = @import("../layout/types.zig");
const layout_mod = @import("../layout/layout.zig");
const Padding = layout_mod.Padding;
const FloatingConfig = layout_types.FloatingConfig;

// Re-exports for convenience
pub const Color = @import("../core/geometry.zig").Color;
pub const ShadowConfig = layout_types.ShadowConfig;
pub const AttachPoint = layout_types.AttachPoint;
pub const CornerRadius = layout_mod.CornerRadius;
pub const ObjectFit = @import("../image/atlas.zig").ObjectFit;
pub const HandlerRef = @import("../context/handler.zig").HandlerRef;

// =============================================================================
// Floating Configuration
// =============================================================================

/// User-friendly floating configuration for dropdowns, tooltips, modals, etc.
/// Floating elements are positioned relative to their parent (or viewport)
/// and render with a higher z-index for proper layering.
pub const Floating = struct {
    /// Where on the floating element to attach
    element_anchor: AttachPoint = .left_top,
    /// Where on the parent to attach
    parent_anchor: AttachPoint = .left_top,
    /// Offset from the anchor point
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    /// Z-index for layering (higher = on top). Default 100 for floating elements.
    z_index: i16 = 100,
    /// If false, positions relative to viewport instead of parent
    attach_to_parent: bool = true,

    /// Preset for dropdown menus (below parent, aligned left)
    pub fn dropdown() Floating {
        return .{
            .element_anchor = .left_top,
            .parent_anchor = .left_bottom,
            .offset_y = 4, // Small gap
        };
    }

    /// Preset for tooltips (above parent, centered)
    pub fn tooltip() Floating {
        return .{
            .element_anchor = .center_bottom,
            .parent_anchor = .center_top,
            .offset_y = -4,
        };
    }

    /// Preset for modals (centered on viewport)
    pub fn modal() Floating {
        return .{
            .attach_to_parent = false,
            .element_anchor = .center_center,
            .parent_anchor = .center_center,
        };
    }

    /// Preset for context menus (positioned at cursor, typically)
    pub fn contextMenu() Floating {
        return .{
            .element_anchor = .left_top,
            .parent_anchor = .left_top,
        };
    }

    /// Convert to internal FloatingConfig
    pub fn toFloatingConfig(self: Floating) FloatingConfig {
        return .{
            .offset = .{ .x = self.offset_x, .y = self.offset_y },
            .z_index = self.z_index,
            .attach_to_parent = self.attach_to_parent,
            .element_attach = self.element_anchor,
            .parent_attach = self.parent_anchor,
        };
    }
};

// =============================================================================
// Text Style
// =============================================================================

/// Text styling options
pub const TextStyle = struct {
    size: u16 = 14,
    color: Color = Color.black,
    weight: Weight = .regular,
    italic: bool = false,
    wrap: WrapMode = .none,
    alignment: Alignment = .left,
    underline: bool = false,
    strikethrough: bool = false,

    pub const Weight = enum { thin, light, regular, medium, semibold, bold, black };
    pub const WrapMode = enum { none, words, newlines };
    pub const Alignment = enum { left, center, right };
};

// =============================================================================
// Box Style
// =============================================================================

/// Box is the fundamental UI primitive. All interactive elements are built on Box.
pub const Box = struct {
    // Sizing
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: ?f32 = null,
    min_height: ?f32 = null,
    max_width: ?f32 = null,
    max_height: ?f32 = null,
    grow: bool = false, // Grow both axes
    grow_width: bool = false, // Grow width only
    grow_height: bool = false, // Grow height only
    fill_width: bool = false, // 100% of parent width
    fill_height: bool = false, // 100% of parent height
    width_percent: ?f32 = null, // Percentage of parent width (0.0-1.0)
    height_percent: ?f32 = null, // Percentage of parent height (0.0-1.0)

    // Spacing
    padding: PaddingValue = .{ .all = 0 },
    gap: f32 = 0,

    // Appearance
    background: Color = Color.transparent,
    corner_radius: f32 = 0,
    opacity: f32 = 1.0,
    border_color: Color = Color.transparent,
    border_width: f32 = 0,

    shadow: ?ShadowConfig = null,

    // Floating positioning (for dropdowns, tooltips, modals)
    floating: ?Floating = null,

    // Hover styles (applied when element is hovered)
    hover_background: ?Color = null,
    hover_border_color: ?Color = null,

    // Layout
    direction: Direction = .column,
    alignment: Alignment = .{ .main = .start, .cross = .start },

    // Interaction
    on_click: ?*const fn () void = null,
    on_click_handler: ?HandlerRef = null,
    on_click_outside: ?*const fn () void = null,
    on_click_outside_handler: ?HandlerRef = null,

    pub const Direction = enum { row, column };

    pub const Alignment = struct {
        main: MainAxis = .start,
        cross: CrossAxis = .start,

        pub const MainAxis = enum { start, center, end, space_between, space_around, space_evenly };
        pub const CrossAxis = enum { start, center, end, stretch };
    };

    pub const PaddingValue = union(enum) {
        all: f32,
        symmetric: struct { x: f32, y: f32 },
        each: struct { top: f32, right: f32, bottom: f32, left: f32 },
    };

    /// Convert to layout Padding
    pub fn toPadding(self: Box) Padding {
        return switch (self.padding) {
            .all => |v| Padding.all(@intFromFloat(v)),
            .symmetric => |s| Padding.symmetric(@intFromFloat(s.x), @intFromFloat(s.y)),
            .each => |e| .{
                .top = @intFromFloat(e.top),
                .right = @intFromFloat(e.right),
                .bottom = @intFromFloat(e.bottom),
                .left = @intFromFloat(e.left),
            },
        };
    }
};

// =============================================================================
// Input Styles
// =============================================================================

/// Input field options
pub const InputStyle = struct {
    // Content
    placeholder: []const u8 = "",
    secure: bool = false,

    // Binding
    bind: ?*[]const u8 = null,

    // Focus navigation
    tab_index: i32 = 0,
    tab_stop: bool = true,

    // Layout
    width: ?f32 = null,
    height: ?f32 = null,
    padding: f32 = 8,

    // Visual chrome (rendered by component)
    background: Color = Color.white,
    border_color: Color = Color.rgb(0.8, 0.8, 0.8),
    border_color_focused: Color = Color.rgb(0.3, 0.5, 1.0),
    border_width: f32 = 1,
    corner_radius: f32 = 4,

    // Text colors (passed to widget)
    text_color: Color = Color.black,
    placeholder_color: Color = Color.rgb(0.6, 0.6, 0.6),
    selection_color: Color = Color.rgba(0.3, 0.5, 1.0, 0.3),
    cursor_color: Color = Color.black,
};

/// Multi-line text area options
pub const TextAreaStyle = struct {
    placeholder: []const u8 = "",
    bind: ?*[]const u8 = null,

    // Focus
    tab_index: i32 = 0,
    tab_stop: bool = true,

    // Layout
    width: ?f32 = null,
    height: ?f32 = null, // null = auto-size based on rows
    rows: usize = 4, // Default visible rows (used when height is null)
    padding: f32 = 8,

    // Visual
    background: Color = Color.white,
    border_color: Color = Color.rgb(0.8, 0.8, 0.8),
    border_color_focused: Color = Color.rgb(0.3, 0.5, 1.0),
    border_width: f32 = 1,
    corner_radius: f32 = 4,

    // Text
    text_color: Color = Color.black,
    placeholder_color: Color = Color.rgb(0.6, 0.6, 0.6),
    selection_color: Color = Color.rgba(0.3, 0.5, 1.0, 0.3),
    cursor_color: Color = Color.black,

    // Scrollbar
    scrollbar_width: f32 = 8,
    scrollbar_track_color: Color = Color.rgba(0.5, 0.5, 0.5, 0.1),
    scrollbar_thumb_color: Color = Color.rgba(0.5, 0.5, 0.5, 0.4),
};

// =============================================================================
// Layout Container Styles
// =============================================================================

/// Stack layout options
pub const StackStyle = struct {
    gap: f32 = 0,
    alignment: Alignment = .start,
    padding: f32 = 0,

    pub const Alignment = enum { start, center, end, stretch };
};

/// Center container options
pub const CenterStyle = struct {
    padding: f32 = 0,
};

/// Scroll container options
pub const ScrollStyle = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    /// Content width (if known ahead of time, for horizontal scrolling)
    content_width: ?f32 = null,
    /// Content height (if known ahead of time)
    content_height: ?f32 = null,

    // Flexible sizing (like Box)
    grow: bool = false, // Grow both axes
    grow_width: bool = false, // Grow width only
    grow_height: bool = false, // Grow height only
    fill_width: bool = false, // 100% of parent width
    fill_height: bool = false, // 100% of parent height

    /// Padding inside the scroll area
    padding: Box.PaddingValue = .{ .all = 0 },
    gap: u16 = 0,
    background: ?Color = null,
    corner_radius: f32 = 0,
    /// Scrollbar styling
    scrollbar_size: f32 = 8,
    track_color: ?Color = null,
    thumb_color: ?Color = null,
    /// Only vertical for now
    vertical: bool = true,
    horizontal: bool = false,
};

/// Uniform list container options (virtualized, fixed-height items)
/// Use with UniformListState for O(1) layout with any number of items.
pub const UniformListStyle = struct {
    /// Fixed viewport width (optional - defaults to grow)
    width: ?f32 = null,
    /// Fixed viewport height (required for virtualization to work well)
    height: ?f32 = null,

    // Flexible sizing (like Box)
    grow: bool = false, // Grow both axes
    grow_width: bool = false, // Grow width only
    grow_height: bool = false, // Grow height only
    fill_width: bool = false, // 100% of parent width
    fill_height: bool = false, // 100% of parent height

    /// Padding inside the list area
    padding: Box.PaddingValue = .{ .all = 0 },
    /// Gap between items (added to item height for spacing)
    gap: f32 = 0,
    /// Background color
    background: ?Color = null,
    /// Corner radius
    corner_radius: f32 = 0,

    /// Scrollbar styling
    scrollbar_size: f32 = 8,
    track_color: ?Color = null,
    thumb_color: ?Color = null,
};

/// Virtual list container options (virtualized, variable-height items)
/// Use with VirtualListState for lists where items have different heights.
/// Item heights are cached after rendering for efficient scroll calculations.
pub const VirtualListStyle = struct {
    /// Fixed viewport width (optional - defaults to grow)
    width: ?f32 = null,
    /// Fixed viewport height (required for virtualization to work well)
    height: ?f32 = null,

    // Flexible sizing (like Box)
    grow: bool = false, // Grow both axes
    grow_width: bool = false, // Grow width only
    grow_height: bool = false, // Grow height only
    fill_width: bool = false, // 100% of parent width
    fill_height: bool = false, // 100% of parent height

    /// Padding inside the list area
    padding: Box.PaddingValue = .{ .all = 0 },
    /// Gap between items
    gap: f32 = 0,
    /// Background color
    background: ?Color = null,
    /// Corner radius
    corner_radius: f32 = 0,

    /// Scrollbar styling
    scrollbar_size: f32 = 8,
    track_color: ?Color = null,
    thumb_color: ?Color = null,
};

/// Data table styling options (virtualized 2D table)
/// Use with DataTableState for O(1) layout with any number of rows/columns.
pub const DataTableStyle = struct {
    /// Fixed viewport width (optional - defaults to grow)
    width: ?f32 = null,
    /// Fixed viewport height (required for virtualization to work well)
    height: ?f32 = null,

    // Flexible sizing (like Box)
    grow: bool = false,
    grow_width: bool = false,
    grow_height: bool = false,
    fill_width: bool = false,
    fill_height: bool = false,

    /// Padding inside the table area
    padding: Box.PaddingValue = .{ .all = 0 },
    /// Gap between rows
    row_gap: f32 = 0,
    /// Background color
    background: ?Color = null,
    /// Corner radius
    corner_radius: f32 = 0,

    // Header styling
    header_background: ?Color = null,
    header_border_bottom: ?Color = null,

    // Row styling
    row_background: ?Color = null,
    row_alternate_background: ?Color = null,
    row_hover_background: ?Color = null,
    row_selected_background: ?Color = null,

    // Cell styling
    cell_padding: Box.PaddingValue = .{ .symmetric = .{ .x = 8, .y = 0 } },

    // Column resize
    resize_handle_width: f32 = 4.0,
    resize_handle_color: ?Color = null,

    // Scrollbar styling
    scrollbar_size: f32 = 8,
    track_color: ?Color = null,
    thumb_color: ?Color = null,

    // Interaction callbacks
    /// Called when a header column is clicked (for sorting)
    on_header_click: ?*const fn (col: u32) void = null,
    /// Called when a row is clicked (for selection)
    on_row_click: ?*const fn (row: u32) void = null,
    /// Called when a cell is clicked
    on_cell_click: ?*const fn (row: u32, col: u32) void = null,
};

// =============================================================================
// Component Styles
// =============================================================================

/// Button styling options
pub const ButtonStyle = struct {
    style: Style = .primary,
    enabled: bool = true,

    pub const Style = enum { primary, secondary, danger };
};

/// Checkbox styling options
pub const CheckboxStyle = struct {
    label: []const u8 = "",
    bind: ?*bool = null,
    on_change: ?*const fn (bool) void = null,

    // Theme-aware colors (optional - uses defaults if not set)
    background: ?Color = null, // Unchecked background
    background_checked: ?Color = null, // Checked background (e.g. theme.primary)
    border_color: ?Color = null, // Border color (e.g. theme.muted)
    checkmark_color: ?Color = null, // Inner square color
    label_color: ?Color = null, // Label text color (e.g. theme.text)
};
