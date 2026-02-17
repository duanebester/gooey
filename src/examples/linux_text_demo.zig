//! Linux Text Rendering Demo
//!
//! Demonstrates text rendering on Linux using the FreeType/HarfBuzz backend.
//! This example uses the full gooey UI framework to test:
//! - Text rendering at various sizes
//! - Text colors
//! - Text layout (horizontal/vertical stacking)
//! - Buttons with text labels
//!
//! Build and run:
//!   zig build run-linux-text

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;
const Svg = gooey.Svg;
const Icons = gooey.Icons;
const Image = gooey.Image;

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    click_count: i32 = 0,
    font_size: u16 = 16,
    message: []const u8 = "Click a button!",

    pub fn increment(self: *AppState) void {
        self.click_count += 1;
        self.message = "Button clicked!";
    }

    pub fn decrement(self: *AppState) void {
        self.click_count -= 1;
        self.message = "Decremented!";
    }

    pub fn reset(self: *AppState) void {
        self.click_count = 0;
        self.message = "Counter reset!";
    }

    pub fn increaseFontSize(self: *AppState) void {
        if (self.font_size < 72) {
            self.font_size += 4;
        }
    }

    pub fn decreaseFontSize(self: *AppState) void {
        if (self.font_size > 8) {
            self.font_size -= 4;
        }
    }
};

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Linux Text Demo",
    .width = 800,
    .height = 800,
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
    const size = cx.windowSize();

    cx.render(ui.scroll("main_scroll", .{
        .width = size.width,
        .height = size.height,
        .vertical = true,
        .horizontal = false,
        .padding = .{ .all = 24 },
        .gap = 20,
        .background = ui.Color.rgb(0.12, 0.12, 0.14),
        .scrollbar_size = 8,
        .track_color = ui.Color.rgb(0.18, 0.18, 0.2),
        .thumb_color = ui.Color.rgb(0.3, 0.3, 0.35),
    }, .{
        // Title
        ui.text("Linux Text Rendering Demo", .{
            .size = 28,
            .color = ui.Color.rgb(0.95, 0.95, 1.0),
        }),

        // Subtitle
        ui.text("FreeType + HarfBuzz + Vulkan", .{
            .size = 14,
            .color = ui.Color.rgb(0.5, 0.5, 0.55),
        }),

        // Counter display section
        CounterSection{},

        // Font size controls
        FontSizeSection{},

        // Text samples at various sizes
        TextSamplesSection{},

        // SVG Icons section
        SvgIconsSection{},

        // Image section
        ImageSection{},

        // Status message
        ui.text(s.message, .{
            .size = 14,
            .color = ui.Color.rgb(0.4, 0.8, 0.4),
        }),
    }));
}

// =============================================================================
// Components
// =============================================================================

const CounterSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .padding = .{ .all = 20 },
            .gap = 16,
            .direction = .column,
            .background = ui.Color.rgb(0.18, 0.18, 0.2),
            .corner_radius = 12,
        }, .{
            ui.text("Counter", .{
                .size = 18,
                .color = ui.Color.rgb(0.8, 0.8, 0.85),
            }),

            // Counter value
            ui.box(.{
                .padding = .{ .all = 16 },
                .background = ui.Color.rgb(0.1, 0.1, 0.12),
                .corner_radius = 8,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                ui.textFmt("{}", .{s.click_count}, .{
                    .size = 48,
                    .color = if (s.click_count >= 0)
                        ui.Color.rgb(0.4, 0.7, 1.0)
                    else
                        ui.Color.rgb(1.0, 0.4, 0.4),
                }),
            }),

            // Control buttons
            ui.hstack(.{ .gap = 12, .alignment = .center }, .{
                Button{
                    .label = "−",
                    .size = .large,
                    .on_click_handler = cx.update(AppState.decrement),
                },
                Button{
                    .label = "+",
                    .size = .large,
                    .on_click_handler = cx.update(AppState.increment),
                },
                ui.spacerMin(16),
                Button{
                    .label = "Reset",
                    .variant = .secondary,
                    .on_click_handler = cx.update(AppState.reset),
                },
            }),
        }));
    }
};

const FontSizeSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.hstack(.{ .gap = 12, .alignment = .center }, .{
            ui.text("Font Size:", .{
                .size = 14,
                .color = ui.Color.rgb(0.6, 0.6, 0.65),
            }),

            Button{
                .label = "A−",
                .size = .small,
                .on_click_handler = cx.update(AppState.decreaseFontSize),
            },

            ui.textFmt("{}", .{s.font_size}, .{
                .size = 16,
                .color = ui.Color.rgb(0.9, 0.9, 0.95),
            }),

            Button{
                .label = "A+",
                .size = .small,
                .on_click_handler = cx.update(AppState.increaseFontSize),
            },
        }));
    }
};

const TextSamplesSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .padding = .{ .all = 16 },
            .gap = 12,
            .direction = .column,
            .background = ui.Color.rgb(0.15, 0.15, 0.17),
            .corner_radius = 8,
        }, .{
            ui.text("Text Samples:", .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.55),
            }),

            // Dynamic size text
            ui.text("The quick brown fox jumps over the lazy dog", .{
                .size = @as(u16, s.font_size),
                .color = ui.Color.rgb(0.9, 0.9, 0.95),
            }),

            // Various fixed sizes
            ui.text("Small text (10px)", .{
                .size = 10,
                .color = ui.Color.rgb(0.7, 0.7, 0.75),
            }),

            ui.text("Normal text (16px)", .{
                .size = 16,
                .color = ui.Color.rgb(0.8, 0.8, 0.85),
            }),

            ui.text("Large text (24px)", .{
                .size = 24,
                .color = ui.Color.rgb(0.9, 0.9, 0.95),
            }),

            // Colored text
            ui.hstack(.{ .gap = 16 }, .{
                ui.text("Red", .{ .size = 16, .color = ui.Color.rgb(1.0, 0.3, 0.3) }),
                ui.text("Green", .{ .size = 16, .color = ui.Color.rgb(0.3, 1.0, 0.3) }),
                ui.text("Blue", .{ .size = 16, .color = ui.Color.rgb(0.3, 0.5, 1.0) }),
                ui.text("Yellow", .{ .size = 16, .color = ui.Color.rgb(1.0, 1.0, 0.3) }),
            }),

            // Special characters
            ui.text("Special: © ® ™ → ← ↑ ↓ • … — –", .{
                .size = 16,
                .color = ui.Color.rgb(0.7, 0.7, 0.75),
            }),

            // Numbers and punctuation
            ui.text("0123456789 !@#$%^&*()[]{}|\\;:'\",.<>?/", .{
                .size = 14,
                .color = ui.Color.rgb(0.6, 0.6, 0.65),
            }),
        }));
    }
};

const ImageSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .padding = .{ .all = 16 },
            .gap = 16,
            .direction = .column,
            .background = ui.Color.rgb(0.15, 0.15, 0.17),
            .corner_radius = 8,
        }, .{
            ui.text("Images:", .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.55),
            }),

            // Row of images at different sizes
            ui.hstack(.{ .gap = 16, .alignment = .center }, .{
                ui.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Image{
                        .src = "assets/ziglang_logo.png",
                        .size = 32,
                    },
                    ui.text("32px", .{ .size = 10, .color = ui.Color.rgb(0.5, 0.5, 0.55) }),
                }),
                ui.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Image{
                        .src = "assets/ziglang_logo.png",
                        .size = 48,
                    },
                    ui.text("48px", .{ .size = 10, .color = ui.Color.rgb(0.5, 0.5, 0.55) }),
                }),
                ui.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Image{
                        .src = "assets/ziglang_logo.png",
                        .size = 64,
                    },
                    ui.text("64px", .{ .size = 10, .color = ui.Color.rgb(0.5, 0.5, 0.55) }),
                }),
                ui.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Image{
                        .src = "assets/ziglang_logo.png",
                        .size = 80,
                    },
                    ui.text("80px", .{ .size = 10, .color = ui.Color.rgb(0.5, 0.5, 0.55) }),
                }),
            }),

            // Row with corner radius and effects
            ui.hstack(.{ .gap = 16, .alignment = .center }, .{
                ui.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Image{
                        .src = "assets/ziglang_logo.png",
                        .size = 64,
                        .corner_radius = 8,
                    },
                    ui.text("rounded", .{ .size = 10, .color = ui.Color.rgb(0.5, 0.5, 0.55) }),
                }),
                ui.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Image{
                        .src = "assets/ziglang_logo.png",
                        .size = 64,
                        .rounded = true,
                    },
                    ui.text("circle", .{ .size = 10, .color = ui.Color.rgb(0.5, 0.5, 0.55) }),
                }),
                ui.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Image{
                        .src = "assets/ziglang_logo.png",
                        .size = 64,
                        .grayscale = 1.0,
                    },
                    ui.text("grayscale", .{ .size = 10, .color = ui.Color.rgb(0.5, 0.5, 0.55) }),
                }),
                ui.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Image{
                        .src = "assets/ziglang_logo.png",
                        .size = 64,
                        .tint = ui.Color.rgb(0.3, 0.6, 1.0),
                    },
                    ui.text("tinted", .{ .size = 10, .color = ui.Color.rgb(0.5, 0.5, 0.55) }),
                }),
                ui.box(.{ .gap = 4, .alignment = .{ .cross = .center } }, .{
                    Image{
                        .src = "assets/ziglang_logo.png",
                        .size = 64,
                        .opacity = 0.5,
                    },
                    ui.text("50% opacity", .{ .size = 10, .color = ui.Color.rgb(0.5, 0.5, 0.55) }),
                }),
            }),
        }));
    }
};

const SvgIconsSection = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .padding = .{ .all = 16 },
            .gap = 16,
            .direction = .column,
            .background = ui.Color.rgb(0.15, 0.15, 0.17),
            .corner_radius = 8,
        }, .{
            ui.text("SVG Icons:", .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.55),
            }),

            // Row of navigation icons
            ui.hstack(.{ .gap = 16, .alignment = .center }, .{
                Svg{ .path = Icons.menu, .size = 24, .color = ui.Color.rgb(0.9, 0.9, 0.95) },
                Svg{ .path = Icons.arrow_back, .size = 24, .color = ui.Color.rgb(0.9, 0.9, 0.95) },
                Svg{ .path = Icons.arrow_forward, .size = 24, .color = ui.Color.rgb(0.9, 0.9, 0.95) },
                Svg{ .path = Icons.close, .size = 24, .color = ui.Color.rgb(0.9, 0.9, 0.95) },
                Svg{ .path = Icons.more_vert, .size = 24, .color = ui.Color.rgb(0.9, 0.9, 0.95) },
            }),

            // Row of action icons with colors
            ui.hstack(.{ .gap = 16, .alignment = .center }, .{
                Svg{ .path = Icons.add, .size = 24, .color = ui.Color.rgb(0.3, 0.8, 0.3) },
                Svg{ .path = Icons.remove, .size = 24, .color = ui.Color.rgb(0.8, 0.3, 0.3) },
                Svg{ .path = Icons.check, .size = 24, .color = ui.Color.rgb(0.3, 0.8, 0.3) },
                Svg{ .path = Icons.edit, .size = 24, .color = ui.Color.rgb(0.3, 0.5, 1.0) },
                Svg{ .path = Icons.delete, .size = 24, .color = ui.Color.rgb(0.8, 0.3, 0.3) },
                Svg{ .path = Icons.search, .size = 24, .color = ui.Color.rgb(0.7, 0.7, 0.75) },
            }),

            // Row of status icons
            ui.hstack(.{ .gap = 16, .alignment = .center }, .{
                Svg{ .path = Icons.star, .size = 24, .color = ui.Color.rgb(1.0, 0.8, 0.0) },
                Svg{ .path = Icons.star_outline, .size = 24, .color = ui.Color.rgb(1.0, 0.8, 0.0) },
                Svg{ .path = Icons.favorite, .size = 24, .color = ui.Color.rgb(1.0, 0.3, 0.4) },
                Svg{ .path = Icons.info, .size = 24, .color = ui.Color.rgb(0.3, 0.6, 1.0) },
                Svg{ .path = Icons.warning, .size = 24, .color = ui.Color.rgb(1.0, 0.7, 0.0) },
                Svg{ .path = Icons.error_icon, .size = 24, .color = ui.Color.rgb(0.9, 0.3, 0.3) },
            }),

            // Row of media icons
            ui.hstack(.{ .gap = 16, .alignment = .center }, .{
                Svg{ .path = Icons.play, .size = 24, .color = ui.Color.rgb(0.3, 0.8, 0.5) },
                Svg{ .path = Icons.pause, .size = 24, .color = ui.Color.rgb(0.8, 0.8, 0.85) },
                Svg{ .path = Icons.skip_prev, .size = 24, .color = ui.Color.rgb(0.8, 0.8, 0.85) },
                Svg{ .path = Icons.skip_next, .size = 24, .color = ui.Color.rgb(0.8, 0.8, 0.85) },
                Svg{ .path = Icons.volume_up, .size = 24, .color = ui.Color.rgb(0.8, 0.8, 0.85) },
            }),

            // Different sizes
            ui.hstack(.{ .gap = 20, .alignment = .center }, .{
                Svg{ .path = Icons.star, .size = 16, .color = ui.Color.rgb(1.0, 0.8, 0.0) },
                Svg{ .path = Icons.star, .size = 24, .color = ui.Color.rgb(1.0, 0.8, 0.0) },
                Svg{ .path = Icons.star, .size = 32, .color = ui.Color.rgb(1.0, 0.8, 0.0) },
                Svg{ .path = Icons.star, .size = 48, .color = ui.Color.rgb(1.0, 0.8, 0.0) },
            }),

            // Stroked icons
            ui.hstack(.{ .gap = 16, .alignment = .center }, .{
                ui.text("Stroked:", .{ .size = 12, .color = ui.Color.rgb(0.5, 0.5, 0.55) }),
                Svg{ .path = Icons.star_outline, .size = 24, .no_fill = true, .stroke_color = ui.Color.rgb(1.0, 0.8, 0.0), .stroke_width = 1.5 },
                Svg{ .path = Icons.favorite, .size = 24, .no_fill = true, .stroke_color = ui.Color.rgb(1.0, 0.3, 0.4), .stroke_width = 1.5 },
                Svg{ .path = Icons.folder, .size = 24, .no_fill = true, .stroke_color = ui.Color.rgb(0.3, 0.6, 1.0), .stroke_width = 1.5 },
            }),
        }));
    }
};
