//! WindowsPlatform - Win32 process state for the Windows backend.
//!
//! Owns the window class, the stock cursors, the bounded window registry, the
//! clipboard's owner window, and the waitable timer the core host's loop
//! waits on (`core_host.zig`). The host runs the message loop itself through
//! `dispatchMessageBatch`.
//!
//! The timer is high resolution where the system has it: a millisecond
//! timeout alone expires on the system tick (15.6 ms by default), so a 16.7 ms
//! wait would last two ticks and cap animation near 32 fps. `timeBeginPeriod`
//! would also fix it, but it raises the tick rate for the whole system.

const std = @import("std");
const interface_mod = @import("../interface.zig");
const window_registry = @import("../window_registry.zig");
const win32 = @import("win32.zig");
const clipboard = @import("clipboard.zig");
const windows_input = @import("input.zig");
const windows_window = @import("window.zig");

const assert = std.debug.assert;
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;

/// Messages dispatched per loop turn. Bounds the time between ticks and
/// frames when input floods the queue; the remainder waits one turn.
pub const message_batch_max: u32 = 256;

/// The core host's pacing period when DWM reports no usable timing: a 60 Hz
/// ceiling.
pub const frame_period_ns_min: u64 = 16_666_667;

/// UTF-16 name of the one window class every Gooey window uses.
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GooeyWindow");

pub const WindowsPlatform = struct {
    /// Cleared only by `quit`, a 0.3.1 call kept while `context/window.zig`
    /// compiles. The core host's loop ends when the window closes.
    running: bool = false,
    window_registry: WindowRegistry,
    hinstance: win32.HINSTANCE,
    /// Stock cursors indexed by `CursorShape`, loaded once. Shared system
    /// resources: they are never destroyed.
    cursors: [cursor_shape_count]?win32.HCURSOR,
    click_settings: windows_input.ClickSettings,
    /// Ends each of the core host's waits at its deadline. Owned.
    frame_timer: win32.HANDLE,

    const Self = @This();

    const cursor_shape_count = std.enums.values(interface_mod.CursorShape).len;

    pub fn initInPlace(self: *Self, allocator: std.mem.Allocator) !void {
        assert(@intFromPtr(self) != 0);

        // Per-monitor v2 makes every size Windows reports a device-pixel size
        // and delivers `WM_DPICHANGED` when a window crosses monitors. It
        // fails when the manifest or an earlier call already chose a mode;
        // that mode stays in effect, so log it and continue.
        if (win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) ==
            win32.FALSE)
        {
            std.log.warn("windows: per-monitor DPI awareness unavailable (error {d})", .{
                win32.GetLastError(),
            });
        }

        const hinstance = win32.GetModuleHandleW(null) orelse return error.NoModuleHandle;

        const frame_timer = try createFrameTimer();
        errdefer closeFrameTimer(frame_timer);

        self.* = .{
            .window_registry = WindowRegistry.init(allocator),
            .hinstance = hinstance,
            .cursors = loadCursors(),
            .click_settings = clickSettings(),
            .frame_timer = frame_timer,
        };
        errdefer self.window_registry.deinit();

        const class = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = win32.CS_HREDRAW | win32.CS_VREDRAW | win32.CS_OWNDC,
            .lpfnWndProc = windows_window.windowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null, // `WM_SETCURSOR` selects per window.
            .hbrBackground = null, // Vulkan covers the client area.
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        if (win32.RegisterClassExW(&class) == 0) {
            std.log.err("windows: RegisterClassExW failed (error {d})", .{win32.GetLastError()});
            return error.WindowClassRegistrationFailed;
        }
        errdefer self.unregisterClass();

        try clipboard.init(hinstance);

        assert(!self.running);
        assert(self.window_registry.count() == 0);
    }

    pub fn deinit(self: *Self) void {
        assert(!self.running);
        assert(self.window_registry.count() == 0);
        clipboard.deinit();
        self.unregisterClass();
        closeFrameTimer(self.frame_timer);
        self.window_registry.deinit();
    }

    /// Fails only while a window of the class exists, which `deinit` asserts
    /// against; the class dies with the process regardless.
    fn unregisterClass(self: *const Self) void {
        assert(self.window_registry.count() == 0);
        if (win32.UnregisterClassW(class_name, self.hinstance) == win32.FALSE) {
            std.log.warn("windows: UnregisterClassW failed (error {d})", .{win32.GetLastError()});
        }
    }

    /// The cursor for a shape. Falls back to the arrow when a stock cursor
    /// failed to load.
    pub fn cursor(self: *const Self, shape: interface_mod.CursorShape) ?win32.HCURSOR {
        const index = @backingInt(shape);
        assert(index < cursor_shape_count);
        const fallback = @backingInt(interface_mod.CursorShape.default);
        return self.cursors[index] orelse self.cursors[fallback];
    }

    // =========================================================================
    // Window registry
    // =========================================================================

    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        assert(@intFromPtr(window) != 0);
        if (self.window_registry.count() >= WindowRegistry.MAX_WINDOWS) {
            std.log.err("windows: window registry full ({d} windows)", .{
                WindowRegistry.MAX_WINDOWS,
            });
            return error.TooManyWindows;
        }
        const id = try self.window_registry.register(window);
        assert(id.isValid());
        return id;
    }

    pub fn unregisterWindow(self: *Self, id: WindowId) void {
        assert(id.isValid());
        _ = self.window_registry.unregister(id);
        assert(!self.window_registry.contains(id));
    }

    pub fn getActiveWindowId(self: *const Self) ?WindowId {
        return self.window_registry.getActiveWindow();
    }

    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        self.window_registry.setActiveWindow(id);
        if (id) |window_id| assert(self.window_registry.contains(window_id));
    }

    // =========================================================================
    // Calls from the 0.3.1 `context/window.zig`
    // =========================================================================
    //
    // The core never makes these calls. They stay only while that file
    // compiles, and go when phase 6 deletes it.

    pub fn quit(self: *Self) void {
        self.running = false;
        assert(!self.running);
    }

    /// The core's renderer is its host's, so there is nothing to lock here.
    pub fn lockRenderThreads(self: *Self) void {
        assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);
    }

    pub fn unlockRenderThreads(self: *Self) void {
        assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);
    }
};

/// Dispatch up to `message_batch_max` queued messages of this thread.
/// Returns false when `WM_QUIT` arrives. The core host's loop calls it.
pub fn dispatchMessageBatch() bool {
    var message: win32.MSG = undefined;
    var dispatched: u32 = 0;
    while (dispatched < message_batch_max) : (dispatched += 1) {
        if (win32.PeekMessageW(&message, null, 0, 0, win32.PM_REMOVE) == win32.FALSE) break;
        if (message.message == win32.WM_QUIT) return false;
        // Produces `WM_CHAR` from key messages; the result says only whether
        // a character message was posted.
        _ = win32.TranslateMessage(&message);
        _ = win32.DispatchMessageW(&message);
    }
    assert(dispatched <= message_batch_max);
    return true;
}

/// Create the loop's waitable timer, high resolution where the system has
/// it (Windows 10 1803 and later). The regular fallback still works but
/// expires on the system tick, so frames below 60 Hz may pace coarsely.
pub fn createFrameTimer() !win32.HANDLE {
    comptime assert(win32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION == 0x2);
    comptime assert(win32.TIMER_ALL_ACCESS == 0x001F_0003);
    const access = win32.TIMER_ALL_ACCESS;
    const high_resolution = win32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION;
    if (win32.CreateWaitableTimerExW(null, null, high_resolution, access)) |timer| {
        return timer;
    }
    std.log.warn(
        "windows: high-resolution waitable timer unavailable (error {d}); " ++
            "frame pacing follows the system timer tick",
        .{win32.GetLastError()},
    );
    return win32.CreateWaitableTimerExW(null, null, 0, access) orelse {
        std.log.err("windows: CreateWaitableTimerExW failed (error {d})", .{
            win32.GetLastError(),
        });
        return error.FrameTimerCreationFailed;
    };
}

pub fn closeFrameTimer(timer: win32.HANDLE) void {
    assert(@intFromPtr(timer) != 0);
    if (win32.CloseHandle(timer) == win32.FALSE) {
        std.log.warn("windows: CloseHandle(frame timer) failed (error {d})", .{
            win32.GetLastError(),
        });
    }
}

fn loadCursors() [WindowsPlatform.cursor_shape_count]?win32.HCURSOR {
    var cursors: [WindowsPlatform.cursor_shape_count]?win32.HCURSOR = undefined;
    for (&cursors, 0..) |*slot, index| {
        const shape: interface_mod.CursorShape = @fromBackingInt(@intCast(index));
        const resource: u16 = switch (shape) {
            .default => win32.IDC_ARROW,
            .text => win32.IDC_IBEAM,
            .pointer => win32.IDC_HAND,
            .resize_left_right => win32.IDC_SIZEWE,
            .resize_up_down => win32.IDC_SIZENS,
        };
        slot.* = win32.LoadCursorW(null, resource);
        if (slot.* == null) {
            std.log.warn("windows: stock cursor {d} failed to load", .{resource});
        }
    }
    return cursors;
}

/// The user's double-click time and distance. Windows returns its defaults
/// (500 ms, 4 px) when the settings are absent, never zero.
fn clickSettings() windows_input.ClickSettings {
    const time_ms_max = win32.GetDoubleClickTime();
    const width_px = win32.GetSystemMetrics(win32.SM_CXDOUBLECLK);
    const height_px = win32.GetSystemMetrics(win32.SM_CYDOUBLECLK);
    // The metrics give the size of the whole rectangle around the first click.
    const distance_px_max: u32 = @intCast(@max(1, @divFloor(@max(width_px, height_px), 2)));
    const settings = windows_input.ClickSettings{
        .time_ms_max = @max(1, time_ms_max),
        .distance_px_max = distance_px_max,
    };
    // Zero would make every second click a double click, or none.
    assert(settings.time_ms_max > 0);
    assert(settings.distance_px_max > 0);
    return settings;
}

/// Milliseconds on the `.awake` clock, for `Window.requestRenderAfter`.
pub fn nowMilliseconds() i64 {
    const ms = @divFloor(nowNanoseconds(), std.time.ns_per_ms);
    assert(ms <= std.math.maxInt(i64));
    return @intCast(ms);
}

/// Nanoseconds on the `.awake` clock. The callers carry no `Io`, so this uses
/// the process-lifetime global, as the other native backends do.
pub fn nowNanoseconds() u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ns = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    assert(ns >= 0);
    return @intCast(ns);
}

comptime {
    // A zero frame period would let the loop spin; above a second would make
    // input feel broken.
    assert(frame_period_ns_min > 0);
    assert(frame_period_ns_min < std.time.ns_per_s);
    assert(message_batch_max > 0);
}

test "frame timer arms, signals, and closes" {
    // Methodology: create the real timer, arm it for 1 ms, and wait for it
    // with a generous backstop; the timer, not the backstop, must end the
    // wait. Covers the externs' signatures against the real kernel32.
    const timer = try createFrameTimer();
    defer closeFrameTimer(timer);

    // Relative (negative), in 100 ns intervals: 1 ms.
    const due_time: i64 = -10_000;
    try std.testing.expect(win32.SetWaitableTimer(timer, &due_time, 0, null, null, 0) != 0);
    const handles = [1]win32.HANDLE{timer};
    // No input mask: only the timer or the backstop can end this wait.
    const result = win32.MsgWaitForMultipleObjectsEx(handles.len, &handles, 1_000, 0, 0);
    try std.testing.expectEqual(win32.WAIT_OBJECT_0, result);
}
