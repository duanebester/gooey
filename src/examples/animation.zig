//! Animation Demo — Springs, Motion Containers, and Stagger
//!
//! Showcases the full animation toolkit:
//! - `cx.animate` / `cx.animateOn` — basic tween animations
//! - `cx.springMotionComptime` — interruptible enter/exit with spring physics
//! - `cx.staggerComptime` — cascading list entry animations
const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = ui.Color;
const Easing = gooey.Easing;
const Button = gooey.Button;

// =============================================================================
// App State
// =============================================================================

const list_items = [_]ListItem{
    .{ .name = "Apples", .color = Color.rgb(0.85, 0.25, 0.25) },
    .{ .name = "Bananas", .color = Color.rgb(0.95, 0.80, 0.20) },
    .{ .name = "Cherries", .color = Color.rgb(0.75, 0.15, 0.30) },
    .{ .name = "Dates", .color = Color.rgb(0.60, 0.40, 0.20) },
    .{ .name = "Elderberries", .color = Color.rgb(0.30, 0.20, 0.50) },
    .{ .name = "Figs", .color = Color.rgb(0.50, 0.35, 0.55) },
};

const ListItem = struct {
    name: []const u8,
    color: Color,
};

const AppState = struct {
    count: i32 = 0,
    show_panel: bool = true,
    show_list: bool = false,

    pub fn increment(self: *AppState) void {
        self.count += 1;
    }

    pub fn decrement(self: *AppState) void {
        self.count -= 1;
    }

    pub fn togglePanel(self: *AppState) void {
        self.show_panel = !self.show_panel;
    }

    pub fn toggleList(self: *AppState) void {
        self.show_list = !self.show_list;
    }
};

// =============================================================================
// Root Render
// =============================================================================

fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    const size = cx.windowSize();

    std.debug.assert(size.width > 0);
    std.debug.assert(size.height > 0);

    const fade_in = cx.animate("main-fade", .{ .duration_ms = 500 });

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 32 },
        .direction = .column,
        .gap = 24,
        .background = Color.rgb(0.95, 0.95, 0.95).withAlpha(fade_in.progress),
    }, .{
        ui.text("Animation Demo", .{
            .size = 28,
            .color = Color.rgb(0.2, 0.2, 0.2).withAlpha(fade_in.progress),
        }),

        CounterDisplay{ .count = s.count },
        ControlButtons{},

        // Spring motion panel — interruptible, no manual lifecycle
        PanelSection{ .show = s.show_panel },

        // Staggered list — cascading entry animations
        StaggeredListSection{ .show = s.show_list },
    }));
}

// =============================================================================
// Control Buttons
// =============================================================================

const ControlButtons = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        std.debug.assert(@TypeOf(s) == *AppState);
        std.debug.assert(@sizeOf(AppState) > 0);

        cx.render(ui.hstack(.{ .gap = 12, .alignment = .center }, .{
            Button{
                .label = "-",
                .size = .large,
                .on_click_handler = cx.update(AppState, AppState.decrement),
            },
            Button{
                .label = "+",
                .size = .large,
                .on_click_handler = cx.update(AppState, AppState.increment),
            },
            Button{
                .label = if (s.show_panel) "Hide Panel" else "Show Panel",
                .on_click_handler = cx.update(AppState, AppState.togglePanel),
            },
            Button{
                .label = if (s.show_list) "Hide List" else "Show List",
                .on_click_handler = cx.update(AppState, AppState.toggleList),
            },
        }));
    }
};

// =============================================================================
// Counter Display (animateOn — pulse on value change)
// =============================================================================

const CounterDisplay = struct {
    count: i32,

    pub fn render(self: @This(), cx: *Cx) void {
        // Restarts each time count changes — velocity not preserved (tween)
        const pulse = cx.animateOn("count-pulse", self.count, .{
            .duration_ms = 200,
            .easing = Easing.easeOutBack,
        });

        std.debug.assert(pulse.progress >= 0.0);
        std.debug.assert(pulse.progress <= 1.5); // easeOutBack overshoots

        const scale = 1.0 + (1.0 - pulse.progress) * 0.15;

        cx.render(ui.box(.{
            .width = 120 * scale,
            .height = 80 * scale,
            .background = Color.white,
            .corner_radius = 12,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.textFmt("{d}", .{self.count}, .{
                .size = 48,
                .color = if (self.count >= 0)
                    Color.rgb(0.2, 0.5, 0.8)
                else
                    Color.rgb(0.8, 0.3, 0.3),
            }),
        }));
    }
};

// =============================================================================
// Panel Section (spring motion — interruptible enter/exit)
// =============================================================================

const PanelSection = struct {
    show: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        // Spring motion: velocity is preserved on rapid toggle.
        // No manual progress reversal, no manual "keep rendering during exit".
        const m = cx.springMotionComptime("panel-spring", self.show, .snappy);

        std.debug.assert(m.progress >= 0.0);
        std.debug.assert(m.progress <= 1.0 or m.phase == .entering);

        if (m.visible) {
            cx.render(ui.box(.{
                .width = 300,
                .height = 100.0 * m.progress,
                .padding = .{ .all = 16 },
                .background = Color.rgba(0.2, 0.5, 1.0, m.progress),
                .corner_radius = 8,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                ui.text("Spring Panel!", .{
                    .size = 18,
                    .color = Color.white.withAlpha(m.progress),
                }),
            }));
        }
    }
};

// =============================================================================
// Staggered List Section (cascading entry animation)
// =============================================================================

const StaggeredListSection = struct {
    show: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const m = cx.springMotionComptime("list-container", self.show, .snappy);

        std.debug.assert(m.progress >= 0.0);
        std.debug.assert(list_items.len <= 512); // MAX_STAGGER_ITEMS

        if (!m.visible) return;

        cx.render(ui.box(.{
            .direction = .column,
            .gap = 8,
        }, .{
            ui.text("Staggered List", .{
                .size = 18,
                .color = Color.rgb(0.3, 0.3, 0.3).withAlpha(m.progress),
            }),
            StaggeredItems{ .container_progress = m.progress, .container_exiting = (m.phase == .exiting) },
        }));
    }
};

const StaggeredItems = struct {
    container_progress: f32,
    container_exiting: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const count: u32 = @intCast(list_items.len);

        std.debug.assert(count > 0);
        std.debug.assert(count <= 512);

        var items: [list_items.len]StaggeredRow = undefined;
        for (&items, 0..) |*slot, i| {
            slot.* = StaggeredRow{
                .index = @intCast(i),
                .total = count,
                .container_progress = self.container_progress,
                .container_exiting = self.container_exiting,
            };
        }
        cx.render(ui.box(.{ .direction = .column, .gap = 6 }, items));
    }
};

/// Compute per-item alpha for a reverse-cascade exit.
/// Last item fades first, first item fades last.
/// `spread` controls how much of the exit is staggered (0 = all at once, 1 = fully sequential).
fn reverseStaggerAlpha(index: u32, total: u32, container_progress: f32) f32 {
    std.debug.assert(total > 0);
    if (total <= 1) return container_progress;

    const spread: f32 = 0.5;
    const total_f = @as(f32, @floatFromInt(total - 1));
    const reverse_index = @as(f32, @floatFromInt(total - 1 - index));
    const step = spread / total_f;
    const window = 1.0 - spread;
    const fade_start = 1.0 - reverse_index * step - window;

    return std.math.clamp((container_progress - fade_start) / window, 0.0, 1.0);
}

const StaggeredRow = struct {
    index: u32,
    total: u32,
    container_progress: f32,
    container_exiting: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const anim = cx.staggerComptime("list-enter", self.index, self.total, .list);
        const item = list_items[self.index];

        std.debug.assert(anim.progress >= 0.0);
        std.debug.assert(anim.progress <= 1.5); // easeOutBack can overshoot

        // Phase-aware alpha:
        // - Entering: stagger cascade in, capped by container visibility
        // - Exiting:  reverse cascade out (last item fades first)
        const alpha = if (self.container_exiting)
            reverseStaggerAlpha(self.index, self.total, self.container_progress)
        else
            @min(anim.progress, self.container_progress);

        cx.render(ui.box(.{
            .width = 260,
            .height = 36,
            .padding = .{ .symmetric = .{ .x = 12, .y = 0 } },
            .background = item.color.withAlpha(alpha * 0.85),
            .corner_radius = 6,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.text(item.name, .{
                .size = 14,
                .color = Color.white.withAlpha(alpha),
            }),
        }));
    }
};

// =============================================================================
// Loading Spinner (continuous ping-pong tween)
// =============================================================================

const LoadingSpinner = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const pulse = cx.animate("spinner", .{
            .duration_ms = 1000,
            .easing = Easing.easeInOut,
            .mode = .ping_pong,
        });

        std.debug.assert(pulse.progress >= 0.0);
        std.debug.assert(pulse.progress <= 1.0);

        cx.render(ui.hstack(.{ .gap = 8, .alignment = .center }, .{
            ui.text("Loading:", .{ .size = 14, .color = Color.rgb(0.5, 0.5, 0.5) }),
            SpinnerBall{ .progress = pulse.progress },
        }));
    }
};

const SpinnerBall = struct {
    progress: f32,

    pub fn render(self: @This(), cx: *Cx) void {
        std.debug.assert(self.progress >= 0.0);
        std.debug.assert(self.progress <= 1.0);

        const spinner_size = gooey.lerp(30.0, 40.0, self.progress);
        const opacity = gooey.lerp(0.4, 1.0, self.progress);

        cx.render(ui.box(.{
            .width = spinner_size,
            .height = spinner_size,
            .background = Color.rgba(0.3, 0.6, 1.0, opacity),
            .corner_radius = spinner_size / 2,
        }, .{}));
    }
};

// =============================================================================
// Entry Point
// =============================================================================

var state = AppState{};

pub fn main() !void {
    try gooey.runCx(AppState, &state, render, .{
        .title = "Animation Demo",
        .width = 550,
        .height = 550,
    });
}
