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
//!     .on_toggle = cx.update(State.toggleSelect),
//!     .on_close = cx.update(State.closeSelect),
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
const window_mod = @import("../context/window.zig");
const Window = window_mod.Window;

/// Hard cap on option count to prevent runaway loops.
const MAX_SELECT_OPTIONS: usize = 4096;

// =============================================================================
// Internal state (PR 8.2 — lives next to the widget that owns it)
// =============================================================================

/// Internal open/close state for `Select`, attached to the widget's
/// `LayoutId` hash and stored on `Window.element_states`.
///
/// Pre-PR-8.2 this lived in `context/widget_store.zig` alongside a
/// dedicated `select_states: AutoHashMap(u32, SelectState)` field plus
/// four accessor methods on `WidgetStore`. PR 8 collapses every
/// per-type widget map onto the unified `ElementStates` keyed pool;
/// `Select` is the first consumer (smallest, u32-keyed). The state
/// type itself moved here so the widget owns its declaration —
/// adding a new stateful widget is now a no-op in framework code.
///
/// `defaultInit` is the comptime function pointer
/// `withElementState` runs on the miss path. It must take no
/// parameters and return `Self` by value (the pool then
/// `allocator.create(Self)` and assigns this value into the slot).
pub const SelectState = struct {
    is_open: bool = false,

    /// Default-state factory for `withElementState`. Closed dropdown
    /// is the only sensible initial state (a freshly-mounted Select
    /// renders its trigger only — the dropdown materialises on the
    /// first toggle).
    pub fn defaultInit() SelectState {
        return .{ .is_open = false };
    }
};

// =============================================================================
// Internal Handlers (module-level, used for internal open/close state)
// =============================================================================

/// Toggle a Select's internal open/close state.
/// EntityId packs the LayoutId hash (u32) in the lower bits.
///
/// PR 8.2 — routed through `Window.element_states` instead of the
/// retired `WidgetStore.toggleSelectState`. The miss-path allocation
/// returns `error.OutOfMemory` or `error.ElementStatesAtCapacity`;
/// either failure mode is handled by leaving the dropdown closed for
/// this tick (caller can retry next frame) rather than panicking.
/// Same defensive shape the pre-PR-8.2 path had with the
/// `getOrPut catch return null` in the old `toggleSelectState`.
fn internalToggle(g: *Window, packed_id: EntityId) void {
    const id_hash: u32 = @truncate(packed_id.id);
    std.debug.assert(id_hash != 0);

    const ss = g.element_states.withElementState(
        SelectState,
        @as(u64, id_hash),
        SelectState.defaultInit,
    ) catch return;
    ss.is_open = !ss.is_open;

    g.requestRender();
}

/// Close a Select's internal open/close state.
/// EntityId packs the LayoutId hash (u32) in the lower bits.
///
/// PR 8.2 — routed through `Window.element_states.get`. Unlike
/// `internalToggle` we deliberately do NOT create the slot on miss:
/// closing a never-opened Select is a no-op (the dropdown wasn't
/// rendered, so there's no state to close), and creating one would
/// add an empty entry to the pool every time a click-outside handler
/// fires on an untouched Select.
fn internalClose(g: *Window, packed_id: EntityId) void {
    const id_hash: u32 = @truncate(packed_id.id);
    std.debug.assert(id_hash != 0);

    if (g.element_states.get(SelectState, @as(u64, id_hash))) |ss| {
        ss.is_open = false;
    }
    g.requestRender();
}

// =============================================================================
// Select Component
// =============================================================================

/// A dropdown select component for single-option selection.
pub const Select = struct {
    /// Unique identifier — used for element IDs and to key the retained
    /// open/close state in `Window.element_states`. Required (no default):
    /// Select is a stateful, retained-by-id widget, and the old shared
    /// `"select"` default made two selects on one screen silently share a
    /// single open/close state. Matches the required-`id` convention of the
    /// other controlled widgets (`Modal`, `TextInput`).
    id: []const u8,

    /// List of options to display
    options: []const []const u8,

    /// Currently selected option index (null = nothing selected)
    selected: ?usize = null,

    /// Placeholder text when nothing is selected
    placeholder: []const u8 = "Select...",

    /// Whether the dropdown is currently open. Legacy manual-control field;
    /// ignored only when `controlMode()` resolves to `.internal`.
    is_open: bool = false,

    // === New API: on_select (recommended) ===

    /// Index-based selection handler, typed `?OnSelectHandler` (NOT a plain
    /// `?HandlerRef`) because it must carry the chosen option index through to
    /// the state method. `RadioGroup` and `TabBar` share this exact shape, so
    /// index-based selection reads identically across all three widgets.
    /// Fixed, index-free actions (Button, Tab, `context_menu.MenuItem`) use
    /// `on_click: ?HandlerRef` instead — the framework keeps the two concepts
    /// on distinct names so a field named `on_select` always has one type.
    /// When set without explicit toggle/close handlers, the widget manages
    /// open/close state internally. Created via `cx.onSelect(State.method)`.
    on_select: ?OnSelectHandler = null,

    // === Legacy API: manual handlers ===

    /// Handler to toggle open/closed state (called when trigger is clicked)
    on_toggle: ?HandlerRef = null,

    /// Handler to close the dropdown (called on click-outside). Shares the
    /// name and `?HandlerRef` type of `Modal.on_close` by design.
    on_close: ?HandlerRef = null,

    /// Array of handlers, one per option. Use cx.updateWith() to create these.
    /// Mutually exclusive with `on_select`; mixing both selection APIs traps
    /// during render instead of silently preferring this legacy field.
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

    /// Resolved open/close state + handlers (internal vs external).
    const ResolvedState = struct {
        is_open: bool,
        toggle_handler: ?HandlerRef,
        close_handler: ?HandlerRef,

        /// Fallback when Window context is unavailable (e.g. headless/test).
        fn disabled() ResolvedState {
            return .{
                .is_open = false,
                .toggle_handler = null,
                .close_handler = null,
            };
        }
    };

    /// Select either owns open/close state or delegates it to legacy manual
    /// fields. Exposed so callers can reason about compatibility explicitly.
    pub const ControlMode = enum {
        internal,
        manual,
    };

    pub const ControlError = error{
        MixedSelectionHandlers,
    };

    pub fn render(self: Select, cx: *ui.Cx) void {
        std.debug.assert(self.id.len > 0);
        std.debug.assert(self.options.len <= MAX_SELECT_OPTIONS);
        self.validateControl() catch {
            @panic("Select: on_select and legacy handlers are mutually exclusive");
        };

        const layout_id = LayoutId.fromString(self.id);
        const t = cx.theme();
        const font_size = self.font_size orelse t.font_size_base;
        std.debug.assert(font_size > 0);
        const resolved = self.resolveState(cx, layout_id);
        const colors = self.resolveColors(t, resolved.is_open);

        // Accessibility: combobox role
        const a11y_pushed = cx.accessible(.{
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
        defer if (a11y_pushed) cx.accessibleEnd();

        // Container: trigger + dropdown. Reuse the already-resolved
        // `layout_id` (PR 11b.2b) instead of re-hashing `self.id` through
        // `boxWithId` — `self.id` is a stateful, retained-by-id widget, so
        // the explicit id stays required, but it's hashed exactly once.
        cx.boxWithLayoutId(layout_id, .{
            .width = self.width,
        }, .{
            SelectTrigger{
                .text = self.getDisplayText(),
                .is_placeholder = self.selected == null,
                .is_open = resolved.is_open,
                .on_click = if (!self.disabled) resolved.toggle_handler else null,
                .background = colors.background,
                .hover_background = if (!self.disabled) colors.hover_bg else colors.background,
                .border_color = colors.current_border,
                .text_color = if (self.selected == null) colors.placeholder_col else colors.text_col,
                .font_size = font_size,
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
                .id_hash = if (self.controlMode() == .internal) layout_id.id else 0,
                .on_close = resolved.close_handler,
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
        });
    }

    /// Determine whether this Select uses widget-managed or manual open state.
    /// `on_select` with explicit toggle/close handlers remains supported as a
    /// manual-control compatibility path.
    pub fn controlMode(self: Select) ControlMode {
        std.debug.assert(self.id.len > 0);
        std.debug.assert(self.options.len <= MAX_SELECT_OPTIONS);
        const uses_internal_state = self.on_select != null and
            self.on_toggle == null and
            self.on_close == null and
            self.handlers == null;
        return if (uses_internal_state) .internal else .manual;
    }

    pub fn validateControl(self: Select) ControlError!void {
        std.debug.assert(self.id.len > 0);
        std.debug.assert(self.options.len <= MAX_SELECT_OPTIONS);
        if (self.on_select != null and self.handlers != null) {
            return error.MixedSelectionHandlers;
        }
    }

    /// Resolve open/close state and handlers — internal vs external.
    fn resolveState(self: Select, cx: *ui.Cx, layout_id: LayoutId) ResolvedState {
        // Legacy path: caller manages open/close externally
        if (self.controlMode() == .manual) {
            std.debug.assert(self.on_select != null or self.handlers != null or
                self.on_toggle == null);
            return .{
                .is_open = self.is_open,
                .toggle_handler = self.on_toggle,
                .close_handler = self.on_close,
            };
        }

        // Internal state path: read from `Window.element_states`
        // (PR 8.2 — was `g.widgets.getOrCreateSelectState(id_hash)`
        // pre-PR-8.2). The pool's miss-path allocation can fail under
        // OOM or capacity exhaustion; in either case fall back to the
        // disabled state so the trigger still renders, just without
        // toggle/close handlers wired up. Same recover-by-disable
        // shape the pre-PR-8.2 path had against the `?*SelectState`
        // null return.
        const g = cx.getGooey() orelse return ResolvedState.disabled();
        const id_hash = layout_id.id;
        std.debug.assert(id_hash != 0);
        const ss = g.element_states.withElementState(
            SelectState,
            @as(u64, id_hash),
            SelectState.defaultInit,
        ) catch return ResolvedState.disabled();

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

test "Select control mode distinguishes internal and compatibility paths" {
    // The canonical on_select-only shape owns open state. Supplying either
    // manual open-state handler deliberately retains legacy external control.
    const callback: OnSelectHandler = undefined;
    const handler: HandlerRef = undefined;
    const options = &.{"One"};

    try std.testing.expectEqual(Select.ControlMode.internal, (Select{
        .id = "internal",
        .options = options,
        .on_select = callback,
    }).controlMode());
    try std.testing.expectEqual(Select.ControlMode.manual, (Select{
        .id = "manual",
        .options = options,
        .on_select = callback,
        .on_toggle = handler,
    }).controlMode());
}

test "Select dropdown width is a floor rather than a fixed constraint" {
    // Goal: option content may widen the popup beyond the trigger width.
    // Methodology: inspect the exact sizing pair consumed by SelectDropdown.
    const sizing = resolveDropdownSizing(160);

    try std.testing.expectEqual(@as(?f32, null), sizing.width);
    try std.testing.expectEqual(@as(?f32, 160), sizing.min_width);
}

test "Select rejects mixed canonical and legacy selection handlers" {
    // Selection must have one source; this catches the formerly silent
    // `handlers`-wins precedence before event wiring can become ambiguous.
    const callback: OnSelectHandler = undefined;
    const handler: HandlerRef = undefined;
    const select = Select{
        .id = "invalid",
        .options = &.{"One"},
        .on_select = callback,
        .handlers = &.{handler},
    };

    try std.testing.expectError(error.MixedSelectionHandlers, select.validateControl());
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

        cx.box(.{
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
        });
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
        cx.box(.{
            .width = self.size,
            .height = self.size,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            Svg{ .path = icon_path, .size = self.size, .color = self.color },
        });
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
    selected: ?usize,
    // Legacy: explicit handler array (one per option)
    handlers: ?[]const HandlerRef,
    // New: index-based handler (generates per-option handlers internally)
    on_select: ?OnSelectHandler,
    /// LayoutId hash for internal state (0 = not using internal state)
    id_hash: u32,
    on_close: ?HandlerRef,
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

        cx.box(.{
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
            .on_click_outside_handler = self.on_close,
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

    pub fn render(self: SelectOptions, cx: *ui.Cx) void {
        std.debug.assert(self.options.len <= MAX_SELECT_OPTIONS);

        for (self.options, 0..) |label, i| {
            const handler: ?HandlerRef = self.resolveOptionHandler(i);
            // `self.selected` is the chosen index (?usize); this derives the
            // per-option boolean for the item at index `i`.
            const option_selected = if (self.selected) |sel| sel == i else false;

            cx.with(SelectOption{
                .label = label,
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

        cx.box(.{
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
            // Keep labels aligned with the trigger; the checkmark is a trailing accessory.
            ui.text(self.label, .{
                .color = self.text_color,
                .size = self.font_size,
            }),
            SelectCheckmark{
                .visible = self.selected,
                .color = self.checkmark_color,
            },
        });
    }
};

/// Checkmark indicator for selected option
const SelectCheckmark = struct {
    visible: bool,
    color: Color,

    pub fn render(self: SelectCheckmark, cx: *ui.Cx) void {
        if (self.visible) {
            cx.box(.{
                .width = 16,
                .height = 16,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                Svg{ .path = Icons.check, .size = 14, .color = self.color },
            });
        } else {
            // Empty space to maintain alignment
            cx.box(.{
                .width = 16,
                .height = 16,
            }, .{});
        }
    }
};
