//! macOS Platform implementation using Cocoa/AppKit
//!
//! This module provides the macOS-specific platform implementation:
//! - AppKit event loop
//! - Metal rendering context
//! - Cocoa window management

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");
const interface_mod = @import("../interface.zig");
const file_dialog = @import("file_dialog.zig");
const window_registry = @import("../window_registry.zig");
const WindowId = window_registry.WindowId;
const WindowRegistry = window_registry.WindowRegistry;

// External Foundation constants - linked at runtime
extern "c" var NSDefaultRunLoopMode: *anyopaque;

// We need distantFuture for blocking event wait
fn getDistantFuture() objc.Object {
    const NSDate = objc.getClass("NSDate") orelse unreachable;
    return NSDate.msgSend(objc.Object, "distantFuture", .{});
}

pub const MacPlatform = struct {
    app: objc.Object,
    delegate: ?objc.Object,
    running: bool,

    /// Registry for tracking all windows by ID
    window_registry: WindowRegistry,

    /// Allocator for platform resources
    allocator: std.mem.Allocator,

    /// Owner hook fired once per `run` iteration; see `setLoopTurnCallback`.
    loop_turn_callback: ?LoopTurnCallback = null,

    const Self = @This();

    /// Callback invoked once per iteration of the `run` loop.
    pub const LoopTurnCallback = *const fn (*Self) void;

    /// Platform capabilities for macOS.
    ///
    /// The type annotation is stylistic — it names the type at a glance.
    /// `contract.verifyConst` is satisfied either way; the un-annotated
    /// `PlatformCapabilities{ ... }` form used by the Linux backend already
    /// has the same `@TypeOf`.
    pub const capabilities: interface_mod.PlatformCapabilities = .{
        .high_dpi = true,
        .multi_window = true,
        .gpu_accelerated = true,
        .display_link = true,
        .can_close_window = true,
        .glass_effects = true,
        // `metal.Renderer.getPostProcess` exists, which is the whole contract
        // this flag asserts. Metal is currently the only renderer with the
        // pass, so this is the only backend that may set it.
        .has_post_process = true,
        .clipboard = true,
        .file_dialogs = true,
        .ime = true,
        .custom_cursors = true,
        // AppKit can do this (`-[NSWindow performWindowDragWithEvent:]`,
        // `movableByWindowBackground`), but no Gooey code requests it and
        // `PlatformWindow` exposes no drag entry point, so advertising it
        // would promise a call that does not exist.
        .window_drag_by_content = false,
        .name = "macOS",
        .graphics_backend = "Metal",
    };

    /// Initialize in place at the caller's final address.
    ///
    /// Field-by-field rather than a struct literal: `MacPlatform` embeds the
    /// window registry, so a literal would materialize a stack temporary and
    /// copy it (CLAUDE.md §13). The address is also handed to AppKit-owned
    /// window delegates, so it must be stable before initialization ends.
    pub fn initInPlace(self: *Self, allocator: std.mem.Allocator) !void {
        assert(@intFromPtr(self) != 0);

        const NSApp = objc.getClass("NSApplication") orelse return error.ClassNotFound;
        const app = NSApp.msgSend(objc.Object, "sharedApplication", .{});
        if (app.value == null) return error.ApplicationUnavailable;

        // NSApplicationActivationPolicyRegular: a foreground app with a Dock
        // tile and a menu bar, as opposed to an accessory or background agent.
        _ = app.msgSend(bool, "setActivationPolicy:", .{@as(i64, 0)});

        self.allocator = allocator;
        self.app = app;
        self.delegate = null;
        self.running = false;
        self.loop_turn_callback = null;

        self.window_registry = WindowRegistry.init(allocator);
        errdefer self.window_registry.deinit();

        assert(self.window_registry.count() == 0);
        assert(!self.running);
    }

    pub fn deinit(self: *Self) void {
        assert(self.app.value != null);

        // Windows unregister themselves in `Window.deinit`. Any that remain
        // are leaked by the caller, not by us, so bound-check rather than
        // demand emptiness: teardown order is the application's choice.
        assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);

        self.running = false;
        self.window_registry.deinit();
        // NSApplication is a process-wide singleton; releasing it would be a
        // double-free of a shared instance we never owned.
    }

    // =========================================================================
    // Window Registry
    // =========================================================================

    /// Register a window with the platform and return its ID.
    pub fn registerWindow(self: *Self, window: *anyopaque) !WindowId {
        assert(@intFromPtr(window) != 0);
        assert(self.window_registry.count() < WindowRegistry.MAX_WINDOWS);

        const id = try self.window_registry.register(window);
        assert(id.isValid());
        return id;
    }

    /// Unregister a window by ID.
    pub fn unregisterWindow(self: *Self, id: WindowId) void {
        assert(id.isValid());
        const before = self.window_registry.count();

        _ = self.window_registry.unregister(id);

        // `unregister` is idempotent, so only assert it never grew the set.
        assert(self.window_registry.count() <= before);
    }

    /// Get a window by ID.
    pub fn getWindow(self: *const Self, id: WindowId) ?*anyopaque {
        if (!id.isValid()) return null;
        assert(self.window_registry.count() <= WindowRegistry.MAX_WINDOWS);
        return self.window_registry.get(id);
    }

    /// Get the active window ID.
    pub fn getActiveWindowId(self: *const Self) ?WindowId {
        const id = self.window_registry.getActiveWindow();
        if (id) |active| assert(active.isValid());
        return id;
    }

    /// Set the active window.
    pub fn setActiveWindowId(self: *Self, id: ?WindowId) void {
        if (id) |active| {
            assert(active.isValid());
            assert(self.window_registry.contains(active));
        }
        self.window_registry.setActiveWindow(id);
    }

    /// Get the number of registered windows.
    pub fn windowCount(self: *const Self) u32 {
        const total = self.window_registry.count();
        assert(total <= WindowRegistry.MAX_WINDOWS);
        return total;
    }

    /// Install the per-turn owner hook. `null` clears it.
    ///
    /// Contract-pinned; see the `LoopTurnCallback` note in
    /// `platform/contract.zig` for why the owner needs this point at all.
    pub fn setLoopTurnCallback(self: *Self, callback: ?LoopTurnCallback) void {
        self.loop_turn_callback = callback;
    }

    /// Run the application event loop.
    /// This blocks until quit() is called or the app terminates.
    /// Rendering happens on the DisplayLink thread, not here.
    pub fn run(self: *Self) void {
        assert(self.app.value != null);
        assert(!self.running);

        // Create autorelease pool (modern runtime API: objc_autoreleasePoolPush/Pop)
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        self.running = true;

        // Activate the app
        _ = self.app.msgSend(void, "activateIgnoringOtherApps:", .{true});

        // Finish launching
        _ = self.app.msgSend(void, "finishLaunching", .{});

        // Run the event loop - BLOCKING on events
        while (self.running) {
            // Create an inner autorelease pool for each iteration
            const inner_pool = objc.AutoreleasePool.init();
            defer inner_pool.deinit();

            // Block waiting for events (CPU efficient!)
            const event = self.app.msgSend(
                ?*anyopaque,
                "nextEventMatchingMask:untilDate:inMode:dequeue:",
                .{
                    @as(u64, 0xFFFFFFFFFFFFFFFF), // NSEventMaskAny
                    getDistantFuture().value,
                    NSDefaultRunLoopMode,
                    true,
                },
            );

            if (event) |e| {
                self.app.msgSend(void, "sendEvent:", .{e});
                self.app.msgSend(void, "updateWindows", .{});
            }

            // `sendEvent:` has returned, so every AppKit delegate callback it
            // ran — including `windowShouldClose:` and `windowWillClose:` for a
            // titlebar close — has unwound off the stack. This is the point
            // where destroying a window's `WindowContext` is sound, so the
            // owner gets its turn here.
            //
            // Outside the `if` above: a turn is owed once per iteration even
            // when the host handed back no event, because the work waiting to
            // be reclaimed is the *previous* event's close.
            //
            // AppKit's nested run loops (menu tracking, modal panels, live
            // resize) never reach this line, so no turn fires during them.
            // That only defers reclamation to the next outer iteration, which
            // is exactly the deferral this hook is built around.
            if (self.loop_turn_callback) |on_turn| on_turn(self);
        }
    }

    pub fn quit(self: *Self) void {
        assert(self.app.value != null);

        self.running = false;
        assert(!self.isRunning());

        self.app.msgSend(void, "terminate:", .{@as(?*anyopaque, null)});
    }

    /// Whether the host event loop is currently pumping events.
    ///
    /// macOS is a `blocking_event_loop` backend, so this is only observable
    /// from inside a callback dispatched by `run`.
    pub fn isRunning(self: *const Self) bool {
        assert(self.app.value != null);
        return self.running;
    }

    // =========================================================================
    // File Dialogs
    // =========================================================================

    /// Show a file/directory open dialog (blocking/modal).
    /// Returns null if user cancels or on error.
    /// Caller owns returned PathPromptResult and must call deinit().
    pub fn promptForPaths(
        _: *Self,
        allocator: std.mem.Allocator,
        options: file_dialog.PathPromptOptions,
    ) ?file_dialog.PathPromptResult {
        return file_dialog.promptForPaths(allocator, options);
    }

    /// Show a file save dialog (blocking/modal).
    /// Returns null if user cancels or on error.
    /// Caller owns returned path and must free with allocator.
    pub fn promptForNewPath(
        _: *Self,
        allocator: std.mem.Allocator,
        options: file_dialog.SavePromptOptions,
    ) ?[]const u8 {
        return file_dialog.promptForNewPath(allocator, options);
    }
};
