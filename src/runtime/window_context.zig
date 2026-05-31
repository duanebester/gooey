//! WindowContext - Per-window state for multi-window support
//!
//! This module replaces the static CallbackState in runner.zig, enabling
//! multiple windows to each have their own context. The WindowContext is
//! stored in the window's user_data pointer and retrieved in callbacks.
//!
//! ## Architecture
//!
//! Each window owns a WindowContext that contains:
//! - Cx: The unified UI context
//! - User callbacks: on_event, on_close, on_resize
//! - Frame state: building flag, frame counter
//!
//! Callbacks retrieve the WindowContext from the window via getUserData(),
//! eliminating the single-window limitation of module-level static variables.

const std = @import("std");
const builtin = @import("builtin");

// Platform
const platform = @import("../platform/mod.zig");
// `PlatformWindow` is the OS-level handle; `Window` is the framework wrapper.
const PlatformWindow = platform.PlatformWindow;
const is_mac = !platform.is_wasm and !platform.is_linux and builtin.os.tag == .macos;

// Core imports
const window_mod = @import("../context/window.zig");
const Window = window_mod.Window;
const FontConfig = window_mod.FontConfig;
// `App` owns application-lifetime state shared across windows. Single-window
// heap-allocates one in the runner; multi-window embeds one in
// `multi_window_app.zig::App`. Either way `WindowContext` borrows `*App` and
// writes it onto `window.app` after the `Window` is constructed, so the field
// is non-`undefined` before any frame runs.
const app_mod = @import("../context/app.zig");
const App = app_mod.App;
const cx_mod = @import("../cx.zig");
const Cx = cx_mod.Cx;
const ui_mod = @import("../ui/mod.zig");
const Builder = ui_mod.Builder;
const input_mod = @import("../input/mod.zig");
const InputEvent = input_mod.InputEvent;
const handler_mod = @import("../context/handler.zig");

// Runtime
const frame_mod = @import("frame.zig");
const input_handler = @import("input.zig");

// =============================================================================
// Constants (per CLAUDE.md: "put a limit on everything")
// =============================================================================

/// Threshold for warning (only warn if significantly over budget)
const FRAME_WARNING_THRESHOLD_NS: i128 = 20_000_000; // 20ms

/// Number of frames to skip before warning (initialization is expected to be slow)
const FRAME_BUDGET_SKIP_COUNT: u32 = 3;

// =============================================================================
// WindowContext
// =============================================================================

// Text system for shared resources
const text_mod = @import("../text/mod.zig");
const TextSystem = text_mod.TextSystem;
const Atlas = text_mod.Atlas;

// Atlas types for shared resources
const svg_mod = @import("../svg/mod.zig");
const SvgAtlas = svg_mod.SvgAtlas;
const image_mod = @import("../image/mod.zig");

// Metal renderer for macOS thread-safe atlas upload
const MetalRenderer = if (is_mac) @import("../platform/macos/metal/metal.zig").Renderer else void;
const ImageAtlas = image_mod.ImageAtlas;

// Shared rendering resources (text system + atlases), owned upstream
// (typically by `App`) and lent borrowed-shape into every per-window `Window`.
const app_resources_mod = @import("../context/app_resources.zig");
const AppResources = app_resources_mod.AppResources;

/// Per-window context that replaces static CallbackState.
/// Stored in window.user_data for callback access.
pub fn WindowContext(comptime State: type) type {
    return struct {
        /// Memory allocator for this window's resources
        allocator: std.mem.Allocator,

        /// The unified UI context
        cx: Cx,

        /// Framework window wrapper (owned, manages layout/scene/widgets)
        window: *Window,

        /// Borrowed `*App` (owned by the runner single-window, or by
        /// `multi_window_app.zig::App` multi-window). `deinit` deliberately
        /// does not touch it: the upstream owner tears the `App` down after
        /// every window's `deinit`, so entity cancel-groups still have a live
        /// `EntityMap` to walk during removal.
        app: *App,

        /// UI Builder instance
        builder: *Builder,

        /// Pointer to user's application state
        state: *State,

        /// User callback for raw input events
        on_event: ?*const fn (*Cx, InputEvent) bool = null,

        /// User callback when window is about to close (return false to prevent)
        on_close: ?*const fn (*Cx) bool = null,

        /// User callback when window resizes
        on_resize: ?*const fn (*Cx, f64, f64) void = null,

        /// User's render function
        render_fn: *const fn (*Cx) void,

        /// Guard against re-entrant rendering
        building: bool = false,

        /// Frame counter for debug timing (skip first few frames)
        frame_count: u32 = 0,

        const Self = @This();

        // =====================================================================
        // Initialization
        // =====================================================================

        /// Initialize a WindowContext for a window.
        /// Allocates Window and Builder on the heap.
        ///
        /// `app` is borrowed from the caller, which must outlive every window
        /// borrowing the pointer; `deinit` does not free it.
        pub fn init(
            allocator: std.mem.Allocator,
            platform_window: *PlatformWindow,
            state: *State,
            render_fn: *const fn (*Cx) void,
            font_config: FontConfig,
            app: *App,
            io: std.Io,
        ) !*Self {
            // Assertions: validate inputs (pointers must not be null-equivalent)
            std.debug.assert(@intFromPtr(state) != 0);
            std.debug.assert(@intFromPtr(render_fn) != 0);
            std.debug.assert(@intFromPtr(app) != 0);

            // Allocate self on heap (WindowContext may be large)
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            // Initialize Window with owned resources (single-window mode).
            const window = try allocator.create(Window);
            errdefer allocator.destroy(window);
            window.* = try Window.initOwned(allocator, platform_window, font_config, io);
            // Wire the borrowed `*App` onto the freshly-initialised `Window`
            // (`initOwned` left `window.app` undefined). This is the latest
            // safe point; every path that reaches `window.app.*` runs after it.
            window.app = app;
            errdefer window.deinit();

            // Bind the app-scoped `ImageLoader` against the window's owning
            // `image_atlas` — the first moment a stable `*ImageAtlas` exists
            // on the single-window path. Single-bind is asserted inside
            // `bindImageLoader`.
            app.bindImageLoader(window.resources.image_atlas);

            // Initialize UI Builder against the `next_frame.*` build target.
            // The per-tick reset in `renderFrameImpl` re-fetches `scene` and
            // `dispatch` from `window.next_frame.*` so the cached pointers
            // track every end-of-frame swap; the values below are just frame-0.
            const builder = try allocator.create(Builder);
            errdefer allocator.destroy(builder);
            builder.* = Builder.init(
                allocator,
                window.layout,
                window.next_frame.scene,
                window.next_frame.dispatch,
            );
            builder.window = window;

            // Initialize fields
            self.* = .{
                .allocator = allocator,
                .window = window,
                .app = app,
                .builder = builder,
                .state = state,
                .render_fn = render_fn,
                .cx = Cx{
                    ._allocator = allocator,
                    ._window = window,
                    ._builder = builder,
                    .state_ptr = @ptrCast(state),
                    .state_type_id = handler_mod.typeId(State),
                },
            };

            // Set cx_ptr on builder so components can receive *Cx
            self.builder.cx_ptr = @ptrCast(&self.cx);

            // Assertions: validate initialization
            std.debug.assert(@intFromPtr(self.window) != 0);
            std.debug.assert(@intFromPtr(self.builder) != 0);
            std.debug.assert(@intFromPtr(self.window.app) == @intFromPtr(app));

            return self;
        }

        /// Initialize a WindowContext with shared resources (multi-window mode).
        /// The shared resources are owned by the App (borrowed view), not this
        /// context.
        pub fn initWithSharedResources(
            allocator: std.mem.Allocator,
            platform_window: *PlatformWindow,
            state: *State,
            render_fn: *const fn (*Cx) void,
            shared_resources: *const AppResources,
            app: *App,
            io: std.Io,
        ) !*Self {
            // Assertions: validate inputs.
            std.debug.assert(@intFromPtr(state) != 0);
            std.debug.assert(@intFromPtr(render_fn) != 0);
            std.debug.assert(@intFromPtr(shared_resources) != 0);
            std.debug.assert(@intFromPtr(shared_resources.text_system) != 0);
            std.debug.assert(@intFromPtr(shared_resources.svg_atlas) != 0);
            std.debug.assert(@intFromPtr(shared_resources.image_atlas) != 0);
            std.debug.assert(@intFromPtr(app) != 0);

            // Allocate self on heap
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            // Initialize Window with shared resources (multi-window mode).
            const window = try allocator.create(Window);
            errdefer allocator.destroy(window);
            window.* = try Window.initWithSharedResources(
                allocator,
                platform_window,
                shared_resources,
                io,
            );
            // Every window in a multi-window app borrows a pointer to the SAME
            // `context.App` (embedded by-value inside the parent), which is
            // what enables cross-window entity observation.
            window.app = app;
            errdefer window.deinit();

            // Bind the app-scoped `ImageLoader` against the shared `image_atlas`.
            // `bindImageLoader` is idempotent on same-atlas re-binds, so only
            // the first window in this `App` actually initializes the loader.
            // Reaching through `shared_resources` (same address as
            // `window.resources`) makes the upstream-owned lifetime explicit.
            app.bindImageLoader(shared_resources.image_atlas);

            // Initialize UI Builder against the `next_frame.*` build target;
            // same wiring as the single-window `init` above.
            const builder = try allocator.create(Builder);
            errdefer allocator.destroy(builder);
            builder.* = Builder.init(
                allocator,
                window.layout,
                window.next_frame.scene,
                window.next_frame.dispatch,
            );
            builder.window = window;

            // Initialize fields
            self.* = .{
                .allocator = allocator,
                .window = window,
                .app = app,
                .builder = builder,
                .state = state,
                .render_fn = render_fn,
                .cx = Cx{
                    ._allocator = allocator,
                    ._window = window,
                    ._builder = builder,
                    .state_ptr = @ptrCast(state),
                    .state_type_id = handler_mod.typeId(State),
                },
            };

            // Set cx_ptr on builder so components can receive *Cx
            self.builder.cx_ptr = @ptrCast(&self.cx);

            // Assertions: validate initialization
            std.debug.assert(@intFromPtr(self.window) != 0);
            std.debug.assert(@intFromPtr(self.builder) != 0);
            std.debug.assert(@intFromPtr(self.window.app) == @intFromPtr(app));

            return self;
        }

        /// Clean up all resources owned by this WindowContext.
        pub fn deinit(self: *Self) void {
            // Assertions: validate self
            std.debug.assert(@intFromPtr(self.window) != 0);
            std.debug.assert(@intFromPtr(self.builder) != 0);

            self.builder.deinit();
            self.allocator.destroy(self.builder);

            self.window.deinit();
            self.allocator.destroy(self.window);

            self.allocator.destroy(self);
        }

        // =====================================================================
        // Window Callbacks
        // =====================================================================

        /// Render callback - called by the window on each frame.
        /// Retrieves WindowContext from window.user_data.
        pub fn onRender(window: *PlatformWindow) void {
            const self = window.getUserData(Self) orelse return;

            // Guard against re-entrant rendering
            if (self.building) return;
            self.building = true;
            defer self.building = false;

            // Frame timing for budget warnings (debug builds only, skip first few frames).
            // Sample `.awake` (monotonic) so the elapsed delta can never be negative
            // even if NTP or the sysadmin adjusts the wall clock mid-frame.
            const io = self.window.io;
            const start_ts = if (builtin.mode == .Debug)
                std.Io.Timestamp.now(io, .awake)
            else
                std.Io.Timestamp.zero;

            frame_mod.renderFrameCxRuntime(&self.cx, self.render_fn) catch |err| {
                std.debug.print("Render error: {}\n", .{err});
            };

            // Check frame budget in debug builds (skip initialization frames)
            if (builtin.mode == .Debug) {
                self.frame_count += 1;
                if (self.frame_count > FRAME_BUDGET_SKIP_COUNT) {
                    const elapsed_ns: i96 = start_ts.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds();
                    std.debug.assert(elapsed_ns >= 0);
                    const elapsed: u64 = @intCast(elapsed_ns);
                    if (elapsed > FRAME_WARNING_THRESHOLD_NS) {
                        const elapsed_ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
                        std.debug.print("⚠️  Frame budget exceeded: {d:.2}ms (target: 16.67ms)\n", .{elapsed_ms});
                    }
                }
            }
        }

        /// Input callback - called by the window for input events.
        pub fn onInput(window: *PlatformWindow, event: InputEvent) bool {
            const self = window.getUserData(Self) orelse return false;
            return input_handler.handleInputCx(&self.cx, self.on_event, event);
        }

        /// Post-input callback - called after input handling with mutex released.
        /// Flushes deferred commands which may run nested event loops (modal dialogs).
        pub fn onPostInput(window: *PlatformWindow) void {
            const self = window.getUserData(Self) orelse return;
            self.window.flushDeferredCommands();
        }

        /// Close callback - called when window is about to close.
        pub fn onClose(window: *PlatformWindow) bool {
            const self = window.getUserData(Self) orelse return true;
            if (self.on_close) |callback| {
                return callback(&self.cx);
            }
            return true; // Allow close by default
        }

        /// Resize callback - called when window size changes.
        pub fn onResize(window: *PlatformWindow, width: f64, height: f64) void {
            const self = window.getUserData(Self) orelse return;
            if (self.on_resize) |callback| {
                callback(&self.cx, width, height);
            }
        }

        // =====================================================================
        // Setup Helpers
        // =====================================================================

        /// Configure all window callbacks and atlases.
        /// Call this after init() to connect the WindowContext to the window.
        pub fn setupWindow(self: *Self, window: *PlatformWindow) void {
            // Assertions: validate state
            std.debug.assert(@intFromPtr(self.window) != 0);
            std.debug.assert(@intFromPtr(self.builder) != 0);

            // Store self in window's user_data
            window.setUserData(self);

            // Set callbacks
            window.setRenderCallback(Self.onRender);
            window.setInputCallback(Self.onInput);
            window.setCloseCallback(Self.onClose);
            window.setResizeCallback(Self.onResize);
            window.setPostInputCallback(Self.onPostInput);

            // Set atlases and scene. The platform scene pointer must track
            // `rendered_frame.scene` (the GPU-side displayed buffer), not the
            // `next_frame.scene` build target. `renderFrameImpl` re-points it
            // after every swap; the `setScene` below is just the frame-0 setup.
            window.setTextAtlas(self.window.resources.text_system.getAtlas());
            window.setSvgAtlas(self.window.resources.svg_atlas.*.getAtlas());
            window.setImageAtlas(self.window.resources.image_atlas.*.getAtlas());
            window.setScene(self.window.rendered_frame.scene);

            // Set thread-safe atlas upload callbacks for multi-window scenarios (macOS only).
            // These callbacks hold the appropriate mutex during GPU upload, preventing races
            // where another window's DisplayLink thread modifies the atlas concurrently.
            if (comptime is_mac) {
                window.setTextAtlasUploadCallback(
                    @ptrCast(self.window.resources.text_system),
                    Self.uploadTextAtlasLocked,
                );
                window.setSvgAtlasUploadCallback(
                    @ptrCast(self.window.resources.svg_atlas),
                    Self.uploadSvgAtlasLocked,
                );
                window.setImageAtlasUploadCallback(
                    @ptrCast(self.window.resources.image_atlas),
                    Self.uploadImageAtlasLocked,
                );
            }
        }

        /// Thread-safe text atlas upload callback (macOS).
        /// Holds glyph_cache_mutex while uploading to prevent concurrent modification.
        fn uploadTextAtlasLocked(ctx: *anyopaque, renderer: *MetalRenderer) anyerror!void {
            if (comptime !is_mac) return;
            const text_system: *TextSystem = @ptrCast(@alignCast(ctx));
            try text_system.withAtlasLockedCtx(*MetalRenderer, renderer, struct {
                fn upload(r: *MetalRenderer, atlas: *const Atlas) anyerror!void {
                    try r.updateTextAtlas(atlas);
                }
            }.upload);
        }

        /// Thread-safe SVG atlas upload callback (macOS).
        /// Holds svg_atlas mutex while uploading to prevent concurrent modification.
        fn uploadSvgAtlasLocked(ctx: *anyopaque, renderer: *MetalRenderer) anyerror!void {
            if (comptime !is_mac) return;
            const svg_atlas: *SvgAtlas = @ptrCast(@alignCast(ctx));
            try svg_atlas.withAtlasLocked(*MetalRenderer, renderer, struct {
                fn upload(r: *MetalRenderer, atlas: *const Atlas) anyerror!void {
                    r.prepareSvgAtlas(atlas);
                }
            }.upload);
        }

        /// Thread-safe image atlas upload callback (macOS).
        /// Holds image_atlas mutex while uploading to prevent concurrent modification.
        fn uploadImageAtlasLocked(ctx: *anyopaque, renderer: *MetalRenderer) anyerror!void {
            if (comptime !is_mac) return;
            const image_atlas: *ImageAtlas = @ptrCast(@alignCast(ctx));
            try image_atlas.withAtlasLocked(*MetalRenderer, renderer, struct {
                fn upload(r: *MetalRenderer, atlas: *const Atlas) anyerror!void {
                    r.prepareImageAtlas(atlas);
                }
            }.upload);
        }

        /// Set user callbacks after initialization.
        pub fn setCallbacks(
            self: *Self,
            on_event: ?*const fn (*Cx, InputEvent) bool,
            on_close: ?*const fn (*Cx) bool,
            on_resize: ?*const fn (*Cx, f64, f64) void,
        ) void {
            self.on_event = on_event;
            self.on_close = on_close;
            self.on_resize = on_resize;
        }

        /// Get a pointer to the Cx context.
        pub fn getCx(self: *Self) *Cx {
            return &self.cx;
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "WindowContext type instantiation" {
    const TestState = struct {
        count: i32 = 0,
    };

    // Just verify the type compiles correctly
    const WinCtx = WindowContext(TestState);
    _ = WinCtx;
}

test "WindowContext callback signature types" {
    const TestState = struct {
        value: i32 = 42,
        pub fn render(_: *Cx) void {}
    };

    const WinCtx = WindowContext(TestState);

    // Verify callback function signatures match what PlatformWindow expects
    const render_cb: *const fn (*PlatformWindow) void = WinCtx.onRender;
    const input_cb: *const fn (*PlatformWindow, InputEvent) bool = WinCtx.onInput;
    const close_cb: *const fn (*PlatformWindow) bool = WinCtx.onClose;
    const resize_cb: *const fn (*PlatformWindow, f64, f64) void = WinCtx.onResize;

    // Assertions: callbacks are valid function pointers
    std.debug.assert(@intFromPtr(render_cb) != 0);
    std.debug.assert(@intFromPtr(input_cb) != 0);
    std.debug.assert(@intFromPtr(close_cb) != 0);
    std.debug.assert(@intFromPtr(resize_cb) != 0);
}

test "WindowContext struct size is reasonable" {
    const TestState = struct {
        count: i32 = 0,
    };

    const WinCtx = WindowContext(TestState);

    // WindowContext should be reasonably sized (not huge)
    // Per CLAUDE.md: heap-allocate structs >50KB
    const size = @sizeOf(WinCtx);
    std.debug.assert(size < 1024); // Should be well under 1KB for the struct itself
}
