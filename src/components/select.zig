//! Select Component
//!
//! A dropdown select menu for choosing from a list of options.
//! Supports keyboard navigation, configurable styling, and proper floating behavior.
//!
//! Colors default to null, which means "use the current theme".
//! Set explicit colors to override theme defaults.
//!
//! Select is controlled: the application owns its open state and supplies the
//! handlers that toggle and close it.
//!
//! ```zig
//! const State = struct {
//!     selected_option: ?usize = null,
//!     select_open: bool = false,
//!
//!     pub fn selectOption(self: *State, index: usize) void {
//!         self.selected_option = index;
//!         self.select_open = false;
//!     }
//!
//!     pub fn toggleSelect(self: *State) void {
//!         self.select_open = !self.select_open;
//!     }
//!
//!     pub fn closeSelect(self: *State) void {
//!         self.select_open = false;
//!     }
//! };
//!
//! Select{
//!     .id = "my-select",
//!     .options = &.{ "Apple", "Banana", "Cherry" },
//!     .selected = s.selected_option,
//!     .is_open = s.select_open,
//!     .on_toggle = cx.update(State.toggleSelect),
//!     .on_close = cx.update(State.closeSelect),
//!     .on_select = cx.onSelect(State.selectOption),
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

const handler_mod = @import("../context/handler.zig");
const OnSelectHandler = handler_mod.OnSelectHandler;

/// Hard cap on option count to prevent runaway loops.
const MAX_SELECT_OPTIONS: usize = 4096;

// =============================================================================
// Select Component
// =============================================================================

/// A dropdown select component for single-option selection.
pub const Select = struct {
    /// Unique identifier used for element and accessibility IDs.
    id: []const u8,

    /// List of options to display
    options: []const []const u8,

    /// Optional per-option leading icon shown in each dropdown row (not the
    /// trigger), index-aligned with `options`. A `null` slice means no
    /// option has an icon; an individual `null` entry means that specific
    /// option has none. Added so a single dropdown spanning multiple
    /// logical groups (e.g. chat models from different providers) can
    /// brand each row without the trigger being pinned to one icon.
    option_icons: ?[]const ?OptionIcon = null,

    /// Uniform render size for `option_icons` entries.
    option_icon_size: f32 = 16,

    /// Tint for `option_icons`. Null falls back to `text_color`.
    option_icon_color: ?Color = null,

    /// Currently selected option index (null = nothing selected)
    selected: ?usize = null,

    /// Placeholder text when nothing is selected
    placeholder: []const u8 = "Select...",

    /// Whether the dropdown is currently open. Owned by the application.
    is_open: bool,

    /// Index-based selection handler, typed `OnSelectHandler` (not a plain
    /// `?HandlerRef`) because it must carry the chosen option index through to
    /// the state method. `RadioGroup` and `TabBar` share this exact shape, so
    /// index-based selection reads identically across all three widgets.
    /// Fixed, index-free actions (Button, Tab, `context_menu.MenuItem`) use
    /// `on_click: ?HandlerRef` instead — the framework keeps the two concepts
    /// on distinct names so a field named `on_select` always has one type.
    /// Created via `cx.onSelect(State.method)`.
    on_select: OnSelectHandler,

    /// Handler that toggles application-owned open state.
    on_toggle: HandlerRef,

    /// Handler that closes application-owned open state on click-outside.
    on_close: HandlerRef,

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

    /// Font size (null = use theme font_size_base)
    font_size: ?u16 = null,

    /// Corner radius (null = use theme)
    corner_radius: ?f32 = null,

    /// Padding inside the trigger
    padding: f32 = 10,

    /// Whether the select is disabled
    disabled: bool = false,

    // Accessibility overrides
    accessible_name: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    /// A leading icon for one dropdown option (see `option_icons` above).
    /// Kept separate from `Svg` itself (rather than embedding `Svg` directly)
    /// so `Select` only depends on the two fields it actually varies per
    /// option — everything else (size, tint) is uniform and lives on `Select`.
    /// Nested rather than module-level so callers spell it `Select.OptionIcon`.
    pub const OptionIcon = struct {
        /// SVG path data (the `d` attribute), same convention as `Svg.path`.
        path: []const u8,

        /// Source SVG viewBox size (square). Default 24 covers most icon
        /// sets; override for logos with a non-square or differently-scaled
        /// viewBox.
        viewbox: f32 = 24,
    };

    pub fn render(self: Select, cx: *ui.Cx) void {
        std.debug.assert(self.id.len > 0);
        std.debug.assert(self.options.len <= MAX_SELECT_OPTIONS);
        if (self.option_icons) |icons| std.debug.assert(icons.len == self.options.len);

        const layout_id = LayoutId.fromString(self.id);
        const t = cx.theme();
        const font_size = self.font_size orelse t.font_size_base;
        std.debug.assert(font_size > 0);
        const colors = self.resolveColors(t, self.is_open);

        // Accessibility: combobox role
        const a11y_pushed = cx.accessible(.{
            .layout_id = layout_id,
            .role = .combobox,
            .name = self.accessible_name orelse self.placeholder,
            .description = self.accessible_description,
            .value = self.getDisplayText(),
            .state = .{
                .expanded = self.is_open,
                .disabled = self.disabled,
                .has_popup = true,
            },
        });
        defer if (a11y_pushed) cx.accessibleEnd();

        // Reuse the resolved layout ID so the required component identity is
        // hashed exactly once.
        cx.render(ui.box_with_layout_id(layout_id, .{
            .width = self.width,
            .on_click_outside_handler = if (self.is_open) self.on_close else null,
        }, .{
            SelectTrigger{
                .text = self.getDisplayText(),
                .is_placeholder = self.selected == null,
                .is_open = self.is_open,
                .on_click = if (!self.disabled) self.on_toggle else null,
                .background = colors.background,
                .hover_background = if (!self.disabled) colors.hover_bg else colors.background,
                .border_color = colors.current_border,
                .text_color = if (self.selected == null)
                    colors.placeholder_col
                else
                    colors.text_col,
                .font_size = font_size,
                .corner_radius = colors.radius,
                .padding = self.padding,
                .disabled = self.disabled,
            },
            SelectDropdown{
                .is_open = self.is_open,
                .options = self.options,
                .option_icons = self.option_icons,
                .option_icon_size = self.option_icon_size,
                .option_icon_color = self.option_icon_color orelse colors.text_col,
                .selected = self.selected,
                .on_select = self.on_select,
                .min_width = self.min_dropdown_width orelse self.width,
                .background = colors.background,
                .selected_background = colors.selected_bg,
                .hover_background = colors.option_hover_bg,
                .text_color = colors.text_col,
                .checkmark_color = cx.theme().primary,
                .border_color = colors.border,
                .font_size = font_size,
                .corner_radius = colors.radius,
                .padding = self.padding,
            },
        }));
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
            if (idx < self.options.len) {
                return self.options[idx];
            }
        }
        return self.placeholder;
    }
};

test "Select dropdown width is a floor rather than a fixed constraint" {
    // Goal: option content may widen the popup beyond the trigger width.
    // Methodology: inspect the exact sizing pair consumed by SelectDropdown.
    const sizing = resolveDropdownSizing(160);

    try std.testing.expectEqual(@as(?f32, null), sizing.width);
    try std.testing.expectEqual(@as(?f32, 160), sizing.min_width);
}

// =============================================================================
// Sub-components
// =============================================================================

/// The clickable trigger that shows current selection
const SelectTrigger = struct {
    text: []const u8,
    is_placeholder: bool,
    is_open: bool,
    on_click: ?HandlerRef,
    background: Color,
    hover_background: Color,
    border_color: Color,
    text_color: Color,
    font_size: u16,
    corner_radius: f32,
    padding: f32,
    disabled: bool,

    pub fn render(self: SelectTrigger, cx: *ui.Cx) void {
        std.debug.assert(self.font_size > 0);
        std.debug.assert(self.padding >= 0);

        const opacity: f32 = if (self.disabled) 0.6 else 1.0;

        cx.render(ui.box(.{
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
            .on_click_handler = self.on_click,
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
        }));
    }
};

/// Chevron indicator that rotates when open
const ChevronIcon = struct {
    is_open: bool,
    color: Color,
    size: f32,

    pub fn render(self: ChevronIcon, cx: *ui.Cx) void {
        std.debug.assert(self.size > 0);
        const icon_path = if (self.is_open) Icons.chevron_up else Icons.chevron_down;
        cx.render(ui.box(.{
            .width = self.size,
            .height = self.size,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            Svg{ .path = icon_path, .size = self.size, .color = self.color },
        }));
    }
};

const DropdownSizing = struct {
    width: ?f32,
    min_width: ?f32,
};

fn resolveDropdownSizing(min_width: ?f32) DropdownSizing {
    if (min_width) |width| std.debug.assert(width >= 0);
    const sizing = DropdownSizing{ .width = null, .min_width = min_width };
    std.debug.assert(sizing.width == null);
    std.debug.assert(sizing.min_width == min_width);
    return sizing;
}

/// The floating dropdown menu containing options
const SelectDropdown = struct {
    is_open: bool,
    options: []const []const u8,
    option_icons: ?[]const ?Select.OptionIcon,
    option_icon_size: f32,
    option_icon_color: Color,
    selected: ?usize,
    on_select: OnSelectHandler,
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

    pub fn render(self: SelectDropdown, cx: *ui.Cx) void {
        if (!self.is_open) return;
        std.debug.assert(self.options.len <= MAX_SELECT_OPTIONS);
        std.debug.assert(self.font_size > 0);
        if (self.min_width) |width| std.debug.assert(width >= 0);
        const sizing = resolveDropdownSizing(self.min_width);

        cx.render(ui.box(.{
            .width = sizing.width,
            .min_width = sizing.min_width,
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
        }, .{
            SelectOptions{
                .options = self.options,
                .option_icons = self.option_icons,
                .option_icon_size = self.option_icon_size,
                .option_icon_color = self.option_icon_color,
                .selected = self.selected,
                .on_select = self.on_select,
                .selected_background = self.selected_background,
                .hover_background = self.hover_background,
                .text_color = self.text_color,
                .checkmark_color = self.checkmark_color,
                .font_size = self.font_size,
                .corner_radius = self.corner_radius - 2,
                .padding = self.padding,
            },
        }));
    }
};

/// Renders all option items
const SelectOptions = struct {
    options: []const []const u8,
    option_icons: ?[]const ?Select.OptionIcon,
    option_icon_size: f32,
    option_icon_color: Color,
    selected: ?usize,
    on_select: OnSelectHandler,
    selected_background: Color,
    hover_background: Color,
    text_color: Color,
    checkmark_color: Color,
    font_size: u16,
    corner_radius: f32,
    padding: f32,

    pub fn render(self: SelectOptions, cx: *ui.Cx) void {
        std.debug.assert(self.options.len <= MAX_SELECT_OPTIONS);

        for (self.options, 0..) |label, i| {
            const handler = self.on_select.forIndex(i);
            // `self.selected` is the chosen index (?usize); this derives the
            // per-option boolean for the item at index `i`.
            const option_selected = if (self.selected) |sel| sel == i else false;
            const icon: ?Select.OptionIcon = if (self.option_icons) |icons| icons[i] else null;

            cx.with(SelectOption{
                .label = label,
                .icon = icon,
                .icon_size = self.option_icon_size,
                .icon_color = self.option_icon_color,
                .selected = option_selected,
                .on_click = handler,
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
};

/// A single option in the dropdown
const SelectOption = struct {
    label: []const u8,
    icon: ?Select.OptionIcon,
    icon_size: f32,
    icon_color: Color,
    selected: bool,
    on_click: ?HandlerRef,
    selected_background: Color,
    hover_background: Color,
    text_color: Color,
    checkmark_color: Color,
    font_size: u16,
    corner_radius: f32,
    padding: f32,

    pub fn render(self: SelectOption, cx: *ui.Cx) void {
        std.debug.assert(self.font_size > 0);
        std.debug.assert(self.padding >= 0);
        const bg = if (self.selected) self.selected_background else Color.transparent;

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = self.padding, .y = self.padding * 0.7 } },
            .background = bg,
            .hover_background = self.hover_background,
            .corner_radius = self.corner_radius,
            .direction = .row,
            .alignment = .{ .main = .space_between, .cross = .center },
            .gap = 8,
            .on_click_handler = self.on_click,
        }, .{
            // Icon + label grouped together so `space_between` still puts
            // exactly one leading group against the trailing checkmark.
            ui.box(.{
                .direction = .row,
                .alignment = .{ .main = .start, .cross = .center },
                .gap = 8,
            }, .{
                SelectOptionIcon{
                    .icon = self.icon,
                    .size = self.icon_size,
                    .color = self.icon_color,
                },
                ui.text(self.label, .{
                    .color = self.text_color,
                    .size = self.font_size,
                }),
            }),
            SelectCheckmark{
                .visible = self.selected,
                .color = self.checkmark_color,
            },
        }));
    }
};

/// Leading icon for one dropdown row. Renders nothing when `icon` is null
/// (no reserved space, no gap contributed) so options without an icon sit
/// flush with the row's left edge, matching pre-icon layout exactly.
const SelectOptionIcon = struct {
    icon: ?Select.OptionIcon,
    size: f32,
    color: Color,

    pub fn render(self: SelectOptionIcon, cx: *ui.Cx) void {
        const icon = self.icon orelse return;
        std.debug.assert(self.size > 0);
        std.debug.assert(icon.viewbox > 0);
        cx.render(ui.box(.{
            .width = self.size,
            .height = self.size,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            Svg{
                .path = icon.path,
                .size = self.size,
                .color = self.color,
                .viewbox = icon.viewbox,
            },
        }));
    }
};

/// Checkmark indicator for selected option
const SelectCheckmark = struct {
    visible: bool,
    color: Color,

    pub fn render(self: SelectCheckmark, cx: *ui.Cx) void {
        if (self.visible) {
            cx.render(ui.box(.{
                .width = 16,
                .height = 16,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                Svg{ .path = Icons.check, .size = 14, .color = self.color },
            }));
        } else {
            // Empty space to maintain alignment
            cx.render(ui.box(.{
                .width = 16,
                .height = 16,
            }, .{}));
        }
    }
};
