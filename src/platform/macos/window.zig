//! macOS Window implementation with vsync-synchronized rendering
//!
//! Simplified version without Entity/View system integration.
//! Uses simple callbacks for rendering and input handling.

const std = @import("std");
const assert = std.debug.assert;
const Mutex = @import("../mutex.zig").Mutex;
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
const interface_mod = @import("../interface.zig");
const WindowId = interface_mod.WindowId;
const GlassStyle = interface_mod.GlassStyle;
const WindowOptions = interface_mod.WindowOptions;

/// Maximum window title length in bytes, excluding the NUL terminator.
///
/// Matches the Linux backend's bound so an application that fits one host
/// fits the other. AppKit itself imposes no limit, but "put a limit on
/// everything" applies to the owned storage backing the title.
pub const title_bytes_max: usize = 255;

const NSRect = appkit.NSRect;
const NSSize = appkit.NSSize;
const DisplayLink = display_link.DisplayLink;

/// Uploads a CPU-side atlas into GPU storage while holding the caller's lock.
/// Named so the three atlas hooks below stay inside the 100-column limit.
const AtlasUploadFn = *const fn (ctx: *anyopaque, renderer: *metal.Renderer) anyerror!void;

/// Hard ceiling on application-supplied Metal shaders per window. Each one
/// costs a pipeline state object and a `custom_{d}` name slot, so the count
/// is bounded rather than taken on trust from the caller's slice.
const custom_shader_count_max: usize = 64;

pub const Window = struct {
    allocator: std.mem.Allocator,

    /// Owning platform. Retained so `deinit` can withdraw this window from the
    /// registry without the caller having to remember the pairing.
    plat: *platform.MacPlatform,

    ns_window: objc.Object,
    ns_view: objc.Object,
    metal_layer: objc.Object,
    renderer: metal.Renderer,
    display_link: ?DisplayLink,
    size: geometry.Size(f64),
    scale_factor: f64,
    /// NUL-terminated window title storage.
    ///
    /// This was a borrowed `[]const u8` whose `.ptr` was handed straight to
    /// `-[NSString stringWithUTF8String:]`. That API requires a NUL-terminated
    /// C string, so it read past the end of any slice that was not incidentally
    /// terminated. The slice was also only borrowed, so a caller passing a
    /// stack buffer left the field dangling. Owning fixed storage fixes both,
    /// and matches Linux and the test backend.
    title_buf: [title_bytes_max + 1]u8,
    title_len: u16,
    background_color: geometry.Color,
    needs_render: std.atomic.Value(bool),
    scene: ?*const scene_mod.Scene,
    text_atlas: ?*const Atlas = null,
    svg_atlas: ?*const Atlas = null,
    image_atlas: ?*const Atlas = null,

    /// Thread-safe atlas upload callbacks for multi-window scenarios.
    /// These are set by WindowContext to hold the appropriate mutex during GPU upload,
    /// preventing races where another window's DisplayLink modifies the atlas.
    text_atlas_upload_ctx: ?*anyopaque = null,
    text_atlas_upload_fn: ?AtlasUploadFn = null,
    svg_atlas_upload_ctx: ?*anyopaque = null,
    svg_atlas_upload_fn: ?AtlasUploadFn = null,
    image_atlas_upload_ctx: ?*anyopaque = null,
    image_atlas_upload_fn: ?AtlasUploadFn = null,
    delegate: ?objc.Object = null,

    /// Unique identifier for this window in the platform's `WindowRegistry`.
    /// Assigned by `init`; reset to `.invalid` by `deinit` so a second
    /// teardown cannot unregister an ID that has since been reused.
    window_id: WindowId = .invalid,

    /// Set once the window has been closed, whether by `close()` or by the
    /// user going through the AppKit delegate. Hosts poll this to drop their
    /// reference without racing the delegate callback.
    closed: bool = false,
    // Custom shader animation flag
    custom_shader_animation: bool,
    // Glass effect support (macOS 26.0+ / fallback blur)
    glass_effect_view: ?objc.Object = null,
    glass_style: GlassStyle = .none,
    background_opacity: f64 = 1.0,
    glass_corner_radius: f64 = 16.0,

    /// Mutex protecting all render-related state accessed from DisplayLink thread.
    /// This includes: scene, text_atlas, background_color, size, scale_factor, renderer.
    /// Must be held when:
    /// - DisplayLink callback reads scene/atlas for rendering
    /// - Main thread modifies scene/atlas/size
    render_mutex: Mutex = .{},

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

    /// Last OS-level pointer icon applied via `NSCursor.set()`. Cached so
    /// the per-frame `setCursorShape` call (see `runtime/frame.zig`) is a
    /// no-op on the common case where the hovered element didn't change.
    cursor_shape: ?interface_mod.CursorShape = null,

    // IME (Input Method Editor) state
    marked_text: []const u8 = "",
    marked_text_buffer: [256]u8 = undefined,
    inserted_text: []const u8 = "",
    inserted_text_buffer: [256]u8 = undefined,
    pending_key_event: ?objc.c.id = null,
    /// IME cursor rect in view coordinates (for candidate window positioning)
    ime_cursor_rect: appkit.NSRect = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 1, .height = 20 },
    },
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

    /// Called when window is about to close. Return false to prevent close.
    on_close: ?CloseCallback = null,

    /// Called when window size changes.
    on_resize: ?ResizeCallback = null,

    /// Called after input handling completes and mutex is released.
    /// Use this for operations that may run nested event loops (e.g., modal dialogs).
    on_post_input: ?PostInputCallback = null,

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
            // `vibrancy` is a web-only style. macOS degrades it to `blur`
            // when applying it to AppKit, and either way the framebuffer must
            // clear transparent for the host backdrop to show through.
            .blur, .glass_regular, .glass_clear, .vibrancy => geometry.Color.transparent,
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

    /// Close callback: called when window is about to close. Return false to prevent close.
    pub const CloseCallback = *const fn (*Window) bool;

    /// Resize callback: called when window size changes
    pub const ResizeCallback = *const fn (*Window, f64, f64) void;

    /// Post-input callback: called after input handling with mutex released.
    /// Safe for operations that run nested event loops (modal dialogs, etc).
    pub const PostInputCallback = *const fn (*Window) void;

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        plat: *platform.MacPlatform,
        options: *const WindowOptions,
    ) !*Self {
        assert(@intFromPtr(plat) != 0);
        assert(options.width >= 1);
        assert(options.height >= 1);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        initFields(self, allocator, plat, options);

        // Register before touching AppKit: the delegate and input view both
        // capture `self`, and callbacks can fire during `center` below, so the
        // window must already be addressable by ID at that point.
        self.window_id = try plat.registerWindow(self);
        errdefer plat.unregisterWindow(self.window_id);
        assert(self.window_id.isValid());

        try self.createNSWindow(options);

        // Set delegate AFTER ns_view is created to prevent crashes from early delegate callbacks
        // (e.g., windowDidChangeBackingProperties can fire during center() and calls handleResize
        // which needs ns_view)
        const window_delegate = @import("window_delegate.zig");
        self.delegate = try window_delegate.create(self);
        self.ns_window.msgSend(void, "setDelegate:", .{self.delegate.?.value});

        // Setup glass/transparency effect if requested
        if (options.background_opacity < 1.0) {
            try self.setupGlassEffect(
                options.glass_style,
                options.background_opacity,
                options.glass_corner_radius,
            );
        }

        // Enable mouse tracking for mouseMoved events
        try self.setupTrackingArea();

        // The Retina backing scale must be known before the Metal layer is
        // sized, or the first frame is drawn at the wrong drawable resolution.
        self.scale_factor = self.ns_window.msgSend(f64, "backingScaleFactor", .{});
        assert(self.scale_factor > 0.0);

        try self.setupMetalLayer();
        self.renderer = try metal.Renderer.init(
            allocator,
            self.metal_layer,
            self.size,
            self.scale_factor,
        );

        self.loadCustomShaders(options.custom_shaders);

        if (options.use_display_link) try self.startDisplayLink();

        // Make window key and visible, then mark for initial render.
        self.ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});
        self.requestRender();

        // A newly ordered-front window claims focus. Every backend publishes
        // this explicitly so the policy is one visible line per backend rather
        // than an implicit "first window wins" buried in `WindowRegistry`,
        // which is what previously made macOS and Linux disagree about which
        // window `getActiveWindowId` named.
        plat.setActiveWindowId(self.window_id);

        assert(!self.closed);
        assert(self.plat.getWindow(self.window_id) != null);
        assert(self.plat.getActiveWindowId().? == self.window_id);
        return self;
    }

    /// Bring every field to a defined state before any AppKit object exists.
    ///
    /// `noinline` and out-pointer based per CLAUDE.md §13/§14: `Window` carries
    /// the embedded renderer plus two 256-byte IME buffers, so it must never
    /// be built in a caller's frame and copied.
    noinline fn initFields(
        self: *Self,
        allocator: std.mem.Allocator,
        plat: *platform.MacPlatform,
        options: *const WindowOptions,
    ) void {
        assert(@intFromPtr(self) != 0);
        assert(options.width >= 1);

        // AppKit handles (`ns_window`, `ns_view`, `metal_layer`) and the
        // renderer stay `undefined` until `init` has actually created them;
        // every field an early delegate callback could observe is set here.
        self.* = .{
            .allocator = allocator,
            .plat = plat,
            .ns_window = undefined,
            .ns_view = undefined,
            .metal_layer = undefined,
            .renderer = undefined,
            .display_link = null,
            .size = geometry.Size(f64).init(options.width, options.height),
            .scale_factor = 1.0,
            // Zeroed rather than seeded from `options.title`: `init` calls
            // `setTitle` once the NSWindow exists, which is the one place that
            // owns the copy and the NUL termination.
            .title_buf = @splat(0),
            .title_len = 0,
            .background_color = options.background_color,
            .needs_render = std.atomic.Value(bool).init(true),
            .scene = null,
            .custom_shader_animation = false,
            .glass_style = options.glass_style,
            .background_opacity = options.background_opacity,
            .glass_corner_radius = options.glass_corner_radius,
        };

        assert(self.window_id == .invalid);
        assert(!self.closed);
    }

    /// Create and configure the `NSWindow` and its content view.
    ///
    /// Split out of `init` to keep that function inside the 70-line limit.
    /// The ordering is load-bearing: the content view must exist before `init`
    /// installs the delegate, because delegate callbacks dereference it.
    fn createNSWindow(self: *Self, options: *const WindowOptions) !void {
        assert(options.width >= 1);
        assert(options.height >= 1);

        const NSWindow = objc.getClass("NSWindow") orelse return error.ClassNotFound;

        // Titled | closable | miniaturizable | resizable.
        const style_mask: u64 = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3);

        const content_rect = NSRect{
            .origin = .{ .x = 100, .y = 100 },
            .size = .{ .width = options.width, .height = options.height },
        };

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
        if (self.ns_window.value == null) return error.WindowCreationFailed;

        if (options.titlebar_transparent) {
            self.ns_window.msgSend(void, "setTitlebarAppearsTransparent:", .{true});
        }

        // Extend content under the titlebar for a full-bleed effect.
        if (options.full_size_content) {
            const current_mask = self.ns_window.msgSend(u64, "styleMask", .{});
            const full_size_content_mask: u64 = 1 << 15; // NSWindowStyleMaskFullSizeContentView
            self.ns_window.msgSend(void, "setStyleMask:", .{current_mask | full_size_content_mask});
        }

        self.setTitle(options.title);

        if (options.min_size) |min| {
            self.ns_window.msgSend(void, "setMinSize:", .{
                NSSize{ .width = min.width, .height = min.height },
            });
        }

        if (options.max_size) |max| {
            self.ns_window.msgSend(void, "setMaxSize:", .{
                NSSize{ .width = max.width, .height = max.height },
            });
        }

        if (options.centered) {
            self.ns_window.msgSend(void, "center", .{});
        }

        const view_frame: NSRect = self.ns_window.msgSend(NSRect, "contentLayoutRect", .{});
        self.ns_view = try input_view.create(view_frame, self);
        self.ns_window.msgSend(void, "setContentView:", .{self.ns_view.value});
        assert(self.ns_view.value != null);
    }

    /// Compile the application's Metal shaders into the renderer.
    ///
    /// A shader that fails to build is logged and skipped: losing one custom
    /// effect degrades the visuals, whereas failing window creation would take
    /// the whole application down for a cosmetic problem.
    fn loadCustomShaders(self: *Self, shaders: []const shader_mod.CustomShader) void {
        assert(shaders.len <= custom_shader_count_max);
        if (shaders.len == 0) return;

        for (shaders, 0..) |shader, i| {
            assert(i < custom_shader_count_max);
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

        // Custom shaders read `iTime`, so the frame clock must keep advancing
        // even when no input or scene change would otherwise request a render.
        self.custom_shader_animation = true;
    }

    /// Start the CVDisplayLink that paces rendering to vsync.
    fn startDisplayLink(self: *Self) !void {
        assert(self.display_link == null);
        assert(self.activity_token == null);

        self.display_link = try DisplayLink.init();
        errdefer {
            self.display_link.?.deinit();
            self.display_link = null;
        }

        try self.display_link.?.setCallback(displayLinkCallback, @ptrCast(self));
        try self.display_link.?.start();

        const refresh_rate = self.display_link.?.getRefreshRate();
        std.debug.print("DisplayLink started at {d:.1}Hz\n", .{refresh_rate});

        // macOS throttles ProMotion panels from 120Hz to 60Hz unless the
        // process declares that it is latency sensitive.
        self.activity_token = beginHighPerformanceActivity();
        assert(self.display_link != null);
    }

    // =========================================================================
    // Callback Setters
    // =========================================================================

    /// Set the input callback. `null` clears it.
    pub fn setInputCallback(self: *Self, callback: ?InputCallback) void {
        assert(self.window_id.isValid());
        self.on_input = callback;
        assert((self.on_input == null) == (callback == null));
    }

    /// Set the render callback. `null` clears it.
    pub fn setRenderCallback(self: *Self, callback: ?RenderCallback) void {
        assert(self.window_id.isValid());
        self.on_render = callback;
        assert((self.on_render == null) == (callback == null));
    }

    /// Set the close callback. Return false from callback to prevent window close.
    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        assert(self.window_id.isValid());
        self.on_close = callback;
        assert((self.on_close == null) == (callback == null));
    }

    /// Set the resize callback. `null` clears it.
    pub fn setResizeCallback(self: *Self, callback: ?ResizeCallback) void {
        assert(self.window_id.isValid());
        self.on_resize = callback;
        assert((self.on_resize == null) == (callback == null));
    }

    /// Set the post-input callback (called after mutex is released). `null` clears it.
    pub fn setPostInputCallback(self: *Self, callback: ?PostInputCallback) void {
        assert(self.window_id.isValid());
        self.on_post_input = callback;
        assert((self.on_post_input == null) == (callback == null));
    }

    /// Set the user data pointer
    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        assert(self.window_id.isValid());
        self.user_data = data;
        assert((self.user_data == null) == (data == null));
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

    /// Set thread-safe text atlas upload callback for multi-window scenarios.
    /// The callback is called with the appropriate mutex held during GPU upload.
    pub fn setTextAtlasUploadCallback(
        self: *Self,
        ctx: *anyopaque,
        callback: *const fn (ctx: *anyopaque, renderer: *metal.Renderer) anyerror!void,
    ) void {
        self.text_atlas_upload_ctx = ctx;
        self.text_atlas_upload_fn = callback;
    }

    /// Set thread-safe SVG atlas upload callback for multi-window scenarios.
    pub fn setSvgAtlasUploadCallback(
        self: *Self,
        ctx: *anyopaque,
        callback: *const fn (ctx: *anyopaque, renderer: *metal.Renderer) anyerror!void,
    ) void {
        self.svg_atlas_upload_ctx = ctx;
        self.svg_atlas_upload_fn = callback;
    }

    /// Set thread-safe image atlas upload callback for multi-window scenarios.
    pub fn setImageAtlasUploadCallback(
        self: *Self,
        ctx: *anyopaque,
        callback: *const fn (ctx: *anyopaque, renderer: *metal.Renderer) anyerror!void,
    ) void {
        self.image_atlas_upload_ctx = ctx;
        self.image_atlas_upload_fn = callback;
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

    /// Backing scale factor of the display this window is on.
    ///
    /// `f64` across every backend: web previously narrowed this to `f32` and
    /// silently lost precision for shared callers.
    pub fn getScaleFactor(self: *const Self) f64 {
        assert(self.scale_factor > 0.0);
        assert(self.scale_factor <= 8.0);
        return self.scale_factor;
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
            handled = callback(self, event);
            self.render_mutex.unlock();

            // Call post-input callback AFTER mutex is released.
            // This is safe for operations that run nested event loops (modal dialogs).
            if (self.on_post_input) |post_callback| {
                post_callback(self);
            }
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

    /// Get the unique identifier for this window.
    pub fn getWindowId(self: *const Self) WindowId {
        return self.window_id;
    }

    // =========================================================================
    // Window Lifecycle
    // =========================================================================

    pub fn deinit(self: *Self) void {
        assert(self.ns_window.value != null);

        // Withdraw from the registry first so nothing can look this window up
        // while its AppKit objects are being torn down. `.invalid` afterwards
        // makes a second `deinit` a no-op rather than a stale unregister.
        if (self.window_id.isValid()) {
            self.plat.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }
        assert(!self.window_id.isValid());

        self.closed = true;

        if (self.delegate) |d| {
            self.ns_window.msgSend(void, "setDelegate:", .{@as(?*anyopaque, null)});
            d.release();
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
    pub fn handleResize(self: *Self) void {
        const old_width = self.size.width;
        const old_height = self.size.height;
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

        // Acquire render mutex to safely modify size/scale while DisplayLink might be reading.
        self.render_mutex.lock();
        defer self.render_mutex.unlock();

        // Mark rendering as in progress while the lock is held. The synchronous
        // render below invokes the user's on_render callback, which calls back
        // into setScene/setTextAtlas/etc. Those setters re-lock render_mutex
        // unless this flag tells them the lock is already held. Without it the
        // re-entrant lock attempt aborts an os_unfair_lock (recursive lock).
        self.render_in_progress.store(true, .release);
        defer self.render_in_progress.store(false, .release);

        self.size.width = new_width;
        self.size.height = new_height;
        self.scale_factor = new_scale;

        self.metal_layer.msgSend(void, "setContentsScale:", .{new_scale});

        self.renderer.resize(geometry.Size(f64).init(
            new_width,
            new_height,
        ), new_scale);

        self.requestRender();

        // Notify user of resize if size actually changed
        const size_changed = (old_width != new_width or old_height != new_height);
        if (size_changed) {
            if (self.on_resize) |callback| {
                callback(self, new_width, new_height);
            }
        }

        // During live resize, render synchronously for smooth visuals
        if (self.in_live_resize.load(.acquire)) {
            const pool = objc.AutoreleasePool.init();
            defer pool.deinit();

            // Call render callback to update scene
            if (self.on_render) |callback| {
                callback(self);
            }

            // Use thread-safe callbacks if available (multi-window scenarios)
            if (self.text_atlas_upload_fn) |upload_fn| {
                if (self.text_atlas_upload_ctx) |ctx| {
                    upload_fn(ctx, &self.renderer) catch {};
                }
            } else if (self.text_atlas) |atlas| {
                self.renderer.updateTextAtlas(atlas) catch {};
            }
            if (self.svg_atlas_upload_fn) |upload_fn| {
                if (self.svg_atlas_upload_ctx) |ctx| {
                    upload_fn(ctx, &self.renderer) catch {};
                }
            } else if (self.svg_atlas) |atlas| {
                self.renderer.prepareSvgAtlas(atlas);
            }
            if (self.image_atlas_upload_fn) |upload_fn| {
                if (self.image_atlas_upload_ctx) |ctx| {
                    upload_fn(ctx, &self.renderer) catch {};
                }
            } else if (self.image_atlas) |atlas| {
                self.renderer.prepareImageAtlas(atlas);
            }

            if (self.scene) |s| {
                self.renderer.renderSceneSynchronous(s, self.getClearColor()) catch {};
            } else {
                self.renderer.clearSynchronous(self.getClearColor());
            }
        }
    }

    /// Handle window close. Returns true if close should proceed, false to cancel.
    pub fn handleClose(self: *Self) bool {
        // Call user callback first - they can prevent close by returning false
        if (self.on_close) |callback| {
            if (!callback(self)) {
                return false; // User prevented close
            }
        }

        // Proceed with close.
        if (self.display_link) |*dl| {
            dl.stop();
        }
        self.closed = true;
        assert(self.isClosed());
        return true;
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
    // Window Operations
    // =========================================================================

    /// Focus this window (bring to front and make key window).
    ///
    /// Makes this window the key window and orders it to the front.
    pub fn focus(self: *Self) void {
        self.ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});
    }

    /// Close this window programmatically.
    ///
    /// Triggers the close callback if set, allowing it to cancel.
    /// If close proceeds, the window is destroyed.
    pub fn close(self: *Self) void {
        assert(self.ns_window.value != null);
        if (self.closed) return;

        // `performClose:` routes through `windowShouldClose:`, so the close
        // callback still gets to veto; `closed` is set by `handleClose` only
        // once the veto has been declined.
        self.ns_window.msgSend(void, "performClose:", .{@as(?*anyopaque, null)});
    }

    /// Whether this window has completed its close sequence.
    pub fn isClosed(self: *const Self) bool {
        assert(self.ns_window.value != null);
        // A window that has not closed is still registered; unregistration
        // happens only in `deinit`, which runs after the close sequence.
        if (!self.closed) assert(self.window_id.isValid());
        return self.closed;
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
        assert(self.ns_window.value != null);
        assert(self.title_buf.len == title_bytes_max + 1);

        // Clamp rather than fail: an over-long title is a cosmetic problem, and
        // AppKit truncates for display anyway. The assertion catches it in
        // Debug; the clamp keeps the copy in bounds in release.
        assert(new_title.len <= title_bytes_max);
        const len = @min(new_title.len, title_bytes_max);

        @memcpy(self.title_buf[0..len], new_title[0..len]);

        // Zero the whole tail, not just the terminator: the buffer is reused
        // across `setTitle` calls, so a shorter title would otherwise leave the
        // previous title's bytes readable past the NUL (CLAUDE.md §21).
        @memset(self.title_buf[len..], 0);
        self.title_len = @intCast(len);

        assert(self.title_buf[self.title_len] == 0);

        const NSString = objc.getClass("NSString") orelse return;
        const ns_title = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{@as([*:0]const u8, @ptrCast(&self.title_buf))},
        );

        self.ns_window.msgSend(void, "setTitle:", .{ns_title});
    }

    /// Current window title, borrowed from the window's own storage.
    pub fn title(self: *const Self) []const u8 {
        assert(self.title_len <= title_bytes_max);
        return self.title_buf[0..self.title_len];
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        self.background_color = color;
        self.requestRender();
    }

    /// Set the window appearance (light or dark mode)
    /// This affects the titlebar text color and other system UI elements
    pub fn setAppearance(self: *Self, dark: bool) void {
        const NSAppearance = objc.getClass("NSAppearance") orelse return;
        const NSString = objc.getClass("NSString") orelse return;

        // NSAppearanceNameAqua for light, NSAppearanceNameDarkAqua for dark
        // Create NSString from null-terminated C string literal
        const appearance_name: [*:0]const u8 =
            if (dark) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua";
        const ns_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{appearance_name});
        const appearance_ptr =
            NSAppearance.msgSend(?*anyopaque, "appearanceNamed:", .{ns_name.value});

        if (appearance_ptr) |ptr| {
            const appearance = objc.Object.fromId(ptr);
            self.ns_window.msgSend(void, "setAppearance:", .{appearance.value});
        }
    }

    /// Set the OS-level mouse pointer icon (not the text-caret drawn by
    /// `TextInput`/`TextArea`/`CodeEditor` — see `interface.CursorShape`).
    ///
    /// `NSCursor.set()` pushes onto a stack rather than replacing outright,
    /// but since Gooey calls this once per frame with the fully-resolved
    /// shape (mirroring the Linux/`wp_cursor_shape_manager_v1` path in
    /// `runtime/frame.zig::updateCursorShape`), there is never more than
    /// one Gooey-owned cursor pushed at a time.
    pub fn setCursorShape(self: *Self, shape: interface_mod.CursorShape) void {
        std.debug.assert(self.ns_window.value != null);
        std.debug.assert(self.ns_view.value != null);
        if (self.cursor_shape) |current| {
            if (current == shape) return;
        }

        const NSCursor = objc.getClass("NSCursor") orelse return;
        const cursor = switch (shape) {
            .default => NSCursor.msgSend(objc.Object, "arrowCursor", .{}),
            .text => NSCursor.msgSend(objc.Object, "IBeamCursor", .{}),
            .pointer => NSCursor.msgSend(objc.Object, "pointingHandCursor", .{}),
        };
        std.debug.assert(cursor.value != null);

        cursor.msgSend(void, "set", .{});
        self.cursor_shape = shape;
    }

    /// Change the glass effect style at runtime.
    pub fn setGlassStyle(self: *Self, style: GlassStyle, opacity: f64, corner_radius: f64) void {
        assert(self.ns_window.value != null);
        assert(opacity >= 0.0 and opacity <= 1.0);
        assert(corner_radius >= 0.0);

        // Remove existing glass effect if any
        if (self.glass_effect_view) |glass_view| {
            glass_view.msgSend(void, "removeFromSuperview", .{});
            self.glass_effect_view = null;
        }

        // Update stored values
        self.glass_style = style;
        self.background_opacity = opacity;
        self.glass_corner_radius = corner_radius;

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

            // Apply new glass effect.
            switch (style) {
                .glass_regular, .glass_clear => {
                    if (!self.setupLiquidGlass(style, corner_radius)) {
                        self.setupTraditionalBlur();
                    }
                },
                // `vibrancy` names the browser's `backdrop-filter`, which has
                // no AppKit equivalent. CGS background blur is the closest
                // native effect, so degrade to it rather than render opaque.
                .blur, .vibrancy => self.setupTraditionalBlur(),
                .none => unreachable,
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
            @as(objc.c.id, @ptrFromInt(0)),
        });

        self.ns_view.msgSend(void, "addTrackingArea:", .{tracking_area.value});
    }

    fn setupMetalLayer(self: *Self) !void {
        const CAMetalLayer = objc.getClass("CAMetalLayer") orelse return error.ClassNotFound;
        self.metal_layer = CAMetalLayer.msgSend(objc.Object, "layer", .{});

        // Configure the layer
        // 80 = MTLPixelFormatBGRA8Unorm.
        self.metal_layer.msgSend(void, "setPixelFormat:", .{@as(u64, 80)});
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
        assert(self.ns_window.value != null);
        assert(corner_radius >= 0.0);
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
            // `vibrancy` is the web backend's `backdrop-filter` style. AppKit
            // has no counterpart, so it degrades to the CGS blur that is
            // visually closest instead of being silently dropped.
            .blur, .vibrancy => {
                self.setupTraditionalBlur();
            },
            .none => unreachable, // Returned above.
        }
    }

    fn setupLiquidGlass(self: *Self, style: GlassStyle, corner_radius: f64) bool {
        assert(style == .glass_regular or style == .glass_clear);
        assert(corner_radius >= 0.0);

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
        std.debug.print(
            "Liquid glass enabled (style: {}, tint: rgba({d:.2},{d:.2},{d:.2},{d:.2}))\n",
            .{ style, tint_r, tint_g, tint_b, tint_a },
        );
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
    // Renderer introspection
    // =========================================================================

    /// Get renderer capabilities.
    pub fn getRendererCapabilities(self: *const Self) interface_mod.RendererCapabilities {
        assert(self.renderer.sample_count >= 1);
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
    const should_render =
        window.benchmark_mode or explicit_render or window.custom_shader_animation;

    // DEBUG. CVDisplayLink callbacks run on a dedicated vsync thread that
    // does not carry a `*Cx`/`Gooey`, so we reach for the single-threaded
    // global `Io` here — same escape hatch as the render mutex (Phase 5
    // option 3 in the migration doc). `std.Io` is a pair of pointers into
    // a process-lifetime vtable, so there's no allocation or cost.
    const static = struct {
        var count: u32 = 0;
        var last_print_ms: i64 = 0;
    };
    static.count += 1;
    const dl_io = std.Io.Threaded.global_single_threaded.io();
    const now_ms = std.Io.Timestamp.now(dl_io, .awake).toMilliseconds();
    if (now_ms - static.last_print_ms > 1000) {
        // Uncomment to trace callback rate:
        // std.debug.print(
        //     "DisplayLink callbacks/sec: {}, should_render: {}, explicit: {}\n",
        //     .{ static.count, should_render, explicit_render },
        // );
        static.count = 0;
        static.last_print_ms = now_ms;
    }

    if (!should_render) {
        return .success;
    }

    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();

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

    // Update text atlas if set - use thread-safe callback if available
    // The callback holds the glyph_cache_mutex during upload, preventing races
    // where another window's DisplayLink modifies the atlas concurrently.
    if (window.text_atlas_upload_fn) |upload_fn| {
        if (window.text_atlas_upload_ctx) |ctx| {
            upload_fn(ctx, &window.renderer) catch {};
        }
    } else if (window.text_atlas) |atlas| {
        window.renderer.updateTextAtlas(atlas) catch {};
    }

    // Update SVG atlas if set - use thread-safe callback if available
    if (window.svg_atlas_upload_fn) |upload_fn| {
        if (window.svg_atlas_upload_ctx) |ctx| {
            upload_fn(ctx, &window.renderer) catch {};
        }
    } else if (window.svg_atlas) |atlas| {
        window.renderer.prepareSvgAtlas(atlas);
    }

    // Update image atlas if set - use thread-safe callback if available
    if (window.image_atlas_upload_fn) |upload_fn| {
        if (window.image_atlas_upload_ctx) |ctx| {
            upload_fn(ctx, &window.renderer) catch {};
        }
    } else if (window.image_atlas) |atlas| {
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
        std.debug.print("WARNING: activity token null; ProMotion throttling not prevented\n", .{});
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
