//! UniformList Example - Virtualized List with 10,000 items
//!
//! This example demonstrates how to use UniformList for efficient rendering
//! of large datasets. Only visible items are rendered, regardless of total count.
//!
//! Run with: zig build run-uniform-list

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;

const Cx = gooey.Cx;
const Builder = gooey.Builder;
const Color = gooey.Color;
const UniformListState = gooey.UniformListState;
const ScrollStrategy = gooey.ScrollStrategy;
const Button = gooey.Button;

const ui = gooey.ui;

// =============================================================================
// Constants
// =============================================================================

const ITEM_COUNT: u32 = 10_000;
const ITEM_HEIGHT: f32 = 32.0;

// =============================================================================
// Application State
// =============================================================================

const State = struct {
    /// Retained state for the virtual list
    list_state: UniformListState = UniformListState.init(ITEM_COUNT, ITEM_HEIGHT),

    /// Currently selected item index
    selected_index: ?u32 = null,

    // =========================================================================
    // Event Handlers (pure state methods)
    // =========================================================================

    pub fn scrollToTop(self: *State) void {
        self.list_state.scrollToTop();
    }

    pub fn scrollToBottom(self: *State) void {
        self.list_state.scrollToBottom();
    }

    pub fn jumpToMiddle(self: *State) void {
        self.selected_index = 5000;
        self.list_state.scrollToItem(5000, .center);
    }

    pub fn selectNext(self: *State) void {
        const current = self.selected_index orelse 0;
        if (current < self.list_state.item_count - 1) {
            self.selected_index = current + 1;
            self.list_state.scrollToItem(current + 1, .nearest);
        }
    }

    pub fn selectPrevious(self: *State) void {
        if (self.selected_index) |idx| {
            if (idx > 0) {
                self.selected_index = idx - 1;
                self.list_state.scrollToItem(idx - 1, .nearest);
            }
        } else {
            self.selected_index = 0;
        }
    }
};

// =============================================================================
// Global State
// =============================================================================

var state = State{};

// =============================================================================
// Components
// =============================================================================

const Header = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const theme = cx.builder().theme();

        cx.render(ui.hstack(.{ .gap = 8 }, .{
            ui.text("Virtual List Demo", .{
                .size = 18,
                .weight = .bold,
                .color = theme.text,
            }),
            ui.spacer(),
            ui.text("10,000 items - only visible ones render!", .{
                .size = 12,
                .color = theme.muted,
            }),
        }));
    }
};

const StatsBar = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(State);
        const b = cx.builder();
        const theme = b.theme();
        const range = s.list_state.visibleRange();

        // Format stats
        var buf: [256]u8 = undefined;
        const stats = std.fmt.bufPrint(&buf, "Showing items {d}-{d} of {d} | Scroll: {d:.0}%", .{
            range.start,
            range.end,
            s.list_state.item_count,
            s.list_state.scrollPercent() * 100,
        }) catch "Stats error";

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .background = theme.surface,
            .corner_radius = 4,
        }, .{
            ui.text(stats, .{ .size = 12, .color = theme.muted }),
        }));
    }
};

/// Context passed to item renderer - avoids global state access
const ItemRenderContext = struct {
    selected_index: ?u32,
    theme: *const gooey.Theme,
};

const FileList = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(State);
        var b = cx.builder();
        const theme = b.theme();

        // Create context for item rendering (avoids global state access)
        const ctx = ItemRenderContext{
            .selected_index = s.selected_index,
            .theme = theme,
        };

        b.uniformListWithContext(
            "file-list",
            &s.list_state,
            .{
                .fill_width = true,
                .grow_height = true,
                .background = theme.surface,
                .corner_radius = 8,
                .padding = .{ .all = 4 },
            },
            ctx,
            renderItem,
        );
    }

    fn renderItem(index: u32, ctx: ItemRenderContext, b: *Builder) void {
        const theme = ctx.theme;

        // Check selection using context (no global access)
        const is_selected = if (ctx.selected_index) |sel| sel == index else false;
        const is_even = index % 2 == 0;

        const bg_color = if (is_selected)
            theme.primary
        else if (is_even)
            theme.surface
        else
            Color.rgba(0, 0, 0, 0.02);

        const text_color = if (is_selected) Color.white else theme.text;

        // Static item names (avoid dynamic text allocation)
        const item_name = switch (index % 5) {
            0 => "document.pdf",
            1 => "image.png",
            2 => "data.json",
            3 => "script.zig",
            4 => "config.toml",
            else => unreachable,
        };

        // IMPORTANT: Height must match item_height_px (32.0)
        b.box(.{
            .fill_width = true,
            .height = ITEM_HEIGHT,
            .background = bg_color,
            .padding = .{ .symmetric = .{ .x = 12, .y = 0 } },
            .corner_radius = 4,
            .hover_background = theme.overlay,
            .direction = .row,
            .alignment = .{ .main = .start, .cross = .center },
            .gap = 16,
        }, .{
            // Name column
            ui.text(item_name, .{ .size = 14, .color = text_color }),
        });
    }
};

const Controls = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.hstack(.{ .gap = 8 }, .{
            Button{
                .label = "Top",
                .on_click_handler = cx.update(State, State.scrollToTop),
            },
            Button{
                .label = "Bottom",
                .on_click_handler = cx.update(State, State.scrollToBottom),
            },
            Button{
                .label = "Jump to #5000",
                .on_click_handler = cx.update(State, State.jumpToMiddle),
            },
            ui.spacer(),
            Button{
                .label = "↑ Prev",
                .on_click_handler = cx.update(State, State.selectPrevious),
            },
            Button{
                .label = "↓ Next",
                .on_click_handler = cx.update(State, State.selectNext),
            },
        }));
    }
};

// =============================================================================
// Main Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();
    const theme = cx.builder().theme();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = theme.bg,
        .padding = .{ .all = 16 },
        .direction = .column,
        .gap = 12,
    }, .{
        Header{},
        StatsBar{},
        FileList{},
        Controls{},
    }));
}

// =============================================================================
// Entry Point
// =============================================================================

const App = gooey.App(State, &state, render, .{
    .title = "UniformList Example - 10,000 Items",
    .width = 800,
    .height = 600,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}
