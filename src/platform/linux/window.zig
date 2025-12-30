//! LinuxWindow - Window implementation for Linux/Wayland
//!
//! Provides window creation and management using Wayland's XDG shell protocol,
//! with GPU rendering via Vulkan.

const std = @import("std");
const wayland = @import("wayland.zig");
const VulkanRenderer = @import("vk_renderer.zig").VulkanRenderer;
const LinuxPlatform = @import("platform.zig").LinuxPlatform;
const interface_mod = @import("../interface.zig");
const geometry = @import("../../core/geometry.zig");
const Size = geometry.Size(f64);
const scene_mod = @import("../../core/scene.zig");
const text_mod = @import("../../text/mod.zig");
const svg_mod = @import("../../svg/atlas.zig");
const input = @import("../../core/input.zig");
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

    // Window state
    width: u32 = 800,
    height: u32 = 600,
    /// Size in logical pixels (for API compatibility with other platforms)
    size: Size = .{ .width = 800, .height = 600 },
    scale_factor: f64 = 1.0,
    configured: bool = false,
    closed: bool = false,
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
    background_color: geometry.Color = geometry.Color.init(0.2, 0.2, 0.25, 1.0),
    needs_redraw: bool = true,

    // Scene reference (set externally)
    scene: ?*const scene_mod.Scene = null,
    text_atlas: ?*const text_mod.Atlas = null,
    last_atlas_generation: u32 = 0,
    svg_atlas: ?*const text_mod.Atlas = null,
    last_svg_atlas_generation: u32 = 0,
    image_atlas: ?*const text_mod.Atlas = null,
    last_image_atlas_generation: u32 = 0,

    // Title storage
    title_buf: [256]u8 = undefined,
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

    /// User data pointer for callbacks
    user_data: ?*anyopaque = null,

    /// Input callback type: return true if the event was handled
    pub const InputCallback = *const fn (*Self, input.InputEvent) bool;

    /// Render callback type: called each frame before drawing
    pub const RenderCallback = *const fn (*Self) void;

    /// Glass style (no-op on Linux, for API compatibility with macOS)
    pub const GlassStyle = enum(u8) {
        none = 0,
        // Linux doesn't support window blur effects like macOS
        // These are included for API compatibility only
        titlebar = 1,
        header_view = 2,
        sidebar = 3,
        content = 4,
        full_screen_ui = 5,
        tooltip = 6,
        menu = 7,
        popover = 8,
        selection = 9,
        window_background = 10,
        hudWindow = 11,
        ultra_thin = 12,
        thin = 13,
        medium = 14,
        thick = 15,
        ultra_thick = 16,
    };

    const Self = @This();

    pub fn init(allocator: Allocator, platform: *LinuxPlatform, options: WindowOptions) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Get initial scale factor from platform (may be updated later by surface events)
        const initial_scale = platform.getScaleFactor();

        self.* = Self{
            .allocator = allocator,
            .platform = platform,
            .width = @intFromFloat(options.width),
            .height = @intFromFloat(options.height),
            .size = .{ .width = options.width, .height = options.height },
            .scale_factor = initial_scale,
            .background_color = options.background_color,
            .renderer = VulkanRenderer.init(allocator),
        };

        // Store title
        const title_len = @min(options.title.len, self.title_buf.len - 1);
        @memcpy(self.title_buf[0..title_len], options.title[0..title_len]);
        self.title_buf[title_len] = 0;
        self.title_len = title_len;

        // Create Wayland surface
        const compositor = platform.getCompositor() orelse return error.NoCompositor;
        self.wl_surface = wayland.compositorCreateSurface(compositor) orelse return error.FailedToCreateSurface;

        // Set up surface listener (uses module-level static listener)
        _ = wayland.surfaceAddListener(self.wl_surface.?, &surface_listener, self);

        // Create XDG surface
        const xdg_wm_base = platform.getXdgWmBase() orelse return error.NoXdgWmBase;
        self.xdg_surface = wayland.xdgWmBaseGetXdgSurface(xdg_wm_base, self.wl_surface.?) orelse return error.FailedToCreateXdgSurface;

        // Set up XDG surface listener (uses module-level static listener)
        _ = wayland.xdgSurfaceAddListener(self.xdg_surface.?, &xdg_surface_listener, self);

        // Create XDG toplevel
        self.xdg_toplevel = wayland.xdgSurfaceGetToplevel(self.xdg_surface.?) orelse return error.FailedToCreateToplevel;

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
        if (platform.getDecorationManager()) |dm| {
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
        _ = wayland.wl_display_roundtrip(platform.display.?);

        // Create viewport for HiDPI scaling (preferred method over set_buffer_scale for Vulkan)
        // wp_viewporter allows us to render at physical resolution and display at logical size
        if (platform.getViewporter()) |viewporter| {
            self.viewport = wayland.viewporterGetViewport(viewporter, self.wl_surface.?);
            if (self.viewport) |vp| {
                // Set destination to logical size - the compositor will scale our buffer to this size
                wayland.viewportSetDestination(vp, @intCast(self.width), @intCast(self.height));
            }
        } else {
            // Fallback: use buffer scale (may not work correctly with Vulkan on all compositors)
            const scale_int: i32 = @intFromFloat(self.scale_factor);
            wayland.surfaceSetBufferScale(self.wl_surface.?, scale_int);
        }

        // Set window geometry to logical size (what the user sees)
        wayland.xdgSurfaceSetWindowGeometry(
            self.xdg_surface.?,
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
        );

        // Commit surface state before creating Vulkan swapchain
        wayland.surfaceCommit(self.wl_surface.?);
        _ = wayland.wl_display_roundtrip(platform.display.?);

        // Initialize Vulkan renderer with Wayland surface
        // Swapchain will be created at physical pixel resolution
        const wl_display = platform.getDisplay() orelse return error.NoDisplay;
        try self.renderer.initWithWaylandSurface(
            wl_display,
            @ptrCast(self.wl_surface),
            self.width,
            self.height,
            self.scale_factor,
        );

        // Final commit after Vulkan initialization
        wayland.surfaceCommit(self.wl_surface.?);

        // Roundtrip to ensure compositor has processed viewport state
        // This is important for HiDPI - pointer coordinates won't be in
        // the correct (logical) coordinate space until viewport is applied
        _ = wayland.wl_display_roundtrip(platform.display.?);

        return self;
    }

    pub fn deinit(self: *Self) void {
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

        self.allocator.destroy(self);
    }

    // =========================================================================
    // Public Interface
    // =========================================================================

    pub fn getWidth(self: *const Self) u32 {
        return self.width;
    }

    pub fn getHeight(self: *const Self) u32 {
        return self.height;
    }

    /// Window width in logical pixels (convenience alias for getWidth)
    pub fn widthPx(self: *const Self) u32 {
        return self.width;
    }

    /// Window height in logical pixels (convenience alias for getHeight)
    pub fn heightPx(self: *const Self) u32 {
        return self.height;
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        return .{
            .width = @floatFromInt(self.width),
            .height = @floatFromInt(self.height),
        };
    }

    pub fn getScaleFactor(self: *const Self) f64 {
        return self.scale_factor;
    }

    pub fn setTitle(self: *Self, title: []const u8) void {
        const len = @min(title.len, self.title_buf.len - 1);
        @memcpy(self.title_buf[0..len], title[0..len]);
        self.title_buf[len] = 0;
        self.title_len = len;

        if (self.xdg_toplevel) |tl| {
            wayland.xdgToplevelSetTitle(tl, @ptrCast(&self.title_buf));
        }
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        self.background_color = color;
        self.requestRender();
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

    pub fn isClosed(self: *const Self) bool {
        return self.closed;
    }

    pub fn requestRender(self: *Self) void {
        self.needs_redraw = true;
        self.scheduleFrame();
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
        const w: f64 = @floatFromInt(self.width);
        const h: f64 = @floatFromInt(self.height);

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
            const callback_listener = wayland.CallbackListener{
                .done = frameCallback,
            };
            _ = wayland.callbackAddListener(cb, &callback_listener, self);
        }
        wayland.surfaceCommit(self.wl_surface.?);
    }

    /// Render the current frame
    pub fn renderFrame(self: *Self) void {
        if (!self.configured) return;
        if (!self.needs_redraw and !self.pending_resize) return;

        // Handle pending resize
        if (self.pending_resize) {
            self.width = self.pending_width;
            self.height = self.pending_height;
            self.size = .{
                .width = @floatFromInt(self.pending_width),
                .height = @floatFromInt(self.pending_height),
            };
            // Update viewport destination size for HiDPI scaling
            if (self.viewport) |vp| {
                wayland.viewportSetDestination(vp, @intCast(self.width), @intCast(self.height));
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
                    @intCast(self.width),
                    @intCast(self.height),
                );
            }
            // Commit surface state (viewport, geometry) before recreating swapchain
            // This ensures Wayland compositor picks up the new viewport destination
            // so pointer coordinates are correctly mapped to logical pixel space
            if (self.wl_surface) |surface| {
                wayland.surfaceCommit(surface);
            }
            self.renderer.resize(self.width, self.height, self.scale_factor);
            self.pending_resize = false;
            self.needs_redraw = true; // Ensure we redraw after resize
        }

        // Call render callback to let app update scene before drawing
        if (self.on_render) |callback| {
            callback(self);
        }

        // Upload text atlas if changed
        if (self.text_atlas) |atlas| {
            if (atlas.generation != self.last_atlas_generation) {
                self.renderer.uploadAtlas(atlas.data, atlas.size, atlas.size) catch |err| {
                    std.log.err("Failed to upload text atlas: {}", .{err});
                };
                self.last_atlas_generation = atlas.generation;
            }
        }

        // Upload SVG atlas if changed
        // Note: We also upload on first frame when atlas_view is null
        if (self.svg_atlas) |atlas| {
            const needs_upload = (atlas.generation != self.last_svg_atlas_generation) or
                (self.last_svg_atlas_generation == 0 and self.renderer.svg_atlas_view == null);
            if (needs_upload) {
                self.renderer.uploadSvgAtlas(atlas.data, atlas.size, atlas.size) catch |err| {
                    std.log.err("Failed to upload SVG atlas: {}", .{err});
                };
                self.last_svg_atlas_generation = atlas.generation;
            }
        }

        // Upload Image atlas if changed
        if (self.image_atlas) |atlas| {
            const needs_upload = (atlas.generation != self.last_image_atlas_generation) or
                (self.last_image_atlas_generation == 0 and self.renderer.image_atlas_view == null);
            if (needs_upload) {
                self.renderer.uploadImageAtlas(atlas.data, atlas.size, atlas.size) catch |err| {
                    std.log.err("Failed to upload Image atlas: {}", .{err});
                };
                self.last_image_atlas_generation = atlas.generation;
            }
        }

        // Render scene if available
        if (self.scene) |scene| {
            self.renderer.render(scene);
        } else {
            // Create empty scene for clear
            var empty_scene = scene_mod.Scene.init(self.allocator);
            defer empty_scene.deinit();
            self.renderer.render(&empty_scene);
        }

        self.needs_redraw = false;
    }

    // =========================================================================
    // Wayland Callbacks
    // =========================================================================

    fn surfaceEnter(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        output: *wayland.Output,
    ) callconv(.c) void {
        _ = surface;
        _ = output;
        const self: *Self = @ptrCast(@alignCast(data));
        self.mouse_inside = true;
    }

    fn surfaceLeave(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        output: *wayland.Output,
    ) callconv(.c) void {
        _ = surface;
        _ = output;
        const self: *Self = @ptrCast(@alignCast(data));
        self.mouse_inside = false;
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
            self.pending_width = self.width;
            self.pending_height = self.height;
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

    fn xdgToplevelConfigure(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
        width: i32,
        height: i32,
        states: *anyopaque,
    ) callconv(.c) void {
        _ = xdg_toplevel;
        _ = states;
        const self: *Self = @ptrCast(@alignCast(data));

        // Width/height of 0 means we can choose our own size
        if (width > 0 and height > 0) {
            self.pending_width = @intCast(width);
            self.pending_height = @intCast(height);
        } else {
            self.pending_width = self.width;
            self.pending_height = self.height;
        }
    }

    fn xdgToplevelConfigureBounds(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
        width: i32,
        height: i32,
    ) callconv(.c) void {
        _ = data;
        _ = xdg_toplevel;
        _ = width;
        _ = height;
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

    fn xdgToplevelClose(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
    ) callconv(.c) void {
        _ = xdg_toplevel;
        const self: *Self = @ptrCast(@alignCast(data));
        std.debug.print("Window close requested\n", .{});
        self.closed = true;
        self.platform.quit();
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

        // Render the frame
        self.renderFrame();

        // Schedule next frame if we still need to redraw
        if (self.needs_redraw) {
            self.scheduleFrame();
        }
    }

    // =========================================================================
    // Interface VTable
    // =========================================================================

    /// Get the WindowVTable interface for runtime polymorphism
    pub fn interface(self: *Self) interface_mod.WindowVTable {
        const vtable = struct {
            fn deinitFn(p: *anyopaque) void {
                const win: *Self = @ptrCast(@alignCast(p));
                win.deinit();
            }

            fn widthFn(p: *anyopaque) u32 {
                const win: *const Self = @ptrCast(@alignCast(p));
                return win.getWidth();
            }

            fn heightFn(p: *anyopaque) u32 {
                const win: *const Self = @ptrCast(@alignCast(p));
                return win.getHeight();
            }

            fn getSizeFn(p: *anyopaque) geometry.Size(f64) {
                const win: *const Self = @ptrCast(@alignCast(p));
                return win.getSize();
            }

            fn getScaleFactorFn(p: *anyopaque) f64 {
                const win: *const Self = @ptrCast(@alignCast(p));
                return win.getScaleFactor();
            }

            fn setTitleFn(p: *anyopaque, title: []const u8) void {
                const win: *Self = @ptrCast(@alignCast(p));
                win.setTitle(title);
            }

            fn setBackgroundColorFn(p: *anyopaque, color: geometry.Color) void {
                const win: *Self = @ptrCast(@alignCast(p));
                win.setBackgroundColor(color);
            }

            fn getMousePositionFn(p: *anyopaque) geometry.Point(f64) {
                const win: *const Self = @ptrCast(@alignCast(p));
                return win.getMousePosition();
            }

            fn isMouseInsideFn(p: *anyopaque) bool {
                const win: *const Self = @ptrCast(@alignCast(p));
                return win.isMouseInside();
            }

            fn requestRenderFn(p: *anyopaque) void {
                const win: *Self = @ptrCast(@alignCast(p));
                win.requestRender();
            }

            fn setSceneFn(p: *anyopaque, s: *const scene_mod.Scene) void {
                const win: *Self = @ptrCast(@alignCast(p));
                win.setScene(s);
            }

            fn setTextAtlasFn(p: *anyopaque, atlas: *const text_mod.Atlas) void {
                const win: *Self = @ptrCast(@alignCast(p));
                win.setTextAtlas(atlas);
            }

            const table = interface_mod.WindowVTable.VTable{
                .deinit = deinitFn,
                .width = widthFn,
                .height = heightFn,
                .getSize = getSizeFn,
                .getScaleFactor = getScaleFactorFn,
                .setTitle = setTitleFn,
                .setBackgroundColor = setBackgroundColorFn,
                .getMousePosition = getMousePositionFn,
                .isMouseInside = isMouseInsideFn,
                .requestRender = requestRenderFn,
                .setScene = setSceneFn,
                .setTextAtlas = setTextAtlasFn,
            };
        };

        return .{
            .ptr = self,
            .vtable = &vtable.table,
        };
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
