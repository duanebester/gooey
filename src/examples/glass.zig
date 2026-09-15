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
const Button = gooey.components.Button;
const Color = ui.Color;

const AppState = struct {
    glass_style: GlassStyle = .glass_regular,
    opacity: f32 = 0.7,
    corner_radius: f32 = 10.0,

    // The window style is the framework's canonical `platform.GlassStyle`.
    // This example used to declare its own four-variant copy and then remap it
    // to the backend's enum in `cycleStyleCmd`; with one shared enum there is
    // nothing to remap.
    const GlassStyle = gooey.platform.GlassStyle;

    fn styleName(style: GlassStyle) []const u8 {
        return switch (style) {
            .none => "None (opaque)",
            .blur => "Traditional Blur",
            .glass_regular => "Liquid Glass (Regular)",
            .glass_clear => "Liquid Glass (Clear)",
            .vibrancy => "Vibrancy (web only)",
        };
    }

    /// Advance to the next style, skipping any the backend cannot render.
    ///
    /// `vibrancy` is a browser `backdrop-filter` effect with no AppKit
    /// counterpart, so cycling into it on macOS would show an unchanged window
    /// and read as a bug. Skipping it is the honest behaviour.
    fn nextStyle(style: GlassStyle) GlassStyle {
        const order = [_]GlassStyle{ .none, .blur, .glass_regular, .glass_clear, .vibrancy };
        const current = std.mem.indexOfScalar(GlassStyle, &order, style) orelse 0;

        var step: usize = 1;
        while (step <= order.len) : (step += 1) {
            const candidate = order[(current + step) % order.len];
            if (candidate != .vibrancy or gooey.platform.is_wasm) return candidate;
        }
        unreachable; // `.none` is always renderable, so the loop always returns.
    }

    /// Command method - needs Window access to change window glass.
    ///
    /// `Cx.command` hands the callback a `*gooey.Window`, not a `*Cx`, so this
    /// cannot route through `Cx.setGlassStyle` and must repeat that method's
    /// comptime capability gate. Without the gate the body reaches
    /// `PlatformWindow.setGlassStyle`, which does not exist on backends where
    /// `capabilities.glass_effects` is false — the example then fails to
    /// compile for Linux even though it can never run there.
    pub fn cycleStyleCmd(self: *AppState, g: *gooey.Window) void {
        if (comptime !gooey.platform.Platform.capabilities.glass_effects) return;

        self.glass_style = nextStyle(self.glass_style);

        // PR 7b.1b — `g.window` (the OS-level handle field on the
        // framework wrapper) was renamed to `g.platform_window` so the
        // wrapper struct itself could claim the name `Window`. The
        // captured `w` is still a `*PlatformWindow`.
        if (g.platform_window) |w| {
            w.setGlassStyle(self.glass_style, self.opacity, self.corner_radius);
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

pub fn main(init: std.process.Init) !void {
    var state = AppState{};

    try gooey.run(AppState, &state, render, .{
        .title = "Glass Demo",
        .width = 600,
        .height = 400,
        // Dark background color - RGB values become the glass tint
        .background_color = gooey.Color.rgba(0.1, 0.1, 0.15, 1.0),
        // How opaque the tint is (0.0-1.0)
        .background_opacity = 0.2,
        // Request liquid glass
        .glass_style = .glass_regular,
        .glass_corner_radius = 10.0, // Try 10 to match typical window corners
        .titlebar_transparent = true,
        .full_size_content = false,
    }, init);
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
            ui.textFmt("Style: {s}", .{AppState.styleName(s.glass_style)}, .{
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
                .on_click_handler = cx.command(AppState.cycleStyleCmd),
            },
        }));
    }
};
