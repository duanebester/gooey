//! Image Example
//!
//! Demonstrates the Image component with various styling options:
//! - Basic image loading from file
//! - Sizing (explicit, uniform, fit modes)
//! - Corner radius and rounded images
//! - Tinting and grayscale effects
//! - Opacity

const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;

const Color = gooey.Color;
const Cx = gooey.Cx;

const AppState = struct {
    hovered_index: ?usize = null,
};

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Image Component Example",
    .width = 900,
    .height = 700,
    .background_color = Color.fromHex("#1a1a2e"),
});

fn render(cx: *Cx) void {
    cx.box(.{
        .padding = .{ .all = 24 },
        .gap = 16,
        .background = Color.fromHex("#1a1a2e"),
    }, .{
        ui.text("Image Component Demo", .{
            .size = 24,
            .color = Color.white,
            .weight = .bold,
        }),
        ScrollContent{},
    });
}

// =============================================================================
// Scroll Container
// =============================================================================

const ScrollContent = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.scroll("images_scroll", .{
            .width = 852,
            .height = 610,
            .background = Color.fromHex("#1a1a2e"),
            .padding = .{ .all = 4 },
            .gap = 24,
            .content_height = 900,
            .track_color = Color.fromHex("#16213e"),
            .thumb_color = Color.fromHex("#4a4a6a"),
        }, .{
            SectionSizing{},
            SectionFitModes{},
            SectionCornerRadius{},
            SectionEffects{},
        });
    }
};

// =============================================================================
// Section: Sizing
// =============================================================================

const SectionSizing = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 12, .fill_width = true }, .{
            ui.text("Sizing", .{
                .size = 16,
                .color = Color.fromHex("#888888"),
                .weight = .medium,
            }),
            SizingRow{},
        });
    }
};

const SizingRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
            .direction = .row,
            .gap = 16,
            .padding = .{ .all = 16 },
            .background = Color.fromHex("#16213e"),
            .corner_radius = 8,
        }, .{
            SizeItem{ .size = 32, .label = "32x32" },
            SizeItem{ .size = 64, .label = "64x64" },
            SizeItem{ .size = 128, .label = "128x128" },
            CustomSizeItem{},
        });
    }
};

const SizeItem = struct {
    size: f32,
    label: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .size = self.size,
            },
            ui.text(self.label, .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

const CustomSizeItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .width = 200,
                .height = 80,
            },
            ui.text("200x80", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

// =============================================================================
// Section: Object Fit Modes
// =============================================================================

const SectionFitModes = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 12, .fill_width = true }, .{
            ui.text("Object Fit Modes", .{
                .size = 16,
                .color = Color.fromHex("#888888"),
                .weight = .medium,
            }),
            FitModesRow{},
        });
    }
};

const FitModesRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
            .direction = .row,
            .gap = 16,
            .padding = .{ .all = 16 },
            .background = Color.fromHex("#16213e"),
            .corner_radius = 8,
        }, .{
            FitContainItem{},
            FitCoverItem{},
            FitFillItem{},
            FitNoneItem{},
        });
    }
};

const FitContainItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .width = 100,
                .height = 100,
                .fit = .contain,
            },
            ui.text("contain", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

const FitCoverItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .width = 100,
                .height = 100,
                .fit = .cover,
            },
            ui.text("cover", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

const FitFillItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .width = 100,
                .height = 100,
                .fit = .fill,
            },
            ui.text("fill", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

const FitNoneItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .width = 100,
                .height = 100,
                .fit = .none,
            },
            ui.text("none", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

// =============================================================================
// Section: Corner Radius
// =============================================================================

const SectionCornerRadius = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 12, .fill_width = true }, .{
            ui.text("Corner Radius", .{
                .size = 16,
                .color = Color.fromHex("#888888"),
                .weight = .medium,
            }),
            CornerRadiusRow{},
        });
    }
};

const CornerRadiusRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
            .direction = .row,
            .gap = 16,
            .padding = .{ .all = 16 },
            .background = Color.fromHex("#16213e"),
            .corner_radius = 8,
        }, .{
            RadiusNoneItem{},
            RadiusSmallItem{},
            RadiusLargeItem{},
            RadiusCircleItem{},
        });
    }
};

const RadiusNoneItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .size = 80,
            },
            ui.text("none", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

const RadiusSmallItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .size = 80,
                .corner_radius = 8,
            },
            ui.text("8px", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

const RadiusLargeItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .size = 80,
                .corner_radius = 20,
            },
            ui.text("20px", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

const RadiusCircleItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .size = 80,
                .rounded = true,
            },
            ui.text("circle", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

// =============================================================================
// Section: Visual Effects
// =============================================================================

const SectionEffects = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 12, .fill_width = true }, .{
            ui.text("Visual Effects", .{
                .size = 16,
                .color = Color.fromHex("#888888"),
                .weight = .medium,
            }),
            EffectsRow{},
        });
    }
};

const EffectsRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{
            .direction = .row,
            .gap = 16,
            .padding = .{ .all = 16 },
            .background = Color.fromHex("#16213e"),
            .corner_radius = 8,
        }, .{
            EffectNormalItem{},
            EffectTintItem{},
            EffectGrayscaleItem{},
            EffectPartialGrayItem{},
            EffectOpacityItem{},
            EffectCombinedItem{},
        });
    }
};

const EffectNormalItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .size = 80,
                .corner_radius = 8,
            },
            ui.text("normal", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

const EffectTintItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .size = 80,
                .corner_radius = 8,
                .tint = Color.fromHex("#4488ff"),
            },
            ui.text("tint", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

const EffectGrayscaleItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .size = 80,
                .corner_radius = 8,
                .grayscale = 1.0,
            },
            ui.text("grayscale", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

const EffectPartialGrayItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .size = 80,
                .corner_radius = 8,
                .grayscale = 0.5,
            },
            ui.text("50% gray", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

const EffectOpacityItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .size = 80,
                .corner_radius = 8,
                .opacity = 0.5,
            },
            ui.text("50% opacity", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

const EffectCombinedItem = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            gooey.Image{
                .src = "assets/ziglang_logo.png",
                .size = 80,
                .rounded = true,
                .grayscale = 0.8,
                .tint = Color.fromHex("#ff6644"),
                .opacity = 0.9,
            },
            ui.text("combined", .{ .size = 12, .color = Color.fromHex("#666666") }),
        });
    }
};

pub fn main() !void {
    return App.main();
}
