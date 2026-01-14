//! Runner
//!
//! Platform initialization, window creation, and event loop management.
//! This is the main entry point for running a gooey application.
//!
//! ## Window Lifecycle Callbacks
//!
//! - `on_close`: Called when window is about to close. Return false to prevent.
//! - `on_resize`: Called when window size changes (after resize completes).
//!
//! ## Architecture Notes
//!
//! **Multi-Window Ready**: This implementation uses per-window WindowContext
//! stored in the window's user_data pointer. Each window has its own:
//! - Cx context
//! - Gooey instance (layout, scene, widgets)
//! - Builder instance
//! - User callbacks
//!
//! This enables future multi-window support without changing the callback model.
//!
//! **Frame Budget**: In debug builds, warnings are emitted when frame rendering
//! exceeds 16.67ms (60 FPS budget). This helps identify performance issues early.
//! The first few frames are skipped since initialization is expected to be slow.

const std = @import("std");
const builtin = @import("builtin");

// Platform abstraction
const platform = @import("../platform/mod.zig");
const interface_mod = @import("../platform/interface.zig");

// Core imports
const geometry_mod = @import("../core/geometry.zig");
const input_mod = @import("../input/mod.zig");
const handler_mod = @import("../context/handler.zig");
const cx_mod = @import("../cx.zig");

// Runtime imports
const window_context = @import("window_context.zig");

const Platform = platform.Platform;
const Window = platform.Window;
const Cx = cx_mod.Cx;
const InputEvent = input_mod.InputEvent;

/// Run a gooey application with the Cx context API
///
/// This function initializes the platform, creates a window, sets up the
/// rendering context, and runs the main event loop.
///
/// Each window gets its own WindowContext stored in user_data, enabling
/// future multi-window support.
pub fn runCx(
    comptime State: type,
    state: *State,
    comptime render: fn (*Cx) void,
    config: CxConfig(State),
) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize platform
    var plat = try Platform.init();
    defer plat.deinit();

    // Linux-specific: set up Wayland listeners to get compositor/globals
    if (platform.is_linux) {
        try plat.setupListeners();
    }

    // Default background color
    const bg_color = config.background_color orelse geometry_mod.Color.init(0.95, 0.95, 0.95, 1.0);

    // Create window
    var window = try Window.init(allocator, &plat, .{
        .title = config.title,
        .width = config.width,
        .height = config.height,
        .background_color = bg_color,
        .custom_shaders = config.custom_shaders,
        // Size constraints
        .min_size = config.min_size,
        .max_size = config.max_size,
        .centered = config.centered,
        // Glass/transparency options
        .background_opacity = config.background_opacity,
        .glass_style = @enumFromInt(@intFromEnum(config.glass_style)),
        .glass_corner_radius = config.glass_corner_radius,
        .titlebar_transparent = config.titlebar_transparent,
        .full_size_content = config.full_size_content,
    });
    defer window.deinit();

    // Linux-specific: register window with platform for pointer/input handling
    if (platform.is_linux) {
        plat.setActiveWindow(window);
    }

    // Create per-window context (replaces static CallbackState)
    const WinCtx = window_context.WindowContext(State);
    const win_ctx = try WinCtx.init(allocator, window, state, render);
    defer win_ctx.deinit();

    // Set user callbacks
    win_ctx.setCallbacks(config.on_event, config.on_close, config.on_resize);

    // Set root state on this window's Gooey instance (not globally)
    // This enables multi-window support where each window has its own state
    win_ctx.gooey.setRootState(State, state);
    defer win_ctx.gooey.clearRootState();

    // Connect WindowContext to window (sets user_data and callbacks)
    win_ctx.setupWindow(window);

    // Run the event loop
    plat.run();
}

/// Configuration for runCx()
pub fn CxConfig(comptime State: type) type {
    _ = State; // State type captured for type safety
    const shader_mod = @import("../core/shader.zig");

    return struct {
        title: []const u8 = "Gooey App",
        width: f64 = 800,
        height: f64 = 600,
        background_color: ?geometry_mod.Color = null,

        // Window size constraints

        /// Minimum window size (optional)
        min_size: ?geometry_mod.Size(f64) = null,

        /// Maximum window size (optional)
        max_size: ?geometry_mod.Size(f64) = null,

        /// Start window centered on screen
        centered: bool = true,

        // Event callbacks

        /// Optional event handler for raw input events
        on_event: ?*const fn (*Cx, InputEvent) bool = null,

        /// Called when window is about to close. Return false to prevent close.
        on_close: ?*const fn (*Cx) bool = null,

        /// Called when window size changes (width, height in logical pixels)
        on_resize: ?*const fn (*Cx, f64, f64) void = null,

        /// Custom shaders (cross-platform - MSL for macOS, WGSL for web)
        custom_shaders: []const shader_mod.CustomShader = &.{},

        // Glass/transparency options (macOS only)

        /// Background opacity (0.0 = fully transparent, 1.0 = opaque)
        background_opacity: f32 = 1.0,

        /// Glass blur style
        glass_style: interface_mod.WindowOptions.GlassStyleCompat = .none,

        /// Corner radius for glass effect
        glass_corner_radius: f32 = 16.0,

        /// Make titlebar transparent
        titlebar_transparent: bool = false,

        /// Extend content under titlebar
        full_size_content: bool = false,
    };
}
