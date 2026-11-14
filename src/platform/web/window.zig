//! WebWindow — canvas-backed `PlatformWindow` for WebAssembly/browser.
//!
//! The browser is the window manager: there is exactly one canvas, it cannot be
//! closed from script, and frames arrive via `requestAnimationFrame`. The core
//! host (`core_host.zig`) creates the window, polls its size every frame, and
//! forwards the cursor and the IME caret through it.

const std = @import("std");
const imports = @import("imports.zig");
const geometry = @import("../../geometry/geometry.zig");
const interface = @import("../interface.zig");
const platform_mod = @import("platform.zig");

const WindowId = interface.WindowId;
const WebPlatform = platform_mod.WebPlatform;

pub const WebWindow = struct {
    /// Owning platform, which registered `window_id`.
    platform: *WebPlatform,

    /// Logical canvas size in CSS pixels, refreshed by `updateSize`.
    size: geometry.Size(f64),

    /// `devicePixelRatio`, in the host's own width: a JS `Number` is an
    /// IEEE-754 double, and the contract speaks `f64`, so no conversion
    /// happens anywhere along this path.
    scale_factor: f64,

    /// The cursor last sent to the canvas, so only a change crosses into JS.
    cursor_shape: interface.CursorShape,

    /// Whether the app asked for a dark appearance. Web has no host-level
    /// appearance switch to push this into; see `setAppearance`.
    dark_appearance: bool,

    /// Unique identifier for this window in the platform's `WindowRegistry`.
    window_id: WindowId = .invalid,

    const Self = @This();

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
        std.debug.assert(options.title.len <= title_bytes_max);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.platform = plat;
        self.size = .{ .width = options.width, .height = options.height };
        self.scale_factor = 1.0;
        self.cursor_shape = .default;
        self.dark_appearance = false;
        self.window_id = .invalid;

        // The canvas already exists when WASM starts, so adopt its real size
        // immediately rather than rendering one frame at the requested size.
        self.updateSize();
        imports.setDocumentTitle(options.title.ptr, @intCast(options.title.len));

        // Registration last: it publishes `self` to the registry, so every
        // field must already hold its final value.
        self.window_id = try plat.registerWindow(self);

        // The single canvas is always the focused surface, but publish it
        // explicitly anyway: every backend states this policy in one visible
        // line rather than inheriting an implicit "first window wins" from
        // `WindowRegistry`, so the backends agree about which window
        // `getActiveWindowId` names.
        plat.setActiveWindowId(self.window_id);

        std.debug.assert(self.window_id.isValid());
        std.debug.assert(plat.getActiveWindowId().? == self.window_id);
        return self;
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

        // A host that reports zero or a negative ratio is misreporting; fall
        // back to 1.0 rather than propagating a scale that would divide to
        // infinity downstream.
        const ratio: f64 = imports.getDevicePixelRatio();
        self.scale_factor = if (ratio > 0.0) ratio else 1.0;

        std.debug.assert(self.scale_factor > 0.0);
    }

    /// Set the canvas's CSS cursor. Only a change crosses into JS, so a
    /// caller that sets the same shape every frame restyles nothing.
    pub fn setCursorShape(self: *Self, shape: interface.CursorShape) void {
        std.debug.assert(self.window_id.isValid());
        std.debug.assert(@backingInt(shape) <= @backingInt(interface.CursorShape.resize_up_down));
        if (self.cursor_shape == shape) return;

        imports.setCanvasCursor(@backingInt(shape));
        self.cursor_shape = shape;

        std.debug.assert(self.cursor_shape == shape);
    }

    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        std.debug.assert(w >= 0.0);
        std.debug.assert(h >= 0.0);
        std.debug.assert(self.window_id.isValid());

        imports.setImeCursorPosition(x, y, w, h);
    }

    // =========================================================================
    // Calls from the 0.3.1 `context/window.zig`
    // =========================================================================
    //
    // The core never makes these calls. They stay only while that file
    // compiles, and go when phase 6 deletes it.

    pub fn getPlatform(self: *Self) *WebPlatform {
        std.debug.assert(@intFromPtr(self.platform) != 0);
        return self.platform;
    }

    /// Stored only: the browser derives `prefers-color-scheme` from the OS.
    pub fn setAppearance(self: *Self, dark: bool) void {
        std.debug.assert(self.window_id.isValid());
        self.dark_appearance = dark;
        std.debug.assert(self.dark_appearance == dark);
    }

    /// The browser coalesces duplicate `requestAnimationFrame` calls.
    pub fn requestRender(self: *Self) void {
        std.debug.assert(self.window_id.isValid());
        imports.requestAnimationFrame();
    }

    /// Nothing to arm: the core host re-arms `requestAnimationFrame` after
    /// every frame while the platform runs.
    pub fn requestRenderAfter(self: *Self, delay_ms: u32) void {
        std.debug.assert(self.window_id.isValid());
        std.debug.assert(delay_ms <= interface.render_delay_ms_max);
    }

    // =========================================================================
    // Limits
    // =========================================================================

    /// Largest canvas edge we accept, in CSS pixels. Browsers cap backing
    /// stores well below this; the bound exists so a bogus host value trips an
    /// assertion instead of producing a nonsense `@intFromFloat`.
    const size_px_max: u32 = 32_768;

    /// Document titles are host-visible strings, not unbounded data.
    const title_bytes_max: usize = 1024;
};
