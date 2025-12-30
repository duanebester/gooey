//! Linux Demo - Interactive demo with Wayland + Vulkan
//!
//! This demo shows the basic usage of gooey on Linux:
//! - Create a Wayland window
//! - Render colored quads using direct Vulkan
//! - Handle input events (mouse, keyboard, scroll)
//! - Interactive quad that follows the mouse

const std = @import("std");
const gooey = @import("gooey");

const platform = gooey.platform;
const Platform = platform.Platform;
const Window = platform.Window;
const Scene = gooey.Scene;
const Quad = gooey.Quad;
const Shadow = gooey.Shadow;
const Hsla = gooey.Hsla;
const Corners = gooey.Corners;
const Edges = gooey.Edges;
const Color = gooey.Color;
const input = gooey.input;

/// Application state
const AppState = struct {
    allocator: std.mem.Allocator,
    scene: Scene,

    // Interactive cursor quad
    cursor_x: f64 = 400,
    cursor_y: f64 = 300,
    cursor_hue: f32 = 0.0,

    // Mouse state
    mouse_down: bool = false,
    click_count: u32 = 0,

    // Scroll offset
    scroll_offset_y: f64 = 0,

    pub fn init(allocator: std.mem.Allocator) !AppState {
        var scene = Scene.init(allocator);

        // Add static background quads
        try addStaticQuads(&scene);

        return .{
            .allocator = allocator,
            .scene = scene,
        };
    }

    pub fn deinit(self: *AppState) void {
        self.scene.deinit();
    }

    fn addStaticQuads(scene: *Scene) !void {
        // Red quad - top left
        try scene.insertQuad(Quad.rounded(50, 50, 200, 150, Hsla.init(0.0, 0.8, 0.5, 1.0), 12));

        // Green quad - top right
        try scene.insertQuad(Quad.rounded(300, 50, 200, 150, Hsla.init(0.33, 0.8, 0.5, 1.0), 12));

        // Blue quad - bottom left
        try scene.insertQuad(Quad.rounded(50, 250, 200, 150, Hsla.init(0.66, 0.8, 0.5, 1.0), 12));

        // Purple quad - bottom right (with border)
        try scene.insertQuad(
            Quad.rounded(300, 250, 200, 150, Hsla.init(0.8, 0.7, 0.5, 1.0), 12)
                .withBorder(Hsla.init(0.8, 0.9, 0.7, 1.0), 3),
        );

        // Central overlapping quad with shadow
        try scene.insertShadow(
            Shadow.drop(200, 175, 200, 150, 20)
                .withColor(Hsla.init(0, 0, 0, 0.4))
                .withOffset(5, 5)
                .withCornerRadius(16),
        );

        try scene.insertQuad(Quad.rounded(200, 175, 200, 150, Hsla.init(0.5, 0.9, 0.95, 1.0), 16));
    }

    pub fn rebuildScene(self: *AppState) void {
        self.scene.clear();

        // Re-add static quads
        addStaticQuads(&self.scene) catch return;

        // Add interactive cursor quad
        const size: f32 = if (self.mouse_down) 60 else 40;
        const lightness: f32 = if (self.mouse_down) 0.7 else 0.5;

        // Apply scroll offset to Y position
        const adjusted_y = self.cursor_y + self.scroll_offset_y;

        self.scene.insertShadow(
            Shadow.drop(
                @as(f32, @floatCast(self.cursor_x)) - size / 2,
                @as(f32, @floatCast(adjusted_y)) - size / 2,
                size,
                size,
                12,
            )
                .withColor(Hsla.init(0, 0, 0, 0.3))
                .withOffset(3, 3)
                .withCornerRadius(size / 2),
        ) catch return;

        self.scene.insertQuad(
            Quad.rounded(
                @as(f32, @floatCast(self.cursor_x)) - size / 2,
                @as(f32, @floatCast(adjusted_y)) - size / 2,
                size,
                size,
                Hsla.init(self.cursor_hue, 0.9, lightness, 1.0),
                size / 2, // Make it a circle
            ).withBorder(Hsla.init(self.cursor_hue, 0.9, 0.9, 1.0), 2),
        ) catch return;

        // Finalize scene
        self.scene.finish();
    }
};

/// Input event handler callback
fn handleInput(window: *Window, event: input.InputEvent) bool {
    const state = window.getUserData(AppState) orelse return false;

    switch (event) {
        .mouse_moved, .mouse_dragged => |m| {
            state.cursor_x = m.position.x;
            state.cursor_y = m.position.y;
            // Slowly rotate hue while moving
            state.cursor_hue = @mod(state.cursor_hue + 0.002, 1.0);
            return false; // Don't consume - let platform handle drag
        },

        .mouse_down => |m| {
            state.mouse_down = true;
            state.click_count = m.click_count;
            std.debug.print("Mouse down at ({d:.1}, {d:.1}) - click count: {d}\n", .{
                m.position.x,
                m.position.y,
                m.click_count,
            });

            // Triple-click resets scroll offset
            if (m.click_count >= 3) {
                state.scroll_offset_y = 0;
                std.debug.print("Triple-click! Scroll offset reset.\n", .{});
            }
            return false;
        },

        .mouse_up => {
            state.mouse_down = false;
            return false;
        },

        .mouse_entered => {
            std.debug.print("Mouse entered window\n", .{});
            return false;
        },

        .mouse_exited => {
            std.debug.print("Mouse exited window\n", .{});
            return false;
        },

        .scroll => |s| {
            state.scroll_offset_y += s.delta.y * 0.5;
            std.debug.print("Scroll: delta=({d:.1}, {d:.1}), offset_y={d:.1}\n", .{
                s.delta.x,
                s.delta.y,
                state.scroll_offset_y,
            });
            return true;
        },

        .key_down => |k| {
            const key_name = @tagName(k.key);
            std.debug.print("Key down: {s} (repeat={s})\n", .{
                key_name,
                if (k.is_repeat) "yes" else "no",
            });

            // Handle escape key
            if (k.key == .escape) {
                std.debug.print("Escape pressed - closing window\n", .{});
                // Don't consume - let platform close the window
                return false;
            }

            // Space resets cursor position
            if (k.key == .space) {
                state.cursor_x = 400;
                state.cursor_y = 300;
                state.scroll_offset_y = 0;
                std.debug.print("Space pressed - position reset\n", .{});
                return true;
            }

            // Arrow keys move cursor
            const move_amount: f64 = if (k.modifiers.shift) 20 else 5;
            switch (k.key) {
                .left => {
                    state.cursor_x -= move_amount;
                    return true;
                },
                .right => {
                    state.cursor_x += move_amount;
                    return true;
                },
                .up => {
                    state.cursor_y -= move_amount;
                    return true;
                },
                .down => {
                    state.cursor_y += move_amount;
                    return true;
                },
                else => {},
            }

            return false;
        },

        .key_up => |k| {
            const key_name = @tagName(k.key);
            std.debug.print("Key up: {s}\n", .{key_name});
            return false;
        },

        .modifiers_changed => |m| {
            if (m.shift or m.ctrl or m.alt or m.cmd) {
                std.debug.print("Modifiers: shift={s} ctrl={s} alt={s} cmd={s}\n", .{
                    if (m.shift) "yes" else "no",
                    if (m.ctrl) "yes" else "no",
                    if (m.alt) "yes" else "no",
                    if (m.cmd) "yes" else "no",
                });
            }
            return false;
        },

        .text_input => |t| {
            // IME committed text - final text from input method
            std.debug.print("IME Text Input: \"{s}\"\n", .{t.text});
            return true;
        },

        .composition => |c| {
            // IME composition (preedit) - text being composed
            if (c.text.len > 0) {
                std.debug.print("IME Composition: \"{s}\" (composing)\n", .{c.text});
            } else {
                std.debug.print("IME Composition: (ended)\n", .{});
            }
            return true;
        },
    }
}

/// Render callback - called each frame before drawing
fn handleRender(window: *Window) void {
    const state = window.getUserData(AppState) orelse return;
    state.rebuildScene();
    window.setScene(&state.scene);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Initializing Linux platform...\n", .{});

    // Initialize platform
    var plat = try Platform.init();
    defer plat.deinit();

    // Set up listeners now that plat is at its final memory location
    try plat.setupListeners();

    std.debug.print("Platform initialized. Creating window...\n", .{});

    // Create window
    var window = try Window.init(allocator, &plat, .{
        .title = "Gooey Linux Demo - Input Events",
        .width = 800,
        .height = 600,
        .background_color = Color.init(0.1, 0.1, 0.15, 1.0),
    });
    defer window.deinit();

    // Register window with platform for client-side move/resize handling
    plat.setActiveWindow(window);

    std.debug.print("Window created. Setting up application state...\n", .{});

    // Create application state
    var state = try AppState.init(allocator);
    defer state.deinit();

    // Set up input and render callbacks
    window.setUserData(&state);
    window.setInputCallback(handleInput);
    window.setRenderCallback(handleRender);

    // Initial scene build
    state.rebuildScene();
    window.setScene(&state.scene);
    window.requestRender();

    std.debug.print("Scene ready. Running event loop...\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("=== CONTROLS ===\n", .{});
    std.debug.print("  Mouse move        - Cursor follows mouse\n", .{});
    std.debug.print("  Mouse click       - Cursor grows (shows click count)\n", .{});
    std.debug.print("  Triple-click      - Reset scroll offset\n", .{});
    std.debug.print("  Scroll wheel      - Offset cursor vertically\n", .{});
    std.debug.print("  Arrow keys        - Move cursor (Shift = faster)\n", .{});
    std.debug.print("  Space             - Reset cursor position\n", .{});
    std.debug.print("  Drag top 32px     - Move window\n", .{});
    std.debug.print("  Drag edges (8px)  - Resize window\n", .{});
    std.debug.print("  Escape            - Close window\n", .{});
    std.debug.print("  Ctrl+Q            - Close window\n", .{});
    std.debug.print("  Alt+F4            - Close window\n", .{});
    std.debug.print("  IME input         - Supported (text_input_v3)\n", .{});
    std.debug.print("================\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("NOTE: Window uses client-side decorations (no title bar from compositor).\n", .{});
    std.debug.print("\n", .{});

    // Run the event loop
    // Use blocking dispatch to properly receive all Wayland events including keyboard
    while (plat.isRunning() and !window.isClosed()) {
        // Render frame first (handles any pending redraws)
        window.renderFrame();

        // Flush outgoing requests to server
        plat.flush();

        // Block and wait for Wayland events (keyboard, pointer, frame callbacks, etc.)
        // This is essential - poll() alone won't read new events from the socket
        if (!plat.dispatch()) break;
    }

    std.debug.print("Shutting down...\n", .{});
}
