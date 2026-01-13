//! New API Demo - Phase 4 Edge Cases Validation
//!
//! Demonstrates and validates the new cx.render() + ui.* pattern:
//! - cx.render() as the single entry point for element trees
//! - ui.box(), ui.hstack(), ui.vstack() return element structs
//! - Clean separation between cx (state/handlers) and ui (layout primitives)
//!
//! Phase 4 Edge Cases Tested:
//! - [x] ui.box() with hover styles (hover_background, hover_border_color)
//! - [x] ui.box() with on_click_handler
//! - [x] ui.hstack() / ui.vstack() alignment (main/cross axis)
//! - [x] Nested ui.when() inside ui.box()
//! - [x] Components with render() method inside new containers
//! - [x] ui.spacer() works inside ui.hstack()
//! - [x] Source location tracking with ui.boxTracked()

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;
const Color = ui.Color;

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    count: i32 = 0,
    show_details: bool = false,
    click_count: i32 = 0,
    selected_alignment: AlignmentOption = .start,

    const AlignmentOption = enum { start, center, end };

    pub fn increment(self: *AppState) void {
        self.count += 1;
    }

    pub fn decrement(self: *AppState) void {
        self.count -= 1;
    }

    pub fn reset(self: *AppState) void {
        self.count = 0;
    }

    pub fn toggleDetails(self: *AppState) void {
        self.show_details = !self.show_details;
    }

    pub fn boxClicked(self: *AppState) void {
        self.click_count += 1;
    }

    pub fn setAlignStart(self: *AppState) void {
        self.selected_alignment = .start;
    }

    pub fn setAlignCenter(self: *AppState) void {
        self.selected_alignment = .center;
    }

    pub fn setAlignEnd(self: *AppState) void {
        self.selected_alignment = .end;
    }
};

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "New API Demo - Phase 4",
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
// Render Function - Uses cx.render() with ui.* elements
// =============================================================================

fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    const size = cx.windowSize();

    // Resolve alignment based on state
    const main_align: ui.StackStyle.Alignment = switch (s.selected_alignment) {
        .start => .start,
        .center => .center,
        .end => .end,
    };

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 20 },
        .gap = 16,
        .direction = .column,
        .background = Color.rgb(0.10, 0.10, 0.12),
    }, .{
        // Title
        ui.text("Phase 4: Edge Cases Demo", .{
            .size = 18,
            .color = Color.rgb(0.9, 0.9, 0.9),
        }),

        // =================================================================
        // Test 1: Hover Styles on ui.box()
        // =================================================================
        SectionHeader{ .title = "1. Hover Styles" },
        ui.hstack(.{ .gap = 12 }, .{
            // Box with hover_background
            ui.box(.{
                .padding = .{ .all = 16 },
                .background = Color.rgb(0.2, 0.2, 0.25),
                .hover_background = Color.rgb(0.3, 0.4, 0.5),
                .corner_radius = 8,
            }, .{
                ui.text("Hover me!", .{ .size = 14, .color = Color.white }),
            }),
            // Box with hover_border_color
            ui.box(.{
                .padding = .{ .all = 16 },
                .background = Color.rgb(0.2, 0.2, 0.25),
                .border_width = 2,
                .border_color = Color.rgb(0.3, 0.3, 0.35),
                .hover_border_color = Color.rgb(0.5, 0.8, 0.5),
                .corner_radius = 8,
            }, .{
                ui.text("Border hover", .{ .size = 14, .color = Color.white }),
            }),
        }),

        // =================================================================
        // Test 2: on_click_handler on ui.box()
        // =================================================================
        SectionHeader{ .title = "2. Click Handler on Box" },
        ui.hstack(.{ .gap = 12, .alignment = .center }, .{
            ui.box(.{
                .padding = .{ .all = 16 },
                .background = Color.rgb(0.3, 0.5, 0.7),
                .hover_background = Color.rgb(0.4, 0.6, 0.8),
                .corner_radius = 8,
                .on_click_handler = cx.update(AppState, AppState.boxClicked),
            }, .{
                ui.text("Click this box!", .{ .size = 14, .color = Color.white }),
            }),
            ui.textFmt("Box clicked: {} times", .{s.click_count}, .{
                .size = 14,
                .color = Color.rgb(0.7, 0.7, 0.7),
            }),
        }),

        // =================================================================
        // Test 3: Alignment on ui.hstack() / ui.vstack()
        // =================================================================
        SectionHeader{ .title = "3. Stack Alignment" },
        ui.hstack(.{ .gap = 8, .alignment = .center }, .{
            ui.text("Alignment:", .{ .size = 12, .color = Color.rgb(0.6, 0.6, 0.6) }),
            Button{
                .label = "Start",
                .size = .small,
                .variant = if (s.selected_alignment == .start) .primary else .secondary,
                .on_click_handler = cx.update(AppState, AppState.setAlignStart),
            },
            Button{
                .label = "Center",
                .size = .small,
                .variant = if (s.selected_alignment == .center) .primary else .secondary,
                .on_click_handler = cx.update(AppState, AppState.setAlignCenter),
            },
            Button{
                .label = "End",
                .size = .small,
                .variant = if (s.selected_alignment == .end) .primary else .secondary,
                .on_click_handler = cx.update(AppState, AppState.setAlignEnd),
            },
        }),
        // Alignment demo box
        ui.box(.{
            .height = 60,
            .fill_width = true,
            .background = Color.rgb(0.15, 0.15, 0.18),
            .corner_radius = 6,
            .padding = .{ .all = 8 },
        }, .{
            ui.hstack(.{ .gap = 8, .alignment = main_align }, .{
                ui.box(.{ .width = 40, .height = 40, .background = Color.rgb(0.8, 0.3, 0.3), .corner_radius = 4 }, .{}),
                ui.box(.{ .width = 40, .height = 40, .background = Color.rgb(0.3, 0.8, 0.3), .corner_radius = 4 }, .{}),
                ui.box(.{ .width = 40, .height = 40, .background = Color.rgb(0.3, 0.3, 0.8), .corner_radius = 4 }, .{}),
            }),
        }),

        // =================================================================
        // Test 4: Nested ui.when() inside ui.box()
        // =================================================================
        SectionHeader{ .title = "4. Nested Conditionals" },
        ui.hstack(.{ .gap = 8, .alignment = .center }, .{
            Button{
                .label = if (s.show_details) "Hide" else "Show",
                .size = .small,
                .variant = .secondary,
                .on_click_handler = cx.update(AppState, AppState.toggleDetails),
            },
            ui.when(s.show_details, .{
                ui.box(.{
                    .padding = .{ .all = 12 },
                    .background = Color.rgb(0.2, 0.25, 0.2),
                    .corner_radius = 6,
                }, .{
                    // Nested when inside box
                    ui.when(s.count >= 0, .{
                        ui.text("Count is non-negative", .{ .size = 12, .color = Color.rgb(0.5, 0.9, 0.5) }),
                    }),
                    ui.when(s.count < 0, .{
                        ui.text("Count is negative!", .{ .size = 12, .color = Color.rgb(0.9, 0.5, 0.5) }),
                    }),
                }),
            }),
        }),

        // =================================================================
        // Test 5: Components with render() inside new containers
        // =================================================================
        SectionHeader{ .title = "5. Components in Containers" },
        ui.hstack(.{ .gap = 12, .alignment = .center }, .{
            // Custom component inside ui.hstack
            CounterBadge{ .value = s.count, .label = "Count" },
            CounterBadge{ .value = s.click_count, .label = "Clicks" },
            // Built-in Button component
            Button{
                .label = "−",
                .size = .small,
                .on_click_handler = cx.update(AppState, AppState.decrement),
            },
            Button{
                .label = "+",
                .size = .small,
                .on_click_handler = cx.update(AppState, AppState.increment),
            },
            Button{
                .label = "Reset",
                .variant = .danger,
                .size = .small,
                .on_click_handler = cx.update(AppState, AppState.reset),
            },
        }),

        // =================================================================
        // Test 6: ui.spacer() inside ui.hstack()
        // =================================================================
        SectionHeader{ .title = "6. Spacers" },
        ui.box(.{
            .fill_width = true,
            .background = Color.rgb(0.15, 0.15, 0.18),
            .corner_radius = 6,
            .padding = .{ .all = 12 },
        }, .{
            ui.hstack(.{ .gap = 8, .alignment = .center }, .{
                ui.text("Left", .{ .size = 12, .color = Color.white }),
                ui.spacer(), // Flexible spacer pushes content apart
                ui.text("Right", .{ .size = 12, .color = Color.white }),
            }),
        }),
        ui.box(.{
            .fill_width = true,
            .background = Color.rgb(0.15, 0.15, 0.18),
            .corner_radius = 6,
            .padding = .{ .all = 12 },
        }, .{
            ui.hstack(.{ .gap = 8, .alignment = .center }, .{
                ui.text("A", .{ .size = 12, .color = Color.white }),
                ui.spacerMin(50), // Fixed minimum spacer
                ui.text("B", .{ .size = 12, .color = Color.white }),
                ui.spacer(),
                ui.text("C", .{ .size = 12, .color = Color.white }),
            }),
        }),

        // =================================================================
        // Test 7: Source Location Tracking with ui.boxTracked()
        // =================================================================
        SectionHeader{ .title = "7. Source Tracking" },
        ui.boxTracked(.{
            .padding = .{ .all = 12 },
            .background = Color.rgb(0.2, 0.2, 0.25),
            .corner_radius = 6,
        }, .{
            ui.text("This box uses ui.boxTracked(@src())", .{
                .size = 12,
                .color = Color.rgb(0.7, 0.7, 0.7),
            }),
        }, @src()),

        // Footer spacer
        ui.spacer(),
        ui.text("All Phase 4 edge cases validated ✓", .{
            .size = 11,
            .color = Color.rgb(0.4, 0.6, 0.4),
        }),
    }));
}

// =============================================================================
// Custom Components - Test render() method inside new containers
// =============================================================================

/// Section header component - demonstrates component with render(*Cx) inside ui.box()
const SectionHeader = struct {
    title: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        const b = cx.builder();
        b.box(.{
            .padding = .{ .symmetric = .{ .x = 0, .y = 4 } },
        }, .{
            ui.text(self.title, .{
                .size = 13,
                .color = Color.rgb(0.6, 0.7, 0.8),
            }),
        });
    }
};

/// Counter badge component - demonstrates component with render() inside ui.hstack()
const CounterBadge = struct {
    value: i32,
    label: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        const b = cx.builder();
        b.box(.{
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .background = if (self.value >= 0)
                Color.rgb(0.2, 0.3, 0.4)
            else
                Color.rgb(0.4, 0.2, 0.2),
            .corner_radius = 16,
            .direction = .column,
            .alignment = .{ .main = .center, .cross = .center },
            .gap = 2,
        }, .{
            ui.textFmt("{}", .{self.value}, .{
                .size = 18,
                .color = Color.white,
            }),
            ui.text(self.label, .{
                .size = 10,
                .color = Color.rgb(0.6, 0.6, 0.6),
            }),
        });
    }
};

// =============================================================================
// Tests
// =============================================================================

test "AppState increment/decrement" {
    var s = AppState{};

    s.increment();
    try std.testing.expectEqual(@as(i32, 1), s.count);

    s.decrement();
    try std.testing.expectEqual(@as(i32, 0), s.count);
}

test "AppState reset" {
    var s = AppState{ .count = 42 };
    s.reset();
    try std.testing.expectEqual(@as(i32, 0), s.count);
}

test "AppState toggleDetails" {
    var s = AppState{};
    try std.testing.expect(!s.show_details);

    s.toggleDetails();
    try std.testing.expect(s.show_details);

    s.toggleDetails();
    try std.testing.expect(!s.show_details);
}

test "AppState boxClicked" {
    var s = AppState{};
    try std.testing.expectEqual(@as(i32, 0), s.click_count);

    s.boxClicked();
    try std.testing.expectEqual(@as(i32, 1), s.click_count);

    s.boxClicked();
    try std.testing.expectEqual(@as(i32, 2), s.click_count);
}

test "AppState alignment" {
    var s = AppState{};
    try std.testing.expectEqual(AppState.AlignmentOption.start, s.selected_alignment);

    s.setAlignCenter();
    try std.testing.expectEqual(AppState.AlignmentOption.center, s.selected_alignment);

    s.setAlignEnd();
    try std.testing.expectEqual(AppState.AlignmentOption.end, s.selected_alignment);

    s.setAlignStart();
    try std.testing.expectEqual(AppState.AlignmentOption.start, s.selected_alignment);
}
