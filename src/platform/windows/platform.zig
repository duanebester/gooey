//! WindowsPlatform - Win32 host loop for the Windows backend.
//!
//! Owns the window class, the stock cursors, the bounded window registry, and
//! the clipboard's owner window, and runs the message loop. Windows are
//! rendered on the main thread with Vulkan (`window.zig`).
//!
//! ## Loop turn
//!
//! Each turn of `run` does bounded work, in this order:
//!
//! 1. The owner's loop-turn hook, outside any window procedure.
//! 2. At most `message_batch_max` queued messages, dispatched to the window
//!    procedure, which translates input and delivers it.
//! 3. Passed timed-redraw deadlines become render requests.
//! 4. At most one frame per open window, and none sooner than
//!    `frame_period_ns_min` after that window's previous frame.
//! 5. A wait for the next message, bounded by the earliest frame or deadline
//!    and by `idle_wait_ms_max`, so the hook sees async completions promptly.
//!
//! ## Frame pacing
//!
//! The swapchain prefers mailbox presentation, which never blocks, so
//! `frame_period_ns_min` is what keeps an animating window from rendering as
//! fast as the GPU allows. Rendering is otherwise on demand: an idle window
//! draws nothing. Display-synchronized pacing on a render thread is a separate
//! item in `docs/windows-port.md`.
//!
//! ## Resource sketch (CLAUDE.md §7)
//!
//! - Messages per turn: `message_batch_max` (256). Each translates to at most
//!   one input event, delivered synchronously; nothing is queued by Gooey.
//! - Frames per turn: one per open window, at most `WindowRegistry.MAX_WINDOWS`.
//! - Memory: the registry and each window are reserved when the window opens,
//!   before `run`. The loop itself allocates nothing.

const std = @import("std");
const interface_mod = @import("../interface.zig");
const window_registry = @import("../window_registry.zig");
const win32 = @import("win32.zig");
const clipboard = @import("clipboard.zig");
const windows_input = @import("input.zig");
const windows_window = @import("window.zig");
const WindowsWindow = windows_window.Window;

const assert = std.debug.assert;
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;

/// Messages dispatched per loop turn. Bounds the time between owner hooks and
/// frames when input floods the queue; the remainder waits one turn.
pub const message_batch_max: u32 = 256;

/// Shortest interval between two frames of one window: a 60 Hz ceiling.
pub const frame_period_ns_min: u64 = 16_666_667;

/// Longest wait for a message while nothing is due, matching the fbdev
/// backend's idle cadence for the owner's loop-turn hook.
const idle_wait_ms_max: u32 = 16;

/// UTF-16 name of the one window class every Gooey window uses.
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GooeyWindow");

pub const WindowsPlatform = struct {
    /// The blocking `run()` loop is on the stack; see the contract.
    running: bool = false,
    allocator: std.mem.Allocator,
    window_registry: WindowRegistry,
    hinstance: win32.HINSTANCE,
    /// Stock cursors indexed by `CursorShape`, loaded once. Shared system
    /// resources: they are never destroyed.
    cursors: [cursor_shape_count]?win32.HCURSOR,
    click_settings: windows_input.ClickSettings,
    loop_turn_callback: ?LoopTurnCallback = null,

    const Self = @This();

    const cursor_shape_count = std.enums.values(interface_mod.CursorShape).len;

    pub const LoopTurnCallback = *const fn (*Self) void;

    pub const capabilities = interface_mod.PlatformCapabilities{
        .high_dpi = true,
        .multi_window = true,
        .gpu_accelerated = true,
        .display_link = false,
        .can_close_window = true,
        .glass_effects = false,
        .clipboard = true,
        .file_dialogs = true,
        .ime = false,
        .custom_cursors = true,
        .window_drag_by_content = false,
        .name = "Windows",
        .graphics_backend = "Vulkan",
    };

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
        self.* = .{
            .allocator = allocator,
            .window_registry = WindowRegistry.init(allocator),
            .hinstance = hinstance,
            .cursors = loadCursors(),
            .click_settings = clickSettings(),
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
    // Event loop
    // =========================================================================

    pub fn run(self: *Self) void {
        assert(!self.running);
        assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);
        self.running = true;
        defer self.running = false;

        while (self.running) {
            // The owner's turn comes first, with no window procedure on the
            // stack, so it may reclaim windows closed during the last turn.
            if (self.loop_turn_callback) |on_turn| on_turn(self);
            if (!self.running) break;

            // Nothing left to present or to receive input: stop. Quitting is
            // still the owner's decision; this only ends a loop that could
            // observe nothing further.
            if (self.openWindowCount() == 0) break;

            if (!self.dispatchMessages()) break;
            self.fireRenderDeadlines(nowMilliseconds());
            self.renderDueWindows(nowNanoseconds());
            if (!self.waitForMessages(self.waitTimeoutMs())) break;
        }
    }

    pub fn quit(self: *Self) void {
        self.running = false;
        assert(!self.running);
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    /// Dispatch up to `message_batch_max` queued messages. Returns false when
    /// `WM_QUIT` arrives, which ends the loop.
    fn dispatchMessages(self: *Self) bool {
        assert(self.running);
        var message: win32.MSG = undefined;
        var dispatched: u32 = 0;
        while (dispatched < message_batch_max) : (dispatched += 1) {
            if (win32.PeekMessageW(&message, null, 0, 0, win32.PM_REMOVE) == win32.FALSE) break;
            if (message.message == win32.WM_QUIT) return false;
            // Produces `WM_CHAR` from key messages; the result says only
            // whether a character message was posted.
            _ = win32.TranslateMessage(&message);
            _ = win32.DispatchMessageW(&message);
        }
        assert(dispatched <= message_batch_max);
        return true;
    }

    /// Block until a message arrives or `timeout_ms` passes. Returns false if
    /// the wait itself failed, which leaves no way to learn of new input.
    fn waitForMessages(self: *const Self, timeout_ms: u32) bool {
        assert(self.running);
        assert(timeout_ms <= idle_wait_ms_max);
        if (timeout_ms == 0) return true;
        const result = win32.MsgWaitForMultipleObjectsEx(
            0,
            null,
            timeout_ms,
            win32.QS_ALLINPUT,
            win32.MWMO_INPUTAVAILABLE,
        );
        if (result == win32.WAIT_FAILED) {
            std.log.err("windows: MsgWaitForMultipleObjectsEx failed (error {d})", .{
                win32.GetLastError(),
            });
            return false;
        }
        return true;
    }

    /// How long the loop may sleep: until the earliest due frame or timed
    /// redraw, never longer than `idle_wait_ms_max`.
    fn waitTimeoutMs(self: *const Self) u32 {
        var ids: [WindowRegistry.MAX_WINDOWS]WindowId = undefined;
        const found = self.snapshotWindowIds(&ids);
        const now_ns = nowNanoseconds();
        const now_ms = nowMilliseconds();
        var timeout_ms: u32 = idle_wait_ms_max;
        for (ids[0..found]) |id| {
            const window = self.window_registry.getTyped(WindowsWindow, id) orelse continue;
            if (window.isClosed()) continue;
            timeout_ms = @min(timeout_ms, window.waitTimeoutMs(now_ns, now_ms, idle_wait_ms_max));
        }
        assert(timeout_ms <= idle_wait_ms_max);
        return timeout_ms;
    }

    fn fireRenderDeadlines(self: *Self, now_ms: i64) void {
        assert(now_ms >= 0);
        var ids: [WindowRegistry.MAX_WINDOWS]WindowId = undefined;
        const found = self.snapshotWindowIds(&ids);
        for (ids[0..found]) |id| {
            const window = self.window_registry.getTyped(WindowsWindow, id) orelse continue;
            window.fireRenderDeadline(now_ms);
        }
    }

    /// Render each window that asked for a frame and whose pacing allows one.
    ///
    /// Ids are copied out first and re-resolved per window: the render
    /// callback may open or close windows, which rehashes the registry map.
    fn renderDueWindows(self: *Self, now_ns: u64) void {
        var ids: [WindowRegistry.MAX_WINDOWS]WindowId = undefined;
        const found = self.snapshotWindowIds(&ids);
        for (ids[0..found]) |id| {
            assert(id.isValid());
            const window = self.window_registry.getTyped(WindowsWindow, id) orelse continue;
            if (window.isFrameDue(now_ns)) window.renderFrame();
        }
    }

    fn openWindowCount(self: *const Self) u32 {
        var ids: [WindowRegistry.MAX_WINDOWS]WindowId = undefined;
        const found = self.snapshotWindowIds(&ids);
        var open_count: u32 = 0;
        for (ids[0..found]) |id| {
            const window = self.window_registry.getTyped(WindowsWindow, id) orelse continue;
            if (!window.isClosed()) open_count += 1;
        }
        assert(open_count <= found);
        return open_count;
    }

    /// Copy every registered id into caller storage; returns the count.
    fn snapshotWindowIds(self: *const Self, ids: *[WindowRegistry.MAX_WINDOWS]WindowId) u32 {
        var found: u32 = 0;
        var iterator = self.window_registry.iterator();
        while (iterator.next()) |id| {
            assert(found < WindowRegistry.MAX_WINDOWS);
            ids[found] = id.*;
            found += 1;
        }
        assert(found == self.window_registry.count());
        return found;
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

    /// Frames render on the main thread inside `run`, so a main-thread caller
    /// already excludes every frame; there is no lock.
    pub fn lockRenderThreads(self: *Self) void {
        assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);
    }

    pub fn unlockRenderThreads(self: *Self) void {
        assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);
    }

    pub fn setLoopTurnCallback(self: *Self, callback: ?LoopTurnCallback) void {
        self.loop_turn_callback = callback;
    }
};

fn loadCursors() [WindowsPlatform.cursor_shape_count]?win32.HCURSOR {
    var cursors: [WindowsPlatform.cursor_shape_count]?win32.HCURSOR = undefined;
    for (&cursors, 0..) |*slot, index| {
        const shape: interface_mod.CursorShape = @fromBackingInt(@intCast(index));
        const resource: u16 = switch (shape) {
            .default => win32.IDC_ARROW,
            .text => win32.IDC_IBEAM,
            .pointer => win32.IDC_HAND,
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
    return .{ .time_ms_max = @max(1, time_ms_max), .distance_px_max = distance_px_max };
}

/// Milliseconds on the `.awake` clock, for timed-redraw deadlines.
pub fn nowMilliseconds() i64 {
    const ms = @divFloor(nowNanoseconds(), std.time.ns_per_ms);
    assert(ms <= std.math.maxInt(i64));
    return @intCast(ms);
}

/// Nanoseconds on the `.awake` clock. The event loop carries no `Io`, so this
/// uses the process-lifetime global, as the other native backends do.
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
    assert(idle_wait_ms_max > 0);
    assert(message_batch_max > 0);
}
