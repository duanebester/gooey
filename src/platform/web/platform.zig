//! WebPlatform - Platform implementation for WebAssembly/Browser

const std = @import("std");
const imports = @import("imports.zig");
const window_registry = @import("../window_registry.zig");
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;

pub const WebPlatform = struct {
    /// Whether `run` has armed the frame callback and `quit` has not stopped
    /// it. The core host reads it through `isRunning` after every frame.
    running: bool = false,

    /// Registry for tracking windows by ID.
    /// Note: Web only supports a single window, but included for API consistency.
    window_registry: WindowRegistry,

    const Self = @This();

    /// Initialize in place, as every backend's platform is.
    pub fn initInPlace(self: *Self, allocator: std.mem.Allocator) !void {
        self.window_registry = WindowRegistry.init(allocator);
        // Not running yet. `run` is the only place this becomes true: the host
        // consults `isRunning` after every frame to decide whether to schedule
        // another, and reporting true here would invite a frame against an
        // application that has not finished initializing.
        self.running = false;

        std.debug.assert(self.window_registry.count() == 0);
        std.debug.assert(self.window_registry.getActiveWindow() == null);
    }

    // =========================================================================
    // Window Registry (single window only on web)
    // =========================================================================

    /// Register a window with the platform and return its ID.
    ///
    /// An app has one window (contract decision 14), and the browser owns tab
    /// and window management. Enforce that here rather than letting a second
    /// canvas-less window register and silently never render.
    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        std.debug.assert(self.window_registry.count() == 0);

        const id = try self.window_registry.register(window);

        std.debug.assert(id.isValid());
        std.debug.assert(self.window_registry.count() == 1);
        return id;
    }

    /// Get the active window ID.
    pub fn getActiveWindowId(self: *const Self) ?WindowId {
        const active = self.window_registry.getActiveWindow();
        if (active) |id| std.debug.assert(id.isValid());
        if (self.window_registry.count() == 0) std.debug.assert(active == null);
        return active;
    }

    /// Set the active window by ID.
    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        if (id) |window_id| std.debug.assert(window_id.isValid());

        self.window_registry.setActiveWindow(id);

        std.debug.assert(self.window_registry.getActiveWindow() == id);
    }

    // =========================================================================
    // Frame loop
    // =========================================================================

    /// Arm the browser frame callback and return immediately.
    ///
    /// Unlike the native backends there is no loop to block in, because the
    /// browser owns the clock. `isRunning` is what lets the core host keep
    /// rescheduling, and this is the moment it starts reporting true.
    pub fn run(self: *Self) void {
        // Arming twice would start a second `requestAnimationFrame` chain, and
        // both chains would render every tick for the rest of the session.
        std.debug.assert(!self.running);
        std.debug.assert(self.window_registry.count() <= 1);

        self.running = true;
        imports.requestAnimationFrame();
    }

    /// Stop rescheduling frames. The browser tab itself stays open: a page
    /// cannot close a tab it did not open.
    pub fn quit(self: *Self) void {
        // Legal before `run`, during a frame, and during teardown; all three
        // are states the browser host can reach. The single-window invariant
        // still has to hold, because a `quit` from a stray second canvas would
        // mean the registry guard in `registerWindow` had been bypassed.
        std.debug.assert(self.window_registry.count() <= 1);

        self.running = false;
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }

    // =========================================================================
    // Calls from the 0.3.1 `context/window.zig`
    // =========================================================================
    //
    // The core never makes these calls. They stay only while that file
    // compiles, and go when phase 6 deletes it.

    /// The browser renders frames on the one WASM thread, so a caller already
    /// excludes every frame; there is no lock.
    pub fn lockRenderThreads(self: *Self) void {
        std.debug.assert(self.window_registry.count() <= 1);
    }

    pub fn unlockRenderThreads(self: *Self) void {
        std.debug.assert(self.window_registry.count() <= 1);
    }
};
