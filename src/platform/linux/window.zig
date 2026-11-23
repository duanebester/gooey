const std = @import("std");
const wayland = @import("wayland.zig");
const vk_renderer = @import("vk_renderer.zig");
const VulkanRenderer = vk_renderer.VulkanRenderer;
const shm_renderer = @import("shm_renderer.zig");
const ShmRenderer = shm_renderer.ShmRenderer;
const linux_backend = @import("../linux_backend.zig");
const LinuxPlatform = @import("platform.zig").LinuxPlatform;
const interface_mod = @import("../interface.zig");
const WindowId = interface_mod.WindowId;
const geometry = @import("../../geometry/geometry.zig");
const Size = geometry.Size(f64);
const input = @import("../../input/events.zig");
const linux_input = @import("input.zig");

const Allocator = std.mem.Allocator;
const WindowOptions = interface_mod.WindowOptions;
const limits_mod = @import("../../core/limits.zig");
const ResourceLimits = limits_mod.ResourceLimits;
const backend = @import("../../core/backend.zig");
const core_events = @import("../../core/events.zig");
const core_router = @import("../../core/router.zig");
const core_clipboard = @import("../../core/clipboard.zig");

pub const CoreBinding = struct {
    queue: *core_events.EventQueue,
    query: *const core_router.Query,
    context: *anyopaque,
    schedule_tick: *const fn (context: *anyopaque) void,
};

const use_cpu_renderer = switch (linux_backend.selected) {
    .wayland_vulkan => false,
    .wayland_cpu => true,
    .fbdev, .eve => @compileError("this backend does not use the Wayland window"),
};
const Renderer = if (use_cpu_renderer) ShmRenderer else VulkanRenderer;
const NativeSurface = if (use_cpu_renderer)
    shm_renderer.NativeSurface
else
    vk_renderer.NativeSurface;

pub const renderer_scale_max: f32 = if (use_cpu_renderer)
    @import("../cpu/renderer.zig").scale_factor_max
else
    std.math.floatMax(f32);

pub fn awakeTimeMs() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const now_ms = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    std.debug.assert(now_ms >= 0);
    return @intCast(now_ms);
}

const surface_listener = wayland.SurfaceListener{
    .enter = Window.surfaceEnter,
    .leave = Window.surfaceLeave,
    .preferred_buffer_scale = Window.surfacePreferredScale,
    .preferred_buffer_transform = Window.surfacePreferredTransform,
};

const fractional_scale_listener = wayland.FractionalScaleListener{
    .preferred_scale = Window.fractionalPreferredScale,
};

const decoration_listener = wayland.ZxdgToplevelDecorationV1Listener{
    .configure = Window.decorationConfigure,
};

const xdg_surface_listener = wayland.XdgSurfaceListener{
    .configure = Window.xdgSurfaceConfigure,
};

const toplevel_listener = wayland.XdgToplevelListener{
    .configure = Window.xdgToplevelConfigure,
    .close = Window.xdgToplevelClose,
    .configure_bounds = Window.xdgToplevelConfigureBounds,
    .wm_capabilities = Window.xdgToplevelWmCapabilities,
};

pub const Window = struct {
    allocator: Allocator,
    platform: *LinuxPlatform,

    wl_surface: ?*wayland.Surface = null,
    xdg_surface: ?*wayland.XdgSurface = null,
    xdg_toplevel: ?*wayland.XdgToplevel = null,
    decoration: ?*wayland.ZxdgToplevelDecorationV1 = null,
    viewport: ?*wayland.WpViewport = null,
    fractional_scale: ?*wayland.WpFractionalScaleV1 = null,

    width_px: u32 = 800,
    height_px: u32 = 600,
    size: Size = .{ .width = 800, .height = 600 },
    scale_factor: f64 = 1.0,
    configured: bool = false,
    closed: bool = false,

    window_id: WindowId = .invalid,

    pending_resize: bool = false,
    pending_width: u32 = 0,
    pending_height: u32 = 0,

    has_server_decorations: bool = false,

    renderer: Renderer,

    title_buf: [title_bytes_max + 1]u8 = undefined,
    title_len: usize = 0,

    marked_text: []const u8 = "",
    marked_text_buffer: []u8 = &.{},

    ime_active: bool = false,

    click_tracker: linux_input.ClickTracker = .{},

    pressed_button: ?input.MouseButton = null,

    on_close: ?CloseCallback = null,

    user_data: ?*anyopaque = null,

    core: ?CoreBinding = null,

    dark_appearance: bool = false,
    needs_redraw: bool = false,
    render_deadline_ms: ?i64 = null,

    pub const CloseCallback = *const fn (*Self) bool;

    const Self = @This();

    pub const title_bytes_max: usize = 255;

    pub fn init(allocator: Allocator, plat: *LinuxPlatform, options: *const WindowOptions) !*Self {
        std.debug.assert(options.width > 0);
        std.debug.assert(options.height > 0);

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = Self{
            .allocator = allocator,
            .platform = plat,
            .width_px = @intFromFloat(options.width),
            .height_px = @intFromFloat(options.height),
            .size = .{ .width = options.width, .height = options.height },
            .scale_factor = plat.getScaleFactor(),
            .renderer = .{},
        };
        self.storeTitle(options.title);
        self.marked_text_buffer = try allocator.alloc(u8, options.limits.text.preedit_bytes_max);
        errdefer allocator.free(self.marked_text_buffer);

        self.window_id = try plat.registerWindow(self);
        errdefer {
            plat.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }

        try self.createSurface(plat);
        errdefer self.destroySurface();

        try self.createToplevel(plat, options);
        errdefer {
            if (self.xdg_toplevel) |tl| wayland.xdgToplevelDestroy(tl);
            self.xdg_toplevel = null;
            if (self.xdg_surface) |xs| wayland.xdgSurfaceDestroy(xs);
            self.xdg_surface = null;
        }

        self.requestServerDecorations(plat);

        wayland.surfaceCommit(self.wl_surface.?);
        _ = wayland.wl_display_roundtrip(plat.display.?);

        errdefer {
            if (self.decoration) |dec| wayland.zxdgToplevelDecorationV1Destroy(dec);
            self.decoration = null;
        }

        self.createViewport(plat);
        errdefer {
            if (self.viewport) |vp| wayland.viewportDestroy(vp);
            self.viewport = null;
        }

        try self.mapWithRenderer(plat, options);

        plat.setActiveWindowId(self.window_id);

        std.debug.assert(self.window_id.isValid());
        std.debug.assert(self.wl_surface != null);
        return self;
    }

    fn storeTitle(self: *Self, title: []const u8) void {
        std.debug.assert(title.len <= title_bytes_max);
        const title_len = @min(title.len, title_bytes_max);
        @memcpy(self.title_buf[0..title_len], title[0..title_len]);
        self.title_buf[title_len] = 0;
        self.title_len = title_len;
        std.debug.assert(self.title_buf[self.title_len] == 0);
    }

    fn createSurface(self: *Self, plat: *LinuxPlatform) !void {
        std.debug.assert(self.wl_surface == null);
        const compositor = plat.getCompositor() orelse return error.NoCompositor;
        self.wl_surface = wayland.compositorCreateSurface(compositor) orelse
            return error.FailedToCreateSurface;

        _ = wayland.surfaceAddListener(self.wl_surface.?, &surface_listener, self);
        self.bindFractionalScale(plat);
        std.debug.assert(self.wl_surface != null);
    }

    fn destroySurface(self: *Self) void {
        if (self.fractional_scale) |fractional_scale| {
            wayland.fractionalScaleDestroy(fractional_scale);
        }
        self.fractional_scale = null;
        if (self.wl_surface) |s| wayland.surfaceDestroy(s);
        self.wl_surface = null;
        std.debug.assert(self.fractional_scale == null);
        std.debug.assert(self.wl_surface == null);
    }

    fn createToplevel(self: *Self, plat: *LinuxPlatform, options: *const WindowOptions) !void {
        std.debug.assert(self.wl_surface != null);
        std.debug.assert(self.xdg_surface == null);
        const xdg_wm_base = plat.getXdgWmBase() orelse return error.NoXdgWmBase;
        self.xdg_surface = wayland.xdgWmBaseGetXdgSurface(xdg_wm_base, self.wl_surface.?) orelse
            return error.FailedToCreateXdgSurface;
        errdefer {
            if (self.xdg_surface) |xs| wayland.xdgSurfaceDestroy(xs);
            self.xdg_surface = null;
        }

        _ = wayland.xdgSurfaceAddListener(self.xdg_surface.?, &xdg_surface_listener, self);

        self.xdg_toplevel = wayland.xdgSurfaceGetToplevel(self.xdg_surface.?) orelse
            return error.FailedToCreateToplevel;
        const toplevel = self.xdg_toplevel.?;

        _ = wayland.xdgToplevelAddListener(toplevel, &toplevel_listener, self);

        wayland.xdgToplevelSetTitle(toplevel, @ptrCast(&self.title_buf));
        wayland.xdgToplevelSetAppId(toplevel, "gooey");
        if (options.min_size) |min| {
            wayland.xdgToplevelSetMinSize(
                toplevel,
                @intFromFloat(min.width),
                @intFromFloat(min.height),
            );
        }
        if (options.max_size) |max| {
            wayland.xdgToplevelSetMaxSize(
                toplevel,
                @intFromFloat(max.width),
                @intFromFloat(max.height),
            );
        }
        std.debug.assert(self.xdg_toplevel != null);
    }

    fn requestServerDecorations(self: *Self, plat: *LinuxPlatform) void {
        std.debug.assert(self.xdg_toplevel != null);
        std.debug.assert(self.decoration == null);
        const manager = plat.getDecorationManager() orelse {
            std.debug.print(
                "WARNING: No decoration manager available - window will have no title bar!\n",
                .{},
            );
            std.debug.print(
                "Your compositor may not support xdg-decoration-unstable-v1 protocol.\n",
                .{},
            );
            return;
        };
        std.debug.print(
            "Decoration manager available, requesting server-side decorations...\n",
            .{},
        );
        self.decoration = wayland.zxdgDecorationManagerV1GetToplevelDecoration(
            manager,
            self.xdg_toplevel.?,
        );
        if (self.decoration) |dec| {
            _ = wayland.zxdgToplevelDecorationV1AddListener(dec, &decoration_listener, self);
            wayland.zxdgToplevelDecorationV1SetMode(dec, .server_side);
        }
    }

    fn createViewport(self: *Self, plat: *LinuxPlatform) void {
        std.debug.assert(self.wl_surface != null);
        std.debug.assert(self.viewport == null);
        const viewporter = plat.getViewporter() orelse {
            const scale_int: i32 = @intFromFloat(self.scale_factor);
            wayland.surfaceSetBufferScale(self.wl_surface.?, scale_int);
            return;
        };
        self.viewport = wayland.viewporterGetViewport(viewporter, self.wl_surface.?);
        if (self.viewport) |vp| {
            wayland.viewportSetDestination(vp, @intCast(self.width_px), @intCast(self.height_px));
        }
    }

    fn mapWithRenderer(self: *Self, plat: *LinuxPlatform, options: *const WindowOptions) !void {
        std.debug.assert(self.xdg_surface != null);
        std.debug.assert(self.wl_surface != null);
        wayland.xdgSurfaceSetWindowGeometry(
            self.xdg_surface.?,
            0,
            0,
            @intCast(self.width_px),
            @intCast(self.height_px),
        );

        wayland.surfaceCommit(self.wl_surface.?);
        _ = wayland.wl_display_roundtrip(plat.display.?);

        const renderer_scale = self.scale_factor;
        try self.initRenderer(plat, options);

        wayland.surfaceCommit(self.wl_surface.?);

        _ = wayland.wl_display_roundtrip(plat.display.?);

        if (self.scale_factor != renderer_scale) {
            self.renderer.resize(self.rendererViewport(&options.limits.window).size_px);
        }
    }

    fn bindFractionalScale(self: *Self, plat: *LinuxPlatform) void {
        std.debug.assert(self.wl_surface != null);
        std.debug.assert(self.fractional_scale == null);
        const manager = plat.getFractionalScaleManager() orelse return;
        if (plat.getViewporter() == null) return;
        const fractional_scale = wayland.fractionalScaleManagerGetFractionalScale(
            manager,
            self.wl_surface.?,
        ) orelse {
            std.log.warn("wp_fractional_scale_v1: no proxy; keeping integer scales", .{});
            return;
        };
        const added = wayland.fractionalScaleAddListener(
            fractional_scale,
            &fractional_scale_listener,
            self,
        );
        std.debug.assert(added);
        self.fractional_scale = fractional_scale;
    }

    fn initRenderer(self: *Self, plat: *LinuxPlatform, options: *const WindowOptions) !void {
        std.debug.assert(self.wl_surface != null);
        std.debug.assert(self.width_px > 0);
        std.debug.assert(self.height_px > 0);
        const native: NativeSurface = if (use_cpu_renderer) .{
            .shm = plat.getShm() orelse return error.NoShm,
            .surface = self.wl_surface.?,
        } else .{
            .display = @ptrCast(plat.getDisplay() orelse return error.NoDisplay),
            .surface = self.wl_surface.?,
        };
        const viewport = self.rendererViewport(&options.limits.window);
        const render_limits = backend.RenderLimits.fromResourceLimits(&options.limits);
        try self.renderer.initInPlace(&.{
            .native = @ptrCast(@constCast(&native)),
            .size_px = viewport.size_px,
            .scale_factor = viewport.scale_factor,
        }, &render_limits);
    }

    fn rendererViewport(
        self: *const Self,
        window: *const limits_mod.WindowLimits,
    ) backend.Viewport {
        std.debug.assert(self.width_px > 0);
        std.debug.assert(self.scale_factor > 0);
        return backend.Viewport.fitLogical(
            @floatFromInt(self.width_px),
            @floatFromInt(self.height_px),
            @min(@as(f32, @floatCast(self.scale_factor)), renderer_scale_max),
            window,
        );
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

        if (self.window_id.isValid()) {
            self.platform.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }
        if (self.platform.active_window == self) {
            self.platform.reelectActiveWindow();
        }
        if (self.platform.touch_window == self) self.platform.touch_window = null;
        std.debug.assert(self.platform.active_window != self);

        if (self.viewport) |vp| {
            wayland.viewportDestroy(vp);
            self.viewport = null;
        }

        self.renderer.deinit();

        if (self.decoration) |dec| wayland.zxdgToplevelDecorationV1Destroy(dec);
        if (self.xdg_toplevel) |tl| wayland.xdgToplevelDestroy(tl);
        if (self.xdg_surface) |xs| wayland.xdgSurfaceDestroy(xs);
        self.destroySurface();

        std.debug.assert(!self.window_id.isValid());
        self.allocator.free(self.marked_text_buffer);
        self.allocator.destroy(self);
    }

    pub fn close(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

        if (self.closed) return;

        if (self.on_close) |callback| {
            if (!callback(self)) return;
        }

        self.markClosed();

        std.debug.assert(self.isClosed());
    }

    fn markClosed(self: *Self) void {
        std.debug.assert(!self.closed);
        std.debug.assert(self.window_id.isValid());

        self.closed = true;

        if (self.platform.active_window == self) self.platform.reelectActiveWindow();

        std.debug.assert(self.closed);
        std.debug.assert(self.platform.active_window != self);
    }

    pub fn isClosed(self: *const Self) bool {
        return self.closed;
    }

    pub fn setCursorShape(self: *Self, shape: interface_mod.CursorShape) void {
        std.debug.assert(self.platform.pointer == null or self.platform.seat != null);
        std.debug.assert(self.platform.cursor_shape_device == null or self.platform.pointer != null);
        self.platform.setCursorShape(shape);
    }

    pub fn setAppearance(self: *Self, dark: bool) void {
        std.debug.assert(@intFromPtr(self) != 0);
        self.dark_appearance = dark;
        std.debug.assert(self.dark_appearance == dark);
    }

    pub fn getPlatform(self: *Self) *LinuxPlatform {
        std.debug.assert(@intFromPtr(self.platform) != 0);
        return self.platform;
    }

    pub fn requestRender(self: *Self) void {
        if (self.closed) return;
        self.needs_redraw = true;
        std.debug.assert(self.needs_redraw);
    }

    pub fn requestRenderAfter(self: *Self, delay_ms: u32) void {
        std.debug.assert(delay_ms <= interface_mod.render_delay_ms_max);

        if (self.closed) return;
        if (delay_ms == 0) {
            self.requestRender();
            return;
        }

        const deadline_ms = awakeTimeMs() + delay_ms;
        if (self.render_deadline_ms) |armed_ms| {
            if (armed_ms <= deadline_ms) return;
        }
        self.render_deadline_ms = deadline_ms;

        std.debug.assert(self.render_deadline_ms.? <= deadline_ms);
    }

    pub fn setMarkedText(self: *Self, text: []const u8) void {
        const bytes_max = self.marked_text_buffer.len;
        std.debug.assert(bytes_max > 0);
        const kept = core_clipboard.prefixFitting(text, bytes_max);
        if (kept < text.len) {
            std.log.warn("IME composition of {d} bytes cut to {d}. Raise " ++
                "ResourceLimits.text.preedit_bytes_max ({d}).", .{ text.len, kept, bytes_max });
        }
        @memcpy(self.marked_text_buffer[0..kept], text[0..kept]);
        self.marked_text = self.marked_text_buffer[0..kept];
        std.debug.assert(self.marked_text.len <= bytes_max);
        if (kept > 0 and kept < text.len) std.debug.assert(text[kept] & 0xC0 != 0x80);
    }

    pub fn clearMarkedText(self: *Self) void {
        self.marked_text = "";
    }

    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        std.debug.assert(w >= 0);
        std.debug.assert(h >= 0);
        self.platform.setImeCursorRect(
            @intFromFloat(x),
            @intFromFloat(y),
            @intFromFloat(w),
            @intFromFloat(h),
        );
    }

    pub fn hasMarkedText(self: *const Self) bool {
        return self.marked_text.len > 0;
    }

    pub fn enableIme(self: *Self) void {
        self.platform.enableTextInput();
    }

    pub fn disableIme(self: *Self) void {
        self.platform.disableTextInput();
    }

    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        self.on_close = callback;
    }

    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        self.user_data = data;
    }

    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        if (self.user_data) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }

    pub fn handleInput(self: *Self, event: input.InputEvent) bool {
        switch (event) {
            .mouse_down => |m| {
                self.pressed_button = m.button;
            },
            .mouse_up, .pointer_cancelled => {
                self.pressed_button = null;
            },
            else => {},
        }

        const binding = self.core orelse return false;
        return pushCoreInput(binding, event, self.hasMarkedText());
    }

    fn pushCoreInput(binding: CoreBinding, event: input.InputEvent, composing: bool) bool {
        if (composing) {
            if (event == .key_down) return false;
        }
        binding.queue.push(.{ .input = event });
        binding.schedule_tick(binding.context);
        return switch (event) {
            .key_down => |key| binding.query.keymapClaims(key),
            .mouse_down => |mouse| binding.query.pressClaims(.{
                .x = @floatCast(mouse.position.x),
                .y = @floatCast(mouse.position.y),
            }),
            else => false,
        };
    }

    pub fn bindCore(self: *Self, binding: CoreBinding) void {
        std.debug.assert(self.core == null);
        std.debug.assert(self.wl_surface != null);
        if (self.pending_resize) self.applyPendingSize();
        self.core = binding;
        std.debug.assert(!self.pending_resize);
    }

    fn applyPendingSize(self: *Self) void {
        std.debug.assert(self.pending_resize);
        std.debug.assert(self.pending_width > 0);
        std.debug.assert(self.pending_height > 0);
        self.pending_resize = false;
        self.width_px = self.pending_width;
        self.height_px = self.pending_height;
        self.size = .{
            .width = @floatFromInt(self.pending_width),
            .height = @floatFromInt(self.pending_height),
        };
    }

    fn resizeCore(self: *Self, binding: CoreBinding) void {
        self.applyPendingSize();
        pushViewport(binding, self.size, self.scale_factor);
    }

    fn applyScale(self: *Self, scale: f64) void {
        std.debug.assert(scale > 0);
        if (self.scale_factor == scale) return;
        self.scale_factor = scale;
        if (self.core) |binding| pushViewport(binding, self.size, scale);
        std.debug.assert(self.scale_factor == scale);
    }

    fn pushViewport(binding: CoreBinding, size: Size, scale: f64) void {
        std.debug.assert(size.width > 0);
        std.debug.assert(size.height > 0);
        std.debug.assert(scale > 0);
        binding.queue.push(.{ .window = .{ .resized = .{
            .width = @floatCast(size.width),
            .height = @floatCast(size.height),
            .scale_factor = @floatCast(scale),
        } } });
        binding.schedule_tick(binding.context);
    }

    pub fn startMove(self: *Self) void {
        const toplevel = self.xdg_toplevel orelse return;
        const seat = self.platform.seat orelse return;
        const serial = self.platform.last_pointer_serial;

        wayland.xdgToplevelMove(toplevel, seat, serial);
    }

    pub fn startResize(self: *Self, edge: wayland.ResizeEdge) void {
        const toplevel = self.xdg_toplevel orelse return;
        const seat = self.platform.seat orelse return;
        const serial = self.platform.last_pointer_serial;

        wayland.xdgToplevelResize(toplevel, seat, serial, edge);
    }

    pub fn getResizeEdge(self: *const Self, x: f64, y: f64, border_width: f64) ?wayland.ResizeEdge {
        const w: f64 = @floatFromInt(self.width_px);
        const h: f64 = @floatFromInt(self.height_px);

        const near_left = x < border_width;
        const near_right = x >= w - border_width;
        const near_top = y < border_width;
        const near_bottom = y >= h - border_width;

        if (near_top and near_left) return .top_left;
        if (near_top and near_right) return .top_right;
        if (near_bottom and near_left) return .bottom_left;
        if (near_bottom and near_right) return .bottom_right;
        if (near_top) return .top;
        if (near_bottom) return .bottom;
        if (near_left) return .left;
        if (near_right) return .right;

        return null;
    }

    pub fn isInTitleBar(self: *const Self, y: f64, title_bar_height: f64) bool {
        _ = self;
        return y < title_bar_height;
    }

    fn surfaceEnter(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        output: *wayland.Output,
    ) callconv(.c) void {
        _ = data;
        _ = surface;
        _ = output;
    }

    fn surfaceLeave(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        output: *wayland.Output,
    ) callconv(.c) void {
        _ = data;
        _ = surface;
        _ = output;
    }

    fn surfacePreferredScale(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        factor: i32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        if (self.fractional_scale != null) return;
        if (factor < 1) {
            std.log.warn("wl_surface: ignoring preferred buffer scale {d}", .{factor});
            return;
        }
        const new_scale: f64 = @floatFromInt(factor);
        if (self.scale_factor == new_scale) return;
        if (self.viewport == null) wayland.surfaceSetBufferScale(surface, factor);
        self.applyScale(new_scale);
    }

    fn fractionalPreferredScale(
        data: ?*anyopaque,
        fractional_scale: *wayland.WpFractionalScaleV1,
        scale_120ths: u32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));
        std.debug.assert(self.fractional_scale == fractional_scale);
        if (scale_120ths == 0) {
            std.log.warn("wp_fractional_scale_v1: ignoring preferred scale 0", .{});
            return;
        }
        self.applyScale(interface_mod.scaleFromSteps(scale_120ths));
    }

    fn surfacePreferredTransform(
        data: ?*anyopaque,
        surface: *wayland.Surface,
        transform: u32,
    ) callconv(.c) void {
        _ = data;
        _ = surface;
        _ = transform;
    }

    fn xdgSurfaceConfigure(
        data: ?*anyopaque,
        xdg_surface: *wayland.XdgSurface,
        serial: u32,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data));

        wayland.xdgSurfaceAckConfigure(xdg_surface, serial);

        if (self.pending_width > 0 and self.pending_height > 0) {
            self.pending_resize = true;
            if (self.core) |binding| self.resizeCore(binding);
        }

        self.configured = true;
    }

    fn xdgToplevelConfigure(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
        width_px: i32,
        height_px: i32,
        states: *anyopaque,
    ) callconv(.c) void {
        _ = xdg_toplevel;
        _ = states;
        const self: *Self = @ptrCast(@alignCast(data));

        if (width_px > 0 and height_px > 0) {
            self.pending_width = @intCast(width_px);
            self.pending_height = @intCast(height_px);
        } else {
            self.pending_width = self.width_px;
            self.pending_height = self.height_px;
        }
    }

    fn xdgToplevelConfigureBounds(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
        width_px: i32,
        height_px: i32,
    ) callconv(.c) void {
        _ = data;
        _ = xdg_toplevel;
        _ = width_px;
        _ = height_px;
    }

    fn xdgToplevelWmCapabilities(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
        capabilities: *anyopaque,
    ) callconv(.c) void {
        _ = data;
        _ = xdg_toplevel;
        _ = capabilities;
    }

    fn xdgToplevelClose(
        data: ?*anyopaque,
        xdg_toplevel: *wayland.XdgToplevel,
    ) callconv(.c) void {
        _ = xdg_toplevel;
        const self: *Self = @ptrCast(@alignCast(data));
        std.debug.assert(@intFromPtr(self) != 0);

        self.close();

        std.debug.assert(self.window_id.isValid());
    }

    fn decorationConfigure(
        data: ?*anyopaque,
        decoration: *wayland.ZxdgToplevelDecorationV1,
        mode: wayland.ZxdgToplevelDecorationV1Mode,
    ) callconv(.c) void {
        _ = decoration;
        const self: *Self = @ptrCast(@alignCast(data));

        switch (mode) {
            .server_side => {
                std.debug.print("Compositor will provide window decorations (server-side)\n", .{});
                self.has_server_decorations = true;
            },
            .client_side => {
                std.debug.print("WARNING: Compositor requires client-side decorations (not implemented)\n", .{});
                std.debug.print("Window will have no title bar - cannot move/resize/close with mouse\n", .{});
                self.has_server_decorations = false;
            },
            .undefined => {
                std.debug.print("WARNING: Decoration mode undefined\n", .{});
                self.has_server_decorations = false;
            },
        }
    }
};
