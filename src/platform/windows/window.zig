const std = @import("std");
const interface_mod = @import("../interface.zig");
const geometry = @import("../../geometry/geometry.zig");
const input = @import("../../input/events.zig");
const vk_renderer = @import("../linux/vk_renderer.zig");
const renderer_choice = @import("renderer.zig");
const Renderer = renderer_choice.Renderer;
const win32 = @import("win32.zig");
const uia = @import("uia.zig");
const ime = @import("ime.zig");
const windows_input = @import("input.zig");
const windows_platform = @import("platform.zig");
const limits_mod = @import("../../core/limits.zig");
const backend = @import("../../core/backend.zig");
const core_events = @import("../../core/events.zig");
const core_router = @import("../../core/router.zig");
const WindowsPlatform = windows_platform.WindowsPlatform;

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const WindowId = interface_mod.WindowId;
const WindowOptions = interface_mod.WindowOptions;

const TitleBuffer = [Window.title_bytes_max + 1]u16;

const ime_cursor_rect_initial = geometry.RectF{
    .origin = .{ .x = 0, .y = 0 },
    .size = .{ .width = 1, .height = 20 },
};

const window_style: u32 = win32.WS_OVERLAPPEDWINDOW;
const window_style_extended: u32 = win32.WS_EX_APPWINDOW;

const modal_turn_timer_id: usize = 1;
const modal_turn_period_ms: u32 = 10;

pub const input_burst_count_max: u32 = 2;

comptime {
    assert(input_burst_count_max >= windows_input.message_event_count_max);
}

pub const CoreBinding = struct {
    queue: *core_events.EventQueue,
    query: *const core_router.Query,
    context: *anyopaque,
    schedule_tick: *const fn (context: *anyopaque) void,
    modal_turn: *const fn (context: *anyopaque) void,
    screen_reader_requested: *const fn (context: *anyopaque) void,
};

const ClientSize = struct {
    width_px: u32,
    height_px: u32,
};

pub const Window = struct {
    allocator: Allocator,
    platform: *WindowsPlatform,
    window_id: WindowId = .invalid,
    hwnd: ?win32.HWND = null,

    size: geometry.Size(f64),
    scale_factor: f64,
    client_width_px: u32 = 0,
    client_height_px: u32 = 0,
    minimized: bool = false,
    min_size: ?geometry.Size(f64),
    max_size: ?geometry.Size(f64),
    window_limits: limits_mod.WindowLimits,
    modal_turn_active: bool = false,

    renderer: Renderer,
    cursor_shape: interface_mod.CursorShape = .default,
    closed: bool = false,

    title_buffer: TitleBuffer = undefined,

    mouse_x: f64 = 0,
    mouse_y: f64 = 0,
    mouse_inside: bool = false,
    translator: windows_input.Translator,

    ime_units: [ime.units_max]u16 = undefined,
    marked_text_buffer: [ime_bytes_max]u8 = undefined,
    marked_text_len: usize = 0,
    inserted_text_buffer: [ime_bytes_max]u8 = undefined,
    inserted_text_len: usize = 0,
    ime_cursor_rect: geometry.RectF = ime_cursor_rect_initial,

    uia_host: uia.Host = .{},

    on_close: ?CloseCallback = null,
    user_data: ?*anyopaque = null,
    core: ?CoreBinding = null,

    dark_appearance: bool = false,
    needs_redraw: bool = false,
    render_deadline_ms: ?i64 = null,

    pub const CloseCallback = *const fn (*Self) bool;

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
        const native = switch (renderer_choice.selected) {
            .vulkan => vk_renderer.NativeSurface{
                .hinstance = plat.hinstance,
                .hwnd = self.hwnd.?,
            },
            .dx11 => {},
        };
        const viewport = self.rendererViewport();
        const render_limits = backend.RenderLimits.fromResourceLimits(&options.limits);
        try self.renderer.initInPlace(&.{
            .native = switch (renderer_choice.selected) {
                .vulkan => @ptrCast(@constCast(&native)),
                .dx11 => self.hwnd.?,
            },
            .size_px = viewport.size_px,
            .scale_factor = viewport.scale_factor,
        }, &render_limits);
        assert(rendererSwapchainUsable(&self.renderer));

        _ = win32.ShowWindow(self.hwnd.?, win32.SW_SHOW);
        _ = win32.SetForegroundWindow(self.hwnd.?);
        plat.setActiveWindowId(self.window_id);

        assert(self.window_id.isValid());
        assert(self.renderer.initialized);
        return self;
    }

    noinline fn initInPlace(
        self: *Self,
        allocator: Allocator,
        plat: *WindowsPlatform,
        options: *const WindowOptions,
    ) void {
        comptime assert(@typeInfo(Self).@"struct".field_names.len == 34);
        self.allocator = allocator;
        self.platform = plat;
        self.window_id = .invalid;
        self.hwnd = null;
        self.size = .{ .width = options.width, .height = options.height };
        self.scale_factor = scaleFromDpi(win32.GetDpiForSystem());
        self.client_width_px = 0;
        self.client_height_px = 0;
        self.minimized = false;
        self.min_size = options.min_size;
        self.max_size = options.max_size;
        self.window_limits = options.limits.window;
        self.modal_turn_active = false;
        switch (renderer_choice.selected) {
            .vulkan => self.renderer = .{},
            .dx11 => self.renderer.initialized = false,
        }
        self.cursor_shape = .default;
        self.closed = false;
        self.title_buffer[0] = 0;
        self.mouse_x = 0;
        self.mouse_y = 0;
        self.mouse_inside = false;
        self.translator = windows_input.Translator.init(plat.click_settings);
        self.marked_text_len = 0;
        self.inserted_text_len = 0;
        self.ime_cursor_rect = ime_cursor_rect_initial;
        self.uia_host = .{};
        self.on_close = null;
        self.user_data = null;
        self.core = null;
        self.dark_appearance = false;
        self.needs_redraw = false;
        self.render_deadline_ms = null;

        assert(self.scale_factor > 0);
        assert(!self.renderer.initialized);
        assert(titleTerminated(&self.title_buffer));
        assert(self.uia_host.root == null);
        assert(self.window_limits.framebuffer_width_max > 0);
    }

    fn createNativeWindow(self: *Self, options: *const WindowOptions) !void {
        assert(self.hwnd == null);
        assert(self.scale_factor > 0);
        const work_area = workArea(null);
        const outer = self.openingOuterSize(options, .{
            .dpi = dpiFromScale(self.scale_factor),
            .work_area = work_area,
        });
        const origin = if (options.centered) centeredOrigin(outer, work_area) else win32.POINT{
            .x = win32.CW_USEDEFAULT,
            .y = win32.CW_USEDEFAULT,
        };

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

    fn destroyNativeWindow(self: *Self) void {
        assert(self.uia_host.root == null);
        assert(!self.modal_turn_active);
        const hwnd = self.hwnd orelse return;
        _ = bindWindow(hwnd, 0);
        if (win32.DestroyWindow(hwnd) == win32.FALSE) {
            std.log.warn("windows: DestroyWindow failed (error {d})", .{win32.GetLastError()});
        }
        self.hwnd = null;
        assert(self.hwnd == null);
    }

    fn adoptWindowDpi(self: *Self, options: *const WindowOptions) void {
        const hwnd = self.hwnd.?;
        const scale = scaleFromDpi(win32.GetDpiForWindow(hwnd));
        if (scale == self.scale_factor) return;
        self.scale_factor = scale;
        const outer = self.openingOuterSize(options, .{
            .dpi = dpiFromScale(scale),
            .work_area = workArea(hwnd),
        });
        const flags = win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_NOMOVE;
        if (win32.SetWindowPos(hwnd, null, 0, 0, outer.x, outer.y, flags) == win32.FALSE) {
            std.log.warn("windows: SetWindowPos for the monitor's DPI failed (error {d})", .{
                win32.GetLastError(),
            });
        }
        assert(self.scale_factor == scale);
    }

    fn openingOuterSize(
        self: *const Self,
        options: *const WindowOptions,
        placement: OpeningPlacement,
    ) win32.POINT {
        assert(options.width > 0);
        assert(options.height > 0);
        const requested = geometry.Size(f64){ .width = options.width, .height = options.height };
        var outer = outerSize(requested, placement.dpi);
        if (placement.work_area) |area| {
            outer.x = @min(outer.x, area.right - area.left);
            outer.y = @min(outer.y, area.bottom - area.top);
        }
        const limits = self.trackLimits(placement.dpi);
        if (limits.min) |min| {
            outer.x = @max(outer.x, min.x);
            outer.y = @max(outer.y, min.y);
        }
        outer.x = @min(outer.x, limits.max.x);
        outer.y = @min(outer.y, limits.max.y);
        assert(outer.x > 0);
        assert(outer.y > 0);
        return outer;
    }

    fn trackLimits(self: *const Self, dpi: u32) TrackLimits {
        assert(dpi > 0);
        assert(self.window_limits.framebuffer_height_max > 0);
        var max = outerFromClient(.{
            .x = @intCast(@min(self.window_limits.framebuffer_width_max, client_px_max_u32)),
            .y = @intCast(@min(self.window_limits.framebuffer_height_max, client_px_max_u32)),
        }, dpi);
        if (self.max_size) |max_size| {
            const outer = outerSize(max_size, dpi);
            if (std.math.isFinite(max_size.width)) max.x = @min(max.x, outer.x);
            if (std.math.isFinite(max_size.height)) max.y = @min(max.y, outer.y);
        }
        const min: ?win32.POINT = if (self.min_size) |min_size| blk: {
            assert(std.math.isFinite(min_size.width));
            assert(std.math.isFinite(min_size.height));
            const outer = outerSize(min_size, dpi);
            break :blk .{ .x = @min(outer.x, max.x), .y = @min(outer.y, max.y) };
        } else null;
        if (min) |value| assert(value.x <= max.x);
        return .{ .min = min, .max = max };
    }

    pub fn deinit(self: *Self) void {
        assert(@intFromPtr(self) != 0);
        assert(self.uia_host.root == null);
        if (self.window_id.isValid()) {
            self.platform.unregisterWindow(self.window_id);
            self.window_id = .invalid;
        }
        self.renderer.deinit();
        self.destroyNativeWindow();
        assert(self.hwnd == null);
        self.allocator.destroy(self);
    }

    pub fn isPresentable(self: *const Self) bool {
        assert(self.client_width_px <= client_px_max_u32);
        assert(self.client_height_px <= client_px_max_u32);
        if (self.closed or self.minimized) return false;
        return self.client_width_px > 0 and self.client_height_px > 0;
    }

    fn applyClientSize(self: *Self, client: ClientSize) void {
        assert(self.scale_factor > 0);
        assert(client.width_px <= client_px_max_u32);
        assert(client.height_px <= client_px_max_u32);
        self.client_width_px = client.width_px;
        self.client_height_px = client.height_px;
        if (client.width_px == 0 or client.height_px == 0) return;
        self.checkClientBudget();

        self.size = .{
            .width = @as(f64, @floatFromInt(client.width_px)) / self.scale_factor,
            .height = @as(f64, @floatFromInt(client.height_px)) / self.scale_factor,
        };
        assert(self.size.width > 0);
        if (self.core) |binding| binding.schedule_tick(binding.context);
    }

    fn checkClientBudget(self: *const Self) void {
        assert(self.client_width_px > 0);
        assert(self.client_height_px > 0);
        const width_max = self.window_limits.framebuffer_width_max;
        const height_max = self.window_limits.framebuffer_height_max;
        if (self.client_width_px <= width_max and self.client_height_px <= height_max) return;
        std.log.err("windows: client area {d}x{d} px exceeds ResourceLimits.window ({d}x{d})", .{
            self.client_width_px,
            self.client_height_px,
            width_max,
            height_max,
        });
    }

    fn readClientSize(self: *Self) void {
        var rect: win32.RECT = undefined;
        if (win32.GetClientRect(self.hwnd.?, &rect) == win32.FALSE) {
            std.log.warn("windows: GetClientRect failed (error {d})", .{win32.GetLastError()});
            return;
        }
        assert(rect.right >= rect.left);
        assert(rect.bottom >= rect.top);
        self.applyClientSize(.{
            .width_px = @intCast(rect.right - rect.left),
            .height_px = @intCast(rect.bottom - rect.top),
        });
    }

    fn rendererViewport(self: *const Self) backend.Viewport {
        assert(self.size.width > 0);
        assert(self.size.height > 0);
        return backend.Viewport.fitLogical(
            @floatCast(self.size.width),
            @floatCast(self.size.height),
            @floatCast(self.scale_factor),
            &self.window_limits,
        );
    }

    fn translateAndDeliver(self: *Self, message: *const windows_input.Message) void {
        assert(self.hwnd != null);
        assert(self.scale_factor > 0);
        const context = windows_input.Context{
            .scale_factor = self.scale_factor,
            .modifiers = currentModifiers(),
            .time_ms = @bitCast(win32.GetMessageTime()),
            .pointer = self.messagePointer(message),
        };
        comptime assert(windows_input.message_event_count_max == 1);
        const event = self.translator.translate(message, &context) orelse return;
        self.applyPointerActions(self.translator.pointerActions(message.id, event));
        if (self.closed) return;
        _ = self.handleInput(event);
        if (message.id == win32.WM_KILLFOCUS) assert(self.translator.buttons_held == 0);
    }

    fn messagePointer(
        self: *const Self,
        message: *const windows_input.Message,
    ) geometry.Point(f64) {
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
        return windows_input.logicalFromDevice(point, self.scale_factor);
    }

    fn applyPointerActions(self: *Self, actions: windows_input.PointerActions) void {
        assert(self.hwnd != null);
        if (actions.capture == .set) assert(!actions.track_leave);
        switch (actions.capture) {
            .none => {},
            .set => _ = win32.SetCapture(self.hwnd.?),
            .release => if (win32.ReleaseCapture() == win32.FALSE) {
                std.log.warn("windows: ReleaseCapture failed (error {d})", .{win32.GetLastError()});
            },
        }
        if (actions.track_leave) self.trackPointerLeave();
    }

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
        if (event == .mouse_exited) assert(!self.mouse_inside);
        const binding = self.core orelse return false;
        return pushCoreInput(binding, event);
    }

    fn pushCoreInput(binding: CoreBinding, event: input.InputEvent) bool {
        binding.queue.push(.{ .input = event });
        binding.schedule_tick(binding.context);
        return switch (event) {
            .key_down => |key| binding.query.keymapClaims(key),
            else => false,
        };
    }

    pub fn bindCore(self: *Self, binding: CoreBinding) void {
        assert(self.core == null);
        assert(self.renderer.initialized);
        self.core = binding;
        assert(self.core != null);
    }

    pub fn setImeEnabled(self: *Self, enabled: bool) void {
        assert(self.core != null);
        const hwnd = self.hwnd orelse return;
        const flags: u32 = if (enabled) ime.IACE_DEFAULT else 0;
        if (ime.ImmAssociateContextEx(hwnd, null, flags) == win32.FALSE) {
            std.log.warn("windows: ImmAssociateContextEx({d}) failed", .{flags});
            return;
        }
        if (enabled) self.applyImePlacement();
    }

    pub fn cancelImeComposition(self: *Self) void {
        assert(self.core != null);
        const hwnd = self.hwnd orelse return;
        const context = ime.ImmGetContext(hwnd) orelse return;
        defer _ = ime.ImmReleaseContext(hwnd, context);

        _ = ime.ImmNotifyIME(context, ime.NI_COMPOSITIONSTR, ime.CPS_CANCEL, 0);
    }

    fn trackPointerLeave(self: *Self) void {
        assert(self.hwnd != null);
        assert(self.translator.pointer_inside);
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

    fn storeTitle(self: *Self, title: []const u8) bool {
        assert(title.len <= title_bytes_max);
        assert(titleTerminated(&self.title_buffer));
        const stored = encodeTitle(&self.title_buffer, title);
        assert(titleTerminated(&self.title_buffer));
        return stored;
    }

    pub fn setCursorShape(self: *Self, shape: interface_mod.CursorShape) void {
        if (self.mouse_inside) assert(self.hwnd != null);
        self.cursor_shape = shape;
        if (self.mouse_inside) _ = win32.SetCursor(self.platform.cursor(shape));
        assert(self.cursor_shape == shape);
    }

    pub fn close(self: *Self) void {
        if (self.closed) return;
        if (self.on_close) |callback| {
            if (!callback(self)) return;
        }
        self.closed = true;
        if (self.hwnd) |hwnd| _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
        if (self.platform.getActiveWindowId() == self.window_id) {
            self.platform.setActiveWindowId(null);
        }
        assert(self.closed);
    }

    pub fn setAppearance(self: *Self, dark: bool) void {
        self.dark_appearance = dark;
        assert(self.dark_appearance == dark);
    }

    pub fn getPlatform(self: *Self) *WindowsPlatform {
        assert(@intFromPtr(self.platform) != 0);
        return self.platform;
    }

    pub fn requestRender(self: *Self) void {
        if (self.closed) return;
        self.needs_redraw = true;
        assert(self.needs_redraw);
    }

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

    comptime {
        assert(ime_bytes_max == ime.bytes_max);
        assert(ime_bytes_max >= ime.units_max * 3);
    }

    pub fn setImeCursorRect(self: *Self, x: f32, y: f32, w: f32, h: f32) void {
        assert(w >= 0);
        assert(h >= 0);
        const rect = geometry.RectF.init(x, y, w, h);
        if (std.meta.eql(rect, self.ime_cursor_rect)) return;
        self.ime_cursor_rect = rect;
        self.applyImePlacement();
    }

    fn applyImePlacement(self: *Self) void {
        assert(self.scale_factor > 0);
        assert(self.ime_cursor_rect.size.width >= 0);
        const hwnd = self.hwnd orelse return;
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

    fn handleImeSetContext(self: *Self, message: *const windows_input.Message) win32.LRESULT {
        assert(message.id == win32.WM_IME_SETCONTEXT);
        assert(self.hwnd != null);
        const flags: usize = @bitCast(message.lparam);
        const lparam: win32.LPARAM = @bitCast(flags & ~ime.ISC_SHOWUICOMPOSITIONWINDOW);
        return win32.DefWindowProcW(self.hwnd.?, message.id, message.wparam, lparam);
    }

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
                self.clearImeComposition();
                return null;
            };
            self.commitImeComposition(units);
        }
        if (changes.preedit) {
            const units = ime.readString(context, ime.GCS_COMPSTR, &self.ime_units) orelse
                return 0;
            self.updateImeComposition(units);
        }
        return 0;
    }

    fn commitImeComposition(self: *Self, units: []const u16) void {
        assert(units.len <= ime.units_max);
        if (units.len == 0) {
            self.clearImeComposition();
            return;
        }
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

    fn clearImeComposition(self: *Self) void {
        if (self.marked_text_len == 0) return;
        assert(self.marked_text_len <= ime_bytes_max);
        self.marked_text_len = 0;
        if (self.closed) return;
        _ = self.handleInput(.{ .composition = .{ .text = "" } });
    }

    pub fn setCloseCallback(self: *Self, callback: ?CloseCallback) void {
        self.on_close = callback;
    }

    pub fn setUserData(self: *Self, data: ?*anyopaque) void {
        self.user_data = data;
    }

    pub fn getUserData(self: *Self, comptime T: type) ?*T {
        const ptr = self.user_data orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    fn handleSize(self: *Self, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
        assert(self.hwnd != null);
        assert(wparam <= 4);
        const was_minimized = self.minimized;
        self.minimized = wparam == win32.SIZE_MINIMIZED;
        if (self.minimized) {
            if (self.core) |binding| binding.schedule_tick(binding.context);
            return;
        }
        const size_bits: usize = @bitCast(lparam);
        self.applyClientSize(.{
            .width_px = win32.loWord(size_bits),
            .height_px = win32.hiWord(size_bits),
        });
        if (!was_minimized) return;
        if (self.core) |binding| binding.schedule_tick(binding.context);
    }

    fn handleDpiChanged(self: *Self, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
        assert(self.hwnd != null);
        const dpi = win32.loWord(wparam);
        assert(dpi > 0);
        self.scale_factor = scaleFromDpi(dpi);
        const suggested: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
        assert(suggested.right > suggested.left);
        const moved = win32.SetWindowPos(
            self.hwnd.?,
            null,
            suggested.left,
            suggested.top,
            suggested.right - suggested.left,
            suggested.bottom - suggested.top,
            win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
        );
        if (moved == win32.FALSE) {
            std.log.warn("windows: SetWindowPos for a DPI change failed (error {d})", .{
                win32.GetLastError(),
            });
        }
        self.readClientSize();
    }

    fn handleMinMaxInfo(self: *const Self, info: *win32.MINMAXINFO) void {
        assert(self.scale_factor > 0);
        assert(self.hwnd != null);
        const limits = self.trackLimits(dpiFromScale(self.scale_factor));
        if (limits.min) |min| info.ptMinTrackSize = min;
        info.ptMaxTrackSize.x = @min(info.ptMaxTrackSize.x, limits.max.x);
        info.ptMaxTrackSize.y = @min(info.ptMaxTrackSize.y, limits.max.y);
        info.ptMaxSize.x = @min(info.ptMaxSize.x, limits.max.x);
        info.ptMaxSize.y = @min(info.ptMaxSize.y, limits.max.y);
        assert(info.ptMaxTrackSize.x <= limits.max.x);
        assert(info.ptMaxSize.y <= limits.max.y);
    }

    fn handleGetObject(self: *Self, wparam: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
        assert(self.hwnd != null);
        const object_id: i32 = @truncate(lparam);
        if (object_id != uia.UiaRootObjectId) return null;
        const root = self.uia_host.root orelse return null;
        const first_request = !self.uia_host.client_requested;
        self.uia_host.client_requested = true;
        const binding = self.core.?;
        if (first_request) binding.screen_reader_requested(binding.context);
        assert(self.uia_host.client_requested);
        return uia.UiaReturnRawElementProvider(self.hwnd.?, wparam, lparam, root);
    }

    fn handleSetFocus(self: *Self) void {
        assert(self.hwnd != null);
        if (self.closed or !self.window_id.isValid()) return;
        self.platform.setActiveWindowId(self.window_id);
        assert(self.platform.getActiveWindowId() == self.window_id);
    }

    fn handleKillFocus(self: *Self, message: *const windows_input.Message) void {
        assert(message.id == win32.WM_KILLFOCUS);
        assert(self.hwnd != null);
        if (self.closed) return;
        self.translateAndDeliver(message);
        if (self.closed) return;
        assert(self.translator.buttons_held == 0);
    }

    fn handleEnterSizeMove(self: *Self) void {
        assert(self.hwnd != null);
        assert(!self.modal_turn_active);
        const timer = win32.SetTimer(self.hwnd.?, modal_turn_timer_id, modal_turn_period_ms, null);
        if (timer == 0) {
            std.log.warn("windows: SetTimer for a move or resize failed (error {d}); " ++
                "frames pause until it ends", .{win32.GetLastError()});
            return;
        }
        assert(timer == modal_turn_timer_id);
        self.modal_turn_active = true;
    }

    fn handleExitSizeMove(self: *Self) void {
        assert(self.hwnd != null);
        if (!self.modal_turn_active) return;
        if (win32.KillTimer(self.hwnd.?, modal_turn_timer_id) == win32.FALSE) {
            std.log.warn("windows: KillTimer failed (error {d})", .{win32.GetLastError()});
        }
        self.modal_turn_active = false;
        assert(!self.modal_turn_active);
    }

    fn handleModalTurnTimer(self: *Self) void {
        assert(self.hwnd != null);
        if (!self.modal_turn_active) return;
        if (self.closed) {
            self.handleExitSizeMove();
            return;
        }
        const binding = self.core orelse return;
        binding.modal_turn(binding.context);
    }

    fn handleMessage(self: *Self, message: *const windows_input.Message) ?win32.LRESULT {
        assert(self.hwnd != null);
        assert(message.id != win32.WM_NCCREATE);
        switch (message.id) {
            win32.WM_CLOSE => self.close(),
            win32.WM_SIZE => self.handleSize(message.wparam, message.lparam),
            win32.WM_DPICHANGED => self.handleDpiChanged(message.wparam, message.lparam),
            win32.WM_GETMINMAXINFO => {
                self.handleMinMaxInfo(@ptrFromInt(@as(usize, @bitCast(message.lparam))));
            },
            win32.WM_SETFOCUS => self.handleSetFocus(),
            win32.WM_KILLFOCUS => self.handleKillFocus(message),
            win32.WM_ENTERSIZEMOVE => self.handleEnterSizeMove(),
            win32.WM_EXITSIZEMOVE => self.handleExitSizeMove(),
            win32.WM_TIMER => {
                if (message.wparam != modal_turn_timer_id) return null;
                self.handleModalTurnTimer();
            },
            win32.WM_GETOBJECT => return self.handleGetObject(message.wparam, message.lparam),
            win32.WM_ERASEBKGND => return 1,
            win32.WM_SETCURSOR => {
                if (win32.loWord(@bitCast(message.lparam)) != win32.HTCLIENT) return null;
                _ = win32.SetCursor(self.platform.cursor(self.cursor_shape));
                return win32.TRUE;
            },
            else => return self.handleInputMessage(message),
        }
        return 0;
    }

    fn handleInputMessage(self: *Self, message: *const windows_input.Message) ?win32.LRESULT {
        assert(self.hwnd != null);
        assert(self.scale_factor > 0);
        switch (message.id) {
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
                const gaining: usize = @bitCast(message.lparam);
                if (gaining != @intFromPtr(self.hwnd.?)) self.translateAndDeliver(message);
            },
            win32.WM_IME_SETCONTEXT => return self.handleImeSetContext(message),
            win32.WM_IME_STARTCOMPOSITION => self.applyImePlacement(),
            win32.WM_IME_COMPOSITION => return self.handleImeComposition(message.lparam),
            win32.WM_IME_ENDCOMPOSITION => self.clearImeComposition(),
            win32.WM_SYSKEYDOWN, win32.WM_SYSKEYUP => {
                self.translateAndDeliver(message);
                if (windows_input.systemKeyUsesDefault(message)) return null;
            },
            win32.WM_SYSCHAR => if (windows_input.systemKeyUsesDefault(message)) return null,
            else => return null,
        }
        return 0;
    }
};

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
        if (!bindWindow(hwnd, @bitCast(@intFromPtr(window)))) return 0;
        window.hwnd = hwnd;
        window.uia_host.hwnd = hwnd;
        return win32.DefWindowProcW(hwnd, message_id, wparam, lparam);
    }
    const bound = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (bound == 0) return win32.DefWindowProcW(hwnd, message_id, wparam, lparam);

    const window: *Window = @ptrFromInt(@as(usize, @bitCast(bound)));
    assert(window.hwnd == hwnd);
    const message = windows_input.Message{ .id = message_id, .wparam = wparam, .lparam = lparam };
    return window.handleMessage(&message) orelse
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

fn encodeTitle(target: *TitleBuffer, title: []const u8) bool {
    assert(title.len <= Window.title_bytes_max);
    assert(titleTerminated(target));
    if (!std.unicode.utf8ValidateSlice(title)) return false;
    const units = std.unicode.utf8ToUtf16Le(target[0..Window.title_bytes_max], title) catch |err|
        switch (err) {
            error.InvalidUtf8 => unreachable,
        };
    assert(units <= title.len);
    target[units] = 0;
    return true;
}

comptime {
    assert(@sizeOf(Window) <= 16 * 1024);
    assert(@sizeOf(TitleBuffer) == (Window.title_bytes_max + 1) * @sizeOf(u16));
}

fn titleTerminated(buffer: *const TitleBuffer) bool {
    return std.mem.indexOfScalar(u16, buffer, 0) != null;
}

fn assertSizeLimit(size: geometry.Size(f64)) void {
    assert(size.width > 0);
    assert(size.height > 0);
}

pub fn rendererSwapchainUsable(renderer: *const Renderer) bool {
    assert(renderer.initialized);
    if (renderer_choice.selected == .dx11) return renderer.swapchainUsable();
    if (renderer.swapchain == null) return false;
    const image_count = renderer.swapchain_image_count;
    if (image_count == 0) return false;
    assert(image_count <= renderer.framebuffers.len);
    for (renderer.framebuffers[0..image_count]) |framebuffer| {
        if (framebuffer == null) return false;
    }
    return true;
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

const client_px_max: i32 = std.math.maxInt(i16);
const client_px_max_u32: u32 = client_px_max;

const OpeningPlacement = struct {
    dpi: u32,
    work_area: ?win32.RECT,
};

const TrackLimits = struct {
    min: ?win32.POINT,
    max: win32.POINT,
};

fn clientPxFromLogical(logical: f64, scale: f64) i32 {
    assert(!std.math.isNan(logical));
    assert(logical > 0);
    assert(std.math.isFinite(scale));
    assert(scale > 0);
    const device_px = @ceil(logical * scale);
    if (device_px >= 1) {
        if (device_px <= client_px_max) return @intFromFloat(device_px);
        return client_px_max;
    }
    return 1;
}

fn outerSize(size: geometry.Size(f64), dpi: u32) win32.POINT {
    assert(size.width > 0);
    assert(size.height > 0);
    const scale = scaleFromDpi(dpi);
    return outerFromClient(.{
        .x = clientPxFromLogical(size.width, scale),
        .y = clientPxFromLogical(size.height, scale),
    }, dpi);
}

fn outerFromClient(client: win32.POINT, dpi: u32) win32.POINT {
    assert(client.x > 0);
    assert(client.x <= client_px_max);
    assert(client.y > 0);
    assert(client.y <= client_px_max);
    var rect = win32.RECT{ .left = 0, .top = 0, .right = client.x, .bottom = client.y };
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

fn centeredOrigin(outer: win32.POINT, work_area: ?win32.RECT) win32.POINT {
    assert(outer.x > 0);
    assert(outer.y > 0);
    const area = work_area orelse return .{ .x = win32.CW_USEDEFAULT, .y = win32.CW_USEDEFAULT };
    return .{
        .x = @max(area.left, area.left + @divFloor(area.right - area.left - outer.x, 2)),
        .y = @max(area.top, area.top + @divFloor(area.bottom - area.top - outer.y, 2)),
    };
}

fn workArea(hwnd: ?win32.HWND) ?win32.RECT {
    var area: win32.RECT = undefined;
    if (hwnd) |window| {
        const monitor = win32.MonitorFromWindow(window, win32.MONITOR_DEFAULTTONEAREST) orelse
            return null;
        var info = win32.MONITORINFO{
            .cbSize = @sizeOf(win32.MONITORINFO),
            .rcMonitor = undefined,
            .rcWork = undefined,
            .dwFlags = 0,
        };
        if (win32.GetMonitorInfoW(monitor, &info) == win32.FALSE) {
            std.log.warn("windows: GetMonitorInfoW failed (error {d})", .{win32.GetLastError()});
            return null;
        }
        area = info.rcWork;
    } else {
        if (win32.SystemParametersInfoW(win32.SPI_GETWORKAREA, 0, &area, 0) == win32.FALSE) {
            std.log.warn("windows: SPI_GETWORKAREA failed (error {d})", .{win32.GetLastError()});
            return null;
        }
    }
    assert(area.right >= area.left);
    assert(area.bottom >= area.top);
    return area;
}

fn bindWindow(hwnd: win32.HWND, value: isize) bool {
    win32.SetLastError(0);
    const previous = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, value);
    if (previous == 0) {
        const err = win32.GetLastError();
        if (err != 0) {
            std.log.err("windows: SetWindowLongPtrW(GWLP_USERDATA) failed (error {d})", .{err});
            return false;
        }
    }
    assert(win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA) == value);
    return true;
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
    var buffer = try testTitleBuffer("Old title");
    const ascii_run: [70]u8 = @splat('x');
    const rejected = [_][]const u8{
        &(ascii_run ++ "\xFF".*),
        &(ascii_run ++ "\xE2\x82".*),
        &(ascii_run ++ "\xED\xA0\x80".*),
        &(ascii_run ++ "\xC0\xAF".*),
    };
    for (rejected) |title| {
        try std.testing.expect(!encodeTitle(&buffer, title));
        try expectTitle(&buffer, "Old title");
    }
    try std.testing.expect(encodeTitle(&buffer, &ascii_run));
    try expectTitle(&buffer, &ascii_run);
}

test "client extents round up and clamp at the Win32 limit" {
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
    const dpis = [_]u32{ win32.USER_DEFAULT_SCREEN_DPI, 3 * win32.USER_DEFAULT_SCREEN_DPI };
    for (dpis) |dpi| {
        const unbounded = std.math.inf(f64);
        const infinite = outerSize(.{ .width = unbounded, .height = unbounded }, dpi);
        try std.testing.expect(infinite.x >= client_px_max);
        try std.testing.expect(infinite.y >= client_px_max);
        const huge = outerSize(.{ .width = std.math.floatMax(f64), .height = 1e12 }, dpi);
        try std.testing.expectEqual(infinite.x, huge.x);
        try std.testing.expectEqual(infinite.y, huge.y);
    }
}

fn testLimitsWindow(options: *const WindowOptions) Window {
    var window: Window = undefined;
    window.window_limits = options.limits.window;
    window.min_size = options.min_size;
    window.max_size = options.max_size;
    return window;
}

test "track limits cap the client at the window budget, then max_size, then min_size" {
    const dpi = 2 * win32.USER_DEFAULT_SCREEN_DPI;
    var options = WindowOptions{
        .limits = limits_mod.ResourceLimits.standard,
        .min_size = .{ .width = 2000, .height = 100 },
        .max_size = .{ .width = 1000, .height = std.math.inf(f64) },
    };
    options.limits.window = .{ .framebuffer_width_max = 2560, .framebuffer_height_max = 1600 };
    const window = testLimitsWindow(&options);

    const limits = window.trackLimits(dpi);
    try std.testing.expectEqual(outerFromClient(.{ .x = 2000, .y = 1600 }, dpi), limits.max);
    try std.testing.expectEqual(limits.max.x, limits.min.?.x);
    try std.testing.expectEqual(outerFromClient(.{ .x = 4000, .y = 200 }, dpi).y, limits.min.?.y);

    options.max_size = null;
    options.min_size = null;
    const budget_only = testLimitsWindow(&options).trackLimits(dpi);
    try std.testing.expectEqual(outerFromClient(.{ .x = 2560, .y = 1600 }, dpi), budget_only.max);
    try std.testing.expectEqual(@as(?win32.POINT, null), budget_only.min);
}

test "a new window fits the work area, then grows to min_size, never past the budget" {
    const dpi = win32.USER_DEFAULT_SCREEN_DPI;
    const work_area = win32.RECT{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };
    var options = WindowOptions{
        .limits = limits_mod.ResourceLimits.standard,
        .width = 3000,
        .height = 3000,
    };
    options.limits.window = .{ .framebuffer_width_max = 4000, .framebuffer_height_max = 1500 };
    const placement = OpeningPlacement{ .dpi = dpi, .work_area = work_area };

    const fitted = testLimitsWindow(&options).openingOuterSize(&options, placement);
    try std.testing.expectEqual(@as(i32, 1920), fitted.x);
    try std.testing.expectEqual(@as(i32, 1040), fitted.y);

    options.min_size = .{ .width = 1600, .height = 1200 };
    const grown = testLimitsWindow(&options).openingOuterSize(&options, placement);
    const min_outer = outerSize(.{ .width = 1600, .height = 1200 }, dpi);
    try std.testing.expectEqual(@as(i32, 1920), grown.x);
    try std.testing.expectEqual(min_outer.y, grown.y);

    options.min_size = .{ .width = 1600, .height = 2000 };
    const capped = testLimitsWindow(&options).openingOuterSize(&options, placement);
    try std.testing.expectEqual(outerFromClient(.{ .x = 4000, .y = 1500 }, dpi).y, capped.y);
}

test "centering keeps the window's corner inside the work area" {
    const area = win32.RECT{ .left = 100, .top = 50, .right = 1100, .bottom = 850 };
    const small = centeredOrigin(.{ .x = 400, .y = 200 }, area);
    try std.testing.expectEqual(@as(i32, 400), small.x);
    try std.testing.expectEqual(@as(i32, 350), small.y);
    const large = centeredOrigin(.{ .x = 1400, .y = 1000 }, area);
    try std.testing.expectEqual(@as(i32, 100), large.x);
    try std.testing.expectEqual(@as(i32, 50), large.y);
    const unknown = centeredOrigin(.{ .x = 400, .y = 200 }, null);
    try std.testing.expectEqual(win32.CW_USEDEFAULT, unknown.x);
}
