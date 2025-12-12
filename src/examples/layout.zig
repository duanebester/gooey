//! Layout System Demo - Phase 1 Features
//!
//! Demonstrates the new layout features:
//! - Shrink behavior (responsive layouts)
//! - Aspect ratio (images, video containers)
//! - Percent sizing with min/max constraints
//! - Text wrapping

const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;

// =============================================================================
// State
// =============================================================================

var state = struct {
    show_dropdown: bool = false,
    window_width: f32 = 800,
}{};

// =============================================================================
// Main Entry
// =============================================================================

pub fn main() !void {
    try gooey.run(.{
        .title = "Layout Demo - Phase 1 Features",
        .width = 800,
        .height = 600,
        .render = render,
        .on_event = onEvent,
    });
}

fn render(g: *gooey.UI) void {
    const size = g.windowSize();
    state.window_width = size.width;

    g.box(.{
        .width = size.width,
        .height = size.height,
        .background = ui.Color.rgb(0.95, 0.95, 0.95),
        .direction = .column,
        .padding = .{ .all = 20 },
        .gap = 20,
    }, .{
        Header{},
        MainContent{},
    });
}

// =============================================================================
// Components
// =============================================================================

const Header = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .padding = .{ .all = 16 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .row,
            .alignment = .{ .main = .space_between, .cross = .center },
        }, .{
            ui.text("Layout System Demo", .{ .size = 24 }),
            DropdownButton{},
        });
    }
};

const DropdownButton = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .padding = .{ .symmetric = .{ .x = 16, .y = 8 } },
            .background = ui.Color.rgb(0.2, 0.5, 1.0),
            .corner_radius = 6,
        }, .{
            ui.button("Menu ▼", toggleDropdown),
            DropdownOverlay{},
        });
    }

    fn toggleDropdown() void {
        state.show_dropdown = !state.show_dropdown;
    }
};

/// Wrapper for conditional dropdown rendering
const DropdownOverlay = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        if (state.show_dropdown) {
            b.box(.{}, .{DropdownMenu{}});
        }
    }
};

const DropdownMenu = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .width = 150,
            .padding = .{ .all = 8 },
            .background = ui.Color.white,
            .corner_radius = 6,
            .direction = .column,
            .gap = 4,
            .shadow = .{ .blur_radius = 8, .offset_y = 4 },
        }, .{
            MenuItem{ .label = "Profile" },
            MenuItem{ .label = "Settings" },
            MenuItem{ .label = "Logout" },
        });
    }
};

const MenuItem = struct {
    label: []const u8,

    pub fn render(self: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .corner_radius = 4,
        }, .{
            ui.text(self.label, .{ .size = 14 }),
        });
    }
};

const MainContent = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .grow = true,
            .direction = .column,
            .gap = 20,
        }, .{
            TextWrapDemo{},
            ShrinkDemo{},
            AspectRatioDemo{},
            PercentSizingDemo{},
        });
    }
};

// =============================================================================
// TEXT WRAPPING DEMO
// =============================================================================

const TextWrapDemo = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .padding = .{ .all = 16 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .column,
            .gap = 12,
        }, .{
            ui.text("Text Wrapping", .{ .size = 18 }),
            ui.text("Resize window to see text wrap:", .{ .size = 12, .color = ui.Color.rgb(0.5, 0.5, 0.5) }),
            TextWrapRow{},
        });
    }
};

const TextWrapRow = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .direction = .column,
            .gap = 16,
        }, .{
            TextWrapBox{
                .title = "No Wrap",
                .wrap = .none,
                .color = ui.Color.rgb(0.95, 0.9, 0.9),
            },
            TextWrapBox{
                .title = "Word Wrap",
                .wrap = .words,
                .color = ui.Color.rgb(0.9, 0.95, 0.9),
            },
            TextWrapBox{
                .title = "Newline Wrap",
                .wrap = .newlines,
                .color = ui.Color.rgb(0.9, 0.9, 0.95),
            },
        });
    }
};

const TextWrapBox = struct {
    title: []const u8,
    wrap: ui.TextStyle.WrapMode,
    color: ui.Color,

    const sample_text = "The quick brown fox jumps over the lazy dog. This text demonstrates wrapping behavior.";
    const newline_text = "Line one here.\nLine two here.\nLine three.";

    pub fn render(self: @This(), b: *ui.Builder) void {
        const text_content = if (self.wrap == .newlines) newline_text else sample_text;

        b.box(.{
            .grow_width = true, // Grow horizontally to share space
            .min_width = 100,
            .padding = .{ .all = 12 },
            .background = self.color,
            .corner_radius = 8,
            .direction = .column,
            .gap = 8,
        }, .{
            ui.text(self.title, .{ .size = 14, .color = ui.Color.rgb(0.3, 0.3, 0.3) }),
            ui.text(text_content, .{
                .size = 13,
                .wrap = self.wrap,
                .color = ui.Color.rgb(0.2, 0.2, 0.2),
            }),
        });
    }
};

// =============================================================================
// SHRINK BEHAVIOR DEMO
// =============================================================================

const ShrinkDemo = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .padding = .{ .all = 16 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .column,
            .gap = 12,
        }, .{
            ui.text("Shrink Behavior", .{ .size = 18 }),
            ui.text("These boxes shrink when window is too small:", .{ .size = 12, .color = ui.Color.rgb(0.5, 0.5, 0.5) }),
            ShrinkRow{},
        });
    }
};

const ShrinkRow = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .direction = .row,
            .gap = 8,
        }, .{
            ShrinkBox{ .label = "Box A", .color = ui.Color.rgb(0.9, 0.3, 0.3) },
            ShrinkBox{ .label = "Box B", .color = ui.Color.rgb(0.3, 0.9, 0.3) },
            ShrinkBox{ .label = "Box C", .color = ui.Color.rgb(0.3, 0.3, 0.9) },
            ShrinkBox{ .label = "Box D", .color = ui.Color.rgb(0.9, 0.9, 0.3) },
        });
    }
};

const ShrinkBox = struct {
    label: []const u8,
    color: ui.Color,

    pub fn render(self: @This(), b: *ui.Builder) void {
        b.box(.{
            .width = 150,
            .min_width = 60,
            .height = 60,
            .background = self.color,
            .corner_radius = 8,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.text(self.label, .{ .size = 14, .color = ui.Color.white }),
        });
    }
};

// =============================================================================
// ASPECT RATIO DEMO
// =============================================================================

const AspectRatioDemo = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .padding = .{ .all = 16 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .column,
            .gap = 12,
        }, .{
            ui.text("Aspect Ratio", .{ .size = 18 }),
            ui.text("Boxes maintain their aspect ratio as width changes:", .{ .size = 12, .color = ui.Color.rgb(0.5, 0.5, 0.5) }),
            AspectRatioRow{},
        });
    }
};

const AspectRatioRow = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .direction = .row,
            .gap = 16,
            .alignment = .{ .cross = .start },
        }, .{
            AspectBox{ .label = "16:9", .ratio = 16.0 / 9.0, .color = ui.Color.rgb(0.2, 0.2, 0.3) },
            AspectBox{ .label = "1:1", .ratio = 1.0, .color = ui.Color.rgb(0.3, 0.2, 0.2) },
            AspectBox{ .label = "4:3", .ratio = 4.0 / 3.0, .color = ui.Color.rgb(0.2, 0.3, 0.2) },
        });
    }
};

const AspectBox = struct {
    label: []const u8,
    ratio: f32,
    color: ui.Color,

    pub fn render(self: @This(), b: *ui.Builder) void {
        const width: f32 = 150;
        const height = width / self.ratio;

        b.box(.{
            .width = width,
            .height = height,
            .background = self.color,
            .corner_radius = 8,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.text(self.label, .{ .size = 16, .color = ui.Color.white }),
        });
    }
};

// =============================================================================
// PERCENT SIZING DEMO
// =============================================================================

const PercentSizingDemo = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        b.box(.{
            .fill_width = true,
            .padding = .{ .all = 16 },
            .background = ui.Color.white,
            .corner_radius = 8,
            .direction = .column,
            .gap = 12,
        }, .{
            ui.text("Percent Sizing with Min/Max", .{ .size = 18 }),
            ui.text("50% width, clamped between 200-400px:", .{ .size = 12, .color = ui.Color.rgb(0.5, 0.5, 0.5) }),
            PercentBar{},
        });
    }
};

const PercentBar = struct {
    pub fn render(_: @This(), b: *ui.Builder) void {
        const parent_width = state.window_width - 40 - 32;
        const computed = @max(200, @min(400, parent_width * 0.5));

        b.box(.{
            .width = computed,
            .height = 40,
            .background = ui.Color.rgb(0.6, 0.2, 0.8),
            .corner_radius = 8,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.text("50% (min:200, max:400)", .{ .size = 12, .color = ui.Color.white }),
        });
    }
};

// =============================================================================
// Event Handling
// =============================================================================

fn onEvent(_: *gooey.UI, event: gooey.InputEvent) bool {
    if (event == .key_down) {
        const key = event.key_down;

        if (key.key == .escape) {
            if (state.show_dropdown) {
                state.show_dropdown = false;
                return true;
            }
        }
    }
    return false;
}
