//! Layout System Demo - Minimal Floating Example
//!
//! Simplified to debug floating dropdown behavior

const std = @import("std");
const builtin = @import("builtin");
const gooey = @import("gooey");

/// WASM-compatible logging - redirect std.log to console.log via JS imports
pub const std_options: std.Options = if (builtin.os.tag == .freestanding)
    .{ .logFn = gooey.wasmLogFn }
else
    .{};
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;

const Button = gooey.Button;

// =============================================================================
// State
// =============================================================================

const AppState = struct {
    show_dropdown: bool = false,

    pub fn toggleDropdown(self: *AppState) void {
        self.show_dropdown = !self.show_dropdown;
    }

    pub fn closeDropdown(self: *AppState) void {
        self.show_dropdown = false;
    }
};

var state = AppState{};

// =============================================================================
// Entry Points
// =============================================================================

// For WASM: WebApp with @export; For Native: struct with main()
const App = gooey.App(AppState, &state, render, .{
    .title = "Floating Dropdown Test",
    .width = 600,
    .height = 400,
    .on_event = onEvent,
});

// Force type analysis - triggers @export on WASM
comptime {
    _ = App;
}

// Native entry point
pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// =============================================================================
// Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = ui.Color.rgb(0.95, 0.95, 0.95),
        .direction = .column,
        .padding = .{ .all = 20 },
        .gap = 20,
    }, .{
        Header{},
        ContentArea{},
    }));
}

// =============================================================================
// Components
// =============================================================================

const Header = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 16 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .row,
            .alignment = .{ .main = .space_between, .cross = .center },
        }, .{
            ui.text("Floating Dropdown Test", .{ .size = 24 }),
            DropdownTrigger{},
        }));
    }
};

const DropdownTrigger = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        // The button acts as the anchor for the floating menu
        cx.render(ui.box(.{}, .{
            Button{
                .label = if (s.show_dropdown) "Close ▲" else "Menu ▼",
                .on_click_handler = cx.update(AppState, AppState.toggleDropdown),
            },
            DropdownMenu{},
        }));
    }
};

const DropdownMenu = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        if (!s.show_dropdown) return;

        cx.render(ui.box(.{
            .width = 160,
            .padding = .{ .all = 8 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .column,
            .gap = 2,
            .shadow = .{ .blur_radius = 12, .offset_y = 4, .color = ui.Color.rgba(0, 0, 0, 0.15) },
            .floating = ui.Floating.dropdown(),
            .on_click_outside_handler = cx.update(AppState, AppState.closeDropdown),
        }, .{
            MenuItem{ .label = "Profile" },
            MenuItem{ .label = "Settings" },
            MenuItem{ .label = "Help" },
            MenuDivider{},
            MenuItem{ .label = "Logout" },
        }));
    }
};

const MenuItem = struct {
    label: []const u8,

    pub fn render(self: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .corner_radius = 4,
            .background = ui.Color.white,
            .hover_background = ui.Color.rgb(0.95, 0.95, 0.95),
        }, .{
            ui.text(self.label, .{ .size = 14, .color = ui.Color.rgb(0.2, 0.2, 0.2) }),
        });
    }
};

const MenuDivider = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .height = 1,
            .background = ui.Color.rgb(0.9, 0.9, 0.9),
        }, .{});
    }
};

const ContentArea = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .grow = true,
            .padding = .{ .all = 20 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .column,
            .gap = 16,
        }, .{
            ui.text("Content Area", .{ .size = 20 }),
            ui.text("Click the Menu button above to toggle the dropdown.", .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.5),
            }),
            ui.text("The dropdown should:", .{ .size = 14, .color = ui.Color.rgb(0.3, 0.3, 0.3) }),
            BulletPoint{ .text = "Appear below the button" },
            BulletPoint{ .text = "Have a white background" },
            BulletPoint{ .text = "Show a subtle shadow" },
            BulletPoint{ .text = "Not gray out other content" },
            BulletPoint{ .text = "Close when clicking outside" },
            BulletPoint{ .text = "Close with Escape key" },
        });
    }
};

const BulletPoint = struct {
    text: []const u8,

    pub fn render(self: @This(), b: *ui.Builder) void {
        b.box(.{
            .direction = .row,
            .gap = 8,
        }, .{
            ui.text("•", .{ .size = 14, .color = ui.Color.rgb(0.4, 0.4, 0.4) }),
            ui.text(self.text, .{ .size = 14, .color = ui.Color.rgb(0.4, 0.4, 0.4) }),
        });
    }
};

// =============================================================================
// Event Handling
// =============================================================================

fn onEvent(cx: *Cx, event: gooey.InputEvent) bool {
    if (event == .key_down) {
        const key = event.key_down;
        const s = cx.state(AppState);
        if (key.key == .escape and s.show_dropdown) {
            state.show_dropdown = false;
            return true;
        }
    }
    return false;
}
