//! Liquid Glass Effect Demo
//!
//! Demonstrates the liquid glass transparency effect available on macOS 26.0+ (Tahoe).
//! On older macOS versions, falls back to traditional background blur.
//!
//! Run with: zig build run-glass

const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;
const Color = ui.Color;

const AppState = struct {
    glass_style: GlassStyle = .glass_regular,
    opacity: f32 = 0.7,
    corner_radius: f32 = 10.0,

    const GlassStyle = enum {
        none,
        blur,
        glass_regular,
        glass_clear,

        pub fn name(self: GlassStyle) []const u8 {
            return switch (self) {
                .none => "None (opaque)",
                .blur => "Traditional Blur",
                .glass_regular => "Liquid Glass (Regular)",
                .glass_clear => "Liquid Glass (Clear)",
            };
        }

        pub fn next(self: GlassStyle) GlassStyle {
            return switch (self) {
                .none => .blur,
                .blur => .glass_regular,
                .glass_regular => .glass_clear,
                .glass_clear => .none,
            };
        }
    };

    /// Command method - needs Gooey access to change window glass
    pub fn cycleStyleCmd(self: *AppState, g: *gooey.Gooey) void {
        self.glass_style = self.glass_style.next();

        // g.window is already *Window, no cast needed!
        const win_style: gooey.platform.Window.GlassStyle = switch (self.glass_style) {
            .none => .none,
            .blur => .blur,
            .glass_regular => .glass_regular,
            .glass_clear => .glass_clear,
        };
        if (g.window) |w| {
            w.setGlassStyle(win_style, self.opacity, self.corner_radius);
        }
    }

    pub fn increaseRadius(self: *AppState) void {
        self.corner_radius = @min(50.0, self.corner_radius + 5.0);
    }

    pub fn decreaseRadius(self: *AppState) void {
        self.corner_radius = @max(0.0, self.corner_radius - 5.0);
    }
};

// Colors
const text_color = Color.rgba(1, 1, 1, 0.95);
const text_muted = Color.rgba(1, 1, 1, 0.6);
const card_bg = Color.rgba(1, 1, 1, 0.1);

pub fn main() !void {
    var state = AppState{};

    try gooey.runCx(AppState, &state, render, .{
        .title = "Glass Demo",
        .width = 600,
        .height = 400,
        // Dark background color - RGB values become the glass tint
        .background_color = gooey.Color.init(0.1, 0.1, 0.15, 1.0),
        // How opaque the tint is (0.0-1.0)
        .background_opacity = 0.2,
        // Request liquid glass
        .glass_style = .glass_regular,
        .glass_corner_radius = 10.0, // Try 10 to match typical window corners
        .titlebar_transparent = true,
        .full_size_content = false,
    });
}

fn render(cx: *Cx) void {
    const size = cx.windowSize();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 24 },
        .direction = .column,
        .gap = 16,
    }, .{
        // Title
        ui.text("Glass Demo", .{
            .size = 28,
            .color = text_color,
        }),

        // Subtitle
        ui.text("Transparent window with glass effect", .{
            .size = 14,
            .color = text_muted,
        }),

        ui.spacer(),

        // Use component structs for nested layouts!
        StyleDisplay{},
        StyleControls{},

        ui.spacer(),

        // Info text
        ui.text("Note: Liquid Glass requires macOS 26.0+ (Tahoe)", .{
            .size = 11,
            .color = text_muted,
        }),
    }));
}

const StyleDisplay = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .padding = .{ .all = 16 },
            .corner_radius = 12,
            .background = card_bg,
            .direction = .column,
            .gap = 8,
        }, .{
            ui.textFmt("Style: {s}", .{s.glass_style.name()}, .{
                .size = 16,
                .color = text_color,
            }),
            ui.textFmt("Opacity: {d:.0}%", .{s.opacity * 100}, .{
                .size = 14,
                .color = text_muted,
            }),
            ui.textFmt("Corner Radius: {d:.0}pt", .{s.corner_radius}, .{
                .size = 14,
                .color = text_muted,
            }),
        }));
    }
};

const StyleControls = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.hstack(.{ .gap = 8 }, .{
            Button{
                .label = "Cycle Style",
                .on_click_handler = cx.command(AppState, AppState.cycleStyleCmd),
            },
        }));
    }
};
