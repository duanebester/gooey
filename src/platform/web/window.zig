//! WebWindow — canvas-backed `PlatformWindow` for WebAssembly/browser.
//!
//! The browser is the window manager: there is exactly one canvas, it cannot be
//! closed from script, and frames arrive via `requestAnimationFrame`. Every
//! method below therefore either forwards to a JS import or records state that
//! Gooey itself can observe. What it must *not* do is accept a caller's intent
//! and throw it away — the previous revision of this file had thirteen empty
//! bodies and five `anytype` setters, which let the shared boundary drift until
//! `getScaleFactor` returned `f32` here and `f64` everywhere else.

const std = @import("std");
const imports = @import("imports.zig");
const geometry = @import("../../core/geometry.zig");
const scene_mod = @import("../../scene/mod.zig");
const text_mod = @import("../../text/mod.zig");
const input = @import("../../input/mod.zig");
const composition_buffer = @import("composition_buffer.zig");
const interface = @import("../interface.zig");
const platform_mod = @import("platform.zig");

const WindowId = interface.WindowId;
const WebPlatform = platform_mod.WebPlatform;

pub const WebWindow = struct {
    allocator: std.mem.Allocator,

    /// Owning platform. Retained so `deinit` can unregister without the caller
    /// having to remember which registry issued `window_id`.
    platform: *WebPlatform,

    /// Logical canvas size in CSS pixels, refreshed by `updateSize`.
    size: geometry.Size(f64),

    /// `devicePixelRatio`. Widened to `f64` to match the contract; the JS
    /// import still hands back `f32`, so the cast happens at that boundary
    /// only (see `updateSize`).
    scale_factor: f64,

    background_color: geometry.Color,
    background_opacity: f64,
    glass_style: interface.GlassStyle,
    glass_corner_radius: f64,

    /// Requested cursor. There is no JS import that applies it yet, so it is
    /// recorded rather than dropped; see `setCursorShape`.
    cursor_shape: interface.CursorShape,

    /// Whether the app asked for a dark appearance. Web has no host-level
    /// appearance switch to push this into; see `setAppearance`.
    dark_appearance: bool,

    /// Byte length of the preedit the framework last handed us. The bytes have
    /// no host destination on web (the browser's hidden input owns the IME
    /// buffer), but the length is exactly what `hasMarkedText` must report.
    marked_text_len: u32,

    closed: bool,

    /// Host callbacks. The web frame loop in `app.zig` currently drains the JS
    /// ring buffers and calls `runtime.handleInputCx` directly, so nothing
    /// invokes these today and storing them changes no behavior. They are
    /// stored anyway because discarding them was a silent lie about a caller's
    /// intent, and because a unified event path can then reuse the same wiring
    /// as the native backends without changing any call site.
    on_input: ?InputCallback = null,
    on_render: ?RenderCallback = null,
    on_close: ?CloseCallback = null,
    on_resize: ?ResizeCallback = null,
    on_post_input: ?PostInputCallback = null,

    user_data: ?*anyopaque = null,

    /// Unique identifier for this window in the platform's `WindowRegistry`.
    window_id: WindowId = .invalid,

    const Self = @This();

    // =========================================================================
    // Callback types
    // =========================================================================

    pub const InputCallback = *const fn (*Self, input.InputEvent) bool;
    pub const RenderCallback = *const fn (*Self) void;
    pub const CloseCallback = *const fn (*Self) bool;
    pub const ResizeCallback = *const fn (*Self, f64, f64) void;
    pub const PostInputCallback = *const fn (*Self) void;

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// Create the window and register it with `plat`.
    ///
    /// `options` crosses by const pointer: the struct is far over the 16-byte
    /// by-value threshold and WASM has a 1 MiB stack to protect.
    pub fn init(
        allocator: std.mem.Allocator,
        plat: *WebPlatform,
        options: *const interface.WindowOptions,
    ) !*Self {
        std.debug.assert(options.width > 0);
        std.debug.assert(options.height > 0);
        std.debug.assert(options.background_opacity >= 0.0);
        std.debug.assert(options.background_opacity <= 1.0);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.platform = plat;
        self.size = .{ .width = options.width, .height = options.height };
        self.scale_factor = 1.0;
        self.background_color = options.background_color;
        self.background_opacity = options.background_opacity;
        self.glass_style = options.glass_style;
        self.glass_corner_radius = options.glass_corner_radius;
        self.cursor_shape = .default;
        self.dark_appearance = false;
        self.marked_text_len = 0;
        self.closed = false;
        self.on_input = null;
        self.on_render = null;
        self.on_close = null;
        self.on_resize = null;
        self.on_post_input = null;
        self.user_data = null;
        self.window_id = .invalid;

        // The canvas already exists when WASM starts, so adopt its real size
        // immediately rather than rendering one frame at the requested size.
        self.updateSize();
        self.setTitle(options.title);

        // Registration last: it publishes `self` to the registry, so every
        // field must already hold its final value.
        self.window_id = try plat.registerWindow(self);

        // The single canvas is always the focused surface, but publish it
        // explicitly anyway: every backend states this policy in one visible
        // line rather than inheriting an implicit "first window wins" from
        // `WindowRegistry`, which is what previously made the backends
        // disagree about which window `getActiveWindowId` named.
        plat.setActiveWindowId(self.window_id);

        std.debug.assert(self.window_id.isValid());
        std.debug.assert(!self.closed);
        std.debug.assert(plat.getActiveWindowId().? == self.window_id);
        return self;
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(self.window_id.isValid());

        self.platform.unregisterWindow(self.window_id);
        self.window_id = .invalid;

        std.debug.assert(!self.window_id.isValid());
        self.allocator.destroy(self);
    }

    // =========================================================================
    // Identity
    // =========================================================================

    /// The platform that owns this window.
    ///
    /// Contract-pinned so shared code can reach the host without spelling a
    /// per-backend field name; see `contract.verifyWindowLifecycle`.
    pub fn getPlatform(self: *Self) *WebPlatform {
        std.debug.assert(@intFromPtr(self.platform) != 0);
        return self.platform;
    }

    pub fn getWindowId(self: *const Self) WindowId {
        std.debug.assert(!self.closed or self.window_id.isValid());
        return self.window_id;
    }

    // =========================================================================
    // Geometry
    // =========================================================================

    /// Re-read canvas size and DPI from the host.
    ///
    /// Web-only: the native backends learn about resizes through host events,
    /// while the browser expects a poll each frame.
    pub fn updateSize(self: *Self) void {
        const canvas_width = imports.getCanvasWidth();
        const canvas_height = imports.getCanvasHeight();
        std.debug.assert(canvas_width <= size_px_max);
        std.debug.assert(canvas_height <= size_px_max);

        self.size.width = @floatFromInt(canvas_width);
        self.size.height = @floatFromInt(canvas_height);

        // Sole `f32` → `f64` widening point for the DPI. `devicePixelRatio` is
        // reported as `f32` by the import; the rest of Gooey speaks `f64`.
        const ratio: f64 = @floatCast(imports.getDevicePixelRatio());
        self.scale_factor = if (ratio > 0.0) ratio else 1.0;

        std.debug.assert(self.scale_factor > 0.0);
    }

    pub fn width(self: *const Self) u32 {
        std.debug.assert(self.size.width >= 0.0);
        std.debug.assert(self.size.width <= @as(f64, size_px_max));
        return @intFromFloat(self.size.width);
    }

    pub fn height(self: *const Self) u32 {
        std.debug.assert(self.size.height >= 0.0);
        std.debug.assert(self.size.height <= @as(f64, size_px_max));
        return @intFromFloat(self.size.height);
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        std.debug.assert(self.size.width >= 0.0);
        std.debug.assert(self.size.height >= 0.0);
        return self.size;
    }

    pub fn getScaleFactor(self: *const Self) f64 {
        std.debug.assert(self.scale_factor > 0.0);
        std.debug.assert(self.scale_factor <= scale_factor_max);
        return self.scale_factor;
    }

    // =========================================================================
    // Window properties
    // =========================================================================

    pub fn setTitle(self: *Self, title: []const u8) void {
        std.debug.assert(title.len <= title_bytes_max);
        std.debug.assert(!self.closed);

        imports.setDocumentTitle(title.ptr, @intCast(title.len));
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        std.debug.assert(color.a >= 0.0);
        std.debug.assert(color.a <= 1.0);

        self.background_color = color;
    }

    /// Record the requested appearance.
    ///
    /// Truthfulness note: there is no host-side knob here. The browser derives
    /// `prefers-color-scheme` from the OS, and Gooey paints its own chrome, so
    /// the flag is stored for the renderer to consult rather than forwarded.
    pub fn setAppearance(self: *Self, dark: bool) void {
        std.debug.assert(!self.closed);

        self.dark_appearance = dark;

        std.debug.assert(self.dark_appearance == dark);
    }

    /// Record the requested cursor.
    ///
    /// `capabilities.custom_cursors` is `false` on this backend: CSS can
    /// express all three shapes, but `imports.zig` has no `setCanvasCursor`
    /// binding, so the JS host cannot consume the request. The capability flag
    /// is the contract's way of saying an operation is unsupported, so it must
    /// stay `false` until that import lands. The shape is still stored rather
    /// than dropped, so wiring the import is the only remaining step.
    pub fn setCursorShape(self: *Self, shape: interface.CursorShape) void {
        std.debug.assert(!self.closed);

        self.cursor_shape = shape;

        std.debug.assert(self.cursor_shape == shape);
    }

    /// Record a glass/blur request.
    ///
    /// Web-only extra, retyped onto the canonical `interface.GlassStyle`. The
    /// backend used to declare its own enum with a different tag order, which
    /// is what made the runtime's `@enumFromInt` bridge unsound. Web *can*
    /// express `blur` and `vibrancy` through `backdrop-filter`, so this is
    /// stored (and reflected by `getClearColor`) rather than discarded, but
    /// `capabilities.glass_effects` stays `false` until the CSS is applied.
    pub fn setGlassStyle(
        self: *Self,
        style: interface.GlassStyle,
        opacity: f64,
        corner_radius: f64,
    ) void {
        std.debug.assert(opacity >= 0.0);
        std.debug.assert(opacity <= 1.0);
        std.debug.assert(corner_radius >= 0.0);

        self.glass_style = style;
        self.background_opacity = opacity;
        self.glass_corner_radius = corner_radius;
    }

    /// Effective framebuffer clear color.
    ///
    /// Derived rather than cached so it cannot disagree with `glass_style`
    /// after a later `setBackgroundColor` or `setGlassStyle`.
    pub fn getClearColor(self: *const Self) geometry.Color {
        if (self.glass_style.needsTransparentClear()) {
            std.debug.assert(self.glass_style != .none);
            return geometry.Color.transparent;
        }

        std.debug.assert(self.glass_style == .none);
        return self.background_color;
    }

    // =========================================================================
    // Pointer state
    // =========================================================================

    pub fn getMousePosition(self: *const Self) geometry.Point(f64) {
        std.debug.assert(self.size.width >= 0.0);

        const position: geometry.Point(f64) = .{
            .x = @floatCast(imports.getMouseX()),
            .y = @floatCast(imports.getMouseY()),
        };

        std.debug.assert(!std.math.isNan(position.x));
        return position;
    }

    /// Web-only raw accessors, kept because the JS event bridge reports CSS
    /// pixels as `f32` and several call sites want them unwidened.
    pub fn getMouseX(self: *const Self) f32 {
        std.debug.assert(!self.closed);
        return imports.getMouseX();
    }

    pub fn getMouseY(self: *const Self) f32 {
        std.debug.assert(!self.closed);
        return imports.getMouseY();
    }

    pub fn isMouseInside(self: *const Self) bool {
        std.debug.assert(self.size.width >= 0.0);
        std.debug.assert(self.size.height >= 0.0);
        return imports.isMouseInCanvas();
    }

    // =========================================================================
    // Host control
    // =========================================================================

    /// Ask the host for another frame.
    ///
    /// Safe to call repeatedly: the browser coalesces duplicate
    /// `requestAnimationFrame` calls within a frame.
    pub fn requestRender(self: *Self) void {
        std.debug.assert(self.window_id.isValid());

        if (self.closed) return;
        imports.requestAnimationFrame();
    }

    /// Truthfulness note: there is exactly one canvas and the browser gives it
    /// focus whenever the tab is active, so there is nothing to raise. Kept as
    /// a no-op because the contract requires the method, not because a host
    /// call was forgotten.
    pub fn focus(self: *Self) void {
        std.debug.assert(self.window_id.isValid());
        std.debug.assert(!self.closed);
    }

    /// Mark the window closed.
    ///
    /// Truthfulness note: a page cannot close its own tab unless it opened it,
    /// which is why `capabilities.can_close_window` is `false`. The host
    /// therefore cannot honour this. What it *can* honour is stopping work, so
    /// the flag is set and `isClosed` reports it — previously this method did
    /// nothing at all and `isClosed` did not exist, so a caller shutting the
    /// window down had no way to observe that its request was ignored.
    pub fn close(self: *Self) void {
        std.debug.assert(self.window_id.isValid());

        self.closed = true;

        std.debug.assert(self.isClosed());
    }

    pub fn isClosed(self: *const Self) bool {
        std.debug.assert(self.closed or self.window_id.isValid());
        return self.closed;
    }

    // =========================================================================
    // Frame handoff
    // =========================================================================
    //
    // On web the render path is owned by `WebApp` in `app.zig`, which holds the
    // scene and the three atlases and drives `WebRenderer` directly. These
    // setters deliberately do not retain the pointers: caching a `*const`
    // alias that nothing reads would add a dangling-pointer hazard without a
    // consumer. They exist because the contract is shared with the native
    // backends, where the platform window genuinely owns the handoff.

    pub fn setScene(self: *Self, scene: *const scene_mod.Scene) void {
        std.debug.assert(!self.closed);
        _ = scene;
    }

    pub fn setTextAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        std.debug.assert(!self.closed);
        _ = atlas;
    }

    pub fn setSvgAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        std.debug.assert(!self.closed);
        _ = atlas;
    }

    pub fn setImageAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        std.debug.assert(!self.closed);
        _ = atlas;
    }

    // =========================================================================
    // IME bridge
    // =========================================================================

    /// Record the preedit length the framework is displaying.
    ///
    /// Truthfulness note: the bytes cannot be pushed anywhere. The browser's
    /// hidden input element owns the composition buffer and Gooey paints the
    /// preedit itself from `composition_buffer`. The length, however, is real
    /// state that `hasMarkedText` must answer from.
    pub fn setMarkedText(self: *Self, text: []const u8) void {
        std.debug.assert(text.len <= composition_buffer.BUFFER_SIZE);
        std.debug.assert(!self.closed);

        self.marked_text_len = @intCast(text.len);
    }

    pub fn clearMarkedText(self: *Self) void {
        std.debug.assert(!self.closed);

        self.marked_text_len = 0;

        std.debug.assert(self.marked_text_len == 0);
    }

    /// Truthfulness note: committed text reaches Gooey through the JS text
    /// ring buffer (`text_buffer.zig`), not through this call, so there is no
    /// host sink for it. Kept for contract parity with the native backends.
    pub fn setInsertedText(self: *Self, text: []const u8) void {
        std.debug.assert(text.len <= composition_buffer.BUFFER_SIZE);
        std.debug.assert(!self.closed);
    }

    /// Whether a composition is in flight.
    ///
    /// Answers from the browser's own composition state where available — that
    /// is the authority on web — and falls back to the framework-reported
    /// preedit length in the window between `setMarkedText` and the next
    /// `compositionupdate`.
    pub fn hasMarkedText(self: *const Self) bool {
        const buffer = @as(
            *const volatile composition_buffer.CompositionBuffer,
            &composition_buffer.g_composition_buffer,
        );
        if (buffer.isActive()) {
            std.debug.assert(buffer.len <= composition_buffer.BUFFER_SIZE);
            return true;
        }

        std.debug.assert(self.marked_text_len <= composition_buffer.BUFFER_SIZE);
        return self.marked_text_len > 0;
    }

    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        std.debug.assert(w >= 0.0);
        std.debug.assert(h >= 0.0);
        std.debug.assert(!self.closed);

        imports.setImeCursorPosition(x, y, w, h);
    }

    // =========================================================================
    // Callbacks
    // =========================================================================

    pub fn setInputCallback(self: *Self, callback: ?InputCallback) void {
        std.debug.assert(!self.closed);

        self.on_input = callback;

        std.debug.assert(self.on_input == callback);
    }

    pub fn setRenderCallback(self: *Self, callback: ?RenderCallback) void {
        std.debug.assert(!self.closed);

        self.on_render = callback;

        std.debug.assert(self.on_render == callback);
    }

    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        std.debug.assert(!self.closed);

        self.on_close = callback;

        std.debug.assert(self.on_close == callback);
    }

    pub fn setResizeCallback(self: *Self, callback: ?ResizeCallback) void {
        std.debug.assert(!self.closed);

        self.on_resize = callback;

        std.debug.assert(self.on_resize == callback);
    }

    pub fn setPostInputCallback(self: *Self, callback: ?PostInputCallback) void {
        std.debug.assert(!self.closed);

        self.on_post_input = callback;

        std.debug.assert(self.on_post_input == callback);
    }

    // =========================================================================
    // User data
    // =========================================================================

    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        std.debug.assert(self.window_id.isValid() or !self.closed);

        self.user_data = data;

        std.debug.assert(self.user_data == data);
    }

    /// Recover the caller's context pointer.
    ///
    /// This is how all five static callbacks reach their owner, which is why
    /// returning `null` unconditionally (the previous behavior) would silently
    /// disable every one of them the moment the shared event path lands.
    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        comptime std.debug.assert(@sizeOf(T) > 0);
        comptime std.debug.assert(@alignOf(T) > 0);

        const data = self.user_data orelse return null;
        std.debug.assert(std.mem.isAligned(@intFromPtr(data), @alignOf(T)));
        return @ptrCast(@alignCast(data));
    }

    // =========================================================================
    // Limits
    // =========================================================================

    /// Largest canvas edge we accept, in CSS pixels. Browsers cap backing
    /// stores well below this; the bound exists so a bogus host value trips an
    /// assertion instead of producing a nonsense `@intFromFloat`.
    const size_px_max: u32 = 32_768;

    /// `devicePixelRatio` above this means the host is misreporting; 4 covers
    /// every shipping display density with headroom.
    const scale_factor_max: f64 = 8.0;

    /// Document titles are host-visible strings, not unbounded data.
    const title_bytes_max: usize = 1024;
};
