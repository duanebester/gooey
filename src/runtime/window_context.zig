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
const Window = platform.Window;
const is_mac = !platform.is_wasm and !platform.is_linux and builtin.os.tag == .macos;

// Core imports
const gooey_mod = @import("../context/gooey.zig");
const Gooey = gooey_mod.Gooey;
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
const MetalRenderer = if (is_mac) @import("../platform/mac/metal/metal.zig").Renderer else void;
const ImageAtlas = image_mod.ImageAtlas;

/// Per-window context that replaces static CallbackState.
/// Stored in window.user_data for callback access.
pub fn WindowContext(comptime State: type) type {
    return struct {
        /// Memory allocator for this window's resources
        allocator: std.mem.Allocator,

        /// The unified UI context
        cx: Cx,

        /// Gooey instance (owned, manages layout/scene/widgets)
        gooey: *Gooey,

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
        /// Allocates Gooey and Builder on the heap.
        pub fn init(
            allocator: std.mem.Allocator,
            window: *Window,
            state: *State,
            render_fn: *const fn (*Cx) void,
        ) !*Self {
            // Assertions: validate inputs (pointers must not be null-equivalent)
            std.debug.assert(@intFromPtr(state) != 0);
            std.debug.assert(@intFromPtr(render_fn) != 0);

            // Allocate self on heap (WindowContext may be large)
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            // Initialize Gooey with owned resources (single-window mode)
            const gooey = try allocator.create(Gooey);
            errdefer allocator.destroy(gooey);
            gooey.* = try Gooey.initOwned(allocator, window);
            errdefer gooey.deinit();

            // Initialize UI Builder
            const builder = try allocator.create(Builder);
            errdefer allocator.destroy(builder);
            builder.* = Builder.init(
                allocator,
                gooey.layout,
                gooey.scene,
                gooey.dispatch,
            );
            builder.gooey = gooey;

            // Initialize fields
            self.* = .{
                .allocator = allocator,
                .gooey = gooey,
                .builder = builder,
                .state = state,
                .render_fn = render_fn,
                .cx = Cx{
                    ._allocator = allocator,
                    ._gooey = gooey,
                    ._builder = builder,
                    .state_ptr = @ptrCast(state),
                    .state_type_id = handler_mod.typeId(State),
                },
            };

            // Set cx_ptr on builder so components can receive *Cx
            self.builder.cx_ptr = @ptrCast(&self.cx);

            // Assertions: validate initialization
            std.debug.assert(@intFromPtr(self.gooey) != 0);
            std.debug.assert(@intFromPtr(self.builder) != 0);

            return self;
        }

        /// Initialize a WindowContext with shared resources (multi-window mode).
        /// The shared resources are owned by the App, not this context.
        pub fn initWithSharedResources(
            allocator: std.mem.Allocator,
            window: *Window,
            state: *State,
            render_fn: *const fn (*Cx) void,
            shared_text_system: *TextSystem,
            shared_svg_atlas: *SvgAtlas,
            shared_image_atlas: *ImageAtlas,
        ) !*Self {
            // Assertions: validate inputs
            std.debug.assert(@intFromPtr(state) != 0);
            std.debug.assert(@intFromPtr(render_fn) != 0);
            std.debug.assert(@intFromPtr(shared_text_system) != 0);
            std.debug.assert(@intFromPtr(shared_svg_atlas) != 0);
            std.debug.assert(@intFromPtr(shared_image_atlas) != 0);

            // Allocate self on heap
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            // Initialize Gooey with shared resources (multi-window mode)
            const gooey = try allocator.create(Gooey);
            errdefer allocator.destroy(gooey);
            gooey.* = try Gooey.initWithSharedResources(
                allocator,
                window,
                shared_text_system,
                shared_svg_atlas,
                shared_image_atlas,
            );
            errdefer gooey.deinit();

            // Initialize UI Builder
            const builder = try allocator.create(Builder);
            errdefer allocator.destroy(builder);
            builder.* = Builder.init(
                allocator,
                gooey.layout,
                gooey.scene,
                gooey.dispatch,
            );
            builder.gooey = gooey;

            // Initialize fields
            self.* = .{
                .allocator = allocator,
                .gooey = gooey,
                .builder = builder,
                .state = state,
                .render_fn = render_fn,
                .cx = Cx{
                    ._allocator = allocator,
                    ._gooey = gooey,
                    ._builder = builder,
                    .state_ptr = @ptrCast(state),
                    .state_type_id = handler_mod.typeId(State),
                },
            };

            // Set cx_ptr on builder so components can receive *Cx
            self.builder.cx_ptr = @ptrCast(&self.cx);

            // Assertions: validate initialization
            std.debug.assert(@intFromPtr(self.gooey) != 0);
            std.debug.assert(@intFromPtr(self.builder) != 0);

            return self;
        }

        /// Clean up all resources owned by this WindowContext.
        pub fn deinit(self: *Self) void {
            // Assertions: validate self
            std.debug.assert(@intFromPtr(self.gooey) != 0);
            std.debug.assert(@intFromPtr(self.builder) != 0);

            self.builder.deinit();
            self.allocator.destroy(self.builder);

            self.gooey.deinit();
            self.allocator.destroy(self.gooey);

            self.allocator.destroy(self);
        }

        // =====================================================================
        // Window Callbacks
        // =====================================================================

        /// Render callback - called by the window on each frame.
        /// Retrieves WindowContext from window.user_data.
        pub fn onRender(window: *Window) void {
            const self = window.getUserData(Self) orelse return;

            // Guard against re-entrant rendering
            if (self.building) return;
            self.building = true;
            defer self.building = false;

            // Frame timing for budget warnings (debug builds only, skip first few frames)
            const start_time = if (builtin.mode == .Debug)
                std.time.nanoTimestamp()
            else
                0;

            frame_mod.renderFrameCxRuntime(&self.cx, self.render_fn) catch |err| {
                std.debug.print("Render error: {}\n", .{err});
            };

            // Check frame budget in debug builds (skip initialization frames)
            if (builtin.mode == .Debug) {
                self.frame_count += 1;
                if (self.frame_count > FRAME_BUDGET_SKIP_COUNT) {
                    const elapsed = std.time.nanoTimestamp() - start_time;
                    if (elapsed > FRAME_WARNING_THRESHOLD_NS) {
                        const elapsed_ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
                        std.debug.print("⚠️  Frame budget exceeded: {d:.2}ms (target: 16.67ms)\n", .{elapsed_ms});
                    }
                }
            }
        }

        /// Input callback - called by the window for input events.
        pub fn onInput(window: *Window, event: InputEvent) bool {
            const self = window.getUserData(Self) orelse return false;
            return input_handler.handleInputCx(&self.cx, self.on_event, event);
        }

        /// Close callback - called when window is about to close.
        pub fn onClose(window: *Window) bool {
            const self = window.getUserData(Self) orelse return true;
            if (self.on_close) |callback| {
                return callback(&self.cx);
            }
            return true; // Allow close by default
        }

        /// Resize callback - called when window size changes.
        pub fn onResize(window: *Window, width: f64, height: f64) void {
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
        pub fn setupWindow(self: *Self, window: *Window) void {
            // Assertions: validate state
            std.debug.assert(@intFromPtr(self.gooey) != 0);
            std.debug.assert(@intFromPtr(self.builder) != 0);

            // Store self in window's user_data
            window.setUserData(self);

            // Set callbacks
            window.setRenderCallback(Self.onRender);
            window.setInputCallback(Self.onInput);
            window.setCloseCallback(Self.onClose);
            window.setResizeCallback(Self.onResize);

            // Set atlases and scene
            window.setTextAtlas(self.gooey.text_system.getAtlas());
            window.setSvgAtlas(self.gooey.svg_atlas.*.getAtlas());
            window.setImageAtlas(self.gooey.image_atlas.*.getAtlas());
            window.setScene(self.gooey.scene);

            // Set thread-safe atlas upload callbacks for multi-window scenarios (macOS only).
            // These callbacks hold the appropriate mutex during GPU upload, preventing races
            // where another window's DisplayLink thread modifies the atlas concurrently.
            if (comptime is_mac) {
                window.setTextAtlasUploadCallback(
                    @ptrCast(self.gooey.text_system),
                    Self.uploadTextAtlasLocked,
                );
                window.setSvgAtlasUploadCallback(
                    @ptrCast(self.gooey.svg_atlas),
                    Self.uploadSvgAtlasLocked,
                );
                window.setImageAtlasUploadCallback(
                    @ptrCast(self.gooey.image_atlas),
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

    // Verify callback function signatures match what Window expects
    const render_cb: *const fn (*Window) void = WinCtx.onRender;
    const input_cb: *const fn (*Window, InputEvent) bool = WinCtx.onInput;
    const close_cb: *const fn (*Window) bool = WinCtx.onClose;
    const resize_cb: *const fn (*Window, f64, f64) void = WinCtx.onResize;

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
