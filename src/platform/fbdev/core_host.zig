const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const platform_mod = @import("platform.zig");
const window_mod = @import("window.zig");
const clipboard = @import("clipboard.zig");
const evdev = @import("evdev.zig");
const input = @import("../../input/events.zig");
const core_window = @import("../../core/window.zig");
const core_limits = @import("../../core/limits.zig");
const backend = @import("../../core/backend.zig");
const core_router = @import("../../core/router.zig");
const core_events = @import("../../core/events.zig");
const core_handler = @import("../../core/handler.zig");
const records = @import("../../core/records.zig");

const assert = std.debug.assert;

const FbdevPlatform = platform_mod.FbdevPlatform;
const FbdevWindow = window_mod.Window;
const Outcome = core_events.Completion.Outcome;

const poll_fd_count_max: u32 = evdev.device_count_max + 1;

pub const input_room_count_min: u32 = evdev.Batch.capacity;

comptime {
    assert(input_room_count_min <= core_limits.input_burst_count_max);
}

pub fn run(comptime App: type, app: *App, backing: std.mem.Allocator, io: std.Io) !void {
    app.beginInit(backing);
    const gpa = app.guard.allocator();

    const platform = try gpa.create(FbdevPlatform);
    defer gpa.destroy(platform);
    try platform.initInPlace();
    defer platform.deinit();

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
    defer app.stop();
    assert(app.guard.lifecycle == .running);
    host.runLoop(App, app);
}

pub const Host = struct {
    platform: *FbdevPlatform,
    window: *FbdevWindow,
    core: *core_window.Window,
    query: core_router.Query,
    wake_fd: posix.fd_t,
    tick_scheduled: std.atomic.Value(bool),
    presented_ns: ?u64,
    frame_packed: bool,
    cursor_moved: bool,

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
        try clipboard.reserve(core.gpa, @intCast(core.clipboard_bytes.len));
        errdefer clipboard.release(core.gpa);
        self.wake_fd = try eventFd();
        self.tick_scheduled = .init(true);
        self.presented_ns = null;
        self.frame_packed = false;
        self.cursor_moved = false;
        self.bindWindow();
        assert(self.core.presenter != null);
    }

    fn bindWindow(self: *Host) void {
        const key = @intFromPtr(self.window);
        self.core.resources.registerAtlasConsumer(key);
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
        self.core.bindViewport(.{
            .width = @floatCast(self.window.size.width),
            .height = @floatCast(self.window.size.height),
            .scale_factor = @floatCast(self.window.scale_factor),
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

    fn presentCursor(self: *Host, now_ns: u64) void {
        assert(self.cursor_moved);
        if (!self.window.cursor_visible or !self.frame_packed) {
            self.cursor_moved = false;
            return;
        }
        if (!self.frameDue(now_ns)) return;
        self.cursor_moved = false;
        self.window.presentFrame(&self.core.packed_frame, self.core.clear_color);
        self.presented_ns = now_ns;
    }

    fn waitForInput(self: *Host) bool {
        var pollfds: [poll_fd_count_max]posix.pollfd = undefined;
        const devices = self.platform.devices.slice();
        assert(devices.len < poll_fd_count_max);
        const reading = self.core.queue.room() >= input_room_count_min;
        const device_events: i16 = if (reading) posix.POLL.IN else 0;
        for (devices, pollfds[0..devices.len]) |device, *pollfd| {
            pollfd.* = .{ .fd = device.fd, .events = device_events, .revents = 0 };
        }
        const wake_index = devices.len;
        pollfds[wake_index] = .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 };
        _ = posix.poll(pollfds[0 .. wake_index + 1], self.timeoutMs()) catch |err| {
            std.log.err("fbdev core host: poll failed: {t}", .{err});
            return false;
        };
        if ((pollfds[wake_index].revents & posix.POLL.IN) != 0) drain(self.wake_fd);
        self.platform.dispatchInput(pollfds[0..wake_index], &self.core.queue);
        return true;
    }

    fn timeoutMs(self: *const Host) i32 {
        const now_ns = platform_mod.nowNanoseconds();
        if (self.tickDue(now_ns)) return 0;
        var wake_ns: ?u64 = null;
        if (self.core.render_requested or self.cursor_moved) {
            const presented_ns = self.presented_ns orelse return 0;
            wake_ns = presented_ns + platform_mod.frame_period_ns_min;
        }
        if (self.core.renderDeadlineNs()) |deadline| {
            wake_ns = if (wake_ns) |frame_ns| @min(frame_ns, deadline) else deadline;
        }
        const target_ns = wake_ns orelse return -1;
        if (now_ns >= target_ns) return 0;
        const remaining_ms = std.math.divCeil(u64, target_ns - now_ns, std.time.ns_per_ms) catch
            unreachable;
        assert(remaining_ms > 0);
        return @intCast(@min(remaining_ms, std.math.maxInt(i32)));
    }
};

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

fn draw(
    context: *anyopaque,
    packed_frame: *const core_window.PackedFrame,
    frame: *const records.Frame,
    clear: records.Color,
) void {
    const host: *Host = @ptrCast(@alignCast(context));
    assert(frame.scale_factor > 0);
    assert(packed_frame == &host.core.packed_frame);
    assert(host.core.render_phase == .draw);
    const renderer = &host.window.renderer;
    const uploads = host.core.resources.atlas_uploads;
    backend.uploadPendingAtlases(renderer, uploads, host.core.atlas_consumer_key);
    backend.checkCapabilities(renderer.capabilities(), packed_frame);
    host.window.presentFrame(packed_frame, clear);
    host.cursor_moved = false;
    host.frame_packed = true;
    host.presented_ns = platform_mod.nowNanoseconds();
}

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
        else => std.debug.panic("fbdev core host: eventfd read failed: {t}", .{err}),
    };
    assert(read_bytes == @sizeOf(u64));
}
