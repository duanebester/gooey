const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");
const appkit = @import("appkit.zig");

extern "c" fn pthread_main_np() c_int;

extern "c" var NSDefaultRunLoopMode: *anyopaque;

fn getDistantFuture() objc.Object {
    const NSDate = objc.getClass("NSDate") orelse unreachable;
    return NSDate.msgSend(objc.Object, "distantFuture", .{});
}

const ae_core_event_class: u32 = 0x61657674;
const ae_quit_application: u32 = 0x71756974;

var quit_handler_class: ?objc.Class = null;

pub const MacPlatform = struct {
    app: objc.Object,
    running: bool,

    quit_handler: objc.Object,
    quit_window: ?objc.Object,
    quit_suspension: ?*const anyopaque,

    loop_turn_callback: ?LoopTurnCallback = null,

    const Self = @This();

    pub const LoopTurnCallback = *const fn (*Self) void;

    pub fn initInPlace(self: *Self) !void {
        assert(@intFromPtr(self) != 0);

        const NSApp = objc.getClass("NSApplication") orelse return error.ClassNotFound;
        const app = NSApp.msgSend(objc.Object, "sharedApplication", .{});
        if (app.value == null) return error.ApplicationUnavailable;

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

    pub fn deinit(self: *Self) void {
        assert(self.app.value != null);
        self.running = false;
        const manager = appleEventManager();
        if (self.quit_suspension) |suspension| {
            manager.msgSend(void, "resumeWithSuspensionID:", .{suspension});
            self.quit_suspension = null;
        }
        manager.msgSend(void, "removeEventHandlerForEventClass:andEventID:", .{
            ae_core_event_class,
            ae_quit_application,
        });
        self.quit_handler.release();
        assert(!self.running);
        assert(self.quit_suspension == null);
    }

    pub fn setLoopTurnCallback(self: *Self, callback: ?LoopTurnCallback) void {
        self.loop_turn_callback = callback;
    }

    pub fn run(self: *Self) void {
        assert(self.app.value != null);
        assert(!self.running);

        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        self.running = true;

        _ = self.app.msgSend(void, "activateIgnoringOtherApps:", .{true});

        _ = self.app.msgSend(void, "finishLaunching", .{});
        const install = "setEventHandler:andSelector:forEventClass:andEventID:";
        appleEventManager().msgSend(void, install, .{
            self.quit_handler.value,
            objc.sel("handleQuitEvent:withReplyEvent:"),
            ae_core_event_class,
            ae_quit_application,
        });

        while (self.running) {
            const inner_pool = objc.AutoreleasePool.init();
            defer inner_pool.deinit();

            const event = self.app.msgSend(
                ?*anyopaque,
                "nextEventMatchingMask:untilDate:inMode:dequeue:",
                .{
                    @as(u64, 0xFFFFFFFFFFFFFFFF),
                    getDistantFuture().value,
                    NSDefaultRunLoopMode,
                    true,
                },
            );

            if (event) |e| {
                self.app.msgSend(void, "sendEvent:", .{e});
                self.app.msgSend(void, "updateWindows", .{});
            }

            if (self.loop_turn_callback) |on_turn| on_turn(self);
        }
    }

    pub fn quit(self: *Self) void {
        assert(self.app.value != null);

        self.running = false;
        assert(!self.isRunning());

        self.postWakeEvent();
    }

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

    pub fn installMainMenu(self: *Self, ns_window: objc.Object, quit_title: [:0]const u8) !void {
        assert(self.app.value != null);
        assert(ns_window.value != null);
        const NSMenu = objc.getClass("NSMenu") orelse return error.ClassNotFound;
        const NSMenuItem = objc.getClass("NSMenuItem") orelse return error.ClassNotFound;
        const NSString = objc.getClass("NSString") orelse return error.ClassNotFound;
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

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

    fn handleQuitEvent(
        handler: objc.c.id,
        _: objc.c.SEL,
        _: objc.c.id,
        _: objc.c.id,
    ) callconv(.c) void {
        const ptr = objc.Object.fromId(handler).getInstanceVariable("_gooeyPlatform");
        const self: *Self = @ptrCast(@alignCast(ptr.value orelse return));
        assert(self.app.value != null);
        if (self.quit_suspension != null) return;
        self.quit_suspension = appleEventManager().msgSend(
            ?*const anyopaque,
            "suspendCurrentAppleEvent",
            .{},
        );
        assert(self.quit_suspension != null);
        if (self.app.msgSend(objc.c.id, "modalWindow", .{}) != null) {
            self.app.msgSend(void, "stopModal", .{});
        }
        const window = self.quit_window orelse return self.quit();
        window.msgSend(void, "performSelector:withObject:afterDelay:", .{
            objc.sel("performClose:"),
            @as(objc.c.id, null),
            @as(f64, 0),
        });
    }

    pub fn isRunning(self: *const Self) bool {
        assert(self.app.value != null);
        return self.running;
    }

    fn appleEventManager() objc.Object {
        const NSAppleEventManager = objc.getClass("NSAppleEventManager") orelse unreachable;
        return NSAppleEventManager.msgSend(objc.Object, "sharedAppleEventManager", .{});
    }

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

    pub fn lockRenderThreads(self: *Self) void {
        assert(self.app.value != null);
        assert(pthread_main_np() != 0);
    }

    pub fn unlockRenderThreads(self: *Self) void {
        assert(self.app.value != null);
        assert(pthread_main_np() != 0);
    }
};
