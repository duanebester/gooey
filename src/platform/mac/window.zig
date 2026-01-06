//! macOS Window implementation with vsync-synchronized rendering
//!
//! Simplified version without Entity/View system integration.
//! Uses simple callbacks for rendering and input handling.

const std = @import("std");
const objc = @import("objc");
const geometry = @import("../../core/geometry.zig");
const scene_mod = @import("../../scene/mod.zig");
const shader_mod = @import("../../core/shader.zig");
const text_mod = @import("../../text/mod.zig");
const Atlas = text_mod.Atlas;
const platform = @import("platform.zig");
const metal = @import("metal/metal.zig");
const custom_shader = metal.custom_shader;
const input_view = @import("input_view.zig");
const input = @import("../../input/events.zig");
const display_link = @import("display_link.zig");
const appkit = @import("appkit.zig");

const NSRect = appkit.NSRect;
const NSSize = appkit.NSSize;
const DisplayLink = display_link.DisplayLink;

pub const Window = struct {
    allocator: std.mem.Allocator,
    ns_window: objc.Object,
    ns_view: objc.Object,
    metal_layer: objc.Object,
    renderer: metal.Renderer,
    display_link: ?DisplayLink,
    size: geometry.Size(f64),
    scale_factor: f64,
    title: []const u8,
    background_color: geometry.Color,
    needs_render: std.atomic.Value(bool),
    scene: ?*const scene_mod.Scene,
    text_atlas: ?*const Atlas = null,
    svg_atlas: ?*const Atlas = null,
    image_atlas: ?*const Atlas = null,
    delegate: ?objc.Object = null,
    // Custom shader animation flag
    custom_shader_animation: bool,
    // Glass effect support (macOS 26.0+ / fallback blur)
    glass_effect_view: ?objc.Object = null,
    glass_style: GlassStyle = .none,
    background_opacity: f64 = 1.0,

    /// Mutex protecting all render-related state accessed from DisplayLink thread.
    /// This includes: scene, text_atlas, background_color, size, scale_factor, renderer.
    /// Must be held when:
    /// - DisplayLink callback reads scene/atlas for rendering
    /// - Main thread modifies scene/atlas/size
    render_mutex: std.Thread.Mutex = .{},

    /// Flag indicating we're in a live resize operation.
    /// During live resize, the main thread handles rendering synchronously,
    /// and the DisplayLink callback should skip rendering entirely.
    in_live_resize: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Flag indicating the DisplayLink callback is currently rendering.
    /// Used to prevent the main thread from modifying state mid-render.
    render_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    benchmark_mode: bool = true,

    /// Current mouse position (updated on every mouse event)
    mouse_position: geometry.Point(f64) = .{ .x = 0, .y = 0 },
    /// Whether mouse is inside the window
    mouse_inside: bool = false,
    hovered_quad_index: ?usize = null,

    // IME (Input Method Editor) state
    marked_text: []const u8 = "",
    marked_text_buffer: [256]u8 = undefined,
    inserted_text: []const u8 = "",
    inserted_text_buffer: [256]u8 = undefined,
    pending_key_event: ?objc.c.id = null,
    /// IME cursor rect in view coordinates (for candidate window positioning)
    ime_cursor_rect: appkit.NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1, .height = 20 } },
    /// NSProcessInfo activity token for preventing ProMotion throttling
    activity_token: ?objc.Object = null,

    // =========================================================================
    // Simplified Callbacks
    // =========================================================================

    /// Called for input events. Return true if handled.
    on_input: ?InputCallback = null,

    /// Called each frame when rendering is needed.
    /// Use this to rebuild your UI/scene before the frame is drawn.
    on_render: ?RenderCallback = null,

    /// User data pointer for callbacks
    user_data: ?*anyopaque = null,

    // =========================================================================
    // Convenience accessors (so user code doesn't need to convert)
    // =========================================================================

    /// Get the effective clear color for rendering.
    /// When glass effects are active, returns transparent so the glass shows through.
    /// Otherwise returns the configured background color.
    pub fn getClearColor(self: *const Self) geometry.Color {
        return switch (self.glass_style) {
            .glass_regular, .glass_clear, .blur => geometry.Color.transparent,
            .none => self.background_color,
        };
    }

    pub fn setSvgAtlas(self: *Self, atlas: *const Atlas) void {
        if (!self.render_in_progress.load(.acquire)) {
            self.render_mutex.lock();
            defer self.render_mutex.unlock();
        }
        self.svg_atlas = atlas;
    }

    pub fn setImageAtlas(self: *Self, atlas: *const Atlas) void {
        if (!self.render_in_progress.load(.acquire)) {
            self.render_mutex.lock();
            defer self.render_mutex.unlock();
        }
        self.image_atlas = atlas;
    }

    /// Window width in logical pixels
    pub fn width(self: *const Self) u32 {
        return @intFromFloat(self.size.width);
    }

    /// Window height in logical pixels
    pub fn height(self: *const Self) u32 {
        return @intFromFloat(self.size.height);
    }

    // =========================================================================
    // Types
    // =========================================================================

    /// Input callback: return true if the event was handled
    pub const InputCallback = *const fn (*Window, input.InputEvent) bool;

    /// Render callback: called each frame before drawing
    pub const RenderCallback = *const fn (*Window) void;

    /// Glass/blur effect style for transparent windows
    pub const GlassStyle = enum {
        /// No glass effect
        none,
        /// macOS 26+ liquid glass (regular density)
        glass_regular,
        /// macOS 26+ liquid glass (clear/lighter)
        glass_clear,
        /// Traditional background blur (works on older macOS)
        blur,
    };

    pub const Options = struct {
        title: []const u8 = "gooey Window",
        width: f64 = 800,
        height: f64 = 600,
        background_color: geometry.Color = geometry.Color.transparent,
        use_display_link: bool = true,
        custom_shaders: []const shader_mod.CustomShader = &.{},
        /// Background opacity (0.0 = fully transparent, 1.0 = opaque)
        /// Values < 1.0 enable transparency effects
        background_opacity: f64 = 1.0,
        /// Glass/blur style for transparent windows
        glass_style: GlassStyle = .none,
        /// Corner radius for glass effect (macOS 26+ only)
        glass_corner_radius: f64 = 16.0,
        /// Make titlebar transparent (blends with window content)
        titlebar_transparent: bool = false,
        /// Extend content under titlebar (full bleed)
        full_size_content: bool = false,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, plat: *platform.MacPlatform, options: Options) !*Self {
        _ = plat;

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .ns_window = undefined,
            .ns_view = undefined,
            .metal_layer = undefined,
            .renderer = undefined,
            .display_link = null,
            .size = geometry.Size(f64).init(options.width, options.height),
            .scale_factor = 1.0,
            .title = options.title,
            .background_color = options.background_color,
            .needs_render = std.atomic.Value(bool).init(true),
            .scene = null,
            .custom_shader_animation = false,
            .glass_style = options.glass_style,
            .background_opacity = options.background_opacity,
        };

        // Create NSWindow
        const NSWindow = objc.getClass("NSWindow") orelse return error.ClassNotFound;

        // Style mask: titled, closable, miniaturizable, resizable
        const style_mask: u64 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3);

        // Content rect
        const content_rect = NSRect{
            .origin = .{ .x = 100, .y = 100 },
            .size = .{ .width = options.width, .height = options.height },
        };

        // Alloc and init window
        const window_alloc = NSWindow.msgSend(objc.Object, "alloc", .{});
        self.ns_window = window_alloc.msgSend(
            objc.Object,
            "initWithContentRect:styleMask:backing:defer:",
            .{
                content_rect,
                style_mask,
                @as(u64, 2), // NSBackingStoreBuffered
                false,
            },
        );

        // Configure titlebar transparency
        if (options.titlebar_transparent) {
            self.ns_window.msgSend(void, "setTitlebarAppearsTransparent:", .{true});
        }

        // Extend content under titlebar for full-bleed effect
        if (options.full_size_content) {
            // Add NSWindowStyleMaskFullSizeContentView to existing style mask
            const current_mask = self.ns_window.msgSend(u64, "styleMask", .{});
            const full_size_content_mask: u64 = 1 << 15; // NSWindowStyleMaskFullSizeContentView
            self.ns_window.msgSend(void, "setStyleMask:", .{current_mask | full_size_content_mask});
        }

        const window_delegate = @import("window_delegate.zig");
        self.delegate = try window_delegate.create(self);
        self.ns_window.msgSend(void, "setDelegate:", .{self.delegate.?.value});

        // Set window title
        self.setTitle(options.title);

        const view_frame: NSRect = self.ns_window.msgSend(NSRect, "contentLayoutRect", .{});
        self.ns_view = try input_view.create(view_frame, self);
        self.ns_window.msgSend(void, "setContentView:", .{self.ns_view.value});

        // Setup glass/transparency effect if requested
        if (options.background_opacity < 1.0) {
            try self.setupGlassEffect(options.glass_style, options.background_opacity, options.glass_corner_radius);
        }

        // Enable mouse tracking for mouseMoved events
        try self.setupTrackingArea();

        // Get backing scale factor for Retina displays
        self.scale_factor = self.ns_window.msgSend(f64, "backingScaleFactor", .{});

        // Setup Metal layer
        try self.setupMetalLayer();

        // Initialize renderer with logical size and scale factor
        self.renderer = try metal.Renderer.init(allocator, self.metal_layer, self.size, self.scale_factor);

        // Load custom shaders
        if (options.custom_shaders.len > 0) {
            for (options.custom_shaders, 0..) |shader, i| {
                // Extract MSL source for macOS
                const msl_source = shader.msl orelse {
                    std.debug.print("Custom shader {d} has no MSL source, skipping\n", .{i});
                    continue;
                };
                var name_buf: [32]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "custom_{d}", .{i}) catch "custom";
                self.renderer.addCustomShader(msl_source, name) catch |err| {
                    std.debug.print("Failed to load custom shader {d}: {}\n", .{ i, err });
                };
            }
            // Enable continuous animation for iTime
            self.custom_shader_animation = true;
        }

        // Setup display link for vsync
        // Setup display link for vsync
        if (options.use_display_link) {
            self.display_link = try DisplayLink.init();
            try self.display_link.?.setCallback(displayLinkCallback, @ptrCast(self));
            try self.display_link.?.start();

            const refresh_rate = self.display_link.?.getRefreshRate();
            std.debug.print("DisplayLink started at {d:.1}Hz\n", .{refresh_rate});

            // Request high-performance activity to prevent macOS from throttling
            // ProMotion displays (120Hz -> 60Hz)
            self.activity_token = beginHighPerformanceActivity();
        }

        // Make window key and visible
        self.ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});

        // Mark for initial render
        self.requestRender();

        return self;
    }

    // =========================================================================
    // Callback Setters
    // =========================================================================

    /// Set the input callback
    pub fn setInputCallback(self: *Self, callback: InputCallback) void {
        self.on_input = callback;
    }

    /// Set the render callback (called each frame before drawing)
    pub fn setRenderCallback(self: *Self, callback: RenderCallback) void {
        self.on_render = callback;
    }

    /// Set user data pointer accessible in callbacks
    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        self.user_data = data;
    }

    /// Get user data pointer
    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        if (self.user_data) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }

    // =========================================================================
    // Scene Management
    // =========================================================================

    pub fn getHoveredQuad(self: *const Self) ?*const scene_mod.Quad {
        const idx = self.hovered_quad_index orelse return null;
        const s = self.scene orelse return null;
        if (idx < s.quads.items.len) {
            return &s.quads.items[idx];
        }
        return null;
    }

    /// Set the text atlas for automatic GPU sync (thread-safe)
    pub fn setTextAtlas(self: *Self, atlas: *const Atlas) void {
        // Only lock if we're not already in a render (which holds the lock)
        if (!self.render_in_progress.load(.acquire)) {
            self.render_mutex.lock();
            defer self.render_mutex.unlock();
        }
        self.text_atlas = atlas;
    }

    /// Set the scene (thread-safe)
    pub fn setScene(self: *Self, s: *const scene_mod.Scene) void {
        // Only lock if we're not already in a render (which holds the lock)
        if (!self.render_in_progress.load(.acquire)) {
            self.render_mutex.lock();
            defer self.render_mutex.unlock();
        }
        self.scene = s;
        self.requestRender();
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        return self.size;
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
        self.ime_cursor_rect = .{
            .origin = .{ .x = @floatCast(x), .y = @floatCast(y) },
            .size = .{ .width = @floatCast(w), .height = @floatCast(h) },
        };
    }

    /// Check if there's active IME composition
    pub fn hasMarkedText(self: *const Self) bool {
        return self.marked_text.len > 0;
    }

    // =========================================================================
    // Input Handling
    // =========================================================================
    pub fn handleInput(self: *Self, event: input.InputEvent) bool {
        // Track mouse position
        switch (event) {
            .mouse_down, .mouse_up, .mouse_moved, .mouse_dragged => |m| {
                self.mouse_position = m.position;
            },
            .mouse_entered => |m| {
                self.mouse_position = m.position;
                self.mouse_inside = true;
            },
            .mouse_exited => |m| {
                self.mouse_position = m.position;
                self.mouse_inside = false;
            },
            else => {},
        }

        var handled = false;
        if (self.on_input) |callback| {
            // Acquire render mutex to safely access layout/scene data.
            // The input callback may query layout bounds or scene state (e.g., for hit testing).
            // Without this lock, the DisplayLink thread could be mid-render, mutating
            // layout/scene data while we read it, causing torn reads or crashes.
            self.render_mutex.lock();
            defer self.render_mutex.unlock();
            handled = callback(self, event);
        }
        self.requestRender();
        return handled;
    }

    /// Get current mouse position
    pub fn getMousePosition(self: *const Self) geometry.Point(f64) {
        return self.mouse_position;
    }

    /// Check if mouse is inside window
    pub fn isMouseInside(self: *const Self) bool {
        return self.mouse_inside;
    }

    // =========================================================================
    // Window Lifecycle
    // =========================================================================

    pub fn deinit(self: *Self) void {
        if (self.delegate) |d| {
            self.ns_window.msgSend(void, "setDelegate:", .{@as(?*anyopaque, null)});
            d.msgSend(void, "release", .{});
        }
        // Clean up glass effect view
        if (self.glass_effect_view) |glass_view| {
            glass_view.msgSend(void, "removeFromSuperview", .{});
            self.glass_effect_view = null;
        }

        // End high-performance activity before stopping display link
        if (self.activity_token) |token| {
            endHighPerformanceActivity(token);
            self.activity_token = null;
        }

        if (self.display_link) |*dl| {
            dl.deinit();
        }
        self.renderer.deinit();
        self.ns_window.msgSend(void, "close", .{});
        self.allocator.destroy(self);
    }

    /// Called by delegate when window is resized
    /// Called by delegate when window is resized
    pub fn handleResize(self: *Self) void {
        const bounds: NSRect = self.ns_view.msgSend(NSRect, "bounds", .{});

        const new_width = bounds.size.width;
        const new_height = bounds.size.height;

        if (new_width < 1 or new_height < 1) {
            return;
        }

        const new_scale = self.ns_window.msgSend(f64, "backingScaleFactor", .{});

        if (new_width == self.size.width and
            new_height == self.size.height and
            new_scale == self.scale_factor)
        {
            return;
        }

        // Acquire render mutex to safely modify size/scale while DisplayLink might be reading
        self.render_mutex.lock();
        defer self.render_mutex.unlock();

        self.size.width = new_width;
        self.size.height = new_height;
        self.scale_factor = new_scale;

        self.metal_layer.msgSend(void, "setContentsScale:", .{new_scale});

        self.renderer.resize(geometry.Size(f64).init(
            new_width,
            new_height,
        ), new_scale);

        self.requestRender();

        // During live resize, render synchronously for smooth visuals
        if (self.in_live_resize.load(.acquire)) {
            const pool = createAutoreleasePool() orelse return;
            defer drainAutoreleasePool(pool);

            // Call render callback to update scene
            if (self.on_render) |callback| {
                callback(self);
            }

            if (self.text_atlas) |atlas| {
                self.renderer.updateTextAtlas(atlas) catch {};
            }
            if (self.svg_atlas) |atlas| {
                self.renderer.prepareSvgAtlas(atlas);
            }
            if (self.image_atlas) |atlas| {
                self.renderer.prepareImageAtlas(atlas);
            }

            if (self.scene) |s| {
                self.renderer.renderSceneSynchronous(s, self.getClearColor()) catch {};
            } else {
                self.renderer.clearSynchronous(self.getClearColor());
            }
        }
    }

    pub fn handleClose(self: *Self) void {
        if (self.display_link) |*dl| {
            dl.stop();
        }
    }

    pub fn handleFocusChange(self: *Self, focused: bool) void {
        _ = focused;
        self.requestRender();
    }

    pub fn handleLiveResizeStart(self: *Self) void {
        self.in_live_resize.store(true, .release);
        self.metal_layer.msgSend(void, "setPresentsWithTransaction:", .{true});
    }

    pub fn handleLiveResizeEnd(self: *Self) void {
        self.in_live_resize.store(false, .release);
        self.metal_layer.msgSend(void, "setPresentsWithTransaction:", .{false});
        self.requestRender();
    }

    pub fn isInLiveResize(self: *const Self) bool {
        return self.in_live_resize.load(.acquire);
    }

    // =========================================================================
    // Rendering
    // =========================================================================

    /// Request a render on the next vsync
    pub fn requestRender(self: *Self) void {
        self.needs_render.store(true, .release);
    }

    /// Manual render (for when display link is disabled)
    pub fn render(self: *Self) void {
        self.renderer.clear(self.getClearColor());
    }

    pub fn setTitle(self: *Self, new_title: []const u8) void {
        self.title = new_title;

        const NSString = objc.getClass("NSString") orelse return;
        const ns_title = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{new_title.ptr},
        );

        self.ns_window.msgSend(void, "setTitle:", .{ns_title});
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        self.background_color = color;
        self.requestRender();
    }

    /// Change the glass effect style at runtime
    pub fn setGlassStyle(self: *Self, style: GlassStyle, opacity: f64, corner_radius: f64) void {
        // Remove existing glass effect if any
        if (self.glass_effect_view) |glass_view| {
            glass_view.msgSend(void, "removeFromSuperview", .{});
            self.glass_effect_view = null;
        }

        // Update stored values
        self.glass_style = style;
        self.background_opacity = opacity;

        if (style == .none) {
            // Restore opaque window
            self.ns_window.msgSend(void, "setOpaque:", .{true});
            const NSColor = objc.getClass("NSColor") orelse return;
            const bg = NSColor.msgSend(objc.Object, "colorWithRed:green:blue:alpha:", .{
                @as(f64, self.background_color.r),
                @as(f64, self.background_color.g),
                @as(f64, self.background_color.b),
                @as(f64, 1.0),
            });
            self.ns_window.msgSend(void, "setBackgroundColor:", .{bg.value});
        } else {
            // Make window non-opaque
            self.ns_window.msgSend(void, "setOpaque:", .{false});

            // Set transparent background
            const NSColor = objc.getClass("NSColor") orelse return;
            const transparent_bg = NSColor.msgSend(objc.Object, "colorWithRed:green:blue:alpha:", .{
                @as(f64, 1.0),
                @as(f64, 1.0),
                @as(f64, 1.0),
                @as(f64, 0.001),
            });
            self.ns_window.msgSend(void, "setBackgroundColor:", .{transparent_bg.value});

            // Apply new glass effect
            switch (style) {
                .glass_regular, .glass_clear => {
                    if (!self.setupLiquidGlass(style, corner_radius)) {
                        self.setupTraditionalBlur();
                    }
                },
                .blur => self.setupTraditionalBlur(),
                .none => {},
            }
        }

        self.requestRender();
    }

    // =========================================================================
    // Private Helpers
    // =========================================================================

    fn setupTrackingArea(self: *Self) !void {
        const bounds: NSRect = self.ns_view.msgSend(NSRect, "bounds", .{});

        const NSTrackingArea = objc.getClass("NSTrackingArea") orelse return error.ClassNotFound;

        const opts = appkit.NSTrackingAreaOptions;
        const options = opts.mouse_moved |
            opts.mouse_entered_and_exited |
            opts.active_in_key_window |
            opts.in_visible_rect;

        const tracking_area = NSTrackingArea.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithRect:options:owner:userInfo:", .{
            bounds,
            options,
            self.ns_view.value,
            @as(?objc.c.id, null),
        });

        self.ns_view.msgSend(void, "addTrackingArea:", .{tracking_area.value});
    }

    fn setupMetalLayer(self: *Self) !void {
        const CAMetalLayer = objc.getClass("CAMetalLayer") orelse return error.ClassNotFound;
        self.metal_layer = CAMetalLayer.msgSend(objc.Object, "layer", .{});

        // Configure the layer
        self.metal_layer.msgSend(void, "setPixelFormat:", .{@as(u64, 80)}); // MTLPixelFormatBGRA8Unorm
        self.metal_layer.msgSend(void, "setContentsScale:", .{self.scale_factor});
        self.metal_layer.msgSend(void, "setDisplaySyncEnabled:", .{false});
        self.metal_layer.msgSend(void, "setMaximumDrawableCount:", .{@as(u64, 3)});

        // Allow transparency through the Metal layer
        self.metal_layer.msgSend(void, "setOpaque:", .{false});

        self.ns_view.msgSend(void, "setWantsLayer:", .{true});
        self.ns_view.msgSend(void, "setLayer:", .{self.metal_layer});

        const drawable_size = NSSize{
            .width = self.size.width * self.scale_factor,
            .height = self.size.height * self.scale_factor,
        };
        self.metal_layer.msgSend(void, "setDrawableSize:", .{drawable_size});
    }

    fn setupGlassEffect(self: *Self, style: GlassStyle, opacity: f64, corner_radius: f64) !void {
        _ = opacity; // Opacity is handled by the glass tint, not window background
        if (style == .none) return;

        // Make the window non-opaque for transparency
        self.ns_window.msgSend(void, "setOpaque:", .{false});

        // Set window background to nearly transparent
        // The glass effect provides the actual visual background
        const NSColor = objc.getClass("NSColor") orelse return error.ClassNotFound;
        const transparent_bg = NSColor.msgSend(objc.Object, "colorWithRed:green:blue:alpha:", .{
            @as(f64, 1.0),
            @as(f64, 1.0),
            @as(f64, 1.0),
            @as(f64, 0.001), // Nearly invisible - glass shows through
        });
        self.ns_window.msgSend(void, "setBackgroundColor:", .{transparent_bg.value});

        // Try to setup liquid glass (macOS 26.0+) or fallback to blur
        switch (style) {
            .glass_regular, .glass_clear => {
                if (!self.setupLiquidGlass(style, corner_radius)) {
                    // Fallback to traditional blur if liquid glass unavailable
                    self.setupTraditionalBlur();
                }
            },
            .blur => {
                self.setupTraditionalBlur();
            },
            .none => {
                // Just transparency, no blur effect
            },
        }
    }

    fn setupLiquidGlass(self: *Self, style: GlassStyle, corner_radius: f64) bool {
        // NSGlassEffectView is only available on macOS 26.0+ (Tahoe)
        const NSGlassEffectView = objc.getClass("NSGlassEffectView") orelse {
            std.debug.print("NSGlassEffectView not available (requires macOS 26.0+)\n", .{});
            return false;
        };

        // Get the content view's superview (the window's content view container)
        const content_view: objc.Object = self.ns_window.msgSend(objc.Object, "contentView", .{});
        const superview: objc.Object = content_view.msgSend(objc.Object, "superview", .{});
        if (superview.value == null) {
            std.debug.print("Could not get content view superview for glass effect\n", .{});
            return false;
        }

        const bounds: NSRect = superview.msgSend(NSRect, "bounds", .{});

        // Create and configure the glass effect view
        const glass_alloc = NSGlassEffectView.msgSend(objc.Object, "alloc", .{});
        const glass_view = glass_alloc.msgSend(objc.Object, "initWithFrame:", .{bounds});

        // Set style: 0 = regular, 1 = clear
        const style_value: i64 = switch (style) {
            .glass_regular => 0,
            .glass_clear => 1,
            else => 0,
        };
        glass_view.msgSend(void, "setStyle:", .{style_value});

        // Set corner radius
        glass_view.msgSend(void, "setCornerRadius:", .{corner_radius});

        // Set tint color based on our background color and opacity
        // If background_color is fully transparent, use a sensible default
        const NSColor = objc.getClass("NSColor") orelse return false;

        // Compute effective tint: use background_color RGB with background_opacity as alpha
        // If the color is fully transparent (default), use a dark gray as fallback
        const tint_r: f64 = if (self.background_color.a > 0.001) self.background_color.r else 0.1;
        const tint_g: f64 = if (self.background_color.a > 0.001) self.background_color.g else 0.1;
        const tint_b: f64 = if (self.background_color.a > 0.001) self.background_color.b else 0.1;
        const tint_a: f64 = @max(0.001, self.background_opacity); // Ensure some minimum opacity

        const tint_color = NSColor.msgSend(objc.Object, "colorWithRed:green:blue:alpha:", .{
            tint_r,
            tint_g,
            tint_b,
            tint_a,
        });
        glass_view.msgSend(void, "setTintColor:", .{tint_color.value});

        // Enable autoresizing to fill the window
        // NSViewWidthSizable | NSViewHeightSizable = 2 | 16 = 18
        glass_view.msgSend(void, "setAutoresizingMask:", .{@as(u64, 18)});

        // Add the glass view BELOW the content view
        // NSWindowBelow = -1
        superview.msgSend(void, "addSubview:positioned:relativeTo:", .{
            glass_view.value,
            @as(i64, -1), // NSWindowBelow
            content_view.value,
        });

        self.glass_effect_view = glass_view;
        std.debug.print("Liquid glass effect enabled (style: {}, tint: rgba({d:.2},{d:.2},{d:.2},{d:.2}))\n", .{ style, tint_r, tint_g, tint_b, tint_a });
        return true;
    }

    fn setupTraditionalBlur(self: *Self) void {
        // Use the private CGS API for background blur (same as Terminal.app, Ghostty)
        // This works on older macOS versions
        const window_number = self.ns_window.msgSend(usize, "windowNumber", .{});
        const blur_radius: c_int = 20; // Reasonable default blur amount

        const result = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            window_number,
            blur_radius,
        );

        if (result == 0) {
            std.debug.print("Traditional background blur enabled (radius: {})\n", .{blur_radius});
        } else {
            std.debug.print("Failed to enable background blur (error: {})\n", .{result});
        }
    }

    // Private CoreGraphics APIs for background blur (used by Terminal.app, Ghostty, etc.)
    extern "c" fn CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32;
    extern "c" fn CGSDefaultConnectionForThread() *anyopaque;

    // =========================================================================
    // Interface Support
    // =========================================================================

    /// Get this window as a runtime-polymorphic interface.
    pub fn interface(self: *Self) @import("../interface.zig").WindowVTable {
        const iface = @import("../interface.zig");

        const vtable = struct {
            fn deinitFn(p: *anyopaque) void {
                const win: *Self = @ptrCast(@alignCast(p));
                win.deinit();
            }

            fn widthFn(p: *anyopaque) u32 {
                const win: *const Self = @ptrCast(@alignCast(p));
                return win.width();
            }

            fn heightFn(p: *anyopaque) u32 {
                const win: *const Self = @ptrCast(@alignCast(p));
                return win.height();
            }

            fn getSizeFn(p: *anyopaque) geometry.Size(f64) {
                const win: *const Self = @ptrCast(@alignCast(p));
                return win.getSize();
            }

            fn getScaleFactorFn(p: *anyopaque) f64 {
                const win: *const Self = @ptrCast(@alignCast(p));
                return win.scale_factor;
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

            fn setTextAtlasFn(p: *anyopaque, atlas: *const Atlas) void {
                const win: *Self = @ptrCast(@alignCast(p));
                win.setTextAtlas(atlas);
            }

            const table = iface.WindowVTable.VTable{
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
    pub fn getRendererCapabilities(self: *const Self) @import("../interface.zig").RendererCapabilities {
        return .{
            .max_texture_size = 4096, // Could query from Metal device
            .msaa = true,
            .msaa_sample_count = self.renderer.sample_count,
            .unified_memory = self.renderer.unified_memory,
            .name = "Metal",
        };
    }
};

// =============================================================================
// Display Link Callback
// =============================================================================

/// CVDisplayLink callback - runs on high-priority background thread
///
/// THREAD SAFETY: This callback runs on a CVDisplayLink thread, NOT the main thread.
/// All access to shared Window state must be synchronized via render_mutex.
///
/// The render_mutex protects: scene, text_atlas, size, scale_factor, background_color, renderer.
/// The on_render callback is called WITH the lock held to prevent race conditions.
fn displayLinkCallback(
    dl: display_link.CVDisplayLinkRef,
    in_now: *const display_link.CVTimeStamp,
    in_output_time: *const display_link.CVTimeStamp,
    flags_in: u64,
    flags_out: *u64,
    user_info: ?*anyopaque,
) callconv(.c) display_link.CVReturn {
    _ = dl;
    _ = in_now;
    _ = in_output_time;
    _ = flags_in;
    _ = flags_out;

    const window: *Window = @ptrCast(@alignCast(user_info orelse return .success));

    // Skip rendering during live resize
    if (window.in_live_resize.load(.acquire)) {
        return .success;
    }

    // Always render if custom shader animation is enabled (for iTime)
    const explicit_render = window.needs_render.swap(false, .acq_rel);
    const should_render = window.benchmark_mode or explicit_render or window.custom_shader_animation;

    // DEBUG
    const static = struct {
        var count: u32 = 0;
        var last_print: i64 = 0;
    };
    static.count += 1;
    const now = std.time.milliTimestamp();
    if (now - static.last_print > 1000) {
        //std.debug.print("DisplayLink callbacks/sec: {}, should_render: {}, explicit: {}\n", .{ static.count, should_render, explicit_render });
        static.count = 0;
        static.last_print = now;
    }

    if (!should_render) {
        return .success;
    }

    const pool = createAutoreleasePool() orelse return .success;
    defer drainAutoreleasePool(pool);

    // Acquire render mutex for thread-safe access to all render state
    window.render_mutex.lock();
    defer window.render_mutex.unlock();

    // Mark that rendering is in progress
    window.render_in_progress.store(true, .release);
    defer window.render_in_progress.store(false, .release);

    // Call render callback to let user rebuild scene
    // NOTE: This is called with the lock held, so the callback must not
    // call any Window methods that also try to acquire the lock.
    if (window.on_render) |callback| {
        callback(window);
    }

    // Update text atlas if set
    if (window.text_atlas) |atlas| {
        window.renderer.updateTextAtlas(atlas) catch {};
    }

    // Update SVG atlas if set
    if (window.svg_atlas) |atlas| {
        window.renderer.prepareSvgAtlas(atlas);
    }

    // Update image atlas if set
    if (window.image_atlas) |atlas| {
        window.renderer.prepareImageAtlas(atlas);
    }

    // Use post-process rendering if shaders are active
    if (window.scene) |s| {
        const clear_color = window.getClearColor();
        if (window.renderer.hasCustomShaders()) {
            window.renderer.renderSceneWithPostProcess(s, clear_color) catch |err| {
                std.debug.print("renderSceneWithPostProcess error: {}\n", .{err});
                // Fall back to normal render
                window.renderer.renderScene(s, clear_color) catch {
                    window.renderer.clear(clear_color);
                };
            };
        } else {
            window.renderer.renderScene(s, clear_color) catch |err| {
                std.debug.print("renderScene error: {}\n", .{err});
                window.renderer.clear(clear_color);
            };
        }
    } else {
        window.renderer.clear(window.getClearColor());
    }

    return .success;
}

// =============================================================================
// Helpers
// =============================================================================

fn createAutoreleasePool() ?objc.Object {
    const NSAutoreleasePool = objc.getClass("NSAutoreleasePool") orelse return null;
    const pool = NSAutoreleasePool.msgSend(objc.Object, "alloc", .{});
    return pool.msgSend(objc.Object, "init", .{});
}

fn drainAutoreleasePool(pool: objc.Object) void {
    pool.msgSend(void, "drain", .{});
}

// =============================================================================
// High Performance Activity (prevents ProMotion throttling)
// =============================================================================

/// Begin a high-performance activity to prevent macOS from throttling
/// the display refresh rate on ProMotion displays.
fn beginHighPerformanceActivity() ?objc.Object {
    const NSProcessInfo = objc.getClass("NSProcessInfo") orelse return null;
    const process_info = NSProcessInfo.msgSend(objc.Object, "processInfo", .{});

    // NSActivityLatencyCritical (0xFF00000000) | NSActivityUserInitiated (0x00FFFFFF)
    // This combination tells macOS we need low-latency, high-priority rendering
    const activity_options: u64 = 0xFF00000000 | 0x00FFFFFF;

    const NSString = objc.getClass("NSString") orelse return null;
    const reason = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{@as([*:0]const u8, "High frame rate rendering")},
    );

    const token = process_info.msgSend(
        objc.Object,
        "beginActivityWithOptions:reason:",
        .{ activity_options, reason }, // Pass `reason` directly, not `reason.value`
    );

    if (token.value == null) {
        std.debug.print("WARNING: Activity token is null - ProMotion throttle prevention failed!\n", .{});
        return null;
    }

    // Retain the token since it's returned autoreleased
    _ = token.msgSend(objc.Object, "retain", .{});
    std.debug.print("High-performance activity started (ProMotion throttle prevention)\n", .{});
    return token;
}

/// End a high-performance activity
fn endHighPerformanceActivity(token: objc.Object) void {
    const NSProcessInfo = objc.getClass("NSProcessInfo") orelse return;
    const process_info = NSProcessInfo.msgSend(objc.Object, "processInfo", .{});
    process_info.msgSend(void, "endActivity:", .{token.value});
}
