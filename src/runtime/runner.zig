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
//! - Window instance (layout, scene, widgets)
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
const window_mod = @import("../context/window.zig");
const FontConfig = window_mod.FontConfig;

// PR 7b.3 — `App` owns application-lifetime state shared across
// windows. The single-window flow heap-allocates one `App` here in
// `runCx` and hands `*App` to the `WindowContext`. Pre-7b.3 the
// entity map lived as a per-window field on `Window`; lifting it
// onto `App` is the precondition for cross-window observation,
// even though the single-window flow has only one borrower. See
// `docs/cleanup-implementation-plan.md` PR 7b.3.
const app_mod = @import("../context/app.zig");
const App = app_mod.App;

// Runtime imports
const window_context = @import("window_context.zig");

const Platform = platform.Platform;
// PR 7b.1a — `platform.Window` renamed to `platform.PlatformWindow`
// to free up the `Window` name for the framework-level wrapper
// landing in PR 7b.1b. See `src/platform/mod.zig` for the rationale.
const PlatformWindow = platform.PlatformWindow;
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
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
    const bg_color = config.background_color orelse geometry_mod.Color.rgba(0.95, 0.95, 0.95, 1.0);

    // Create window
    var window = try PlatformWindow.init(allocator, &plat, .{
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

    // Resolve IO: use caller-provided instance or fall back to global single-threaded.
    const io = config.io orelse std.Io.Threaded.global_single_threaded.io();

    // PR 7b.3 — heap-allocate an `App` and hand `*App` to the
    // window. The single-window flow has exactly one borrower
    // today, but going through `App` keeps the call chain
    // identical to the multi-window path (`multi_window_app.zig`)
    // and makes the future runner consolidation in a later 7b
    // slice a no-op for entity ownership.
    //
    // Defer order matters: `win_ctx.deinit()` (and the
    // `window.deinit()` inside it) must run BEFORE
    // `app.deinit()` so any cancel-group teardown driven by
    // `Window` close still has a live `EntityMap` to walk —
    // but `Window.deinit` was rewritten in 7b.3 to NOT touch
    // `self.app`, so the strict ordering matters less than the
    // ownership story. We still order the defers so the `App`
    // outlives the `Window` for safety.
    const app_ptr = try allocator.create(App);
    defer allocator.destroy(app_ptr);
    // PR 7b.4 — `App.initInPlace` returns `!void` now (was `void`)
    // because it registers an owned `Keymap` in `app.globals`,
    // and `Globals.setOwned` may fail with `OutOfMemory`. The
    // `defer allocator.destroy(app_ptr)` above runs even on the
    // error path, so a failure here doesn't leak the
    // `allocator.create(App)` allocation.
    try app_ptr.initInPlace(allocator, io);
    defer app_ptr.deinit();

    // Create per-window context (replaces static CallbackState)
    const WinCtx = window_context.WindowContext(State);
    const win_ctx = try WinCtx.init(allocator, window, state, render, .{
        .font_name = config.font,
        .font_size = config.font_size,
    }, app_ptr, io);
    defer win_ctx.deinit();

    // Set user callbacks
    win_ctx.setCallbacks(config.on_event, config.on_close, config.on_resize);

    // Set root state on this window's Window instance (not globally)
    // This enables multi-window support where each window has its own state
    win_ctx.window.setRootState(State, state);
    defer win_ctx.window.clearRootState();

    // Connect WindowContext to window (sets user_data and callbacks)
    win_ctx.setupWindow(window);

    // Call user init callback if provided (after full setup, before first frame)
    if (config.on_init) |init_fn| {
        init_fn(win_ctx.getCx());
    }

    // Run the event loop
    plat.run();
}

/// Configuration for runCx()
pub fn CxConfig(comptime State: type) type {
    _ = State; // State type captured for type safety
    const shader_mod = @import("../core/shader.zig");

    return struct {
        title: []const u8 = "Window App",
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

        /// Called once after platform, window, and Window context are initialized,
        /// before the first render. Use for one-time setup (HTTP clients, API keys, etc.)
        on_init: ?*const fn (*Cx) void = null,

        /// Optional event handler for raw input events
        on_event: ?*const fn (*Cx, InputEvent) bool = null,

        /// Called when window is about to close. Return false to prevent close.
        on_close: ?*const fn (*Cx) bool = null,

        /// Called when window size changes (width, height in logical pixels)
        on_resize: ?*const fn (*Cx, f64, f64) void = null,

        /// Font family name (e.g., "Inter", "JetBrains Mono").
        /// When null, uses the platform's default sans-serif font.
        font: ?[]const u8 = null,

        /// Default font size in points.
        font_size: f32 = 16.0,

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

        /// IO interface for async work (filesystem, network, concurrency).
        /// When null, falls back to `std.Io.Threaded.global_single_threaded`.
        io: ?std.Io = null,
    };
}
