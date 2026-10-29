//! WindowsWindow - one Win32 top-level window rendered with Vulkan.
//!
//! The window procedure (`windowProc`) is the only entry point Windows calls.
//! It routes every input message through `input.Translator.translate` and
//! delivers the result through `handleInput`, so phase 4's event queue
//! replaces one call (`docs/windows-port.md`, seam 1). Drawing goes through
//! the shared Vulkan renderer's `render(scene)`, the one entry phase 5 swaps
//! for a `PackedFrame` (seam 2).
//!
//! ## Sizes
//!
//! The process is per-monitor DPI aware (v2), so Windows reports the client
//! area in device pixels. `size` is that area in logical pixels, divided by
//! `scale_factor` (the monitor's DPI over 96). The swapchain is sized in device
//! pixels and fitted to `ResourceLimits.window` by the renderer.
//!
//! ## Memory (CLAUDE.md §2)
//!
//! `init` allocates the window and its renderer storage, sized from the app's
//! `ResourceLimits`, before the event loop starts. Title, IME text, and the
//! translated event's text live in fixed inline buffers; nothing is allocated
//! afterwards.

const std = @import("std");
const interface_mod = @import("../interface.zig");
const geometry = @import("../../geometry/geometry.zig");
const scene_mod = @import("../../scene/mod.zig");
const text_mod = @import("../../text/mod.zig");
const input = @import("../../input/events.zig");
const VulkanRenderer = @import("../linux/vk_renderer.zig").VulkanRenderer;
const win32 = @import("win32.zig");
const windows_input = @import("input.zig");
const windows_platform = @import("platform.zig");
const WindowsPlatform = windows_platform.WindowsPlatform;

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const WindowId = interface_mod.WindowId;
const WindowOptions = interface_mod.WindowOptions;

/// Window style for every Gooey window: a standard resizable frame.
const window_style: u32 = win32.WS_OVERLAPPEDWINDOW;
const window_style_extended: u32 = win32.WS_EX_APPWINDOW;

pub const Window = struct {
    allocator: Allocator,
    platform: *WindowsPlatform,
    window_id: WindowId = .invalid,
    hwnd: ?win32.HWND = null,

    /// Logical size; contract-pinned field read directly by shared code.
    size: geometry.Size(f64),
    /// Device pixels per logical pixel; contract-pinned field.
    scale_factor: f64,
    /// The client area in device pixels, as `WM_SIZE` last reported it.
    client_width_px: u32 = 0,
    client_height_px: u32 = 0,
    /// The size and scale the swapchain was last built for, so a `WM_SIZE`
    /// that changes neither does not rebuild it.
    swapchain_width_px: u32 = 0,
    swapchain_height_px: u32 = 0,
    swapchain_scale_factor: f64 = 0,
    minimized: bool = false,
    min_size: ?geometry.Size(f64),
    max_size: ?geometry.Size(f64),

    renderer: VulkanRenderer,
    background_color: geometry.Color,
    glass_style: interface_mod.GlassStyle,
    dark_appearance: bool = false,
    cursor_shape: interface_mod.CursorShape = .default,

    needs_redraw: bool = true,
    closed: bool = false,
    /// Set while `renderFrame` runs. A window procedure re-entered from the
    /// render callback (a modal dialog, a `SetWindowPos`) must not start a
    /// second frame on the same swapchain.
    rendering: bool = false,
    /// Earliest time, on `platform.nowMilliseconds`, at which the loop must
    /// request a frame. Frame-scoped, as on the other backends: cleared before
    /// application code builds a frame, which re-arms what it still needs.
    render_deadline_ms: ?i64 = null,
    /// When this window last presented, on `platform.nowNanoseconds`.
    last_frame_ns: ?u64 = null,

    scene: ?*const scene_mod.Scene = null,
    text_atlas: ?*const text_mod.Atlas = null,
    svg_atlas: ?*const text_mod.Atlas = null,
    image_atlas: ?*const text_mod.Atlas = null,

    /// `SetWindowTextW` takes a NUL-terminated UTF-16 string. UTF-8 never
    /// needs more UTF-16 units than bytes, so the payload fits.
    title_buffer: [title_bytes_max + 1]u16 = undefined,

    mouse_x: f64 = 0,
    mouse_y: f64 = 0,
    mouse_inside: bool = false,
    translator: windows_input.Translator,

    // IME state. Composition through `WM_IME_*` is a later item of the port;
    // the contract's bridge still stores what callers hand it.
    marked_text_buffer: [ime_bytes_max]u8 = undefined,
    marked_text_len: usize = 0,
    inserted_text_buffer: [ime_bytes_max]u8 = undefined,
    inserted_text_len: usize = 0,
    ime_cursor_rect: geometry.RectF = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 1, .height = 20 },
    },

    on_input: ?InputCallback = null,
    on_render: ?RenderCallback = null,
    on_close: ?CloseCallback = null,
    on_resize: ?ResizeCallback = null,
    on_post_input: ?PostInputCallback = null,
    user_data: ?*anyopaque = null,

    pub const InputCallback = *const fn (*Self, input.InputEvent) bool;
    pub const RenderCallback = *const fn (*Self) void;
    pub const CloseCallback = *const fn (*Self) bool;
    pub const ResizeCallback = *const fn (*Self, f64, f64) void;
    pub const PostInputCallback = *const fn (*Self) void;

    pub const title_bytes_max: usize = 255;
    pub const ime_bytes_max: usize = 256;

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        plat: *WindowsPlatform,
        options: *const WindowOptions,
    ) !*Self {
        assert(options.width > 0);
        assert(options.height > 0);
        assert(options.title.len <= title_bytes_max);
        assert(options.limits.check() == null);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const system_scale = scaleFromDpi(win32.GetDpiForSystem());
        self.* = .{
            .allocator = allocator,
            .platform = plat,
            .size = .{ .width = options.width, .height = options.height },
            .scale_factor = system_scale,
            .min_size = options.min_size,
            .max_size = options.max_size,
            .renderer = VulkanRenderer.init(allocator),
            .background_color = options.background_color,
            .glass_style = options.glass_style,
            .translator = windows_input.Translator.init(plat.click_settings),
        };
        self.storeTitle(options.title);

        self.window_id = try plat.registerWindow(self);
        errdefer {
            plat.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }

        try self.createNativeWindow(options);
        errdefer self.destroyNativeWindow();

        self.adoptWindowDpi(options);
        self.readClientSize();
        try self.renderer.initWithNativeSurface(
            .{ .hinstance = plat.hinstance, .hwnd = self.hwnd.? },
            self.rendererWidth(),
            self.rendererHeight(),
            self.scale_factor,
            &options.limits,
        );
        self.recordSwapchainSize();

        // Shown only once the renderer exists, so the first `WM_SIZE` and
        // `WM_PAINT` find a surface to draw on.
        _ = win32.ShowWindow(self.hwnd.?, win32.SW_SHOW);
        _ = win32.SetForegroundWindow(self.hwnd.?);
        plat.setActiveWindowId(self.window_id);

        assert(self.window_id.isValid());
        assert(self.renderer.initialized);
        return self;
    }

    /// Create the `HWND` with an outer size that gives the requested logical
    /// client size at the system DPI. `adoptWindowDpi` corrects it when the
    /// window opens on a monitor with a different DPI.
    fn createNativeWindow(self: *Self, options: *const WindowOptions) !void {
        assert(self.hwnd == null);
        assert(self.scale_factor > 0);
        const outer = outerSize(options.width, options.height, dpiFromScale(self.scale_factor));
        const origin = if (options.centered) centeredOrigin(outer) else win32.POINT{
            .x = win32.CW_USEDEFAULT,
            .y = win32.CW_USEDEFAULT,
        };

        // `WM_NCCREATE` binds the new `HWND` to `self` (see `windowProc`).
        const hwnd = win32.CreateWindowExW(
            window_style_extended,
            windows_platform.class_name,
            @ptrCast(&self.title_buffer),
            window_style,
            origin.x,
            origin.y,
            outer.x,
            outer.y,
            null,
            null,
            self.platform.hinstance,
            self,
        ) orelse {
            std.log.err("windows: CreateWindowExW failed (error {d})", .{win32.GetLastError()});
            return error.WindowCreationFailed;
        };
        assert(self.hwnd == hwnd);
    }

    /// Unbind and destroy the `HWND`. Unbinding first means the messages
    /// `DestroyWindow` sends reach `DefWindowProcW` rather than a window that
    /// is being torn down.
    fn destroyNativeWindow(self: *Self) void {
        const hwnd = self.hwnd orelse return;
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
        if (win32.DestroyWindow(hwnd) == win32.FALSE) {
            std.log.warn("windows: DestroyWindow failed (error {d})", .{win32.GetLastError()});
        }
        self.hwnd = null;
    }

    /// Resize the new window for its monitor's DPI when that differs from the
    /// system DPI it was sized for, keeping the requested logical size.
    fn adoptWindowDpi(self: *Self, options: *const WindowOptions) void {
        const hwnd = self.hwnd.?;
        const scale = scaleFromDpi(win32.GetDpiForWindow(hwnd));
        if (scale == self.scale_factor) return;
        self.scale_factor = scale;
        const outer = outerSize(options.width, options.height, dpiFromScale(scale));
        const flags = win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_NOMOVE;
        _ = win32.SetWindowPos(hwnd, null, 0, 0, outer.x, outer.y, flags);
        assert(self.scale_factor == scale);
    }

    pub fn deinit(self: *Self) void {
        assert(@intFromPtr(self) != 0);
        assert(!self.rendering);
        if (self.window_id.isValid()) {
            self.platform.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }
        // The renderer's surface borrows the `HWND`, so it goes first.
        self.renderer.deinit();
        self.destroyNativeWindow();
        assert(self.hwnd == null);
        self.allocator.destroy(self);
    }

    // =========================================================================
    // Frames
    // =========================================================================

    /// Whether the loop should render this window now: it asked for a frame,
    /// can show one, and its previous frame is at least one period old.
    pub fn isFrameDue(self: *const Self, now_ns: u64) bool {
        if (self.closed or self.minimized or self.rendering) return false;
        if (!self.needs_redraw and !self.renderer.hasPendingAtlasUploads()) return false;
        const last_ns = self.last_frame_ns orelse return true;
        return now_ns -| last_ns >= windows_platform.frame_period_ns_min;
    }

    /// How long the loop may wait before this window needs attention.
    pub fn waitTimeoutMs(self: *const Self, now_ns: u64, now_ms: i64, timeout_ms_max: u32) u32 {
        assert(!self.closed);
        assert(now_ms >= 0);
        if (self.minimized) return timeout_ms_max;
        if (self.needs_redraw) {
            const last_ns = self.last_frame_ns orelse return 0;
            const elapsed_ns = now_ns -| last_ns;
            if (elapsed_ns >= windows_platform.frame_period_ns_min) return 0;
            const remaining_ns = windows_platform.frame_period_ns_min - elapsed_ns;
            const remaining_ms = std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch
                unreachable; // The divisor is a nonzero constant.
            return @intCast(@min(remaining_ms, timeout_ms_max));
        }
        const deadline_ms = self.render_deadline_ms orelse return timeout_ms_max;
        if (deadline_ms <= now_ms) return 0;
        return @intCast(@min(deadline_ms - now_ms, timeout_ms_max));
    }

    /// Build and present one frame.
    pub fn renderFrame(self: *Self) void {
        if (self.closed or self.minimized or self.rendering) return;
        assert(self.renderer.initialized);
        self.rendering = true;
        defer self.rendering = false;

        // Cleared before application code runs, so a render requested while
        // building this frame (an animation step) schedules the next one.
        self.needs_redraw = false;
        self.render_deadline_ms = null;
        if (self.on_render) |callback| callback(self);
        if (self.closed) return;

        // Republished every frame: `setBackgroundColor` may have run since.
        self.renderer.setClearColor(self.getClearColor());
        if (self.text_atlas) |atlas| {
            self.renderer.bindAtlasUploads(atlas.uploads, @intFromPtr(self));
        }
        if (self.scene) |scene| {
            self.renderer.render(scene);
        } else {
            // Zero capacity: presenting a clear needs no primitive storage.
            var empty_scene = scene_mod.Scene.initEmpty(self.allocator);
            defer empty_scene.deinit();
            self.renderer.render(&empty_scene);
        }
        self.last_frame_ns = windows_platform.nowNanoseconds();
        assert(self.rendering);
    }

    /// Adopt the client size `WM_SIZE` reported and rebuild the swapchain
    /// when the device-pixel size or the scale changed.
    fn applyClientSize(self: *Self, width_px: u32, height_px: u32) void {
        assert(self.scale_factor > 0);
        self.client_width_px = width_px;
        self.client_height_px = height_px;
        if (width_px == 0 or height_px == 0) return;

        const old_size = self.size;
        self.size = .{
            .width = @as(f64, @floatFromInt(width_px)) / self.scale_factor,
            .height = @as(f64, @floatFromInt(height_px)) / self.scale_factor,
        };
        const unchanged = width_px == self.swapchain_width_px and
            height_px == self.swapchain_height_px and
            self.scale_factor == self.swapchain_scale_factor;
        if (unchanged or !self.renderer.initialized) return;

        self.renderer.resize(self.rendererWidth(), self.rendererHeight(), self.scale_factor);
        self.recordSwapchainSize();
        self.requestRender();
        if (old_size.width != self.size.width or old_size.height != self.size.height) {
            if (self.on_resize) |callback| callback(self, self.size.width, self.size.height);
        }
    }

    fn readClientSize(self: *Self) void {
        var rect: win32.RECT = undefined;
        if (win32.GetClientRect(self.hwnd.?, &rect) == win32.FALSE) {
            std.log.warn("windows: GetClientRect failed (error {d})", .{win32.GetLastError()});
            return;
        }
        assert(rect.right >= rect.left);
        assert(rect.bottom >= rect.top);
        self.applyClientSize(@intCast(rect.right - rect.left), @intCast(rect.bottom - rect.top));
    }

    fn recordSwapchainSize(self: *Self) void {
        self.swapchain_width_px = self.client_width_px;
        self.swapchain_height_px = self.client_height_px;
        self.swapchain_scale_factor = self.scale_factor;
    }

    /// The renderer takes whole logical pixels and multiplies by the scale.
    /// Rounding up makes the product cover the client area; the swapchain
    /// clamps it to the surface's exact extent.
    fn rendererWidth(self: *const Self) u32 {
        assert(self.size.width > 0);
        return @intFromFloat(@ceil(self.size.width));
    }

    fn rendererHeight(self: *const Self) u32 {
        assert(self.size.height > 0);
        return @intFromFloat(@ceil(self.size.height));
    }

    // =========================================================================
    // Input
    // =========================================================================

    /// Translate one input message and deliver the event it produces.
    fn translateAndDeliver(self: *Self, message: windows_input.Message) void {
        assert(self.hwnd != null);
        const context = windows_input.Context{
            .scale_factor = self.scale_factor,
            .modifiers = currentModifiers(),
            .time_ms = @bitCast(win32.GetMessageTime()),
            .pointer = .{ .x = self.mouse_x, .y = self.mouse_y },
        };
        const event = self.translator.translate(message, &context) orelse return;
        switch (event) {
            .mouse_entered => self.trackPointerLeave(),
            .mouse_down => _ = win32.SetCapture(self.hwnd.?),
            .mouse_up => if (self.translator.pressed_button == null) {
                _ = win32.ReleaseCapture();
            },
            else => {},
        }
        if (self.closed) return;
        _ = self.handleInput(event);
    }

    /// Route one translated input event to the application.
    pub fn handleInput(self: *Self, event: input.InputEvent) bool {
        assert(!self.closed);
        switch (event) {
            .mouse_down, .mouse_up, .mouse_moved, .mouse_dragged => |mouse| {
                self.mouse_x = mouse.position.x;
                self.mouse_y = mouse.position.y;
            },
            .mouse_entered => |mouse| {
                self.mouse_x = mouse.position.x;
                self.mouse_y = mouse.position.y;
                self.mouse_inside = true;
            },
            .mouse_exited => self.mouse_inside = false,
            else => {},
        }
        var handled = false;
        if (self.on_input) |callback| handled = callback(self, event);
        if (self.on_post_input) |callback| callback(self);
        self.requestRender();
        return handled;
    }

    /// Ask for one `WM_MOUSELEAVE` when the pointer next leaves the client.
    fn trackPointerLeave(self: *Self) void {
        var request = win32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
            .dwFlags = win32.TME_LEAVE,
            .hwndTrack = self.hwnd.?,
            .dwHoverTime = 0,
        };
        if (win32.TrackMouseEvent(&request) == win32.FALSE) {
            std.log.warn("windows: TrackMouseEvent failed (error {d})", .{win32.GetLastError()});
        }
    }

    // =========================================================================
    // Geometry
    // =========================================================================

    pub fn width(self: *const Self) u32 {
        assert(self.size.width >= 0);
        return @intFromFloat(self.size.width);
    }

    pub fn height(self: *const Self) u32 {
        assert(self.size.height >= 0);
        return @intFromFloat(self.size.height);
    }

    pub fn getSize(self: *const Self) geometry.Size(f64) {
        return self.size;
    }

    pub fn getScaleFactor(self: *const Self) f64 {
        assert(self.scale_factor > 0);
        return self.scale_factor;
    }

    // =========================================================================
    // Properties
    // =========================================================================

    pub fn setTitle(self: *Self, title: []const u8) void {
        assert(title.len <= title_bytes_max);
        self.storeTitle(title);
        const hwnd = self.hwnd orelse return;
        if (win32.SetWindowTextW(hwnd, @ptrCast(&self.title_buffer)) == win32.FALSE) {
            std.log.warn("windows: SetWindowTextW failed (error {d})", .{win32.GetLastError()});
        }
    }

    /// Convert the title to NUL-terminated UTF-16. Invalid UTF-8 is a caller
    /// bug; the previous title is kept rather than showing a partial one.
    fn storeTitle(self: *Self, title: []const u8) void {
        const len = @min(title.len, title_bytes_max);
        const target = self.title_buffer[0..title_bytes_max];
        const units = std.unicode.utf8ToUtf16Le(target, title[0..len]) catch {
            std.log.err("windows: window title is not valid UTF-8; keeping the old title", .{});
            return;
        };
        assert(units <= title_bytes_max);
        self.title_buffer[units] = 0;
    }

    pub fn setBackgroundColor(self: *Self, color: geometry.Color) void {
        assert(color.a >= 0);
        assert(color.a <= 1);
        self.background_color = color;
        self.requestRender();
    }

    /// Stored only. Windows applies the system theme to the frame; asking
    /// for a dark title bar needs `DwmSetWindowAttribute`, a later item.
    pub fn setAppearance(self: *Self, dark: bool) void {
        self.dark_appearance = dark;
        assert(self.dark_appearance == dark);
    }

    /// Applied on the next `WM_SETCURSOR`, which Windows sends on every
    /// pointer move.
    pub fn setCursorShape(self: *Self, shape: interface_mod.CursorShape) void {
        self.cursor_shape = shape;
        if (self.mouse_inside) _ = win32.SetCursor(self.platform.cursor(shape));
        assert(self.cursor_shape == shape);
    }

    /// The surface is opaque, so a glass style has no backdrop to show; it
    /// still clears transparent to match the other backends' contract.
    pub fn getClearColor(self: *const Self) geometry.Color {
        assert(self.background_color.a >= 0);
        assert(self.background_color.a <= 1);
        if (self.glass_style.needsTransparentClear()) return geometry.Color.transparent;
        return self.background_color;
    }

    pub fn getMousePosition(self: *const Self) geometry.Point(f64) {
        return .{ .x = self.mouse_x, .y = self.mouse_y };
    }

    pub fn isMouseInside(self: *const Self) bool {
        return self.mouse_inside;
    }

    pub fn getWindowId(self: *const Self) WindowId {
        return self.window_id;
    }

    pub fn getPlatform(self: *Self) *WindowsPlatform {
        assert(@intFromPtr(self.platform) != 0);
        return self.platform;
    }

    // =========================================================================
    // Host control
    // =========================================================================

    pub fn requestRender(self: *Self) void {
        if (self.closed) return;
        self.needs_redraw = true;
        assert(self.needs_redraw);
    }

    /// Ask for a frame no later than `delay_ms` from now. Only the earliest
    /// deadline is kept; the frame drawn at it re-arms whatever views still
    /// depend on the clock (see `render_deadline_ms`).
    pub fn requestRenderAfter(self: *Self, delay_ms: u32) void {
        assert(delay_ms <= interface_mod.render_delay_ms_max);
        if (self.closed) return;
        if (delay_ms == 0) {
            self.requestRender();
            return;
        }
        const deadline_ms = windows_platform.nowMilliseconds() + delay_ms;
        if (self.render_deadline_ms) |armed_ms| {
            if (armed_ms <= deadline_ms) return;
        }
        self.render_deadline_ms = deadline_ms;
        assert(self.render_deadline_ms.? <= deadline_ms);
    }

    /// Request the frame a passed deadline asked for. Called by the loop once
    /// per turn.
    pub fn fireRenderDeadline(self: *Self, now_ms: i64) void {
        assert(now_ms >= 0);
        const deadline_ms = self.render_deadline_ms orelse return;
        if (now_ms < deadline_ms) return;
        self.render_deadline_ms = null;
        self.requestRender();
        if (!self.closed) assert(self.needs_redraw);
    }

    pub fn focus(self: *Self) void {
        assert(!self.closed);
        // Windows may refuse to steal focus from another process and flash
        // the taskbar button instead; that is the system's policy to apply.
        _ = win32.SetForegroundWindow(self.hwnd.?);
        self.requestRender();
    }

    /// Runs the application's veto, then records the close and hides the
    /// window. The `HWND` lives until `deinit`: `close` is reachable from
    /// inside this window's own input dispatch, where teardown would free
    /// state the caller is still using. The owner reclaims it from its
    /// loop-turn hook, and the loop ends once no open window remains.
    pub fn close(self: *Self) void {
        if (self.closed) return;
        if (self.on_close) |callback| {
            if (!callback(self)) return;
        }
        self.closed = true;
        self.needs_redraw = false;
        self.render_deadline_ms = null;
        if (self.hwnd) |hwnd| _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
        if (self.platform.getActiveWindowId() == self.window_id) {
            self.platform.setActiveWindowId(null);
        }
        assert(self.isClosed());
    }

    pub fn isClosed(self: *const Self) bool {
        return self.closed;
    }

    // =========================================================================
    // Frame handoff
    // =========================================================================

    pub fn setScene(self: *Self, scene: *const scene_mod.Scene) void {
        self.scene = scene;
    }

    pub fn setTextAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        self.text_atlas = atlas;
    }

    pub fn setSvgAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        self.svg_atlas = atlas;
    }

    pub fn setImageAtlas(self: *Self, atlas: *const text_mod.Atlas) void {
        self.image_atlas = atlas;
    }

    // =========================================================================
    // IME bridge
    // =========================================================================

    pub fn setMarkedText(self: *Self, text: []const u8) void {
        const len = @min(text.len, ime_bytes_max);
        @memcpy(self.marked_text_buffer[0..len], text[0..len]);
        self.marked_text_len = len;
    }

    pub fn clearMarkedText(self: *Self) void {
        self.marked_text_len = 0;
    }

    pub fn setInsertedText(self: *Self, text: []const u8) void {
        const len = @min(text.len, ime_bytes_max);
        @memcpy(self.inserted_text_buffer[0..len], text[0..len]);
        self.inserted_text_len = len;
    }

    pub fn hasMarkedText(self: *const Self) bool {
        return self.marked_text_len > 0;
    }

    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        self.ime_cursor_rect = geometry.RectF.init(x, y, w, h);
    }

    // =========================================================================
    // Callbacks
    // =========================================================================

    pub fn setInputCallback(self: *Self, callback: ?InputCallback) void {
        self.on_input = callback;
    }

    pub fn setRenderCallback(self: *Self, callback: ?RenderCallback) void {
        self.on_render = callback;
    }

    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        self.on_close = callback;
    }

    pub fn setResizeCallback(self: *Self, callback: ?ResizeCallback) void {
        self.on_resize = callback;
    }

    pub fn setPostInputCallback(self: *Self, callback: ?PostInputCallback) void {
        self.on_post_input = callback;
    }

    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        self.user_data = data;
    }

    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        const ptr = self.user_data orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    // =========================================================================
    // Window procedure handlers
    // =========================================================================

    fn handleSize(self: *Self, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
        const was_minimized = self.minimized;
        self.minimized = wparam == win32.SIZE_MINIMIZED;
        if (self.minimized) return;
        const size_bits: usize = @bitCast(lparam);
        self.applyClientSize(win32.loWord(size_bits), win32.hiWord(size_bits));
        if (was_minimized) self.requestRender();
    }

    /// Adopt the new monitor's scale and move to the rectangle Windows
    /// suggests, which keeps the logical size. The resulting `WM_SIZE`
    /// rebuilds the swapchain at the new scale.
    fn handleDpiChanged(self: *Self, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
        const dpi = win32.loWord(wparam);
        assert(dpi > 0);
        self.scale_factor = scaleFromDpi(dpi);
        const suggested: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = win32.SetWindowPos(
            self.hwnd.?,
            null,
            suggested.left,
            suggested.top,
            suggested.right - suggested.left,
            suggested.bottom - suggested.top,
            win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
        );
        // A move between monitors of equal pixel size changes only the scale.
        self.readClientSize();
    }

    /// Apply `WindowOptions.min_size` and `max_size` as outer track sizes.
    fn handleMinMaxInfo(self: *const Self, info: *win32.MINMAXINFO) void {
        const dpi = dpiFromScale(self.scale_factor);
        if (self.min_size) |min| {
            info.ptMinTrackSize = outerSize(min.width, min.height, dpi);
        }
        if (self.max_size) |max| {
            info.ptMaxTrackSize = outerSize(max.width, max.height, dpi);
        }
    }

    fn handleSetFocus(self: *Self) void {
        if (self.closed or !self.window_id.isValid()) return;
        self.platform.setActiveWindowId(self.window_id);
        self.requestRender();
    }

    /// Dispatch one message for this window. Returns null to defer to
    /// `DefWindowProcW`.
    fn handleMessage(self: *Self, message: windows_input.Message) ?win32.LRESULT {
        switch (message.id) {
            win32.WM_CLOSE => self.close(),
            win32.WM_SIZE => self.handleSize(message.wparam, message.lparam),
            win32.WM_DPICHANGED => self.handleDpiChanged(message.wparam, message.lparam),
            win32.WM_GETMINMAXINFO => {
                self.handleMinMaxInfo(@ptrFromInt(@as(usize, @bitCast(message.lparam))));
            },
            win32.WM_SETFOCUS => self.handleSetFocus(),
            win32.WM_ERASEBKGND => return 1, // Vulkan covers every pixel.
            win32.WM_PAINT => {
                // Live resizing runs a modal loop inside `DefWindowProcW`, so
                // the platform loop cannot render; this keeps the window
                // drawn. `DefWindowProcW` then validates the region.
                if (self.needs_redraw) self.renderFrame();
                return null;
            },
            win32.WM_SETCURSOR => {
                if (win32.loWord(@bitCast(message.lparam)) != win32.HTCLIENT) return null;
                _ = win32.SetCursor(self.platform.cursor(self.cursor_shape));
                return win32.TRUE;
            },
            win32.WM_MOUSEMOVE,
            win32.WM_MOUSELEAVE,
            win32.WM_LBUTTONDOWN,
            win32.WM_LBUTTONUP,
            win32.WM_RBUTTONDOWN,
            win32.WM_RBUTTONUP,
            win32.WM_MBUTTONDOWN,
            win32.WM_MBUTTONUP,
            win32.WM_MOUSEWHEEL,
            win32.WM_MOUSEHWHEEL,
            win32.WM_KEYDOWN,
            win32.WM_KEYUP,
            win32.WM_CHAR,
            => self.translateAndDeliver(message),
            win32.WM_SYSKEYDOWN, win32.WM_SYSKEYUP => {
                // Delivered, then also left to the system so Alt+F4 and
                // Alt+Space keep working.
                self.translateAndDeliver(message);
                return null;
            },
            else => return null,
        }
        return 0;
    }
};

/// The window procedure for every Gooey window.
///
/// `WM_NCCREATE` carries the `*Window` passed to `CreateWindowExW`; it is
/// stored in `GWLP_USERDATA` and recovered for every later message. Messages
/// sent before it, and after `destroyNativeWindow` unbinds the window, go to
/// `DefWindowProcW`.
pub fn windowProc(
    hwnd: win32.HWND,
    message_id: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    if (message_id == win32.WM_NCCREATE) {
        const create: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const window: *Window = @ptrCast(@alignCast(create.lpCreateParams.?));
        assert(window.hwnd == null);
        window.hwnd = hwnd;
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(window)));
        return win32.DefWindowProcW(hwnd, message_id, wparam, lparam);
    }
    const bound = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (bound == 0) return win32.DefWindowProcW(hwnd, message_id, wparam, lparam);

    const window: *Window = @ptrFromInt(@as(usize, @bitCast(bound)));
    assert(window.hwnd == hwnd);
    const message = windows_input.Message{ .id = message_id, .wparam = wparam, .lparam = lparam };
    return window.handleMessage(message) orelse
        win32.DefWindowProcW(hwnd, message_id, wparam, lparam);
}

fn currentModifiers() input.Modifiers {
    return .{
        .shift = win32.isKeyDown(win32.VK_SHIFT),
        .ctrl = win32.isKeyDown(win32.VK_CONTROL),
        .alt = win32.isKeyDown(win32.VK_MENU),
        .cmd = win32.isKeyDown(win32.VK_LWIN) or win32.isKeyDown(win32.VK_RWIN),
    };
}

fn scaleFromDpi(dpi: u32) f64 {
    assert(dpi > 0);
    const dpi_default: f64 = @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI);
    const scale = @as(f64, @floatFromInt(dpi)) / dpi_default;
    assert(scale > 0);
    return scale;
}

fn dpiFromScale(scale: f64) u32 {
    assert(scale > 0);
    return @intFromFloat(@round(scale * @as(f64, @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI))));
}

/// The outer window size whose client area is `width` by `height` logical
/// pixels at `dpi`.
fn outerSize(width: f64, height: f64, dpi: u32) win32.POINT {
    assert(width > 0);
    assert(height > 0);
    const scale = scaleFromDpi(dpi);
    var rect = win32.RECT{
        .left = 0,
        .top = 0,
        .right = @intFromFloat(@ceil(width * scale)),
        .bottom = @intFromFloat(@ceil(height * scale)),
    };
    const adjusted = win32.AdjustWindowRectExForDpi(
        &rect,
        window_style,
        win32.FALSE,
        window_style_extended,
        dpi,
    );
    if (adjusted == win32.FALSE) {
        std.log.warn("windows: AdjustWindowRectExForDpi failed (error {d})", .{
            win32.GetLastError(),
        });
    }
    return .{ .x = rect.right - rect.left, .y = rect.bottom - rect.top };
}

/// Top-left corner that centers `outer` in the primary monitor's work area.
fn centeredOrigin(outer: win32.POINT) win32.POINT {
    var area: win32.RECT = undefined;
    if (win32.SystemParametersInfoW(win32.SPI_GETWORKAREA, 0, &area, 0) == win32.FALSE) {
        return .{ .x = win32.CW_USEDEFAULT, .y = win32.CW_USEDEFAULT };
    }
    return .{
        .x = area.left + @divFloor(area.right - area.left - outer.x, 2),
        .y = @max(area.top, area.top + @divFloor(area.bottom - area.top - outer.y, 2)),
    };
}
