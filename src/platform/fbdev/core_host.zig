//! Runs a 0.4.0 core app full-screen on the kernel framebuffer (contract
//! decision 17): the fbdev backend's app path once the 0.3.1 runtime goes.
//!
//! One thread. There is no compositor and no GPU, so the render side runs on
//! the main thread right after the main side, as on TestBackend (`App.tick`):
//! the CPU renderer draws into the window's back buffer and the window copies
//! it to the panel. Each loop turn waits in `poll` on the evdev devices and a
//! wake eventfd, dispatches what arrived into the core's queue, and ticks when
//! work is pending. A tick that would build waits until the last present is
//! `frame_period_ns_min` old, so frames stay at or under 60 Hz while input
//! keeps queueing (pointer moves coalesce in the queue).
//!
//! The software cursor is drawn over each frame. A pointer move that renders
//! nothing new re-presents the last packed scene under the moved cursor; the
//! scene stays untouched until the next pack, which only this thread runs.
//!
//! Without a display server there is no input method (the IME query is never
//! asked), no file dialog (a request completes as `error.FileDialogUnsupported`),
//! and an in-process clipboard (`clipboard.zig`). Ctrl+Q and Alt+F4 close the
//! window unless the app's keymap claims them.
//!
//! Resource sketch: one eventfd, the window's panel-sized back buffer and the
//! CPU renderer's scratch (both reserved by the window at init), and no
//! thread. Per turn: one poll, at most `evdev.raw_batch_max` events per
//! device, at most one tick, and at most one raster of the panel. Every
//! allocation happens before `finishInit`; the core's guard panics on any
//! later one, the window's and the platform's included.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const platform_mod = @import("platform.zig");
const window_mod = @import("window.zig");
const clipboard = @import("clipboard.zig");
const evdev = @import("evdev.zig");
const input = @import("../../input/events.zig");
const scene_mod = @import("../../scene/mod.zig");
const core_window = @import("../../core/window.zig");
const core_router = @import("../../core/router.zig");
const core_events = @import("../../core/events.zig");
const core_handler = @import("../../core/handler.zig");
const records = @import("../../core/records.zig");

const assert = std.debug.assert;

const FbdevPlatform = platform_mod.FbdevPlatform;
const FbdevWindow = window_mod.Window;
const Outcome = core_events.Completion.Outcome;

/// Pollable descriptors: every input device plus the wake eventfd.
const poll_fd_count_max: u32 = evdev.device_count_max + 1;

/// Run `App` until its window closes. Everything is reserved before
/// `finishInit`; the core's guard owns every allocation, the platform's too.
pub fn run(comptime App: type, app: *App, backing: std.mem.Allocator, io: std.Io) !void {
    app.beginInit(backing);
    const gpa = app.guard.allocator();

    const platform = try gpa.create(FbdevPlatform);
    defer gpa.destroy(platform);
    try platform.initInPlace(gpa);
    defer platform.deinit();

    // The window covers the panel; `width` and `height` are ignored.
    const window = try FbdevWindow.init(gpa, platform, &.{
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
    try host.initInPlace(platform, window, &app.window);
    defer host.deinit();

    app.finishInit();
    // Deferred last, so it runs first: the guard leaves `running` before the
    // deferred teardown above frees the host, the window, and the platform.
    defer app.stop();
    assert(app.guard.lifecycle == .running);
    host.runLoop(App, app);
}

pub const Host = struct {
    platform: *FbdevPlatform,
    window: *FbdevWindow,
    core: *core_window.Window,
    query: core_router.Query,
    /// Wakes the loop from the image worker (`scheduleTick`).
    wake_fd: posix.fd_t,
    /// A tick is scheduled and has not started. Written by the worker.
    tick_scheduled: std.atomic.Value(bool),
    /// When the last frame reached the panel; null before the first.
    presented_ns: ?u64,
    /// A tick has packed a scene, so `core.scene` holds a whole frame.
    scene_packed: bool,
    /// The pointer moved since the cursor was last drawn.
    cursor_moved: bool,

    /// Bind the window's input, the presenter, and the services. The host
    /// must stay at this address.
    pub fn initInPlace(
        self: *Host,
        platform: *FbdevPlatform,
        window: *FbdevWindow,
        core: *core_window.Window,
    ) !void {
        assert(core.presenter == null);
        assert(!window.isClosed());
        self.platform = platform;
        self.window = window;
        self.core = core;
        self.query = .{ .window = core };
        self.wake_fd = try eventFd();
        self.tick_scheduled = .init(true);
        self.presented_ns = null;
        self.scene_packed = false;
        self.cursor_moved = false;
        self.bindWindow();
        assert(self.core.presenter != null);
    }

    fn bindWindow(self: *Host) void {
        const resources = self.core.resources;
        // The CPU renderer samples the atlases in place while it draws. The
        // render side runs on this thread between builds, so the atlases have
        // one writer at a time and no upload journal is consumed.
        self.window.setTextAtlas(resources.text_system.getAtlas());
        self.window.setSvgAtlas(&resources.svg_atlas.atlas);
        self.window.setImageAtlas(&resources.image_atlas.atlas);
        self.window.setUserData(self);
        self.window.setInputCallback(onInput);
        self.core.presenter = .{ .context = self, .draw = draw };
        self.core.file_dialog = .{ .context = self, .open = openDialog };
        self.core.images.bindWake(.{ .context = self, .wake = scheduleTickErased });
        self.core.clipboard.service = .{
            .context = self,
            .read = clipboardRead,
            .write = clipboardWrite,
        };
        // The window covers the panel, whatever size the app asked for.
        self.core.queue.push(.{ .window = .{ .resized = .{
            .width = @floatCast(self.window.size.width),
            .height = @floatCast(self.window.size.height),
            .scale_factor = @floatCast(self.window.scale_factor),
        } } });
        assert(self.window.on_input != null);
    }

    /// Unbind what `bindWindow` bound, after the loop has stopped.
    pub fn deinit(self: *Host) void {
        assert(self.core.phase == .idle);
        self.window.setInputCallback(null);
        self.window.setUserData(null);
        self.core.presenter = null;
        self.core.file_dialog = null;
        self.core.images.bindWake(null);
        self.core.clipboard.service = null;
        _ = std.c.close(self.wake_fd);
        self.wake_fd = -1;
    }

    fn scheduleTickErased(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        if (self.tick_scheduled.swap(true, .acq_rel)) return;
        signal(self.wake_fd);
    }

    /// The loop. Each turn runs at most one tick and one cursor-only present,
    /// then waits for and dispatches one batch of input, so every turn is
    /// bounded; it ends when the window closes or the app quits.
    fn runLoop(self: *Host, comptime App: type, app: *App) void {
        assert(&app.window == self.core);
        while (!self.window.isClosed()) {
            const now_ns = platform_mod.nowNanoseconds();
            if (self.tickDue(now_ns)) {
                _ = self.tick_scheduled.swap(false, .acq_rel);
                app.tick(now_ns);
                if (self.core.quit_requested) break;
            }
            if (self.cursor_moved) self.presentCursor(now_ns);
            if (!self.waitForInput()) break;
        }
        assert(self.core.phase == .idle);
    }

    /// Work is pending: queued events, a scheduled tick, a render request,
    /// or a passed render deadline. A tick that would build also waits out
    /// the frame period.
    fn tickDue(self: *const Host, now_ns: u64) bool {
        const deadline_passed = if (self.core.renderDeadlineNs()) |deadline|
            now_ns >= deadline
        else
            false;
        const renders = self.core.render_requested or deadline_passed;
        if (renders) return self.frameDue(now_ns);
        return self.core.queue.count > 0 or self.tick_scheduled.load(.acquire);
    }

    fn frameDue(self: *const Host, now_ns: u64) bool {
        const presented_ns = self.presented_ns orelse return true;
        return now_ns -| presented_ns >= platform_mod.frame_period_ns_min;
    }

    /// The pointer moved the software cursor. A tick that presented has
    /// drawn it already; otherwise re-present the last scene under it, at
    /// most once per frame period.
    fn presentCursor(self: *Host, now_ns: u64) void {
        assert(self.cursor_moved);
        if (!self.window.cursor_visible or !self.scene_packed) {
            self.cursor_moved = false;
            return;
        }
        if (!self.frameDue(now_ns)) return;
        self.cursor_moved = false;
        self.window.presentScene(self.core.scene, self.core.clear_color);
        self.presented_ns = now_ns;
    }

    /// Wait for input, the wake fd, the frame period, or the render deadline,
    /// then dispatch what arrived. Returns false when polling failed.
    fn waitForInput(self: *Host) bool {
        var pollfds: [poll_fd_count_max]posix.pollfd = undefined;
        const devices = self.platform.devices.slice();
        assert(devices.len < poll_fd_count_max);
        for (devices, pollfds[0..devices.len]) |device, *pollfd| {
            pollfd.* = .{ .fd = device.fd, .events = posix.POLL.IN, .revents = 0 };
        }
        const wake_index = devices.len;
        pollfds[wake_index] = .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 };
        // `poll` fails only on a bad descriptor array or a lack of kernel
        // memory; neither leaves a way to wait for input, so stop.
        _ = posix.poll(pollfds[0 .. wake_index + 1], self.timeoutMs()) catch |err| {
            std.log.err("fbdev core host: poll failed: {t}", .{err});
            return false;
        };
        if ((pollfds[wake_index].revents & posix.POLL.IN) != 0) drain(self.wake_fd);
        self.platform.dispatchInput(pollfds[0..wake_index]);
        return true;
    }

    /// 0 when a tick is due now; the time to the frame period or the render
    /// deadline when one waits; otherwise -1, until input or a wake arrives.
    fn timeoutMs(self: *const Host) i32 {
        const now_ns = platform_mod.nowNanoseconds();
        if (self.tickDue(now_ns)) return 0;
        var wake_ns: ?u64 = null;
        if (self.core.render_requested or self.cursor_moved) {
            // Not due, so a frame was presented less than a period ago.
            const presented_ns = self.presented_ns orelse return 0;
            wake_ns = presented_ns + platform_mod.frame_period_ns_min;
        }
        if (self.core.renderDeadlineNs()) |deadline| {
            wake_ns = if (wake_ns) |frame_ns| @min(frame_ns, deadline) else deadline;
        }
        const target_ns = wake_ns orelse return -1;
        if (now_ns >= target_ns) return 0;
        const remaining_ms = std.math.divCeil(u64, target_ns - now_ns, std.time.ns_per_ms) catch
            unreachable; // The divisor is a nonzero constant.
        assert(remaining_ms > 0);
        return @intCast(@min(remaining_ms, std.math.maxInt(i32)));
    }
};

/// The window's input callback, during `dispatchInput`: queue the event for
/// the next tick. Only a key the keymap claims counts as handled, so the
/// platform's Ctrl+Q and Alt+F4 still close the window otherwise.
fn onInput(window: *FbdevWindow, event: input.InputEvent) bool {
    const host = window.getUserData(Host).?;
    assert(host.window == window);
    host.core.queue.push(.{ .input = event });
    switch (event) {
        .mouse_down, .mouse_up, .mouse_moved, .mouse_dragged => host.cursor_moved = true,
        .touch_down, .touch_moved, .touch_up => host.cursor_moved = true,
        else => {},
    }
    return switch (event) {
        .key_down => |key| host.query.keymapClaims(key),
        else => false,
    };
}

/// The core's presenter, inside the tick's draw phase on this thread.
fn draw(
    context: *anyopaque,
    scene: *const scene_mod.Scene,
    frame: *const records.Frame,
    clear: records.Color,
) void {
    const host: *Host = @ptrCast(@alignCast(context));
    assert(frame.scale_factor > 0);
    assert(host.core.render_phase == .draw);
    assert(scene == host.core.scene);
    host.window.presentScene(scene, clear);
    // The frame drew the cursor where it is now.
    host.cursor_moved = false;
    host.scene_packed = true;
    host.presented_ns = platform_mod.nowNanoseconds();
}

/// No file dialog exists without a display server; the request completes
/// as a failure the app's handler sees.
fn openDialog(
    context: *anyopaque,
    scratch: std.mem.Allocator,
    request: core_handler.FileDialogRequest,
) Outcome {
    const host: *Host = @ptrCast(@alignCast(context));
    _ = scratch;
    _ = request;
    assert(host.core.phase == .drain);
    std.log.warn("fbdev core host: the fbdev backend has no file dialog", .{});
    return .{ .failed = error.FileDialogUnsupported };
}

fn clipboardRead(_: *anyopaque, out: []u8) u32 {
    return clipboard.readText(out);
}

fn clipboardWrite(_: *anyopaque, text: []const u8) void {
    if (!clipboard.setText(text)) std.log.warn("fbdev core host: clipboard write failed", .{});
}

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
        else => std.debug.panic("fbdev core host: eventfd read failed: {t}", .{err}),
    };
    assert(read_bytes == @sizeOf(u64));
}
