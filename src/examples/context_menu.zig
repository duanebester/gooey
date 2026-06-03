//! Context Menu Component Demo
//!
//! Right-click (or middle-click) inside the canvas panel to open a
//! cursor-anchored menu. Pick an item to run an action, click outside to
//! dismiss, or press Escape.
//!
//! Shows the controlled pattern: the app owns `is_open` + the cursor
//! coordinates, opens the menu from its `on_event` hook on the right mouse
//! button, and each action method closes the menu (mirrors the Modal demo).
//!
//! The right-click is *scoped to the panel*: `on_event` is a window-wide
//! hook, so the handler hit-tests the cursor against the panel (by hover)
//! before opening — clicks on the header or status row are ignored.

const gooey = @import("gooey");
const std = @import("std");

/// WASM-compatible logging - redirect std.log to console.log via JS imports
pub const std_options = gooey.std_options;
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;

const ContextMenu = gooey.components.ContextMenu;
const Lucide = gooey.components.Lucide;

/// Stable layout id for the right-clickable panel. `Canvas.render` stamps it
/// onto the box and `onEvent` hashes the same string to hit-test the cursor,
/// so both sides agree on which element is the menu's trigger area.
const CANVAS_ID = "context-canvas";

// =============================================================================
// State
// =============================================================================

const AppState = struct {
    // Menu open/position state (controlled by the app).
    menu_open: bool = false,
    menu_x: f32 = 0,
    menu_y: f32 = 0,

    // Last action taken, for the status line.
    last_action: []const u8 = "(right-click the panel)",

    pub fn closeMenu(self: *AppState) void {
        self.menu_open = false;
    }

    // Each action performs its work AND closes the menu, the same convention
    // the Modal demo uses (see `AppState.doDelete` there).
    pub fn doCut(self: *AppState) void {
        self.last_action = "Cut";
        self.menu_open = false;
    }

    pub fn doCopy(self: *AppState) void {
        self.last_action = "Copy";
        self.menu_open = false;
    }

    pub fn doPaste(self: *AppState) void {
        self.last_action = "Paste";
        self.menu_open = false;
    }

    pub fn doRename(self: *AppState) void {
        self.last_action = "Rename";
        self.menu_open = false;
    }

    pub fn doDelete(self: *AppState) void {
        self.last_action = "Delete";
        self.menu_open = false;
    }

    /// Open the menu at a cursor position. Called from `onEvent`.
    pub fn openAt(self: *AppState, x: f32, y: f32) void {
        self.menu_x = x;
        self.menu_y = y;
        self.menu_open = true;
    }
};

var state = AppState{};

// =============================================================================
// Entry Points
// =============================================================================

const App = gooey.App(AppState, &state, render, .{
    .title = "Context Menu Demo",
    .width = 720,
    .height = 520,
    .on_event = onEvent,
});

comptime {
    _ = App;
}

pub fn main(init: std.process.Init) !void {
    if (platform.is_wasm) unreachable;
    return App.main(init);
}

// =============================================================================
// Render
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();
    const s = cx.state(AppState);

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = ui.Color.rgb(0.95, 0.95, 0.95),
        .direction = .column,
        .padding = .{ .all = 24 },
        .gap = 16,
    }, .{
        Header{},
        StatusRow{ .action = s.last_action },
        Canvas{},

        // The menu itself. Renders nothing while closed.
        ContextMenu{
            .id = "demo-menu",
            .is_open = s.menu_open,
            .x = s.menu_x,
            .y = s.menu_y,
            .on_close = cx.update(AppState.closeMenu),
            .items = &.{
                .{ .label = "Cut", .icon = Lucide.scissors, .shortcut = "Ctrl+X", .on_select = cx.update(AppState.doCut) },
                .{ .label = "Copy", .icon = Lucide.copy, .shortcut = "Ctrl+C", .on_select = cx.update(AppState.doCopy) },
                .{ .label = "Paste", .icon = Lucide.clipboard_paste, .shortcut = "Ctrl+V", .disabled = true },
                .{ .separator = true },
                .{ .label = "Rename", .icon = Lucide.pencil, .on_select = cx.update(AppState.doRename) },
                .{ .separator = true },
                .{ .label = "Delete", .icon = Lucide.trash_2, .danger = true, .on_select = cx.update(AppState.doDelete) },
            },
        },
    }));
}

// =============================================================================
// Components
// =============================================================================

const Header = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 20 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .column,
            .gap = 8,
        }, .{
            ui.text("Context Menu Demo", .{ .size = 24 }),
            ui.text("Right-click (or middle-click) the panel below. Click outside or press Escape to dismiss.", .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.5),
                .wrap = .words,
            }),
        }));
    }
};

const StatusRow = struct {
    action: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 16 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .row,
            .gap = 8,
        }, .{
            ui.text("Last action:", .{ .size = 14, .color = ui.Color.rgb(0.5, 0.5, 0.5) }),
            ui.text(self.action, .{ .size = 14, .color = ui.Color.rgb(0.2, 0.2, 0.2) }),
        }));
    }
};

const Canvas = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        // Stamp the panel with an explicit layout id so `onEvent` can hit-test
        // right-clicks against exactly this box. `cx.idFor(CANVAS_ID)` hashes
        // the string the same way the handler does, so the ids match.
        cx.boxWithLayoutId(cx.idFor(CANVAS_ID), .{
            .fill_width = true,
            .grow_height = true,
            .background = ui.Color.white,
            .corner_radius = 8,
            .border_color = ui.Color.rgb(0.85, 0.85, 0.85),
            .border_width = .{ .all = 1 },
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.text("Right-click anywhere in this panel", .{
                .size = 16,
                .color = ui.Color.rgb(0.6, 0.6, 0.6),
            }),
        });
    }
};

// =============================================================================
// Event Handling
// =============================================================================

fn onEvent(cx: *Cx, event: gooey.input.InputEvent) bool {
    const s = cx.state(AppState);

    // Right (or middle) mouse button opens the menu at the cursor, but only
    // when the click lands inside the canvas panel. `on_event` is window-wide,
    // so we hit-test the cursor against the panel before opening. We gate on
    // hover rather than re-deriving the panel's (flexible) rect: by mouse-down
    // time the framework has already resolved the topmost element under the
    // cursor from the preceding mouse-move, and `isHoveredOrDescendant` is
    // true when the panel itself OR any of its children is that element.
    // Right-clicks on the header or status row fall through to `return false`.
    if (event == .mouse_down) {
        const m = event.mouse_down;
        if (m.button == .right or m.button == .middle) {
            const canvas_id = cx.idFor(CANVAS_ID).id;
            if (cx.window().isHoveredOrDescendant(canvas_id)) {
                s.openAt(@floatCast(m.position.x), @floatCast(m.position.y));
                cx.notify();
                return true;
            }
        }
    }

    // Escape dismisses the menu (parity with the Modal demo).
    if (event == .key_down) {
        if (event.key_down.key == .escape and s.menu_open) {
            s.closeMenu();
            cx.notify();
            return true;
        }
    }

    return false;
}
