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

const render_mod = @import("../../core/render.zig");
const context_mod = @import("../../core/context.zig");
const entity_map_mod = @import("../../core/entity_map.zig");

const AnyView = render_mod.AnyView;
const RenderOutput = render_mod.RenderOutput;
const WindowVTable = render_mod.WindowVTable;
const ContextVTable = context_mod.ContextVTable;
const EntityMap = entity_map_mod.EntityMap;

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
    // IME (Input Method Editor) state
    marked_text: []const u8 = "",
    marked_text_buffer: [256]u8 = undefined,
    inserted_text: []const u8 = "",
    inserted_text_buffer: [256]u8 = undefined,
    pending_key_event: ?objc.c.id = null,
    /// IME cursor rect in view coordinates (for candidate window positioning)
    ime_cursor_rect: appkit.NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1, .height = 20 } },

    // =========================================================================
    // Reactive View System Fields
    // =========================================================================

    /// The root view for this window (type-erased)
    root_view: ?AnyView = null,

    /// Reference to App for entity access (type-erased)
    app_ptr: ?*anyopaque = null,

    /// App's context vtable for creating contexts
    app_ctx_vtable: ?*const ContextVTable = null,

    /// Callback to check if an entity is dirty
    is_dirty_fn: ?*const fn (*anyopaque, render_mod.EntityId) bool = null,

    /// Callback to clear dirty flag for an entity
    clear_dirty_fn: ?*const fn (*anyopaque, render_mod.EntityId) void = null,

    /// Callback to get the entity map
    get_entities_fn: ?*const fn (*anyopaque) *EntityMap = null,

    /// Our WindowVTable for ViewContext
    window_vtable: WindowVTable,

    /// Custom render callback (called when root view renders)
    on_render: ?*const fn (*Window, RenderOutput) void = null,

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
            .window_vtable = .{
                .getSize = windowVTableGetSize,
                .requestRender = windowVTableRequestRender,
            },
        };

        // Initialize reactive system fields
        self.root_view = null;
        self.app_ptr = null;
        self.app_ctx_vtable = null;
        self.is_dirty_fn = null;
        self.clear_dirty_fn = null;
        self.get_entities_fn = null;
        self.on_render = null;

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

    /// Set the marked (composing) text for IME
    pub fn setMarkedText(self: *Self, text: []const u8) void {
        if (text.len > self.marked_text_buffer.len) {
            // Text too long, truncate
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
    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, width: f32, height: f32) void {
        self.ime_cursor_rect = .{
            .origin = .{ .x = @floatCast(x), .y = @floatCast(y) },
            .size = .{ .width = @floatCast(width), .height = @floatCast(height) },
        };
    }

    /// Check if there's active IME composition
    pub fn hasMarkedText(self: *const Self) bool {
        return self.marked_text.len > 0;
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

    // =========================================================================
    // Reactive View System Methods
    // =========================================================================

    /// Connect this window to an App for reactive rendering.
    /// This must be called before setRootView().
    pub fn connectApp(
        self: *Self,
        app_ptr: *anyopaque,
        ctx_vtable: *const ContextVTable,
        is_dirty_fn: *const fn (*anyopaque, render_mod.EntityId) bool,
        clear_dirty_fn: *const fn (*anyopaque, render_mod.EntityId) void,
        get_entities_fn: *const fn (*anyopaque) *EntityMap,
    ) void {
        self.app_ptr = app_ptr;
        self.app_ctx_vtable = ctx_vtable;
        self.is_dirty_fn = is_dirty_fn;
        self.clear_dirty_fn = clear_dirty_fn;
        self.get_entities_fn = get_entities_fn;
    }

    /// Set the root view for this window.
    /// T must be Renderable (have a render method).
    /// The window will automatically re-render when the view's entity is dirty.
    pub fn setRootView(self: *Self, comptime T: type, view: render_mod.Entity(T)) void {
        if (self.app_ptr == null) {
            @panic("Window.connectApp() must be called before setRootView()");
        }

        // Create the type-erased view
        self.root_view = AnyView.from(T, view);

        // Request initial render
        self.needs_render.store(true, .seq_cst);
    }

    /// Clear the root view
    pub fn clearRootView(self: *Self) void {
        self.root_view = null;
    }

    /// Check if the root view needs re-rendering
    pub fn rootViewIsDirty(self: *Self) bool {
        if (self.root_view) |view| {
            if (self.app_ptr) |app| {
                if (self.is_dirty_fn) |is_dirty| {
                    return is_dirty(app, view.entity_id);
                }
            }
        }
        return false;
    }

    /// Render the root view if it exists and is dirty
    pub fn renderRootViewIfNeeded(self: *Self) void {
        const view = self.root_view orelse return;
        const app = self.app_ptr orelse return;
        const ctx_vtable = self.app_ctx_vtable orelse return;
        const get_entities = self.get_entities_fn orelse return;

        // Check if dirty or forced render
        const is_dirty = if (self.is_dirty_fn) |check| check(app, view.entity_id) else false;

        if (!is_dirty and !self.needs_render.load(.seq_cst)) {
            return;
        }

        // Get the entity map
        const entities = get_entities(app);

        // Render the view
        var output = view.render(
            entities,
            app,
            ctx_vtable,
            @ptrCast(self),
            &self.window_vtable,
        );
        defer output.deinit();

        // Call custom render callback if set
        if (self.on_render) |on_render| {
            on_render(self, output);
        }

        // Clear dirty flag
        if (self.clear_dirty_fn) |clear| {
            clear(app, view.entity_id);
        }
    }

    /// Set a callback to be invoked when the root view renders.
    /// This is where you convert RenderOutput to Scene primitives.
    pub fn setRenderCallback(self: *Self, callback: *const fn (*Window, RenderOutput) void) void {
        self.on_render = callback;
    }

    // =========================================================================
    // WindowVTable Implementation
    // =========================================================================

    fn windowVTableGetSize(ptr: *anyopaque) WindowVTable.Size {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return .{
            .width = @floatCast(self.size.width),
            .height = @floatCast(self.size.height),
        };
    }

    fn windowVTableRequestRender(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.needs_render.store(true, .seq_cst);
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

        // =====================================================================
        // NEW: Check if root view is dirty and trigger re-render
        // =====================================================================
        var view_is_dirty = false;
        if (window.root_view) |view| {
            if (window.app_ptr) |app| {
                if (window.is_dirty_fn) |is_dirty| {
                    view_is_dirty = is_dirty(app, view.entity_id);
                }
            }
        }

        // Benchmark mode: always render. Normal mode: only when dirty
        const explicit_render = window.needs_render.swap(false, .acq_rel);
        const should_render = window.benchmark_mode or explicit_render or view_is_dirty;

        // Only render if needed (dirty flag pattern)
        if (should_render) {
            // CRITICAL: Create autorelease pool for this background thread!
            const pool = createAutoreleasePool() orelse return .success;
            defer drainAutoreleasePool(pool);

            // Lock to prevent race with resize on main thread
            window.resize_mutex.lock();
            defer window.resize_mutex.unlock();

            // =================================================================
            // NEW: Render root view if we have one
            // =================================================================
            if (view_is_dirty) {
                window.renderRootViewIfNeeded();
            }

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
