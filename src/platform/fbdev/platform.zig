const std = @import("std");
const posix = std.posix;
const window_registry = @import("../window_registry.zig");
const cpu = @import("../cpu/renderer.zig");
const input = @import("../../input/events.zig");
const framebuffer_mod = @import("framebuffer.zig");
const evdev = @import("evdev.zig");
const core_events = @import("../../core/events.zig");
const FbdevWindow = @import("window.zig").Window;

const assert = std.debug.assert;
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;

pub const frame_period_ns_min: u64 = 16_666_667;

pub const FbdevPlatform = struct {
    running: bool = false,
    window_registry: WindowRegistry,
    framebuffer: framebuffer_mod.Framebuffer = .{},
    devices: evdev.DeviceSet = .{},
    translator: evdev.Translator,
    scale_factor: f64,
    window: ?*FbdevWindow = null,

    const Self = @This();

    pub fn initInPlace(self: *Self) !void {
        assert(@intFromPtr(self) != 0);
        self.* = .{
            .window_registry = .init(),
            .translator = undefined,
            .scale_factor = scaleFromEnvironment(),
        };

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
    }

    pub fn logicalWidth(self: *const Self) f64 {
        assert(self.scale_factor > 0);
        return @as(f64, @floatFromInt(self.framebuffer.width)) / self.scale_factor;
    }

    pub fn logicalHeight(self: *const Self) f64 {
        assert(self.scale_factor > 0);
        return @as(f64, @floatFromInt(self.framebuffer.height)) / self.scale_factor;
    }

    fn openWindow(self: *const Self) ?*FbdevWindow {
        const window = self.window orelse return null;
        assert(window.window_id.isValid());
        if (window.isClosed()) return null;
        return window;
    }

    pub fn dispatchInput(
        self: *Self,
        pollfds: []const posix.pollfd,
        queue: *const core_events.EventQueue,
    ) void {
        assert(pollfds.len == self.devices.count);
        assert(pollfds.len <= evdev.device_count_max);
        const lost_mask = posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL;
        var raw_events: [evdev.raw_batch_max]evdev.RawEvent = undefined;
        var index: u32 = @intCast(pollfds.len);
        while (index > 0) {
            index -= 1;
            const device = &self.devices.devices[index];
            const revents = pollfds[index].revents;
            var lost = revents & lost_mask != 0;
            const raw_count_max = evdev.rawCountMax(queue.room());
            if (!lost and revents & posix.POLL.IN != 0 and raw_count_max > 0) {
                if (evdev.readEvents(device, raw_events[0..raw_count_max])) |raws| {
                    for (raws) |raw| {
                        var batch = evdev.Batch{};
                        self.translator.feed(device, raw, &batch);
                        for (batch.slice()) |event| self.deliver(event);
                    }
                } else |_| lost = true;
            }
            if (lost) {
                std.log.warn("fbdev: input device fd {d} lost; closing it", .{device.fd});
                self.devices.remove(index);
            }
        }
    }

    fn deliver(self: *Self, event: input.InputEvent) void {
        const window = self.openWindow() orelse return;
        const handled = window.handleInput(event);
        if (handled) return;
        switch (event) {
            .key_down => |key| {
                const quit_chord = (key.key == .q and key.modifiers.ctrl) or
                    (key.key == .f4 and key.modifiers.alt);
                if (quit_chord) window.close();
            },
            else => {},
        }
    }

    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        assert(@intFromPtr(window) != 0);
        const id = try self.window_registry.register(window);
        assert(id.isValid());
        return id;
    }

    pub fn unregisterWindow(self: *Self, id: WindowId) void {
        assert(id.isValid());
        _ = self.window_registry.unregister(id);
        assert(!self.window_registry.contains(id));
    }

    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        self.window_registry.setActiveWindow(id);
        if (id) |window_id| assert(self.window_registry.contains(window_id));
    }

    pub fn quit(self: *Self) void {
        self.running = false;
        assert(!self.running);
    }

    pub fn lockRenderThreads(self: *Self) void {
        assert(self.window_registry.count() <= 1);
    }

    pub fn unlockRenderThreads(self: *Self) void {
        assert(self.window_registry.count() <= 1);
    }
};

pub fn nowMilliseconds() i64 {
    const ms = @divFloor(nowNanoseconds(), std.time.ns_per_ms);
    assert(ms <= std.math.maxInt(i64));
    return @intCast(ms);
}

pub fn nowNanoseconds() u64 {
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
    assert(frame_period_ns_min > 0);
    assert(frame_period_ns_min < std.time.ns_per_s);
    assert(evdev.device_count_max <= std.math.maxInt(u8));
}
