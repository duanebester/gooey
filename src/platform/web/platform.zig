//! WebPlatform - Platform implementation for WebAssembly/Browser

const std = @import("std");
const imports = @import("imports.zig");
const interface_mod = @import("../interface.zig");
const file_dialog = @import("file_dialog.zig");
const window_registry = @import("../window_registry.zig");
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;

pub const WebPlatform = struct {
    /// Whether `run` has armed the frame callback and `quit` has not stopped
    /// it. Backs `isRunning`; see `contract.verifyPlatform` for the exact
    /// transitions every backend owes its host.
    running: bool = false,

    /// Registry for tracking windows by ID.
    /// Note: Web only supports a single window, but included for API consistency.
    window_registry: WindowRegistry,

    /// Allocator for platform resources
    allocator: std.mem.Allocator,

    /// Owner hook fired once per host frame callback; see `fireLoopTurn`.
    loop_turn_callback: ?LoopTurnCallback = null,

    const Self = @This();

    /// Callback invoked once per host frame callback.
    pub const LoopTurnCallback = *const fn (*Self) void;

    /// Platform capabilities for Web/WASM
    pub const capabilities: interface_mod.PlatformCapabilities = .{
        .high_dpi = true,
        .multi_window = false, // Browser manages windows
        .gpu_accelerated = true,
        .display_link = false, // Uses requestAnimationFrame
        .can_close_window = false, // Can't close browser tabs
        .glass_effects = false, // CSS backdrop-filter would be separate
        // `WebRenderer` has no post-process pass, so `has_post_process` stays
        // at its `false` default rather than being restated here.

        // Write-only: `clipboard.setText` forwards to
        // `navigator.clipboard.writeText`, but `clipboard.getText` always
        // returns null because paste arrives as a JS paste event injected as
        // text input rather than through a read API.
        .clipboard = true,
        .file_dialogs = true, // Via <input type="file"> and Blob downloads
        .ime = true, // Via beforeinput/compositionend events
        // CSS could express every `CursorShape`, but `imports.zig` has no
        // cursor binding, so `WebWindow.setCursorShape` only records the
        // request and the JS host never applies it. Flip back to `true` in the
        // same change that lands the import (design decision 7: unsupported
        // operations must be explicit, and this is the mechanism).
        .custom_cursors = false,
        .window_drag_by_content = false,
        .name = "Web/WASM",
        .graphics_backend = "WebGPU",
    };

    /// Initialize in place.
    ///
    /// The previous by-value `init`/`initWithAllocator` pair forced the caller
    /// to move the platform after construction, which is unsound for any
    /// backend whose host retains `&self`. Web does not retain it today, but
    /// the boundary is shared with Wayland, which does, so the contract pins
    /// the in-place form on every backend (see `contract.verifyPlatform`).
    pub fn initInPlace(self: *Self, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.window_registry = WindowRegistry.init(allocator);
        self.loop_turn_callback = null;
        // Not running yet. `run` is the only place this becomes true: the host
        // consults `isRunning` after every frame to decide whether to schedule
        // another, and reporting true here would invite a frame against an
        // application that has not finished initializing.
        self.running = false;

        std.debug.assert(self.window_registry.count() == 0);
        std.debug.assert(self.window_registry.getActiveWindow() == null);
    }

    pub fn deinit(self: *Self) void {
        // Every window must have unregistered itself first; a live entry here
        // means a `WebWindow.deinit` was skipped and its ID would dangle.
        std.debug.assert(self.window_registry.count() == 0);

        self.window_registry.deinit();
        // Teardown ends the loop whether or not the host called `quit` first,
        // so a post-`deinit` poll cannot ask for another frame.
        self.running = false;
    }

    // =========================================================================
    // Window Registry (single window only on web)
    // =========================================================================

    /// Register a window with the platform and return its ID.
    ///
    /// The browser owns tab and window management, so `capabilities`
    /// advertises `multi_window = false`. Enforce that here rather than
    /// letting a second canvas-less window register and silently never render.
    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        comptime std.debug.assert(!capabilities.multi_window);
        std.debug.assert(self.window_registry.count() == 0);

        const id = try self.window_registry.register(window);

        std.debug.assert(id.isValid());
        std.debug.assert(self.window_registry.count() == 1);
        return id;
    }

    /// Unregister a window by ID.
    pub fn unregisterWindow(self: *Self, id: WindowId) void {
        std.debug.assert(id.isValid());

        _ = self.window_registry.unregister(id);

        std.debug.assert(!self.window_registry.contains(id));
    }

    /// Get a window by ID.
    pub fn getWindow(self: *const Self, id: WindowId) ?*anyopaque {
        const found = self.window_registry.get(id);
        if (!id.isValid()) std.debug.assert(found == null);
        return found;
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

    /// Get the number of registered windows.
    pub fn windowCount(self: *const Self) u32 {
        const count = self.window_registry.count();
        std.debug.assert(count <= 1); // Single-window backend; see `registerWindow`.
        return count;
    }

    /// Arm the browser frame callback and return immediately.
    ///
    /// This is the `DriveModel.host_callback` half of the contract: unlike the
    /// native backends there is no loop to block in, because the host owns the
    /// clock. `isRunning` is what lets the host know to keep rescheduling, and
    /// this is the moment it starts reporting true.
    pub fn run(self: *Self) void {
        // Arming twice would start a second `requestAnimationFrame` chain, and
        // both chains would render every tick for the rest of the session.
        std.debug.assert(!self.running);
        std.debug.assert(self.window_registry.count() <= 1);

        self.running = true;
        imports.requestAnimationFrame();
    }

    /// Stop rescheduling frames. The browser tab itself stays open; see
    /// `capabilities.can_close_window`.
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

    /// Install the per-turn owner hook. `null` clears it.
    ///
    /// Contract-pinned; see the `LoopTurnCallback` note in
    /// `platform/contract.zig` for why the owner needs this point at all.
    pub fn setLoopTurnCallback(self: *Self, callback: ?LoopTurnCallback) void {
        self.loop_turn_callback = callback;
    }

    /// Run the owner's turn for this host frame callback.
    ///
    /// `DriveModel.host_callback` has no loop to fire from: `run` arms
    /// `requestAnimationFrame` and returns, so the browser owns the cycle and
    /// the turn point is the frame entry itself. `WebApp.frame` in
    /// `src/app.zig` calls this once per tick, after it has drained the input
    /// ring buffers and rendered — the same "no window callback is on the
    /// stack" position the native backends fire from.
    ///
    /// Native backends need no equivalent method because their `run` loop is
    /// the cycle and fires the hook inline.
    pub fn fireLoopTurn(self: *Self) void {
        std.debug.assert(self.window_registry.count() <= 1);

        if (self.loop_turn_callback) |on_turn| on_turn(self);
    }

    // =========================================================================
    // File Dialog API
    // =========================================================================

    /// Initialize the file dialog system. Call once at startup.
    pub fn initFileDialog(allocator: std.mem.Allocator) void {
        file_dialog.init(allocator);
    }

    /// Deinitialize file dialog system
    pub fn deinitFileDialog() void {
        file_dialog.deinit();
    }

    /// Open files asynchronously. Callback invoked when user selects or cancels.
    /// Returns request_id for tracking, or null on failure.
    pub fn openFilesAsync(
        _: *Self,
        options: file_dialog.OpenDialogOptions,
        callback: file_dialog.FileDialogCallback,
    ) ?u32 {
        return file_dialog.openFilesAsync(options, callback);
    }

    /// Trigger a file download (web "save" dialog).
    /// Fire-and-forget - browser handles the download.
    pub fn saveFile(_: *Self, filename: []const u8, data: []const u8) void {
        file_dialog.saveFile(filename, data);
    }

    /// Cancel a pending file dialog request
    pub fn cancelFileDialog(_: *Self, request_id: u32) void {
        file_dialog.cancelRequest(request_id);
    }

    /// Check if a file dialog request is pending
    pub fn isFileDialogPending(_: *Self, request_id: u32) bool {
        return file_dialog.isPending(request_id);
    }
};
