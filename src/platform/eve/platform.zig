//! Bridgetek EVE (BT81x) platform for embedded Linux boards whose panel sits
//! behind an EVE display controller on SPI, with no framebuffer (selected
//! with `-Dlinux-backend=eve`). Input is the chip's capacitive touch engine,
//! read once per loop turn and delivered as left-button mouse events, so
//! buttons, hovers, and drags work as with a mouse; there is no keyboard.
//!
//! Configuration: `-Deve-device` (build): the spidev node, default
//! `/dev/spidev1.0`; `-Deve-spi-hz` (build): the SPI clock, 1 to 30 MHz,
//! default 10 MHz; `GOOEY_EVE_SIMULATE=<path>` (environment): draw into a
//! simulated chip instead of the device, dumping `RAM_G` and `RAM_DL` to
//! `<path>` at every swap for `eve_preview.py`. The chip must already be
//! booted and scanning out: board bring-up (reset, clocks, panel timing,
//! backlight) stays with the board's own driver.

const std = @import("std");
const build_options = @import("gooey_build_options");
const window_registry = @import("../window_registry.zig");
const input = @import("../../input/events.zig");
const linux_input = @import("../linux/input.zig");
const core_events = @import("../../core/events.zig");
const chip_mod = @import("chip.zig");
const EveWindow = @import("window.zig").Window;

const assert = std.debug.assert;
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;

/// Interval between touch reads while nothing draws: how quickly a touch is
/// seen. While frames draw, each loop turn reads touch once per refresh.
pub const touch_poll_ns: u64 = 16 * std.time.ns_per_ms;

/// Events one touch read can produce: a press with its move, or a release.
pub const touch_event_count_max: u32 = 2;

comptime {
    assert(build_options.eve_spi_hz >= chip_mod.spi_hz_min);
    assert(build_options.eve_spi_hz <= chip_mod.spi_hz_max);
    assert(build_options.eve_device.len > 0);
}

pub const EvePlatform = struct {
    /// Cleared only by `quit`; the core host's loop ends when the window
    /// closes.
    running: bool = false,
    window_registry: WindowRegistry,
    chip: chip_mod.Chip,
    /// The one window. The panel has no room for a second.
    window: ?*EveWindow = null,
    /// The contact of the last touch read, in panel pixels; null when none.
    contact: ?[2]f64 = null,
    click_tracker: linux_input.ClickTracker = .{},

    const Self = @This();

    pub fn initInPlace(self: *Self) !void {
        assert(@intFromPtr(self) != 0);
        self.* = .{ .window_registry = .init(), .chip = .{} };
        if (std.c.getenv("GOOEY_EVE_SIMULATE")) |path| {
            try self.chip.openSimulated(path);
        } else {
            const device = std.fmt.comptimePrint("{s}", .{build_options.eve_device});
            self.chip.open(device, build_options.eve_spi_hz) catch |err| {
                std.log.err("eve: cannot use {s}: {t}", .{ device, err });
                return err;
            };
        }
        assert(!self.running);
        assert(self.chip.panel_width > 0);
    }

    pub fn deinit(self: *Self) void {
        assert(!self.running);
        assert(self.window == null);
        self.chip.close();
    }

    /// Read the touch engine once and deliver what changed. A failed read
    /// counts as no contact, so a lost bus releases a press rather than
    /// leaving it held.
    pub fn dispatchTouch(self: *Self, now_ms: u32) void {
        assert(self.chip.panel_width > 0);
        const touch = self.chip.readTouch() catch |err| blk: {
            std.log.warn("eve: touch read failed: {t}", .{err});
            break :blk null;
        };
        const window = self.openWindow() orelse return;
        const previous = self.contact;
        const current: ?[2]f64 = if (touch) |point| self.clampToPanel(point) else null;
        self.contact = current;
        const modifiers = input.Modifiers{};
        if (current) |point| {
            if (previous == null) {
                const count = self.click_tracker.recordClick(
                    now_ms,
                    point[0],
                    point[1],
                    linux_input.evdev.BTN_LEFT,
                );
                // Move first, so hover state reaches the pressed element.
                _ = window.handleInput(linux_input.mouseMovedEvent(point[0], point[1], modifiers));
                _ = window.handleInput(linux_input.mouseDownEvent(
                    point[0],
                    point[1],
                    linux_input.evdev.BTN_LEFT,
                    count,
                    modifiers,
                ));
            } else if (previous.?[0] != point[0] or previous.?[1] != point[1]) {
                const event = linux_input.mouseDraggedEvent(point[0], point[1], .left, modifiers);
                _ = window.handleInput(event);
            }
        } else if (previous) |point| {
            _ = window.handleInput(linux_input.mouseUpEvent(
                point[0],
                point[1],
                linux_input.evdev.BTN_LEFT,
                modifiers,
            ));
        }
    }

    /// The touch engine reports slightly past the panel's edges.
    fn clampToPanel(self: *const Self, touch: chip_mod.Touch) [2]f64 {
        assert(self.chip.panel_width > 0);
        assert(self.chip.panel_height > 0);
        const right: f64 = @floatFromInt(self.chip.panel_width - 1);
        const bottom: f64 = @floatFromInt(self.chip.panel_height - 1);
        return .{
            std.math.clamp(@as(f64, @floatFromInt(touch.x)), 0, right),
            std.math.clamp(@as(f64, @floatFromInt(touch.y)), 0, bottom),
        };
    }

    fn openWindow(self: *const Self) ?*EveWindow {
        const window = self.window orelse return null;
        assert(window.window_id.isValid());
        if (window.isClosed()) return null;
        return window;
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

    // Kept only while 0.3.1 `context/window.zig` compiles; the core never
    // calls these, and they go when phase 6 deletes that file.

    pub fn quit(self: *Self) void {
        self.running = false;
        assert(!self.running);
    }

    /// Frames render on the main thread, so there is no lock.
    pub fn lockRenderThreads(self: *Self) void {
        assert(self.window_registry.count() <= 1);
    }

    pub fn unlockRenderThreads(self: *Self) void {
        assert(self.window_registry.count() <= 1);
    }
};

/// Milliseconds on the chip's clock, for `Window.requestRenderAfter`.
pub fn nowMilliseconds() i64 {
    const ms = @divFloor(chip_mod.nowNanoseconds(), std.time.ns_per_ms);
    assert(ms <= std.math.maxInt(i64));
    return @intCast(ms);
}
