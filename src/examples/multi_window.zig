//! Multi-Window Example
//!
//! Demonstrates using the MultiWindowApp API to manage multiple windows
//! with shared resources. Shows:
//! - Opening multiple windows with different state types
//! - Cross-window communication (dialog updates parent window)
//! - Proper resource sharing (text system, atlases - no font glitching)
//! - Window close behavior

const std = @import("std");
const gooey = @import("gooey");

const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = ui.Color;
const Button = gooey.Button;
const MultiWindowApp = gooey.MultiWindowApp;
const WindowHandle = gooey.WindowHandle;

// =============================================================================
// Main Window State
// =============================================================================

const MainState = struct {
    counter: i32 = 0,
    /// Atomic flag to prevent race conditions when opening dialog from multiple threads
    dialog_open: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    app: ?*MultiWindowApp = null,
    dialog_handle: ?WindowHandle(DialogState) = null,

    // Dialog state is owned here so we can pass a pointer to it
    // This enables cross-window communication back to main window
    dialog_state: DialogState = .{},

    // Comptime size/alignment validation
    comptime {
        std.debug.assert(@sizeOf(MainState) >= @sizeOf(DialogState));
        std.debug.assert(@alignOf(MainState) >= @alignOf(DialogState));
    }

    pub fn increment(self: *MainState) void {
        self.counter += 1;
    }

    pub fn decrement(self: *MainState) void {
        self.counter -= 1;
    }

    pub fn openDialog(self: *MainState) void {
        if (self.dialog_open.load(.seq_cst)) return;
        if (self.app) |app| {
            // Set flag EARLY to prevent race condition with rapid double-clicks
            self.dialog_open.store(true, .seq_cst);

            // Initialize dialog state with:
            // - Current counter value (snapshot for reset)
            // - Pointer back to main state (for cross-window updates)
            self.dialog_state = .{
                .main_counter_snapshot = self.counter,
                .new_value = self.counter,
                .main_state = self, // Cross-window reference!
                .app = app,
            };

            std.debug.print("Dialog opened: counter={d}, dialog_state_ptr={*}, main_state_ptr={*}\n", .{
                self.counter,
                &self.dialog_state,
                self,
            });

            // Open dialog window
            const handle = app.openWindow(
                DialogState,
                &self.dialog_state,
                renderDialog,
                .{
                    .title = "Settings Dialog",
                    .width = 420,
                    .height = 340,
                    .centered = true,
                },
            ) catch {
                std.debug.print("Failed to open dialog window\n", .{});
                self.dialog_open.store(false, .seq_cst); // Reset on error
                return;
            };

            self.dialog_handle = handle;
        }
    }

    /// Called by dialog when it closes (via Apply or close button)
    pub fn onDialogClosed(self: *MainState) void {
        self.dialog_open.store(false, .seq_cst);
        self.dialog_handle = null;
    }
};

// =============================================================================
// Dialog Window State
// =============================================================================

const DialogState = struct {
    main_counter_snapshot: i32 = 0,
    new_value: i32 = 0,

    // Cross-window reference to main state
    main_state: ?*MainState = null,
    app: ?*MultiWindowApp = null,

    pub fn incrementNew(self: *DialogState) void {
        self.new_value += 1;
    }

    pub fn decrementNew(self: *DialogState) void {
        self.new_value -= 1;
    }

    pub fn reset(self: *DialogState) void {
        self.new_value = self.main_counter_snapshot;
    }

    /// Apply changes to main window and close dialog
    pub fn applyAndClose(self: *DialogState) void {
        // Update main window's counter with our new value
        if (self.main_state) |main_win| {
            main_win.counter = self.new_value;
            main_win.onDialogClosed();

            // Close this dialog window
            if (main_win.dialog_handle) |handle| {
                if (main_win.app) |the_app| {
                    handle.close(the_app.getRegistry());
                }
            }
        }
    }

    /// Cancel and close dialog without applying changes
    pub fn cancel(self: *DialogState) void {
        if (self.main_state) |main_win| {
            main_win.onDialogClosed();

            // Close this dialog window
            if (main_win.dialog_handle) |handle| {
                if (main_win.app) |the_app| {
                    handle.close(the_app.getRegistry());
                }
            }
        }
    }

    /// Check if value has changed from snapshot
    pub fn hasChanges(self: *const DialogState) bool {
        return self.new_value != self.main_counter_snapshot;
    }
};

// =============================================================================
// Main Window Render
// =============================================================================

fn renderMain(cx: *Cx) void {
    const s = cx.state(MainState);
    const size = cx.windowSize();

    // Read counter with volatile semantics
    const counter = @as(*volatile i32, @ptrCast(&s.counter)).*;

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 32 },
        .direction = .column,
        .gap = 24,
        .alignment = .{ .main = .center, .cross = .center },
        .background = Color.rgb(0.95, 0.95, 0.95),
    }, .{
        // Title
        ui.text("Multi-Window Demo", .{
            .size = 28,
            .weight = .bold,
            .color = Color.rgb(0.2, 0.5, 0.8),
        }),

        // Counter display card
        ui.box(.{
            .padding = .{ .all = 24 },
            .corner_radius = 12,
            .background = Color.white,
            .shadow = .{
                .color = Color.black.withAlpha(0.1),
                .blur_radius = 10,
                .offset_y = 2,
            },
            .direction = .column,
            .gap = 16,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            // Counter value
            ui.textFmt("Counter: {d}", .{counter}, .{
                .size = 32,
                .weight = .bold,
                .color = Color.rgb(0.2, 0.2, 0.25),
            }),
            // Counter controls
            ui.hstack(.{ .gap = 12 }, .{
                Button{
                    .label = "−",
                    .size = .large,
                    .on_click_handler = cx.update(MainState.decrement),
                },
                Button{
                    .label = "+",
                    .size = .large,
                    .on_click_handler = cx.update(MainState.increment),
                },
            }),
        }),

        // Open dialog button
        Button{
            .label = if (s.dialog_open.load(.seq_cst)) "Dialog Open..." else "Open Settings Dialog",
            .variant = if (s.dialog_open.load(.seq_cst)) .secondary else .primary,
            .size = .large,
            .on_click_handler = cx.update(MainState.openDialog),
        },

        // Window count info
        ui.when(s.app != null, .{
            ui.textFmt("Open windows: {d}", .{if (s.app) |app| app.windowCount() else 0}, .{
                .size = 14,
                .color = Color.rgb(0.5, 0.5, 0.55),
            }),
        }),

        // Instructions
        ui.text("Open the dialog to edit the counter value in a separate window.", .{
            .size = 13,
            .color = Color.rgb(0.5, 0.5, 0.55),
        }),
        ui.text("Click 'Apply' in the dialog to update this window's counter.", .{
            .size = 13,
            .color = Color.rgb(0.5, 0.5, 0.55),
        }),
    }));
}

// =============================================================================
// Dialog Window Render
// =============================================================================

fn renderDialog(cx: *Cx) void {
    const s = cx.state(DialogState);
    const size = cx.windowSize();

    // Read values with volatile semantics to prevent compiler reordering
    const new_value = @as(*volatile i32, @ptrCast(&s.new_value)).*;
    const snapshot = @as(*volatile i32, @ptrCast(&s.main_counter_snapshot)).*;

    const has_changes = new_value != snapshot;

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 24 },
        .direction = .column,
        .gap = 20,
        .background = Color.rgb(0.98, 0.98, 0.98),
    }, .{
        // Dialog title
        ui.text("Edit Counter Value", .{
            .size = 22,
            .weight = .bold,
            .color = Color.rgb(0.2, 0.2, 0.25),
        }),

        // Content card
        ui.box(.{
            .padding = .{ .all = 20 },
            .corner_radius = 8,
            .background = Color.white,
            .direction = .column,
            .gap = 16,
        }, .{
            // Snapshot info
            ui.hstack(.{ .gap = 8 }, .{
                ui.text("Original value:", .{
                    .size = 14,
                    .color = Color.rgb(0.5, 0.5, 0.55),
                }),
                ui.textFmt("{d}", .{snapshot}, .{
                    .size = 14,
                    .weight = .semibold,
                    .color = Color.rgb(0.4, 0.4, 0.45),
                }),
            }),
            // New value display
            ui.hstack(.{ .gap = 8, .alignment = .center }, .{
                ui.text("New value:", .{
                    .size = 16,
                    .weight = .semibold,
                    .color = Color.rgb(0.3, 0.3, 0.35),
                }),
                ui.textFmt("{d}", .{new_value}, .{
                    .size = 28,
                    .weight = .bold,
                    .color = if (has_changes)
                        Color.rgb(0.2, 0.6, 0.4)
                    else
                        Color.rgb(0.3, 0.3, 0.35),
                }),
                ui.when(has_changes, .{
                    ui.text("(modified)", .{
                        .size = 12,
                        .color = Color.rgb(0.2, 0.6, 0.4),
                    }),
                }),
            }),
            // Value controls
            ui.hstack(.{ .gap = 12 }, .{
                Button{
                    .label = "−",
                    .size = .medium,
                    .on_click_handler = cx.update(DialogState.decrementNew),
                },
                Button{
                    .label = "+",
                    .size = .medium,
                    .on_click_handler = cx.update(DialogState.incrementNew),
                },
                ui.spacerMin(8),
                Button{
                    .label = "Reset",
                    .variant = .secondary,
                    .size = .small,
                    .on_click_handler = cx.update(DialogState.reset),
                },
            }),
        }),

        // Spacer pushes buttons to bottom
        ui.spacer(),

        // Action buttons row
        ui.hstack(.{ .gap = 12, .alignment = .end }, .{
            Button{
                .label = "Cancel",
                .variant = .secondary,
                .size = .medium,
                .on_click_handler = cx.update(DialogState.cancel),
            },
            Button{
                .label = if (has_changes) "Apply Changes" else "Apply",
                .variant = if (has_changes) .primary else .secondary,
                .size = .medium,
                .on_click_handler = cx.update(DialogState.applyAndClose),
            },
        }),

        // Help text
        ui.text("Changes will be applied to the main window when you click Apply.", .{
            .size = 12,
            .color = Color.rgb(0.5, 0.5, 0.55),
        }),
    }));
}

// =============================================================================
// Main Entry Point
// =============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create the multi-window app
    var app = try MultiWindowApp.init(allocator, .{ .font_size = 16.0 });
    defer app.deinit();

    // Create main window state with app reference
    var main_state = MainState{};
    main_state.app = &app;

    // Open the main window
    _ = try app.openWindow(MainState, &main_state, renderMain, .{
        .title = "Multi-Window Demo - Main",
        .width = 500,
        .height = 450,
        .centered = true,
    });

    // Run the event loop
    app.run();
}
