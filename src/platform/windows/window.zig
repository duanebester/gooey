//! Windows platform window — an HWND plus a GPU swapchain (Vulkan or DX11).
//!
//! Rendering is owned by a compile-time-selected renderer (see
//! `gpu_backend` in `mod.zig`: `vk_renderer.zig` by default, `dx11_renderer.zig`
//! under `-Dgpu-backend=dx11`), paced by `WindowsPlatform.run`. Input arrives
//! as Win32 messages translated by `input.zig` into Gooey's `InputEvent`
//! union. All window state lives on the UI thread, so no locks are needed.
//!
//! Sizes are logical pixels; the swapchain is created at physical resolution
//! (`logical * scale_factor`). Win32 client coordinates are physical Y-down,
//! so mouse positions are divided by the scale factor before dispatch.

const std = @import("std");
const win32 = @import("win32/mod.zig");
const wam_foundation = @import("win32/mod.zig").foundation;
const win_input = @import("input.zig");
const platform = @import("platform.zig");
const vk_renderer = @import("vk_renderer.zig");
const vk_atlas = @import("vk_atlas.zig");
const dx11_renderer = @import("dx11_renderer.zig");
const dx11_atlas = @import("dx11_atlas.zig");
const build_options = @import("build_options");
const interface = @import("../interface.zig");
const geometry = @import("../../core/geometry.zig");
const input = @import("../../input/mod.zig");
const scene_mod = @import("../../scene/mod.zig");
const text_mod = @import("../../text/mod.zig");

/// Compile-time renderer selection. The platform layer is deliberately
/// compile-time monomorphic (platform/interface.zig), so the backend is a
/// type choice here rather than a runtime union: every call site binds
/// directly to the concrete renderer.
pub const Renderer = switch (build_options.gpu_backend) {
    .vulkan => vk_renderer.VulkanRenderer,
    .dx11 => dx11_renderer.Dx11Renderer,
};

pub const renderer_name: []const u8 = switch (build_options.gpu_backend) {
    .vulkan => "Vulkan",
    .dx11 => "Direct3D 11",
};

const WindowId = interface.WindowId;
const WindowOptions = interface.WindowOptions;
const CursorShape = interface.CursorShape;
const Color = geometry.Color;
const Size = geometry.Size(f64);
const Point = geometry.Point(f64);

/// The generated `RECT` is a plain extern struct, so width/height are computed
/// here rather than through a hand-written facade method.
fn rectWidth(r: *const win32.RECT) i32 {
    return r.right - r.left;
}

fn rectHeight(r: *const win32.RECT) i32 {
    return r.bottom - r.top;
}

/// Longest window title, in bytes. Stored inline so no allocation happens
/// after initialization; the buffer carries one extra byte for the NUL that
/// `SetWindowTextW`'s UTF-16 conversion does not need.
pub const title_bytes_max: usize = 255;

pub const Window = struct {
    allocator: std.mem.Allocator,
    plat: *platform.WindowsPlatform,
    hinstance: win32.HINSTANCE,
    hwnd: win32.HWND = null,

    /// Contract-pinned fields: shared code reads these directly.
    size: Size,
    scale_factor: f64,

    /// Logical client dimensions, mirroring `size` (the Linux backend keeps
    /// the same pairing). The renderer multiplies by `scale_factor` to get
    /// the physical swapchain extent; the HWND's client rect is physical and
    /// is converted in `syncSizeFromHwnd`.
    width_px: u32,
    height_px: u32,

    window_id: WindowId = .invalid,
    closed: bool = false,
    needs_redraw: bool = true,
    has_presented_frame: bool = false,

    renderer: Renderer,
    background_color: Color,
    clear_color: Color,
    glass_style: interface.GlassStyle = .none,
    dark_appearance: bool = false,

    // Scene / atlas pointers published by the framework before each frame.
    scene: ?*const scene_mod.Scene = null,
    text_atlas: ?*const text_mod.Atlas = null,
    last_atlas_generation: u32 = 0,
    svg_atlas: ?*const text_mod.Atlas = null,
    last_svg_atlas_generation: u32 = 0,
    image_atlas: ?*const text_mod.Atlas = null,
    last_image_atlas_generation: u32 = 0,

    // Input state.
    mouse_position: Point = .{ .x = 0, .y = 0 },
    mouse_inside: bool = false,
    pressed_button: ?input.MouseButton = null,
    mouse_buttons: u8 = 0,
    char_buffer: win_input.CharBuffer = .{},
    cursor_shape: ?CursorShape = null,
    tracking_mouse_leave: bool = false,

    // Title storage.
    title_buf: [title_bytes_max + 1]u8 = @splat(0),
    title_len: usize = 0,

    // Size hints, in logical pixels; applied in WM_GETMINMAXINFO.
    min_size: ?Size = null,
    max_size: ?Size = null,

    // IME bridge state. Services are deferred (`capabilities.ime = false`),
    // but the contract still requires these accessors to be usable.
    marked_text: []const u8 = "",
    marked_text_buffer: [256]u8 = undefined,
    inserted_text: []const u8 = "",
    inserted_text_buffer: [256]u8 = undefined,
    ime_cursor_rect: geometry.RectF = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1, .height = 20 } },

    // Callbacks.
    on_input: ?InputCallback = null,
    on_render: ?RenderCallback = null,
    on_close: ?CloseCallback = null,
    on_resize: ?ResizeCallback = null,
    on_post_input: ?PostInputCallback = null,
    user_data: ?*anyopaque = null,

    // GPU timing (reported to the profiler at the start of the next frame).
    last_gpu_submit_ns: u64 = 0,
    last_atlas_upload_ns: u64 = 0,

    pub const InputCallback = *const fn (*Window, input.InputEvent) bool;
    pub const RenderCallback = *const fn (*Window) void;
    pub const CloseCallback = *const fn (*Window) bool;
    pub const ResizeCallback = *const fn (*Window, f64, f64) void;
    pub const PostInputCallback = *const fn (*Window) void;

    const Self = @This();

    // =========================================================================
    // Lifecycle
    // =========================================================================

    pub fn init(
        allocator: std.mem.Allocator,
        plat: *platform.WindowsPlatform,
        options: *const WindowOptions,
    ) !*Self {
        std.debug.assert(@intFromPtr(plat) != 0);
        std.debug.assert(options.width >= 1);
        std.debug.assert(options.height >= 1);
        std.debug.assert(options.title.len <= title_bytes_max);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const initial_scale = plat.primaryScaleFactor();
        self.* = .{
            .allocator = allocator,
            .plat = plat,
            .hinstance = plat.hinstance,
            .size = .{ .width = options.width, .height = options.height },
            .scale_factor = initial_scale,
            .width_px = @intFromFloat(@round(options.width)),
            .height_px = @intFromFloat(@round(options.height)),
            .renderer = Renderer.init(allocator),
            .background_color = options.background_color,
            .clear_color = options.clearColor(),
            .glass_style = options.glass_style,
            .min_size = options.min_size,
            .max_size = options.max_size,
        };
        self.setTitle(options.title);

        // Register before the HWND exists: WM_NCCREATE needs a live `*Window`
        // to stash in GWLP_USERDATA, and every later failure unwinds through
        // this one registration.
        self.window_id = try plat.registerWindow(self);
        errdefer {
            plat.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }

        try self.createHwnd(options);

        // The window's real DPI can differ from the system default (the HWND
        // lands on whichever monitor the default placement picks), and the
        // requested logical size can exceed the monitor's logical work area,
        // which the OS resolves by silently rescaling the created window.
        // Adopt the real DPI, cap the request to the work area, and re-apply
        // it so the client area is deterministic before the GPU resources are
        // sized — a stale size here would leave the swapchain and the client
        // area disagreeing.
        const dpi = win32.GetDpiForWindow(self.hwnd);
        if (dpi > 0) {
            self.scale_factor = @as(f64, @floatFromInt(dpi)) /
                @as(f64, @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI));
        }
        const work = self.workAreaLogical();
        self.width_px = @intFromFloat(@round(@min(options.width, work.width)));
        self.height_px = @intFromFloat(@round(@min(options.height, work.height)));
        self.applyLogicalSize();
        self.syncSizeFromHwnd();

        try self.renderer.initWithWin32Surface(
            @ptrCast(self.hinstance.?),
            @ptrCast(self.hwnd.?),
            self.width_px,
            self.height_px,
            self.scale_factor,
            &options.limits.scene,
        );
        errdefer self.renderer.deinit();

        if (options.centered) self.center();

        _ = win32.ShowWindow(self.hwnd, @bitCast(win32.SW_SHOW));
        _ = win32.UpdateWindow(self.hwnd);
        plat.setActiveWindowId(self.window_id);
        self.requestRender();

        std.debug.assert(self.window_id.isValid());
        std.debug.assert(self.hwnd != null);
        return self;
    }

    /// Create the HWND with the current logical size converted to physical
    /// pixels at the provisional scale. `lpParam` carries `self` into
    /// `WM_NCCREATE`.
    fn createHwnd(self: *Self, options: *const WindowOptions) !void {
        var rect = clientRectForSize(self.width_px, self.height_px, self.scale_factor);
        _ = win32.AdjustWindowRectEx(&rect, @bitCast(win32.WS_OVERLAPPEDWINDOW), 0, .{});

        const title_w = try utf8ToWideZ(self.allocator, options.title);
        defer self.allocator.free(title_w);

        const hwnd = win32.CreateWindowExW(
            @bitCast(win32.WS_EX_APPWINDOW),
            win32ClassName(),
            title_w.ptr,
            @bitCast(win32.WS_OVERLAPPEDWINDOW),
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            rectWidth(&rect),
            rectHeight(&rect),
            null,
            null,
            self.hinstance,
            @ptrCast(self),
        );
        if (hwnd == null) return error.WindowCreationFailed;
        self.hwnd = hwnd;
    }

    pub fn deinit(self: *Self) void {
        if (self.window_id.isValid()) {
            self.plat.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }
        self.closed = true;
        self.renderer.deinit();

        // DestroyWindow synchronously sends WM_DESTROY; GWLP_USERDATA is
        // cleared first so no stale message can reach a dead `self`.
        if (self.hwnd) |hwnd| {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
            _ = win32.DestroyWindow(hwnd);
            self.hwnd = null;
        }
        self.allocator.destroy(self);
    }

    // =========================================================================
    // Geometry
    // =========================================================================

    pub fn width(self: *const Self) u32 {
        return @intFromFloat(self.size.width);
    }

    pub fn height(self: *const Self) u32 {
        return @intFromFloat(self.size.height);
    }

    pub fn getSize(self: *const Self) Size {
        return self.size;
    }

    pub fn getScaleFactor(self: *const Self) f64 {
        return self.scale_factor;
    }

    /// Adopt the physical client rect from the HWND and derive logical size.
    fn syncSizeFromHwnd(self: *Self) void {
        const hwnd = self.hwnd orelse return;
        var rect: win32.RECT = undefined;
        if (win32.GetClientRect(hwnd, &rect) == 0) return;

        const w_px: u32 = @intCast(@max(rectWidth(&rect), 0));
        const h_px: u32 = @intCast(@max(rectHeight(&rect), 0));
        if (w_px == 0 or h_px == 0) return;

        const s = @max(self.scale_factor, 0.01);
        self.width_px = @intFromFloat(@round(@as(f64, @floatFromInt(w_px)) / s));
        self.height_px = @intFromFloat(@round(@as(f64, @floatFromInt(h_px)) / s));
        self.size = .{
            .width = @floatFromInt(self.width_px),
            .height = @floatFromInt(self.height_px),
        };
    }

    /// Outer rect (pre-`AdjustWindowRectEx`) whose client area is
    /// `w`×`h` logical pixels at `scale`.
    fn clientRectForSize(w: u32, h: u32, scale: f64) win32.RECT {
        const s = @max(scale, 0.01);
        return .{
            .left = 0,
            .top = 0,
            .right = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * s)),
            .bottom = @intFromFloat(@round(@as(f64, @floatFromInt(h)) * s)),
        };
    }

    /// Resize the HWND so its client area matches the current logical size at
    /// the current scale. Used when the provisional creation scale turns out
    /// to differ from the creating monitor's real DPI.
    fn applyLogicalSize(self: *Self) void {
        const hwnd = self.hwnd orelse return;
        var rect = clientRectForSize(self.width_px, self.height_px, self.scale_factor);
        _ = win32.AdjustWindowRectEx(&rect, @bitCast(win32.WS_OVERLAPPEDWINDOW), 0, .{});
        _ = win32.SetWindowPos(
            hwnd,
            null,
            0,
            0,
            rectWidth(&rect),
            rectHeight(&rect),
            .{ .NOMOVE = 1, .NOZORDER = 1, .NOACTIVATE = 1 },
        );
    }

    /// The work area of the monitor the HWND sits on, in logical pixels.
    /// `SPI_GETWORKAREA` answers for the primary monitor in physical units;
    /// that is the same monitor a `CW_USEDEFAULT` placement picks on single-
    /// display setups, and the cap only ever shrinks oversized requests.
    fn workAreaLogical(self: *Self) Size {
        var work: win32.RECT = undefined;
        if (win32.SystemParametersInfoW(
            win32.SPI_GETWORKAREA,
            0,
            @ptrCast(&work),
            .{},
        ) == 0 or rectWidth(&work) <= 0 or rectHeight(&work) <= 0) {
            // No work area answer: leave the request uncapped.
            return .{ .width = std.math.floatMax(f64), .height = std.math.floatMax(f64) };
        }
        const s = @max(self.scale_factor, 0.01);
        return .{
            .width = @as(f64, @floatFromInt(rectWidth(&work))) / s,
            .height = @as(f64, @floatFromInt(rectHeight(&work))) / s,
        };
    }

    fn center(self: *Self) void {
        const hwnd = self.hwnd orelse return;
        var wr: win32.RECT = undefined;
        if (win32.GetWindowRect(hwnd, &wr) == 0) return;

        var work: win32.RECT = undefined;
        if (win32.SystemParametersInfoW(
            win32.SPI_GETWORKAREA,
            0,
            @ptrCast(&work),
            .{},
        ) == 0 or rectWidth(&work) <= 0 or rectHeight(&work) <= 0) {
            work = .{
                .left = 0,
                .top = 0,
                .right = win32.GetSystemMetrics(win32.SM_CXSCREEN),
                .bottom = win32.GetSystemMetrics(win32.SM_CYSCREEN),
            };
        }

        const x = work.left + @divTrunc(rectWidth(&work) - rectWidth(&wr), 2);
        const y = work.top + @divTrunc(rectHeight(&work) - rectHeight(&wr), 2);
        _ = win32.SetWindowPos(
            hwnd,
            null,
            x,
            y,
            0,
            0,
            .{ .NOSIZE = 1, .NOZORDER = 1, .NOACTIVATE = 1 },
        );
    }

    /// Rebuild the swapchain for a new physical size / scale and notify the
    /// application when the logical size actually changed.
    fn applyResize(self: *Self) void {
        const old_w = self.size.width;
        const old_h = self.size.height;
        self.syncSizeFromHwnd();
        if (self.width_px == 0 or self.height_px == 0) return;

        self.renderer.resize(self.width_px, self.height_px, self.scale_factor);
        self.needs_redraw = true;
        if (old_w != self.size.width or old_h != self.size.height) {
            if (self.on_resize) |callback| callback(self, self.size.width, self.size.height);
        }
    }

    // =========================================================================
    // Contract surface
    // =========================================================================

    pub fn getWindowId(self: *const Self) WindowId {
        return self.window_id;
    }

    pub fn getPlatform(self: *Self) *platform.WindowsPlatform {
        std.debug.assert(@intFromPtr(self.plat) != 0);
        return self.plat;
    }

    pub fn setTitle(self: *Self, new_title: []const u8) void {
        std.debug.assert(self.title_buf.len == title_bytes_max + 1);
        const len = @min(new_title.len, title_bytes_max);
        @memcpy(self.title_buf[0..len], new_title[0..len]);
        @memset(self.title_buf[len..], 0);
        self.title_len = len;

        if (self.hwnd) |hwnd| {
            const wide = utf8ToWideZ(self.allocator, self.title_buf[0..len]) catch return;
            defer self.allocator.free(wide);
            _ = win32.SetWindowTextW(hwnd, wide.ptr);
        }
    }

    pub fn setBackgroundColor(self: *Self, color: Color) void {
        self.background_color = color;
        self.clear_color = if (self.glass_style.needsTransparentClear()) Color.transparent else color;
        self.requestRender();
    }

    /// Record the requested appearance. Win32 dark-mode titlebars are not
    /// toggled in this first pass; the value is retained like Linux's
    /// advisory flag.
    pub fn setAppearance(self: *Self, dark: bool) void {
        self.dark_appearance = dark;
    }

    pub fn getClearColor(self: *const Self) Color {
        return self.clear_color;
    }

    pub fn getMousePosition(self: *const Self) Point {
        return self.mouse_position;
    }

    pub fn isMouseInside(self: *const Self) bool {
        return self.mouse_inside;
    }

    pub fn focus(self: *Self) void {
        const hwnd = self.hwnd orelse return;
        _ = win32.SetForegroundWindow(hwnd);
        _ = win32.BringWindowToTop(hwnd);
        _ = win32.SetFocus(hwnd);
        self.plat.setActiveWindowId(self.window_id);
    }

    /// Programmatic close. The veto callback can decline; otherwise the
    /// window is marked closed and left registered for the owner to reclaim
    /// from the loop-turn hook, exactly like the other native backends.
    pub fn close(self: *Self) void {
        if (self.closed) return;
        if (self.on_close) |callback| {
            if (!callback(self)) return;
        }
        self.markClosed();
    }

    fn markClosed(self: *Self) void {
        self.closed = true;
        self.needs_redraw = false;
        if (self.plat.getActiveWindowId() == self.window_id) {
            self.plat.setActiveWindowId(null);
        }
    }

    pub fn isClosed(self: *const Self) bool {
        return self.closed;
    }

    pub fn requestRender(self: *Self) void {
        if (self.closed) return;
        self.needs_redraw = true;
    }

    /// Whether a frame is queued. Used by the platform's loop pacing.
    pub fn needsRedraw(self: *const Self) bool {
        return self.needs_redraw;
    }

    /// Arm a one-shot timer that requests a frame after `delay_ms`.
    pub fn requestRenderAfter(self: *Self, delay_ms: u32) void {
        std.debug.assert(delay_ms <= interface.render_delay_ms_max);
        if (self.closed) return;
        if (delay_ms == 0) {
            self.requestRender();
            return;
        }
        const hwnd = self.hwnd orelse return;
        _ = win32.SetTimer(hwnd, win32.TIMER_RENDER_ID, delay_ms, null);
    }

    pub fn setCursorShape(self: *Self, shape: CursorShape) void {
        if (self.cursor_shape) |current| {
            if (current == shape) return;
        }
        const cursor = loadCursor(shape) orelse return;
        _ = win32.SetCursor(cursor);
        self.cursor_shape = shape;
    }

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
    // IME bridge (state only in this pass)
    // =========================================================================

    pub fn setMarkedText(self: *Self, text: []const u8) void {
        self.marked_text = copyToBuffer(&self.marked_text_buffer, text);
    }

    pub fn clearMarkedText(self: *Self) void {
        self.marked_text = "";
    }

    pub fn setInsertedText(self: *Self, text: []const u8) void {
        self.inserted_text = copyToBuffer(&self.inserted_text_buffer, text);
    }

    pub fn hasMarkedText(self: *const Self) bool {
        return self.marked_text.len > 0;
    }

    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        self.ime_cursor_rect = geometry.RectF.init(x, y, w, h);
    }

    // =========================================================================
    // Callbacks / user data
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
        if (self.user_data) |ptr| return @ptrCast(@alignCast(ptr));
        return null;
    }

    // =========================================================================
    // Input dispatch
    // =========================================================================

    pub fn handleInput(self: *Self, event: input.InputEvent) bool {
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

        switch (event) {
            .mouse_down => |m| self.pressed_button = m.button,
            .mouse_up => self.pressed_button = null,
            else => {},
        }

        var handled = false;
        if (self.on_input) |callback| handled = callback(self, event);
        if (self.on_post_input) |post| post(self);
        self.requestRender();
        return handled;
    }

    // =========================================================================
    // Frame
    // =========================================================================

    /// Present one frame. Called by `WindowsPlatform.renderOpenWindows` on the
    /// UI thread after input has been drained for this turn.
    pub fn renderFrame(self: *Self) void {
        if (self.closed) return;
        if (!self.needs_redraw and self.has_presented_frame) return;
        self.needs_redraw = false;

        if (self.on_render) |callback| callback(self);
        self.renderer.setClearColor(self.getClearColor());
        self.stageAtlasUploads();

        const render_io = std.Io.Threaded.global_single_threaded.io();
        const gpu_start = std.Io.Timestamp.now(render_io, .awake);

        if (self.scene) |scene| {
            self.renderer.render(scene);
        } else {
            var empty_scene = scene_mod.Scene.initEmpty(self.allocator);
            defer empty_scene.deinit();
            self.renderer.render(&empty_scene);
        }
        self.has_presented_frame = true;

        const gpu_end = std.Io.Timestamp.now(render_io, .awake);
        const gpu_ns: i96 = gpu_start.durationTo(gpu_end).toNanoseconds();
        std.debug.assert(gpu_ns >= 0);
        self.last_gpu_submit_ns = @intCast(gpu_ns);
        self.last_atlas_upload_ns = 0;
    }

    fn stageAtlasUploads(self: *Self) void {
        if (self.text_atlas) |atlas| {
            if (atlas.generation != self.last_atlas_generation) {
                self.renderer.stageTextAtlas(atlas.data, atlas.size, atlas.size, toDirty(atlas.getDirtyRegion()));
                self.last_atlas_generation = atlas.generation;
            }
        }
        if (self.svg_atlas) |atlas| {
            const needs_upload = atlas.generation != self.last_svg_atlas_generation or
                (self.last_svg_atlas_generation == 0 and self.renderer.svg_atlas.view == null);
            if (needs_upload) {
                self.renderer.stageSvgAtlas(atlas.data, atlas.size, atlas.size, toDirty(atlas.getDirtyRegion()));
                self.last_svg_atlas_generation = atlas.generation;
            }
        }
        if (self.image_atlas) |atlas| {
            const needs_upload = atlas.generation != self.last_image_atlas_generation or
                (self.last_image_atlas_generation == 0 and self.renderer.image_atlas.view == null);
            if (needs_upload) {
                self.renderer.stageImageAtlas(atlas.data, atlas.size, atlas.size, toDirty(atlas.getDirtyRegion()));
                self.last_image_atlas_generation = atlas.generation;
            }
        }
    }

    pub fn getRendererCapabilities(self: *const Self) interface.RendererCapabilities {
        _ = self;
        return .{
            .max_texture_size = 4096,
            .msaa = true,
            .msaa_sample_count = 4,
            .unified_memory = false,
            .name = renderer_name,
        };
    }

    // =========================================================================
    // WndProc (static, forwarded from the module-level procedure)
    // =========================================================================

    fn handleClose(self: *Self) void {
        self.close();
    }

    fn handleResize(self: *Self) void {
        if (self.closed) return;
        self.applyResize();
        self.requestRender();
    }

    fn handleDpiChanged(self: *Self, suggested: *const win32.RECT) void {
        // Adopt the new scale BEFORE resizing: `SetWindowPos` raises WM_SIZE,
        // and `applyResize` derives the logical size from the physical client
        // rect using `scale_factor`.
        const dpi = win32.GetDpiForWindow(self.hwnd);
        if (dpi > 0) {
            self.scale_factor = @as(f64, @floatFromInt(dpi)) /
                @as(f64, @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI));
        }
        if (self.hwnd) |hwnd| {
            _ = win32.SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                rectWidth(suggested),
                rectHeight(suggested),
                .{ .NOZORDER = 1, .NOACTIVATE = 1 },
            );
        }
        self.applyResize();
        self.requestRender();
    }

    fn handleGetMinMaxInfo(self: *Self, mmi: *win32.MINMAXINFO) void {
        const s = @max(self.scale_factor, 0.01);
        if (self.min_size) |min| {
            var r = win32.RECT{
                .left = 0,
                .top = 0,
                .right = @intFromFloat(@round(min.width * s)),
                .bottom = @intFromFloat(@round(min.height * s)),
            };
            _ = win32.AdjustWindowRectEx(&r, @bitCast(win32.WS_OVERLAPPEDWINDOW), 0, .{});
            mmi.ptMinTrackSize = .{ .x = rectWidth(&r), .y = rectHeight(&r) };
        }
        if (self.max_size) |max| {
            var r = win32.RECT{
                .left = 0,
                .top = 0,
                .right = @intFromFloat(@round(max.width * s)),
                .bottom = @intFromFloat(@round(max.height * s)),
            };
            _ = win32.AdjustWindowRectEx(&r, @bitCast(win32.WS_OVERLAPPEDWINDOW), 0, .{});
            mmi.ptMaxTrackSize = .{ .x = rectWidth(&r), .y = rectHeight(&r) };
        }
    }

    fn handlePaint(self: *Self) void {
        var ps: win32.PAINTSTRUCT = undefined;
        _ = win32.BeginPaint(self.hwnd, &ps);
        _ = win32.EndPaint(self.hwnd, &ps);
        // Vulkan owns the client area; WM_PAINT only exists to validate the
        // region. A redraw request keeps the loop's next frame honest.
        self.requestRender();
    }

    fn handleMouseMove(self: *Self, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
        if (!self.mouse_inside) {
            self.mouse_inside = true;
            _ = self.handleInput(.{ .mouse_entered = self.mouseEvent(.left, wparam) });
        }
        if (!self.tracking_mouse_leave) {
            var tme = win32.TRACKMOUSEEVENT{
                .cbSize = @sizeOf(win32.TRACKMOUSEEVENT),
                .dwFlags = win32.TME_LEAVE,
                .hwndTrack = @ptrCast(self.hwnd),
                .dwHoverTime = 0,
            };
            self.tracking_mouse_leave = win32.TrackMouseEvent(&tme) != 0;
        }

        const pos = win_input.logicalPoint(
            win_input.mouseXFromLParam(lparam),
            win_input.mouseYFromLParam(lparam),
            self.scale_factor,
        );
        const button = self.pressed_button orelse .left;
        const event: input.InputEvent = if (self.pressed_button != null)
            .{ .mouse_dragged = .{
                .position = pos,
                .button = button,
                .click_count = 1,
                .modifiers = win_input.modifiersFromMouseWParam(wparam),
            } }
        else
            .{ .mouse_moved = .{
                .position = pos,
                .button = button,
                .click_count = 1,
                .modifiers = win_input.modifiersFromMouseWParam(wparam),
            } };
        _ = self.handleInput(event);
    }

    fn handleMouseButton(
        self: *Self,
        msg: win32.UINT,
        wparam: win32.WPARAM,
        lparam: win32.LPARAM,
    ) void {
        const down = msg == win32.WM_LBUTTONDOWN or msg == win32.WM_RBUTTONDOWN or msg == win32.WM_MBUTTONDOWN;
        const button: input.MouseButton = switch (msg) {
            win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP => .left,
            win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP => .right,
            else => .middle,
        };
        const bit: u8 = @as(u8, 1) << @intCast(@backingInt(button));
        if (down) {
            self.mouse_buttons |= bit;
            _ = win32.SetCapture(self.hwnd);
        } else {
            self.mouse_buttons &= ~bit;
            if (self.mouse_buttons == 0) _ = win32.ReleaseCapture();
        }

        const pos = win_input.logicalPoint(
            win_input.mouseXFromLParam(lparam),
            win_input.mouseYFromLParam(lparam),
            self.scale_factor,
        );
        const ev = input.MouseEvent{
            .position = pos,
            .button = button,
            .click_count = 1,
            .modifiers = win_input.modifiersFromMouseWParam(wparam),
        };
        _ = self.handleInput(if (down)
            .{ .mouse_down = ev }
        else
            .{ .mouse_up = ev });
    }

    fn handleMouseWheel(self: *Self, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
        var pt = win32.POINT{
            .x = win_input.mouseXFromLParam(lparam),
            .y = win_input.mouseYFromLParam(lparam),
        };
        _ = win32.ScreenToClient(self.hwnd, &pt);
        const pos = win_input.logicalPoint(
            @intCast(pt.x),
            @intCast(pt.y),
            self.scale_factor,
        );
        const raw = win_input.wheelDeltaFromWParam(wparam);
        const delta = win_input.scrollDelta(raw);
        const scroll = input.ScrollEvent{
            .position = pos,
            .delta = if (msg == win32.WM_MOUSEWHEEL)
                .{ .x = 0, .y = delta }
            else
                .{ .x = delta, .y = 0 },
            .modifiers = win_input.currentModifiers(),
        };
        _ = self.handleInput(.{ .scroll = scroll });
    }

    fn handleKey(self: *Self, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
        const down = msg == win32.WM_KEYDOWN or msg == win32.WM_SYSKEYDOWN;
        const extended = (lparam & (1 << 24)) != 0;
        const repeat = (lparam & (1 << 30)) != 0;
        const ev = input.KeyEvent{
            .key = win_input.keyTagFromVirtualKey(wparam, extended),
            .modifiers = win_input.currentModifiers(),
            .characters = null,
            .characters_ignoring_modifiers = null,
            .is_repeat = repeat,
        };
        _ = self.handleInput(if (down) .{ .key_down = ev } else .{ .key_up = ev });
    }

    fn handleChar(self: *Self, wparam: win32.WPARAM) void {
        if (self.char_buffer.pushUtf16(@truncate(wparam))) {
            _ = self.handleInput(.{ .text_input = .{ .text = self.char_buffer.slice() } });
        }
    }

    fn mouseEvent(self: *Self, button: input.MouseButton, wparam: win32.WPARAM) input.MouseEvent {
        return .{
            .position = self.mouse_position,
            .button = button,
            .click_count = 1,
            .modifiers = win_input.modifiersFromMouseWParam(wparam),
        };
    }
};

// =============================================================================
// Window class
// =============================================================================

/// Per-process window class name.
pub fn win32ClassName() [*:0]const u16 {
    return comptime std.unicode.utf8ToUtf16LeStringLiteral("gooey.Window");
}

/// Register the window class. A duplicate registration fails harmlessly.
pub fn registerWindowClass(hinstance: win32.HINSTANCE) bool {
    // WNDCLASSEXW takes the generated bindings' WNDPROC (opaque `*HWND`
    // handles); the trampoline adapts gooey's optional-handle wndProc.
    const cls = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{ .HREDRAW = 1, .VREDRAW = 1 },
        .lpfnWndProc = wndProcTrampoline,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = @ptrCast(hinstance),
        .hIcon = null,
        .hCursor = loadCursor(.default) orelse null,
        .hbrBackground = null, // Vulkan owns the client area.
        .lpszMenuName = null,
        .lpszClassName = win32ClassName(),
        .hIconSm = null,
    };
    return win32.RegisterClassExW(@ptrCast(&cls)) != 0;
}

/// Adapts the generated WNDPROC signature (opaque handles) to gooey's
/// optional-handle `wndProc`.
fn wndProcTrampoline(
    hwnd: wam_foundation.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    return wndProc(@ptrCast(hwnd), msg, wparam, lparam);
}

// =============================================================================
// Static WndProc
// =============================================================================

fn wndProc(
    hwnd: win32.HWND,
    msg: win32.UINT,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    if (msg == win32.WM_NCCREATE) {
        const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const self: *Window = @ptrCast(@alignCast(cs.lpCreateParams.?));
        self.hwnd = hwnd;
        _ = win32.SetWindowLongPtrW(
            hwnd,
            win32.GWLP_USERDATA,
            @bitCast(@intFromPtr(self)),
        );
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self_ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (self_ptr == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Window = @ptrFromInt(@as(usize, @bitCast(self_ptr)));

    // Messages arriving after the window was marked closed still need the
    // default handling (destroy, etc.) but must not run application code.
    if (self.closed and msg != win32.WM_DESTROY) {
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    return switch (msg) {
        win32.WM_CLOSE => blk: {
            self.handleClose();
            break :blk 0;
        },
        win32.WM_DESTROY => blk: {
            // A host-initiated destroy (e.g. session shutdown) still marks the
            // window closed so the owner reclaims it. Do not unregister here:
            // `Window.deinit` owns that transition.
            if (!self.closed) self.markClosed();
            self.hwnd = null;
            break :blk 0;
        },
        win32.WM_SIZE => blk: {
            self.handleResize();
            break :blk 0;
        },
        win32.WM_DPICHANGED => blk: {
            const suggested: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.handleDpiChanged(suggested);
            break :blk 0;
        },
        win32.WM_GETMINMAXINFO => blk: {
            const mmi: *win32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.handleGetMinMaxInfo(mmi);
            break :blk 0;
        },
        win32.WM_PAINT => blk: {
            self.handlePaint();
            break :blk 0;
        },
        win32.WM_ERASEBKGND => 1,
        win32.WM_SETCURSOR => blk: {
            if (@as(win32.LPARAM, @truncate(lparam)) == win32.HTCLIENT) {
                if (self.cursor_shape) |shape| _ = loadCursor(shape);
                break :blk 1;
            }
            break :blk win32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        win32.WM_TIMER => blk: {
            if (wparam == win32.TIMER_RENDER_ID) {
                _ = win32.KillTimer(hwnd, win32.TIMER_RENDER_ID);
                self.requestRender();
            }
            break :blk 0;
        },
        win32.WM_SETFOCUS, win32.WM_KILLFOCUS => blk: {
            self.plat.setActiveWindowId(if (msg == win32.WM_SETFOCUS) self.window_id else null);
            self.requestRender();
            break :blk 0;
        },
        win32.WM_MOUSEMOVE => blk: {
            self.handleMouseMove(wparam, lparam);
            break :blk 0;
        },
        win32.WM_MOUSELEAVE => blk: {
            self.tracking_mouse_leave = false;
            self.mouse_inside = false;
            _ = self.handleInput(.{ .mouse_exited = self.mouseEvent(.left, wparam) });
            break :blk 0;
        },
        win32.WM_LBUTTONDOWN,
        win32.WM_RBUTTONDOWN,
        win32.WM_MBUTTONDOWN,
        win32.WM_LBUTTONUP,
        win32.WM_RBUTTONUP,
        win32.WM_MBUTTONUP,
        => blk: {
            self.handleMouseButton(msg, wparam, lparam);
            break :blk 0;
        },
        win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => blk: {
            self.handleMouseWheel(msg, wparam, lparam);
            break :blk 0;
        },
        win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYUP => blk: {
            self.handleKey(msg, wparam, lparam);
            break :blk 0;
        },
        win32.WM_CHAR => blk: {
            self.handleChar(wparam);
            break :blk 0;
        },
        else => win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    };
}

// =============================================================================
// Helpers
// =============================================================================

var cursor_cache = struct {
    arrow: ?win32.HCURSOR = null,
    ibeam: ?win32.HCURSOR = null,
    hand: ?win32.HCURSOR = null,
}{};

fn loadCursor(shape: CursorShape) ?win32.HCURSOR {
    switch (shape) {
        .default => {
            if (cursor_cache.arrow == null) {
                cursor_cache.arrow = win32.LoadCursorW(null, win32.IDC_ARROW);
            }
            return cursor_cache.arrow;
        },
        .text => {
            if (cursor_cache.ibeam == null) {
                cursor_cache.ibeam = win32.LoadCursorW(null, win32.IDC_IBEAM);
            }
            return cursor_cache.ibeam;
        },
        .pointer => {
            if (cursor_cache.hand == null) {
                cursor_cache.hand = win32.LoadCursorW(null, win32.IDC_HAND);
            }
            return cursor_cache.hand;
        },
    }
}

fn utf8ToWideZ(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

fn copyToBuffer(buffer: *[256]u8, text: []const u8) []const u8 {
    const n = @min(text.len, buffer.len);
    @memcpy(buffer[0..n], text[0..n]);
    return buffer[0..n];
}

/// The dirty-rect type of the selected renderer's atlas module. Both atlas
/// modules define an identical `DirtyRegion`; only the selected one matches
/// the renderer's `stage*Atlas` signature.
const AtlasDirtyRegion = if (build_options.gpu_backend == .dx11)
    dx11_atlas.DirtyRegion
else
    vk_atlas.DirtyRegion;

fn toDirty(region: ?@import("../../text/atlas.zig").DirtyRegion) ?AtlasDirtyRegion {
    const d = region orelse return null;
    return .{
        .x = @intCast(d.x),
        .y = @intCast(d.y),
        .width = @intCast(d.width),
        .height = @intCast(d.height),
    };
}

// =============================================================================
// Tests
// =============================================================================

test "WS_OVERLAPPEDWINDOW is the documented composite style" {
    try std.testing.expectEqual(
        @as(u32, 0x00CF0000),
        @as(u32, @bitCast(win32.WS_OVERLAPPEDWINDOW)),
    );
}

test "rectWidth and rectHeight ignore the origin" {
    const r = win32.RECT{ .left = 10, .top = 20, .right = 110, .bottom = 220 };
    try std.testing.expectEqual(@as(i32, 100), rectWidth(&r));
    try std.testing.expectEqual(@as(i32, 200), rectHeight(&r));
}

test "GWLP_USERDATA is the SDK's -21" {
    try std.testing.expectEqual(@as(i32, -21), @backingInt(win32.GWLP_USERDATA));
}
