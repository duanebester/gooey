//! Windows platform host — Win32 message loop with a DWM vsync tick.
//!
//! Like macOS and Linux this is a `blocking_event_loop`: `run()` pumps the
//! thread's message queue until `quit()` (or the last window closes). Frames
//! are paced by `DwmFlush`, which blocks until the next compositor frame;
//! rendering happens on the UI thread, so no render mutex is needed.
//!
//! DPI: the process is made PER_MONITOR_AWARE_V2 before any window exists.
//! `GetDpiForWindow` supplies the initial scale and `WM_DPICHANGED` handles
//! monitor changes and hot-plugs.

const std = @import("std");
const win32 = @import("win32/mod.zig");
const window_mod = @import("window.zig");
const interface = @import("../interface.zig");

const WindowId = interface.WindowId;
const WindowRegistry = interface.WindowRegistry;
const PlatformCapabilities = interface.PlatformCapabilities;

pub const WindowsPlatform = struct {
    hinstance: win32.HINSTANCE = null,
    allocator: std.mem.Allocator = undefined,
    running: bool = false,
    registry: WindowRegistry = undefined,
    loop_turn_callback: ?LoopTurnCallback = null,

    const Self = @This();

    /// Owner hook fired once per iteration of `run`, outside any window
    /// callback. See the `LoopTurnCallback` note in `platform/contract.zig`.
    pub const LoopTurnCallback = *const fn (*Self) void;

    /// Capabilities for this backend. Services (clipboard, file dialogs, IME)
    /// are deliberately deferred to a later pass, so they are not advertised.
    pub const capabilities: PlatformCapabilities = .{
        .high_dpi = true,
        .multi_window = true,
        .gpu_accelerated = true,
        .display_link = true, // DwmFlush gives a compositor-paced tick.
        .can_close_window = true,
        .glass_effects = false,
        .has_post_process = false,
        .clipboard = false,
        .file_dialogs = false,
        .ime = false,
        .custom_cursors = true,
        .window_drag_by_content = false,
        .name = "Windows/Win32",
        .graphics_backend = window_mod.renderer_name,
    };

    // =========================================================================
    // Lifecycle
    // =========================================================================

    /// Initialize the platform against its final address.
    ///
    /// The window procedure keeps no pointer to the platform, but the registry
    /// does hold window pointers, so all state is installed here rather than
    /// returned by value.
    pub fn initInPlace(self: *Self, allocator: std.mem.Allocator) !void {
        std.debug.assert(@intFromPtr(self) != 0);

        // DPI awareness must be set before any HWND is created. On older
        // systems the V2 context is unavailable; fall back to system-DPI
        // awareness, then to no awareness (the OS bitmap-scales the window).
        if (win32.SetProcessDpiAwarenessContext(
            win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        ) == 0) {
            _ = win32.SetProcessDPIAware();
        }

        self.* = .{
            .hinstance = win32.GetModuleHandleW(null),
            .allocator = allocator,
            .running = false,
            .registry = WindowRegistry.init(allocator),
            .loop_turn_callback = null,
        };
        errdefer self.registry.deinit();

        // Register the window class once per process. A duplicate registration
        // fails harmlessly when a host creates a second platform instance.
        _ = window_mod.registerWindowClass(self.hinstance);

        std.debug.assert(!self.running);
        std.debug.assert(self.registry.count() == 0);
    }

    pub fn deinit(self: *Self) void {
        // Windows unregister themselves in `Window.deinit`. Any remaining
        // entries belong to windows the owner has not reclaimed.
        self.running = false;
        self.registry.deinit();
        self.hinstance = null;
    }

    // =========================================================================
    // Window registry
    // =========================================================================

    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        std.debug.assert(@intFromPtr(window) != 0);
        std.debug.assert(self.registry.count() < WindowRegistry.MAX_WINDOWS);
        return self.registry.register(window);
    }

    pub fn unregisterWindow(self: *Self, id: WindowId) void {
        std.debug.assert(id.isValid());
        _ = self.registry.unregister(id);
    }

    pub fn getWindow(self: *const Self, id: WindowId) ?*anyopaque {
        return self.registry.get(id);
    }

    pub fn getActiveWindowId(self: *const Self) ?WindowId {
        return self.registry.getActiveWindow();
    }

    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        self.registry.setActiveWindow(id);
    }

    pub fn windowCount(self: *const Self) u32 {
        return self.registry.count();
    }

    pub fn setLoopTurnCallback(self: *Self, callback: ?LoopTurnCallback) void {
        self.loop_turn_callback = callback;
    }

    // =========================================================================
    // Event loop
    // =========================================================================

    /// Drain every currently queued message. `WM_QUIT` ends the loop.
    fn pump(self: *Self) void {
        var msg: win32.MSG = undefined;
        while (win32.PeekMessageW(&msg, null, 0, 0, @bitCast(win32.PM_REMOVE)) != 0) {
            if (msg.message == win32.WM_QUIT) {
                self.running = false;
                return;
            }
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
            if (!self.running) return; // A callback called quit().
        }
    }

    /// Present one frame for every open window that asked for one.
    ///
    /// Ids are snapshotted first: `renderFrame` runs the application's render
    /// callback, which may open or close windows and rehash the registry.
    fn renderOpenWindows(self: *Self) void {
        var ids: [WindowRegistry.MAX_WINDOWS]WindowId = undefined;
        var found: u32 = 0;
        var it = self.registry.iterator();
        while (it.next()) |id| {
            std.debug.assert(found < WindowRegistry.MAX_WINDOWS);
            ids[found] = id.*;
            found += 1;
        }

        for (ids[0..found]) |id| {
            const ptr = self.registry.get(id) orelse continue;
            const win: *window_mod.Window = @ptrCast(@alignCast(ptr));
            if (win.isClosed()) continue;
            win.renderFrame();
        }
    }

    /// Whether any open window still has work to present this turn.
    fn hasPendingWork(self: *const Self) bool {
        var it = self.registry.iterator();
        while (it.next()) |id| {
            const ptr = self.registry.get(id.*) orelse continue;
            const win: *const window_mod.Window = @ptrCast(@alignCast(ptr));
            if (!win.isClosed() and win.needsRedraw()) return true;
        }
        return false;
    }

    /// Number of open (not closed) windows.
    fn openWindowCount(self: *const Self) u32 {
        var count: u32 = 0;
        var it = self.registry.iterator();
        while (it.next()) |id| {
            const ptr = self.registry.get(id.*) orelse continue;
            const win: *const window_mod.Window = @ptrCast(@alignCast(ptr));
            if (!win.isClosed()) count += 1;
        }
        return count;
    }

    /// Blocking host loop. Each iteration gives the owner its turn, renders
    /// windows that requested a frame, drains input, then waits for the next
    /// compositor tick (or the next message/timer when idle).
    pub fn run(self: *Self) void {
        std.debug.assert(!self.running);
        self.running = true;
        defer self.running = false;

        while (self.running) {
            // Give the owner its turn before dispatching anything: a window
            // closed by the titlebar during the previous iteration is reclaimed
            // here, and the callback may call quit().
            if (self.loop_turn_callback) |on_turn| on_turn(self);
            if (!self.running) break;

            // With no open windows there is nothing to present and nothing to
            // receive input. The owner's quit policy still decides teardown.
            if (self.openWindowCount() == 0) break;

            self.pump();
            if (!self.running) break;

            self.renderOpenWindows();

            // Drain any messages generated by rendering (e.g. WM_PAINT)
            // before waiting, so the next turn starts from a clean queue.
            self.pump();
            if (!self.running) break;

            if (self.hasPendingWork()) {
                // A frame was requested during render: pace with DwmFlush and
                // go straight to the next iteration, but still let messages
                // in (the wait below handles both).
                if (win32.DwmFlush() != win32.S_OK) win32.Sleep(16);
                continue;
            }

            // Idle: block until a message or a WM_TIMER deadline arrives.
            // `MWMO_INPUTAVAILABLE` keeps already-queued messages from being
            // stranded behind the wait.
            _ = win32.MsgWaitForMultipleObjectsEx(
                0,
                null,
                win32.INFINITE,
                @bitCast(win32.QS_ALLINPUT),
                @bitCast(win32.MWMO_INPUTAVAILABLE),
            );
        }
    }

    pub fn quit(self: *Self) void {
        self.running = false;
        win32.PostQuitMessage(0);
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    /// Whether the host can still carry messages. Win32 queues exist for the
    /// lifetime of the thread, so this is the mirror of `isRunning` that a
    /// caller driving its own loop can poll (see `linux_demo.zig`).
    pub fn isConnected(self: *const Self) bool {
        _ = self;
        return true;
    }

    /// Drain and dispatch one round of queued messages. A hand-rolled loop
    /// (see `linux_demo.zig`) calls this instead of `run()`; returning false
    /// means `WM_QUIT` arrived.
    pub fn dispatch(self: *Self) bool {
        var msg: win32.MSG = undefined;
        if (win32.PeekMessageW(&msg, null, 0, 0, @bitCast(win32.PM_REMOVE)) == 0) return true;
        if (msg.message == win32.WM_QUIT) {
            self.running = false;
            return false;
        }
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
        return true;
    }

    /// No-op on Win32: `DispatchMessageW` delivers messages synchronously,
    /// so there is no outgoing request queue to flush. Kept so a caller
    /// driving its own loop has the same shape on every native backend.
    pub fn flush(self: *Self) void {
        _ = self;
    }

    /// System scale factor, used before a window exists to pick its initial
    /// size. Per-window DPI replaces this once the HWND is live.
    pub fn primaryScaleFactor(self: *const Self) f64 {
        _ = self;
        const dpi = win32.GetDpiForSystem();
        if (dpi == 0) return 1.0;
        return @as(f64, @floatFromInt(dpi)) /
            @as(f64, @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "capabilities advertise only implemented services" {
    const caps = WindowsPlatform.capabilities;
    try std.testing.expect(caps.high_dpi);
    try std.testing.expect(caps.gpu_accelerated);
    try std.testing.expect(caps.custom_cursors);
    try std.testing.expect(!caps.clipboard);
    try std.testing.expect(!caps.file_dialogs);
    try std.testing.expect(!caps.ime);
    try std.testing.expect(!caps.glass_effects);
    try std.testing.expectEqualStrings("Windows/Win32", caps.name);
    // The backend name is the compile-time-selected renderer, not a pinned
    // string: `-Dgpu-backend=dx11` builds must not fail this test.
    try std.testing.expectEqualStrings(window_mod.renderer_name, caps.graphics_backend);
    try std.testing.expect(caps.graphics_backend.len > 0);
}
