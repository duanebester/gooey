//! LinuxWindow - Window implementation for Linux/Wayland
//!
//! Provides window creation and management using Wayland's XDG shell protocol,
//! with GPU rendering via Vulkan.

const std = @import("std");
const wayland = @import("wayland.zig");
const VulkanRenderer = @import("vk_renderer.zig").VulkanRenderer;
const vk_atlas = @import("vk_atlas.zig");
const LinuxPlatform = @import("platform.zig").LinuxPlatform;
const interface_mod = @import("../interface.zig");
const WindowId = interface_mod.WindowId;
const geometry = @import("../../core/geometry.zig");
const Size = geometry.Size(f64);
const scene_mod = @import("../../scene/mod.zig");
const text_mod = @import("../../text/mod.zig");
const svg_mod = @import("../../svg/atlas.zig");
const input = @import("../../input/events.zig");
const linux_input = @import("input.zig");

const Allocator = std.mem.Allocator;
const WindowOptions = interface_mod.WindowOptions;

// Static listeners - must persist for lifetime of Wayland objects
const surface_listener = wayland.SurfaceListener{
    .enter = Window.surfaceEnter,
    .leave = Window.surfaceLeave,
    .preferred_buffer_scale = Window.surfacePreferredScale,
    .preferred_buffer_transform = Window.surfacePreferredTransform,
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

// Frame callback listener - must be static to persist across scheduleFrame() calls
const frame_callback_listener = wayland.CallbackListener{
    .done = Window.frameCallback,
};

pub const Window = struct {
    allocator: Allocator,
    platform: *LinuxPlatform,

    // Wayland objects
    wl_surface: ?*wayland.Surface = null,
    xdg_surface: ?*wayland.XdgSurface = null,
    xdg_toplevel: ?*wayland.XdgToplevel = null,
    decoration: ?*wayland.ZxdgToplevelDecorationV1 = null,
    frame_callback: ?*wayland.Callback = null,
    viewport: ?*wayland.WpViewport = null,

    // Window state.
    //
    // These carry the `_px` suffix because `width`/`height` are taken by the
    // contract's accessor methods, and Zig puts fields and declarations in one
    // struct namespace. Both are *logical* pixels; multiply by `scale_factor`
    // for the physical swapchain extent.
    width_px: u32 = 800,
    height_px: u32 = 600,
    /// Size in logical pixels (for API compatibility with other platforms)
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

    // Input state
    mouse_x: f64 = 0,
    mouse_y: f64 = 0,
    mouse_inside: bool = false,

    // Decoration state
    has_server_decorations: bool = false,

    // Rendering (Vulkan)
    renderer: VulkanRenderer,
    background_color: geometry.Color = geometry.Color.rgba(0.2, 0.2, 0.25, 1.0),

    /// Translucent-background style requested by the application.
    ///
    /// Stored but ignored at render time: Wayland has no portable window-blur
    /// protocol, which is why `LinuxPlatform.capabilities.glass_effects` is
    /// false. Only `getClearColor` consults it, so that a compositor which
    /// does composite behind the surface has something to show through.
    glass_style: interface_mod.GlassStyle = .none,

    /// Last appearance requested via `setAppearance`. Advisory only; see there.
    dark_appearance: bool = false,

    needs_redraw: bool = true,
    has_presented_frame: bool = false,

    /// Continuously schedule frames at vsync rate for immediate-mode UI.
    /// Hidden windows are throttled by the platform event loop while their
    /// compositor frame callback is withheld.
    continuous_render: bool = true,

    // Scene reference (set externally)
    scene: ?*const scene_mod.Scene = null,
    text_atlas: ?*const text_mod.Atlas = null,
    last_atlas_generation: u32 = 0,
    svg_atlas: ?*const text_mod.Atlas = null,
    last_svg_atlas_generation: u32 = 0,
    image_atlas: ?*const text_mod.Atlas = null,
    last_image_atlas_generation: u32 = 0,

    // Title storage. `xdg_toplevel.set_title` takes a C string, so the buffer
    // holds `title_bytes_max` payload bytes plus the terminating NUL.
    title_buf: [title_bytes_max + 1]u8 = undefined,
    title_len: usize = 0,

    // =========================================================================
    // IME (Input Method Editor) State
    // =========================================================================

    /// Marked (composing) text from IME
    marked_text: []const u8 = "",
    marked_text_buffer: [256]u8 = undefined,

    /// Inserted text from IME (committed)
    inserted_text: []const u8 = "",
    inserted_text_buffer: [256]u8 = undefined,

    /// Whether IME is currently active for this window
    ime_active: bool = false,

    /// IME cursor rect in window coordinates (for candidate window positioning)
    ime_cursor_rect: geometry.RectF = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1, .height = 20 } },

    // =========================================================================
    // Input State & Callbacks
    // =========================================================================

    /// Click tracker for multi-click detection
    click_tracker: linux_input.ClickTracker = .{},

    /// Key repeat tracker
    key_repeat_tracker: linux_input.KeyRepeatTracker = .{},

    /// Currently pressed mouse button (for drag detection)
    pressed_button: ?input.MouseButton = null,

    /// Called for input events. Return true if handled.
    on_input: ?InputCallback = null,

    /// Called each frame when rendering is needed.
    on_render: ?RenderCallback = null,

    /// Called when window is about to close. Return false to prevent close.
    on_close: ?CloseCallback = null,

    /// Called when window size changes.
    on_resize: ?ResizeCallback = null,

    /// Called after input handling completes.
    /// Use this for operations that may run nested event loops (e.g., modal dialogs).
    on_post_input: ?PostInputCallback = null,

    /// User data pointer for callbacks
    user_data: ?*anyopaque = null,

    // =========================================================================
    // GPU Timing (reported to profiler at start of next frame)
    // =========================================================================

    /// Time spent in Vulkan command recording + submit + present (ns)
    last_gpu_submit_ns: u64 = 0,
    /// Time spent uploading atlas textures to GPU (ns)
    last_atlas_upload_ns: u64 = 0,

    /// Input callback type: return true if the event was handled
    pub const InputCallback = *const fn (*Self, input.InputEvent) bool;

    /// Render callback type: called each frame before drawing
    pub const RenderCallback = *const fn (*Self) void;

    /// Close callback: called when window is about to close. Return false to prevent close.
    pub const CloseCallback = *const fn (*Self) bool;

    /// Resize callback: called when window size changes
    pub const ResizeCallback = *const fn (*Self, f64, f64) void;

    /// Post-input callback: called after input handling.
    /// Safe for operations that run nested event loops (modal dialogs, etc).
    pub const PostInputCallback = *const fn (*Self) void;

    const Self = @This();

    /// Longest window title, in bytes, that `setTitle` accepts.
    ///
    /// The bound exists because the title is stored inline (no allocation after
    /// initialization, `CLAUDE.md` §2) and must reach the compositor as a C
    /// string, so the buffer is one byte wider for the terminator.
    pub const title_bytes_max: usize = 255;

    pub fn init(allocator: Allocator, plat: *LinuxPlatform, options: *const WindowOptions) !*Self {
        std.debug.assert(options.width > 0);
        std.debug.assert(options.height > 0);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Get initial scale factor from platform (may be updated later by surface events)
        const initial_scale = plat.getScaleFactor();

        self.* = Self{
            .allocator = allocator,
            .platform = plat,
            .width_px = @intFromFloat(options.width),
            .height_px = @intFromFloat(options.height),
            .size = .{ .width = options.width, .height = options.height },
            .scale_factor = initial_scale,
            .background_color = options.background_color,
            .glass_style = options.glass_style,
            .renderer = VulkanRenderer.init(allocator),
        };

        // Store title. Same contract as `setTitle`: over-long is a programmer
        // error, and the clamp is what keeps a release build in bounds.
        std.debug.assert(options.title.len <= title_bytes_max);
        const title_len = @min(options.title.len, title_bytes_max);
        @memcpy(self.title_buf[0..title_len], options.title[0..title_len]);
        self.title_buf[title_len] = 0;
        self.title_len = title_len;

        // Register before any Wayland object exists so that every later error
        // path unwinds through one errdefer rather than a second exit branch.
        self.window_id = try plat.registerWindow(self);
        errdefer {
            plat.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }

        // Create Wayland surface
        const compositor = plat.getCompositor() orelse return error.NoCompositor;
        self.wl_surface = wayland.compositorCreateSurface(compositor) orelse return error.FailedToCreateSurface;
        errdefer {
            if (self.wl_surface) |s| wayland.surfaceDestroy(s);
            self.wl_surface = null;
        }

        // Set up surface listener (uses module-level static listener)
        _ = wayland.surfaceAddListener(self.wl_surface.?, &surface_listener, self);

        // Create XDG surface
        const xdg_wm_base = plat.getXdgWmBase() orelse return error.NoXdgWmBase;
        self.xdg_surface = wayland.xdgWmBaseGetXdgSurface(xdg_wm_base, self.wl_surface.?) orelse return error.FailedToCreateXdgSurface;
        errdefer {
            if (self.xdg_surface) |xs| wayland.xdgSurfaceDestroy(xs);
            self.xdg_surface = null;
        }

        // Set up XDG surface listener (uses module-level static listener)
        _ = wayland.xdgSurfaceAddListener(self.xdg_surface.?, &xdg_surface_listener, self);

        // Create XDG toplevel
        self.xdg_toplevel = wayland.xdgSurfaceGetToplevel(self.xdg_surface.?) orelse return error.FailedToCreateToplevel;
        errdefer {
            if (self.xdg_toplevel) |tl| wayland.xdgToplevelDestroy(tl);
            self.xdg_toplevel = null;
        }

        // Set up toplevel listener (uses module-level static listener)
        _ = wayland.xdgToplevelAddListener(self.xdg_toplevel.?, &toplevel_listener, self);

        // Set window properties
        wayland.xdgToplevelSetTitle(self.xdg_toplevel.?, @ptrCast(&self.title_buf));
        wayland.xdgToplevelSetAppId(self.xdg_toplevel.?, "gooey");

        // Set size hints
        if (options.min_size) |min| {
            wayland.xdgToplevelSetMinSize(
                self.xdg_toplevel.?,
                @intFromFloat(min.width),
                @intFromFloat(min.height),
            );
        }
        if (options.max_size) |max| {
            wayland.xdgToplevelSetMaxSize(
                self.xdg_toplevel.?,
                @intFromFloat(max.width),
                @intFromFloat(max.height),
            );
        }

        // Request server-side decorations if available
        if (plat.getDecorationManager()) |dm| {
            std.debug.print("Decoration manager available, requesting server-side decorations...\n", .{});
            self.decoration = wayland.zxdgDecorationManagerV1GetToplevelDecoration(dm, self.xdg_toplevel.?);
            if (self.decoration) |dec| {
                // Add listener to get decoration mode response
                _ = wayland.zxdgToplevelDecorationV1AddListener(dec, &decoration_listener, self);
                wayland.zxdgToplevelDecorationV1SetMode(dec, .server_side);
            }
        } else {
            std.debug.print("WARNING: No decoration manager available - window will have no title bar!\n", .{});
            std.debug.print("Your compositor may not support xdg-decoration-unstable-v1 protocol.\n", .{});
        }

        // Commit surface to trigger configure events
        wayland.surfaceCommit(self.wl_surface.?);

        // Wait for initial configure - this may update scale_factor via preferred_buffer_scale callback
        _ = wayland.wl_display_roundtrip(plat.display.?);

        // errdefer for decoration (created above, may be null)
        errdefer {
            if (self.decoration) |dec| wayland.zxdgToplevelDecorationV1Destroy(dec);
            self.decoration = null;
        }

        // Create viewport for HiDPI scaling (preferred method over set_buffer_scale for Vulkan)
        // wp_viewporter allows us to render at physical resolution and display at logical size
        if (plat.getViewporter()) |viewporter| {
            self.viewport = wayland.viewporterGetViewport(viewporter, self.wl_surface.?);
            if (self.viewport) |vp| {
                // Set destination to logical size - the compositor will scale our buffer to this size
                wayland.viewportSetDestination(
                    vp,
                    @intCast(self.width_px),
                    @intCast(self.height_px),
                );
            }
        } else {
            // Fallback: use buffer scale (may not work correctly with Vulkan on all compositors)
            const scale_int: i32 = @intFromFloat(self.scale_factor);
            wayland.surfaceSetBufferScale(self.wl_surface.?, scale_int);
        }

        // errdefer for viewport (created above, may be null)
        errdefer {
            if (self.viewport) |vp| wayland.viewportDestroy(vp);
            self.viewport = null;
        }

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

        // Initialize Vulkan renderer with Wayland surface
        // Swapchain will be created at physical pixel resolution
        const wl_display = plat.getDisplay() orelse return error.NoDisplay;
        try self.renderer.initWithWaylandSurface(
            wl_display,
            @ptrCast(self.wl_surface),
            self.width_px,
            self.height_px,
            self.scale_factor,
        );

        // Final commit after Vulkan initialization
        wayland.surfaceCommit(self.wl_surface.?);

        // Roundtrip to ensure compositor has processed viewport state
        // This is important for HiDPI - pointer coordinates won't be in
        // the correct (logical) coordinate space until viewport is applied
        _ = wayland.wl_display_roundtrip(plat.display.?);

        // A newly mapped window claims focus. `setActiveWindowId` also derives
        // the `*LinuxWindow` that Wayland input dispatch needs, so publishing
        // the id alone keeps both authorities in agreement.
        plat.setActiveWindowId(self.window_id);

        std.debug.assert(self.window_id.isValid());
        std.debug.assert(self.wl_surface != null);
        return self;
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

        // Cancel any pending frame callback
        if (self.frame_callback) |cb| {
            wayland.callbackDestroy(cb);
        }

        // Clean up renderer
        self.renderer.deinit();

        // Destroy Wayland objects in reverse order
        if (self.decoration) |dec| wayland.zxdgToplevelDecorationV1Destroy(dec);
        if (self.xdg_toplevel) |tl| wayland.xdgToplevelDestroy(tl);
        if (self.xdg_surface) |xs| wayland.xdgSurfaceDestroy(xs);
        if (self.wl_surface) |s| wayland.surfaceDestroy(s);

        std.debug.assert(!self.window_id.isValid());
        self.allocator.destroy(self);
    }

    // =========================================================================
    // Public Interface
    // =========================================================================

    /// Window width in logical pixels.
    pub fn width(self: *const Self) u32 {
        return self.width_px;
    }

    /// Window height in logical pixels.
    pub fn height(self: *const Self) u32 {
        return self.height_px;
    }

    /// Window width in logical pixels (convenience alias for `width`)
    pub fn widthPx(self: *const Self) u32 {
        return self.width_px;
    }

    /// Window height in logical pixels (convenience alias for `height`)
    pub fn heightPx(self: *const Self) u32 {
        return self.height_px;
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        return .{
            .width = @floatFromInt(self.width_px),
            .height = @floatFromInt(self.height_px),
        };
    }

    pub fn getScaleFactor(self: *const Self) f64 {
        return self.scale_factor;
    }

    /// Copy `title` into the fixed title buffer and publish it to the
    /// compositor.
    ///
    /// An over-long title is a programmer error here, exactly as it is on web
    /// (`title.len <= title_bytes_max`) and in the test backend. This used to
    /// truncate silently, so the same call that trips an assertion on two
    /// targets quietly produced a different window title on the third.
    ///
    /// The clamp is kept as well, and is not a second policy: with assertions
    /// elided in release builds it is what keeps the `@memcpy` inside
    /// `title_buf` instead of overrunning it.
    pub fn setTitle(self: *Self, title: []const u8) void {
        std.debug.assert(title.len <= title_bytes_max);
        std.debug.assert(self.title_buf.len == title_bytes_max + 1);

        const len = @min(title.len, title_bytes_max);
        @memcpy(self.title_buf[0..len], title[0..len]);
        // NUL-terminate, and zero nothing else: the tail beyond the terminator
        // is never read, and `xdgToplevelSetTitle` stops at the first zero.
        self.title_buf[len] = 0;
        self.title_len = len;

        std.debug.assert(self.title_len <= title_bytes_max);

        if (self.xdg_toplevel) |tl| {
            wayland.xdgToplevelSetTitle(tl, @ptrCast(&self.title_buf));
        }
    }

    // =========================================================================
    // Window Operations
    // =========================================================================

    /// Request focus for this window.
    ///
    /// Wayland gives the compositor sole authority over activation: a client
    /// cannot raise itself, and there is no protocol error to report when the
    /// request is declined. Without `xdg-activation-v1` there is nothing to
    /// send, so this schedules a redraw and nothing more.
    ///
    /// The previous comment claimed it "request[s] a render", but the body was
    /// `_ = self;` and did not. Callers such as `WindowHandle.focus` publish a
    /// new active window id immediately afterwards, so a silent no-op here left
    /// `getActiveWindowId()` reporting a window the compositor had never been
    /// asked about. Redrawing is the only honest action available, and
    /// `capabilities` carries no `can_raise_window` flag yet to express the
    /// rest.
    pub fn focus(self: *Self) void {
        std.debug.assert(!self.closed);

        self.requestRender();

        std.debug.assert(self.needs_redraw);
    }

    /// Close this window programmatically.
    ///
    /// The veto callback runs first and may decline the close. Otherwise the
    /// window records `closed = true`, stops presenting, and returns. It is
    /// deliberately neither torn down here nor allowed to stop the host loop.
    ///
    /// Teardown cannot happen here: `close()` is reachable from inside this
    /// window's own input dispatch, where the `Cx` being dispatched lives in
    /// the `WindowContext` that teardown would free. The owning `App` reclaims
    /// the window from a safe point (`App.drainClosedWindows`, which polls
    /// `isClosed()`), and `App.checkQuitCondition` decides whether losing the
    /// last window should quit.
    ///
    /// This used to end with `platform.quit()`, which made closing any single
    /// window terminate the whole application — Linux multi-window was
    /// effectively single-window. macOS has always routed through the delegate
    /// to the owning `App` instead; this now matches.
    pub fn close(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

        // Idempotent: `App.closeWindowById` and the compositor can both reach
        // a window, and re-running the veto would ask the application twice.
        if (self.closed) return;

        if (self.on_close) |callback| {
            if (!callback(self)) return; // Declined by the application.
        }

        self.markClosed();

        std.debug.assert(self.isClosed());
    }

    /// Record the close and stop this window from presenting further frames.
    ///
    /// Shared by the programmatic `close()` and the compositor-initiated
    /// `xdg_toplevel.close`, so a titlebar click and an application call
    /// converge on one state transition exactly as they do on macOS, where
    /// both arrive at `handleClose`.
    ///
    /// An outstanding `wl_callback` is left in place rather than destroyed:
    /// `deinit` owns exactly one destroy of it, and when it fires `renderFrame`
    /// returns immediately while neither `continuous_render` nor `needs_redraw`
    /// asks for a successor, so the callback chain retires by itself.
    fn markClosed(self: *Self) void {
        std.debug.assert(!self.closed);
        std.debug.assert(self.window_id.isValid());

        self.closed = true;
        self.needs_redraw = false;
        self.continuous_render = false;

        // A closed window stays registered until its owner reclaims it, but it
        // is no longer a legal input target, so focus must move on now rather
        // than at teardown. `reelectActiveWindow` skips closed windows, so it
        // cannot re-elect this one.
        if (self.platform.active_window == self) self.platform.reelectActiveWindow();

        std.debug.assert(self.closed);
        std.debug.assert(self.platform.active_window != self);
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        self.background_color = color;
        self.requestRender();
    }

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

    /// Effective framebuffer clear color.
    ///
    /// Applied by `renderFrame` through `VulkanRenderer.setClearColor`, which
    /// records it into the next render pass.
    ///
    /// A glass style needs a transparent clear so a host-composited backdrop
    /// shows through. Wayland cannot produce the blur itself (see
    /// `glass_style`), so on this backend the transparent clear is the whole
    /// of the effect, and it only shows if the compositor honours the
    /// surface's alpha.
    pub fn getClearColor(self: *const Self) geometry.Color {
        std.debug.assert(self.background_color.a >= 0.0);
        std.debug.assert(self.background_color.a <= 1.0);

        if (self.glass_style.needsTransparentClear()) return geometry.Color.transparent;
        return self.background_color;
    }

    pub fn getMousePosition(self: *const Self) geometry.Point(f64) {
        return .{
            .x = self.mouse_x,
            .y = self.mouse_y,
        };
    }

    pub fn isMouseInside(self: *const Self) bool {
        return self.mouse_inside;
    }

    /// Get the unique identifier for this window.
    pub fn getWindowId(self: *const Self) WindowId {
        return self.window_id;
    }

    /// The platform that owns this window.
    ///
    /// Contract-pinned so shared code can reach the host without spelling a
    /// per-backend field name; see `contract.verifyWindowLifecycle`.
    pub fn getPlatform(self: *Self) *LinuxPlatform {
        std.debug.assert(@intFromPtr(self.platform) != 0);
        return self.platform;
    }

    pub fn isClosed(self: *const Self) bool {
        return self.closed;
    }

    pub fn requestRender(self: *Self) void {
        // A closed window never presents again (`renderFrame` returns at once),
        // so arming a `wl_callback` here would start a chain that re-schedules
        // itself every vsync on a window that can only ever drop the frame.
        // Setters such as `setBackgroundColor` still reach a closed window
        // between the close and the owner's reclaim, so this must be checked
        // here and not only at the call sites.
        if (self.closed) return;

        self.needs_redraw = true;
        self.scheduleFrame();

        std.debug.assert(self.needs_redraw);
        std.debug.assert(!self.closed);
    }

    pub fn setCursorShape(self: *Self, shape: interface_mod.CursorShape) void {
        std.debug.assert(self.platform.pointer == null or self.platform.seat != null);
        std.debug.assert(self.platform.cursor_shape_device == null or self.platform.pointer != null);
        self.platform.setCursorShape(shape);
    }

    pub fn setScene(self: *Self, scene: *const scene_mod.Scene) void {
        self.scene = scene;
    }

    pub fn setTextAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        self.text_atlas = atlas;
    }

    /// Set the SVG atlas for icon rendering
    pub fn setSvgAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        self.svg_atlas = atlas;
    }

    /// Set the image atlas for raster image rendering
    pub fn setImageAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        self.image_atlas = atlas;
    }

    // =========================================================================
    // IME Support
    // =========================================================================

    /// Set the marked (composing) text for IME
    pub fn setMarkedText(self: *Self, text: []const u8) void {
        if (text.len > self.marked_text_buffer.len) {
            @memcpy(self.marked_text_buffer[0..], text[0..self.marked_text_buffer.len]);
            self.marked_text = self.marked_text_buffer[0..self.marked_text_buffer.len];
        } else {
            @memcpy(self.marked_text_buffer[0..text.len], text);
            self.marked_text = self.marked_text_buffer[0..text.len];
        }
    }

    /// Clear the marked text (composition ended or cancelled)
    pub fn clearMarkedText(self: *Self) void {
        self.marked_text = "";
    }

    /// Set the inserted text for IME (copies to window-owned buffer)
    pub fn setInsertedText(self: *Self, text: []const u8) void {
        if (text.len > self.inserted_text_buffer.len) {
            @memcpy(self.inserted_text_buffer[0..], text[0..self.inserted_text_buffer.len]);
            self.inserted_text = self.inserted_text_buffer[0..self.inserted_text_buffer.len];
        } else {
            @memcpy(self.inserted_text_buffer[0..text.len], text);
            self.inserted_text = self.inserted_text_buffer[0..text.len];
        }
    }

    /// Set the IME cursor rect (call from TextInput during render)
    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        self.ime_cursor_rect = geometry.RectF.init(x, y, w, h);

        // Update the platform's text input cursor rectangle
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
    // Input Callback Management
    // =========================================================================

    /// Set the input callback
    pub fn setInputCallback(self: *Self, callback: ?InputCallback) void {
        self.on_input = callback;
    }

    /// Set the render callback
    pub fn setRenderCallback(self: *Self, callback: ?RenderCallback) void {
        self.on_render = callback;
    }

    /// Set the close callback. Return false from callback to prevent window close.
    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        self.on_close = callback;
    }

    /// Set the resize callback
    pub fn setResizeCallback(self: *Self, callback: ?ResizeCallback) void {
        self.on_resize = callback;
    }

    /// Set the post-input callback (called after input handling completes)
    pub fn setPostInputCallback(self: *Self, callback: ?PostInputCallback) void {
        self.on_post_input = callback;
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

    /// Handle an input event and dispatch to callback
    /// Note: Wayland uses Y-down (0 at top), which matches our scene coordinate system.
    /// The Vulkan viewport uses negative height to flip Y-axis for OpenGL/Metal-compatible
    /// NDC coordinates, so no coordinate flipping is needed here.
    pub fn handleInput(self: *Self, event: input.InputEvent) bool {
        // Track mouse position and inside state
        switch (event) {
            .mouse_down, .mouse_up, .mouse_moved, .mouse_dragged => |m| {
                self.mouse_x = m.position.x;
                self.mouse_y = m.position.y;
            },
            .mouse_entered => |m| {
                self.mouse_x = m.position.x;
                self.mouse_y = m.position.y;
                self.mouse_inside = true;
            },
            .mouse_exited => |m| {
                self.mouse_x = m.position.x;
                self.mouse_y = m.position.y;
                self.mouse_inside = false;
            },
            else => {},
        }

        // Track pressed button for drag detection
        switch (event) {
            .mouse_down => |m| {
                self.pressed_button = m.button;
            },
            .mouse_up => {
                self.pressed_button = null;
            },
            else => {},
        }

        // Dispatch to user callback
        var handled = false;
        if (self.on_input) |callback| {
            handled = callback(self, event);
        }

        // Call post-input callback after input handling.
        // This is safe for operations that run nested event loops (modal dialogs).
        if (self.on_post_input) |post_callback| {
            post_callback(self);
        }

        // Request redraw after input
        self.requestRender();
        return handled;
    }

    /// Get current modifier state from platform
    pub fn getModifiers(self: *const Self) input.Modifiers {
        return linux_input.modifiersFromFlags(
            self.platform.modifier_shift,
            self.platform.modifier_ctrl,
            self.platform.modifier_alt,
            self.platform.modifier_super,
        );
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

    /// Schedule a frame callback for the next vsync
    fn scheduleFrame(self: *Self) void {
        if (self.frame_callback != null) return; // Already scheduled
        if (self.wl_surface == null) return;

        self.frame_callback = wayland.surfaceFrame(self.wl_surface.?);
        if (self.frame_callback) |cb| {
            // Use static listener - local variables would be dangling pointers!
            _ = wayland.callbackAddListener(cb, &frame_callback_listener, self);
        }
        wayland.surfaceCommit(self.wl_surface.?);
    }

    /// Render the current frame
    pub fn renderFrame(self: *Self) void {
        // A closed window holds its Vulkan resources until its owner reclaims
        // it, but must never present again: its `WindowContext` may already be
        // on the way out. This also retires an in-flight frame callback rather
        // than letting it drive a zombie render chain (see `markClosed`).
        if (self.closed) return;
        if (!self.configured) return;
        if (!self.needs_redraw and !self.pending_resize) return;

        // Clear before invoking application code so requestRender() calls made
        // while building an animation survive for the following frame.
        self.needs_redraw = false;

        // Handle pending resize
        if (self.pending_resize) {
            const old_width = self.size.width;
            const old_height = self.size.height;

            self.width_px = self.pending_width;
            self.height_px = self.pending_height;
            self.size = .{
                .width = @floatFromInt(self.pending_width),
                .height = @floatFromInt(self.pending_height),
            };
            // Update viewport destination size for HiDPI scaling
            if (self.viewport) |vp| {
                wayland.viewportSetDestination(
                    vp,
                    @intCast(self.width_px),
                    @intCast(self.height_px),
                );
            } else if (self.wl_surface) |surface| {
                // Fallback to buffer scale
                const scale_int: i32 = @intFromFloat(self.scale_factor);
                wayland.surfaceSetBufferScale(surface, scale_int);
            }
            if (self.xdg_surface) |xdg| {
                wayland.xdgSurfaceSetWindowGeometry(
                    xdg,
                    0,
                    0,
                    @intCast(self.width_px),
                    @intCast(self.height_px),
                );
            }
            // Commit surface state (viewport, geometry) before recreating swapchain
            // This ensures Wayland compositor picks up the new viewport destination
            // so pointer coordinates are correctly mapped to logical pixel space
            if (self.wl_surface) |surface| {
                wayland.surfaceCommit(surface);
            }
            self.renderer.resize(self.width_px, self.height_px, self.scale_factor);
            self.pending_resize = false;
            // Notify user of resize if size actually changed
            const size_changed = (old_width != self.size.width or old_height != self.size.height);
            if (size_changed) {
                if (self.on_resize) |callback| {
                    callback(self, self.size.width, self.size.height);
                }
            }
        }

        // Call render callback to let app update scene before drawing
        if (self.on_render) |callback| {
            callback(self);
        }

        // Republish every frame: `setBackgroundColor` may have run since the
        // last record, and the renderer only reads this when recording.
        self.renderer.setClearColor(self.getClearColor());

        // Stage atlas uploads — stores data pointers only, no memcpy.
        // Actual staging + GPU transfer happens inside render() after
        // the frame fence wait, eliminating the synchronous GPU stall.
        self.stageAtlasUploads();

        // Time GPU command recording + atlas transfers + submit + present.
        // Atlas transfers are now folded into the render command buffer,
        // so this timing covers everything.
        //
        // `render_io` is intentionally the process-lifetime single-threaded
        // `Io` — the render path runs on the Wayland event thread and does
        // not carry a `*Cx`/`Gooey`. `std.Io` is a pair of pointers into a
        // static vtable, so copying it here costs nothing. Same escape hatch
        // as the render mutex (see phase-5 option 3 in the migration doc).
        const render_io = std.Io.Threaded.global_single_threaded.io();
        const gpu_start = std.Io.Timestamp.now(render_io, .awake);

        // Render scene if available
        if (self.scene) |scene| {
            self.renderer.render(scene);
        } else {
            // Create empty scene for clear
            var empty_scene = scene_mod.Scene.init(self.allocator);
            defer empty_scene.deinit();
            self.renderer.render(&empty_scene);
        }
        self.has_presented_frame = true;

        const gpu_end = std.Io.Timestamp.now(render_io, .awake);
        const gpu_ns: i96 = gpu_start.durationTo(gpu_end).toNanoseconds();
        std.debug.assert(gpu_ns >= 0);
        self.last_gpu_submit_ns = @intCast(gpu_ns);
        self.last_atlas_upload_ns = 0; // Atlas transfers are now async (inside render cmd buf)

    }

    // =========================================================================
    // Wayland Callbacks
    // =========================================================================

    /// Stage all pending atlas uploads to the renderer. Only stores data
    /// pointers and dirty regions — the actual memcpy + GPU transfer is
    /// deferred to render() after the frame fence wait.
    fn stageAtlasUploads(self: *Self) void {
        // Text atlas — R8 format, dirty region from skyline packer
        if (self.text_atlas) |atlas| {
            if (atlas.generation != self.last_atlas_generation) {
                const dirty: ?vk_atlas.DirtyRegion = if (atlas.getDirtyRegion()) |d| .{
                    .x = @as(u32, d.x),
                    .y = @as(u32, d.y),
                    .width = @as(u32, d.width),
                    .height = @as(u32, d.height),
                } else null;
                self.renderer.stageTextAtlas(atlas.data, atlas.size, atlas.size, dirty);
                self.last_atlas_generation = atlas.generation;
            }
        }

        // SVG atlas — RGBA format; also upload on first frame when view is null
        if (self.svg_atlas) |atlas| {
            const needs_upload = (atlas.generation != self.last_svg_atlas_generation) or
                (self.last_svg_atlas_generation == 0 and self.renderer.svg_atlas.view == null);
            if (needs_upload) {
                const dirty: ?vk_atlas.DirtyRegion = if (atlas.getDirtyRegion()) |d| .{
                    .x = @as(u32, d.x),
                    .y = @as(u32, d.y),
                    .width = @as(u32, d.width),
                    .height = @as(u32, d.height),
                } else null;
                self.renderer.stageSvgAtlas(atlas.data, atlas.size, atlas.size, dirty);
                self.last_svg_atlas_generation = atlas.generation;
            }
        }

        // Image atlas — RGBA format; also upload on first frame when view is null
        if (self.image_atlas) |atlas| {
            const needs_upload = (atlas.generation != self.last_image_atlas_generation) or
                (self.last_image_atlas_generation == 0 and self.renderer.image_atlas.view == null);
            if (needs_upload) {
                const dirty: ?vk_atlas.DirtyRegion = if (atlas.getDirtyRegion()) |d| .{
                    .x = @as(u32, d.x),
                    .y = @as(u32, d.y),
                    .width = @as(u32, d.width),
                    .height = @as(u32, d.height),
                } else null;
                self.renderer.stageImageAtlas(atlas.data, atlas.size, atlas.size, dirty);
                self.last_image_atlas_generation = atlas.generation;
            }
        }
    }

    fn surfaceEnter(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        output: *wayland.Output,
    ) callconv(.c) void {
        _ = surface;
        _ = output;
        const self: *Self = @ptrCast(@alignCast(data));
        // Output membership can change scale/configure state when moving a
        // window between workspaces or displays, so rebuild layout once.
        self.requestRender();
    }

    fn surfaceLeave(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        output: *wayland.Output,
    ) callconv(.c) void {
        _ = surface;
        _ = output;
        const self: *Self = @ptrCast(@alignCast(data));
        self.requestRender();
    }

    fn surfacePreferredScale(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        factor: i32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        const new_scale: f64 = @floatFromInt(factor);
        if (self.scale_factor != new_scale) {
            self.scale_factor = new_scale;
            // If using viewport, we don't need to update buffer scale - just recreate swapchain
            // The viewport destination size stays the same (logical pixels)
            if (self.viewport == null) {
                // Fallback: tell Wayland compositor about our buffer scale
                wayland.surfaceSetBufferScale(surface, factor);
            }
            // Trigger resize to recreate swapchain with new scale
            self.pending_resize = true;
            self.pending_width = self.width_px;
            self.pending_height = self.height_px;
        }
        self.requestRender();
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
        }

        self.configured = true;
        self.requestRender();
    }

    // Parameters are suffixed `_px` because `width`/`height` are declarations
    // on this struct, and a parameter may not shadow one.
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
    /// close run the same veto and the same state transition; the application
    /// cannot tell the two apart, which is the macOS behaviour. Destroying the
    /// window here would free it underneath the Wayland dispatch calling us,
    /// and quitting here would take every other window down with it.
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

    fn frameCallback(
        data: ?*anyopaque,
        callback: *wayland.Callback,
        callback_data: u32,
    ) callconv(.c) void {
        _ = callback_data;
        const self: *Self = @ptrCast(@alignCast(data));

        // Destroy the callback
        wayland.callbackDestroy(callback);
        self.frame_callback = null;

        // DEBUG: FPS counter. Wayland frame callbacks fire on the main
        // event thread which does not carry a `*Cx`, so we reach for the
        // single-threaded global `Io` here (same escape hatch as the
        // render-mutex strategy in the Phase 5 migration doc).
        const static = struct {
            var count: u32 = 0;
            var last_print_ms: i64 = 0;
        };
        static.count += 1;
        const fps_io = std.Io.Threaded.global_single_threaded.io();
        const now_ms = std.Io.Timestamp.now(fps_io, .awake).toMilliseconds();
        if (now_ms - static.last_print_ms > 1000) {
            std.debug.print("Wayland frame callbacks/sec: {}\n", .{static.count});
            static.count = 0;
            static.last_print_ms = now_ms;
        }

        // In continuous mode, always render (like macOS benchmark_mode)
        // This ensures animations run smoothly and the render callback is always invoked
        if (self.continuous_render) {
            self.needs_redraw = true;
        }

        // Render the frame
        self.renderFrame();

        // Schedule next frame:
        // - In continuous mode: always schedule (vsync-driven like macOS DisplayLink)
        // - In on-demand mode: only if needs_redraw is still true
        if (self.continuous_render or self.needs_redraw) {
            self.scheduleFrame();
        }
    }

    /// Get renderer capabilities
    pub fn getRendererCapabilities(self: *const Self) interface_mod.RendererCapabilities {
        _ = self;
        return .{
            .max_texture_size = 4096,
            .msaa = true,
            .msaa_sample_count = 4,
            .unified_memory = false,
            .name = "Vulkan",
        };
    }
};
