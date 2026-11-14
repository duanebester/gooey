//! macOS window: the NSWindow, its input view and Metal layer, and the
//! bridge that turns AppKit callbacks into core queue events (see
//! `CoreBinding`). The core host (`core_host.zig`) draws on its own render
//! thread.

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");
const geometry = @import("../../geometry/geometry.zig");
const platform = @import("platform.zig");
const metal = @import("metal/metal.zig");
const backend = @import("../../core/backend.zig");
const limits_mod = @import("../../core/limits.zig");
const input_view = @import("input_view.zig");
const input = @import("../../input/events.zig");
const appkit = @import("appkit.zig");
const interface_mod = @import("../interface.zig");
const WindowOptions = interface_mod.WindowOptions;
const core_events = @import("../../core/events.zig");
const core_router = @import("../../core/router.zig");
const core_clipboard = @import("../../core/clipboard.zig");
const core_text_engine = @import("../../core/text_engine.zig");

/// How a 0.4.0 core app drives this window (contract §9): the window pushes
/// input and resizes into the core's queue and asks the host for a tick, and
/// AppKit's synchronous questions (the IME rect, whether a key is claimed)
/// go to the read-only query. The host's render thread draws.
pub const CoreBinding = struct {
    queue: *core_events.EventQueue,
    query: *const core_router.Query,
    context: *anyopaque,
    /// Ask the host for a main-thread tick. Called on the main thread after
    /// every push.
    schedule_tick: *const fn (context: *anyopaque) void,
};

/// Maximum window title length in bytes, excluding the NUL terminator.
///
/// Matches the Linux backend's bound so an application that fits one host
/// fits the other. AppKit itself imposes no limit, but "put a limit on
/// everything" applies to the owned storage backing the title.
pub const title_bytes_max: usize = 255;

const NSRect = appkit.NSRect;
const NSSize = appkit.NSSize;

pub const Window = struct {
    allocator: std.mem.Allocator,

    /// Owning platform.
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
    /// The budget's framebuffer, which caps the content size (`applySizeLimits`).
    window_limits: limits_mod.WindowLimits,
    /// `WindowOptions.min_size` and `max_size`: frame sizes in points, as
    /// `setMinSize:` and `setMaxSize:` take them.
    min_size: ?geometry.Size(f64),
    max_size: ?geometry.Size(f64),
    /// The backing scale the content size limits were last applied for; 0
    /// until `createNSWindow` applies them.
    size_limits_scale: f64,
    /// NUL-terminated window title storage.
    ///
    /// `-[NSString stringWithUTF8String:]` requires a NUL-terminated C string,
    /// so handing it a borrowed slice's `.ptr` would read past the end of any
    /// slice that is not incidentally terminated, and a caller passing a stack
    /// buffer would leave a borrowed field dangling. Owning fixed storage rules
    /// out both, and matches Linux.
    title_buf: [title_bytes_max + 1]u8,
    title_len: u16,

    /// Owned +1 from `window_delegate.create`, released once in `deinit`.
    delegate: ?objc.Object = null,
    /// Owned +1 from `alloc`/`init`; the view also retains it while installed.
    /// `deinit` removes it from the view and releases this reference.
    tracking_area: ?objc.Object = null,

    /// Last OS-level pointer icon applied via `NSCursor.set()`. Cached so
    /// the host's `setCursorShape` call is a no-op when the hovered element
    /// didn't change.
    cursor_shape: ?interface_mod.CursorShape = null,

    // IME (Input Method Editor) state
    marked_text: []const u8 = "",
    marked_text_buffer: [marked_text_bytes_max]u8 = undefined,
    /// The marked text's length and the IME's selection within it, in UTF-16
    /// units as NSTextInputClient counts them; `marked_text` is UTF-8.
    marked_length_utf16: c_ulong = 0,
    marked_selection: appkit.NSRange = .{ .location = 0, .length = 0 },
    /// `marked_length_utf16` as the core's rendered frame shows it, which
    /// lags `setMarkedText:` by a frame. The core host sets it.
    rendered_marked_length_utf16: c_ulong = 0,

    /// Called when window is about to close. Return false to prevent close.
    on_close: ?CloseCallback = null,

    /// Set when a 0.4.0 core app drives this window; see `CoreBinding`.
    core: ?CoreBinding = null,

    // =========================================================================
    // Types
    // =========================================================================

    /// Close callback: called when window is about to close. Return false to prevent close.
    pub const CloseCallback = *const fn (*Window) bool;

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
        try self.createNSWindow(options);

        // Set delegate AFTER ns_view is created to prevent crashes from early delegate callbacks
        // (e.g., windowDidChangeBackingProperties can fire during center() and calls handleResize
        // which needs ns_view)
        const window_delegate = @import("window_delegate.zig");
        self.delegate = try window_delegate.create(self);
        self.ns_window.msgSend(void, "setDelegate:", .{self.delegate.?.value});

        // Enable mouse tracking for mouseMoved events
        try self.setupTrackingArea();

        // `createNSWindow` read the backing scale and capped the size, so the
        // Metal layer and the renderer are sized for the first frame's drawable.
        assert(self.scale_factor > 0.0);
        assert(self.size_limits_scale == self.scale_factor);

        try self.setupMetalLayer();
        const render_limits = backend.RenderLimits.fromResourceLimits(&options.limits);
        const viewport = framebufferViewport(.{
            .width = self.size.width,
            .height = self.size.height,
            .scale_factor = self.scale_factor,
        }, &render_limits.window);
        try self.renderer.initInPlace(&.{
            .native = self.metal_layer.value,
            .size_px = viewport.size_px,
            .scale_factor = viewport.scale_factor,
        }, &render_limits);

        self.ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});

        assert(self.core == null);
        assert(self.delegate != null);
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
            .window_limits = options.limits.window,
            .min_size = options.min_size,
            .max_size = options.max_size,
            .size_limits_scale = 0,
            // Zeroed rather than seeded from `options.title`: `init` calls
            // `setTitle` once the NSWindow exists, which is the one place that
            // owns the copy and the NUL termination.
            .title_buf = @splat(0),
            .title_len = 0,
        };

        assert(self.core == null);
        assert(self.on_close == null);
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

        self.setTitle(options.title);

        // The backing scale of the screen the window opened on decides the
        // cap, which must shrink an oversized request before `center` places it.
        // No delegate is installed yet, so the shrink is read back here.
        self.scale_factor = self.ns_window.msgSend(f64, "backingScaleFactor", .{});
        assert(self.scale_factor > 0.0);
        self.applySizeLimits(self.scale_factor);
        self.size = self.contentSize();

        if (options.centered) {
            self.ns_window.msgSend(void, "center", .{});
        }

        const view_frame: NSRect = self.ns_window.msgSend(NSRect, "contentLayoutRect", .{});
        self.ns_view = try input_view.create(view_frame, self);
        self.ns_window.msgSend(void, "setContentView:", .{self.ns_view.value});
        assert(self.ns_view.value != null);
    }

    /// Set the close callback. Return false from callback to prevent window close.
    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        assert(self.ns_window.value != null);
        self.on_close = callback;
        assert((self.on_close == null) == (callback == null));
    }

    // =========================================================================
    // IME Support
    // =========================================================================

    /// The composition the window keeps for the input method to read back,
    /// as long as the text engines' preedit, which shows no more.
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
        assert(self.marked_text.len <= marked_text_bytes_max);
        if (kept > 0 and kept < text.len) assert(text[kept] & 0xC0 != 0x80);
    }

    /// Clear the marked text (composition ended or cancelled)
    pub fn clearMarkedText(self: *Self) void {
        self.marked_text = "";
        self.marked_length_utf16 = 0;
        self.marked_selection = .{ .location = 0, .length = 0 };
    }

    /// Check if there's active IME composition
    pub fn hasMarkedText(self: *const Self) bool {
        return self.marked_text.len > 0;
    }

    // =========================================================================
    // Input Handling
    // =========================================================================

    /// Events that arrive before the core host binds are dropped: `init`
    /// shows the window before `bindCore`, and nothing can consume them yet.
    pub fn handleInput(self: *Self, event: input.InputEvent) bool {
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
        assert(self.core == null);
        assert(self.ns_view.value != null);
        self.core = binding;
    }

    // =========================================================================
    // Window Lifecycle
    // =========================================================================

    /// Tear down the window. Runs once, on the main thread, after the core
    /// host's render thread has stopped: free GPU resources, then release the
    /// AppKit objects children-first, then free the Zig allocation.
    pub fn deinit(self: *Self) void {
        assert(self.ns_window.value != null);
        assert(self.ns_view.value != null);
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
        assert(self.ns_window.value != null);
        assert(self.ns_view.value != null);
        const nil: objc.Object = .{ .value = null };

        if (self.delegate) |d| {
            self.ns_window.msgSend(void, "setDelegate:", .{@as(?*anyopaque, null)});
            d.setInstanceVariable("_gooeyWindow", nil);
            d.release();
            self.delegate = null;
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
        const new_scale = self.ns_window.msgSend(f64, "backingScaleFactor", .{});
        assert(new_scale > 0);
        // A display with another backing scale changes how many points the
        // budget allows; a shrink re-enters here first (`applySizeLimits`).
        if (new_scale != self.size_limits_scale) self.applySizeLimits(new_scale);
        assert(self.size_limits_scale == new_scale);

        const bounds: NSRect = self.ns_view.msgSend(NSRect, "bounds", .{});

        const new_width = bounds.size.width;
        const new_height = bounds.size.height;

        if (new_width < 1 or new_height < 1) {
            return;
        }

        if (new_width == self.size.width and
            new_height == self.size.height and
            new_scale == self.scale_factor)
        {
            return;
        }

        const size = geometry.Size(f64).init(new_width, new_height);
        if (self.core) |binding| {
            self.resizeCore(binding, size, new_scale);
        } else {
            // Before `bindCore`: record the geometry the host reads at bind.
            self.size = size;
            self.scale_factor = new_scale;
            self.metal_layer.msgSend(void, "setContentsScale:", .{new_scale});
        }
    }

    /// Cap the content size at the largest the budget's framebuffer holds at
    /// `scale_factor`, within the app's `min_size` and `max_size`, and shrink a
    /// window already past it. The framebuffer a window can reach is then the
    /// one the budget reserved (CLAUDE.md §2), never a reduced drawing scale.
    /// A `min_size` past the cap yields to it, as on Windows. AppKit holds
    /// live resizes and zoom to the cap. The shrink posts `windowDidResize:`,
    /// which re-enters `handleResize`; `size_limits_scale` is set first, so
    /// that call reads the capped bounds without reapplying the limits.
    fn applySizeLimits(self: *Self, scale_factor: f64) void {
        assert(scale_factor > 0);
        assert(self.ns_window.value != null);
        var content_max = contentSizeMax(&self.window_limits, scale_factor);
        if (self.max_size) |max_size| {
            const content = self.contentSizeForFrame(max_size);
            content_max.width = @min(content_max.width, content.width);
            content_max.height = @min(content_max.height, content.height);
        }
        self.ns_window.msgSend(void, "setContentMaxSize:", .{
            NSSize{ .width = content_max.width, .height = content_max.height },
        });
        if (self.min_size) |min_size| {
            const content = self.contentSizeForFrame(min_size);
            self.ns_window.msgSend(void, "setContentMinSize:", .{NSSize{
                .width = @min(content.width, content_max.width),
                .height = @min(content.height, content_max.height),
            }});
        }
        self.size_limits_scale = scale_factor;

        const current = self.contentSize();
        if (current.width > content_max.width or current.height > content_max.height) {
            std.log.info("window: content {d}x{d} pt capped at {d}x{d} pt, the " ++
                "ResourceLimits.window framebuffer at scale {d:.2}", .{
                current.width,
                current.height,
                content_max.width,
                content_max.height,
                scale_factor,
            });
            self.ns_window.msgSend(void, "setContentSize:", .{NSSize{
                .width = @min(current.width, content_max.width),
                .height = @min(current.height, content_max.height),
            }});
        }
        const capped = self.contentSize();
        assert(capped.width <= content_max.width);
        assert(capped.height <= content_max.height);
    }

    /// The window's content size in points, from its frame.
    fn contentSize(self: *const Self) geometry.Size(f64) {
        assert(self.ns_window.value != null);
        const frame: NSRect = self.ns_window.msgSend(NSRect, "frame", .{});
        const content: NSRect =
            self.ns_window.msgSend(NSRect, "contentRectForFrameRect:", .{frame});
        assert(content.size.width >= 0);
        assert(content.size.height >= 0);
        return geometry.Size(f64).init(content.size.width, content.size.height);
    }

    /// The content size a frame of `frame_size` points holds, for converting
    /// the frame-sized `min_size` and `max_size` into content limits.
    fn contentSizeForFrame(self: *const Self, frame_size: geometry.Size(f64)) geometry.Size(f64) {
        assert(self.ns_window.value != null);
        assert(frame_size.width >= 0);
        assert(frame_size.height >= 0);
        const frame = NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = frame_size.width, .height = frame_size.height },
        };
        const content: NSRect =
            self.ns_window.msgSend(NSRect, "contentRectForFrameRect:", .{frame});
        return geometry.Size(f64).init(
            @max(content.size.width, 0),
            @max(content.size.height, 0),
        );
    }

    /// A core app resizes through its queue: the next built frame carries the
    /// new viewport and the render thread resizes the drawable before drawing
    /// it, so the main thread never touches the renderer.
    fn resizeCore(self: *Self, binding: CoreBinding, size: geometry.Size(f64), scale: f64) void {
        assert(size.width >= 1);
        assert(size.height >= 1);
        assert(scale > 0);
        self.size = size;
        self.scale_factor = scale;
        self.metal_layer.msgSend(void, "setContentsScale:", .{scale});
        binding.queue.push(.{ .window = .{ .resized = .{
            .width = @floatCast(size.width),
            .height = @floatCast(size.height),
            .scale_factor = @floatCast(scale),
        } } });
        binding.schedule_tick(binding.context);
    }

    /// Handle window close. Returns true if close should proceed, false to cancel.
    pub fn handleClose(self: *Self) bool {
        assert(self.ns_window.value != null);
        if (self.on_close) |callback| return callback(self);
        return true;
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

    /// Set the OS-level mouse pointer icon (not the text caret the text
    /// engines draw; see `interface.CursorShape`).
    ///
    /// `NSCursor.set()` pushes onto a stack rather than replacing outright,
    /// but the core host calls this with the fully resolved shape whenever it
    /// changes, so there is never more than one Gooey-owned cursor pushed.
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
            .resize_left_right => NSCursor.msgSend(objc.Object, "resizeLeftRightCursor", .{}),
            .resize_up_down => NSCursor.msgSend(objc.Object, "resizeUpDownCursor", .{}),
        };
        std.debug.assert(cursor.value != null);

        cursor.msgSend(void, "set", .{});
        self.cursor_shape = shape;
    }

    // =========================================================================
    // Calls from the 0.3.1 `context/window.zig`
    // =========================================================================
    //
    // The core never makes these calls. They stay only while that file
    // compiles, and go when phase 6 deletes it.

    pub fn getPlatform(self: *Self) *platform.MacPlatform {
        assert(@intFromPtr(self.plat) != 0);
        return self.plat;
    }

    /// Nothing to request: the core host schedules its own ticks and frames.
    pub fn requestRender(self: *Self) void {
        assert(self.ns_window.value != null);
    }

    pub fn requestRenderAfter(self: *Self, delay_ms: u32) void {
        assert(self.ns_window.value != null);
        assert(delay_ms <= interface_mod.render_delay_ms_max);
    }

    /// Set the window appearance (light or dark mode)
    /// This affects the titlebar text color and other system UI elements
    pub fn setAppearance(self: *Self, dark: bool) void {
        assert(self.ns_window.value != null);
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
        // `metal.Renderer.init` sets `maximumDrawableCount` from the window budget's
        // frames in flight; its rings' in-flight proof depends on that count.

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
};

/// The largest content size, in whole points, whose framebuffer at
/// `scale_factor` fits `ResourceLimits.window`. Flooring keeps the pixel size
/// a window rounds to within the limits.
pub fn contentSizeMax(
    window_limits: *const limits_mod.WindowLimits,
    scale_factor: f64,
) geometry.Size(f64) {
    assert(scale_factor > 0);
    assert(window_limits.framebuffer_width_max > 0);
    assert(window_limits.framebuffer_height_max > 0);
    const width_max: f64 = @floatFromInt(window_limits.framebuffer_width_max);
    const height_max: f64 = @floatFromInt(window_limits.framebuffer_height_max);
    const size = geometry.Size(f64).init(
        @floor(width_max / scale_factor),
        @floor(height_max / scale_factor),
    );
    assert(size.width * scale_factor <= width_max);
    assert(size.height * scale_factor <= height_max);
    return size;
}

/// The framebuffer a logical window needs, within the budget's framebuffer
/// limits. `applySizeLimits` keeps resizes, zoom and display changes within
/// them. Should full screen size a window past its `contentMaxSize`, it draws
/// at the largest scale that fits, which the layer stretches to fill: sharper
/// pixels would need drawables the budget did not provide for (CLAUDE.md §2).
pub fn framebufferViewport(
    logical: struct { width: f64, height: f64, scale_factor: f64 },
    window_limits: *const limits_mod.WindowLimits,
) backend.Viewport {
    assert(logical.scale_factor > 0);
    assert(logical.width >= 0 and logical.height >= 0);
    const width_max: f64 = @floatFromInt(window_limits.framebuffer_width_max);
    const height_max: f64 = @floatFromInt(window_limits.framebuffer_height_max);
    var scale = logical.scale_factor;
    if (logical.width * scale > width_max) scale = width_max / logical.width;
    if (logical.height * scale > height_max) scale = height_max / logical.height;
    var viewport = backend.Viewport.fromLogical(
        @floatCast(logical.width),
        @floatCast(logical.height),
        @floatCast(scale),
    );
    // Rounding to whole pixels can land one past a limit the scale meets exactly.
    viewport.size_px.width = @min(viewport.size_px.width, window_limits.framebuffer_width_max);
    viewport.size_px.height = @min(viewport.size_px.height, window_limits.framebuffer_height_max);
    assert(viewport.scale_factor <= logical.scale_factor);
    return viewport;
}

test "contentSizeMax floors the budget's framebuffer to whole points at each scale" {
    // Goal: the cap is the largest whole-point size whose framebuffer fits. At
    // scale 1.75, 2560 px allows 1462.86 pt: 1463 pt would round to 2561 px.
    const window_limits = limits_mod.WindowLimits{
        .framebuffer_width_max = 2560,
        .framebuffer_height_max = 1600,
    };
    const retina = contentSizeMax(&window_limits, 2);
    try std.testing.expectEqual(@as(f64, 1280), retina.width);
    try std.testing.expectEqual(@as(f64, 800), retina.height);

    const standard = contentSizeMax(&window_limits, 1);
    try std.testing.expectEqual(@as(f64, 2560), standard.width);
    try std.testing.expectEqual(@as(f64, 1600), standard.height);

    const fractional = contentSizeMax(&window_limits, 1.75);
    try std.testing.expectEqual(@as(f64, 1462), fractional.width);
    try std.testing.expectEqual(@as(f64, 914), fractional.height);
    const viewport = framebufferViewport(.{
        .width = fractional.width,
        .height = fractional.height,
        .scale_factor = 1.75,
    }, &window_limits);
    try std.testing.expectEqual(@as(f32, 1.75), viewport.scale_factor);
    try std.testing.expect(viewport.size_px.width <= 2560);
    try std.testing.expect(viewport.size_px.height <= 1600);
}

test "framebufferViewport keeps the scale within the limits and clamps past them" {
    // Goal: a window that fits keeps its backing scale exactly; one a pixel past
    // either limit drops to the largest scale that fits, never past the limit.
    const window_limits = limits_mod.WindowLimits{
        .framebuffer_width_max = 2560,
        .framebuffer_height_max = 1600,
    };
    const fits = framebufferViewport(.{
        .width = 1280,
        .height = 800,
        .scale_factor = 2,
    }, &window_limits);
    try std.testing.expectEqual(@as(f32, 2), fits.scale_factor);
    try std.testing.expectEqual(@as(u32, 2560), fits.size_px.width);
    try std.testing.expectEqual(@as(u32, 1600), fits.size_px.height);

    const wide = framebufferViewport(.{
        .width = 1281,
        .height = 400,
        .scale_factor = 2,
    }, &window_limits);
    try std.testing.expect(wide.scale_factor < 2);
    try std.testing.expectEqual(@as(u32, 2560), wide.size_px.width);
    try std.testing.expectEqual(@as(u32, 799), wide.size_px.height);

    const tall = framebufferViewport(.{
        .width = 100,
        .height = 1601,
        .scale_factor = 1,
    }, &window_limits);
    try std.testing.expect(tall.size_px.height <= 1600);
    try std.testing.expect(tall.scale_factor < 1);
}
