//! Modal Component Demo
//!
//! Demonstrates the Modal component with various configurations.

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;

const Button = gooey.Button;
const Modal = gooey.Modal;

// =============================================================================
// State
// =============================================================================

const AppState = struct {
    // Basic modal
    show_basic: bool = false,

    // Confirm modal
    show_confirm: bool = false,
    delete_count: u32 = 0,

    // Custom styled modal
    show_custom: bool = false,

    // Basic modal handlers
    pub fn openBasic(self: *AppState) void {
        self.show_basic = true;
    }

    pub fn closeBasic(self: *AppState) void {
        self.show_basic = false;
    }

    // Confirm modal handlers
    pub fn openConfirm(self: *AppState) void {
        self.show_confirm = true;
    }

    pub fn closeConfirm(self: *AppState) void {
        self.show_confirm = false;
    }

    pub fn doDelete(self: *AppState) void {
        self.delete_count += 1;
        self.show_confirm = false;
    }

    // Custom modal handlers
    pub fn openCustom(self: *AppState) void {
        self.show_custom = true;
    }

    pub fn closeCustom(self: *AppState) void {
        self.show_custom = false;
    }
};

var state = AppState{};

// =============================================================================
// Entry Points
// =============================================================================

const App = gooey.App(AppState, &state, render, .{
    .title = "Modal Component Demo",
    .width = 700,
    .height = 500,
    .on_event = onEvent,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// =============================================================================
// Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();
    const s = cx.state(AppState);

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = ui.Color.rgb(0.95, 0.95, 0.95),
        .direction = .column,
        .padding = .{ .all = 30 },
        .gap = 24,
    }, .{
        Header{},
        ButtonRow{},
        StatusRow{ .delete_count = s.delete_count },

        // Basic Modal
        Modal(BasicModalContent){
            .id = "basic-modal",
            .is_open = s.show_basic,
            .on_close = cx.update(AppState, AppState.closeBasic),
            .child = BasicModalContent{},
        },

        // Confirm Modal
        Modal(ConfirmModalContent){
            .id = "confirm-modal",
            .is_open = s.show_confirm,
            .on_close = cx.update(AppState, AppState.closeConfirm),
            .child = ConfirmModalContent{},
        },

        // Custom Styled Modal
        Modal(CustomModalContent){
            .id = "custom-modal",
            .is_open = s.show_custom,
            .on_close = cx.update(AppState, AppState.closeCustom),
            .child = CustomModalContent{},
            .backdrop_color = ui.Color.rgba(0.1, 0.1, 0.2, 0.7),
            .content_max_width = 400,
            .content_background = ui.Color.rgb(0.15, 0.15, 0.2),
            .content_corner_radius = 16,
        },
    }));
}

// =============================================================================
// Components
// =============================================================================

const Header = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .padding = .{ .all = 20 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .column,
            .gap = 8,
        }, .{
            ui.text("Modal Component Demo", .{ .size = 24 }),
            ui.text("Click a button to open a modal. Click the backdrop or press Escape to close.", .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.5),
                .wrap = .words,
            }),
        });
    }
};

const ButtonRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 20 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .row,
            .gap = 16,
            .alignment = .{ .main = .center },
        }, .{
            Button{
                .label = "Basic Modal",
                .variant = .primary,
                .on_click_handler = cx.update(AppState, AppState.openBasic),
            },
            Button{
                .label = "Confirm Delete",
                .variant = .danger,
                .on_click_handler = cx.update(AppState, AppState.openConfirm),
            },
            Button{
                .label = "Custom Style",
                .variant = .secondary,
                .on_click_handler = cx.update(AppState, AppState.openCustom),
            },
        }));
    }
};

const StatusRow = struct {
    delete_count: u32,

    pub fn render(self: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .padding = .{ .all = 16 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .row,
            .gap = 8,
        }, .{
            ui.text("Items deleted:", .{ .size = 14, .color = ui.Color.rgb(0.5, 0.5, 0.5) }),
            ui.textFmt("{d}", .{self.delete_count}, .{ .size = 14 }),
        });
    }
};

const BasicModalContent = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .direction = .column,
            .gap = 16,
            .fill_width = true,
        }, .{
            ui.text("Welcome!", .{ .size = 20 }),
            ui.text("This is a basic modal dialog. Click outside or press Escape to close.", .{
                .size = 14,
                .color = ui.Color.rgb(0.4, 0.4, 0.4),
                .wrap = .words,
            }),
            Button{
                .label = "Got it",
                .variant = .primary,
                .on_click_handler = cx.update(AppState, AppState.closeBasic),
            },
        }));
    }
};

const ConfirmModalContent = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .direction = .column,
            .gap = 20,
            .fill_width = true,
        }, .{
            ui.text("Confirm Delete", .{ .size = 20 }),
            ui.text("Are you sure you want to delete this item? This action cannot be undone.", .{
                .size = 14,
                .color = ui.Color.rgb(0.4, 0.4, 0.4),
                .wrap = .words,
            }),
            ActionButtons{},
        }));
    }
};

const ActionButtons = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .direction = .row,
            .gap = 12,
            .alignment = .{ .main = .end },
            .fill_width = true,
        }, .{
            Button{
                .label = "Cancel",
                .variant = .secondary,
                .on_click_handler = cx.update(AppState, AppState.closeConfirm),
            },
            Button{
                .label = "Delete",
                .variant = .danger,
                .on_click_handler = cx.update(AppState, AppState.doDelete),
            },
        }));
    }
};

const CustomModalContent = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .direction = .column,
            .gap = 16,
            .alignment = .{ .cross = .center },
            .fill_width = true,
        }, .{
            ui.text("Dark Theme Modal", .{ .size = 22, .color = ui.Color.white }),
            ui.text("Custom styled modal with dark theme.", .{
                .size = 14,
                .color = ui.Color.rgb(0.7, 0.7, 0.8),
                .wrap = .words,
            }),
            Button{
                .label = "Close",
                .variant = .primary,
                .on_click_handler = cx.update(AppState, AppState.closeCustom),
            },
        }));
    }
};

// =============================================================================
// Event Handling
// =============================================================================

fn onEvent(cx: *Cx, event: gooey.InputEvent) bool {
    if (event == .key_down) {
        const key = event.key_down;
        const s = cx.state(AppState);

        // Escape closes modals (in reverse order of opening)
        if (key.key == .escape) {
            if (s.show_custom) {
                state.closeCustom();
                return true;
            }
            if (s.show_confirm) {
                state.closeConfirm();
                return true;
            }
            if (s.show_basic) {
                state.closeBasic();
                return true;
            }
        }
    }
    return false;
}
