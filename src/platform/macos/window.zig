//! macOS window: AppKit hosting, input, and main-thread frames.
//!
//! Every frame is built, encoded, and presented on the main thread. A shared
//! per-display vsync (`display_link.zig`) ticks visible windows through the
//! main queue; a tick draws only when the window is dirty, a render deadline
//! has passed, or a custom shader animates. Covered or minimized windows
//! unsubscribe and receive no ticks at all. Because nothing runs on another
//! thread, window, scene, and atlas state need no locks.
//!
//! The one exception is acquiring the next drawable, which can sleep for most
//! of a refresh interval: the renderer's `DrawableReserve` does it on a worker
//! ahead of time, and a dirty tick with no drawable ready yet is skipped.

const std = @import("std");
const assert = std.debug.assert;
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
const render_delay_ms_max = interface_mod.render_delay_ms_max;

/// Maximum window title length in bytes, excluding the NUL terminator.
///
/// Matches the Linux backend's bound so an application that fits one host
/// fits the other. AppKit itself imposes no limit, but "put a limit on
/// everything" applies to the owned storage backing the title.
pub const title_bytes_max: usize = 255;

const NSRect = appkit.NSRect;
const NSSize = appkit.NSSize;

/// Minimum gap between frames of an unfocused window, so a background animation
/// cannot cost as much as the window the user is working in. It targets 30 fps
/// (33.3 ms) less half a 120 Hz tick: ticks are timed on the main queue and
/// jitter by a few milliseconds, and a strict 33.3 ms gap would often skip the
/// 4th tick at 120 Hz (or 2nd at 60 Hz) and drop to about 24 fps.
const unfocused_frame_gap_ns_min: u64 = 29_166_667;

/// Hard ceiling on application-supplied Metal shaders per window. Each one
/// costs a pipeline state object and a `custom_{d}` name slot, so the count
/// is bounded rather than taken on trust from the caller's slice.
const custom_shader_count_max: usize = 64;

pub const Window = struct {
    allocator: std.mem.Allocator,

    /// Owning platform. Retained so `deinit` can withdraw this window from the
    /// registry without the caller having to remember the pairing.
    plat: *platform.MacPlatform,

    /// Owned +1 from `alloc`/`init`, released once in `deinit`. AppKit's
    /// release-when-closed is turned off at creation, so this reference alone
    /// decides the window's lifetime (see `createNSWindow`).
    ns_window: objc.Object,
    /// Owned +1 from `input_view.create`, released once in `deinit`. The view
    /// owns `metal_layer` and, through it, the layer's drawables.
    ns_view: objc.Object,
    /// Borrowed: `+[CAMetalLayer layer]` is autoreleased and the view retains it.
    metal_layer: objc.Object,
    renderer: metal.Renderer,
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
    /// Something changed since the last frame. Main thread only.
    dirty: bool,
    /// Uptime (ns) at which to redraw even if nothing marks the window dirty,
    /// for clock-driven UI such as a caret blink; 0 when none is pending.
    render_deadline_ns: u64,
    /// Uptime (ns) when the last frame started; paces unfocused windows.
    frame_last_ns: u64,
    /// Display whose vsync ticks this window, or null while it is occluded,
    /// minimized, closed, or created with `use_display_link = false`.
    display_id: ?u32,
    /// Whether the window should receive ticks while visible.
    uses_display_link: bool,
    /// Key window state; unfocused windows are paced (`unfocused_frame_gap_ns_min`).
    key_window: bool,
    /// AppKit is live-resizing; `handleResize` draws synchronously meanwhile.
    live_resize_active: bool,
    scene: ?*const scene_mod.Scene,
    text_atlas: ?*const Atlas = null,
    svg_atlas: ?*const Atlas = null,
    image_atlas: ?*const Atlas = null,

    /// Owned +1 from `window_delegate.create`, released once in `deinit`.
    delegate: ?objc.Object = null,
    /// Owned +1 from `alloc`/`init`; the view also retains it while installed.
    /// `deinit` removes it from the view and releases this reference.
    tracking_area: ?objc.Object = null,

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
    // Glass effect support (macOS 26.0+ / fallback blur).
    /// Owned +1 from `alloc`/`init`; the superview also retains it while installed.
    glass_effect_view: ?objc.Object = null,
    glass_style: GlassStyle = .none,
    background_opacity: f64 = 1.0,
    glass_corner_radius: f64 = 16.0,

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
    /// NSProcessInfo activity token for preventing ProMotion throttling.
    /// Owned +1 (explicit retain in `beginHighPerformanceActivity`).
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
        assert(display_link.isMainThread());
        self.svg_atlas = atlas;
    }

    pub fn setImageAtlas(self: *Self, atlas: *const Atlas) void {
        assert(display_link.isMainThread());
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
            &options.limits.scene,
        );

        self.loadCustomShaders(options.custom_shaders);

        if (options.use_display_link) self.startFrameTicks();

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
            .size = geometry.Size(f64).init(options.width, options.height),
            .scale_factor = 1.0,
            // Zeroed rather than seeded from `options.title`: `init` calls
            // `setTitle` once the NSWindow exists, which is the one place that
            // owns the copy and the NUL termination.
            .title_buf = @splat(0),
            .title_len = 0,
            .background_color = options.background_color,
            .dirty = true,
            .render_deadline_ns = 0,
            .frame_last_ns = 0,
            .display_id = null,
            .uses_display_link = options.use_display_link,
            // Unfocused until AppKit says otherwise: the delegate is installed
            // before `makeKeyAndOrderFront:`, so `windowDidBecomeKey:` reports
            // focus. A window that never becomes key stays at the unfocused rate.
            .key_window = false,
            .live_resize_active = false,
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

        // Own the window's lifetime through the +1 above. With AppKit's default
        // (released when closed), `-close` frees the window by itself, and
        // `deinit` runs later, at the owning app's drain point after a titlebar
        // close, so it would message a freed object. `deinit` releases it once.
        self.ns_window.msgSend(void, "setReleasedWhenClosed:", .{false});
        assert(!self.ns_window.msgSend(bool, "isReleasedWhenClosed", .{}));

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

    /// Subscribe to this window's display and mark the process latency
    /// critical. A display-link failure is logged by `subscribeToDisplay`; the
    /// window then waits for the next occlusion or screen change to retry.
    fn startFrameTicks(self: *Self) void {
        assert(self.display_id == null);
        assert(self.activity_token == null);
        self.subscribeToDisplay();

        // Start acquiring the first frame's drawable now, so the first tick can draw. The
        // renderer is in its final place, which the reserve's worker requires.
        const first_drawable_ready = self.renderer.drawableReady();
        assert(!first_drawable_ready); // Nothing was reserved before this request.

        // macOS throttles ProMotion panels from 120Hz to 60Hz unless the
        // process declares that it is latency sensitive.
        self.activity_token = beginHighPerformanceActivity();
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

    /// Set the text atlas uploaded at the start of each frame.
    pub fn setTextAtlas(self: *Self, atlas: *const Atlas) void {
        assert(display_link.isMainThread());
        self.text_atlas = atlas;
    }

    /// Point the window at the scene to present. Called by the frame builder
    /// after it swaps buffers, inside the frame it is about to present, so it
    /// does not mark the window dirty: that would turn every frame into a
    /// request for another and keep idle windows drawing forever.
    pub fn setScene(self: *Self, s: *const scene_mod.Scene) void {
        assert(display_link.isMainThread());
        self.scene = s;
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
            handled = callback(self, event);

            // Runs after the input callback has fully returned, so it may enter
            // nested event loops (modal dialogs). Frames keep drawing inside
            // them: main-queue ticks are serviced in every common run-loop mode.
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

    /// The platform that owns this window.
    ///
    /// Contract-pinned so shared code can reach the host without spelling a
    /// per-backend field name — this backend stores it as `plat`, the others as
    /// `platform`. See `contract.verifyWindowLifecycle`.
    pub fn getPlatform(self: *Self) *platform.MacPlatform {
        assert(@intFromPtr(self.plat) != 0);
        return self.plat;
    }

    // =========================================================================
    // Window Lifecycle
    // =========================================================================

    /// Tear down the window. Runs once, on the main thread, after the close
    /// sequence, from the owning app's drain point (never inside this window's
    /// own dispatch).
    ///
    /// Order matters: leave the display's subscriber list first so no tick can
    /// reach the window while it is dismantled, then free GPU resources, then
    /// release the AppKit objects children-first, then free the Zig allocation.
    pub fn deinit(self: *Self) void {
        assert(display_link.isMainThread());
        assert(self.ns_window.value != null);
        assert(self.ns_view.value != null);

        // Withdraw from the registry first so nothing can look this window up
        // while its AppKit objects are being torn down. `.invalid` afterwards
        // makes a second `deinit` a no-op rather than a stale unregister.
        if (self.window_id.isValid()) {
            self.plat.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }
        assert(!self.window_id.isValid());

        self.closed = true;

        // Ticks run on the main thread, as does this, so once the window has
        // left the subscriber list no tick can observe it again.
        self.unsubscribeFromDisplay();
        assert(self.display_id == null);

        if (self.activity_token) |token| {
            endHighPerformanceActivity(token);
            self.activity_token = null;
        }

        self.renderer.deinit();
        self.releaseAppKitObjects();
        self.allocator.destroy(self);
    }

    /// Release every AppKit object `init` created, exactly once, children
    /// first. Each optional is cleared as it is released, so a second release
    /// cannot happen through it.
    ///
    /// AppKit may keep a view or window alive briefly after our release (an
    /// autorelease pool, an event in flight), so the `_gooeyWindow`
    /// back-pointers are cleared first: a late callback then finds no window
    /// and returns, instead of dereferencing the freed `Window`.
    fn releaseAppKitObjects(self: *Self) void {
        assert(self.display_id == null); // No tick can reach us any more.
        assert(self.ns_window.value != null);
        const nil: objc.Object = .{ .value = null };

        if (self.delegate) |d| {
            self.ns_window.msgSend(void, "setDelegate:", .{@as(?*anyopaque, null)});
            d.setInstanceVariable("_gooeyWindow", nil);
            d.release();
            self.delegate = null;
        }
        if (self.glass_effect_view) |glass_view| {
            glass_view.msgSend(void, "removeFromSuperview", .{});
            glass_view.release();
            self.glass_effect_view = null;
        }
        if (self.tracking_area) |area| {
            self.ns_view.msgSend(void, "removeTrackingArea:", .{area.value});
            area.release();
            self.tracking_area = null;
        }

        self.ns_view.setInstanceVariable("_gooeyWindow", nil);
        // `-close` is a no-op on an already-closed window. With release-when-
        // closed off, it never frees the window, so the release below is the
        // only one. The window drops its content-view retain when it is freed;
        // the view's own +1 is released after it.
        self.ns_window.msgSend(void, "close", .{});
        assert(!self.ns_window.msgSend(bool, "isReleasedWhenClosed", .{}));
        self.ns_window.release();
        self.ns_window = nil;
        self.ns_view.release();
        self.ns_view = nil;
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

        // During live resize AppKit is inside its own tracking loop and the
        // layer presents with the transaction, so draw now, synchronously, at
        // the new size. Ticks skip the window until the resize ends.
        if (self.live_resize_active) {
            self.drawFrame(.synchronous);
        } else {
            // The reserved drawable has the old size: replace it now rather than on the
            // next tick, which would then have to skip.
            _ = self.renderer.drawableReady();
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

        // Proceed with close. A closed window never presents again.
        self.unsubscribeFromDisplay();
        self.closed = true;
        assert(self.isClosed());
        return true;
    }

    pub fn handleFocusChange(self: *Self, focused: bool) void {
        assert(display_link.isMainThread());
        self.key_window = focused;
        self.requestRender();
    }

    pub fn handleLiveResizeStart(self: *Self) void {
        assert(!self.live_resize_active);
        self.live_resize_active = true;
        self.metal_layer.msgSend(void, "setPresentsWithTransaction:", .{true});
    }

    pub fn handleLiveResizeEnd(self: *Self) void {
        assert(self.live_resize_active);
        self.live_resize_active = false;
        self.metal_layer.msgSend(void, "setPresentsWithTransaction:", .{false});
        self.requestRender();
        // Synchronous frames gave the reserve back; acquire the next tick's drawable now.
        _ = self.renderer.drawableReady();
    }

    pub fn isInLiveResize(self: *const Self) bool {
        return self.live_resize_active;
    }

    /// The window became fully covered or visible again (including minimize
    /// and restore). Covered windows leave their display so they get no ticks.
    pub fn handleOcclusionChange(self: *Self) void {
        assert(display_link.isMainThread());
        if (self.closed) return;
        const occlusion_visible: u64 = 1 << 1; // NSWindowOcclusionStateVisible
        const state = self.ns_window.msgSend(u64, "occlusionState", .{});
        if (state & occlusion_visible != 0) {
            self.subscribeToDisplay();
            self.requestRender();
        } else {
            self.unsubscribeFromDisplay();
        }
    }

    /// The window moved to another screen: follow that display's vsync.
    pub fn handleScreenChange(self: *Self) void {
        assert(display_link.isMainThread());
        if (self.display_id == null) return; // Occluded or closed; nothing to move.
        if (self.display_id.? == display_link.displayIdForWindow(self.ns_window)) return;
        self.unsubscribeFromDisplay();
        self.subscribeToDisplay();
        self.requestRender();
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

    /// Draw on the next vsync tick. Main thread only: frames, input, and every
    /// caller of this run there, so a plain flag is enough.
    pub fn requestRender(self: *Self) void {
        assert(display_link.isMainThread());
        self.dirty = true;
    }

    /// Draw on the first tick at least `delay_ms` from now, even if nothing
    /// marks the window dirty. Keeps the earliest pending deadline. Serves
    /// clock-driven UI (caret blink, timers, polling a worker) without
    /// redrawing every vsync.
    pub fn requestRenderAfter(self: *Self, delay_ms: u32) void {
        assert(display_link.isMainThread());
        assert(delay_ms <= render_delay_ms_max);
        const deadline_ns = display_link.nowNs() + @as(u64, delay_ms) * std.time.ns_per_ms;
        if (self.render_deadline_ns == 0 or deadline_ns < self.render_deadline_ns) {
            self.render_deadline_ns = deadline_ns;
        }
        assert(self.render_deadline_ns != 0);
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

        // Remove existing glass effect if any; the superview drops its retain,
        // this drops ours.
        if (self.glass_effect_view) |glass_view| {
            glass_view.msgSend(void, "removeFromSuperview", .{});
            glass_view.release();
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
        assert(self.tracking_area == null);
        self.tracking_area = tracking_area;
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

    // =========================================================================
    // Main-thread frames
    // =========================================================================

    const FrameMode = enum {
        /// Commit and return; the drawable presents when the GPU finishes.
        asynchronous,
        /// Wait until scheduled and present inside the current CATransaction,
        /// so live-resize frames match the window's new size exactly.
        synchronous,
    };

    /// Display-link tick, on the main thread, at most once per coalesced vsync.
    /// Draws only when something asked for it, so an idle visible window costs a
    /// few branches per tick and builds no frame.
    fn displayTick(context: *anyopaque, now_ns: u64) void {
        const self: *Self = @ptrCast(@alignCast(context));
        assert(self.display_id != null);
        assert(!self.closed);
        if (self.live_resize_active) return; // `handleResize` draws meanwhile.

        if (self.render_deadline_ns != 0) {
            if (now_ns >= self.render_deadline_ns) {
                self.render_deadline_ns = 0;
                self.dirty = true;
            }
        }
        if (!self.dirty and !self.custom_shader_animation) return;

        // An unfocused window keeps its pending work and draws at most about
        // 30 times a second; focus returns it to full rate on the next tick.
        if (!self.key_window) {
            if (now_ns - self.frame_last_ns < unfocused_frame_gap_ns_min) return;
        }

        // Acquiring a drawable can sleep for most of a refresh interval, so it happens off
        // the main thread, ahead of the frame. None ready yet: skip this tick before
        // building anything and stay dirty; the next tick draws.
        if (!self.renderer.drawableReady()) return;
        self.frame_last_ns = now_ns;
        self.drawFrame(.asynchronous);
    }

    /// Build, upload, encode, and present one frame. Main thread only.
    fn drawFrame(self: *Self, mode: FrameMode) void {
        assert(display_link.isMainThread());
        assert(!self.closed);
        // Cleared first: building the frame may request the next one (an
        // animation still running), and that request must survive.
        self.dirty = false;

        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        if (self.on_render) |callback| callback(self);
        self.uploadAtlases();

        const clear_color = self.getClearColor();
        const scene = self.scene orelse {
            switch (mode) {
                .asynchronous => self.renderer.clear(clear_color),
                .synchronous => self.renderer.clearSynchronous(clear_color),
            }
            return;
        };
        switch (mode) {
            .asynchronous => self.renderSceneAsync(scene, clear_color),
            .synchronous => self.renderer.renderSceneSynchronous(scene, clear_color) catch |err| {
                std.log.err("renderSceneSynchronous failed: {}", .{err});
                self.renderer.clearSynchronous(clear_color);
            },
        }
    }

    fn renderSceneAsync(
        self: *Self,
        scene: *const scene_mod.Scene,
        clear_color: geometry.Color,
    ) void {
        assert(display_link.isMainThread());
        if (self.renderer.hasCustomShaders()) {
            self.renderer.renderSceneWithPostProcess(scene, clear_color) catch |err| {
                std.log.err("renderSceneWithPostProcess failed: {}", .{err});
                self.renderer.renderScene(scene, clear_color) catch {
                    self.renderer.clear(clear_color);
                };
            };
        } else {
            self.renderer.renderScene(scene, clear_color) catch |err| {
                std.log.err("renderScene failed: {}", .{err});
                self.renderer.clear(clear_color);
            };
        }
    }

    /// Copy any atlas pages the frame added into GPU textures. Atlases are
    /// written only on the main thread, during frame building, so they are
    /// read here without a lock.
    fn uploadAtlases(self: *Self) void {
        assert(display_link.isMainThread());
        if (self.text_atlas) |atlas| {
            self.renderer.updateTextAtlas(atlas) catch |err| {
                std.log.err("text atlas upload failed: {}", .{err});
            };
        }
        if (self.svg_atlas) |atlas| self.renderer.prepareSvgAtlas(atlas);
        if (self.image_atlas) |atlas| self.renderer.prepareImageAtlas(atlas);
    }

    /// Start receiving ticks from the display the window is on. Idempotent.
    fn subscribeToDisplay(self: *Self) void {
        assert(display_link.isMainThread());
        assert(!self.closed);
        if (!self.uses_display_link) return;
        if (self.display_id != null) return;

        const display_id = display_link.displayIdForWindow(self.ns_window);
        display_link.subscribe(display_id, .{ .context = self, .tick = displayTick }) catch {
            // Logged by `subscribe`. Without a link the window cannot animate,
            // but input still marks it dirty and the next occlusion or screen
            // change retries the subscription.
            return;
        };
        self.display_id = display_id;
    }

    /// Stop receiving ticks. Idempotent; must run before the window is freed.
    fn unsubscribeFromDisplay(self: *Self) void {
        assert(display_link.isMainThread());
        const display_id = self.display_id orelse return;
        display_link.unsubscribe(display_id, self);
        self.display_id = null;
    }
};

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

/// End a high-performance activity and release the token's retain from
/// `beginHighPerformanceActivity`.
fn endHighPerformanceActivity(token: objc.Object) void {
    assert(token.value != null);
    const NSProcessInfo = objc.getClass("NSProcessInfo") orelse return;
    const process_info = NSProcessInfo.msgSend(objc.Object, "processInfo", .{});
    process_info.msgSend(void, "endActivity:", .{token.value});
    token.release();
}
