//! Runs a 0.4.0 core app in a Wayland window (phase 4), drawn by Vulkan
//! (`wayland_vulkan`) or by the CPU renderer into `wl_shm` buffers
//! (`wayland_cpu`, contract decision 17). The loop, pacing, input, IME, and
//! dialogs are the same for both; only the presenter and atlas binding differ.
//!
//! Two threads, one owner each (contract rule 1), as on macOS:
//! - The main thread runs the Wayland event loop (`runLoop`). The window
//!   pushes input and configures into the core's queue and schedules a tick.
//!   The loop runs at most one tick (drain, build, layout, emit) per turn,
//!   between dispatches, so no tick nests inside a Wayland callback and a
//!   handler's file dialog (a blocking portal call) opens on the main thread
//!   between handlers.
//! - The render thread presents the frame in flight (pack, then draw on
//!   Vulkan), paced by the compositor: it requests a `wl_surface.frame`
//!   callback on a private event queue with each present and presents the
//!   next frame only once that callback is done, or `frame_callback_timeout_ms`
//!   has passed (a hidden surface's callback can be withheld indefinitely).
//!   Presents are also at least `present_interval_ns` apart, three quarters
//!   of the output's refresh period. SER9 (mutter 46) showed input followed
//!   by an animation presenting three frames within 9 ms and then skipping
//!   refreshes: a compositor waking from idle can answer a burst's first
//!   callbacks early. The first present after idle still goes out at once.
//!   After each present it schedules a main tick, which makes the frame
//!   `rendered` and builds the next one if a render is pending.
//!
//! They meet only at `frame_in_flight` (see `core/tick.zig`) and two
//! eventfds that wake each loop. Both threads wait on the display fd with
//! libwayland's prepare/read protocol, so either can read events for the
//! other's queue.
//!
//! CPU renderer: it samples the core's atlases in place while it draws. The
//! tick never builds while a frame is in flight, so the atlases have one
//! writer at a time and no upload journal is consumed. Its buffer releases
//! arrive on the render queue, so only the render thread touches its slots;
//! a frame waits for a released slot as Vulkan's present waits for an image.
//!
//! IME: text-input-v3 has no synchronous rect query; the client pushes the
//! rect. The main loop compares the rendered frame's IME record with what it
//! last sent each turn (`syncIme`), so the rect it sends is always the one the
//! core's `Query` would answer.
//!
//! Resource sketch: one thread whose stack the OS maps at init, two eventfds,
//! one event queue, one surface wrapper, at most one frame callback, and one
//! frame in flight. Per turn the main thread runs at most one tick and one
//! dispatch; per compositor frame the render thread does at most one pack and
//! one draw. Every allocation happens before `finishInit`; the core's
//! lifecycle guard panics on any later one, including the Vulkan renderer's,
//! which shares the guard.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const wayland = @import("wayland.zig");
const platform_mod = @import("platform.zig");
const window_mod = @import("window.zig");
const file_dialog = @import("file_dialog.zig");
const clipboard = @import("clipboard.zig");
const linux_backend = @import("../linux_backend.zig");
const scene_mod = @import("../../scene/mod.zig");
const core_window = @import("../../core/window.zig");
const core_element = @import("../../core/element.zig");
const core_tick = @import("../../core/tick.zig");
const core_router = @import("../../core/router.zig");
const core_events = @import("../../core/events.zig");
const core_handler = @import("../../core/handler.zig");
const records = @import("../../core/records.zig");

const assert = std.debug.assert;

const LinuxPlatform = platform_mod.LinuxPlatform;
const PlatformWindow = window_mod.Window;
const Outcome = core_events.Completion.Outcome;

/// The longest the render thread waits for a frame callback before it
/// presents anyway: the 20 Hz cadence the 0.3.1 loop uses for hidden windows.
const frame_callback_timeout_ms: u32 = 50;

/// The output refresh rates pacing honours, in millihertz as `wl_output`
/// reports them; a mode outside is clamped. 20 Hz keeps the interval under
/// the callback timeout.
const refresh_rate_mhz_min: i32 = 20_000;
const refresh_rate_mhz_max: i32 = 1_000_000;

/// Bound on dispatch rounds before a thread may prepare to read. Each round
/// empties the queue; more arrive only if another thread reads in between.
const prepare_read_rounds_max: u32 = 1024;

const frame_callback_listener = wayland.CallbackListener{ .done = frameCallbackDone };

/// The window draws with the CPU renderer (`wayland_cpu`) rather than Vulkan.
const cpu_renderer = linux_backend.uses_cpu_renderer;

comptime {
    // The fbdev backend has no Wayland; its host is `platform/fbdev/core_host.zig`.
    if (linux_backend.selected == .fbdev) @compileError("fbdev runs core apps on its own host");
}

/// Run `App` until its window closes. Everything is reserved before
/// `finishInit`; the core's guard owns every allocation, the platform's too.
pub fn run(comptime App: type, app: *App, backing: std.mem.Allocator, io: std.Io) !void {
    app.beginInit(backing);
    const gpa = app.guard.allocator();

    const platform = try gpa.create(LinuxPlatform);
    defer gpa.destroy(platform);
    try platform.initInPlace(gpa);
    defer platform.deinit();

    const window = try PlatformWindow.init(gpa, platform, &.{
        .title = App.title,
        .width = @floatFromInt(App.width),
        .height = @floatFromInt(App.height),
        .background_color = App.theme.bg,
        .limits = App.limits_reserved,
    });
    defer window.deinit();

    try app.initCore(io, @floatCast(window.scale_factor));
    defer app.deinit();

    const host = try gpa.create(Host);
    defer gpa.destroy(host);
    try host.initInPlace(.{
        .platform = platform,
        .window = window,
        .core = &app.window,
        .app = app,
        .tick_main = App.tickMainErased,
        .io = io,
    });
    defer host.deinit();

    app.finishInit();
    // Deferred last, so it runs first: the guard leaves `running` before the
    // deferred teardown above frees the host, the window, and the platform.
    defer app.stop();
    assert(app.guard.lifecycle == .running);
    host.scheduleTick();
    host.runLoop();
}

pub const Host = struct {
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
    /// Wakes the main loop: `scheduleTick` from either thread.
    main_wake_fd: posix.fd_t,
    /// Wakes the render thread: a published frame, or `deinit`.
    render_wake_fd: posix.fd_t,
    /// The render thread's queue; the frame callbacks are its only proxies.
    render_queue: *wayland.EventQueue,
    /// The window's surface, with requests' new proxies on `render_queue`.
    surface_wrapper: *wayland.Surface,
    thread: ?std.Thread,
    /// A main tick is scheduled and has not started.
    tick_scheduled: std.atomic.Value(bool),
    stopping: std.atomic.Value(bool),
    /// The shortest gap between presents, from the output's refresh rate.
    /// The main thread, which receives `wl_output` modes, refreshes it.
    present_interval_ns: std.atomic.Value(u64),

    // Main thread only.
    quit: bool,
    ime_enabled: bool,
    /// The IME rect last sent to the compositor, while enabled.
    ime_rect: ?records.Rect,
    /// The cursor last set on the window.
    cursor: core_element.CursorShape,

    // Render thread only.
    frame_callback: ?*wayland.Callback,
    frame_callback_deadline_ns: u64,
    /// When the last frame was presented; null before the first.
    presented_ns: ?u64,
    /// The logical size and scale the swapchain and viewport were last set to.
    surface_width: u32,
    surface_height: u32,
    surface_scale: f32,

    pub const Options = struct {
        platform: *LinuxPlatform,
        window: *PlatformWindow,
        core: *core_window.Window,
        app: *anyopaque,
        tick_main: *const fn (app: *anyopaque, now_ns: u64) void,
        io: std.Io,
    };

    /// Bind the window, the presenter, and the dialog service, then start
    /// the render thread. The host must stay at this address.
    pub fn initInPlace(self: *Host, options: Options) !void {
        assert(options.core.presenter == null);
        assert(options.window.configured);
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
        self.cursor = .default;
        self.frame_callback = null;
        self.frame_callback_deadline_ns = 0;
        self.presented_ns = null;
        self.surface_width = self.window.width_px;
        self.surface_height = self.window.height_px;
        self.surface_scale = @floatCast(self.window.scale_factor);
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
        self.core.images.bindWake(.{ .context = self, .wake = scheduleTickErased });
        self.core.clipboard.service = .{
            .context = self,
            .read = clipboardRead,
            .write = clipboardWrite,
        };
        // `syncIme` alone enables text-input-v3, while a field is focused.
        self.core.bindScreenReader(null, null);
        assert(self.window.core != null);
    }

    /// Vulkan consumes the upload journal as this window. The CPU renderer
    /// samples the atlases in place, so it registers no consumer; its buffer
    /// releases move to the render queue before the first frame.
    fn bindAtlases(self: *Host) void {
        const resources = self.core.resources;
        if (cpu_renderer) {
            self.window.renderer.setAtlases(
                resources.text_system.getAtlas(),
                &resources.svg_atlas.atlas,
                &resources.image_atlas.atlas,
            );
            self.window.renderer.setEventQueue(self.render_queue);
        } else {
            const key = @intFromPtr(self.window);
            resources.registerAtlasConsumer(key);
            self.core.atlas_consumer_key = key;
            self.window.renderer.bindAtlasUploads(resources.atlas_uploads, key);
        }
    }

    /// Stop the render thread and wait for it, then unbind what `bindWindow`
    /// bound and release the Wayland objects the thread used. No draw can
    /// start afterwards.
    pub fn deinit(self: *Host) void {
        if (self.thread) |thread| {
            self.stopping.store(true, .release);
            signal(self.render_wake_fd);
            thread.join();
            self.thread = null;
        }
        self.unbindWindow();
        self.deinitWayland();
        assert(self.stopping.load(.acquire));
    }

    /// Undo `bindWindow` once the render thread, the atlas consumer, has
    /// stopped: the shared upload journal requires every consumer to leave
    /// before it is freed.
    fn unbindWindow(self: *Host) void {
        assert(self.thread == null);
        if (cpu_renderer) {
            // The render queue is destroyed next; the buffers outlive it.
            self.window.renderer.setEventQueue(null);
        } else {
            assert(self.core.atlas_consumer_key == @intFromPtr(self.window));
            self.core.resources.unregisterAtlasConsumer(self.core.atlas_consumer_key);
        }
        self.core.presenter = null;
        self.core.file_dialog = null;
        self.core.images.bindWake(null);
        self.core.clipboard.service = null;
        self.core.unbindScreenReader();
    }

    /// Schedule one main tick unless one is already scheduled. Any thread.
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

    // =========================================================================
    // Main thread
    // =========================================================================

    /// The event loop. Each turn runs at most one tick, syncs the IME, and
    /// waits for and dispatches one batch of events, so every turn is
    /// bounded; the loop ends when the window closes or the app quits.
    fn runLoop(self: *Host) void {
        assert(self.thread != null);
        while (!self.quit) {
            if (self.tick_scheduled.swap(false, .acq_rel)) self.mainTick();
            if (self.quit) break;
            self.syncIme();
            if (!self.waitForEvents()) {
                std.log.err("core host: the Wayland connection failed", .{});
                break;
            }
        }
        assert(self.core.phase == .idle);
    }

    /// One main-side tick, then either hand the published frame to the
    /// render thread or keep ticking while work is pending.
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
        // A render requested while a frame is in flight waits for the
        // render thread, which schedules a tick after it presents.
        const in_flight = self.core.frame_in_flight.load(.acquire);
        if (in_flight) signal(self.render_wake_fd);
        const pending = self.core.render_requested or self.core.queue.count > 0;
        if (pending and !in_flight) self.scheduleTick();
    }

    /// Wait for the display or the wake fd, then dispatch the main queue.
    /// Returns false when the connection failed.
    fn waitForEvents(self: *Host) bool {
        var rounds: u32 = 0;
        while (wayland.wl_display_prepare_read(self.display) != 0) : (rounds += 1) {
            assert(rounds < prepare_read_rounds_max);
            if (wayland.wl_display_dispatch_pending(self.display) < 0) return false;
        }
        // A passed render deadline schedules a tick here.
        const timeout_ms = self.deadlineTimeoutMs();
        // Dispatched events may have scheduled a tick or closed the window.
        if (self.tick_scheduled.load(.acquire) or self.quit) {
            wayland.wl_display_cancel_read(self.display);
            return true;
        }
        _ = wayland.wl_display_flush(self.display);
        var fds = [_]posix.pollfd{
            .{ .fd = self.display_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.main_wake_fd, .events = posix.POLL.IN, .revents = 0 },
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
        if (wayland.wl_display_dispatch_pending(self.display) < 0) return false;
        if ((fds[1].revents & posix.POLL.IN) != 0) drain(self.main_wake_fd);
        return true;
    }

    /// How long the main loop may sleep before the last build's render
    /// deadline (`cx.requestRenderAfter`, caret blink), or -1 without one.
    /// A passed deadline schedules the tick that fires it.
    fn deadlineTimeoutMs(self: *Host) i32 {
        const deadline = self.core.renderDeadlineNs() orelse return -1;
        const now_ns = self.nowNs();
        if (now_ns >= deadline) {
            self.scheduleTick();
            return 0;
        }
        const remaining_ms = std.math.divCeil(u64, deadline - now_ns, std.time.ns_per_ms) catch
            unreachable; // The divisor is a nonzero constant.
        assert(remaining_ms > 0);
        return @intCast(@min(remaining_ms, std.math.maxInt(i32)));
    }

    /// Set the cursor the tick resolved from the hovered record, only when it
    /// changed, so an idle pointer sends the compositor nothing.
    fn applyCursor(self: *Host) void {
        assert(self.core.phase == .idle);
        if (self.core.cursor == self.cursor) return;
        self.window.setCursorShape(self.core.cursor);
        self.cursor = self.core.cursor;
        assert(self.cursor == self.core.cursor);
    }

    /// Send the rendered frame's IME state to text-input-v3: enabled while a
    /// text input is focused and the compositor has entered the surface, with
    /// the caret rect the core's `Query` answers.
    fn syncIme(self: *Host) void {
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

    // =========================================================================
    // Render thread
    // =========================================================================

    /// A frame is in flight, the compositor is ready for it, and the last
    /// present is at least `present_interval_ns` old. The CPU renderer also
    /// needs a buffer the compositor has released.
    fn presentDue(self: *const Host) bool {
        if (!self.core.frame_in_flight.load(.acquire)) return false;
        if (cpu_renderer and !self.window.renderer.hasFreeSlot()) return false;
        const now_ns = self.nowNs();
        if (now_ns < self.pacedNs()) return false;
        if (self.frame_callback == null) return true;
        return now_ns >= self.frame_callback_deadline_ns;
    }

    /// The earliest time the next present may go out.
    fn pacedNs(self: *const Host) u64 {
        const presented_ns = self.presented_ns orelse return 0;
        const interval_ns = self.present_interval_ns.load(.acquire);
        assert(interval_ns > 0);
        return presented_ns + interval_ns;
    }

    /// Present the frame in flight with a frame callback on the same commit,
    /// then let the main thread make it `rendered` and build the next.
    fn presentFrame(self: *Host) void {
        assert(self.core.frame_in_flight.load(.acquire));
        // A callback past its deadline is abandoned; its event, if it ever
        // arrives, is dropped with the proxy.
        if (self.frame_callback) |callback| wayland.callbackDestroy(callback);
        self.frame_callback = wayland.surfaceFrame(self.surface_wrapper);
        if (self.frame_callback) |callback| {
            _ = wayland.callbackAddListener(callback, &frame_callback_listener, self);
        }
        const timeout_ns = @as(u64, frame_callback_timeout_ms) * std.time.ns_per_ms;
        const now_ns = self.nowNs();
        self.frame_callback_deadline_ns = now_ns + timeout_ns;
        self.presented_ns = now_ns;
        // The present commits the surface, and the callback with it.
        core_tick.presentBuilt(self.core);
        assert(!self.core.frame_in_flight.load(.acquire));
        self.scheduleTick();
    }

    /// Wait for a published frame, a frame callback, the callback deadline,
    /// or `deinit`, then dispatch the render queue. Returns false when the
    /// connection failed.
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

    /// While a frame waits, sleep until it may present: the pacing time,
    /// or the callback deadline when a callback is outstanding (its arrival
    /// wakes the poll sooner). Without a frame, or without a released CPU
    /// buffer, whose release event wakes it, sleep until woken.
    fn renderTimeoutMs(self: *const Host) i32 {
        if (!self.core.frame_in_flight.load(.acquire)) return -1;
        if (cpu_renderer and !self.window.renderer.hasFreeSlot()) return -1;
        var wake_ns = self.pacedNs();
        if (self.frame_callback != null) wake_ns = @max(wake_ns, self.frame_callback_deadline_ns);
        const now_ns = self.nowNs();
        if (now_ns >= wake_ns) return 0;
        const remaining_ms = std.math.divCeil(u64, wake_ns - now_ns, std.time.ns_per_ms) catch
            unreachable; // The divisor is a non-zero constant.
        assert(remaining_ms <= frame_callback_timeout_ms);
        return @intCast(remaining_ms);
    }

    /// Bring the swapchain and the surface's viewport and window geometry to
    /// the frame's viewport before drawing it, so both reach the compositor
    /// in the present's commit.
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
        window.renderer.resize(width, height, frame.scale_factor);
    }
};

/// Three quarters of the refresh period of an output refreshing at
/// `refresh_rate_mhz`. A compositor that paces callbacks to its refresh
/// answers each about one period after the last present, so this floor never
/// delays it; it only spreads callbacks answered early.
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

/// The frame callback, on the render thread: the compositor is ready for
/// the next frame.
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

/// The core's presenter, on the render thread.
fn draw(
    context: *anyopaque,
    scene: *const scene_mod.Scene,
    frame: *const records.Frame,
    clear: records.Color,
) void {
    const host: *Host = @ptrCast(@alignCast(context));
    assert(frame.scale_factor > 0);
    host.applyViewport(frame);
    const renderer = &host.window.renderer;
    renderer.setClearColor(clear);
    if (cpu_renderer) {
        // `presentDue` waited for a released buffer; only this thread takes one.
        const drawn = renderer.render(scene);
        assert(drawn);
    } else {
        renderer.render(scene);
        // An out-of-date swapchain skips the frame and is recreated by the
        // next render; draw this frame again rather than leave a stale one.
        if (renderer.swapchain_needs_recreate) renderer.render(scene);
    }
    assert(host.core.render_phase == .draw);
}

/// The window's close callback, on the main thread during dispatch: leave
/// the loop once the dispatch unwinds. The app has one window.
fn onClose(window: *PlatformWindow) bool {
    const host = window.getUserData(Host).?;
    assert(host.window == window);
    host.quit = true;
    return true;
}

// =============================================================================
// File dialogs
// =============================================================================

/// The core's file dialog service, on the main thread after the drain. The
/// portal reports cancel and failure alike as no selection, so both arrive as
/// `cancelled`.
fn openDialog(
    context: *anyopaque,
    scratch: std.mem.Allocator,
    request: core_handler.FileDialogRequest,
) Outcome {
    const host: *Host = @ptrCast(@alignCast(context));
    assert(host.core.phase == .drain);
    const paths = switch (request.kind) {
        .open => |options| paths: {
            const result = file_dialog.promptForPaths(scratch, options) orelse return .cancelled;
            if (result.paths.len == 0) return .cancelled;
            if (!options.multiple) assert(result.paths.len == 1);
            break :paths core_events.Paths.join(scratch, result.paths);
        },
        .save => |options| paths: {
            const path = file_dialog.promptForNewPath(scratch, options) orelse return .cancelled;
            break :paths core_events.Paths.join(scratch, &.{path});
        },
    };
    return .{ .file_selected = paths catch |err| return .{ .failed = err } };
}

// =============================================================================
// Wake fds
// =============================================================================

fn eventFd() !posix.fd_t {
    const fd = std.c.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (fd < 0) return error.EventFdCreationFailed;
    return fd;
}

/// Add one to the eventfd's counter. The counter cannot overflow (it is
/// drained every turn), so the write cannot fail.
fn signal(fd: posix.fd_t) void {
    assert(fd >= 0);
    const one: u64 = 1;
    const written = std.c.write(fd, std.mem.asBytes(&one), @sizeOf(u64));
    assert(written == @sizeOf(u64));
}

/// Reset the eventfd's counter. A spurious wake reads nothing.
fn drain(fd: posix.fd_t) void {
    assert(fd >= 0);
    var count: u64 = 0;
    const read_bytes = posix.read(fd, std.mem.asBytes(&count)) catch |err| switch (err) {
        error.WouldBlock => return,
        else => std.debug.panic("core host: eventfd read failed: {t}", .{err}),
    };
    assert(read_bytes == @sizeOf(u64));
}

/// The text engines' clipboard on the platform's 0.3.1 path, main thread.
fn clipboardRead(_: *anyopaque, out: []u8) u32 {
    return clipboard.readText(out);
}

fn clipboardWrite(_: *anyopaque, text: []const u8) void {
    if (!clipboard.setText(text)) std.log.warn("core host: clipboard write failed", .{});
}
