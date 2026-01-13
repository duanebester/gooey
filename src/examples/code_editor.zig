//! CodeEditor Example
//!
//! Demonstrates the CodeEditor component with line numbers and syntax highlighting support.

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;
const CodeEditor = gooey.CodeEditor;

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    source_code: []const u8 = sample_code,
    show_line_numbers: bool = true,
    show_status_bar: bool = true,
    tab_size: u8 = 4,
    use_hard_tabs: bool = false,

    const sample_code =
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    const allocator = std.heap.page_allocator;
        \\
        \\    var list = std.ArrayList(i32).init(allocator);
        \\    defer list.deinit();
        \\
        \\    try list.append(42);
        \\    try list.append(100);
        \\
        \\    for (list.items) |item| {
        \\        std.debug.print("{d}\n", .{item});
        \\    }
        \\}
    ;

    pub fn toggleLineNumbers(self: *AppState) void {
        self.show_line_numbers = !self.show_line_numbers;
    }

    pub fn toggleStatusBar(self: *AppState) void {
        self.show_status_bar = !self.show_status_bar;
    }

    pub fn toggleHardTabs(self: *AppState) void {
        self.use_hard_tabs = !self.use_hard_tabs;
    }

    pub fn setTabSize2(self: *AppState) void {
        self.tab_size = 2;
    }

    pub fn setTabSize4(self: *AppState) void {
        self.tab_size = 4;
    }

    pub fn setTabSize8(self: *AppState) void {
        self.tab_size = 8;
    }
};

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Code Editor",
    .width = 900,
    .height = 700,
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
    const s = cx.state(AppState);
    const t = cx.theme();
    const size = cx.windowSize();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 16 },
        .background = t.bg,
        .direction = .column,
        .gap = 16,
    }, .{
        // Header
        ui.text("Code Editor Demo", .{ .size = 24, .weight = .bold, .color = t.text }),

        // Controls
        ui.hstack(.{ .gap = 12 }, .{
            Button{
                .label = if (s.show_line_numbers) "Hide Lines" else "Show Lines",
                .on_click_handler = cx.update(AppState, AppState.toggleLineNumbers),
            },
            Button{
                .label = if (s.show_status_bar) "Hide Status" else "Show Status",
                .on_click_handler = cx.update(AppState, AppState.toggleStatusBar),
            },
            Button{
                .label = if (s.use_hard_tabs) "Spaces" else "Tabs",
                .on_click_handler = cx.update(AppState, AppState.toggleHardTabs),
            },
            ui.text("Tab Size:", .{ .color = t.text }),
            Button{
                .label = "2",
                .variant = if (s.tab_size == 2) .primary else .secondary,
                .on_click_handler = cx.update(AppState, AppState.setTabSize2),
            },
            Button{
                .label = "4",
                .variant = if (s.tab_size == 4) .primary else .secondary,
                .on_click_handler = cx.update(AppState, AppState.setTabSize4),
            },
            Button{
                .label = "8",
                .variant = if (s.tab_size == 8) .primary else .secondary,
                .on_click_handler = cx.update(AppState, AppState.setTabSize8),
            },
        }),

        // Code Editor with current line highlighting and status bar
        CodeEditor{
            .id = "source",
            .placeholder = "Enter your code here...",
            .bind = @constCast(&s.source_code),
            .width = 800,
            .height = 500,
            .rows = 25,
            .show_line_numbers = s.show_line_numbers,
            .gutter_width = 60,
            .tab_size = s.tab_size,
            .use_hard_tabs = s.use_hard_tabs,
            // Status bar configuration
            .show_status_bar = s.show_status_bar,
            .language_mode = "Zig",
            .encoding = "UTF-8",
            // Current line highlight (subtle blue tint)
            .current_line_background = gooey.Color.rgba(0.3, 0.5, 1.0, 0.06),
        },

        // Status
        ui.hstack(.{ .gap = 8 }, .{
            ui.text("Characters:", .{ .color = t.muted }),
            ui.textFmt("{d}", .{s.source_code.len}, .{ .color = t.text }),
        }),
    }));
}
