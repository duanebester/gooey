//! FbdevPlatform - display-server-free platform for embedded Linux.
//!
//! Selected with `-Dlinux-backend=fbdev`. The platform owns the framebuffer
//! device and every evdev input device; its single window covers the whole
//! panel and is rendered on the CPU. There is no compositor, so the event loop
//! paces frames itself: it waits in `poll` on the input devices, dispatches
//! what arrived, and redraws at most once per `frame_period_ns_min` and only
//! when something requested it.
//!
//! ## Configuration (environment, read once at initialization)
//!
//! - `GOOEY_FBDEV`: framebuffer device path. Default `/dev/fb0`.
//! - `GOOEY_SCALE`: device pixels per logical pixel, 1 through 8. Default 1.
//! - `GOOEY_EVDEV_GRAB=1`: take exclusive access to input devices so the
//!   virtual console underneath does not also receive keystrokes.
//!
//! The process needs read/write access to the framebuffer and read access to
//! `/dev/input/event*`, usually through the `video` and `input` groups.

const std = @import("std");
const posix = std.posix;
const interface_mod = @import("../interface.zig");
const window_registry = @import("../window_registry.zig");
const cpu = @import("../cpu/renderer.zig");
const input = @import("../../input/events.zig");
const framebuffer_mod = @import("framebuffer.zig");
const evdev = @import("evdev.zig");
const FbdevWindow = @import("window.zig").Window;

const assert = std.debug.assert;
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;

/// Shortest interval between presented frames: a 60 Hz ceiling, because
/// without a compositor nothing else limits the redraw rate.
pub const frame_period_ns_min: u64 = 16_666_667;

/// Poll timeout while nothing is queued. The loop still turns at the frame
/// rate so the owner's per-turn hook sees asynchronous completions promptly,
/// matching the Wayland backend's idle cadence.
const idle_poll_timeout_ms: i32 = 16;

pub const FbdevPlatform = struct {
    /// The blocking `run()` loop is on the stack; see the contract.
    running: bool = false,
    allocator: std.mem.Allocator,
    window_registry: WindowRegistry,
    framebuffer: framebuffer_mod.Framebuffer = .{},
    devices: evdev.DeviceSet = .{},
    translator: evdev.Translator,
    scale_factor: f64,
    /// The one window. The panel has no room for a second.
    window: ?*FbdevWindow = null,
    loop_turn_callback: ?LoopTurnCallback = null,
    last_frame_ns: ?u64 = null,

    const Self = @This();

    pub const LoopTurnCallback = *const fn (*Self) void;

    pub const capabilities = interface_mod.PlatformCapabilities{
        .high_dpi = true,
        .multi_window = false,
        .gpu_accelerated = false,
        .display_link = false,
        .can_close_window = true,
        .glass_effects = false,
        .clipboard = true, // In-process only; see `clipboard.zig`.
        .file_dialogs = false,
        .ime = false,
        .custom_cursors = false,
        .window_drag_by_content = false,
        .name = "Linux/fbdev",
        .graphics_backend = "CPU",
    };

    pub fn initInPlace(self: *Self, allocator: std.mem.Allocator) !void {
        assert(@intFromPtr(self) != 0);
        self.* = .{
            .allocator = allocator,
            .window_registry = WindowRegistry.init(allocator),
            .translator = undefined,
            .scale_factor = scaleFromEnvironment(),
        };
        errdefer self.window_registry.deinit();

        const path = std.c.getenv("GOOEY_FBDEV") orelse "/dev/fb0";
        self.framebuffer.open(path) catch |err| {
            std.log.err("fbdev: cannot use framebuffer {s}: {t}", .{ path, err });
            return err;
        };
        errdefer self.framebuffer.close();

        self.devices.openAll(environmentFlag("GOOEY_EVDEV_GRAB"));
        self.translator = evdev.Translator.init(
            self.logicalWidth(),
            self.logicalHeight(),
            self.scale_factor,
        );
        std.log.info("fbdev: {d}x{d} at scale {d}, {d} input device(s)", .{
            self.framebuffer.width,
            self.framebuffer.height,
            self.scale_factor,
            self.devices.count,
        });
        assert(!self.running);
        assert(self.framebuffer.width > 0);
    }

    pub fn deinit(self: *Self) void {
        assert(!self.running);
        assert(self.window == null);
        self.devices.closeAll();
        self.framebuffer.close();
        self.window_registry.deinit();
    }

    /// Logical size of the panel: the size of the one window.
    pub fn logicalWidth(self: *const Self) f64 {
        assert(self.scale_factor > 0);
        return @as(f64, @floatFromInt(self.framebuffer.width)) / self.scale_factor;
    }

    pub fn logicalHeight(self: *const Self) f64 {
        assert(self.scale_factor > 0);
        return @as(f64, @floatFromInt(self.framebuffer.height)) / self.scale_factor;
    }

    // =========================================================================
    // Event loop
    // =========================================================================

    pub fn run(self: *Self) void {
        assert(!self.running);
        assert(self.window_registry.count() <= 1);
        self.running = true;
        defer self.running = false;

        // Each turn polls once, dispatches at most `raw_batch_max` events per
        // device, and renders at most one frame, so every turn is bounded.
        while (self.running) {
            if (self.loop_turn_callback) |on_turn| on_turn(self);
            if (!self.running) break;
            const window = self.openWindow() orelse break;

            var pollfds: [evdev.device_count_max]posix.pollfd = undefined;
            const devices = self.devices.slice();
            for (devices, pollfds[0..devices.len]) |device, *pollfd| {
                pollfd.* = .{ .fd = device.fd, .events = posix.POLL.IN, .revents = 0 };
            }
            _ = posix.poll(pollfds[0..devices.len], self.pollTimeout(window)) catch 0;
            self.dispatchInput(pollfds[0..devices.len]);

            if (window.isClosed()) continue;
            if (window.needs_redraw and self.frameDue()) {
                window.renderFrame();
                self.last_frame_ns = nowNanoseconds();
            }
        }
    }

    pub fn quit(self: *Self) void {
        self.running = false;
        assert(!self.running);
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    fn openWindow(self: *const Self) ?*FbdevWindow {
        const window = self.window orelse return null;
        assert(window.window_id.isValid());
        if (window.isClosed()) return null;
        return window;
    }

    fn pollTimeout(self: *const Self, window: *const FbdevWindow) i32 {
        assert(!window.isClosed());
        if (!window.needs_redraw) return idle_poll_timeout_ms;
        const last = self.last_frame_ns orelse return 0;
        const elapsed = nowNanoseconds() -| last;
        if (elapsed >= frame_period_ns_min) return 0;
        const remaining_ns = frame_period_ns_min - elapsed;
        return @intCast(std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch unreachable);
    }

    fn frameDue(self: *const Self) bool {
        const last = self.last_frame_ns orelse return true;
        return nowNanoseconds() -| last >= frame_period_ns_min;
    }

    fn dispatchInput(self: *Self, pollfds: []const posix.pollfd) void {
        assert(pollfds.len == self.devices.count);
        var raw_events: [evdev.raw_batch_max]evdev.RawEvent = undefined;
        for (self.devices.slice(), pollfds) |*device, pollfd| {
            if (pollfd.revents & posix.POLL.IN == 0) continue;
            for (evdev.readEvents(device, &raw_events)) |raw| {
                var batch = evdev.Batch{};
                self.translator.feed(device, raw, &batch);
                for (batch.slice()) |event| self.deliver(event);
            }
        }
    }

    fn deliver(self: *Self, event: input.InputEvent) void {
        const window = self.openWindow() orelse return;
        const handled = window.handleInput(event);
        if (handled) return;
        // Same escape hatches as the Wayland backend. With an exclusive
        // input grab they are the only way out short of a remote shell.
        switch (event) {
            .key_down => |key| {
                const quit_chord = (key.key == .q and key.modifiers.ctrl) or
                    (key.key == .f4 and key.modifiers.alt);
                if (quit_chord) window.close();
            },
            else => {},
        }
    }

    // =========================================================================
    // Window registry
    // =========================================================================

    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        assert(@intFromPtr(window) != 0);
        if (self.window_registry.count() >= 1) return error.MultipleWindowsUnsupported;
        const id = try self.window_registry.register(window);
        assert(id.isValid());
        return id;
    }

    pub fn unregisterWindow(self: *Self, id: WindowId) void {
        assert(id.isValid());
        _ = self.window_registry.unregister(id);
        assert(!self.window_registry.contains(id));
    }

    pub fn getWindow(self: *const Self, id: WindowId) ?*anyopaque {
        return self.window_registry.get(id);
    }

    pub fn getActiveWindowId(self: *const Self) ?WindowId {
        return self.window_registry.getActiveWindow();
    }

    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        self.window_registry.setActiveWindow(id);
        if (id) |window_id| assert(self.window_registry.contains(window_id));
    }

    pub fn windowCount(self: *const Self) u32 {
        return self.window_registry.count();
    }

    pub fn setLoopTurnCallback(self: *Self, callback: ?LoopTurnCallback) void {
        self.loop_turn_callback = callback;
    }
};

fn nowNanoseconds() u64 {
    // Same process-lifetime single-threaded `Io` the Wayland render path
    // uses; the event loop carries no `*Cx`.
    const io = std.Io.Threaded.global_single_threaded.io();
    const ns = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    assert(ns >= 0);
    return @intCast(ns);
}

fn environmentFlag(name: [*:0]const u8) bool {
    const value = std.c.getenv(name) orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
}

fn scaleFromEnvironment() f64 {
    const text = std.c.getenv("GOOEY_SCALE") orelse return 1.0;
    const scale = std.fmt.parseFloat(f64, std.mem.span(text)) catch {
        std.log.warn("fbdev: ignoring unparsable GOOEY_SCALE", .{});
        return 1.0;
    };
    if (scale < 1.0 or scale > cpu.scale_factor_max) {
        std.log.warn("fbdev: GOOEY_SCALE must be 1 to {d}; using 1", .{cpu.scale_factor_max});
        return 1.0;
    }
    return scale;
}

comptime {
    // A frame period of zero would let the loop spin; anything above one
    // second would make input feel broken.
    assert(frame_period_ns_min > 0);
    assert(frame_period_ns_min < std.time.ns_per_s);
    assert(evdev.device_count_max <= std.math.maxInt(u8));
}
