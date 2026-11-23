const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const wayland = @import("wayland.zig");
const platform_mod = @import("platform.zig");
const window_mod = @import("window.zig");
const interface = @import("../interface.zig");
const file_dialog = @import("file_dialog.zig");
const clipboard = @import("clipboard.zig");
const linux_backend = @import("../linux_backend.zig");
const core_window = @import("../../core/window.zig");
const core_element = @import("../../core/element.zig");
const core_tick = @import("../../core/tick.zig");
const core_router = @import("../../core/router.zig");
const core_events = @import("../../core/events.zig");
const core_handler = @import("../../core/handler.zig");
const core_limits = @import("../../core/limits.zig");
const backend = @import("../../core/backend.zig");
const records = @import("../../core/records.zig");

const assert = std.debug.assert;

const LinuxPlatform = platform_mod.LinuxPlatform;
const PlatformWindow = window_mod.Window;
const Outcome = core_events.Completion.Outcome;

const frame_callback_timeout_ms: u32 = 50;

const refresh_rate_mhz_min: i32 = 20_000;
const refresh_rate_mhz_max: i32 = 1_000_000;

const prepare_read_rounds_max: u32 = 1024;

pub const dispatch_event_count_max: u32 = 2;

pub const host_event_count_max: u32 = 3;

pub const input_room_count_single: u32 = dispatch_event_count_max + host_event_count_max;

pub const input_room_count_min: u32 = 4096 / 16;

const dispatch_single_count_max: u32 = 4096 / 8;

comptime {
    assert(input_room_count_min <= core_limits.input_burst_count_max);
    assert(input_room_count_single <= input_room_count_min);
    assert(input_room_count_single == 5);
}

const frame_callback_listener = wayland.CallbackListener{ .done = frameCallbackDone };

const cpu_renderer = linux_backend.uses_cpu_renderer;

comptime {
    switch (linux_backend.selected) {
        .wayland_cpu, .wayland_vulkan => {},
        .fbdev, .eve => @compileError("this backend runs core apps on its own host"),
    }
}

pub fn run(comptime App: type, app: *App, backing: std.mem.Allocator, io: std.Io) !void {
    app.beginInit(backing);
    const gpa = app.guard.allocator();

    const platform = try gpa.create(LinuxPlatform);
    defer gpa.destroy(platform);
    try platform.initInPlace();
    defer platform.deinit();

    const window = try PlatformWindow.init(gpa, platform, &.{
        .title = App.title,
        .width = @floatFromInt(App.width),
        .height = @floatFromInt(App.height),
        .background_color = App.theme.bg,
        .min_size = interface.minSize(App.min_width, App.min_height),
        .limits = App.limits_reserved,
    });
    defer window.deinit();

    try app.initCore(io, @floatCast(window.scale_factor));
    defer app.deinit();

    const host = try gpa.create(Host);
    defer gpa.destroy(host);
    try host.initInPlace(.{
        .gpa = gpa,
        .platform = platform,
        .window = window,
        .core = &app.window,
        .app = app,
        .tick_main = App.tickMainErased,
        .io = io,
    });
    defer host.deinit();

    app.finishInit();
    defer app.stop();
    assert(app.guard.lifecycle == .running);
    host.scheduleTick();
    host.runLoop();
}

pub const Host = struct {
    gpa: std.mem.Allocator,
    platform: *LinuxPlatform,
    window: *PlatformWindow,
    core: *core_window.Window,
    app: *anyopaque,
    tick_main: *const fn (app: *anyopaque, now_ns: u64) void,
    io: std.Io,
    start: std.Io.Timestamp,
    query: core_router.Query,
    display: *wayland.Display,
    display_fd: posix.fd_t,
    dispatch_single: ?wayland.DispatchPendingSingle,
    main_wake_fd: posix.fd_t,
    render_wake_fd: posix.fd_t,
    render_queue: *wayland.EventQueue,
    surface_wrapper: *wayland.Surface,
    thread: ?std.Thread,
    tick_scheduled: std.atomic.Value(bool),
    stopping: std.atomic.Value(bool),
    present_interval_ns: std.atomic.Value(u64),

    quit: bool,
    ime_enabled: bool,
    ime_rect: ?records.Rect,
    ime_owner: ?core_window.ElementId,
    cursor: core_element.CursorShape,
    dialog: ?PendingDialog,
    dialog_paths: []u8,

    frame_callback: ?*wayland.Callback,
    frame_callback_deadline_ns: u64,
    presented_ns: ?u64,
    surface_width: u32,
    surface_height: u32,
    surface_scale: f32,
    viewport: backend.Viewport,
    downscaled: bool,

    pub const Options = struct {
        gpa: std.mem.Allocator,
        platform: *LinuxPlatform,
        window: *PlatformWindow,
        core: *core_window.Window,
        app: *anyopaque,
        tick_main: *const fn (app: *anyopaque, now_ns: u64) void,
        io: std.Io,
    };

    pub fn initInPlace(self: *Host, options: Options) !void {
        assert(options.core.presenter == null);
        assert(options.window.configured);
        const path_bytes_max = options.core.limits.events.dialog_path_bytes_max;
        assert(path_bytes_max > 0);
        assert(path_bytes_max <= core_limits.EventLimits.ceiling.dialog_path_bytes_max);
        self.gpa = options.gpa;
        self.platform = options.platform;
        self.window = options.window;
        self.core = options.core;
        self.app = options.app;
        self.tick_main = options.tick_main;
        self.io = options.io;
        self.start = std.Io.Timestamp.now(options.io, .awake);
        self.query = .{ .window = options.core };
        self.thread = null;
        self.tick_scheduled = .init(false);
        self.stopping = .init(false);
        self.present_interval_ns = .init(presentIntervalNs(options.platform.refresh_rate_mhz));
        self.quit = false;
        self.ime_enabled = false;
        self.ime_rect = null;
        self.ime_owner = null;
        self.cursor = .default;
        self.dialog = null;
        self.frame_callback = null;
        self.frame_callback_deadline_ns = 0;
        self.presented_ns = null;
        self.surface_width = self.window.width_px;
        self.surface_height = self.window.height_px;
        self.surface_scale = @floatCast(self.window.scale_factor);
        self.viewport = backend.Viewport.fitLogical(
            @floatFromInt(self.surface_width),
            @floatFromInt(self.surface_height),
            @min(self.surface_scale, window_mod.renderer_scale_max),
            &options.core.limits.window,
        );
        self.downscaled = false;
        self.dialog_paths = try options.gpa.alloc(u8, file_dialog.requestBytes(path_bytes_max));
        errdefer options.gpa.free(self.dialog_paths);
        const clipboard_bytes: u32 = @intCast(options.core.clipboard_bytes.len);
        try clipboard.getState().reserveCopy(options.gpa, clipboard_bytes);
        errdefer clipboard.getState().releaseCopy(options.gpa);

        try self.initWayland();
        errdefer self.deinitWayland();
        self.bindWindow();
        errdefer self.unbindWindow();
        self.thread = try std.Thread.spawn(.{}, renderThreadMain, .{self});
        assert(self.thread != null);
    }

    fn initWayland(self: *Host) !void {
        self.display = self.platform.display orelse return error.NoDisplay;
        self.display_fd = wayland.wl_display_get_fd(self.display);
        assert(self.display_fd >= 0);
        self.dispatch_single = wayland.lookupDispatchPendingSingle();
        self.main_wake_fd = try eventFd();
        errdefer _ = std.c.close(self.main_wake_fd);
        self.render_wake_fd = try eventFd();
        errdefer _ = std.c.close(self.render_wake_fd);
        self.render_queue = wayland.wl_display_create_queue(self.display) orelse
            return error.EventQueueCreationFailed;
        errdefer wayland.wl_event_queue_destroy(self.render_queue);
        const surface = self.window.wl_surface orelse return error.NoSurface;
        const wrapper = wayland.wl_proxy_create_wrapper(@ptrCast(surface)) orelse
            return error.ProxyWrapperCreationFailed;
        wayland.wl_proxy_set_queue(wrapper, self.render_queue);
        self.surface_wrapper = @ptrCast(wrapper);
        assert(self.main_wake_fd != self.render_wake_fd);
    }

    fn deinitWayland(self: *Host) void {
        assert(self.thread == null);
        assert(self.frame_callback == null);
        wayland.wl_proxy_wrapper_destroy(@ptrCast(self.surface_wrapper));
        wayland.wl_event_queue_destroy(self.render_queue);
        _ = std.c.close(self.render_wake_fd);
        _ = std.c.close(self.main_wake_fd);
    }

    fn bindWindow(self: *Host) void {
        self.bindAtlases();
        self.window.bindCore(.{
            .queue = &self.core.queue,
            .query = &self.query,
            .context = self,
            .schedule_tick = scheduleTickErased,
        });
        self.window.setUserData(self);
        self.window.setCloseCallback(onClose);
        self.core.presenter = .{ .context = self, .draw = draw };
        self.core.file_dialog = .{ .context = self, .open = openDialog };
        self.core.bindWake(.{ .context = self, .wake = scheduleTickErased });
        self.core.clipboard.service = .{
            .context = self,
            .read = clipboardRead,
            .write = clipboardWrite,
        };
        self.core.bindScreenReader(null, null);
        self.core.bindViewport(.{
            .width = @floatCast(self.window.size.width),
            .height = @floatCast(self.window.size.height),
            .scale_factor = @floatCast(self.window.scale_factor),
        });
        assert(self.window.core != null);
    }

    fn bindAtlases(self: *Host) void {
        const resources = self.core.resources;
        const key = @intFromPtr(self.window);
        resources.registerAtlasConsumer(key);
        self.core.atlas_consumer_key = key;
        if (cpu_renderer) self.window.renderer.setEventQueue(self.render_queue);
        assert(self.core.atlas_consumer_key != 0);
    }

    pub fn deinit(self: *Host) void {
        if (self.dialog) |*pending| pending.request.close();
        self.dialog = null;
        if (self.thread) |thread| {
            self.stopping.store(true, .release);
            signal(self.render_wake_fd);
            thread.join();
            self.thread = null;
        }
        self.unbindWindow();
        self.deinitWayland();
        clipboard.getState().releaseCopy(self.gpa);
        self.gpa.free(self.dialog_paths);
        assert(self.stopping.load(.acquire));
        assert(self.dialog == null);
    }

    fn unbindWindow(self: *Host) void {
        assert(self.thread == null);
        if (cpu_renderer) self.window.renderer.setEventQueue(null);
        assert(self.core.atlas_consumer_key == @intFromPtr(self.window));
        self.core.resources.unregisterAtlasConsumer(self.core.atlas_consumer_key);
        self.core.presenter = null;
        self.core.file_dialog = null;
        self.core.bindWake(null);
        self.core.clipboard.service = null;
        self.core.unbindScreenReader();
    }

    pub fn scheduleTick(self: *Host) void {
        if (self.tick_scheduled.swap(true, .acq_rel)) return;
        signal(self.main_wake_fd);
    }

    fn scheduleTickErased(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.scheduleTick();
    }

    fn nowNs(self: *const Host) u64 {
        const elapsed = self.start.durationTo(std.Io.Timestamp.now(self.io, .awake));
        const ns = elapsed.toNanoseconds();
        assert(ns >= 0);
        return @intCast(ns);
    }

    fn runLoop(self: *Host) void {
        assert(self.thread != null);
        while (!self.quit) {
            self.platform.fireKeyRepeat();
            if (self.tick_scheduled.swap(false, .acq_rel)) self.mainTick();
            if (self.quit) break;
            self.syncIme();
            self.pollDialog();
            if (!self.waitForEvents()) {
                std.log.err("core host: the Wayland connection failed", .{});
                break;
            }
        }
        assert(self.core.phase == .idle);
    }

    fn mainTick(self: *Host) void {
        assert(self.core.phase == .idle);
        self.tick_main(self.app, self.nowNs());
        assert(self.core.phase == .idle);
        self.applyCursor();
        const interval_ns = presentIntervalNs(self.platform.refresh_rate_mhz);
        self.present_interval_ns.store(interval_ns, .release);
        if (self.core.quit_requested) {
            self.quit = true;
            return;
        }
        const in_flight = self.core.frame_in_flight.load(.acquire);
        if (in_flight) signal(self.render_wake_fd);
        const pending = self.core.render_requested or self.core.queue.count > 0;
        if (pending and !in_flight) self.scheduleTick();
    }

    fn waitForEvents(self: *Host) bool {
        if (self.core.queue.room() < self.inputRoomCountMin()) {
            assert(self.core.queue.count > 0);
            self.scheduleTick();
            return true;
        }
        var rounds: u32 = 0;
        while (wayland.wl_display_prepare_read(self.display) != 0) : (rounds += 1) {
            assert(rounds < prepare_read_rounds_max);
            switch (self.dispatchMain()) {
                .failed => return false,
                .drained => {},
                .held => return true,
            }
        }
        const timeout_ms = self.deadlineTimeoutMs();
        if (self.tick_scheduled.load(.acquire) or self.quit) {
            wayland.wl_display_cancel_read(self.display);
            return true;
        }
        _ = wayland.wl_display_flush(self.display);
        const dialog_fd: posix.fd_t = if (self.dialog) |pending| pending.fd else -1;
        var fds = [_]posix.pollfd{
            .{ .fd = self.display_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.main_wake_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = dialog_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&fds, timeout_ms) catch {
            wayland.wl_display_cancel_read(self.display);
            return false;
        };
        if ((fds[0].revents & posix.POLL.IN) != 0) {
            if (wayland.wl_display_read_events(self.display) < 0) return false;
        } else {
            wayland.wl_display_cancel_read(self.display);
        }
        if (self.dispatchMain() == .failed) return false;
        if ((fds[1].revents & posix.POLL.IN) != 0) drain(self.main_wake_fd);
        return true;
    }

    fn inputRoomCountMin(self: *const Host) u32 {
        const single = self.dispatch_single != null;
        const room = if (single) input_room_count_single else input_room_count_min;
        assert(room >= input_room_count_single);
        assert(room <= core_limits.input_burst_count_max);
        return room;
    }

    const Dispatch = enum { drained, held, failed };

    fn dispatchMain(self: *Host) Dispatch {
        const single = self.dispatch_single orelse {
            if (wayland.wl_display_dispatch_pending(self.display) < 0) return .failed;
            return .drained;
        };
        var dispatched: u32 = 0;
        while (dispatched < dispatch_single_count_max) : (dispatched += 1) {
            if (self.core.queue.room() < input_room_count_single) break;
            const count = single(self.display);
            if (count < 0) return .failed;
            if (count == 0) return .drained;
            assert(count == 1);
        }
        assert(self.core.queue.count > 0 or dispatched == dispatch_single_count_max);
        self.scheduleTick();
        return .held;
    }

    fn pollDialog(self: *Host) void {
        assert(self.core.phase == .idle);
        const pending = if (self.dialog) |*pending| pending else return;
        assert(pending.fd >= 0);
        const polled = pending.request.poll(self.dialog_paths);
        const outcome: Outcome = if (polled) |status| switch (status) {
            .open => return,
            .open_more => return self.scheduleTick(),
            .cancelled => .cancelled,
            .selected => |selection| self.selectedOutcome(pending.many, selection),
        } else |err| failed: {
            std.log.err("core host: the file dialog portal failed: {t}", .{err});
            break :failed .{ .failed = err };
        };
        const request_id = pending.request_id;
        pending.request.end();
        self.dialog = null;
        self.core.queue.push(.{ .completion = .{ .request_id = request_id, .outcome = outcome } });
        switch (outcome) {
            .file_selected => |paths| @memset(self.dialog_paths[0..paths.bytes.len], 0),
            .cancelled, .failed => {},
        }
        self.scheduleTick();
        assert(self.dialog == null);
    }

    fn selectedOutcome(self: *const Host, many: bool, selection: file_dialog.Selection) Outcome {
        core_tick.checkSelection(self.core, many, selection.count, selection.bytes_len);
        assert(selection.bytes_len <= self.core.limits.events.dialog_path_bytes_max);
        assert(selection.bytes_len < self.dialog_paths.len);
        const bytes = self.dialog_paths[0..@intCast(selection.bytes_len)];
        assert(std.mem.count(u8, bytes, &.{0}) == selection.count - 1);
        return .{ .file_selected = .{ .bytes = bytes, .count = selection.count } };
    }

    fn deadlineTimeoutMs(self: *Host) i32 {
        const render_ms = self.renderDeadlineTimeoutMs();
        const repeat_ms = self.platform.keyRepeatTimeoutMs() orelse return render_ms;
        assert(repeat_ms <= std.math.maxInt(i32));
        if (render_ms < 0) return @intCast(repeat_ms);
        return @min(render_ms, @as(i32, @intCast(repeat_ms)));
    }

    fn renderDeadlineTimeoutMs(self: *Host) i32 {
        const deadline = self.core.renderDeadlineNs() orelse return -1;
        const now_ns = self.nowNs();
        if (now_ns >= deadline) {
            self.scheduleTick();
            return 0;
        }
        const remaining_ms = std.math.divCeil(u64, deadline - now_ns, std.time.ns_per_ms) catch
            unreachable;
        assert(remaining_ms > 0);
        return @intCast(@min(remaining_ms, std.math.maxInt(i32)));
    }

    fn applyCursor(self: *Host) void {
        assert(self.core.phase == .idle);
        if (self.core.cursor == self.cursor) return;
        self.window.setCursorShape(self.core.cursor);
        self.cursor = self.core.cursor;
        assert(self.cursor == self.core.cursor);
    }

    fn syncIme(self: *Host) void {
        self.endStaleComposition();
        const rect = self.query.imeCursorRect();
        const wanted = rect != null and self.window.ime_active;
        if (!wanted) {
            if (self.ime_enabled) self.window.disableIme();
            self.ime_enabled = false;
            self.ime_rect = null;
            return;
        }
        if (!self.ime_enabled) self.window.enableIme();
        self.ime_enabled = true;
        const caret = rect.?;
        assert(caret.width >= 0);
        assert(caret.height >= 0);
        if (self.ime_rect) |sent| {
            if (std.meta.eql(sent, caret)) return;
        }
        self.window.setImeCursorRect(caret.x, caret.y, caret.width, caret.height);
        self.ime_rect = caret;
    }

    fn endStaleComposition(self: *Host) void {
        const owner = self.query.imeOwner();
        if (std.meta.eql(owner, self.ime_owner)) return;
        self.ime_owner = owner;
        if (!self.window.hasMarkedText()) return;
        self.window.clearMarkedText();
        assert(!self.window.hasMarkedText());
        if (!self.ime_enabled) return;
        self.window.disableIme();
        self.window.enableIme();
        self.ime_rect = null;
    }

    fn presentDue(self: *const Host) bool {
        if (!self.core.frame_in_flight.load(.acquire)) return false;
        if (cpu_renderer and !self.window.renderer.hasFreeSlot()) return false;
        const now_ns = self.nowNs();
        if (now_ns < self.pacedNs()) return false;
        if (self.frame_callback == null) return true;
        return now_ns >= self.frame_callback_deadline_ns;
    }

    fn pacedNs(self: *const Host) u64 {
        const presented_ns = self.presented_ns orelse return 0;
        const interval_ns = self.present_interval_ns.load(.acquire);
        assert(interval_ns > 0);
        return presented_ns + interval_ns;
    }

    fn presentFrame(self: *Host) void {
        assert(self.core.frame_in_flight.load(.acquire));
        if (self.frame_callback) |callback| wayland.callbackDestroy(callback);
        self.frame_callback = wayland.surfaceFrame(self.surface_wrapper);
        if (self.frame_callback) |callback| {
            _ = wayland.callbackAddListener(callback, &frame_callback_listener, self);
        }
        const timeout_ns = @as(u64, frame_callback_timeout_ms) * std.time.ns_per_ms;
        const now_ns = self.nowNs();
        self.frame_callback_deadline_ns = now_ns + timeout_ns;
        self.presented_ns = now_ns;
        core_tick.presentBuilt(self.core);
        assert(!self.core.frame_in_flight.load(.acquire));
        self.scheduleTick();
    }

    fn renderWait(self: *Host) bool {
        var rounds: u32 = 0;
        while (wayland.wl_display_prepare_read_queue(self.display, self.render_queue) != 0) {
            assert(rounds < prepare_read_rounds_max);
            rounds += 1;
            const dispatched = wayland.wl_display_dispatch_queue_pending(
                self.display,
                self.render_queue,
            );
            if (dispatched < 0) return false;
        }
        if (self.presentDue() or self.stopping.load(.acquire)) {
            wayland.wl_display_cancel_read(self.display);
            return true;
        }
        _ = wayland.wl_display_flush(self.display);
        var fds = [_]posix.pollfd{
            .{ .fd = self.display_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.render_wake_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&fds, self.renderTimeoutMs()) catch {
            wayland.wl_display_cancel_read(self.display);
            return false;
        };
        if ((fds[0].revents & posix.POLL.IN) != 0) {
            if (wayland.wl_display_read_events(self.display) < 0) return false;
        } else {
            wayland.wl_display_cancel_read(self.display);
        }
        if (wayland.wl_display_dispatch_queue_pending(self.display, self.render_queue) < 0) {
            return false;
        }
        if ((fds[1].revents & posix.POLL.IN) != 0) drain(self.render_wake_fd);
        return true;
    }

    fn renderTimeoutMs(self: *const Host) i32 {
        if (!self.core.frame_in_flight.load(.acquire)) return -1;
        if (cpu_renderer and !self.window.renderer.hasFreeSlot()) return -1;
        var wake_ns = self.pacedNs();
        if (self.frame_callback != null) wake_ns = @max(wake_ns, self.frame_callback_deadline_ns);
        const now_ns = self.nowNs();
        if (now_ns >= wake_ns) return 0;
        const remaining_ms = std.math.divCeil(u64, wake_ns - now_ns, std.time.ns_per_ms) catch
            unreachable;
        assert(remaining_ms <= frame_callback_timeout_ms);
        return @intCast(remaining_ms);
    }

    fn applyViewport(self: *Host, frame: *const records.Frame) void {
        assert(frame.viewport_width >= 1);
        assert(frame.viewport_height >= 1);
        const width: u32 = @intFromFloat(@round(frame.viewport_width));
        const height: u32 = @intFromFloat(@round(frame.viewport_height));
        const same_size = width == self.surface_width and height == self.surface_height;
        if (same_size and frame.scale_factor == self.surface_scale) return;
        self.surface_width = width;
        self.surface_height = height;
        self.surface_scale = frame.scale_factor;
        const window = self.window;
        if (window.viewport) |viewport| {
            wayland.viewportSetDestination(viewport, @intCast(width), @intCast(height));
        }
        if (window.xdg_surface) |xdg| {
            wayland.xdgSurfaceSetWindowGeometry(xdg, 0, 0, @intCast(width), @intCast(height));
        }
        self.fitViewport(width, height, frame.scale_factor);
    }

    fn fitViewport(self: *Host, width: u32, height: u32, scale_factor: f32) void {
        assert(width > 0);
        assert(height > 0);
        assert(scale_factor > 0);
        const window_limits = &self.core.limits.window;
        const viewport = backend.Viewport.fitLogical(
            @floatFromInt(width),
            @floatFromInt(height),
            @min(scale_factor, window_mod.renderer_scale_max),
            window_limits,
        );
        const downscaled = viewport.scale_factor < scale_factor;
        if (downscaled and !self.downscaled) {
            std.log.warn(
                "renderer: a {d}x{d} window at scale {d} exceeds ResourceLimits.window " ++
                    "({d}x{d} px); rendering at scale {d}",
                .{
                    width,
                    height,
                    scale_factor,
                    window_limits.framebuffer_width_max,
                    window_limits.framebuffer_height_max,
                    viewport.scale_factor,
                },
            );
        }
        self.downscaled = downscaled;
        const same_size = std.meta.eql(viewport.size_px, self.viewport.size_px);
        self.viewport = viewport;
        if (!same_size) self.window.renderer.resize(viewport.size_px);
    }
};

const PendingDialog = struct {
    request: file_dialog.PortalRequest,
    request_id: u32,
    fd: posix.fd_t,
    many: bool,
};

fn presentIntervalNs(refresh_rate_mhz: i32) u64 {
    assert(refresh_rate_mhz > 0);
    const rate_mhz = std.math.clamp(refresh_rate_mhz, refresh_rate_mhz_min, refresh_rate_mhz_max);
    const period_ns = @divFloor(std.time.ns_per_s * 1000, @as(u64, @intCast(rate_mhz)));
    const interval_ns = @divFloor(period_ns * 3, 4);
    assert(interval_ns > 0);
    assert(interval_ns < @as(u64, frame_callback_timeout_ms) * std.time.ns_per_ms);
    return interval_ns;
}

fn renderThreadMain(host: *Host) void {
    while (!host.stopping.load(.acquire)) {
        if (host.presentDue()) {
            host.presentFrame();
        } else if (!host.renderWait()) {
            std.log.err("core host: the render thread lost the Wayland connection", .{});
            break;
        }
    }
    if (host.frame_callback) |callback| wayland.callbackDestroy(callback);
    host.frame_callback = null;
}

fn frameCallbackDone(
    data: ?*anyopaque,
    callback: *wayland.Callback,
    callback_data: u32,
) callconv(.c) void {
    _ = callback_data;
    const host: *Host = @ptrCast(@alignCast(data.?));
    assert(host.frame_callback == callback);
    wayland.callbackDestroy(callback);
    host.frame_callback = null;
}

fn draw(
    context: *anyopaque,
    packed_frame: *const core_window.PackedFrame,
    frame: *const records.Frame,
    clear: records.Color,
) void {
    const host: *Host = @ptrCast(@alignCast(context));
    assert(frame.scale_factor > 0);
    host.applyViewport(frame);
    const renderer = &host.window.renderer;
    const uploads = host.core.resources.atlas_uploads;
    backend.uploadPendingAtlases(renderer, uploads, host.core.atlas_consumer_key);
    backend.checkCapabilities(renderer.capabilities(), packed_frame);
    if (cpu_renderer) assert(renderer.hasFreeSlot());
    renderer.draw(packed_frame, host.viewport, clear);
    if (!cpu_renderer and renderer.swapchain_needs_recreate) {
        renderer.draw(packed_frame, host.viewport, clear);
    }
    assert(host.core.render_phase == .draw);
}

fn onClose(window: *PlatformWindow) bool {
    const host = window.getUserData(Host).?;
    assert(host.window == window);
    host.quit = true;
    return true;
}

fn openDialog(
    context: *anyopaque,
    scratch: std.mem.Allocator,
    request_id: u32,
    request: core_handler.FileDialogRequest,
) ?Outcome {
    const host: *Host = @ptrCast(@alignCast(context));
    _ = scratch;
    assert(host.core.phase == .drain);
    assert(request_id < host.core.dialog_handlers.len);
    if (host.dialog) |open| {
        std.log.warn("core host: file dialog request {d} failed: request {d} is still open", .{
            request_id,
            open.request_id,
        });
        return .{ .failed = error.FileDialogBusy };
    }
    host.dialog = .{
        .request = undefined,
        .request_id = request_id,
        .fd = -1,
        .many = core_tick.selectsMany(request),
    };
    const pending = &host.dialog.?;
    const strings = host.dialog_paths;
    const begun = switch (request.kind) {
        .open => |*options| pending.request.begin(.{ .open = options }, strings),
        .save => |*options| pending.request.begin(.{ .save = options }, strings),
    };
    @memset(strings, 0);
    begun catch |err| {
        host.dialog = null;
        std.log.err("core host: the file dialog portal call failed: {t}", .{err});
        return .{ .failed = err };
    };
    pending.fd = pending.request.fd() orelse {
        pending.request.close();
        host.dialog = null;
        std.log.err("core host: the session bus has no socket to poll", .{});
        return .{ .failed = error.SessionBusNoSocket };
    };
    assert(pending.fd >= 0);
    return null;
}

fn eventFd() !posix.fd_t {
    const fd = std.c.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (fd < 0) return error.EventFdCreationFailed;
    return fd;
}

fn signal(fd: posix.fd_t) void {
    assert(fd >= 0);
    const one: u64 = 1;
    const written = std.c.write(fd, std.mem.asBytes(&one), @sizeOf(u64));
    assert(written == @sizeOf(u64));
}

fn drain(fd: posix.fd_t) void {
    assert(fd >= 0);
    var count: u64 = 0;
    const read_bytes = posix.read(fd, std.mem.asBytes(&count)) catch |err| switch (err) {
        error.WouldBlock => return,
        else => std.debug.panic("core host: eventfd read failed: {t}", .{err}),
    };
    assert(read_bytes == @sizeOf(u64));
}

fn clipboardRead(_: *anyopaque, out: []u8) u32 {
    return clipboard.readText(out);
}

fn clipboardWrite(_: *anyopaque, text: []const u8) void {
    if (!clipboard.setText(text)) std.log.warn("core host: clipboard write failed", .{});
}
