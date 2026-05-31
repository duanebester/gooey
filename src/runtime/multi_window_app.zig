//! Multi-Window App - High-level API for managing multiple windows
//!
//! This module provides the `App` struct which enables multi-window applications
//! with shared resources. Each window has its own state and render function,
//! while expensive resources (text system, atlases) are shared.
//!
//! ## Architecture
//!
//! The App struct centralizes:
//! - Platform lifecycle (init/deinit/run)
//! - Window registry (create/close/lookup)
//! - Shared resources (text system, SVG atlas, image atlas)
//! - Quit behavior (quit when last window closes)
//!
//! ## Usage
//!
//! ```zig
//! var app = try App.init(allocator);
//! defer app.deinit();
//!
//! const main_handle = try app.openWindow(MainState, &main_state, mainRender, .{
//!     .title = "Main Window",
//! });
//!
//! // Later, open another window:
//! const dialog_handle = try app.openWindow(DialogState, &dialog_state, dialogRender, .{
//!     .title = "Dialog",
//!     .width = 400,
//!     .height = 300,
//! });
//!
//! app.run();
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// Platform
const platform = @import("../platform/mod.zig");
const Platform = platform.Platform;
// `PlatformWindow` is the OS-level handle; `Window` is the framework wrapper.
const PlatformWindow = platform.PlatformWindow;
const WindowId = platform.WindowId;
const WindowRegistry = platform.WindowRegistry;
const WindowOptions = platform.WindowOptions;

// Core
const geometry = @import("../core/geometry.zig");
const Color = geometry.Color;
const shader_mod = @import("../core/shader.zig");

// Bundle the three "expensive to duplicate per window" resources (text system
// + svg atlas + image atlas) into a single `AppResources` field, owned once on
// `App` and lent as borrowed views to each `Window`. The types are reached
// through `AppResources`, never named directly here.
const app_resources_mod = @import("../context/app_resources.zig");
const AppResources = app_resources_mod.AppResources;

// `context.App` owns application-lifetime state shared across windows
// (entities, keymap, globals, image loader). Embedded by-value below so every
// `Window` borrows `&self.context_app` and reaches the same `EntityMap` — the
// property cross-window observation needs.
const context_app_mod = @import("../context/app.zig");
const ContextApp = context_app_mod.App;

// Runtime
const WindowContext = @import("window_context.zig").WindowContext;
const WindowHandle = @import("window_handle.zig").WindowHandle;

// Context
const cx_mod = @import("../cx.zig");
const Cx = cx_mod.Cx;
const handler_mod = @import("../context/handler.zig");
const window_mod = @import("../context/window.zig");
const FontConfig = window_mod.FontConfig;

// Input
const input_mod = @import("../input/mod.zig");
const InputEvent = input_mod.InputEvent;

// =============================================================================
// Constants (per CLAUDE.md: "put a limit on everything")
// =============================================================================

/// Maximum number of windows an App can manage
pub const MAX_WINDOWS: u32 = WindowRegistry.MAX_WINDOWS;

/// Default window dimensions
const DEFAULT_WIDTH: f64 = 800;
const DEFAULT_HEIGHT: f64 = 600;

// =============================================================================
// App
// =============================================================================

/// Multi-window application manager.
///
/// Owns the platform, window registry, and shared resources.
/// Each window gets its own WindowContext with state and render function.
pub const App = struct {
    /// Memory allocator for app resources
    allocator: Allocator,

    /// Platform instance (event loop, window creation)
    platform: Platform,

    /// Registry of all open windows
    registry: WindowRegistry,

    // =========================================================================
    // Shared Resources (expensive to duplicate per window)
    // =========================================================================

    /// Shared rendering resources owned at app scope. Every per-window `Window`
    /// embeds a borrowed view over the same pointees; `AppResources.deinit`
    /// tears them down once, in `App.deinit`, after the last window closes.
    resources: AppResources,

    /// Application-lifetime state shared across windows (entities, keymap,
    /// globals, image loader). Embedded by-value: `&self.context_app` outlives
    /// every `Window` opened from this app, making models observable across
    /// windows.
    context_app: ContextApp,

    /// IO interface for async work. Threaded through to all windows.
    io: std.Io,

    // =========================================================================
    // App State
    // =========================================================================

    /// Quit when the last window closes (default: true)
    quit_when_last_window_closes: bool = true,

    /// Is the app currently running?
    running: bool = false,

    /// Has the app been initialized?
    initialized: bool = false,

    const Self = @This();

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// Initialize a new multi-window App.
    ///
    /// Creates the platform, registry, and shared resources.
    /// Call `deinit()` when done to clean up.
    pub fn init(allocator: Allocator, font_config: FontConfig, io: std.Io) !Self {
        // Assertions: validate input
        std.debug.assert(@intFromPtr(&allocator) != 0);

        // Initialize platform
        var plat = try Platform.init();
        errdefer plat.deinit();

        // Linux-specific setup
        if (platform.is_linux) {
            try plat.setupListeners();
        }

        // Create text + SVG + image atlases in one call. Scale is `1.0` here;
        // the first window's scale factor is installed later in `openWindow`
        // once a platform window exists to read `scale_factor` from.
        var resources = try AppResources.initOwned(
            allocator,
            io,
            1.0,
            .{
                .font_name = font_config.font_name,
                .font_size = font_config.font_size,
            },
        );
        errdefer resources.deinit();

        const self = Self{
            .allocator = allocator,
            .io = io,
            .platform = plat,
            .registry = WindowRegistry.init(allocator),
            .resources = resources,
            // `ContextApp.init` may fail with `OutOfMemory` (it registers an
            // owned `Keymap` in `app.globals`); the `errdefer resources.deinit()`
            // above unwinds the by-value resources copy, and `ContextApp.init`
            // tears down its own allocations on its error path.
            .context_app = try ContextApp.init(allocator, io),
            .initialized = true,
        };

        // Disarm the local `resources.owned` flag: the by-value copy into
        // `self` keeps `owned = true`, so an unwinding `errdefer` here must not
        // also free the pointees out from under `self.resources`. (Same idiom
        // as `Window.initOwned`.)
        resources.owned = false;

        // Pair-assert: post-init pointers must be non-null.
        std.debug.assert(@intFromPtr(self.resources.text_system) != 0);
        std.debug.assert(@intFromPtr(self.resources.svg_atlas) != 0);
        std.debug.assert(@intFromPtr(self.resources.image_atlas) != 0);

        return self;
    }

    /// Clean up all app resources.
    ///
    /// Closes all windows and frees shared resources.
    pub fn deinit(self: *Self) void {
        // Assertions: validate state
        std.debug.assert(self.initialized);
        std.debug.assert(self.registry.count() >= 0);

        // Close all windows first — every per-window `Window` holds a
        // borrowed view of `self.resources` and `&self.context_app`;
        // closing the windows before tearing either down ensures no
        // in-flight render can still reach a freed atlas, and no
        // `Window.deinit` can still walk a freed `EntityMap`.
        self.closeAllWindows();

        // Tear the shared `EntityMap` down before the atlases: `EntityMap.deinit`
        // cancels attached async groups that may hold pointers into the image
        // atlas's pixel buffers, so those tasks must unwind against a still-live
        // atlas to avoid use-after-free.
        self.context_app.deinit();

        // Frees text_system + svg_atlas + image_atlas in one call.
        self.resources.deinit();

        // Clean up registry
        self.registry.deinit();

        // Clean up platform
        self.platform.deinit();

        self.initialized = false;
    }

    // =========================================================================
    // Window Management
    // =========================================================================

    /// Open a new window with its own state and render function.
    ///
    /// Returns a typed handle for cross-window communication.
    /// The window will use shared resources (text system, atlases).
    pub fn openWindow(
        self: *Self,
        comptime State: type,
        state: *State,
        comptime render: fn (*Cx) void,
        options: AppWindowOptions,
    ) !WindowHandle(State) {
        // Assertions: validate inputs
        std.debug.assert(self.initialized);
        std.debug.assert(@intFromPtr(state) != 0);

        // Check window limit
        if (self.registry.count() >= MAX_WINDOWS) {
            return error.TooManyWindows;
        }

        // Create platform window
        const bg_color = options.background_color orelse Color.rgba(0.95, 0.95, 0.95, 1.0);

        var window = try PlatformWindow.init(self.allocator, &self.platform, .{
            .title = options.title,
            .width = options.width,
            .height = options.height,
            .background_color = bg_color,
            .min_size = options.min_size,
            .max_size = options.max_size,
            .centered = options.centered,
            .background_opacity = options.background_opacity,
            .glass_style = @enumFromInt(@intFromEnum(options.glass_style)),
            .glass_corner_radius = options.glass_corner_radius,
            .titlebar_transparent = options.titlebar_transparent,
            .full_size_content = options.full_size_content,
            .custom_shaders = options.custom_shaders,
        });
        errdefer window.deinit();

        // Update scale factor on the first window (resources are initialized
        // with 1.0 before any windows exist).
        if (self.registry.count() == 0) {
            const scale: f32 = @floatCast(window.scale_factor);
            self.resources.text_system.setScaleFactor(scale);
            // Also update the atlas scale factors for proper rendering
            self.resources.svg_atlas.setScaleFactor(scale);
            self.resources.image_atlas.setScaleFactor(window.scale_factor); // ImageAtlas uses f64
        }

        // Register window in registry
        const id = try self.registry.register(window);
        errdefer _ = self.registry.unregister(id);

        // Create per-window context with shared resources
        const ctx = try self.createWindowContext(State, window, state, render);
        errdefer ctx.deinit();

        // Set user callbacks if provided
        ctx.setCallbacks(options.on_event, options.on_close, options.on_resize);

        // Connect context to window
        ctx.setupWindow(window);

        // Set up close callback to handle quit behavior
        window.setCloseCallback(struct {
            fn onClose(w: *PlatformWindow) bool {
                // Get App pointer from user data in context
                if (w.getUserData(WindowContext(State))) |wctx| {
                    // Call user's close callback first
                    if (wctx.on_close) |user_close| {
                        if (!user_close(&wctx.cx)) {
                            return false; // User prevented close
                        }
                    }
                }
                return true;
            }
        }.onClose);

        // Linux-specific: set active window
        if (platform.is_linux) {
            self.platform.setActiveWindow(window);
        }

        // Assertions: validate result
        std.debug.assert(id.isValid());
        std.debug.assert(self.registry.contains(id));

        return WindowHandle(State).fromId(id);
    }

    /// Close a specific window by ID.
    ///
    /// Cleans up the window context and removes from registry.
    /// May trigger app quit if `quit_when_last_window_closes` is true.
    pub fn closeWindowById(self: *Self, id: WindowId) void {
        // Assertions: validate input
        std.debug.assert(id.isValid());
        std.debug.assert(self.initialized);

        if (self.registry.unregister(id)) |window_ptr| {
            const window: *PlatformWindow = @ptrCast(@alignCast(window_ptr));

            // Clean up window
            window.deinit();
            self.allocator.destroy(window);
        }

        // Check if we should quit
        self.checkQuitCondition();
    }

    /// Close a window using its typed handle.
    pub fn closeWindow(self: *Self, comptime State: type, handle: WindowHandle(State)) void {
        self.closeWindowById(handle.getId());
    }

    /// Close all windows.
    fn closeAllWindows(self: *Self) void {
        // Assertions: validate state
        std.debug.assert(self.initialized);

        // Collect all window IDs first (can't modify while iterating)
        var ids: [MAX_WINDOWS]WindowId = undefined;
        var count: u32 = 0;

        var iter = self.registry.iterator();
        while (iter.next()) |id| {
            if (count < MAX_WINDOWS) {
                ids[count] = id.*;
                count += 1;
            }
        }

        // Close each window
        for (ids[0..count]) |id| {
            if (self.registry.unregister(id)) |window_ptr| {
                const window: *PlatformWindow = @ptrCast(@alignCast(window_ptr));
                window.deinit();
                self.allocator.destroy(window);
            }
        }
    }

    // =========================================================================
    // Window Queries
    // =========================================================================

    /// Get the number of open windows.
    pub fn windowCount(self: *const Self) u32 {
        return self.registry.count();
    }

    /// Get the currently focused window ID.
    pub fn activeWindow(self: *const Self) ?WindowId {
        return self.registry.getActiveWindow();
    }

    /// Check if a window is still open.
    pub fn isWindowOpen(self: *const Self, id: WindowId) bool {
        return self.registry.contains(id);
    }

    /// Get the window registry (for WindowHandle operations).
    pub fn getRegistry(self: *Self) *WindowRegistry {
        return &self.registry;
    }

    /// Get the window registry (const, for read-only operations).
    pub fn getRegistryConst(self: *const Self) *const WindowRegistry {
        return &self.registry;
    }

    // =========================================================================
    // Event Loop
    // =========================================================================

    /// Run the application event loop.
    ///
    /// Blocks until `quit()` is called or all windows are closed
    /// (if `quit_when_last_window_closes` is true).
    pub fn run(self: *Self) void {
        // Assertions: validate state
        std.debug.assert(self.initialized);
        std.debug.assert(self.registry.count() > 0); // Need at least one window

        self.running = true;
        self.platform.run();
    }

    /// Signal the application to quit.
    ///
    /// Stops the event loop. Does not close windows - call `deinit()` for cleanup.
    pub fn quit(self: *Self) void {
        // Assertions: validate state
        std.debug.assert(self.initialized);

        self.running = false;
        self.platform.quit();
    }

    /// Check if the app is currently running.
    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// Create a WindowContext with shared resources.
    /// Uses the App's shared text system and atlases for consistent rendering.
    fn createWindowContext(
        self: *Self,
        comptime State: type,
        window: *PlatformWindow,
        state: *State,
        comptime render: fn (*Cx) void,
    ) !*WindowContext(State) {
        // Assertions: validate inputs
        std.debug.assert(@intFromPtr(window) != 0);
        std.debug.assert(@intFromPtr(state) != 0);

        const WinCtx = WindowContext(State);

        // Shared-resources mode: all windows share one text system and atlas
        // set, fixing font glitching where layout and rendering used different
        // atlases. `&self.resources` is lent as a borrowed view (each window's
        // own `resources` is `owned = false`), and `&self.context_app` lets
        // every window borrow the same `EntityMap` for cross-window observation.
        const ctx = try WinCtx.initWithSharedResources(
            self.allocator,
            window,
            state,
            render,
            &self.resources,
            &self.context_app,
            self.io,
        );

        // Wire up shared atlases to window for rendering
        // Now layout and rendering use the SAME atlas, eliminating glitching
        window.setTextAtlas(self.resources.text_system.getAtlas());
        window.setSvgAtlas(self.resources.svg_atlas.getAtlas());
        window.setImageAtlas(self.resources.image_atlas.getAtlas());

        // Set root state on this window's Window instance (not globally)
        // This enables multi-window support where each window has its own state
        ctx.window.setRootState(State, state);

        return ctx;
    }

    /// Check if we should quit based on window count.
    fn checkQuitCondition(self: *Self) void {
        if (self.quit_when_last_window_closes and self.registry.count() == 0) {
            self.quit();
        }
    }
};

// =============================================================================
// AppWindowOptions
// =============================================================================

/// Options for opening a new window via App.openWindow().
pub const AppWindowOptions = struct {
    /// Window title
    title: []const u8 = "Window",

    /// Initial window width (logical pixels)
    width: f64 = DEFAULT_WIDTH,

    /// Initial window height (logical pixels)
    height: f64 = DEFAULT_HEIGHT,

    /// Background color (null for default)
    background_color: ?Color = null,

    /// Minimum window size
    min_size: ?geometry.Size(f64) = null,

    /// Maximum window size
    max_size: ?geometry.Size(f64) = null,

    /// Center window on screen
    centered: bool = true,

    // Callbacks

    /// Input event handler
    on_event: ?*const fn (*Cx, InputEvent) bool = null,

    /// Close request handler (return false to prevent close)
    on_close: ?*const fn (*Cx) bool = null,

    /// Resize handler
    on_resize: ?*const fn (*Cx, f64, f64) void = null,

    // Glass/transparency (macOS)

    /// Background opacity (0.0 = transparent, 1.0 = opaque)
    background_opacity: f32 = 1.0,

    /// Glass blur style
    glass_style: GlassStyleCompat = .none,

    /// Corner radius for glass effect
    glass_corner_radius: f32 = 16.0,

    /// Make titlebar transparent
    titlebar_transparent: bool = false,

    /// Extend content under titlebar
    full_size_content: bool = false,

    // Advanced

    /// Custom shaders
    custom_shaders: []const shader_mod.CustomShader = &.{},
};

/// Glass style enum (compatible with platform interface)
pub const GlassStyleCompat = enum(u8) {
    none = 0,
    light = 1,
    dark = 2,
    titlebar = 3,
    selection = 4,
    menu = 5,
    popover = 6,
    sidebar = 7,
    header_view = 8,
    sheet = 9,
    window_background = 10,
    hud_window = 11,
    full_screen_ui = 12,
    tool_tip = 13,
    content_background = 14,
    under_window_background = 15,
    under_page_background = 16,
};

// =============================================================================
// Tests
// =============================================================================

test "App type instantiation" {
    // Just verify the type compiles correctly
    _ = App;
    _ = AppWindowOptions;
}

test "AppWindowOptions defaults" {
    const opts = AppWindowOptions{};

    std.debug.assert(opts.width == DEFAULT_WIDTH);
    std.debug.assert(opts.height == DEFAULT_HEIGHT);
    std.debug.assert(opts.centered == true);
    std.debug.assert(opts.background_opacity == 1.0);
}

test "MAX_WINDOWS constant" {
    // Verify limit is reasonable
    std.debug.assert(MAX_WINDOWS >= 1);
    std.debug.assert(MAX_WINDOWS <= 256);
}

test "GlassStyleCompat values" {
    // Verify enum values match expected range
    std.debug.assert(@intFromEnum(GlassStyleCompat.none) == 0);
    std.debug.assert(@intFromEnum(GlassStyleCompat.under_page_background) == 16);
}
