//! macOS Window implementation with vsync-synchronized rendering

const std = @import("std");
const objc = @import("objc");
const geometry = @import("../../core/geometry.zig");
const scene_mod = @import("../../core/scene.zig");
const Atlas = @import("../../font/atlas.zig").Atlas;
const platform = @import("platform.zig");
const metal = @import("metal/metal.zig");
const input_view = @import("input_view.zig");
const input = @import("../../core/input.zig");
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
    delegate: ?objc.Object = null,
    resize_mutex: std.Thread.Mutex = .{},
    benchmark_mode: bool = false, // Set true to force
    in_live_resize: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    on_input: ?InputCallback = null,
    /// Current mouse position (updated on every mouse event)
    mouse_position: geometry.Point(f64) = .{ .x = 0, .y = 0 },
    /// Whether mouse is inside the window
    mouse_inside: bool = false,
    hovered_quad_index: ?usize = null,

    pub const InputCallback = *const fn (*Window, input.InputEvent) bool;

    pub const Options = struct {
        title: []const u8 = "gooey Window",
        width: f64 = 800,
        height: f64 = 600,
        background_color: geometry.Color = geometry.Color.init(0.2, 0.2, 0.25, 1.0),
        use_display_link: bool = true, // Enable vsync by default
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

        const window_delegate = @import("window_delegate.zig");
        self.delegate = try window_delegate.create(self);
        self.ns_window.msgSend(void, "setDelegate:", .{self.delegate.?.value});

        // Set window title
        self.setTitle(options.title);

        const view_frame: NSRect = self.ns_window.msgSend(NSRect, "contentLayoutRect", .{});
        self.ns_view = try input_view.create(view_frame, self);
        self.ns_window.msgSend(void, "setContentView:", .{self.ns_view.value});

        // Enable mouse tracking for mouseMoved events
        try self.setupTrackingArea();

        // Get backing scale factor for Retina displays
        self.scale_factor = self.ns_window.msgSend(f64, "backingScaleFactor", .{});

        // Setup Metal layer
        try self.setupMetalLayer();

        // Initialize renderer with logical size and scale factor
        self.renderer = try metal.Renderer.init(self.metal_layer, self.size, self.scale_factor);

        // Setup display link for vsync
        if (options.use_display_link) {
            self.display_link = try DisplayLink.init();

            // Now set callback - 'self' is heap-allocated so pointer is stable
            try self.display_link.?.setCallback(displayLinkCallback, @ptrCast(self));
            try self.display_link.?.start();

            const refresh_rate = self.display_link.?.getRefreshRate();
            std.debug.print("DisplayLink started at {d:.1}Hz\n", .{refresh_rate});
        }

        // Make window key and visible
        self.ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});

        // Mark for initial render
        self.requestRender();

        return self;
    }

    pub fn getHoveredQuad(self: *const Self) ?*const scene_mod.Quad {
        const idx = self.hovered_quad_index orelse return null;
        const s = self.scene orelse return null;
        if (idx < s.quads.items.len) {
            return &s.quads.items[idx];
        }
        return null;
    }

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

    // Add handler method:
    pub fn handleInput(self: *Self, event: input.InputEvent) void {
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

        if (self.on_input) |callback| {
            _ = callback(self, event);
        }
        self.requestRender();
    }

    /// Get current mouse position
    pub fn getMousePosition(self: *const Self) geometry.Point(f64) {
        return self.mouse_position;
    }

    /// Check if mouse is inside window
    pub fn isMouseInside(self: *const Self) bool {
        return self.mouse_inside;
    }

    pub fn setInputCallback(self: *Self, callback: InputCallback) void {
        self.on_input = callback;
    }

    pub fn deinit(self: *Self) void {
        if (self.delegate) |d| {
            self.ns_window.msgSend(void, "setDelegate:", .{@as(?*anyopaque, null)});
            d.msgSend(void, "release", .{});
        }
        // Stop display link
        if (self.display_link) |*dl| {
            dl.deinit();
        }
        self.renderer.deinit();
        self.ns_window.msgSend(void, "close", .{});
        self.allocator.destroy(self);
    }

    /// Called by delegate when window is resized
    pub fn handleResize(self: *Self) void {
        // Get current view bounds
        const bounds: NSRect = self.ns_view.msgSend(NSRect, "bounds", .{});

        const new_width = bounds.size.width;
        const new_height = bounds.size.height;

        // Validate minimum size to prevent invalid textures
        if (new_width < 1 or new_height < 1) {
            return;
        }

        // Get current scale factor (may have changed if moved between displays)
        const new_scale = self.ns_window.msgSend(f64, "backingScaleFactor", .{});

        // Only update if something changed
        if (new_width == self.size.width and
            new_height == self.size.height and
            new_scale == self.scale_factor)
        {
            return;
        }

        // Lock to prevent race with render thread
        self.resize_mutex.lock();
        defer self.resize_mutex.unlock();

        self.size.width = new_width;
        self.size.height = new_height;
        self.scale_factor = new_scale;

        // Update Metal layer contents scale (for Retina)
        self.metal_layer.msgSend(void, "setContentsScale:", .{new_scale});

        // Let renderer handle drawable size and MSAA texture
        self.renderer.resize(geometry.Size(f64).init(
            new_width,
            new_height,
        ), new_scale);

        // Request re-render
        self.requestRender();

        // During live resize, render synchronously for smooth visuals
        if (self.in_live_resize.load(.acquire)) {
            // Create autorelease pool for Metal objects created during render
            const pool = createAutoreleasePool() orelse return;
            defer drainAutoreleasePool(pool);

            // Auto-update text atlas during resize
            if (self.text_atlas) |atlas| {
                self.renderer.updateTextAtlas(atlas) catch {};
            }

            if (self.scene) |s| {
                self.renderer.renderSceneSynchronous(s, self.background_color) catch {};
            } else {
                self.renderer.clearSynchronous(self.background_color);
            }
        }
    }

    pub fn handleClose(self: *Self) void {
        // Stop display link before window closes
        if (self.display_link) |*dl| {
            dl.stop();
        }
    }

    pub fn handleFocusChange(self: *Self, focused: bool) void {
        _ = focused;
        // Could track focus state, adjust rendering, etc.
        self.requestRender();
    }

    pub fn handleLiveResizeStart(self: *Self) void {
        self.in_live_resize.store(true, .release);
        // Enable synchronous presentation for smooth resize
        self.metal_layer.msgSend(void, "setPresentsWithTransaction:", .{true});
    }

    pub fn handleLiveResizeEnd(self: *Self) void {
        self.in_live_resize.store(false, .release);
        // Disable synchronous presentation for better performance
        self.metal_layer.msgSend(void, "setPresentsWithTransaction:", .{false});
        self.requestRender();
    }

    /// Check if currently in live resize
    pub fn isInLiveResize(self: *const Self) bool {
        return self.in_live_resize.load(.acquire);
    }

    fn setupMetalLayer(self: *Self) !void {
        // Create CAMetalLayer
        const CAMetalLayer = objc.getClass("CAMetalLayer") orelse return error.ClassNotFound;
        self.metal_layer = CAMetalLayer.msgSend(objc.Object, "layer", .{});

        // Configure the layer
        // Set pixel format to BGRA8Unorm
        self.metal_layer.msgSend(void, "setPixelFormat:", .{@as(u64, 80)}); // MTLPixelFormatBGRA8Unorm

        // Set contents scale for Retina
        self.metal_layer.msgSend(void, "setContentsScale:", .{self.scale_factor});

        // Disable CAMetalLayer's vsync - CVDisplayLink handles timing
        self.metal_layer.msgSend(void, "setDisplaySyncEnabled:", .{false});

        // Triple buffering for smooth rendering
        self.metal_layer.msgSend(void, "setMaximumDrawableCount:", .{@as(u64, 3)});

        // Set the layer on the view
        self.ns_view.msgSend(void, "setWantsLayer:", .{true});
        self.ns_view.msgSend(void, "setLayer:", .{self.metal_layer});

        // Set drawable size (scaled for Retina)
        const drawable_size = NSSize{
            .width = self.size.width * self.scale_factor,
            .height = self.size.height * self.scale_factor,
        };
        self.metal_layer.msgSend(void, "setDrawableSize:", .{drawable_size});
    }

    /// Request a render on the next vsync
    pub fn requestRender(self: *Self) void {
        self.needs_render.store(true, .release);
    }

    /// Manual render (for when display link is disabled)
    pub fn render(self: *Self) void {
        self.renderer.clear(self.background_color);
    }

    pub fn setTitle(self: *Self, title: []const u8) void {
        self.title = title;

        // Create NSString from title
        const NSString = objc.getClass("NSString") orelse return;
        const ns_title = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{title.ptr},
        );

        self.ns_window.msgSend(void, "setTitle:", .{ns_title});
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        self.background_color = color;
        self.requestRender(); // Mark dirty for next vsync
    }

    /// Set the text atlas for automatic GPU sync
    pub fn setTextAtlas(self: *Self, atlas: *const Atlas) void {
        self.text_atlas = atlas;
    }

    pub fn setScene(self: *Self, s: *const scene_mod.Scene) void {
        self.scene = s;
        self.requestRender();
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        return self.size;
    }
};

/// CVDisplayLink callback - runs on high-priority background thread
/// user_info points to the Window (heap-allocated, stable pointer)
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

    if (user_info) |ptr| {
        const window: *Window = @ptrCast(@alignCast(ptr));

        // Skip rendering during live resize - main thread handles it synchronously
        if (window.in_live_resize.load(.acquire)) {
            return .success;
        }

        // Benchmark mode: always render. Normal mode: only when dirty
        const should_render = window.benchmark_mode or
            window.needs_render.swap(false, .acq_rel);

        // Only render if needed (dirty flag pattern)
        if (should_render) {
            // CRITICAL: Create autorelease pool for this background thread!
            // Metal objects (command buffers, render pass descriptors, drawables)
            // are autoreleased and will leak without a pool.
            const pool = createAutoreleasePool() orelse return .success;
            defer drainAutoreleasePool(pool);

            // Lock to prevent race with resize on main thread
            window.resize_mutex.lock();
            defer window.resize_mutex.unlock();

            // Auto-update text atlas if set (checks generation, no-op if unchanged)
            if (window.text_atlas) |atlas| {
                window.renderer.updateTextAtlas(atlas) catch {};
            }

            if (window.scene) |s| {
                window.renderer.renderScene(s, window.background_color) catch |err| {
                    std.debug.print("renderScene error: {}\n", .{err});
                    window.renderer.clear(window.background_color);
                };
            } else {
                window.renderer.clear(window.background_color);
            }
        }
    }

    return .success;
}

// Autorelease pool helpers for background threads
fn createAutoreleasePool() ?objc.Object {
    const NSAutoreleasePool = objc.getClass("NSAutoreleasePool") orelse return null;
    const pool = NSAutoreleasePool.msgSend(objc.Object, "alloc", .{});
    return pool.msgSend(objc.Object, "init", .{});
}

fn drainAutoreleasePool(pool: objc.Object) void {
    pool.msgSend(void, "drain", .{});
}
