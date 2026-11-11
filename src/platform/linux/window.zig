//! LinuxWindow - Window implementation for Linux/Wayland
//!
//! Provides window creation and management using Wayland's XDG shell protocol,
//! with GPU rendering via Vulkan, or CPU rendering into shared memory when the
//! build selects `-Dlinux-backend=wayland_cpu`. The window never draws: once
//! the core host binds it (`CoreBinding`), the host's render thread owns the
//! renderer.

const std = @import("std");
const wayland = @import("wayland.zig");
const vk_renderer = @import("vk_renderer.zig");
const VulkanRenderer = vk_renderer.VulkanRenderer;
const shm_renderer = @import("shm_renderer.zig");
const ShmRenderer = shm_renderer.ShmRenderer;
const linux_backend = @import("../linux_backend.zig");
const LinuxPlatform = @import("platform.zig").LinuxPlatform;
const interface_mod = @import("../interface.zig");
const WindowId = interface_mod.WindowId;
const geometry = @import("../../geometry/geometry.zig");
const Size = geometry.Size(f64);
const input = @import("../../input/events.zig");
const linux_input = @import("input.zig");

const Allocator = std.mem.Allocator;
const WindowOptions = interface_mod.WindowOptions;
const limits_mod = @import("../../core/limits.zig");
const ResourceLimits = limits_mod.ResourceLimits;
const backend = @import("../../core/backend.zig");
const core_events = @import("../../core/events.zig");
const core_router = @import("../../core/router.zig");
const core_clipboard = @import("../../core/clipboard.zig");
const core_text_engine = @import("../../core/text_engine.zig");

/// How the core host drives this window (contract §9), as on macOS: the
/// window pushes input and configures into the core's queue and asks the
/// host for a tick. The window never draws on the main thread; the host's
/// render thread draws.
pub const CoreBinding = struct {
    queue: *core_events.EventQueue,
    query: *const core_router.Query,
    context: *anyopaque,
    /// Ask the host for a main-thread tick. Called on the main thread after
    /// every push.
    schedule_tick: *const fn (context: *anyopaque) void,
};

/// The renderer is fixed per build. Selecting it at comptime keeps the
/// unselected renderer out of the binary, so a CPU build neither links nor
/// loads Vulkan.
const use_cpu_renderer = switch (linux_backend.selected) {
    .wayland_vulkan => false,
    .wayland_cpu => true,
    .fbdev => @compileError("the fbdev backend does not use the Wayland window"),
};
const Renderer = if (use_cpu_renderer) ShmRenderer else VulkanRenderer;
const NativeSurface = if (use_cpu_renderer)
    shm_renderer.NativeSurface
else
    vk_renderer.NativeSurface;

/// The highest device scale the selected renderer draws at; the CPU raster
/// bounds it to keep device coordinates well inside `f32`.
pub const renderer_scale_max: f32 = if (use_cpu_renderer)
    @import("../cpu/renderer.zig").scale_factor_max
else
    std.math.floatMax(f32);

/// Monotonic milliseconds for `Window.requestRenderAfter`. The callers carry
/// no `Io`, so this uses the process-lifetime global.
fn awakeTimeMs() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    std.debug.assert(now_ms >= 0);
    return @intCast(now_ms);
}

// Static listeners - must persist for lifetime of Wayland objects
const surface_listener = wayland.SurfaceListener{
    .enter = Window.surfaceEnter,
    .leave = Window.surfaceLeave,
    .preferred_buffer_scale = Window.surfacePreferredScale,
    .preferred_buffer_transform = Window.surfacePreferredTransform,
};

const fractional_scale_listener = wayland.FractionalScaleListener{
    .preferred_scale = Window.fractionalPreferredScale,
};

const decoration_listener = wayland.ZxdgToplevelDecorationV1Listener{
    .configure = Window.decorationConfigure,
};

const xdg_surface_listener = wayland.XdgSurfaceListener{
    .configure = Window.xdgSurfaceConfigure,
};

const toplevel_listener = wayland.XdgToplevelListener{
    .configure = Window.xdgToplevelConfigure,
    .close = Window.xdgToplevelClose,
    .configure_bounds = Window.xdgToplevelConfigureBounds,
    .wm_capabilities = Window.xdgToplevelWmCapabilities,
};

pub const Window = struct {
    allocator: Allocator,
    platform: *LinuxPlatform,

    // Wayland objects
    wl_surface: ?*wayland.Surface = null,
    xdg_surface: ?*wayland.XdgSurface = null,
    xdg_toplevel: ?*wayland.XdgToplevel = null,
    decoration: ?*wayland.ZxdgToplevelDecorationV1 = null,
    viewport: ?*wayland.WpViewport = null,
    /// Bound only with a viewport. While bound, its `preferred_scale` sets
    /// `scale_factor` and `wl_surface.preferred_buffer_scale` is ignored.
    fractional_scale: ?*wayland.WpFractionalScaleV1 = null,

    // Window state. Both are *logical* pixels; multiply by `scale_factor` for
    // the physical swapchain extent.
    width_px: u32 = 800,
    height_px: u32 = 600,
    /// `width_px` and `height_px` as floats, which `context/window.zig` reads.
    size: Size = .{ .width = 800, .height = 600 },
    scale_factor: f64 = 1.0,
    configured: bool = false,
    closed: bool = false,

    /// Unique identifier for this window in the WindowRegistry.
    /// Set by WindowRegistry.register() after creation.
    window_id: WindowId = .invalid,

    pending_resize: bool = false,
    pending_width: u32 = 0,
    pending_height: u32 = 0,

    // Decoration state
    has_server_decorations: bool = false,

    // Rendering (Vulkan, or CPU into shared memory; see `Renderer`)
    renderer: Renderer,

    // Title storage. `xdg_toplevel.set_title` takes a C string, so the buffer
    // holds `title_bytes_max` payload bytes plus the terminating NUL.
    title_buf: [title_bytes_max + 1]u8 = undefined,
    title_len: usize = 0,

    // =========================================================================
    // IME (Input Method Editor) State
    // =========================================================================

    /// Marked (composing) text from IME
    marked_text: []const u8 = "",
    marked_text_buffer: [marked_text_bytes_max]u8 = undefined,

    /// Whether IME is currently active for this window
    ime_active: bool = false,

    // =========================================================================
    // Input state
    // =========================================================================

    /// Click tracker for multi-click detection
    click_tracker: linux_input.ClickTracker = .{},

    /// Key repeat tracker
    key_repeat_tracker: linux_input.KeyRepeatTracker = .{},

    /// Currently pressed mouse button (for drag detection)
    pressed_button: ?input.MouseButton = null,

    /// Called when window is about to close. Return false to prevent close.
    on_close: ?CloseCallback = null,

    /// User data pointer for callbacks
    user_data: ?*anyopaque = null,

    /// Set once the core host binds the window; see `CoreBinding`.
    core: ?CoreBinding = null,

    // Written only by the section of 0.3.1 calls below.
    dark_appearance: bool = false,
    needs_redraw: bool = false,
    render_deadline_ms: ?i64 = null,

    /// Close callback: called when window is about to close. Return false to prevent close.
    pub const CloseCallback = *const fn (*Self) bool;

    const Self = @This();

    /// Longest window title, in bytes, that `init` accepts.
    ///
    /// The bound exists because the title is stored inline (no allocation after
    /// initialization, `CLAUDE.md` §2) and must reach the compositor as a C
    /// string, so the buffer is one byte wider for the terminator.
    pub const title_bytes_max: usize = 255;

    /// Create the window and map it. The Wayland objects are created in
    /// dependency order and unwound in reverse by the errdefers here, so each
    /// helper below leaves nothing behind when it fails.
    pub fn init(allocator: Allocator, plat: *LinuxPlatform, options: *const WindowOptions) !*Self {
        std.debug.assert(options.width > 0);
        std.debug.assert(options.height > 0);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = Self{
            .allocator = allocator,
            .platform = plat,
            .width_px = @intFromFloat(options.width),
            .height_px = @intFromFloat(options.height),
            .size = .{ .width = options.width, .height = options.height },
            // Surface events may update the output's scale later.
            .scale_factor = plat.getScaleFactor(),
            .renderer = .{},
        };
        self.storeTitle(options.title);

        // Register before any Wayland object exists so that every later error
        // path unwinds through one errdefer rather than a second exit branch.
        self.window_id = try plat.registerWindow(self);
        errdefer {
            plat.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }

        try self.createSurface(plat);
        errdefer self.destroySurface();

        try self.createToplevel(plat, options);
        errdefer {
            if (self.xdg_toplevel) |tl| wayland.xdgToplevelDestroy(tl);
            self.xdg_toplevel = null;
            if (self.xdg_surface) |xs| wayland.xdgSurfaceDestroy(xs);
            self.xdg_surface = null;
        }

        self.requestServerDecorations(plat);

        // Commit to trigger the initial configure, and wait for it. This may
        // update scale_factor through the preferred_buffer_scale callback.
        wayland.surfaceCommit(self.wl_surface.?);
        _ = wayland.wl_display_roundtrip(plat.display.?);

        // errdefer for decoration (created above, may be null)
        errdefer {
            if (self.decoration) |dec| wayland.zxdgToplevelDecorationV1Destroy(dec);
            self.decoration = null;
        }

        self.createViewport(plat);
        errdefer {
            if (self.viewport) |vp| wayland.viewportDestroy(vp);
            self.viewport = null;
        }

        try self.mapWithRenderer(plat, options);

        // A newly mapped window claims focus. `setActiveWindowId` also derives
        // the `*LinuxWindow` that Wayland input dispatch needs, so publishing
        // the id alone keeps both authorities in agreement.
        plat.setActiveWindowId(self.window_id);

        std.debug.assert(self.window_id.isValid());
        std.debug.assert(self.wl_surface != null);
        return self;
    }

    /// Store the title as the C string `xdg_toplevel.set_title` takes. Over-long
    /// is a programmer error, and the clamp is what keeps a release build in
    /// bounds.
    fn storeTitle(self: *Self, title: []const u8) void {
        std.debug.assert(title.len <= title_bytes_max);
        const title_len = @min(title.len, title_bytes_max);
        @memcpy(self.title_buf[0..title_len], title[0..title_len]);
        self.title_buf[title_len] = 0;
        self.title_len = title_len;
        std.debug.assert(self.title_buf[self.title_len] == 0);
    }

    /// Create the `wl_surface` and listen for its scale. The last fallible step
    /// creates the surface, so a failure leaves nothing to destroy.
    fn createSurface(self: *Self, plat: *LinuxPlatform) !void {
        std.debug.assert(self.wl_surface == null);
        const compositor = plat.getCompositor() orelse return error.NoCompositor;
        self.wl_surface = wayland.compositorCreateSurface(compositor) orelse
            return error.FailedToCreateSurface;

        // Set up surface listener (uses module-level static listener)
        _ = wayland.surfaceAddListener(self.wl_surface.?, &surface_listener, self);
        self.bindFractionalScale(plat);
        std.debug.assert(self.wl_surface != null);
    }

    /// Undo `createSurface`. The fractional scale object goes before its surface.
    fn destroySurface(self: *Self) void {
        if (self.fractional_scale) |fractional_scale| {
            wayland.fractionalScaleDestroy(fractional_scale);
        }
        self.fractional_scale = null;
        if (self.wl_surface) |s| wayland.surfaceDestroy(s);
        self.wl_surface = null;
        std.debug.assert(self.fractional_scale == null);
        std.debug.assert(self.wl_surface == null);
    }

    /// Give the surface the xdg toplevel role, with its title, app id, and size
    /// hints. A failure destroys whatever this created.
    fn createToplevel(self: *Self, plat: *LinuxPlatform, options: *const WindowOptions) !void {
        std.debug.assert(self.wl_surface != null);
        std.debug.assert(self.xdg_surface == null);
        const xdg_wm_base = plat.getXdgWmBase() orelse return error.NoXdgWmBase;
        self.xdg_surface = wayland.xdgWmBaseGetXdgSurface(xdg_wm_base, self.wl_surface.?) orelse
            return error.FailedToCreateXdgSurface;
        errdefer {
            if (self.xdg_surface) |xs| wayland.xdgSurfaceDestroy(xs);
            self.xdg_surface = null;
        }

        // Set up XDG surface listener (uses module-level static listener)
        _ = wayland.xdgSurfaceAddListener(self.xdg_surface.?, &xdg_surface_listener, self);

        self.xdg_toplevel = wayland.xdgSurfaceGetToplevel(self.xdg_surface.?) orelse
            return error.FailedToCreateToplevel;
        const toplevel = self.xdg_toplevel.?;

        // Set up toplevel listener (uses module-level static listener)
        _ = wayland.xdgToplevelAddListener(toplevel, &toplevel_listener, self);

        wayland.xdgToplevelSetTitle(toplevel, @ptrCast(&self.title_buf));
        wayland.xdgToplevelSetAppId(toplevel, "gooey");
        if (options.min_size) |min| {
            wayland.xdgToplevelSetMinSize(
                toplevel,
                @intFromFloat(min.width),
                @intFromFloat(min.height),
            );
        }
        if (options.max_size) |max| {
            wayland.xdgToplevelSetMaxSize(
                toplevel,
                @intFromFloat(max.width),
                @intFromFloat(max.height),
            );
        }
        std.debug.assert(self.xdg_toplevel != null);
    }

    /// Ask for server-side decorations when the compositor offers them. Best
    /// effort: without them the window has no title bar.
    fn requestServerDecorations(self: *Self, plat: *LinuxPlatform) void {
        std.debug.assert(self.xdg_toplevel != null);
        std.debug.assert(self.decoration == null);
        const manager = plat.getDecorationManager() orelse {
            std.debug.print(
                "WARNING: No decoration manager available - window will have no title bar!\n",
                .{},
            );
            std.debug.print(
                "Your compositor may not support xdg-decoration-unstable-v1 protocol.\n",
                .{},
            );
            return;
        };
        std.debug.print(
            "Decoration manager available, requesting server-side decorations...\n",
            .{},
        );
        self.decoration = wayland.zxdgDecorationManagerV1GetToplevelDecoration(
            manager,
            self.xdg_toplevel.?,
        );
        if (self.decoration) |dec| {
            // Add listener to get decoration mode response
            _ = wayland.zxdgToplevelDecorationV1AddListener(dec, &decoration_listener, self);
            wayland.zxdgToplevelDecorationV1SetMode(dec, .server_side);
        }
    }

    /// Map buffers to the logical size: through a viewport (wp_viewporter),
    /// which lets the renderer draw at physical resolution, or else through
    /// the integer buffer scale.
    fn createViewport(self: *Self, plat: *LinuxPlatform) void {
        std.debug.assert(self.wl_surface != null);
        std.debug.assert(self.viewport == null);
        const viewporter = plat.getViewporter() orelse {
            // Fallback: use buffer scale (may not work correctly with Vulkan on all compositors)
            const scale_int: i32 = @intFromFloat(self.scale_factor);
            wayland.surfaceSetBufferScale(self.wl_surface.?, scale_int);
            return;
        };
        self.viewport = wayland.viewporterGetViewport(viewporter, self.wl_surface.?);
        if (self.viewport) |vp| {
            // Set destination to logical size - the compositor will scale our buffer to this size
            wayland.viewportSetDestination(vp, @intCast(self.width_px), @intCast(self.height_px));
        }
    }

    /// Set the window geometry, create the renderer on the committed surface
    /// state, and commit again, so pointer coordinates are logical once the
    /// compositor has applied the viewport.
    fn mapWithRenderer(self: *Self, plat: *LinuxPlatform, options: *const WindowOptions) !void {
        std.debug.assert(self.xdg_surface != null);
        std.debug.assert(self.wl_surface != null);
        // Set window geometry to logical size (what the user sees)
        wayland.xdgSurfaceSetWindowGeometry(
            self.xdg_surface.?,
            0,
            0,
            @intCast(self.width_px),
            @intCast(self.height_px),
        );

        // Commit surface state before creating Vulkan swapchain
        wayland.surfaceCommit(self.wl_surface.?);
        _ = wayland.wl_display_roundtrip(plat.display.?);

        const renderer_scale = self.scale_factor;
        try self.initRenderer(plat, options);

        // Final commit after Vulkan initialization
        wayland.surfaceCommit(self.wl_surface.?);

        // Roundtrip to ensure compositor has processed viewport state
        // This is important for HiDPI - pointer coordinates won't be in
        // the correct (logical) coordinate space until viewport is applied
        _ = wayland.wl_display_roundtrip(plat.display.?);

        // The core host starts from `scale_factor`, so a scale that arrived in
        // that roundtrip must reach the renderer's buffers here.
        if (self.scale_factor != renderer_scale) {
            self.renderer.resize(self.rendererViewport(&options.limits.window).size_px);
        }
    }

    /// Ask for the compositor's fractional scale (1.5 rather than the 2 that
    /// `wl_output` and `preferred_buffer_scale` round it up to). It applies only
    /// through a viewport, so without wp_viewporter the window keeps integer
    /// scales. Bound before the first commit, so a compositor that already
    /// knows the output can send the scale before the renderer is created.
    fn bindFractionalScale(self: *Self, plat: *LinuxPlatform) void {
        std.debug.assert(self.wl_surface != null);
        std.debug.assert(self.fractional_scale == null);
        const manager = plat.getFractionalScaleManager() orelse return;
        if (plat.getViewporter() == null) return;
        const fractional_scale = wayland.fractionalScaleManagerGetFractionalScale(
            manager,
            self.wl_surface.?,
        ) orelse {
            std.log.warn("wp_fractional_scale_v1: no proxy; keeping integer scales", .{});
            return;
        };
        // Fails only for a proxy that already has a listener, and this one is new.
        const added = wayland.fractionalScaleAddListener(
            fractional_scale,
            &fractional_scale_listener,
            self,
        );
        std.debug.assert(added);
        self.fractional_scale = fractional_scale;
    }

    /// Bind the renderer to the Wayland surface. Both renderers create their
    /// frames at physical pixel resolution, fitted to the window budget.
    fn initRenderer(self: *Self, plat: *LinuxPlatform, options: *const WindowOptions) !void {
        std.debug.assert(self.wl_surface != null);
        std.debug.assert(self.width_px > 0);
        std.debug.assert(self.height_px > 0);
        const native: NativeSurface = if (use_cpu_renderer) .{
            .shm = plat.getShm() orelse return error.NoShm,
            .surface = self.wl_surface.?,
        } else .{
            .display = @ptrCast(plat.getDisplay() orelse return error.NoDisplay),
            .surface = self.wl_surface.?,
        };
        const viewport = self.rendererViewport(&options.limits.window);
        const render_limits = backend.RenderLimits.fromResourceLimits(&options.limits);
        try self.renderer.initInPlace(&.{
            .native = @ptrCast(@constCast(&native)),
            .size_px = viewport.size_px,
            .scale_factor = viewport.scale_factor,
        }, &render_limits);
    }

    /// The framebuffer for the window's logical size and scale, fitted to the
    /// budget as the core host fits every frame's (`applyViewport`).
    fn rendererViewport(
        self: *const Self,
        window: *const limits_mod.WindowLimits,
    ) backend.Viewport {
        std.debug.assert(self.width_px > 0);
        std.debug.assert(self.scale_factor > 0);
        return backend.Viewport.fitLogical(
            @floatFromInt(self.width_px),
            @floatFromInt(self.height_px),
            @min(@as(f32, @floatCast(self.scale_factor)), renderer_scale_max),
            window,
        );
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

        // Drop every platform-held reference before any Wayland object dies,
        // so a queued event cannot be routed into a half-destroyed window.
        // `.invalid` makes a second deinit a no-op here rather than tripping
        // the registry's validity assertion.
        if (self.window_id.isValid()) {
            self.platform.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }
        if (self.platform.active_window == self) {
            // Re-elect rather than clear: `active_window` is the routing target
            // for every Wayland pointer, keyboard, and IME event, so a null here
            // with other windows still open would strand input. Unregistration
            // above already removed this window from the candidates.
            self.platform.reelectActiveWindow();
        }
        if (self.platform.touch_window == self) self.platform.touch_window = null;
        std.debug.assert(self.platform.active_window != self);

        // Destroy viewport
        if (self.viewport) |vp| {
            wayland.viewportDestroy(vp);
            self.viewport = null;
        }

        // Clean up renderer
        self.renderer.deinit();

        // Destroy Wayland objects in reverse order
        if (self.decoration) |dec| wayland.zxdgToplevelDecorationV1Destroy(dec);
        if (self.xdg_toplevel) |tl| wayland.xdgToplevelDestroy(tl);
        if (self.xdg_surface) |xs| wayland.xdgSurfaceDestroy(xs);
        self.destroySurface();

        std.debug.assert(!self.window_id.isValid());
        self.allocator.destroy(self);
    }

    // =========================================================================
    // Window Operations
    // =========================================================================

    /// Close this window: the core host's close handler runs first and may
    /// decline. Otherwise the window records `closed = true` and returns;
    /// teardown waits for `deinit`, because `close()` is reachable from inside
    /// this window's own input dispatch.
    pub fn close(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

        // Idempotent: the compositor and a key chord can both reach a window,
        // and running the handler twice would ask the application twice.
        if (self.closed) return;

        if (self.on_close) |callback| {
            if (!callback(self)) return; // Declined by the application.
        }

        self.markClosed();

        std.debug.assert(self.isClosed());
    }

    /// Record the close. Shared by the programmatic `close()` and the
    /// compositor-initiated `xdg_toplevel.close`.
    fn markClosed(self: *Self) void {
        std.debug.assert(!self.closed);
        std.debug.assert(self.window_id.isValid());

        self.closed = true;

        // A closed window stays registered until its owner reclaims it, but it
        // is no longer a legal input target, so focus must move on now rather
        // than at teardown. `reelectActiveWindow` skips closed windows, so it
        // cannot re-elect this one.
        if (self.platform.active_window == self) self.platform.reelectActiveWindow();

        std.debug.assert(self.closed);
        std.debug.assert(self.platform.active_window != self);
    }

    pub fn isClosed(self: *const Self) bool {
        return self.closed;
    }

    pub fn setCursorShape(self: *Self, shape: interface_mod.CursorShape) void {
        std.debug.assert(self.platform.pointer == null or self.platform.seat != null);
        std.debug.assert(self.platform.cursor_shape_device == null or self.platform.pointer != null);
        self.platform.setCursorShape(shape);
    }

    // =========================================================================
    // Calls from the 0.3.1 `context/window.zig`
    // =========================================================================
    //
    // The core never makes these calls. They stay only while that file
    // compiles, and go when phase 6 deletes it.

    /// Record the requested light/dark appearance.
    ///
    /// Advisory only: Wayland has no server-side appearance protocol, so the
    /// desktop environment owns the theme and the compositor cannot be told.
    /// The flag is stored rather than dropped so the value the application
    /// asked for stays observable instead of vanishing into a silent no-op.
    pub fn setAppearance(self: *Self, dark: bool) void {
        std.debug.assert(@intFromPtr(self) != 0);
        self.dark_appearance = dark;
        std.debug.assert(self.dark_appearance == dark);
    }

    pub fn getPlatform(self: *Self) *LinuxPlatform {
        std.debug.assert(@intFromPtr(self.platform) != 0);
        return self.platform;
    }

    pub fn requestRender(self: *Self) void {
        if (self.closed) return;
        self.needs_redraw = true;
        std.debug.assert(self.needs_redraw);
    }

    /// Keeps only the earliest deadline.
    pub fn requestRenderAfter(self: *Self, delay_ms: u32) void {
        std.debug.assert(delay_ms <= interface_mod.render_delay_ms_max);

        if (self.closed) return;
        if (delay_ms == 0) {
            self.requestRender();
            return;
        }

        const deadline_ms = awakeTimeMs() + delay_ms;
        if (self.render_deadline_ms) |armed_ms| {
            if (armed_ms <= deadline_ms) return;
        }
        self.render_deadline_ms = deadline_ms;

        std.debug.assert(self.render_deadline_ms.? <= deadline_ms);
    }

    // =========================================================================
    // IME Support
    // =========================================================================

    /// The composition the window keeps, as long as the text engines'
    /// preedit, which shows no more.
    pub const marked_text_bytes_max = core_text_engine.preedit_bytes_max;

    /// Set the marked (composing) text for IME. A longer composition is
    /// external input, so it is cut at a codepoint boundary, never inside a
    /// UTF-8 sequence, and the cut logged.
    pub fn setMarkedText(self: *Self, text: []const u8) void {
        const kept = core_clipboard.prefixFitting(text, marked_text_bytes_max);
        if (kept < text.len) {
            std.log.warn("IME composition of {d} bytes cut to {d}", .{ text.len, kept });
        }
        @memcpy(self.marked_text_buffer[0..kept], text[0..kept]);
        self.marked_text = self.marked_text_buffer[0..kept];
        std.debug.assert(self.marked_text.len <= marked_text_bytes_max);
        if (kept > 0 and kept < text.len) std.debug.assert(text[kept] & 0xC0 != 0x80);
    }

    /// Clear the marked text (composition ended or cancelled)
    pub fn clearMarkedText(self: *Self) void {
        self.marked_text = "";
    }

    /// Place the IME's candidate window against the caret, in window
    /// coordinates. The core host calls it when the focused field's caret moves.
    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        std.debug.assert(w >= 0);
        std.debug.assert(h >= 0);
        self.platform.setImeCursorRect(
            @intFromFloat(x),
            @intFromFloat(y),
            @intFromFloat(w),
            @intFromFloat(h),
        );
    }

    /// Check if there's active IME composition
    pub fn hasMarkedText(self: *const Self) bool {
        return self.marked_text.len > 0;
    }

    /// Enable IME text input for this window
    pub fn enableIme(self: *Self) void {
        self.platform.enableTextInput();
    }

    /// Disable IME text input for this window
    pub fn disableIme(self: *Self) void {
        self.platform.disableTextInput();
    }

    // =========================================================================
    // Core host binding
    // =========================================================================

    /// Set the close callback. Return false from callback to prevent window close.
    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        self.on_close = callback;
    }

    /// Set user data pointer
    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        self.user_data = data;
    }

    /// Get user data pointer with type cast
    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        if (self.user_data) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }

    // =========================================================================
    // Input Handling
    // =========================================================================

    /// Route one input event to the core. Events before `bindCore` reach
    /// nothing. Wayland and Vulkan framebuffer space are both Y-down (0 at
    /// top), matching the scene coordinate system, so no flipping is needed.
    pub fn handleInput(self: *Self, event: input.InputEvent) bool {
        // Track the pressed button for the platform's drag detection.
        switch (event) {
            .mouse_down => |m| {
                self.pressed_button = m.button;
            },
            .mouse_up => {
                self.pressed_button = null;
            },
            else => {},
        }

        const binding = self.core orelse return false;
        return pushCoreInput(binding, event, self.hasMarkedText());
    }

    /// Queue `event` for the core's next drain. Only a key the keymap claims
    /// counts as handled, so every other key still reaches the IME. While the
    /// IME holds marked text it owns every key (Escape cancels the
    /// composition, Return accepts a candidate), so a key down is neither
    /// queued nor claimed: no binding or `on_key` handler may act on a
    /// keystroke that only edited the composition. Windows drops
    /// `VK_PROCESSKEY` for the same reason.
    fn pushCoreInput(binding: CoreBinding, event: input.InputEvent, composing: bool) bool {
        if (composing) {
            if (event == .key_down) return false;
        }
        binding.queue.push(.{ .input = event });
        binding.schedule_tick(binding.context);
        return switch (event) {
            .key_down => |key| binding.query.keymapClaims(key),
            else => false,
        };
    }

    /// Bind a core app. Call once, before the host's render thread starts.
    pub fn bindCore(self: *Self, binding: CoreBinding) void {
        std.debug.assert(self.core == null);
        std.debug.assert(self.wl_surface != null);
        // The first configure arrived before the core existed; the host
        // reads `size` once bound and tells the core.
        if (self.pending_resize) self.applyPendingSize();
        self.core = binding;
        std.debug.assert(!self.pending_resize);
    }

    fn applyPendingSize(self: *Self) void {
        std.debug.assert(self.pending_resize);
        std.debug.assert(self.pending_width > 0);
        std.debug.assert(self.pending_height > 0);
        self.pending_resize = false;
        self.width_px = self.pending_width;
        self.height_px = self.pending_height;
        self.size = .{
            .width = @floatFromInt(self.pending_width),
            .height = @floatFromInt(self.pending_height),
        };
    }

    /// A core app resizes through its queue: the next built frame carries the
    /// new viewport, and the render thread resizes the swapchain and the
    /// surface's viewport before it presents that frame, so the new size and
    /// the buffer drawn for it reach the compositor in one commit.
    fn resizeCore(self: *Self, binding: CoreBinding) void {
        self.applyPendingSize();
        pushViewport(binding, self.size, self.scale_factor);
    }

    /// Adopt the compositor's scale at the same logical size. Once bound, the
    /// core rebuilds at the new scale and the render thread resizes the
    /// buffers before presenting that frame. Before, the host reads
    /// `scale_factor` when it binds. A configure whose size is still pending
    /// keeps it, and reports the new scale with it.
    fn applyScale(self: *Self, scale: f64) void {
        std.debug.assert(scale > 0);
        if (self.scale_factor == scale) return;
        self.scale_factor = scale;
        if (self.core) |binding| pushViewport(binding, self.size, scale);
        std.debug.assert(self.scale_factor == scale);
    }

    fn pushViewport(binding: CoreBinding, size: Size, scale: f64) void {
        std.debug.assert(size.width > 0);
        std.debug.assert(size.height > 0);
        std.debug.assert(scale > 0);
        binding.queue.push(.{ .window = .{ .resized = .{
            .width = @floatCast(size.width),
            .height = @floatCast(size.height),
            .scale_factor = @floatCast(scale),
        } } });
        binding.schedule_tick(binding.context);
    }

    // =========================================================================
    // Interactive Window Operations (for client-side decorations)
    // =========================================================================

    /// Start an interactive move operation.
    /// Call this in response to a pointer button press (e.g., on a title bar area).
    /// The compositor will take over and move the window until the button is released.
    pub fn startMove(self: *Self) void {
        const toplevel = self.xdg_toplevel orelse return;
        const seat = self.platform.seat orelse return;
        const serial = self.platform.last_pointer_serial;

        wayland.xdgToplevelMove(toplevel, seat, serial);
    }

    /// Start an interactive resize operation.
    /// Call this in response to a pointer button press (e.g., on window edges).
    /// The compositor will take over and resize the window until the button is released.
    pub fn startResize(self: *Self, edge: wayland.ResizeEdge) void {
        const toplevel = self.xdg_toplevel orelse return;
        const seat = self.platform.seat orelse return;
        const serial = self.platform.last_pointer_serial;

        wayland.xdgToplevelResize(toplevel, seat, serial, edge);
    }

    /// Determine which resize edge the mouse is near, if any.
    /// Returns null if not near any edge (inside the content area).
    pub fn getResizeEdge(self: *const Self, x: f64, y: f64, border_width: f64) ?wayland.ResizeEdge {
        const w: f64 = @floatFromInt(self.width_px);
        const h: f64 = @floatFromInt(self.height_px);

        const near_left = x < border_width;
        const near_right = x >= w - border_width;
        const near_top = y < border_width;
        const near_bottom = y >= h - border_width;

        if (near_top and near_left) return .top_left;
        if (near_top and near_right) return .top_right;
        if (near_bottom and near_left) return .bottom_left;
        if (near_bottom and near_right) return .bottom_right;
        if (near_top) return .top;
        if (near_bottom) return .bottom;
        if (near_left) return .left;
        if (near_right) return .right;

        return null;
    }

    /// Check if a point is in the "title bar" area (top of window for dragging).
    /// For client-side decorations, this might be the top N pixels of the window.
    pub fn isInTitleBar(self: *const Self, y: f64, title_bar_height: f64) bool {
        _ = self;
        return y < title_bar_height;
    }

    // =========================================================================
    // Wayland Callbacks
    // =========================================================================

    fn surfaceEnter(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        output: *wayland.Output,
    ) callconv(.c) void {
        _ = data;
        _ = surface;
        _ = output;
        // A scale change arrives as `preferred_buffer_scale`, or as
        // `wp_fractional_scale_v1.preferred_scale` while that is bound.
    }

    fn surfaceLeave(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        output: *wayland.Output,
    ) callconv(.c) void {
        _ = data;
        _ = surface;
        _ = output;
    }

    fn surfacePreferredScale(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        factor: i32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        // While bound, `preferred_scale` carries the exact scale; this is the
        // same scale rounded up (2 for 1.5), and would draw buffers too large.
        if (self.fractional_scale != null) return;
        if (factor < 1) {
            std.log.warn("wl_surface: ignoring preferred buffer scale {d}", .{factor});
            return;
        }
        const new_scale: f64 = @floatFromInt(factor);
        if (self.scale_factor == new_scale) return;
        // The viewport maps buffers to the logical size; without one, the
        // compositor needs the buffer scale.
        if (self.viewport == null) wayland.surfaceSetBufferScale(surface, factor);
        self.applyScale(new_scale);
    }

    /// The compositor's preferred scale in 120ths (180 is 1.5). The viewport's
    /// destination stays the logical size, so only the buffers change.
    fn fractionalPreferredScale(
        data: ?*anyopaque,
        fractional_scale: *wayland.WpFractionalScaleV1,
        scale_120ths: u32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        std.debug.assert(self.fractional_scale == fractional_scale);
        // The protocol has no zero scale; it would make empty buffers.
        if (scale_120ths == 0) {
            std.log.warn("wp_fractional_scale_v1: ignoring preferred scale 0", .{});
            return;
        }
        self.applyScale(interface_mod.scaleFromSteps(scale_120ths));
    }

    fn surfacePreferredTransform(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        transform: u32,
    ) callconv(.c) void {
        _ = data;
        _ = surface;
        _ = transform;
        // Transform is informational, we don't need to handle it for now
    }

    fn xdgSurfaceConfigure(
        data: ?*anyopaque,
        xdg_surface: *wayland.XdgSurface,
        serial: u32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));

        // Acknowledge the configure
        wayland.xdgSurfaceAckConfigure(xdg_surface, serial);

        // Apply pending size changes
        if (self.pending_width > 0 and self.pending_height > 0) {
            self.pending_resize = true;
            if (self.core) |binding| self.resizeCore(binding);
        }

        self.configured = true;
    }

    fn xdgToplevelConfigure(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
        width_px: i32,
        height_px: i32,
        states: *anyopaque,
    ) callconv(.c) void {
        _ = xdg_toplevel;
        _ = states;
        const self: *Self = @ptrCast(@alignCast(data));

        // Width/height of 0 means we can choose our own size
        if (width_px > 0 and height_px > 0) {
            self.pending_width = @intCast(width_px);
            self.pending_height = @intCast(height_px);
        } else {
            self.pending_width = self.width_px;
            self.pending_height = self.height_px;
        }
    }

    fn xdgToplevelConfigureBounds(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
        width_px: i32,
        height_px: i32,
    ) callconv(.c) void {
        _ = data;
        _ = xdg_toplevel;
        _ = width_px;
        _ = height_px;
        // Configure bounds is informational - the compositor suggests max size
        // We don't need to enforce it for now
    }

    fn xdgToplevelWmCapabilities(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
        capabilities: *anyopaque,
    ) callconv(.c) void {
        _ = data;
        _ = xdg_toplevel;
        _ = capabilities;
        // WM capabilities tells us what the compositor supports
        // We don't need to handle it for now
    }

    /// The compositor asked this toplevel to close (titlebar button, window
    /// menu, or a session request).
    ///
    /// Routed through `close()` so the compositor request and a programmatic
    /// close run the same handler and the same state transition. Destroying
    /// the window here would free it underneath the Wayland dispatch calling
    /// us.
    fn xdgToplevelClose(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
    ) callconv(.c) void {
        _ = xdg_toplevel;
        const self: *Self = @ptrCast(@alignCast(data));
        std.debug.assert(@intFromPtr(self) != 0);

        self.close();

        // Nothing was torn down: `window_id` is invalidated only by `deinit`,
        // so this proves the window is still registered and still resolvable
        // by the owner that will reclaim it.
        std.debug.assert(self.window_id.isValid());
    }

    fn decorationConfigure(
        data: ?*anyopaque,
        decoration: *wayland.ZxdgToplevelDecorationV1,
        mode: wayland.ZxdgToplevelDecorationV1Mode,
    ) callconv(.c) void {
        _ = decoration;
        const self: *Self = @ptrCast(@alignCast(data));

        switch (mode) {
            .server_side => {
                std.debug.print("Compositor will provide window decorations (server-side)\n", .{});
                self.has_server_decorations = true;
            },
            .client_side => {
                std.debug.print("WARNING: Compositor requires client-side decorations (not implemented)\n", .{});
                std.debug.print("Window will have no title bar - cannot move/resize/close with mouse\n", .{});
                self.has_server_decorations = false;
            },
            .undefined => {
                std.debug.print("WARNING: Decoration mode undefined\n", .{});
                self.has_server_decorations = false;
            },
        }
    }
};
