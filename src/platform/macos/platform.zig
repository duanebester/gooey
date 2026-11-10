//! macOS platform: the shared NSApplication, its event loop, the main menu,
//! and the quit Apple Event. The core host (`core_host.zig`) runs `run` and
//! turns the loop through `setLoopTurnCallback`.

const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");
const appkit = @import("appkit.zig");

/// Nonzero when the calling thread is the process's main thread.
extern "c" fn pthread_main_np() c_int;

// External Foundation constants - linked at runtime
extern "c" var NSDefaultRunLoopMode: *anyopaque;

// We need distantFuture for blocking event wait
fn getDistantFuture() objc.Object {
    const NSDate = objc.getClass("NSDate") orelse unreachable;
    return NSDate.msgSend(objc.Object, "distantFuture", .{});
}

/// `kCoreEventClass` ('aevt') and `kAEQuitApplication` ('quit'): the event the
/// Dock's Quit, loginwindow at logout, and `osascript ... to quit` send.
const ae_core_event_class: u32 = 0x61657674;
const ae_quit_application: u32 = 0x71756974;

/// Receives the quit Apple Event; registered once, by the first `initInPlace`.
var quit_handler_class: ?objc.Class = null;

pub const MacPlatform = struct {
    app: objc.Object,
    running: bool,

    /// A `GooeyQuitHandler` pointing back here; see `handleQuitEvent`.
    quit_handler: objc.Object,
    /// The window Cmd+Q closes, set by `installMainMenu`.
    quit_window: ?objc.Object,
    /// The quit Apple Event whose reply waits for teardown; `deinit` sends it.
    quit_suspension: ?*const anyopaque,

    /// Owner hook fired once per `run` iteration; see `setLoopTurnCallback`.
    loop_turn_callback: ?LoopTurnCallback = null,

    const Self = @This();

    /// Callback invoked once per iteration of the `run` loop.
    pub const LoopTurnCallback = *const fn (*Self) void;

    /// Initialize in place at the caller's final address, which the core
    /// host's loop-turn callback receives.
    pub fn initInPlace(self: *Self, allocator: std.mem.Allocator) !void {
        assert(@intFromPtr(self) != 0);
        _ = allocator; // Every backend's platform takes one; AppKit needs none.

        const NSApp = objc.getClass("NSApplication") orelse return error.ClassNotFound;
        const app = NSApp.msgSend(objc.Object, "sharedApplication", .{});
        if (app.value == null) return error.ApplicationUnavailable;

        // NSApplicationActivationPolicyRegular: a foreground app with a Dock
        // tile and a menu bar, as opposed to an accessory or background agent.
        _ = app.msgSend(bool, "setActivationPolicy:", .{@as(i64, 0)});

        const handler_class = try registerQuitHandlerClass();
        const handler = handler_class.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        if (handler.value == null) return error.QuitHandlerUnavailable;
        const self_id: objc.c.id = @ptrCast(self);
        handler.setInstanceVariable("_gooeyPlatform", objc.Object.fromId(self_id));

        self.app = app;
        self.running = false;
        self.loop_turn_callback = null;
        self.quit_handler = handler;
        self.quit_window = null;
        self.quit_suspension = null;

        assert(self.app.value != null);
        assert(!self.running);
    }

    /// Runs last in the core host's teardown, so a held quit Apple Event is
    /// answered only once every other deinit has run. Its sender (the Dock,
    /// or loginwindow at logout) gets success, and the process exits 0.
    pub fn deinit(self: *Self) void {
        assert(self.app.value != null);
        self.running = false;
        const manager = appleEventManager();
        if (self.quit_suspension) |suspension| {
            manager.msgSend(void, "resumeWithSuspensionID:", .{suspension});
            self.quit_suspension = null;
        }
        // The manager does not retain its handlers, so unhook before release.
        manager.msgSend(void, "removeEventHandlerForEventClass:andEventID:", .{
            ae_core_event_class,
            ae_quit_application,
        });
        self.quit_handler.release();
        assert(!self.running);
        assert(self.quit_suspension == null);
        // NSApplication is a process-wide singleton; releasing it would be a
        // double-free of a shared instance we never owned.
    }

    /// Install the per-turn owner hook. `null` clears it.
    pub fn setLoopTurnCallback(self: *Self, callback: ?LoopTurnCallback) void {
        self.loop_turn_callback = callback;
    }

    /// Run the application event loop.
    /// This blocks until quit() is called or the app terminates.
    /// The core host renders on its own thread, not here.
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
        // After `finishLaunching`, which installs AppKit's own quit handler.
        const install = "setEventHandler:andSelector:forEventClass:andEventID:";
        appleEventManager().msgSend(void, install, .{
            self.quit_handler.value,
            objc.sel("handleQuitEvent:withReplyEvent:"),
            ae_core_event_class,
            ae_quit_application,
        });

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
            // ran, including `windowShouldClose:` for a titlebar close, has
            // unwound off the stack, and the owner gets its turn here. A turn
            // is owed once per iteration even when no event came back.
            //
            // AppKit's nested run loops (menu tracking, modal panels, live
            // resize) never reach this line, so no turn fires during them.
            if (self.loop_turn_callback) |on_turn| on_turn(self);
        }
    }

    /// Stop the loop so `run` returns and its caller tears down in order.
    /// `-[NSApp terminate:]` would `exit()` from inside this call and skip
    /// every deinit; the quit Apple Event avoids it (`handleQuitEvent`).
    pub fn quit(self: *Self) void {
        assert(self.app.value != null);

        self.running = false;
        assert(!self.isRunning());

        // `run` checks `running` only after an event, and a quit from a
        // main-queue tick arrives as none.
        self.postWakeEvent();
    }

    /// Wake the event loop: it blocks in `nextEventMatchingMask:` and turns
    /// only after an event, which a close sent as `performClose:` (from the
    /// Quit menu item or a script) or a main-queue tick does not produce.
    pub fn postWakeEvent(self: *Self) void {
        const NSEvent = objc.getClass("NSEvent") orelse return;
        const ns_event_type_application_defined: u64 = 15;
        const event = NSEvent.msgSend(
            objc.Object,
            "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:" ++
                "subtype:data1:data2:",
            .{
                ns_event_type_application_defined,
                appkit.NSPoint{ .x = 0, .y = 0 },
                @as(u64, 0),
                @as(f64, 0),
                @as(i64, 0),
                @as(objc.c.id, null),
                @as(i16, 0),
                @as(i64, 0),
                @as(i64, 0),
            },
        );
        assert(event.value != null);
        self.app.msgSend(void, "postEvent:atStart:", .{ event.value, true });
    }

    /// Install a main menu whose app menu holds `quit_title` on Cmd+Q. The
    /// item sends `performClose:` to `ns_window`, so Cmd+Q takes the close
    /// button's path. The view's `performKeyEquivalent:` runs before the
    /// menu, so an app keymap that claims Cmd+Q still wins.
    pub fn installMainMenu(self: *Self, ns_window: objc.Object, quit_title: [:0]const u8) !void {
        assert(self.app.value != null);
        assert(ns_window.value != null);
        const NSMenu = objc.getClass("NSMenu") orelse return error.ClassNotFound;
        const NSMenuItem = objc.getClass("NSMenuItem") orelse return error.ClassNotFound;
        const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
        // `run` has not pushed its pool yet; the strings below autorelease.
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        // Each `alloc`/`init` is ours (+1); the parent retains it, so release.
        const main_menu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        defer main_menu.release();
        const app_item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        defer app_item.release();
        const app_menu = NSMenu.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
        defer app_menu.release();
        const quit_item = NSMenuItem.msgSend(objc.Object, "alloc", .{}).msgSend(
            objc.Object,
            "initWithTitle:action:keyEquivalent:",
            .{
                NSString.msgSend(objc.Object, "stringWithUTF8String:", .{quit_title.ptr}),
                objc.sel("performClose:"),
                NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"q"}),
            },
        );
        defer quit_item.release();

        quit_item.msgSend(void, "setTarget:", .{ns_window});
        self.quit_window = ns_window;
        app_menu.msgSend(void, "addItem:", .{quit_item});
        app_item.msgSend(void, "setSubmenu:", .{app_menu});
        main_menu.msgSend(void, "addItem:", .{app_item});
        self.app.msgSend(void, "setMainMenu:", .{main_menu});
        assert(self.app.msgSend(objc.c.id, "mainMenu", .{}) == main_menu.value);
    }

    /// The quit Apple Event (Dock Quit, logout, `osascript`) closes the window
    /// the way Cmd+Q does, and holds the event's reply until `deinit`.
    ///
    /// AppKit's own handler calls `terminate:`, which `exit()`s and skips
    /// teardown. Answering `applicationShouldTerminate:` with
    /// `NSTerminateLater` does not help: `terminate:` then waits in a nested
    /// run loop for the reply, so `run` never returns to tear down, and the
    /// reply `exit()`s from there. Suspending the event is what
    /// `NSTerminateLater` does for its sender, without the nested loop.
    fn handleQuitEvent(
        handler: objc.c.id,
        _: objc.c.SEL,
        _: objc.c.id, // event
        _: objc.c.id, // reply
    ) callconv(.c) void {
        const ptr = objc.Object.fromId(handler).getInstanceVariable("_gooeyPlatform");
        const self: *Self = @ptrCast(@alignCast(ptr.value orelse return));
        assert(self.app.value != null);
        // A repeated quit is answered now; the first one's reply is held.
        if (self.quit_suspension != null) return;
        self.quit_suspension = appleEventManager().msgSend(
            ?*const anyopaque,
            "suspendCurrentAppleEvent",
            .{},
        );
        assert(self.quit_suspension != null);
        // A file dialog's modal loop would hold `run` until the user answers
        // it, so end it: the dialog reports a cancel, then the window closes.
        if (self.app.msgSend(objc.c.id, "modalWindow", .{}) != null) {
            self.app.msgSend(void, "stopModal", .{});
        }
        const window = self.quit_window orelse return self.quit();
        // `performClose:` beeps and does nothing while a modal session runs,
        // so it waits until the loop is back in the default mode: after this
        // event, and after the modal loop `stopModal` ends.
        window.msgSend(void, "performSelector:withObject:afterDelay:", .{
            objc.sel("performClose:"),
            @as(objc.c.id, null),
            @as(f64, 0),
        });
    }

    /// Whether the host event loop is currently pumping events. Only
    /// observable from inside a callback dispatched by `run`.
    pub fn isRunning(self: *const Self) bool {
        assert(self.app.value != null);
        return self.running;
    }

    fn appleEventManager() objc.Object {
        const NSAppleEventManager = objc.getClass("NSAppleEventManager") orelse unreachable;
        return NSAppleEventManager.msgSend(objc.Object, "sharedAppleEventManager", .{});
    }

    /// Register `GooeyQuitHandler` once per process.
    fn registerQuitHandlerClass() !objc.Class {
        if (quit_handler_class) |class| return class;
        const NSObject = objc.getClass("NSObject") orelse return error.ClassNotFound;
        var class = objc.allocateClassPair(NSObject, "GooeyQuitHandler") orelse
            return error.ClassAllocationFailed;
        if (!class.addIvar("_gooeyPlatform")) return error.IvarAddFailed;
        if (!class.addMethod("handleQuitEvent:withReplyEvent:", handleQuitEvent)) {
            return error.MethodAddFailed;
        }
        objc.registerClassPair(class);
        quit_handler_class = class;
        return class;
    }

    // =========================================================================
    // Calls from the 0.3.1 `context/window.zig`
    // =========================================================================
    //
    // The core never makes these calls. They stay only while that file
    // compiles, and go when phase 6 deletes it. The core host's render thread
    // takes no lock the main thread could hold, so there is nothing to lock.

    pub fn lockRenderThreads(self: *Self) void {
        assert(self.app.value != null);
        assert(pthread_main_np() != 0);
    }

    pub fn unlockRenderThreads(self: *Self) void {
        assert(self.app.value != null);
        assert(pthread_main_np() != 0);
    }
};
