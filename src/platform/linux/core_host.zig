//! Runs a 0.4.0 core app in a Wayland window (phase 4).
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
//!   After each present it schedules a main tick, which makes the frame
//!   `rendered` and builds the next one if a render is pending.
//!
//! They meet only at `frame_in_flight` (see `core/tick.zig`) and two
//! eventfds that wake each loop. Both threads wait on the display fd with
//! libwayland's prepare/read protocol, so either can read events for the
//! other's queue.
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
const linux_backend = @import("../linux_backend.zig");
const scene_mod = @import("../../scene/mod.zig");
const core_window = @import("../../core/window.zig");
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

/// Bound on dispatch rounds before a thread may prepare to read. Each round
/// empties the queue; more arrive only if another thread reads in between.
const prepare_read_rounds_max: u32 = 1024;

const frame_callback_listener = wayland.CallbackListener{ .done = frameCallbackDone };

/// Run `App` until its window closes. Everything is reserved before
/// `finishInit`; the core's guard owns every allocation, the platform's too.
pub fn run(comptime App: type, app: *App, backing: std.mem.Allocator, io: std.Io) !void {
    if (comptime linux_backend.selected != .wayland_vulkan) {
        @compileError("core apps run on Linux with the wayland_vulkan backend; " ++
            "the wayland_cpu and fbdev backends move onto the core in phase 5");
    }
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
        .limits = App.limits,
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

    // Main thread only.
    quit: bool,
    ime_enabled: bool,
    /// The IME rect last sent to the compositor, while enabled.
    ime_rect: ?records.Rect,

    // Render thread only.
    frame_callback: ?*wayland.Callback,
    frame_callback_deadline_ns: u64,
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
        self.quit = false;
        self.ime_enabled = false;
        self.ime_rect = null;
        self.frame_callback = null;
        self.frame_callback_deadline_ns = 0;
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
        const resources = self.core.resources;
        const key = @intFromPtr(self.window);
        resources.registerAtlasConsumer(key);
        self.core.atlas_consumer_key = key;
        self.window.renderer.bindAtlasUploads(resources.atlas_uploads, key);
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
        // `syncIme` alone enables text-input-v3, while a field is focused.
        // A keyboard enter during window creation may have enabled it.
        self.window.platform.text_input_follows_keyboard = false;
        self.window.disableIme();
        self.core.bindScreenReader(null, null);
        assert(self.window.core != null);
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
        assert(self.core.atlas_consumer_key == @intFromPtr(self.window));
        self.core.resources.unregisterAtlasConsumer(self.core.atlas_consumer_key);
        self.core.presenter = null;
        self.core.file_dialog = null;
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
        _ = posix.poll(&fds, -1) catch {
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

    /// A frame is in flight and the compositor is ready for it.
    fn presentDue(self: *const Host) bool {
        if (!self.core.frame_in_flight.load(.acquire)) return false;
        if (self.frame_callback == null) return true;
        return self.nowNs() >= self.frame_callback_deadline_ns;
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
        self.frame_callback_deadline_ns = self.nowNs() + timeout_ns;
        // Vulkan's present commits the surface, and the callback with it.
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

    /// Sleep until the callback deadline while a frame waits on it, else
    /// until woken.
    fn renderTimeoutMs(self: *const Host) i32 {
        if (self.frame_callback == null) return -1;
        if (!self.core.frame_in_flight.load(.acquire)) return -1;
        const now_ns = self.nowNs();
        if (now_ns >= self.frame_callback_deadline_ns) return 0;
        const remaining_ns = self.frame_callback_deadline_ns - now_ns;
        const remaining_ms = std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch
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
    renderer.render(scene);
    // An out-of-date swapchain skips the frame and is recreated by the next
    // render; draw this frame again rather than leave a stale one on screen.
    if (renderer.swapchain_needs_recreate) renderer.render(scene);
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
    switch (request.kind) {
        .open => {
            const result = file_dialog.promptForPaths(scratch, .{
                .files = true,
                .directories = false,
                .multiple = false,
            }) orelse return .cancelled;
            if (result.paths.len == 0) return .cancelled;
            assert(result.paths.len == 1);
            return .{ .file_selected = result.paths[0] };
        },
        .save => {
            const path = file_dialog.promptForNewPath(scratch, .{}) orelse return .cancelled;
            assert(path.len > 0);
            return .{ .file_selected = path };
        },
    }
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
