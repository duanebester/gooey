//! Windows Demo - the platform layer alone: a Win32 window drawn with Vulkan.
//!
//! Exercises the Windows backend without the text system, which has no
//! Windows implementation yet: a few static quads, a circle that follows the
//! pointer, a box that animates through timed redraws, and resize, DPI, and
//! close handling. Every input event is logged.
//!
//! Controls: move and click the mouse, scroll the wheel, press arrow keys to
//! nudge the circle, Space to reset it, and Escape or Alt+F4 to close.

const std = @import("std");
const gooey = @import("gooey");

const platform = gooey.platform;
const Platform = platform.Platform;
const PlatformWindow = platform.PlatformWindow;
const Scene = gooey.scene.Scene;
const Quad = gooey.scene.Quad;
const Shadow = gooey.scene.Shadow;
const Hsla = gooey.scene.Hsla;
const input = gooey.input;

const limits = gooey.ResourceLimits.nano;

/// Timed-redraw interval for the animated box: about 60 frames per second.
const animation_frame_ms: u32 = 16;
/// Length of one full sweep of the animated box.
const animation_period_ms: i64 = 4_000;

const DemoState = struct {
    scene: Scene,
    start_ms: i64,
    cursor_x: f64 = 400,
    cursor_y: f64 = 300,
    cursor_hue: f32 = 0.55,
    mouse_down: bool = false,

    fn rebuildScene(self: *DemoState, window: *PlatformWindow) void {
        const size = window.getSize();
        self.scene.clear();
        self.scene.setViewport(@floatCast(size.width), @floatCast(size.height));
        self.addStaticQuads() catch |err| return logSceneFull(err);
        self.addAnimatedBox(window, @floatCast(size.width)) catch |err| return logSceneFull(err);
        self.addCursor() catch |err| return logSceneFull(err);
        self.scene.finish();
    }

    fn addStaticQuads(self: *DemoState) !void {
        const quads = [_]Quad{
            Quad.rounded(50, 50, 200, 150, Hsla.init(0.0, 0.8, 0.5, 1.0), 12),
            Quad.rounded(300, 50, 200, 150, Hsla.init(0.33, 0.8, 0.5, 1.0), 12),
            Quad.rounded(50, 250, 200, 150, Hsla.init(0.66, 0.8, 0.5, 1.0), 12),
            Quad.rounded(300, 250, 200, 150, Hsla.init(0.8, 0.7, 0.5, 1.0), 12)
                .withBorder(Hsla.init(0.8, 0.9, 0.7, 1.0), 3),
        };
        for (quads) |quad| try self.scene.insertQuad(quad);
        try self.scene.insertShadow(Shadow.drop(200, 175, 200, 150, 20)
            .withColor(Hsla.init(0, 0, 0, 0.4))
            .withOffset(5, 5)
            .withCornerRadius(16));
        const center_color = Hsla.init(0.5, 0.9, 0.95, 1.0);
        try self.scene.insertQuad(Quad.rounded(200, 175, 200, 150, center_color, 16));
    }

    /// A box that sweeps across the bottom of the window. Re-arms its own
    /// redraw, so it keeps moving without input.
    fn addAnimatedBox(self: *DemoState, window: *PlatformWindow, width: f32) !void {
        const elapsed_ms = platform.backend.platform.nowMilliseconds() - self.start_ms;
        const phase: f32 = @floatFromInt(@mod(elapsed_ms, animation_period_ms));
        const t = phase / @as(f32, @floatFromInt(animation_period_ms));
        const sweep = 0.5 - 0.5 * @cos(t * 2 * std.math.pi);
        const box_size: f32 = 48;
        const x = 24 + sweep * @max(0, width - box_size - 48);
        const color = Hsla.init(t, 0.8, 0.6, 1.0);
        try self.scene.insertQuad(Quad.rounded(x, 440, box_size, box_size, color, 8));
        window.requestRenderAfter(animation_frame_ms);
    }

    fn addCursor(self: *DemoState) !void {
        const size: f32 = if (self.mouse_down) 60 else 40;
        const lightness: f32 = if (self.mouse_down) 0.7 else 0.5;
        const x = @as(f32, @floatCast(self.cursor_x)) - size / 2;
        const y = @as(f32, @floatCast(self.cursor_y)) - size / 2;
        try self.scene.insertShadow(Shadow.drop(x, y, size, size, 12)
            .withColor(Hsla.init(0, 0, 0, 0.3))
            .withOffset(3, 3)
            .withCornerRadius(size / 2));
        const fill = Hsla.init(self.cursor_hue, 0.9, lightness, 1.0);
        try self.scene.insertQuad(Quad.rounded(x, y, size, size, fill, size / 2)
            .withBorder(Hsla.init(self.cursor_hue, 0.9, 0.9, 1.0), 2));
    }
};

fn logSceneFull(err: anyerror) void {
    std.log.err("windows-demo: scene budget exhausted: {t}", .{err});
}

fn handleInput(window: *PlatformWindow, event: input.InputEvent) bool {
    const state = window.getUserData(DemoState) orelse return false;
    switch (event) {
        .mouse_moved, .mouse_dragged, .mouse_entered => |mouse| {
            state.cursor_x = mouse.position.x;
            state.cursor_y = mouse.position.y;
            state.cursor_hue = @mod(state.cursor_hue + 0.002, 1.0);
            return false;
        },
        .mouse_down => |mouse| {
            state.mouse_down = true;
            std.debug.print("mouse down {t} at ({d:.1}, {d:.1}), click {d}\n", .{
                mouse.button, mouse.position.x, mouse.position.y, mouse.click_count,
            });
        },
        .mouse_up => state.mouse_down = false,
        .mouse_exited => std.debug.print("mouse exited\n", .{}),
        .scroll => |scroll| {
            state.cursor_y += scroll.delta.y;
            std.debug.print("scroll ({d:.1}, {d:.1})\n", .{ scroll.delta.x, scroll.delta.y });
        },
        .key_down => |key| return handleKey(window, state, key),
        .text_input => |text| std.debug.print("text \"{s}\"\n", .{text.text}),
        else => {},
    }
    return true;
}

fn handleKey(window: *PlatformWindow, state: *DemoState, key: input.KeyEvent) bool {
    std.debug.print("key down {t}{s}\n", .{ key.key, if (key.is_repeat) " (repeat)" else "" });
    const step: f64 = if (key.modifiers.shift) 20 else 5;
    switch (key.key) {
        .escape => window.close(),
        .space => {
            state.cursor_x = 400;
            state.cursor_y = 300;
        },
        .left => state.cursor_x -= step,
        .right => state.cursor_x += step,
        .up => state.cursor_y -= step,
        .down => state.cursor_y += step,
        else => return false,
    }
    return true;
}

fn handleRender(window: *PlatformWindow) void {
    const state = window.getUserData(DemoState) orelse return;
    state.rebuildScene(window);
    window.setScene(&state.scene);
}

fn handleResize(window: *PlatformWindow, width: f64, height: f64) void {
    std.debug.print("resized to {d:.0}x{d:.0} logical at scale {d:.2}\n", .{
        width, height, window.getScaleFactor(),
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var plat: Platform = undefined;
    try plat.initInPlace(allocator);
    defer plat.deinit();

    const window_options: platform.WindowOptions = .{
        .title = "Gooey Windows Demo",
        .width = 800,
        .height = 600,
        .min_size = .{ .width = 320, .height = 240 },
        .background_color = gooey.Color.rgba(0.1, 0.1, 0.15, 1.0),
        .limits = limits,
    };
    const window = try PlatformWindow.init(allocator, &plat, &window_options);
    defer window.deinit();

    var state = DemoState{
        .scene = try Scene.initCapacity(allocator, &limits.scene),
        .start_ms = platform.backend.platform.nowMilliseconds(),
    };
    defer state.scene.deinit();

    window.setUserData(&state);
    window.setInputCallback(handleInput);
    window.setRenderCallback(handleRender);
    window.setResizeCallback(handleResize);
    window.requestRender();

    std.debug.print("{s} on {s}: {d}x{d} logical at scale {d:.2}\n", .{
        Platform.capabilities.name,
        Platform.capabilities.graphics_backend,
        window.width(),
        window.height(),
        window.getScaleFactor(),
    });
    plat.run();
    std.debug.print("window closed; shutting down\n", .{});
}
