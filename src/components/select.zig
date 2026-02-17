//! Select Component
//!
//! A dropdown select menu for choosing from a list of options.
//! Supports keyboard navigation, configurable styling, and proper floating behavior.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.
//!
//! ## Recommended Usage (with `on_select`):
//!
//! ```zig
//! const State = struct {
//!     selected_option: ?usize = null,
//!
//!     pub fn selectOption(self: *State, index: usize) void {
//!         self.selected_option = index;
//!     }
//! };
//!
//! // In render — no toggle/close handlers, no per-option handler arrays:
//! Select{
//!     .id = "my-select",
//!     .options = &.{ "Apple", "Banana", "Cherry" },
//!     .selected = s.selected_option,
//!     .on_select = cx.onSelect(State.selectOption),
//! }
//! ```
//!
//! The widget internally manages open/close state when `on_select` is used
//! without explicit toggle/close handlers — no `is_open` field needed.
//!
//! ## Legacy Usage (manual state management):
//!
//! ```zig
//! Select{
//!     .id = "my-select",
//!     .options = &.{ "Apple", "Banana", "Cherry" },
//!     .selected = s.selected_option,
//!     .is_open = s.select_open,
//!     .on_toggle_handler = cx.update(State.toggleSelect),
//!     .on_close_handler = cx.update(State.closeSelect),
//!     .handlers = &.{
//!         cx.updateWith(@as(usize, 0), State.selectOption),
//!         cx.updateWith(@as(usize, 1), State.selectOption),
//!         cx.updateWith(@as(usize, 2), State.selectOption),
//!     },
//! }
//! ```

const std = @import("std");
const ui = @import("../ui/mod.zig");
const Color = ui.Color;
const Theme = ui.Theme;
const HandlerRef = ui.HandlerRef;
const layout_mod = @import("../layout/layout.zig");
const LayoutId = layout_mod.LayoutId;
const Svg = @import("svg.zig").Svg;
const Icons = @import("svg.zig").Icons;

// Handler / context imports for internal state management
const handler_mod = @import("../context/handler.zig");
const OnSelectHandler = handler_mod.OnSelectHandler;
const EntityId = handler_mod.EntityId;
const gooey_mod = @import("../context/gooey.zig");
const Gooey = gooey_mod.Gooey;

/// Hard cap on option count to prevent runaway loops.
const MAX_SELECT_OPTIONS: usize = 4096;

// =============================================================================
// Internal Handlers (module-level, used for internal open/close state)
// =============================================================================

/// Toggle a Select's internal open/close state.
/// EntityId packs the LayoutId hash (u32) in the lower bits.
fn internalToggle(g: *Gooey, packed_id: EntityId) void {
    const id_hash: u32 = @truncate(packed_id.id);
    std.debug.assert(id_hash != 0);
    g.widgets.toggleSelectState(id_hash);
    g.requestRender();
}

/// Close a Select's internal open/close state.
/// EntityId packs the LayoutId hash (u32) in the lower bits.
fn internalClose(g: *Gooey, packed_id: EntityId) void {
    const id_hash: u32 = @truncate(packed_id.id);
    std.debug.assert(id_hash != 0);
    g.widgets.closeSelectState(id_hash);
    g.requestRender();
}

// =============================================================================
// Select Component
// =============================================================================

/// A dropdown select component for single-option selection.
pub const Select = struct {
    /// Unique identifier for the select (used for element IDs and internal state)
    id: []const u8 = "select",

    /// List of options to display
    options: []const []const u8,

    /// Currently selected option index (null = nothing selected)
    selected: ?usize = null,

    /// Placeholder text when nothing is selected
    placeholder: []const u8 = "Select...",

    /// Whether the dropdown is currently open (legacy — ignored when using on_select)
    is_open: bool = false,

    // === New API: on_select (recommended) ===

    /// Index-based selection handler. When set without explicit toggle/close
    /// handlers, the widget manages open/close state internally.
    /// Created via `cx.onSelect(State.method)`.
    on_select: ?OnSelectHandler = null,

    // === Legacy API: manual handlers ===

    /// Handler to toggle open/closed state (called when trigger is clicked)
    on_toggle_handler: ?HandlerRef = null,

    /// Handler to close the dropdown (called on click-outside)
    on_close_handler: ?HandlerRef = null,

    /// Array of handlers, one per option. Use cx.updateWith() to create these.
    handlers: ?[]const HandlerRef = null,

    // === Layout ===

    /// Fixed width for the select (null = auto-size to content)
    width: ?f32 = 200,

    /// Minimum width for the dropdown menu
    min_dropdown_width: ?f32 = null,

    // === Styling (null = use theme) ===

    /// Background color for the trigger button
    background: ?Color = null,

    /// Background color when hovering the trigger
    hover_background: ?Color = null,

    /// Background color for selected/highlighted option
    selected_background: ?Color = null,

    /// Background color for option on hover
    option_hover_background: ?Color = null,

    /// Border color
    border_color: ?Color = null,

    /// Border color when open/focused
    focus_border_color: ?Color = null,

    /// Text color
    text_color: ?Color = null,

    /// Placeholder text color
    placeholder_color: ?Color = null,

    /// Font size
    font_size: u16 = 14,

    /// Corner radius (null = use theme)
    corner_radius: ?f32 = null,

    /// Padding inside the trigger
    padding: f32 = 10,

    /// Whether the select is disabled
    disabled: bool = false,

    // Accessibility overrides
    accessible_name: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    /// Resolved open/close state + handlers (internal vs external).
    const ResolvedState = struct {
        is_open: bool,
        toggle_handler: ?HandlerRef,
        close_handler: ?HandlerRef,

        /// Fallback when Gooey context is unavailable (e.g. headless/test).
        fn disabled() ResolvedState {
            return .{
                .is_open = false,
                .toggle_handler = null,
                .close_handler = null,
            };
        }
    };

    pub fn render(self: Select, b: *ui.Builder) void {
        std.debug.assert(self.id.len > 0);
        std.debug.assert(self.options.len <= MAX_SELECT_OPTIONS);

        const layout_id = LayoutId.fromString(self.id);
        const resolved = self.resolveState(b, layout_id);
        const colors = self.resolveColors(b.theme(), resolved.is_open);

        // Accessibility: combobox role
        const a11y_pushed = b.accessible(.{
            .layout_id = layout_id,
            .role = .combobox,
            .name = self.accessible_name orelse self.placeholder,
            .description = self.accessible_description,
            .value = self.getDisplayText(),
            .state = .{
                .expanded = resolved.is_open,
                .disabled = self.disabled,
                .has_popup = true,
            },
        });
        defer if (a11y_pushed) b.accessibleEnd();

        // Container: trigger + dropdown
        b.boxWithId(self.id, .{
            .width = self.width,
        }, .{
            SelectTrigger{
                .text = self.getDisplayText(),
                .is_placeholder = self.selected == null,
                .is_open = resolved.is_open,
                .on_click_handler = if (!self.disabled) resolved.toggle_handler else null,
                .background = colors.background,
                .hover_background = if (!self.disabled) colors.hover_bg else colors.background,
                .border_color = colors.current_border,
                .text_color = if (self.selected == null) colors.placeholder_col else colors.text_col,
                .font_size = self.font_size,
                .corner_radius = colors.radius,
                .padding = self.padding,
                .disabled = self.disabled,
            },
            SelectDropdown{
                .is_open = resolved.is_open,
                .options = self.options,
                .selected = self.selected,
                .handlers = self.handlers,
                .on_select = self.on_select,
                .id_hash = if (self.usesInternalState()) layout_id.id else 0,
                .on_close_handler = resolved.close_handler,
                .min_width = self.min_dropdown_width orelse self.width,
                .background = colors.background,
                .selected_background = colors.selected_bg,
                .hover_background = colors.option_hover_bg,
                .text_color = colors.text_col,
                .checkmark_color = b.theme().primary,
                .border_color = colors.border,
                .font_size = self.font_size,
                .corner_radius = colors.radius,
                .padding = self.padding,
            },
        });
    }

    /// Determine whether this Select uses internal (widget-managed) open/close state.
    /// True when `on_select` is set and no legacy toggle/close/handlers are provided.
    fn usesInternalState(self: Select) bool {
        return self.on_select != null and
            self.on_toggle_handler == null and
            self.on_close_handler == null and
            self.handlers == null;
    }

    /// Resolve open/close state and handlers — internal vs external.
    fn resolveState(self: Select, b: *ui.Builder, layout_id: LayoutId) ResolvedState {
        // Legacy path: caller manages open/close externally
        if (!self.usesInternalState()) {
            std.debug.assert(self.on_select != null or self.handlers != null or
                self.on_toggle_handler == null);
            return .{
                .is_open = self.is_open,
                .toggle_handler = self.on_toggle_handler,
                .close_handler = self.on_close_handler,
            };
        }

        // Internal state path: read from WidgetStore
        const g = b.gooey orelse return ResolvedState.disabled();
        const id_hash = layout_id.id;
        std.debug.assert(id_hash != 0);
        const ss = g.widgets.getOrCreateSelectState(id_hash) orelse return ResolvedState.disabled();

        return .{
            .is_open = ss.is_open,
            .toggle_handler = .{
                .callback = internalToggle,
                .entity_id = .{ .id = @as(u64, id_hash) },
            },
            .close_handler = .{
                .callback = internalClose,
                .entity_id = .{ .id = @as(u64, id_hash) },
            },
        };
    }

    /// Resolved color set (avoids repeating theme lookups).
    const ResolvedColors = struct {
        background: Color,
        hover_bg: Color,
        selected_bg: Color,
        option_hover_bg: Color,
        border: Color,
        current_border: Color,
        text_col: Color,
        placeholder_col: Color,
        radius: f32,
    };

    fn resolveColors(self: Select, t: *const Theme, is_open: bool) ResolvedColors {
        const background = self.background orelse t.surface;
        const border = self.border_color orelse t.border;
        const focus_border = self.focus_border_color orelse t.border_focus;
        std.debug.assert(self.font_size > 0);
        std.debug.assert(self.padding >= 0);
        return .{
            .background = background,
            .hover_bg = self.hover_background orelse t.overlay,
            .selected_bg = self.selected_background orelse t.primary.withAlpha(0.15),
            .option_hover_bg = self.option_hover_background orelse t.overlay,
            .border = border,
            .current_border = if (is_open) focus_border else border,
            .text_col = self.text_color orelse t.text,
            .placeholder_col = self.placeholder_color orelse t.muted,
            .radius = self.corner_radius orelse t.radius_md,
        };
    }

    fn getDisplayText(self: Select) []const u8 {
        if (self.selected) |idx| {
            std.debug.assert(self.options.len > 0);
            if (idx < self.options.len) {
                return self.options[idx];
            }
        }
        return self.placeholder;
    }
};

// =============================================================================
// Sub-components
// =============================================================================

/// The clickable trigger that shows current selection
const SelectTrigger = struct {
    text: []const u8,
    is_placeholder: bool,
    is_open: bool,
    on_click_handler: ?HandlerRef,
    background: Color,
    hover_background: Color,
    border_color: Color,
    text_color: Color,
    font_size: u16,
    corner_radius: f32,
    padding: f32,
    disabled: bool,

    pub fn render(self: SelectTrigger, b: *ui.Builder) void {
        std.debug.assert(self.font_size > 0);
        std.debug.assert(self.padding >= 0);

        const opacity: f32 = if (self.disabled) 0.6 else 1.0;

        b.box(.{
            .fill_width = true,
            .height = @as(f32, @floatFromInt(self.font_size)) + self.padding * 2 + 4,
            .padding = .{ .symmetric = .{ .x = self.padding, .y = self.padding / 2 } },
            .background = self.background.withAlpha(opacity),
            .hover_background = self.hover_background.withAlpha(opacity),
            .border_color = self.border_color,
            .border_width = .{ .all = 1 },
            .corner_radius = self.corner_radius,
            .direction = .row,
            .alignment = .{ .main = .space_between, .cross = .center },
            .on_click_handler = self.on_click_handler,
        }, .{
            // Selected text
            ui.text(self.text, .{
                .color = self.text_color.withAlpha(opacity),
                .size = self.font_size,
            }),
            // Dropdown arrow
            ChevronIcon{
                .is_open = self.is_open,
                .color = self.text_color.withAlpha(opacity),
                .size = 10,
            },
        });
    }
};

/// Chevron indicator that rotates when open
const ChevronIcon = struct {
    is_open: bool,
    color: Color,
    size: f32,

    pub fn render(self: ChevronIcon, b: *ui.Builder) void {
        std.debug.assert(self.size > 0);
        const icon_path = if (self.is_open) Icons.chevron_up else Icons.chevron_down;
        b.box(.{
            .width = self.size,
            .height = self.size,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            Svg{ .path = icon_path, .size = self.size, .color = self.color },
        });
    }
};

/// The floating dropdown menu containing options
const SelectDropdown = struct {
    is_open: bool,
    options: []const []const u8,
    selected: ?usize,
    // Legacy: explicit handler array (one per option)
    handlers: ?[]const HandlerRef,
    // New: index-based handler (generates per-option handlers internally)
    on_select: ?OnSelectHandler,
    /// LayoutId hash for internal state (0 = not using internal state)
    id_hash: u32,
    on_close_handler: ?HandlerRef,
    min_width: ?f32,
    background: Color,
    selected_background: Color,
    hover_background: Color,
    text_color: Color,
    checkmark_color: Color,
    border_color: Color,
    font_size: u16,
    corner_radius: f32,
    padding: f32,

    pub fn render(self: SelectDropdown, b: *ui.Builder) void {
        if (!self.is_open) return;
        std.debug.assert(self.options.len <= MAX_SELECT_OPTIONS);

        b.box(.{
            .width = self.min_width,
            .padding = .{ .all = 4 },
            .background = self.background,
            .border_color = self.border_color,
            .border_width = .{ .all = 1 },
            .corner_radius = self.corner_radius,
            .direction = .column,
            .gap = 2,
            .shadow = .{
                .blur_radius = 12,
                .offset_y = 4,
                .color = Color.rgba(0, 0, 0, 0.15),
            },
            .floating = ui.Floating.dropdown(),
            .on_click_outside_handler = self.on_close_handler,
        }, .{
            SelectOptions{
                .options = self.options,
                .selected = self.selected,
                .handlers = self.handlers,
                .on_select = self.on_select,
                .id_hash = self.id_hash,
                .selected_background = self.selected_background,
                .hover_background = self.hover_background,
                .text_color = self.text_color,
                .checkmark_color = self.checkmark_color,
                .font_size = self.font_size,
                .corner_radius = self.corner_radius - 2,
                .padding = self.padding,
            },
        });
    }
};

/// Renders all option items
const SelectOptions = struct {
    options: []const []const u8,
    selected: ?usize,
    // Legacy: explicit handler array
    handlers: ?[]const HandlerRef,
    // New: on_select + id_hash for per-option handler generation
    on_select: ?OnSelectHandler,
    id_hash: u32,
    selected_background: Color,
    hover_background: Color,
    text_color: Color,
    checkmark_color: Color,
    font_size: u16,
    corner_radius: f32,
    padding: f32,

    pub fn render(self: SelectOptions, b: *ui.Builder) void {
        std.debug.assert(self.options.len <= MAX_SELECT_OPTIONS);

        for (self.options, 0..) |label, i| {
            const handler: ?HandlerRef = self.resolveOptionHandler(i);
            const is_selected = if (self.selected) |sel| sel == i else false;

            b.with(SelectOption{
                .label = label,
                .is_selected = is_selected,
                .on_click_handler = handler,
                .selected_background = self.selected_background,
                .hover_background = self.hover_background,
                .text_color = self.text_color,
                .checkmark_color = self.checkmark_color,
                .font_size = self.font_size,
                .corner_radius = self.corner_radius,
                .padding = self.padding,
            });
        }
    }

    /// Resolve the click handler for option at `index`.
    /// Prefers legacy `handlers` array; falls back to `on_select` generation.
    fn resolveOptionHandler(self: SelectOptions, index: usize) ?HandlerRef {
        // Legacy path: explicit handler array
        if (self.handlers) |h| {
            std.debug.assert(h.len <= MAX_SELECT_OPTIONS);
            return if (index < h.len) h[index] else null;
        }
        // New path: generate from on_select
        if (self.on_select) |os| {
            if (self.id_hash != 0) {
                // Internal state: select + close
                return os.forIndexAndClose(@intCast(index), self.id_hash);
            } else {
                // External state: select only
                return os.forIndex(index);
            }
        }
        return null;
    }
};

/// A single option in the dropdown
const SelectOption = struct {
    label: []const u8,
    is_selected: bool,
    on_click_handler: ?HandlerRef,
    selected_background: Color,
    hover_background: Color,
    text_color: Color,
    checkmark_color: Color,
    font_size: u16,
    corner_radius: f32,
    padding: f32,

    pub fn render(self: SelectOption, b: *ui.Builder) void {
        const bg = if (self.is_selected) self.selected_background else Color.transparent;

        b.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = self.padding, .y = self.padding * 0.7 } },
            .background = bg,
            .hover_background = self.hover_background,
            .corner_radius = self.corner_radius,
            .direction = .row,
            .alignment = .{ .cross = .center },
            .gap = 8,
            .on_click_handler = self.on_click_handler,
        }, .{
            // Checkmark for selected item
            SelectCheckmark{
                .visible = self.is_selected,
                .color = self.checkmark_color,
            },
            // Option text
            ui.text(self.label, .{
                .color = self.text_color,
                .size = self.font_size,
            }),
        });
    }
};

/// Checkmark indicator for selected option
const SelectCheckmark = struct {
    visible: bool,
    color: Color,

    pub fn render(self: SelectCheckmark, b: *ui.Builder) void {
        if (self.visible) {
            b.box(.{
                .width = 16,
                .height = 16,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                Svg{ .path = Icons.check, .size = 14, .color = self.color },
            });
        } else {
            // Empty space to maintain alignment
            b.box(.{
                .width = 16,
                .height = 16,
            }, .{});
        }
    }
};
