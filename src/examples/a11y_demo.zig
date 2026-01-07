//! Accessibility Demo - VoiceOver Integration
//!
//! Demonstrates Gooey's accessibility features:
//! - Accessible elements with semantic roles
//! - VoiceOver announcements (polite and assertive)
//! - Focus tracking for screen readers
//! - State changes (checked, disabled)
//!
//! To test with VoiceOver on macOS:
//! 1. Enable VoiceOver: Cmd+F5 (or System Settings > Accessibility > VoiceOver)
//! 2. Run this example
//! 3. Navigate with Tab/Arrow keys while VoiceOver reads the UI

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    count: i32 = 0,
    notifications_enabled: bool = true,
    dark_mode: bool = false,
    status_message: []const u8 = "Ready",
    last_action: []const u8 = "No actions yet",

    pub fn increment(self: *AppState) void {
        self.count += 1;
        self.last_action = "Incremented counter";
    }

    pub fn decrement(self: *AppState) void {
        self.count -= 1;
        self.last_action = "Decremented counter";
    }

    pub fn toggleNotifications(self: *AppState) void {
        self.notifications_enabled = !self.notifications_enabled;
        self.last_action = if (self.notifications_enabled)
            "Notifications enabled"
        else
            "Notifications disabled";
    }

    pub fn toggleDarkMode(self: *AppState) void {
        self.dark_mode = !self.dark_mode;
        self.last_action = if (self.dark_mode)
            "Dark mode enabled"
        else
            "Dark mode disabled";
    }

    pub fn simulateError(self: *AppState) void {
        self.status_message = "Error: Connection failed!";
        self.last_action = "Simulated error";
    }

    pub fn clearError(self: *AppState) void {
        self.status_message = "Ready";
        self.last_action = "Cleared status";
    }
};

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Accessibility Demo - VoiceOver",
    .width = 500,
    .height = 600,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// =============================================================================
// Main Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    const size = cx.windowSize();
    const b = cx.builder();
    const g = b.gooey orelse return;

    // Announce errors assertively (live region behavior)
    if (std.mem.indexOf(u8, s.status_message, "Error") != null) {
        g.announce(s.status_message, .assertive);
    }

    const bg_color = if (s.dark_mode)
        ui.Color.rgb(0.15, 0.15, 0.15)
    else
        ui.Color.rgb(0.95, 0.95, 0.95);

    const text_color = if (s.dark_mode)
        ui.Color.rgb(0.9, 0.9, 0.9)
    else
        ui.Color.rgb(0.2, 0.2, 0.2);

    cx.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 24 },
        .gap = 20,
        .direction = .column,
        .background = bg_color,
    }, .{
        // Header
        HeaderSection{ .text_color = text_color },

        // A11y status
        A11yStatusSection{ .text_color = text_color },

        // Counter demo
        CounterSection{ .count = s.count, .text_color = text_color, .dark_mode = s.dark_mode },

        // Toggles
        ToggleSection{
            .notifications = s.notifications_enabled,
            .dark_mode = s.dark_mode,
            .text_color = text_color,
        },

        // Status section
        StatusSection{
            .message = s.status_message,
            .dark_mode = s.dark_mode,
        },

        // Action log
        ActionLogSection{ .action = s.last_action, .text_color = text_color },
    });
}

// =============================================================================
// Components
// =============================================================================

const HeaderSection = struct {
    text_color: ui.Color,

    pub fn render(self: @This(), cx: *Cx) void {
        const b = cx.builder();

        // Accessible heading
        if (b.accessible(.{
            .role = .heading,
            .name = "Accessibility Demo",
            .heading_level = .h1,
        })) {
            defer b.accessibleEnd();
        }

        cx.vstack(.{ .gap = 4 }, .{
            ui.text("Accessibility Demo", .{
                .size = 28,
                .color = self.text_color,
                .weight = .bold,
            }),
            ui.text("Testing VoiceOver integration with Gooey", .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.5),
            }),
        });
    }
};

const A11yStatusSection = struct {
    text_color: ui.Color,

    pub fn render(self: @This(), cx: *Cx) void {
        const b = cx.builder();
        const g = b.gooey orelse return;
        const is_enabled = g.isA11yEnabled();

        const status_color = if (is_enabled)
            ui.Color.rgb(0.2, 0.7, 0.3)
        else
            ui.Color.rgb(0.6, 0.6, 0.6);

        // Accessible status region
        if (b.accessible(.{
            .role = .status,
            .name = if (is_enabled) "VoiceOver detected" else "VoiceOver not detected",
            .live = .polite,
        })) {
            defer b.accessibleEnd();
        }

        cx.hstack(.{ .gap = 8, .alignment = .center }, .{
            cx.box(.{
                .width = 12,
                .height = 12,
                .corner_radius = 6,
                .background = status_color,
            }, .{}),
            ui.text(
                if (is_enabled) "VoiceOver Active" else "VoiceOver Not Detected",
                .{ .size = 12, .color = self.text_color },
            ),
        });
    }
};

const CounterSection = struct {
    count: i32,
    text_color: ui.Color,
    dark_mode: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const b = cx.builder();

        // Accessible group
        if (b.accessible(.{
            .role = .group,
            .name = "Counter controls",
        })) {
            defer b.accessibleEnd();
        }

        cx.box(.{
            .padding = .{ .all = 16 },
            .gap = 12,
            .background = if (self.dark_mode)
                ui.Color.rgb(0.2, 0.2, 0.2)
            else
                ui.Color.white,
            .corner_radius = 8,
        }, .{
            ui.text("Counter Demo", .{
                .size = 16,
                .color = self.text_color,
                .weight = .semibold,
            }),

            cx.hstack(.{ .gap = 16, .alignment = .center }, .{
                // Decrement button - Button has built-in a11y
                Button{
                    .label = "−",
                    .accessible_name = "Decrease counter",
                    .on_click_handler = cx.update(AppState, AppState.decrement),
                },
                // Counter value
                ui.textFmt("{d}", .{self.count}, .{
                    .size = 32,
                    .color = if (self.count >= 0)
                        ui.Color.rgb(0.2, 0.5, 0.8)
                    else
                        ui.Color.rgb(0.8, 0.3, 0.3),
                }),
                // Increment button - Button has built-in a11y
                Button{
                    .label = "+",
                    .accessible_name = "Increase counter",
                    .on_click_handler = cx.update(AppState, AppState.increment),
                },
            }),
        });
    }
};

const ToggleSection = struct {
    notifications: bool,
    dark_mode: bool,
    text_color: ui.Color,

    pub fn render(self: @This(), cx: *Cx) void {
        const b = cx.builder();

        // Accessible group
        if (b.accessible(.{
            .role = .group,
            .name = "Toggle settings",
        })) {
            defer b.accessibleEnd();
        }

        cx.box(.{
            .padding = .{ .all = 16 },
            .gap = 12,
            .background = if (self.dark_mode)
                ui.Color.rgb(0.2, 0.2, 0.2)
            else
                ui.Color.white,
            .corner_radius = 8,
        }, .{
            ui.text("Toggle Settings", .{
                .size = 16,
                .color = self.text_color,
                .weight = .semibold,
            }),

            cx.hstack(.{ .gap = 12 }, .{
                // Notifications toggle - Checkbox has built-in a11y
                gooey.Checkbox{
                    .id = "notifications",
                    .checked = self.notifications,
                    .label = if (self.notifications) "Notifications On" else "Notifications Off",
                    .accessible_name = "Enable Notifications",
                    .on_click_handler = cx.update(AppState, AppState.toggleNotifications),
                },
                // Dark mode toggle - Checkbox has built-in a11y
                gooey.Checkbox{
                    .id = "dark_mode",
                    .checked = self.dark_mode,
                    .label = if (self.dark_mode) "Dark Mode On" else "Dark Mode Off",
                    .accessible_name = "Dark Mode",
                    .on_click_handler = cx.update(AppState, AppState.toggleDarkMode),
                },
            }),
        });
    }
};

const StatusSection = struct {
    message: []const u8,
    dark_mode: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const is_error = std.mem.indexOf(u8, self.message, "Error") != null;

        const bg_color = if (is_error)
            ui.Color.rgb(0.9, 0.3, 0.3)
        else if (self.dark_mode)
            ui.Color.rgb(0.2, 0.4, 0.2)
        else
            ui.Color.rgb(0.85, 0.95, 0.85);

        const text_color = if (is_error)
            ui.Color.white
        else if (self.dark_mode)
            ui.Color.rgb(0.9, 0.9, 0.9)
        else
            ui.Color.rgb(0.1, 0.4, 0.1);

        const b = cx.builder();

        // Live region - announced when content changes
        if (b.accessible(.{
            .role = if (is_error) .alert else .status,
            .name = self.message,
            .live = if (is_error) .assertive else .polite,
        })) {
            defer b.accessibleEnd();
        }

        cx.box(.{
            .padding = .{ .all = 12 },
            .background = bg_color,
            .corner_radius = 8,
        }, .{
            cx.hstack(.{ .gap = 12, .alignment = .center }, .{
                ui.text(if (is_error) "⚠" else "✓", .{ .size = 16, .color = text_color }),
                ui.text(self.message, .{ .size = 14, .color = text_color }),
                ui.spacerMin(20),
                ui.when(is_error, .{
                    Button{
                        .label = "Dismiss",
                        .size = .small,
                        .variant = .secondary,
                        .on_click_handler = cx.update(AppState, AppState.clearError),
                    },
                }),
                ui.when(!is_error, .{
                    Button{
                        .label = "Test Error",
                        .size = .small,
                        .variant = .danger,
                        .on_click_handler = cx.update(AppState, AppState.simulateError),
                    },
                }),
            }),
        });
    }
};

const ActionLogSection = struct {
    action: []const u8,
    text_color: ui.Color,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.hstack(.{ .gap = 4 }, .{
            ui.text("Last action: ", .{ .size = 12, .color = ui.Color.rgb(0.5, 0.5, 0.5) }),
            ui.text(self.action, .{ .size = 12, .color = self.text_color }),
        });
    }
};

// =============================================================================
// Note: Custom accessible wrappers are no longer needed!
// =============================================================================
// Phase 3 of A11Y_PROPOSAL has been completed. All standard Gooey components
// (Button, Checkbox, TextInput, Select, Tabs, etc.) now have built-in
// accessibility support. Simply use the `accessible_name` field to override
// the default label for screen readers.
//
// Example:
//   Button{
//       .label = "+",
//       .accessible_name = "Increase counter",  // VoiceOver reads this
//       .on_click_handler = handler,
//   }
//
//   Checkbox{
//       .id = "agree",
//       .checked = state.agreed,
//       .label = "I agree",
//       .accessible_name = "Accept terms and conditions",
//       .on_click_handler = handler,
//   }

// =============================================================================
// Tests
// =============================================================================

test "AppState toggles" {
    var s = AppState{};

    try std.testing.expect(s.notifications_enabled);
    s.toggleNotifications();
    try std.testing.expect(!s.notifications_enabled);

    try std.testing.expect(!s.dark_mode);
    s.toggleDarkMode();
    try std.testing.expect(s.dark_mode);
}

test "AppState counter" {
    var s = AppState{};

    s.increment();
    try std.testing.expectEqual(@as(i32, 1), s.count);

    s.decrement();
    try std.testing.expectEqual(@as(i32, 0), s.count);
}
