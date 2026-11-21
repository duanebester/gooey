//! Runs a core app full-screen on an EVE panel: the EVE backend's app path,
//! modelled on the fbdev host (`../fbdev/core_host.zig`). One thread: the
//! chip draws, so the render side runs on the main thread right after the
//! main side; `EveRenderer.draw` first waits for the previous list to reach
//! the screen, so continuous animation runs at the panel's refresh with no
//! timer.
//!
//! Each loop turn reads the touch engine once (when the queue has room for a
//! touch's events), ticks when work is pending, and otherwise waits in
//! `poll` on a wake eventfd for at most `touch_poll_ns`, the render
//! deadline, or the image worker's wake.
//!
//! There is no keyboard, input method, or file dialog (a request completes
//! as `error.FileDialogUnsupported`); the clipboard is in-process
//! (`../fbdev/clipboard.zig`, which has no fbdev dependency).
//!
//! Every allocation happens before `finishInit`; the core's guard panics on
//! any later one.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const platform_mod = @import("platform.zig");
const window_mod = @import("window.zig");
const chip_mod = @import("chip.zig");
const eve_limits = @import("limits.zig");
const clipboard = @import("../fbdev/clipboard.zig");
const input = @import("../../input/events.zig");
const core_window = @import("../../core/window.zig");
const core_limits = @import("../../core/limits.zig");
const backend = @import("../../core/backend.zig");
const core_router = @import("../../core/router.zig");
const core_events = @import("../../core/events.zig");
const core_handler = @import("../../core/handler.zig");
const records = @import("../../core/records.zig");

const assert = std.debug.assert;

const EvePlatform = platform_mod.EvePlatform;
const EveWindow = window_mod.Window;
const Outcome = core_events.Completion.Outcome;

comptime {
    // Every profile's queue holds the largest host burst (`ResourceLimits.check`).
    assert(platform_mod.touch_event_count_max <= core_limits.input_burst_count_max);
}

/// Run `App` until its window closes. Everything is reserved before
/// `finishInit`; the core's guard owns every allocation, the platform's too.
pub fn run(comptime App: type, app: *App, backing: std.mem.Allocator, io: std.Io) !void {
    comptime {
        // The app's own budget: the debugger overlay's headroom in
        // `limits_reserved` needs a keyboard shortcut the panel cannot send.
        if (eve_limits.EveLimits.bt81x.check(&App.limits)) |reason| {
            @compileError("the EVE backend cannot hold this app's ResourceLimits: " ++ reason);
        }
    }
    app.beginInit(backing);
    const gpa = app.guard.allocator();

    const platform = try gpa.create(EvePlatform);
    defer gpa.destroy(platform);
    try platform.initInPlace();
    defer platform.deinit();

    // The window covers the panel; `width` and `height` are ignored.
    const window = try EveWindow.init(gpa, platform, &.{
        .title = App.title,
        .width = @floatFromInt(App.width),
        .height = @floatFromInt(App.height),
        .background_color = App.theme.bg,
        .limits = App.limits_reserved,
    });
    defer window.deinit();

    try app.initCore(io, 1);
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
    platform: *EvePlatform,
    window: *EveWindow,
    core: *core_window.Window,
    query: core_router.Query,
    /// Wakes the loop from the image worker (`scheduleTick`).
    wake_fd: posix.fd_t,
    /// A tick is scheduled and has not started. Written by the worker.
    tick_scheduled: std.atomic.Value(bool),

    /// Bind the window's input, the presenter, and the services. The host
    /// must stay at this address.
    pub fn initInPlace(
        self: *Host,
        platform: *EvePlatform,
        window: *EveWindow,
        core: *core_window.Window,
    ) !void {
        assert(core.presenter == null);
        assert(!window.isClosed());
        self.platform = platform;
        self.window = window;
        self.core = core;
        self.query = .{ .window = core };
        try clipboard.reserve(core.gpa, @intCast(core.clipboard_bytes.len));
        errdefer clipboard.release(core.gpa);
        self.wake_fd = try eventFd();
        self.tick_scheduled = .init(true);
        self.bindWindow();
        assert(self.core.presenter != null);
    }

    fn bindWindow(self: *Host) void {
        // The renderer consumes the upload journal as this window: `draw`
        // feeds it this consumer's records before each frame.
        const key = @intFromPtr(self.window);
        self.core.resources.registerAtlasConsumer(key);
        // The chip draws list N from its image mirror while frame N+1 writes
        // new texels into it, so frame N's shelves stay until N+1 uploads.
        self.core.resources.atlas_uploads.protectShownFrame(key);
        self.core.atlas_consumer_key = key;
        self.window.setUserData(self);
        self.window.setInputCallback(onInput);
        self.core.presenter = .{ .context = self, .draw = draw };
        self.core.file_dialog = .{ .context = self, .open = openDialog };
        self.core.bindWake(.{ .context = self, .wake = scheduleTickErased });
        self.core.clipboard.service = .{
            .context = self,
            .read = clipboardRead,
            .write = clipboardWrite,
        };
        // The window covers the panel, whatever size the app asked for.
        self.core.bindViewport(.{
            .width = @floatCast(self.window.size.width),
            .height = @floatCast(self.window.size.height),
            .scale_factor = 1,
        });
        assert(self.window.on_input != null);
    }

    pub fn deinit(self: *Host) void {
        assert(self.core.phase == .idle);
        assert(self.core.atlas_consumer_key == @intFromPtr(self.window));
        self.core.resources.unregisterAtlasConsumer(self.core.atlas_consumer_key);
        self.window.setInputCallback(null);
        self.window.setUserData(null);
        self.core.presenter = null;
        self.core.file_dialog = null;
        self.core.bindWake(null);
        self.core.clipboard.service = null;
        clipboard.release(self.core.gpa);
        _ = std.c.close(self.wake_fd);
        self.wake_fd = -1;
    }

    fn scheduleTickErased(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        if (self.tick_scheduled.swap(true, .acq_rel)) return;
        signal(self.wake_fd);
    }

    /// Each turn reads touch once, runs at most one tick, then waits, so
    /// every turn is bounded; it ends when the window closes or the app
    /// quits.
    fn runLoop(self: *Host, comptime App: type, app: *App) void {
        assert(&app.window == self.core);
        while (!self.window.isClosed()) {
            const now_ns = chip_mod.nowNanoseconds();
            if (self.core.queue.room() >= platform_mod.touch_event_count_max) {
                self.platform.dispatchTouch(@truncate(now_ns / std.time.ns_per_ms));
            }
            if (self.tickDue(now_ns)) {
                _ = self.tick_scheduled.swap(false, .acq_rel);
                app.tick(now_ns);
                if (self.core.quit_requested) break;
                continue;
            }
            if (!self.wait()) break;
        }
        assert(self.core.phase == .idle);
    }

    fn tickDue(self: *const Host, now_ns: u64) bool {
        if (self.core.render_requested) return true;
        if (self.core.renderDeadlineNs()) |deadline| {
            if (now_ns >= deadline) return true;
        }
        return self.core.queue.count > 0 or self.tick_scheduled.load(.acquire);
    }

    fn wait(self: *Host) bool {
        assert(self.wake_fd >= 0);
        var pollfds = [_]posix.pollfd{
            .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        // `poll` fails only on a bad descriptor or a lack of kernel memory;
        // neither leaves a way to wait, so stop.
        _ = posix.poll(&pollfds, self.timeoutMs()) catch |err| {
            std.log.err("eve core host: poll failed: {t}", .{err});
            return false;
        };
        if ((pollfds[0].revents & posix.POLL.IN) != 0) drain(self.wake_fd);
        return true;
    }

    fn timeoutMs(self: *const Host) i32 {
        const now_ns = chip_mod.nowNanoseconds();
        var wake_ns = now_ns + platform_mod.touch_poll_ns;
        if (self.core.renderDeadlineNs()) |deadline| wake_ns = @min(wake_ns, deadline);
        if (now_ns >= wake_ns) return 0;
        const remaining_ms = std.math.divCeil(u64, wake_ns - now_ns, std.time.ns_per_ms) catch
            unreachable; // The divisor is a nonzero constant.
        assert(remaining_ms > 0);
        assert(remaining_ms <= platform_mod.touch_poll_ns / std.time.ns_per_ms + 1);
        return @intCast(remaining_ms);
    }
};

/// The window's input callback, during `dispatchTouch`: queue the event for
/// the next tick. There is no keyboard, so nothing counts as handled.
fn onInput(window: *EveWindow, event: input.InputEvent) bool {
    const host = window.getUserData(Host).?;
    assert(host.window == window);
    host.core.queue.push(.{ .input = event });
    return false;
}

fn draw(
    context: *anyopaque,
    packed_frame: *const core_window.PackedFrame,
    frame: *const records.Frame,
    clear: records.Color,
) void {
    const host: *Host = @ptrCast(@alignCast(context));
    assert(frame.scale_factor == 1);
    assert(packed_frame == &host.core.packed_frame);
    assert(host.core.render_phase == .draw);
    const renderer = &host.window.renderer;
    const uploads = host.core.resources.atlas_uploads;
    backend.uploadPendingAtlases(renderer, uploads, host.core.atlas_consumer_key);
    backend.checkCapabilities(renderer.capabilities(), packed_frame);
    host.window.presentFrame(packed_frame, clear);
}

/// No file dialog exists on a bare panel; the request completes as a
/// failure the app's handler sees.
fn openDialog(
    context: *anyopaque,
    scratch: std.mem.Allocator,
    request_id: u32,
    request: core_handler.FileDialogRequest,
) ?Outcome {
    const host: *Host = @ptrCast(@alignCast(context));
    _ = scratch;
    _ = request_id;
    _ = request;
    assert(host.core.phase == .drain);
    std.log.warn("eve core host: the EVE backend has no file dialog", .{});
    return .{ .failed = error.FileDialogUnsupported };
}

fn clipboardRead(_: *anyopaque, out: []u8) u32 {
    return clipboard.readText(out);
}

fn clipboardWrite(_: *anyopaque, text: []const u8) void {
    if (!clipboard.setText(text)) std.log.warn("eve core host: clipboard write failed", .{});
}

fn eventFd() !posix.fd_t {
    const fd = std.c.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (fd < 0) return error.EventFdCreationFailed;
    return fd;
}

/// Add one to the eventfd's counter. The counter cannot overflow (it is
/// drained every wait), so the write cannot fail.
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
        else => std.debug.panic("eve core host: eventfd read failed: {t}", .{err}),
    };
    assert(read_bytes == @sizeOf(u64));
}
