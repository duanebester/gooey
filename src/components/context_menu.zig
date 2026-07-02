//! Context Menu Component
//!
//! A floating, cursor-anchored menu of action rows — the kind of menu you
//! get from a right-click. It is pure composition over primitives that
//! already ship today:
//!
//! - Positioning : `ui.Floating.contextMenu()` (viewport-anchored, clamped).
//! - Dismissal   : `on_click_outside_handler` (see `context/dispatch.zig`).
//! - A11y        : `menu` / `menuitem` roles (see `accessibility/types.zig`).
//! - Rendering   : a floating column of `Box` rows — no new layout or GPU work.
//!
//! `ContextMenu` is *controlled*, exactly like `Modal`: the application owns
//! `is_open` plus the cursor coordinates `x`/`y`, and supplies an `on_close`
//! handler. The framework decodes right/middle mouse buttons already
//! (`input/events.zig` → `MouseButton`), so an app opens the menu from its
//! `on_event` hook and closes it from `on_close` (click-outside) and Escape.
//!
//! Following the established convention (see `Modal.doDelete` in the modal
//! example), each item's action method also flips `is_open` back to false —
//! the activation handler performs the action *and* closes the menu.
//!
//! ## Usage
//!
//! ```zig
//! const State = struct {
//!     menu_open: bool = false,
//!     menu_x: f32 = 0,
//!     menu_y: f32 = 0,
//!
//!     pub fn closeMenu(self: *State) void {
//!         self.menu_open = false;
//!     }
//!
//!     pub fn cut(self: *State) void {
//!         // ... perform action ...
//!         self.menu_open = false; // activation closes the menu
//!     }
//! };
//!
//! // In render:
//! ContextMenu{
//!     .id = "editor-menu",
//!     .is_open = s.menu_open,
//!     .x = s.menu_x,
//!     .y = s.menu_y,
//!     .on_close = cx.update(State.closeMenu),
//!     .items = &.{
//!         .{ .label = "Cut",  .icon = gooey.Icons.close, .shortcut = "Ctrl+X", .on_select = cx.update(State.cut) },
//!         .{ .label = "Copy", .shortcut = "Ctrl+C", .on_select = cx.update(State.copy) },
//!         .{ .separator = true },
//!         .{ .label = "Delete", .danger = true, .on_select = cx.update(State.delete) },
//!     },
//! }
//!
//! // Open at the cursor on right mouse button:
//! fn onEvent(cx: *Cx, event: gooey.input.InputEvent) bool {
//!     if (event == .mouse_down and event.mouse_down.button == .right) {
//!         const p = event.mouse_down.position;
//!         state.menu_open = true;
//!         state.menu_x = @floatCast(p.x);
//!         state.menu_y = @floatCast(p.y);
//!         cx.notify();
//!         return true;
//!     }
//!     return false;
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

/// Hard cap on item count to keep the render loop bounded (CLAUDE.md §4).
/// A right-click menu with more than this many rows is a design smell long
/// before it is a performance problem; we fail fast rather than spin.
const MAX_CONTEXT_MENU_ITEMS: u32 = 256;

/// Lucide-icon viewbox the bundled icon paths are authored against. Lucide
/// icons are drawn on a 24x24 grid, so this stays fixed at 24.
const ICON_VIEWBOX: f32 = 24;

// =============================================================================
// Menu Item
// =============================================================================

/// A single row in a `ContextMenu`.
///
/// A row is either an action item (the default) or a decorative separator
/// (`separator = true`). Separators ignore every other field and are skipped
/// in the accessibility tree.
pub const MenuItem = struct {
    /// Visible label. Empty only for separators.
    label: []const u8 = "",

    /// Handler invoked when the row is activated. Per the controlled
    /// convention this method should also set the app's open flag to false.
    /// `null` renders a non-interactive row (e.g. a section header).
    ///
    /// Typed `?HandlerRef` (NOT `?OnSelectHandler`): a menu item triggers one
    /// fixed action and carries no index, unlike `select.Select.on_select`
    /// which is `?OnSelectHandler` so it can pass the chosen option index. The
    /// two fields deliberately share the `on_select` name but differ in type;
    /// unifying them is a deeper design change left out of the naming pass.
    on_select: ?HandlerRef = null,

    /// Optional leading icon as SVG markup (e.g. one of `gooey.Lucide`),
    /// rendered stroke-based to match the Lucide icon style.
    icon: ?[]const u8 = null,

    /// Optional trailing shortcut hint, right-aligned and muted (e.g. "Ctrl+C").
    /// Purely visual — wiring the actual accelerator is the app's job.
    shortcut: ?[]const u8 = null,

    /// Greys the row out and drops its click handler.
    disabled: bool = false,

    /// Destructive styling (danger color text), e.g. "Delete".
    danger: bool = false,

    /// Render a horizontal divider instead of an action row.
    separator: bool = false,
};

// =============================================================================
// Context Menu
// =============================================================================

/// A cursor-anchored floating menu. Controlled by the application (`is_open`,
/// `x`, `y`, `on_close`) in the same shape as `Modal`.
pub const ContextMenu = struct {
    /// Stable identifier — used for the layout id and a11y bounds correlation.
    id: []const u8 = "context-menu",

    /// Whether the menu is currently visible.
    is_open: bool = false,

    /// Cursor position in logical pixels (top-left of the menu, clamped on-screen).
    x: f32 = 0,
    y: f32 = 0,

    /// Rows to display, top to bottom.
    items: []const MenuItem,

    /// Fired on click-outside. Should set the app's open flag to false.
    on_close: ?HandlerRef = null,

    // === Layout ===

    /// Minimum menu width (most menus want a comfortable floor).
    min_width: f32 = 180,

    /// Maximum menu width (long labels wrap/clip rather than sprawl). null = unbounded.
    max_width: ?f32 = 360,

    /// Stacking order. Above dropdowns (100), below modals (1000) by default.
    z_index: i16 = 200,

    // === Styling (null = use theme) ===

    /// Menu surface background.
    background: ?Color = null,

    /// Row hover background.
    hover_background: ?Color = null,

    /// Surface border color.
    border_color: ?Color = null,

    /// Default label color.
    text_color: ?Color = null,

    /// Disabled label color.
    disabled_color: ?Color = null,

    /// Destructive label color.
    danger_color: ?Color = null,

    /// Shortcut hint color.
    shortcut_color: ?Color = null,

    /// Separator line color.
    separator_color: ?Color = null,

    /// Label font size (null = theme `font_size_base`).
    font_size: ?u16 = null,

    /// Surface corner radius (null = theme `radius_md`).
    corner_radius: ?f32 = null,

    /// Horizontal padding inside each row.
    item_padding_x: f32 = 12,

    /// Vertical padding inside each row.
    item_padding_y: f32 = 7,

    // === Accessibility overrides ===
    accessible_name: ?[]const u8 = null,
    accessible_description: ?[]const u8 = null,

    /// Resolved color/metric set, computed once and threaded into rows so the
    /// theme is looked up a single time per frame (mirrors `Select`).
    const Palette = struct {
        background: Color,
        hover: Color,
        border: Color,
        text: Color,
        disabled: Color,
        danger: Color,
        shortcut: Color,
        separator: Color,
        radius: f32,
        font_size: u16,
    };

    pub fn render(self: ContextMenu, cx: *ui.Cx) void {
        std.debug.assert(self.id.len > 0);
        std.debug.assert(self.items.len <= MAX_CONTEXT_MENU_ITEMS);

        // Closed menu renders nothing — no surface, no a11y node, no listeners.
        if (!self.is_open) return;

        const layout_id = cx.idFor(self.id);
        const palette = self.resolvePalette(cx.theme());

        // Count actionable rows up front for `set_size` (separators excluded).
        // ARIA's pos_in_set/set_size describe the menuitem set, not raw rows.
        const menuitem_count = countMenuItems(self.items);

        // Accessibility: the surface is the `menu`; rows are `menuitem`s.
        const a11y_pushed = cx.accessible(.{
            .layout_id = layout_id,
            .role = .menu,
            .name = self.accessible_name orelse self.id,
            .description = self.accessible_description,
            .state = .{ .expanded = true },
        });
        defer if (a11y_pushed) cx.accessibleEnd();

        cx.with(MenuSurface{
            .layout_id = layout_id,
            .x = self.x,
            .y = self.y,
            .z_index = self.z_index,
            .min_width = self.min_width,
            .max_width = self.max_width,
            .on_close = self.on_close,
            .items = self.items,
            .menuitem_count = menuitem_count,
            .palette = palette,
            .item_padding_x = self.item_padding_x,
            .item_padding_y = self.item_padding_y,
        });
    }

    fn resolvePalette(self: ContextMenu, t: *const Theme) Palette {
        std.debug.assert(self.min_width >= 0);
        std.debug.assert(self.item_padding_x >= 0);
        std.debug.assert(self.item_padding_y >= 0);
        const font_size = self.font_size orelse t.font_size_base;
        std.debug.assert(font_size > 0);
        return .{
            .background = self.background orelse t.surface,
            .hover = self.hover_background orelse t.overlay,
            .border = self.border_color orelse t.border,
            .text = self.text_color orelse t.text,
            .disabled = self.disabled_color orelse t.muted,
            .danger = self.danger_color orelse t.danger,
            .shortcut = self.shortcut_color orelse t.muted,
            .separator = self.separator_color orelse t.border,
            .radius = self.corner_radius orelse t.radius_md,
            .font_size = font_size,
        };
    }
};

/// Count actionable (non-separator) rows. Pulled out as a primitive-only leaf
/// so the bound is obvious and the parent stays readable (CLAUDE.md §20).
fn countMenuItems(items: []const MenuItem) u16 {
    std.debug.assert(items.len <= MAX_CONTEXT_MENU_ITEMS);
    var count: u16 = 0;
    for (items) |item| {
        if (!item.separator) count += 1;
    }
    // Actionable rows are a subset of all rows.
    std.debug.assert(count <= items.len);
    return count;
}

// =============================================================================
// Sub-components
// =============================================================================

/// The floating surface: a viewport-anchored column of rows with a shadow.
const MenuSurface = struct {
    layout_id: LayoutId,
    x: f32,
    y: f32,
    z_index: i16,
    min_width: f32,
    max_width: ?f32,
    on_close: ?HandlerRef,
    items: []const MenuItem,
    menuitem_count: u16,
    palette: ContextMenu.Palette,
    item_padding_x: f32,
    item_padding_y: f32,

    pub fn render(self: MenuSurface, cx: *ui.Cx) void {
        std.debug.assert(self.items.len <= MAX_CONTEXT_MENU_ITEMS);
        std.debug.assert(self.min_width >= 0);

        // Anchor the cursor-positioned preset at (x, y). Building from the
        // preset keeps the "context menu" intent in one place (`ui/styles.zig`).
        var floating = ui.Floating.contextMenu();
        floating.offset_x = self.x;
        floating.offset_y = self.y;
        floating.z_index = self.z_index;

        cx.boxWithLayoutId(self.layout_id, .{
            .min_width = self.min_width,
            .max_width = self.max_width,
            .padding = .{ .all = 4 },
            .background = self.palette.background,
            .border_color = self.palette.border,
            .border_width = .{ .all = 1 },
            .corner_radius = self.palette.radius,
            .direction = .column,
            .gap = 2,
            .shadow = .{
                .blur_radius = 16,
                .offset_y = 6,
                .color = Color.rgba(0, 0, 0, 0.18),
            },
            .floating = floating,
            .on_click_outside_handler = self.on_close,
        }, .{
            MenuRows{
                .items = self.items,
                .menuitem_count = self.menuitem_count,
                .palette = self.palette,
                .item_padding_x = self.item_padding_x,
                .item_padding_y = self.item_padding_y,
            },
        });
    }
};

/// Expands the item slice into rows, tracking ARIA position as it goes.
const MenuRows = struct {
    items: []const MenuItem,
    menuitem_count: u16,
    palette: ContextMenu.Palette,
    item_padding_x: f32,
    item_padding_y: f32,

    pub fn render(self: MenuRows, cx: *ui.Cx) void {
        std.debug.assert(self.items.len <= MAX_CONTEXT_MENU_ITEMS);

        // 1-based position within the menuitem set (ARIA convention). Only
        // advances for actionable rows so separators don't perturb the count.
        var pos_in_set: u16 = 0;
        for (self.items) |item| {
            if (!item.separator) pos_in_set += 1;
            cx.with(MenuRow{
                .item = item,
                .pos_in_set = pos_in_set,
                .set_size = self.menuitem_count,
                .palette = self.palette,
                .item_padding_x = self.item_padding_x,
                .item_padding_y = self.item_padding_y,
            });
        }
    }
};

/// A single rendered row — separator or action.
const MenuRow = struct {
    item: MenuItem,
    pos_in_set: u16,
    set_size: u16,
    palette: ContextMenu.Palette,
    item_padding_x: f32,
    item_padding_y: f32,

    pub fn render(self: MenuRow, cx: *ui.Cx) void {
        // ARIA position is 1-based and never exceeds the set size. A
        // separator carries the running position of the row above it, so the
        // lower bound only holds for actionable rows.
        std.debug.assert(self.pos_in_set <= self.set_size);
        if (!self.item.separator) std.debug.assert(self.pos_in_set >= 1);

        // Separator: a thin divider, hidden from the a11y tree.
        if (self.item.separator) {
            cx.box(.{
                .fill_width = true,
                .height = 1,
                .background = self.palette.separator,
            }, .{});
            return;
        }

        // Action row. Interactivity collapses to null when disabled or when no
        // handler was supplied, so a disabled/header row neither hovers nor clicks.
        const interactive = !self.item.disabled and self.item.on_select != null;
        const label_color = if (self.item.disabled)
            self.palette.disabled
        else if (self.item.danger)
            self.palette.danger
        else
            self.palette.text;

        const a11y_pushed = cx.accessible(.{
            .role = .menuitem,
            .name = self.item.label,
            .state = .{ .disabled = self.item.disabled },
            .pos_in_set = self.pos_in_set,
            .set_size = self.set_size,
        });
        defer if (a11y_pushed) cx.accessibleEnd();

        cx.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = self.item_padding_x, .y = self.item_padding_y } },
            .background = Color.transparent,
            .hover_background = if (interactive) self.palette.hover else Color.transparent,
            .corner_radius = @max(0, self.palette.radius - 2),
            .direction = .row,
            .alignment = .{ .main = .space_between, .cross = .center },
            .gap = 16,
            .on_click_handler = if (interactive) self.item.on_select else null,
        }, .{
            MenuRowLabel{
                .label = self.item.label,
                .icon = self.item.icon,
                .color = label_color,
                .font_size = self.palette.font_size,
            },
            MenuRowShortcut{
                .shortcut = self.item.shortcut,
                .color = self.palette.shortcut,
                .font_size = self.palette.font_size,
            },
        });
    }
};

/// Leading icon (optional) + label, grouped so they stay together on the left.
const MenuRowLabel = struct {
    label: []const u8,
    icon: ?[]const u8,
    color: Color,
    font_size: u16,

    pub fn render(self: MenuRowLabel, cx: *ui.Cx) void {
        std.debug.assert(self.font_size > 0);
        const icon_size: f32 = @floatFromInt(self.font_size);
        cx.box(.{
            .direction = .row,
            .alignment = .{ .cross = .center },
            .gap = 8,
        }, .{
            MenuRowIcon{ .path = self.icon, .size = icon_size, .color = self.color },
            ui.text(self.label, .{ .color = self.color, .size = self.font_size }),
        });
    }
};

/// Renders the leading icon, or nothing when the row has no icon.
const MenuRowIcon = struct {
    path: ?[]const u8,
    size: f32,
    color: Color,

    pub fn render(self: MenuRowIcon, cx: *ui.Cx) void {
        std.debug.assert(self.size > 0);
        const path = self.path orelse return;
        cx.box(.{
            .width = self.size,
            .height = self.size,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            Svg{ .path = path, .size = self.size, .no_fill = true, .stroke_color = self.color, .stroke_width = 1.5, .viewbox = ICON_VIEWBOX },
        });
    }
};

/// Trailing shortcut hint, or nothing when the row has no shortcut.
const MenuRowShortcut = struct {
    shortcut: ?[]const u8,
    color: Color,
    font_size: u16,

    pub fn render(self: MenuRowShortcut, cx: *ui.Cx) void {
        std.debug.assert(self.font_size > 0);
        const shortcut = self.shortcut orelse return;
        // One size step down keeps the hint subordinate to the label.
        const hint_size: u16 = if (self.font_size > 2) self.font_size - 2 else self.font_size;
        // `ui.text` is a primitive, not a component — route it through
        // `render`/`processChildren` rather than `with` (which expects a
        // struct exposing a `render` method).
        cx.render(ui.text(shortcut, .{ .color = self.color, .size = hint_size }));
    }
};
