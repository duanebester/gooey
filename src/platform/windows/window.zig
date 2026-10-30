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
const uia = @import("uia.zig");
const ime = @import("ime.zig");
const windows_input = @import("input.zig");
const windows_platform = @import("platform.zig");
const WindowsPlatform = windows_platform.WindowsPlatform;

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const WindowId = interface_mod.WindowId;
const WindowOptions = interface_mod.WindowOptions;

/// NUL-terminated UTF-16 title storage; see `Window.title_buffer`.
const TitleBuffer = [Window.title_bytes_max + 1]u16;

/// Caret rectangle the IME is placed against before a text widget reports one.
const ime_cursor_rect_initial = geometry.RectF{
    .origin = .{ .x = 0, .y = 0 },
    .size = .{ .width = 1, .height = 20 },
};

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
    /// Set while the last swapchain rebuild failed, so the failure is logged
    /// once rather than on every retry.
    swapchain_rebuild_failed: bool = false,
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
    /// The cadence slot of the window's last frame, on
    /// `platform.nowNanoseconds`: when it was due, not when it finished (see
    /// `frameSlotNs`).
    last_frame_ns: ?u64 = null,

    scene: ?*const scene_mod.Scene = null,
    text_atlas: ?*const text_mod.Atlas = null,
    svg_atlas: ?*const text_mod.Atlas = null,
    image_atlas: ?*const text_mod.Atlas = null,

    /// `SetWindowTextW` takes a NUL-terminated UTF-16 string. UTF-8 never
    /// needs more UTF-16 units than bytes, so the payload fits. Always holds
    /// a terminator once `initInPlace` has run.
    title_buffer: TitleBuffer = undefined,

    mouse_x: f64 = 0,
    mouse_y: f64 = 0,
    mouse_inside: bool = false,
    translator: windows_input.Translator,

    // IME state; see `ime.zig`. `WM_IME_COMPOSITION` reads into `ime_units`
    // and encodes into the marked (preedit) and inserted (committed) buffers,
    // which the contract's bridge also writes.
    ime_units: [ime.units_max]u16 = undefined,
    marked_text_buffer: [ime_bytes_max]u8 = undefined,
    marked_text_len: usize = 0,
    inserted_text_buffer: [ime_bytes_max]u8 = undefined,
    inserted_text_len: usize = 0,
    ime_cursor_rect: geometry.RectF = ime_cursor_rect_initial,

    /// The accessibility bridge's root provider, published by
    /// `accessibility/windows_bridge.zig` and served on `WM_GETOBJECT`.
    uia_host: uia.Host = .{},
    /// Frames still to render after a UI Automation root request; see
    /// `uia.activation_frame_count`.
    uia_activation_frames: u8 = 0,

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
    pub const ime_bytes_max: usize = ime.bytes_max;

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
        if (options.min_size) |min| assertSizeLimit(min);
        if (options.max_size) |max| assertSizeLimit(max);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.initInPlace(allocator, plat, options);
        // A rejected title leaves the empty one `initInPlace` established.
        if (!self.storeTitle(options.title)) {
            std.log.err("windows: window title is not valid UTF-8; opening untitled", .{});
        }

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
        assert(rendererSwapchainUsable(&self.renderer));
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

    /// Establish every field before the window can be observed. Assigned field
    /// by field: one struct literal for the whole window, renderer included,
    /// may be built in a stack temporary and copied (CLAUDE.md §13 and §14).
    noinline fn initInPlace(
        self: *Self,
        allocator: Allocator,
        plat: *WindowsPlatform,
        options: *const WindowOptions,
    ) void {
        // A field added to `Window` must be initialized here too.
        comptime assert(@typeInfo(Self).@"struct".field_names.len == 48);
        self.allocator = allocator;
        self.platform = plat;
        self.window_id = .invalid;
        self.hwnd = null;
        self.size = .{ .width = options.width, .height = options.height };
        self.scale_factor = scaleFromDpi(win32.GetDpiForSystem());
        self.client_width_px = 0;
        self.client_height_px = 0;
        self.swapchain_width_px = 0;
        self.swapchain_height_px = 0;
        self.swapchain_scale_factor = 0;
        self.swapchain_rebuild_failed = false;
        self.minimized = false;
        self.min_size = options.min_size;
        self.max_size = options.max_size;
        self.renderer = VulkanRenderer.init(allocator);
        self.background_color = options.background_color;
        self.glass_style = options.glass_style;
        self.dark_appearance = false;
        self.cursor_shape = .default;
        self.needs_redraw = true;
        self.closed = false;
        self.rendering = false;
        self.render_deadline_ms = null;
        self.last_frame_ns = null;
        self.scene = null;
        self.text_atlas = null;
        self.svg_atlas = null;
        self.image_atlas = null;
        // Empty and terminated, so `CreateWindowExW` reads a valid string even
        // when `options.title` is rejected. Units past the NUL are never read.
        self.title_buffer[0] = 0;
        self.mouse_x = 0;
        self.mouse_y = 0;
        self.mouse_inside = false;
        self.translator = windows_input.Translator.init(plat.click_settings);
        // `ime_units` and the two text buffers are scratch, read only below
        // the lengths set here, so they stay unwritten.
        self.marked_text_len = 0;
        self.inserted_text_len = 0;
        self.ime_cursor_rect = ime_cursor_rect_initial;
        self.uia_host = .{};
        self.uia_activation_frames = 0;
        self.on_input = null;
        self.on_render = null;
        self.on_close = null;
        self.on_resize = null;
        self.on_post_input = null;
        self.user_data = null;

        assert(self.scale_factor > 0);
        assert(!self.renderer.initialized);
        assert(titleTerminated(&self.title_buffer));
        assert(self.uia_host.root == null);
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
        // The accessibility bridge withdraws its root before the window goes.
        assert(self.uia_host.root == null);
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
        if (!self.isPresentable() or self.rendering) return false;
        if (!self.needs_redraw and !self.renderer.hasPendingAtlasUploads()) return false;
        const last_ns = self.last_frame_ns orelse return true;
        return now_ns -| last_ns >= windows_platform.frame_period_ns_min;
    }

    /// Whether a frame can be shown: the window is open, not minimized, and
    /// has a client area. A zero-area client is not reported as minimized
    /// (a restore animation, a shell that collapses the window), and the
    /// renderer cannot build a swapchain with a zero extent.
    fn isPresentable(self: *const Self) bool {
        if (self.closed or self.minimized) return false;
        return self.client_width_px > 0 and self.client_height_px > 0;
    }

    /// How long, in nanoseconds, the loop may wait before this window needs
    /// attention.
    pub fn waitTimeoutNs(self: *const Self, now_ns: u64, now_ms: i64, timeout_ns_max: u64) u64 {
        assert(!self.closed);
        assert(now_ms >= 0);
        if (!self.isPresentable()) return timeout_ns_max;
        const wait_ns = frameWaitNs(&.{
            .needs_redraw = self.needs_redraw,
            .last_frame_ns = self.last_frame_ns,
            .render_deadline_ms = self.render_deadline_ms,
            .now_ns = now_ns,
            .now_ms = now_ms,
            .timeout_ns_max = timeout_ns_max,
        });
        assert(wait_ns <= timeout_ns_max);
        return wait_ns;
    }

    /// Build and present one frame.
    pub fn renderFrame(self: *Self) void {
        if (!self.isPresentable() or self.rendering) return;
        assert(self.renderer.initialized);
        if (!self.swapchainMatchesClient()) {
            self.resizeSwapchain();
            if (!self.swapchainMatchesClient()) {
                // Paced like a frame, so a rebuild that keeps failing is
                // retried once per period rather than in a busy loop.
                self.last_frame_ns = windows_platform.nowNanoseconds();
                return;
            }
        }
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
        self.last_frame_ns = frameSlotNs(self.last_frame_ns, windows_platform.nowNanoseconds());
        // An out-of-date or suboptimal swapchain skips or degrades this frame
        // and is rebuilt at the start of the next, so ask for that frame now:
        // otherwise an idle window keeps its last image until other input.
        if (self.renderer.swapchain_needs_recreate) self.requestRender();
        if (self.uia_activation_frames > 0) {
            self.uia_activation_frames -= 1;
            self.requestRender();
        }
        assert(self.rendering);
    }

    /// Adopt the client size `WM_SIZE` reported and rebuild the swapchain
    /// when the device-pixel size or the scale changed.
    fn applyClientSize(self: *Self, width_px: u32, height_px: u32) void {
        assert(self.scale_factor > 0);
        const had_area = self.client_width_px > 0 and self.client_height_px > 0;
        self.client_width_px = width_px;
        self.client_height_px = height_px;
        // No area: `isPresentable` keeps frames off the stale swapchain, and
        // `size` keeps the last real size until the client grows again.
        if (width_px == 0 or height_px == 0) return;

        const old_size = self.size;
        self.size = .{
            .width = @as(f64, @floatFromInt(width_px)) / self.scale_factor,
            .height = @as(f64, @floatFromInt(height_px)) / self.scale_factor,
        };
        if (!self.renderer.initialized) return;
        if (!had_area) self.requestRender();
        if (self.swapchainMatchesClient()) return;

        self.resizeSwapchain();
        self.requestRender();
        if (old_size.width != self.size.width or old_size.height != self.size.height) {
            if (self.on_resize) |callback| callback(self, self.size.width, self.size.height);
        }
    }

    /// Rebuild the swapchain for the client size and scale. The shared
    /// renderer's `resize` logs and swallows its errors and can leave the
    /// swapchain without framebuffers, so success is read back from its
    /// state. A failed rebuild is not recorded, so `renderFrame` retries it
    /// rather than drawing into the broken swapchain.
    fn resizeSwapchain(self: *Self) void {
        assert(self.renderer.initialized);
        assert(self.client_width_px > 0);
        assert(self.client_height_px > 0);
        self.renderer.resize(self.rendererWidth(), self.rendererHeight(), self.scale_factor);
        if (rendererSwapchainUsable(&self.renderer)) {
            self.recordSwapchainSize();
            self.swapchain_rebuild_failed = false;
            assert(self.swapchainMatchesClient());
            return;
        }
        if (!self.swapchain_rebuild_failed) {
            std.log.err("windows: swapchain rebuild for {d}x{d} px failed; retrying", .{
                self.client_width_px,
                self.client_height_px,
            });
        }
        self.swapchain_rebuild_failed = true;
        // No presentable client is zero pixels wide, so a later return to the
        // previous size still rebuilds instead of drawing into the remains.
        self.swapchain_width_px = 0;
        self.swapchain_height_px = 0;
        assert(!self.swapchainMatchesClient());
    }

    /// Whether the swapchain was last built for the current client size and
    /// scale.
    fn swapchainMatchesClient(self: *const Self) bool {
        assert(self.scale_factor > 0);
        if (self.client_width_px != self.swapchain_width_px) return false;
        if (self.client_height_px != self.swapchain_height_px) return false;
        return self.scale_factor == self.swapchain_scale_factor;
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
        assert(self.scale_factor > 0);
        assert(self.renderer.initialized);
        self.swapchain_width_px = self.client_width_px;
        self.swapchain_height_px = self.client_height_px;
        self.swapchain_scale_factor = self.scale_factor;
    }

    /// The renderer takes whole logical pixels and multiplies by the scale.
    /// Rounding up makes the product cover the client area; the swapchain
    /// clamps it to the surface's exact extent.
    ///
    /// The same whole number is the renderer's viewport uniform, so at a
    /// fractional scale the scene is drawn at `client_px / ceil(size)` rather
    /// than `scale_factor`: at 150% a 1001 px client renders 668 logical px
    /// across it (scale 1.4985), shrinking content by under one logical pixel
    /// and leaving that sliver at the right and bottom edges. Exact output
    /// needs a fractional viewport from the shared renderer; see
    /// `docs/windows-port.md`.
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

    /// Translate one input message and deliver the events it produces: at
    /// most one, except a capture loss, which releases each held button.
    fn translateAndDeliver(self: *Self, message: windows_input.Message) void {
        assert(self.hwnd != null);
        assert(self.scale_factor > 0);
        const context = windows_input.Context{
            .scale_factor = self.scale_factor,
            .modifiers = currentModifiers(),
            .time_ms = @bitCast(win32.GetMessageTime()),
            .pointer = self.messagePointer(message),
        };
        const lost_capture = message.id == win32.WM_CAPTURECHANGED;
        const event_count_max: u32 = if (lost_capture) windows_input.mouse_button_count else 1;
        var event_count: u32 = 0;
        while (event_count < event_count_max) : (event_count += 1) {
            const event = self.translator.translate(message, &context) orelse return;
            self.applyPointerActions(self.translator.pointerActions(message.id, event));
            if (self.closed) return;
            _ = self.handleInput(event);
        }
        assert(event_count == event_count_max);
        if (lost_capture) assert(self.translator.buttons_held == 0);
    }

    /// The pointer position `Context` reports for `message`, in logical
    /// client pixels. Wheel messages carry screen coordinates, converted here
    /// so the translator stays free of Win32 calls; every other message uses
    /// the last known position.
    fn messagePointer(self: *const Self, message: windows_input.Message) geometry.Point(f64) {
        assert(self.hwnd != null);
        assert(self.scale_factor > 0);
        const last_known = geometry.Point(f64){ .x = self.mouse_x, .y = self.mouse_y };
        const is_wheel = message.id == win32.WM_MOUSEWHEEL or message.id == win32.WM_MOUSEHWHEEL;
        if (!is_wheel) return last_known;

        var point = win32.POINT{
            .x = win32.xFromLParam(message.lparam),
            .y = win32.yFromLParam(message.lparam),
        };
        if (win32.ScreenToClient(self.hwnd.?, &point) == win32.FALSE) {
            std.log.warn("windows: ScreenToClient failed for a wheel message (error {d})", .{
                win32.GetLastError(),
            });
            return last_known;
        }
        return windows_input.logicalFromDevice(point.x, point.y, self.scale_factor);
    }

    /// Make the capture and leave-tracking calls `pointerActions` decided.
    fn applyPointerActions(self: *Self, actions: windows_input.PointerActions) void {
        assert(self.hwnd != null);
        if (actions.capture == .set) assert(!actions.track_leave);
        switch (actions.capture) {
            .none => {},
            // Returns the previous capture owner, which carries no error.
            .set => _ = win32.SetCapture(self.hwnd.?),
            // Sends `WM_CAPTURECHANGED`, which translates to nothing: no
            // button is held by the time capture is released.
            .release => if (win32.ReleaseCapture() == win32.FALSE) {
                std.log.warn("windows: ReleaseCapture failed (error {d})", .{win32.GetLastError()});
            },
        }
        if (actions.track_leave) self.trackPointerLeave();
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

    /// An over-long title is a programmer error, as on the other backends.
    /// Invalid UTF-8 keeps the previous title rather than showing part of one.
    pub fn setTitle(self: *Self, title: []const u8) void {
        assert(title.len <= title_bytes_max);
        if (!self.storeTitle(title)) {
            std.log.err("windows: window title is not valid UTF-8; keeping the old title", .{});
            return;
        }
        const hwnd = self.hwnd orelse return;
        if (win32.SetWindowTextW(hwnd, @ptrCast(&self.title_buffer)) == win32.FALSE) {
            std.log.warn("windows: SetWindowTextW failed (error {d})", .{win32.GetLastError()});
        }
    }

    /// Store the title as NUL-terminated UTF-16. Returns false, with the
    /// stored title untouched, when `title` is not valid UTF-8.
    fn storeTitle(self: *Self, title: []const u8) bool {
        assert(title.len <= title_bytes_max);
        assert(titleTerminated(&self.title_buffer));
        const stored = encodeTitle(&self.title_buffer, title);
        assert(titleTerminated(&self.title_buffer));
        return stored;
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

    // IME text on this backend is one `ime.utf8FromUtf16` result: at most
    // `ime.units_max` (1024) UTF-16 units, each at most three UTF-8 bytes
    // (a surrogate pair is four bytes for two units), so 3072 bytes, which
    // is `ime_bytes_max` exactly. Longer text cannot come from an IME and is a
    // programmer error, so the setters assert instead of truncating, which
    // could also split a UTF-8 sequence.
    comptime {
        assert(ime_bytes_max == ime.bytes_max);
        assert(ime_bytes_max >= ime.units_max * 3);
    }

    pub fn setMarkedText(self: *Self, text: []const u8) void {
        assert(text.len <= ime_bytes_max);
        assert(std.unicode.utf8ValidateSlice(text));
        @memcpy(self.marked_text_buffer[0..text.len], text);
        self.marked_text_len = text.len;
    }

    pub fn clearMarkedText(self: *Self) void {
        self.marked_text_len = 0;
    }

    pub fn setInsertedText(self: *Self, text: []const u8) void {
        assert(text.len <= ime_bytes_max);
        assert(std.unicode.utf8ValidateSlice(text));
        @memcpy(self.inserted_text_buffer[0..text.len], text);
        self.inserted_text_len = text.len;
    }

    pub fn hasMarkedText(self: *const Self) bool {
        return self.marked_text_len > 0;
    }

    /// Called every frame while a text widget has focus. The IME is told only
    /// when the caret moved, and again when a composition starts.
    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        assert(w >= 0);
        assert(h >= 0);
        const rect = geometry.RectF.init(x, y, w, h);
        if (std.meta.eql(rect, self.ime_cursor_rect)) return;
        self.ime_cursor_rect = rect;
        self.applyImePlacement();
    }

    /// Place the IME's candidate list against the caret.
    fn applyImePlacement(self: *Self) void {
        const hwnd = self.hwnd orelse return;
        // No context: IME is disabled for this window, so nothing to place.
        const context = ime.ImmGetContext(hwnd) orelse return;
        defer _ = ime.ImmReleaseContext(hwnd, context);

        const placement = ime.Placement.fromCaret(self.ime_cursor_rect, self.scale_factor);
        if (ime.ImmSetCompositionWindow(context, &placement.composition) == win32.FALSE) {
            std.log.warn("windows: ImmSetCompositionWindow failed", .{});
        }
        if (ime.ImmSetCandidateWindow(context, &placement.candidate) == win32.FALSE) {
            std.log.warn("windows: ImmSetCandidateWindow failed", .{});
        }
    }

    /// Hide the IME's composition window, because the text widgets draw the
    /// composition inline as preedit. The candidate list stays.
    fn handleImeSetContext(self: *Self, message: windows_input.Message) win32.LRESULT {
        assert(message.id == win32.WM_IME_SETCONTEXT);
        assert(self.hwnd != null);
        const flags: usize = @bitCast(message.lparam);
        const lparam: win32.LPARAM = @bitCast(flags & ~ime.ISC_SHOWUICOMPOSITIONWINDOW);
        return win32.DefWindowProcW(self.hwnd.?, message.id, message.wparam, lparam);
    }

    /// Deliver one composition update: committed text first, then the new
    /// preedit, the order the Wayland backend uses. Returns null to let
    /// `DefWindowProcW` deliver a result too long for `ime.units_max`.
    fn handleImeComposition(self: *Self, lparam: win32.LPARAM) ?win32.LRESULT {
        assert(self.hwnd != null);
        const hwnd = self.hwnd.?;
        const changes = ime.Changes.fromLParam(lparam);
        if (changes.cancelled) {
            self.clearImeComposition();
            return 0;
        }
        const context = ime.ImmGetContext(hwnd) orelse return null;
        defer _ = ime.ImmReleaseContext(hwnd, context);

        if (changes.result) {
            const units = ime.readString(context, ime.GCS_RESULTSTR, &self.ime_units) orelse {
                // `DefWindowProcW` turns the result into `WM_CHAR`, which
                // loses nothing. The preedit is cleared first so the
                // characters do not land inside it; the next update redraws
                // any new composition.
                self.clearImeComposition();
                return null;
            };
            self.commitImeComposition(units);
        }
        if (changes.preedit) {
            // Unreadable or oversized preedit was logged; the last one stays.
            const units = ime.readString(context, ime.GCS_COMPSTR, &self.ime_units) orelse
                return 0;
            self.updateImeComposition(units);
        }
        // Neither string changed: only the cursor, attributes, or clauses
        // moved, which `CompositionEvent` cannot carry, so the preedit stays.
        return 0;
    }

    fn commitImeComposition(self: *Self, units: []const u16) void {
        assert(units.len <= ime.units_max);
        if (units.len == 0) {
            self.clearImeComposition();
            return;
        }
        // The widgets drop their preedit when committed text arrives.
        self.marked_text_len = 0;
        self.inserted_text_len = ime.utf8FromUtf16(&self.inserted_text_buffer, units);
        assert(self.inserted_text_len > 0);
        if (self.closed) return;
        const text = self.inserted_text_buffer[0..self.inserted_text_len];
        _ = self.handleInput(.{ .text_input = .{ .text = text } });
    }

    fn updateImeComposition(self: *Self, units: []const u16) void {
        assert(units.len <= ime.units_max);
        if (units.len == 0) {
            self.clearImeComposition();
            return;
        }
        self.marked_text_len = ime.utf8FromUtf16(&self.marked_text_buffer, units);
        assert(self.marked_text_len > 0);
        if (self.closed) return;
        const text = self.marked_text_buffer[0..self.marked_text_len];
        _ = self.handleInput(.{ .composition = .{ .text = text } });
    }

    /// Remove a shown preedit. Also the `WM_IME_ENDCOMPOSITION` handler: after
    /// a commit nothing is shown, so only a cancelled composition reports.
    fn clearImeComposition(self: *Self) void {
        if (self.marked_text_len == 0) return;
        assert(self.marked_text_len <= ime_bytes_max);
        self.marked_text_len = 0;
        if (self.closed) return;
        _ = self.handleInput(.{ .composition = .{ .text = "" } });
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
    /// An infinite maximum on an axis means no limit there, so that axis
    /// keeps the system's track size; sizes beyond `client_px_max` clamp.
    fn handleMinMaxInfo(self: *const Self, info: *win32.MINMAXINFO) void {
        assert(self.scale_factor > 0);
        const dpi = dpiFromScale(self.scale_factor);
        if (self.min_size) |min| {
            assert(std.math.isFinite(min.width));
            assert(std.math.isFinite(min.height));
            info.ptMinTrackSize = outerSize(min.width, min.height, dpi);
        }
        if (self.max_size) |max| {
            const outer = outerSize(max.width, max.height, dpi);
            if (std.math.isFinite(max.width)) info.ptMaxTrackSize.x = outer.x;
            if (std.math.isFinite(max.height)) info.ptMaxTrackSize.y = outer.y;
        }
    }

    /// Answer a UI Automation client's request for the root provider, and
    /// render for one poll interval so the accessibility system notices the
    /// client even when nothing else would draw. Other object requests (MSAA)
    /// go to `DefWindowProcW`.
    fn handleGetObject(self: *Self, wparam: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
        assert(self.hwnd != null);
        const object_id: i32 = @truncate(lparam);
        if (object_id != uia.UiaRootObjectId) return null;
        const root = self.uia_host.root orelse return null;
        self.uia_host.client_requested = true;
        self.uia_activation_frames = uia.activation_frame_count;
        self.requestRender();
        return uia.UiaReturnRawElementProvider(self.hwnd.?, wparam, lparam, root);
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
            win32.WM_GETOBJECT => return self.handleGetObject(message.wparam, message.lparam),
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
            win32.WM_CAPTURECHANGED => {
                // `lParam` is the window gaining capture. This window's own
                // `SetCapture` for a second button can name itself, which is
                // no loss; null (its own `ReleaseCapture`) translates to
                // nothing because no button is held by then.
                const gaining: usize = @bitCast(message.lparam);
                if (gaining != @intFromPtr(self.hwnd.?)) self.translateAndDeliver(message);
            },
            win32.WM_IME_SETCONTEXT => return self.handleImeSetContext(message),
            // Handled, not passed on, so the IME draws no composition window.
            win32.WM_IME_STARTCOMPOSITION => self.applyImePlacement(),
            win32.WM_IME_COMPOSITION => return self.handleImeComposition(message.lparam),
            win32.WM_IME_ENDCOMPOSITION => self.clearImeComposition(),
            win32.WM_SYSKEYDOWN, win32.WM_SYSKEYUP => {
                // Delivered as keys; only Alt+F4 and Alt+Space also reach the
                // system, so a lone Alt or F10 never enters menu mode.
                self.translateAndDeliver(message);
                if (windows_input.systemKeyUsesDefault(message)) return null;
            },
            // Consumed, so Alt+letter does not beep; Alt+Space opens the
            // system menu.
            win32.WM_SYSCHAR => if (windows_input.systemKeyUsesDefault(message)) return null,
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
        window.uia_host.hwnd = hwnd;
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

/// Convert `title` into `target` as NUL-terminated UTF-16. Returns false,
/// with `target` untouched, when `title` is not valid UTF-8. Validation comes
/// first because `utf8ToUtf16Le` writes its ASCII prefix before it reports an
/// error, which would leave a half-replaced title behind.
fn encodeTitle(target: *TitleBuffer, title: []const u8) bool {
    assert(title.len <= Window.title_bytes_max);
    assert(titleTerminated(target));
    if (!std.unicode.utf8ValidateSlice(title)) return false;
    // `utf8ValidateSlice` applies the policy `utf8ToUtf16Le` decodes with
    // (no encoded surrogate halves), so the conversion cannot fail.
    const units = std.unicode.utf8ToUtf16Le(target[0..Window.title_bytes_max], title) catch |err|
        switch (err) {
            error.InvalidUtf8 => unreachable,
        };
    assert(units <= title.len);
    target[units] = 0;
    return true;
}

comptime {
    // About 11.5 KiB, the shared renderer 2.6 KiB of it: heap-allocated and
    // initialized in place, but under the 50 KiB WASM stack threshold
    // (CLAUDE.md §14). Revisit `initInPlace` if this bound has to grow.
    assert(@sizeOf(Window) <= 16 * 1024);
    assert(@sizeOf(TitleBuffer) == (Window.title_bytes_max + 1) * @sizeOf(u16));
}

fn titleTerminated(buffer: *const TitleBuffer) bool {
    return std.mem.indexOfScalar(u16, buffer, 0) != null;
}

/// `WindowOptions.min_size` and `max_size` must be positive. Infinity is
/// accepted, and means no limit for a maximum; NaN is a caller bug.
fn assertSizeLimit(size: geometry.Size(f64)) void {
    assert(size.width > 0);
    assert(size.height > 0);
}

/// Whether the shared renderer holds a complete swapchain: a handle and one
/// framebuffer per image. Its `resize` reports no error, and a failed
/// rebuild leaves the framebuffers destroyed.
fn rendererSwapchainUsable(renderer: *const VulkanRenderer) bool {
    assert(renderer.initialized);
    if (renderer.swapchain == null) return false;
    const image_count = renderer.swapchain_image_count;
    if (image_count == 0) return false;
    assert(image_count <= renderer.framebuffers.len);
    for (renderer.framebuffers[0..image_count]) |framebuffer| {
        if (framebuffer == null) return false;
    }
    return true;
}

/// The cadence slot a frame finishing at `now_ns` occupies.
///
/// Measuring the period from when a frame finished adds its render time and
/// the timer's wake-up latency to every period, which held a 60 Hz cap to
/// about 57 fps on an Intel UHD 620. A frame inside the period after its slot
/// was due instead takes that slot, so the next is due one period after it
/// and the rate stays at the cap. A frame later than that (a stall, an idle
/// window, a burst of input) or earlier than its slot (`WM_PAINT` during a
/// live resize) starts a new cadence at `now_ns`, so lost time is never made
/// up with a burst of frames.
fn frameSlotNs(last_slot_ns: ?u64, now_ns: u64) u64 {
    const period_ns = windows_platform.frame_period_ns_min;
    const last_ns = last_slot_ns orelse return now_ns;
    const due_ns = last_ns +| period_ns;
    if (now_ns < due_ns) return now_ns;
    if (now_ns - due_ns < period_ns) {
        assert(due_ns <= now_ns);
        return due_ns;
    }
    return now_ns;
}

/// The inputs of `frameWaitNs`, named because several share a type.
const FrameWait = struct {
    needs_redraw: bool,
    last_frame_ns: ?u64,
    render_deadline_ms: ?i64,
    now_ns: u64,
    now_ms: i64,
    timeout_ns_max: u64,
};

/// Nanoseconds until a window needs a frame: none while a requested frame
/// is already one period past the last, the rest of the period otherwise,
/// or the time to a timed redraw. Never more than `timeout_ns_max`.
///
/// The deadline is measured from `now_ms`, which is `now_ns` rounded down,
/// so the wait ends at or after the deadline and `fireRenderDeadline` sees
/// it as passed.
fn frameWaitNs(wait: *const FrameWait) u64 {
    assert(wait.now_ms >= 0);
    assert(wait.timeout_ns_max > 0);
    const period_ns = windows_platform.frame_period_ns_min;
    if (wait.needs_redraw) {
        const last_ns = wait.last_frame_ns orelse return 0;
        const elapsed_ns = wait.now_ns -| last_ns;
        if (elapsed_ns < period_ns) {
            return @min(period_ns - elapsed_ns, wait.timeout_ns_max);
        }
        return 0;
    }
    const deadline_ms = wait.render_deadline_ms orelse return wait.timeout_ns_max;
    if (deadline_ms > wait.now_ms) {
        const remaining_ms: u64 = @intCast(deadline_ms - wait.now_ms);
        return @min(remaining_ms *| std.time.ns_per_ms, wait.timeout_ns_max);
    }
    return 0;
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

/// Largest client extent, in device pixels, a window is sized to. `WM_SIZE`
/// reports the client size in 16-bit words and mouse messages carry signed
/// 16-bit client coordinates, so no larger client is usable. It also keeps
/// `AdjustWindowRectExForDpi`'s frame arithmetic far from `i32` overflow.
const client_px_max: i32 = std.math.maxInt(i16);

/// Device pixels covering `logical` pixels at `scale`, rounded up and
/// clamped to `[1, client_px_max]`. Infinity clamps to the maximum.
fn clientPxFromLogical(logical: f64, scale: f64) i32 {
    assert(!std.math.isNan(logical));
    assert(logical > 0);
    assert(std.math.isFinite(scale));
    assert(scale > 0);
    const device_px = @ceil(logical * scale);
    // Compared as floats first: `@intFromFloat` of an out-of-range value is
    // illegal behavior. A NaN that slipped past the assertions takes the
    // minimum.
    if (device_px >= 1) {
        if (device_px <= client_px_max) return @intFromFloat(device_px);
        return client_px_max;
    }
    return 1;
}

/// The outer window size whose client area is `width` by `height` logical
/// pixels at `dpi`, each clamped by `clientPxFromLogical`.
fn outerSize(width: f64, height: f64, dpi: u32) win32.POINT {
    assert(width > 0);
    assert(height > 0);
    const scale = scaleFromDpi(dpi);
    var rect = win32.RECT{
        .left = 0,
        .top = 0,
        .right = clientPxFromLogical(width, scale),
        .bottom = clientPxFromLogical(height, scale),
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
    const outer = win32.POINT{ .x = rect.right - rect.left, .y = rect.bottom - rect.top };
    assert(outer.x > 0);
    assert(outer.y > 0);
    return outer;
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

fn testTitleBuffer(initial: []const u8) !TitleBuffer {
    var buffer: TitleBuffer = undefined;
    buffer[0] = 0;
    try std.testing.expect(encodeTitle(&buffer, initial));
    return buffer;
}

fn testRepeat(comptime unit: []const u8, comptime count: usize) [unit.len * count]u8 {
    var result: [unit.len * count]u8 = undefined;
    for (0..count) |index| {
        @memcpy(result[index * unit.len ..][0..unit.len], unit);
    }
    return result;
}

fn expectTitle(buffer: *const TitleBuffer, expected: []const u8) !void {
    const units = std.mem.sliceTo(buffer, 0);
    var expected_units: TitleBuffer = undefined;
    const count = try std.unicode.utf8ToUtf16Le(&expected_units, expected);
    try std.testing.expectEqualSlices(u16, expected_units[0..count], units);
}

test "title encoding fills the buffer exactly at the byte limit" {
    // Methodology: the empty title, then the longest ASCII title (one unit
    // per byte, so the terminator lands in the last slot), then the longest
    // three-byte title (fewer units than bytes).
    var buffer = try testTitleBuffer("");
    try std.testing.expectEqual(@as(u16, 0), buffer[0]);

    const ascii_max: [Window.title_bytes_max]u8 = @splat('a');
    try std.testing.expect(encodeTitle(&buffer, &ascii_max));
    try std.testing.expectEqual(@as(u16, 0), buffer[Window.title_bytes_max]);
    try expectTitle(&buffer, &ascii_max);

    const euro_max = comptime testRepeat("\u{20AC}", @divExact(Window.title_bytes_max, 3));
    comptime assert(euro_max.len == Window.title_bytes_max);
    try std.testing.expect(encodeTitle(&buffer, &euro_max));
    try expectTitle(&buffer, &euro_max);
}

test "invalid title UTF-8 leaves the stored title intact" {
    // Methodology: each rejected title starts with an ASCII run longer than
    // any SIMD chunk, which `utf8ToUtf16Le` would copy before failing. The
    // previous title must survive unit for unit up to its terminator.
    var buffer = try testTitleBuffer("Old title");
    const ascii_run: [70]u8 = @splat('x');
    const rejected = [_][]const u8{
        &(ascii_run ++ "\xFF".*), // Never valid in UTF-8.
        &(ascii_run ++ "\xE2\x82".*), // Truncated three-byte sequence.
        &(ascii_run ++ "\xED\xA0\x80".*), // Encoded surrogate half.
        &(ascii_run ++ "\xC0\xAF".*), // Overlong encoding.
    };
    for (rejected) |title| {
        try std.testing.expect(!encodeTitle(&buffer, title));
        try expectTitle(&buffer, "Old title");
    }
    // One valid title after the rejections still replaces it.
    try std.testing.expect(encodeTitle(&buffer, &ascii_run));
    try expectTitle(&buffer, &ascii_run);
}

test "frame wait covers the rest of the period around its boundary" {
    // Methodology: a requested frame one nanosecond either side of the
    // period boundary, the first frame, and a clock that read earlier than
    // the last frame (the elapsed time saturates to zero).
    const period_ns = windows_platform.frame_period_ns_min;
    const max_ns: u64 = 20 * std.time.ns_per_ms;
    const last_ns: u64 = 1_000_000_000;
    var wait = FrameWait{
        .needs_redraw = true,
        .last_frame_ns = null,
        .render_deadline_ms = null,
        .now_ns = last_ns,
        .now_ms = 1_000,
        .timeout_ns_max = max_ns,
    };
    try std.testing.expectEqual(@as(u64, 0), frameWaitNs(&wait));

    wait.last_frame_ns = last_ns;
    try std.testing.expectEqual(period_ns, frameWaitNs(&wait));
    wait.now_ns = last_ns + period_ns - 1;
    try std.testing.expectEqual(@as(u64, 1), frameWaitNs(&wait));
    wait.now_ns = last_ns + period_ns;
    try std.testing.expectEqual(@as(u64, 0), frameWaitNs(&wait));
    wait.now_ns = last_ns - 1;
    try std.testing.expectEqual(period_ns, frameWaitNs(&wait));

    // The cap wins over a period longer than it.
    wait.timeout_ns_max = period_ns - 1;
    try std.testing.expectEqual(period_ns - 1, frameWaitNs(&wait));
}

test "frame slots keep the cadence through latency and restart after a stall" {
    // Goal: frames that finish late within a period keep the slot grid, so
    // the rate stays at the cap; a frame a full period late, or early,
    // restarts the grid at the frame. Methodology: one nanosecond either side
    // of each boundary, the first frame, and saturation at the clock's end.
    const period_ns = windows_platform.frame_period_ns_min;
    const start_ns: u64 = 1_000_000_000;
    try std.testing.expectEqual(start_ns, frameSlotNs(null, start_ns));

    const due_ns = start_ns + period_ns;
    try std.testing.expectEqual(due_ns, frameSlotNs(start_ns, due_ns));
    try std.testing.expectEqual(due_ns, frameSlotNs(start_ns, due_ns + 800_000));
    try std.testing.expectEqual(due_ns, frameSlotNs(start_ns, due_ns + period_ns - 1));

    const stalled_ns = due_ns + period_ns;
    try std.testing.expectEqual(stalled_ns, frameSlotNs(start_ns, stalled_ns));
    try std.testing.expectEqual(due_ns - 1, frameSlotNs(start_ns, due_ns - 1));

    // A thousand frames each 0.8 ms late stay on the grid: no drift.
    var slot_ns = start_ns;
    var frame: u32 = 0;
    while (frame < 1_000) : (frame += 1) {
        slot_ns = frameSlotNs(slot_ns, slot_ns + period_ns + 800_000);
    }
    try std.testing.expectEqual(start_ns + 1_000 * period_ns, slot_ns);

    const end_ns = std.math.maxInt(u64);
    try std.testing.expectEqual(end_ns, frameSlotNs(end_ns - 1, end_ns));
}

test "frame wait reaches a timed redraw without ending before it" {
    // Methodology: deadlines before, at, one millisecond after, and far after
    // `now_ms`, with no frame requested; then a requested frame, which takes
    // precedence over a deadline.
    const max_ns: u64 = 16 * std.time.ns_per_ms;
    var wait = FrameWait{
        .needs_redraw = false,
        .last_frame_ns = 0,
        .render_deadline_ms = null,
        .now_ns = 5_000_400_000,
        .now_ms = 5_000,
        .timeout_ns_max = max_ns,
    };
    try std.testing.expectEqual(max_ns, frameWaitNs(&wait));
    wait.render_deadline_ms = 4_999;
    try std.testing.expectEqual(@as(u64, 0), frameWaitNs(&wait));
    wait.render_deadline_ms = 5_000;
    try std.testing.expectEqual(@as(u64, 0), frameWaitNs(&wait));
    wait.render_deadline_ms = 5_001;
    try std.testing.expectEqual(std.time.ns_per_ms, frameWaitNs(&wait));
    wait.render_deadline_ms = std.math.maxInt(i64);
    try std.testing.expectEqual(max_ns, frameWaitNs(&wait));

    wait.needs_redraw = true;
    wait.last_frame_ns = wait.now_ns;
    wait.render_deadline_ms = 5_001;
    try std.testing.expectEqual(max_ns, frameWaitNs(&wait));
}

test "client extents round up and clamp at the Win32 limit" {
    // Methodology: the smallest sizes, a fractional-scale size, one device
    // pixel either side of `client_px_max`, and infinity, which a caller may
    // pass as "no maximum" and which must not reach `@intFromFloat`.
    const max_f: f64 = @floatFromInt(client_px_max);
    try std.testing.expectEqual(@as(i32, 1), clientPxFromLogical(1, 1));
    try std.testing.expectEqual(@as(i32, 1), clientPxFromLogical(1e-9, 1));
    try std.testing.expectEqual(@as(i32, 1001), clientPxFromLogical(667.25, 1.5));
    try std.testing.expectEqual(client_px_max, clientPxFromLogical(max_f, 1));
    try std.testing.expectEqual(client_px_max - 1, clientPxFromLogical(max_f - 1, 1));
    try std.testing.expectEqual(client_px_max, clientPxFromLogical(max_f + 1, 1));
    try std.testing.expectEqual(client_px_max, clientPxFromLogical(max_f, 2));
    try std.testing.expectEqual(client_px_max, clientPxFromLogical(std.math.inf(f64), 1));
    try std.testing.expectEqual(client_px_max, clientPxFromLogical(std.math.floatMax(f64), 3));
}

test "outer size stays in range for unbounded client sizes" {
    // Methodology: the real `AdjustWindowRectExForDpi` adds the frame to the
    // clamped client size at 100% and 300%; the result must be positive and
    // at least the client extent, which an `i32` overflow would break.
    const dpis = [_]u32{ win32.USER_DEFAULT_SCREEN_DPI, 3 * win32.USER_DEFAULT_SCREEN_DPI };
    for (dpis) |dpi| {
        const infinite = outerSize(std.math.inf(f64), std.math.inf(f64), dpi);
        try std.testing.expect(infinite.x >= client_px_max);
        try std.testing.expect(infinite.y >= client_px_max);
        const huge = outerSize(std.math.floatMax(f64), 1e12, dpi);
        try std.testing.expectEqual(infinite.x, huge.x);
        try std.testing.expectEqual(infinite.y, huge.y);
    }
}
