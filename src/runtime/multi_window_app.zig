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
// PR 7b.1a — `platform.Window` renamed to `platform.PlatformWindow`
// to free up the `Window` name for the framework-level wrapper
// landing in PR 7b.1b. See `src/platform/mod.zig` for the rationale.
const PlatformWindow = platform.PlatformWindow;
const WindowId = platform.WindowId;
const WindowRegistry = platform.WindowRegistry;
const WindowOptions = platform.WindowOptions;

// Core
const geometry = @import("../core/geometry.zig");
const Color = geometry.Color;
const shader_mod = @import("../core/shader.zig");

// PR 7b.6 — `TextSystem` / `SvgAtlas` / `ImageAtlas` type-alias
// imports retired alongside the call-site collapse to
// `&self.resources` in `createWindowContext`. Every reference left
// in this file (`self.resources.text_system.setScaleFactor`,
// `self.resources.svg_atlas.getAtlas`, …) is value-level — the
// types are reached through `AppResources` now, never named
// directly. The `text_mod` / `svg_mod` / `image_mod` imports were
// only ever used to surface those three aliases, so they go too.

// PR 7b.2 — bundle the three "expensive to duplicate per window"
// resources (text system + svg atlas + image atlas) into a single
// `AppResources` field. Replaces the three separate `*T` fields plus
// their parallel allocate/init/deinit blocks. Mirrors the same shape
// the single-window `Window.init*` paths adopted in PR 7a, so both
// ownership shapes (single-window owns by-value, multi-window owns
// once on `App` and hands borrowed views to each `Window`) now route
// through the same struct. See `src/context/app_resources.zig` and
// `docs/cleanup-implementation-plan.md` PR 7b.
const app_resources_mod = @import("../context/app_resources.zig");
const AppResources = app_resources_mod.AppResources;

// PR 7b.3 — `context.App` owns application-lifetime state shared
// across windows. Currently holds `entities` (lifted off `Window`
// in 7b.3); subsequent 7b slices add `keymap` / `globals` /
// `image_loader` here per the GPUI mapping in
// `architectural-cleanup-plan.md` §10. Embedded by-value below
// (`context_app: ContextApp`) so every `Window` opened by this
// app borrows `&self.context_app` and reaches the same
// `EntityMap` — that's the property cross-window observation
// needs. See `docs/cleanup-implementation-plan.md` PR 7b.3.
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

    /// PR 7b.2 — bundled shared rendering resources owned at app
    /// scope. `App.init` constructs an owning `AppResources` here;
    /// every per-window `Window` embeds a borrowed view over the
    /// same three pointees (`text_system` / `svg_atlas` /
    /// `image_atlas`). `AppResources.deinit` tears them down once,
    /// in `App.deinit`, after the last window has closed. Replaces
    /// the previous `text_system: *T` / `svg_atlas: *T` /
    /// `image_atlas: *T` triplet that duplicated the alloc/init/
    /// deinit logic three times.
    resources: AppResources,

    /// PR 7b.3 — application-lifetime state shared across windows.
    /// Currently owns `entities` (the `EntityMap` used to live on
    /// each per-window `Window`; lifting it here makes models
    /// observable across windows). Subsequent 7b slices add
    /// `keymap` / `globals` / `image_loader`. Embedded by-value:
    /// the outer `App` is heap-allocated by the caller and
    /// `&self.context_app` outlives every `Window` opened from
    /// this app.
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

        // PR 7b.2 — bundle text + SVG + image atlas creation into one
        // `AppResources.initOwned` call. Replaces the three parallel
        // `allocator.create` + init + errdefer blocks plus the inline
        // font-load step. Scale is `1.0` here (matching the
        // pre-extraction default); the first window's scale factor is
        // installed on this `AppResources` later in `openWindow` once a
        // platform window exists to read `scale_factor` from.
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
            // PR 7b.3 — initialise the embedded `context.App`
            // with the same `allocator` + `io` the rest of the
            // multi-window app uses. `ContextApp.init` is
            // infallible (no `try`) — `EntityMap.init` never
            // returns errors. The `EntityMap` inside is empty
            // until the first `cx.entities.create(...)` call.
            // PR 7b.4 — `ContextApp.init` now returns `!Self`
            // (was `Self`) because it registers an owned `Keymap`
            // in `app.globals` via `Globals.setOwned`, which can
            // fail with `OutOfMemory`. The surrounding `errdefer
            // resources.deinit()` above unwinds the by-value
            // resources copy on failure; the `EntityMap` /
            // `Keymap` allocations that `ContextApp.init` would
            // have made are torn down inside its own `errdefer`
            // chain before this expression unwinds.
            .context_app = try ContextApp.init(allocator, io),
            .initialized = true,
        };

        // PR 7b.2 — `resources.owned` is true on the local `resources`
        // returned from `initOwned`. The by-value copy into `self`
        // duplicates the flag; without disarming the local, an
        // unwinding `errdefer` in this function would tear the heap
        // pointees down out from under the successfully-copied
        // `self.resources`. Same idiom as `Window.initOwned` after
        // PR 7a — see `src/context/window.zig` for the pre-existing
        // precedent. The copied `self.resources.owned` retains the
        // `true` value, which is what the caller needs.
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

        // PR 7b.3 — tear the shared `EntityMap` down before the
        // shared atlases. Order rationale: `EntityMap.deinit`
        // cancels any attached async groups, which may hold
        // pointers into the image atlas's pixel buffers
        // (entity-attached fetches today, but also any future
        // pipeline that lands an `ImageLoader` on `App`). Doing
        // entity teardown first means those tasks unwind against
        // a still-live atlas; the reverse order would risk
        // use-after-free in cancellation paths.
        self.context_app.deinit();

        // PR 7b.2 — single teardown call covers text_system +
        // svg_atlas + image_atlas. `AppResources.deinit` frees the
        // three subsystems in image → svg → text order (matching
        // the pre-extraction sequence). Replaces three flag-guarded
        // free blocks at this point in the function.
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

        // Update text system scale factor on first window
        // (Text system is initialized with 1.0 before any windows exist)
        //
        // PR 7b.2 — reach through `self.resources` for the three
        // subsystems instead of the retired top-level pointer fields.
        // The pointees are unchanged — same heap addresses, same
        // setScaleFactor semantics — only the access path moves.
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

        // Use shared resources mode - all windows share the same text system and atlases
        // This fixes font glitching where layout used one atlas but rendering used another
        // PR 7b.6 — pass `&self.resources` as a single
        // `*const AppResources` borrowed view. Replaces the pre-7b.6
        // call site that unbundled `self.resources.*` into three
        // separate pointer arguments — same heap addresses, but the
        // bundle stays bundled across the `App → WindowContext →
        // Window` call chain. Down-tree, `Window.initWithSharedResources`
        // wraps it in `AppResources.borrowed(...)` so each window's
        // own `resources` field is `owned = false` and `Window.deinit`
        // is a no-op for the shared atlases.
        // PR 7b.3 — pass `&self.context_app` so the new
        // `Window` borrows the same `EntityMap` every other
        // window in this app borrows. Pre-7b.3 the per-window
        // map was constructed inside `Window.initWithSharedResources`
        // and the cross-window observation property was
        // structurally impossible.
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
    title: []const u8 = "Window Window",

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
