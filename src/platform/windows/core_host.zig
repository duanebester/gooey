//! Runs a 0.4.0 core app in a Win32 window (phase 4).
//!
//! Two threads, one owner each (contract rule 1), as on macOS and Linux:
//! - The main thread created the window, so it receives the window's
//!   messages, and runs the host's message loop (`runLoop`). The window
//!   pushes input into the core's queue and schedules a tick. The loop runs
//!   at most one tick (drain, build, layout, emit) per turn, between message
//!   batches, so no tick nests inside a window procedure and a handler's file
//!   dialog opens on the main thread between handlers. A move or resize holds
//!   the thread in `DefWindowProcW`'s modal loop; the window's modal timer
//!   runs the same turn from there (`modalTurn`).
//! - The render thread presents the frame in flight (pack, then draw on
//!   Vulkan), paced by the display: after each present it waits for the first
//!   vertical blank at least half a refresh away, read from DWM's composition
//!   timing, so it presents at most once per refresh at the display's own
//!   rate (60, 120, or 144 Hz). It then schedules a main tick, which makes
//!   the frame `rendered` and builds the next one if a render is pending.
//!
//! They meet only at `frame_in_flight` (see `core/tick.zig`), at
//! `presentable`, which the main thread sets from the window's minimized
//! state and client area before each tick, and at two auto-reset events that
//! wake each thread. The renderer belongs to the render thread once the
//! window is bound: the main thread never resizes or draws.
//!
//! IME: the main loop compares the rendered frame's IME record each turn
//! (`syncIme`), attaching the window's input context only while a text field
//! is focused and placing the candidate list at the caret the core's `Query`
//! answers.
//!
//! Services: file dialogs open on the main thread after the drain, and run
//! their own modal loop there. UI Automation is served from the window's
//! `uia_host`; the core publishes each rendered frame's nodes to it on the
//! main thread, where clients' calls also arrive.
//!
//! Resource sketch: one thread whose stack the OS maps at init, three events,
//! one waitable timer (the main loop borrows the platform's), and one frame
//! in flight. Per turn the main thread runs at most one tick and dispatches
//! at most `message_batch_max` messages; per refresh the render thread does
//! at most one pack, one draw, and one DWM timing query. Every allocation
//! happens before `finishInit`; the core's lifecycle guard panics on any
//! later one, including the Vulkan renderer's, which shares the guard.

const std = @import("std");
const win32 = @import("win32.zig");
const platform_mod = @import("platform.zig");
const window_mod = @import("window.zig");
const clipboard = @import("clipboard.zig");
const file_dialog = @import("file_dialog.zig");
const core_window = @import("../../core/window.zig");
const backend = @import("../../core/backend.zig");
const core_element = @import("../../core/element.zig");
const core_tick = @import("../../core/tick.zig");
const core_router = @import("../../core/router.zig");
const core_events = @import("../../core/events.zig");
const core_handler = @import("../../core/handler.zig");
const records = @import("../../core/records.zig");

const assert = std.debug.assert;

const WindowsPlatform = platform_mod.WindowsPlatform;
const PlatformWindow = window_mod.Window;
const Outcome = core_events.Completion.Outcome;

/// The pacing period when DWM reports no usable timing: 0.3.1's 60 Hz cap.
const refresh_period_ns_fallback: u64 = platform_mod.frame_period_ns_min;
/// A reported refresh outside 24 to 500 Hz is treated as no timing at all.
const refresh_period_ns_min: u64 = std.time.ns_per_s / 500;
const refresh_period_ns_max: u64 = std.time.ns_per_s / 24;

/// The longest single wait of the main loop for a render deadline. A later
/// deadline wakes the loop once per interval to wait again.
const deadline_wait_ns_max: u64 = 60 * std.time.ns_per_s;

/// Bound on `deinit`'s waits for the render thread, each ended by the thread
/// or by a message another thread sent this one. The thread finishes at most
/// one present after `stopping` is set.
const join_wait_count_max: u32 = 1 << 20;

/// `SetWaitableTimer` counts due times in 100 ns intervals.
const timer_interval_ns: u64 = 100;

/// Run `App` until its window closes. Everything is reserved before
/// `finishInit`; the core's guard owns every allocation, the platform's too.
pub fn run(comptime App: type, app: *App, backing: std.mem.Allocator, io: std.Io) !void {
    app.beginInit(backing);
    const gpa = app.guard.allocator();

    const platform = try gpa.create(WindowsPlatform);
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

/// A logical size and scale, as the core's resize event carries them.
const Viewport = struct {
    width: f32,
    height: f32,
    scale_factor: f32,
};

pub const Host = struct {
    platform: *WindowsPlatform,
    window: *PlatformWindow,
    core: *core_window.Window,
    app: *anyopaque,
    tick_main: *const fn (app: *anyopaque, now_ns: u64) void,
    io: std.Io,
    start: std.Io.Timestamp,
    query: core_router.Query,
    /// `QueryPerformanceCounter` ticks per second, read once at init.
    qpc_frequency: u64,
    /// Wakes the main loop: `scheduleTick` from either thread. Auto-reset.
    main_wake: win32.HANDLE,
    /// Wakes the render thread: a published frame, or `deinit`. Auto-reset.
    render_wake: win32.HANDLE,
    /// Set by the render thread as it exits. Manual-reset.
    render_done: win32.HANDLE,
    /// Ends the render thread's wait when the next present is due.
    render_timer: win32.HANDLE,
    thread: ?std.Thread,
    /// A main tick is scheduled and has not started.
    tick_scheduled: std.atomic.Value(bool),
    stopping: std.atomic.Value(bool),
    /// The window can show a frame: open, not minimized, with a client area.
    /// Written by the main thread before each tick; the render thread skips
    /// drawing while it is false.
    presentable: std.atomic.Value(bool),

    // Main thread only.
    quit: bool,
    ime_enabled: bool,
    /// The cursor last set on the window.
    cursor: core_element.CursorShape,
    /// The viewport last pushed to the core; zero before the first push.
    viewport_sent: Viewport,
    /// A UI Automation client asked for the root since the last tick.
    screen_reader_requested: bool,

    // Render thread only.
    /// When the next present may start, on `nowNs`.
    present_due_ns: u64,
    /// The framebuffer the swapchain was last built for: the frame's
    /// viewport, fitted to `ResourceLimits.window`.
    viewport: backend.Viewport,
    /// Set while the swapchain cannot be rebuilt, so that is logged once.
    swapchain_failure_logged: bool,

    pub const Options = struct {
        platform: *WindowsPlatform,
        window: *PlatformWindow,
        core: *core_window.Window,
        app: *anyopaque,
        tick_main: *const fn (app: *anyopaque, now_ns: u64) void,
        io: std.Io,
    };

    /// Bind the window, the presenter, and the services, then start the
    /// render thread. The host must stay at this address.
    pub fn initInPlace(self: *Host, options: Options) !void {
        assert(options.core.presenter == null);
        assert(options.window.core == null);
        assert(options.window.renderer.initialized);
        self.platform = options.platform;
        self.window = options.window;
        self.core = options.core;
        self.app = options.app;
        self.tick_main = options.tick_main;
        self.io = options.io;
        self.start = std.Io.Timestamp.now(options.io, .awake);
        self.query = .{ .window = options.core };
        self.qpc_frequency = qpcFrequency();
        self.thread = null;
        self.tick_scheduled = .init(false);
        self.stopping = .init(false);
        self.presentable = .init(false);
        self.quit = false;
        self.ime_enabled = false;
        self.cursor = .default;
        self.viewport_sent = .{ .width = 0, .height = 0, .scale_factor = 0 };
        self.screen_reader_requested = false;
        self.present_due_ns = 0;
        // No size a frame can have, so the first frame sizes the swapchain to
        // its viewport: `WM_SIZE` may have changed the client area after
        // `Window.init` built the swapchain and before this host existed.
        self.viewport = .{ .size_px = .{ .width = 0, .height = 0 }, .scale_factor = 0 };
        self.swapchain_failure_logged = false;
        try self.initHandles();
        errdefer self.deinitHandles();
        self.bindWindow();
        errdefer self.unbindWindow();
        self.thread = try std.Thread.spawn(.{}, renderThreadMain, .{self});
        assert(self.thread != null);
    }

    fn initHandles(self: *Host) !void {
        self.main_wake = try createEvent(.{ .manual_reset = false });
        errdefer closeHandle(self.main_wake);
        self.render_wake = try createEvent(.{ .manual_reset = false });
        errdefer closeHandle(self.render_wake);
        self.render_done = try createEvent(.{ .manual_reset = true });
        errdefer closeHandle(self.render_done);
        self.render_timer = try platform_mod.createFrameTimer();
        assert(self.main_wake != self.render_wake);
        assert(self.render_wake != self.render_done);
    }

    fn deinitHandles(self: *Host) void {
        assert(self.thread == null);
        platform_mod.closeFrameTimer(self.render_timer);
        closeHandle(self.render_done);
        closeHandle(self.render_wake);
        closeHandle(self.main_wake);
    }

    fn bindWindow(self: *Host) void {
        const resources = self.core.resources;
        const key = @intFromPtr(self.window);
        resources.registerAtlasConsumer(key);
        self.core.atlas_consumer_key = key;
        self.window.bindCore(.{
            .queue = &self.core.queue,
            .query = &self.query,
            .context = self,
            .schedule_tick = scheduleTickErased,
            .modal_turn = modalTurnErased,
            .screen_reader_requested = screenReaderRequestedErased,
        });
        self.window.setUserData(self);
        self.window.setCloseCallback(onClose);
        self.core.presenter = .{ .context = self, .draw = draw };
        self.core.file_dialog = .{ .context = self, .open = openDialog };
        // The decode worker wakes the main loop when an image lands.
        self.core.images.bindWake(.{ .context = self, .wake = scheduleTickErased });
        self.core.clipboard.service = .{
            .context = self,
            .read = clipboardRead,
            .write = clipboardWrite,
        };
        // `syncIme` alone attaches the input context, while a field is focused.
        self.window.setImeEnabled(false);
        self.core.bindScreenReader(&self.window.uia_host, null);
        assert(self.window.core != null);
    }

    /// Stop the render thread and wait for it, then unbind what `bindWindow`
    /// bound. No draw can start afterwards.
    pub fn deinit(self: *Host) void {
        if (self.thread) |thread| {
            self.stopping.store(true, .release);
            signal(self.render_wake);
            self.waitForRenderThread();
            thread.join();
            self.thread = null;
        }
        self.unbindWindow();
        self.deinitHandles();
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
        self.core.images.bindWake(null);
        self.core.clipboard.service = null;
        // Withdraws the UI Automation root before the window is destroyed.
        self.core.unbindScreenReader();
    }

    /// Wait for the render thread's last present. A Vulkan present or
    /// swapchain rebuild may send the window's thread a message and wait for
    /// the reply, so the wait handles sent messages, and only those: queued
    /// input stays queued and no tick runs.
    fn waitForRenderThread(self: *Host) void {
        assert(self.stopping.load(.acquire));
        const handles = [1]win32.HANDLE{self.render_done};
        var waits: u32 = 0;
        while (waits < join_wait_count_max) : (waits += 1) {
            const result = win32.MsgWaitForMultipleObjectsEx(
                handles.len,
                &handles,
                win32.INFINITE,
                win32.QS_SENDMESSAGE,
                0,
            );
            if (result == win32.WAIT_OBJECT_0) return;
            if (result == win32.WAIT_FAILED) waitFailed("the render thread's exit");
            assert(result == win32.WAIT_OBJECT_0 + handles.len);
            // Delivers the sent messages; removes nothing from the queue.
            var message: win32.MSG = undefined;
            const sent_only = win32.PM_NOREMOVE | win32.PM_QS_SENDMESSAGE;
            _ = win32.PeekMessageW(&message, null, 0, 0, sent_only);
        }
        std.debug.panic("core host: the render thread did not stop after {d} waits", .{
            join_wait_count_max,
        });
    }

    /// Schedule one main tick unless one is already scheduled. Any thread.
    pub fn scheduleTick(self: *Host) void {
        if (self.tick_scheduled.swap(true, .acq_rel)) return;
        signal(self.main_wake);
    }

    fn scheduleTickErased(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.scheduleTick();
    }

    fn modalTurnErased(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.modalTurn();
    }

    fn screenReaderRequestedErased(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        self.screen_reader_requested = true;
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

    /// The message loop. Each turn runs at most one tick, syncs the IME,
    /// waits, and dispatches one bounded batch of messages, so every turn is
    /// bounded; the loop ends when the window closes or the app quits.
    fn runLoop(self: *Host) void {
        assert(self.thread != null);
        while (!self.quit) {
            self.turn();
            if (self.quit) break;
            self.waitForMessages();
            if (!platform_mod.dispatchMessageBatch()) break;
        }
        assert(self.core.phase == .idle);
    }

    /// A turn's own work: the scheduled tick, then the IME.
    fn turn(self: *Host) void {
        assert(self.core.phase == .idle);
        if (self.tick_scheduled.swap(false, .acq_rel)) self.mainTick();
        if (!self.quit) self.syncIme();
    }

    /// A turn from inside a modal move or resize loop, which dispatches the
    /// messages and paces these turns with its timer, so there is no wait.
    /// A tick still running (a file dialog's own loop) is not re-entered.
    fn modalTurn(self: *Host) void {
        if (self.core.phase != .idle) return;
        // Schedules the tick a passed render deadline needs.
        _ = self.deadlineWaitNs();
        self.turn();
    }

    /// One main-side tick, then either hand the published frame to the
    /// render thread or keep ticking while work is pending.
    fn mainTick(self: *Host) void {
        assert(self.core.phase == .idle);
        self.syncViewport();
        if (self.screen_reader_requested) self.activateScreenReader();
        self.tick_main(self.app, self.nowNs());
        assert(self.core.phase == .idle);
        self.applyCursor();
        if (self.core.quit_requested) {
            self.quit = true;
            return;
        }
        // A render requested while a frame is in flight waits for the
        // render thread, which schedules a tick after it presents.
        const in_flight = self.core.frame_in_flight.load(.acquire);
        if (in_flight) signal(self.render_wake);
        const pending = self.core.render_requested or self.core.queue.count > 0;
        if (pending and !in_flight) self.scheduleTick();
    }

    /// Push the window's logical size and scale when they changed, or when
    /// the window can show frames again: the frames built while it could not
    /// were skipped. Read once per tick, so a live resize queues one event
    /// per tick rather than one per `WM_SIZE`.
    fn syncViewport(self: *Host) void {
        assert(self.core.phase == .idle);
        const presentable = self.window.isPresentable();
        const restored = presentable and !self.presentable.load(.monotonic);
        self.presentable.store(presentable, .release);
        if (!presentable) return;
        const viewport = Viewport{
            .width = @floatCast(self.window.size.width),
            .height = @floatCast(self.window.size.height),
            .scale_factor = @floatCast(self.window.scale_factor),
        };
        assert(viewport.width > 0);
        assert(viewport.scale_factor > 0);
        if (!restored and std.meta.eql(viewport, self.viewport_sent)) return;
        self.core.queue.push(.{ .window = .{ .resized = .{
            .width = viewport.width,
            .height = viewport.height,
            .scale_factor = viewport.scale_factor,
        } } });
        self.viewport_sent = viewport;
    }

    /// A UI Automation client's first root request. The core asks the bridge
    /// whether a screen reader runs at most once a second, on rendered
    /// frames, so an idle app could leave the client with no tree: poll at
    /// the next rendered frame, and render one.
    fn activateScreenReader(self: *Host) void {
        assert(self.core.phase == .idle);
        assert(self.window.uia_host.client_requested);
        self.screen_reader_requested = false;
        self.core.screen_reader_poll = .{};
        self.core.render_requested = true;
    }

    /// Wait for a message, a scheduled tick, or the last build's render
    /// deadline (`cx.requestRenderAfter`, caret blink). A passed deadline
    /// schedules the tick that fires it.
    fn waitForMessages(self: *Host) void {
        const wait_ns = self.deadlineWaitNs();
        if (self.tick_scheduled.load(.acquire) or self.quit) return;
        const handles = [2]win32.HANDLE{ self.main_wake, self.platform.frame_timer };
        var handle_count: u32 = 1;
        var backstop_ms: u32 = win32.INFINITE;
        if (wait_ns) |ns| {
            armTimer(self.platform.frame_timer, ns);
            handle_count = 2;
            backstop_ms = backstopMs(ns);
        }
        const result = win32.MsgWaitForMultipleObjectsEx(
            handle_count,
            &handles,
            backstop_ms,
            win32.QS_ALLINPUT,
            win32.MWMO_INPUTAVAILABLE,
        );
        if (result == win32.WAIT_FAILED) waitFailed("the main loop");
        // A handle, input (index `handle_count`), or the backstop.
        assert(result <= win32.WAIT_OBJECT_0 + handle_count or result == win32.WAIT_TIMEOUT);
    }

    /// Nanoseconds until the render deadline, at most `deadline_wait_ns_max`,
    /// or null without one. A passed deadline schedules a tick instead.
    fn deadlineWaitNs(self: *Host) ?u64 {
        const deadline_ns = self.core.renderDeadlineNs() orelse return null;
        const now_ns = self.nowNs();
        if (now_ns < deadline_ns) return @min(deadline_ns - now_ns, deadline_wait_ns_max);
        self.scheduleTick();
        return null;
    }

    /// Set the cursor the tick resolved from the hovered record, only when it
    /// changed, so an idle pointer makes no cursor calls.
    fn applyCursor(self: *Host) void {
        assert(self.core.phase == .idle);
        if (self.core.cursor == self.cursor) return;
        self.window.setCursorShape(self.core.cursor);
        self.cursor = self.core.cursor;
        assert(self.cursor == self.core.cursor);
    }

    /// Give the rendered frame's IME state to the window: the input context
    /// is attached while a text field is focused, and the candidate list
    /// follows the caret rect the core's `Query` answers. The window tells
    /// the IME only when the rect moved.
    fn syncIme(self: *Host) void {
        const caret = self.query.imeCursorRect() orelse {
            if (self.ime_enabled) self.window.setImeEnabled(false);
            self.ime_enabled = false;
            return;
        };
        assert(caret.width >= 0);
        assert(caret.height >= 0);
        if (!self.ime_enabled) self.window.setImeEnabled(true);
        self.ime_enabled = true;
        self.window.setImeCursorRect(caret.x, caret.y, caret.width, caret.height);
    }

    // =========================================================================
    // Render thread
    // =========================================================================

    /// A frame is in flight and the display is ready for it.
    fn presentDue(self: *const Host) bool {
        if (!self.core.frame_in_flight.load(.acquire)) return false;
        return self.nowNs() >= self.present_due_ns;
    }

    /// Present the frame in flight, hold the next present for the next
    /// refresh, then let the main thread make the frame `rendered` and build
    /// the next.
    fn presentFrame(self: *Host) void {
        assert(self.core.frame_in_flight.load(.acquire));
        core_tick.presentBuilt(self.core);
        assert(!self.core.frame_in_flight.load(.acquire));
        self.present_due_ns = self.nowNs() + self.refreshWaitNs();
        self.scheduleTick();
    }

    /// Wait for a published frame, the next present's due time, or `deinit`.
    fn renderWait(self: *Host) void {
        const handles = [2]win32.HANDLE{ self.render_wake, self.render_timer };
        var handle_count: u32 = 1;
        var backstop_ms: u32 = win32.INFINITE;
        if (self.core.frame_in_flight.load(.acquire)) {
            const wait_ns = self.present_due_ns -| self.nowNs();
            if (wait_ns == 0) return;
            armTimer(self.render_timer, wait_ns);
            handle_count = 2;
            backstop_ms = backstopMs(wait_ns);
        }
        const wait_all = win32.FALSE;
        const result = win32.WaitForMultipleObjects(handle_count, &handles, wait_all, backstop_ms);
        if (result == win32.WAIT_FAILED) waitFailed("the render thread");
        assert(result < win32.WAIT_OBJECT_0 + handle_count or result == win32.WAIT_TIMEOUT);
    }

    /// Nanoseconds from now to the first vertical blank at least half a
    /// refresh away, from DWM's timing for the primary display, or one
    /// fallback period when DWM reports none usable.
    fn refreshWaitNs(self: *const Host) u64 {
        var info: [win32.DwmTimingInfo.bytes_count]u8 align(4) = @splat(0);
        std.mem.writeInt(u32, info[0..4], win32.DwmTimingInfo.bytes_count, .little);
        if (win32.DwmGetCompositionTimingInfo(null, &info) < 0) return refresh_period_ns_fallback;
        const period_offset = win32.DwmTimingInfo.refresh_period_offset;
        const vblank_offset = win32.DwmTimingInfo.vblank_offset;
        const period_ticks = std.mem.readInt(u64, info[period_offset..][0..8], .little);
        const vblank_ticks = std.mem.readInt(u64, info[vblank_offset..][0..8], .little);
        const period_ns = ticksToNs(period_ticks, self.qpc_frequency);
        if (period_ns < refresh_period_ns_min) return refresh_period_ns_fallback;
        if (period_ns > refresh_period_ns_max) return refresh_period_ns_fallback;
        const wait_ticks = vblankWaitTicks(.{
            .now_ticks = qpcNow(),
            .vblank_ticks = vblank_ticks,
            .period_ticks = period_ticks,
        });
        const wait_ns = ticksToNs(wait_ticks, self.qpc_frequency);
        assert(wait_ns <= 2 * period_ns);
        return wait_ns;
    }

    /// Bring the swapchain to the frame's viewport before drawing it, and
    /// rebuild a swapchain a failed rebuild left without framebuffers. The
    /// framebuffer takes the frame's exact logical size at its scale, so a
    /// fractional scale draws at that scale across the whole client area.
    fn applyViewport(self: *Host, frame: *const records.Frame) void {
        assert(frame.viewport_width > 0);
        assert(frame.viewport_height > 0);
        const viewport = backend.Viewport.fitLogical(
            frame.viewport_width,
            frame.viewport_height,
            frame.scale_factor,
            &self.window.window_limits,
        );
        const renderer = &self.window.renderer;
        const same = std.meta.eql(viewport, self.viewport);
        if (same and window_mod.rendererSwapchainUsable(renderer)) return;
        self.viewport = viewport;
        renderer.resize(viewport.size_px);
    }
};

fn renderThreadMain(host: *Host) void {
    while (!host.stopping.load(.acquire)) {
        if (host.presentDue()) {
            host.presentFrame();
        } else {
            host.renderWait();
        }
    }
    signal(host.render_done);
}

/// The core's presenter, on the render thread. While the window cannot show
/// a frame (minimized, or no client area) the surface has no extent, so the
/// frame is skipped; the main thread pushes a resize once it can again.
fn draw(
    context: *anyopaque,
    packed_frame: *const core_window.PackedFrame,
    frame: *const records.Frame,
    clear: records.Color,
) void {
    const host: *Host = @ptrCast(@alignCast(context));
    assert(frame.scale_factor > 0);
    assert(host.core.render_phase == .draw);
    // A minimized window draws nothing; its atlas records stay journaled.
    if (!host.presentable.load(.acquire)) return;
    host.applyViewport(frame);
    const renderer = &host.window.renderer;
    if (!window_mod.rendererSwapchainUsable(renderer)) {
        // Retried at the next frame's `applyViewport`.
        if (!host.swapchain_failure_logged) {
            std.log.err("core host: frame {d} not drawn: swapchain rebuild for {d}x{d} failed", .{
                frame.frame_number,
                host.viewport.size_px.width,
                host.viewport.size_px.height,
            });
        }
        host.swapchain_failure_logged = true;
        return;
    }
    host.swapchain_failure_logged = false;
    // Pending atlas regions stay in the journal while frames are skipped.
    const uploads = host.core.resources.atlas_uploads;
    backend.uploadPendingAtlases(renderer, uploads, host.core.atlas_consumer_key);
    renderer.draw(packed_frame, host.viewport, clear);
    // An out-of-date swapchain skips the frame and is rebuilt by the next
    // draw; draw this frame again rather than leave a stale one on screen.
    if (renderer.swapchain_needs_recreate) renderer.draw(packed_frame, host.viewport, clear);
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
/// Common Item Dialog runs its own modal loop with the window disabled; it
/// reports cancel and failure alike as no selection (failures are logged),
/// so both arrive as `cancelled`, as on macOS and Linux.
fn openDialog(
    context: *anyopaque,
    scratch: std.mem.Allocator,
    request_id: u32,
    request: core_handler.FileDialogRequest,
) ?Outcome {
    const host: *Host = @ptrCast(@alignCast(context));
    // The modal loop returns the outcome; the core queues it under this id.
    _ = request_id;
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
// Pacing
// =============================================================================

/// The clock `vblankWaitTicks` reads, in `QueryPerformanceCounter` ticks;
/// named because every field shares a type.
const VblankClock = struct {
    now_ticks: u64,
    /// A recent vertical blank, from `DWM_TIMING_INFO.qpcVBlank`.
    vblank_ticks: u64,
    period_ticks: u64,
};

/// Ticks from now to the first vertical blank on `clock`'s grid that is at
/// least half a period away, so two presents never share a refresh. DWM's
/// vertical blank may be just ahead of or behind `now`.
fn vblankWaitTicks(clock: VblankClock) u64 {
    const period = clock.period_ticks;
    assert(period > 1);
    var wait = if (clock.now_ticks >= clock.vblank_ticks)
        period - (clock.now_ticks - clock.vblank_ticks) % period
    else
        (clock.vblank_ticks - clock.now_ticks) % period;
    if (2 * wait < period) wait += period;
    assert(2 * wait >= period);
    assert(2 * wait <= 3 * period);
    return wait;
}

fn ticksToNs(ticks: u64, frequency: u64) u64 {
    assert(frequency > 0);
    const ns = @as(u128, ticks) * std.time.ns_per_s / frequency;
    return @intCast(@min(ns, std.math.maxInt(u64)));
}

/// Never fails on Windows XP and later, which the backend requires.
fn qpcNow() u64 {
    var ticks: i64 = 0;
    const queried = win32.QueryPerformanceCounter(&ticks);
    assert(queried != win32.FALSE);
    assert(ticks >= 0);
    return @intCast(ticks);
}

fn qpcFrequency() u64 {
    var frequency: i64 = 0;
    const queried = win32.QueryPerformanceFrequency(&frequency);
    assert(queried != win32.FALSE);
    assert(frequency > 0);
    return @intCast(frequency);
}

// =============================================================================
// Events and timers
// =============================================================================

fn createEvent(options: struct { manual_reset: bool }) !win32.HANDLE {
    const manual_reset: win32.BOOL = if (options.manual_reset) win32.TRUE else win32.FALSE;
    return win32.CreateEventW(null, manual_reset, win32.FALSE, null) orelse {
        std.log.err("core host: CreateEventW failed (error {d})", .{win32.GetLastError()});
        return error.EventCreationFailed;
    };
}

fn closeHandle(handle: win32.HANDLE) void {
    if (win32.CloseHandle(handle) == win32.FALSE) {
        std.log.warn("core host: CloseHandle failed (error {d})", .{win32.GetLastError()});
    }
}

/// `SetEvent` fails only for a handle that is not an event, a programmer
/// error.
fn signal(event: win32.HANDLE) void {
    if (win32.SetEvent(event) != win32.FALSE) return;
    std.debug.panic("core host: SetEvent failed (error {d})", .{win32.GetLastError()});
}

/// Arm `timer` to signal `wait_ns` from now, rounded up so it never fires
/// early. Fails only for a handle that is not a timer.
fn armTimer(timer: win32.HANDLE, wait_ns: u64) void {
    assert(wait_ns > 0);
    assert(wait_ns <= deadline_wait_ns_max);
    const intervals = std.math.divCeil(u64, wait_ns, timer_interval_ns) catch
        unreachable; // The divisor is a nonzero constant.
    const due_time = -@as(i64, @intCast(intervals));
    if (win32.SetWaitableTimer(timer, &due_time, 0, null, null, win32.FALSE) != win32.FALSE) {
        return;
    }
    std.debug.panic("core host: SetWaitableTimer failed (error {d})", .{win32.GetLastError()});
}

/// A millisecond backstop that never ends a wait before its timer: rounded
/// up, plus one for the system tick's granularity.
fn backstopMs(wait_ns: u64) u32 {
    assert(wait_ns > 0);
    assert(wait_ns <= deadline_wait_ns_max);
    const wait_ms = std.math.divCeil(u64, wait_ns, std.time.ns_per_ms) catch
        unreachable; // The divisor is a nonzero constant.
    assert(wait_ms + 1 < win32.INFINITE);
    return @intCast(wait_ms + 1);
}

/// A wait on handles this host owns fails only if one is invalid.
fn waitFailed(waiter: []const u8) noreturn {
    std.debug.panic("core host: the wait in {s} failed (error {d})", .{
        waiter,
        win32.GetLastError(),
    });
}

// =============================================================================
// Clipboard
// =============================================================================

/// The text engines' clipboard, main thread. `readText` decodes straight
/// into the core's reserved paste buffer.
fn clipboardRead(_: *anyopaque, out: []u8) u32 {
    return clipboard.readText(out);
}

fn clipboardWrite(_: *anyopaque, text: []const u8) void {
    if (!clipboard.setText(text)) std.log.warn("core host: clipboard write failed", .{});
}

comptime {
    assert(refresh_period_ns_min < refresh_period_ns_fallback);
    assert(refresh_period_ns_fallback < refresh_period_ns_max);
    // The deadline wait's backstop must fit a `u32` of milliseconds.
    assert(@divFloor(deadline_wait_ns_max, std.time.ns_per_ms) + 2 < std.math.maxInt(u32));
}

test "the next present waits for a vertical blank at least half a refresh away" {
    // Goal: at most one present per refresh, on the display's grid.
    // Methodology: a 1,000-tick period with now on either side of the half
    // period, exactly on a vertical blank, and before a reported blank.
    const period: u64 = 1_000;
    const blank: u64 = 50_000;
    try std.testing.expectEqual(@as(u64, 501), vblankWaitTicks(.{
        .now_ticks = blank + 499,
        .vblank_ticks = blank,
        .period_ticks = period,
    }));
    try std.testing.expectEqual(@as(u64, 500), vblankWaitTicks(.{
        .now_ticks = blank + 500,
        .vblank_ticks = blank,
        .period_ticks = period,
    }));
    // 499 to the next blank is under half a period: skip to the one after.
    try std.testing.expectEqual(@as(u64, 1_499), vblankWaitTicks(.{
        .now_ticks = blank + 501,
        .vblank_ticks = blank,
        .period_ticks = period,
    }));
    try std.testing.expectEqual(period, vblankWaitTicks(.{
        .now_ticks = blank + 3 * period,
        .vblank_ticks = blank,
        .period_ticks = period,
    }));
    try std.testing.expectEqual(@as(u64, 700), vblankWaitTicks(.{
        .now_ticks = blank - 700,
        .vblank_ticks = blank,
        .period_ticks = period,
    }));
    try std.testing.expectEqual(@as(u64, 1_200), vblankWaitTicks(.{
        .now_ticks = blank - 200,
        .vblank_ticks = blank,
        .period_ticks = period,
    }));
}

test "QPC ticks convert to nanoseconds without overflow" {
    // One tick of a 60 Hz counter is a 60 Hz refresh, rounded down.
    try std.testing.expectEqual(@as(u64, 16_666_666), ticksToNs(1, 60));
    try std.testing.expectEqual(@as(u64, 16_666_600), ticksToNs(166_666, 10_000_000));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), ticksToNs(3, 3));
    const day_ticks: u64 = 24 * 3600 * 10_000_000;
    try std.testing.expectEqual(24 * 3600 * std.time.ns_per_s, ticksToNs(day_ticks, 10_000_000));
}
