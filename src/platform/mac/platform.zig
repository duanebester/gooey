//! macOS Platform implementation using Cocoa/AppKit
//!
//! This module provides the macOS-specific platform implementation:
//! - AppKit event loop
//! - Metal rendering context
//! - Cocoa window management

const std = @import("std");
const objc = @import("objc");
const interface_mod = @import("../interface.zig");

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

    const Self = @This();

    /// Platform capabilities for macOS
    pub const capabilities = interface_mod.PlatformCapabilities{
        .high_dpi = true,
        .multi_window = true,
        .gpu_accelerated = true,
        .display_link = true,
        .can_close_window = true,
        .glass_effects = true,
        .clipboard = false,
        .file_dialogs = false,
        .ime = true,
        .custom_cursors = true,
        .window_drag_by_content = true,
        .name = "macOS",
        .graphics_backend = "Metal",
    };

    pub fn init() !Self {
        // Get NSApplication class
        const NSApp = objc.getClass("NSApplication") orelse return error.ClassNotFound;

        // Get shared application instance
        const app = NSApp.msgSend(objc.Object, "sharedApplication", .{});

        // Set activation policy to regular (foreground app)
        _ = app.msgSend(bool, "setActivationPolicy:", .{@as(i64, 0)});

        return .{
            .app = app,
            .delegate = null,
            .running = false,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // NSApplication is a singleton, don't release
    }

    /// Run the application event loop.
    /// This blocks until quit() is called or the app terminates.
    /// Rendering happens on the DisplayLink thread, not here.
    pub fn run(self: *Self) void {
        // Create autorelease pool
        const NSAutoreleasePoolClass = objc.getClass("NSAutoreleasePool") orelse return;
        const pool = NSAutoreleasePoolClass.msgSend(objc.Object, "alloc", .{});
        const pool_init = pool.msgSend(objc.Object, "init", .{});
        defer pool_init.msgSend(void, "drain", .{});

        self.running = true;

        // Activate the app
        _ = self.app.msgSend(void, "activateIgnoringOtherApps:", .{true});

        // Finish launching
        _ = self.app.msgSend(void, "finishLaunching", .{});

        // Run the event loop - BLOCKING on events
        while (self.running) {
            // Create an inner autorelease pool for each iteration
            const inner_pool = NSAutoreleasePoolClass.msgSend(objc.Object, "alloc", .{});
            const inner_pool_init = inner_pool.msgSend(objc.Object, "init", .{});
            defer inner_pool_init.msgSend(void, "drain", .{});

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
        }
    }

    pub fn quit(self: *Self) void {
        self.running = false;
        self.app.msgSend(void, "terminate:", .{@as(?*anyopaque, null)});
    }

    /// Get this platform as a runtime-polymorphic interface.
    /// Useful for passing to generic code that works with any platform.
    pub fn interface(self: *Self) interface_mod.PlatformVTable {
        return interface_mod.makePlatformVTable(Self, self);
    }

    /// Get platform capabilities
    pub fn getCapabilities(_: *const Self) interface_mod.PlatformCapabilities {
        return capabilities;
    }
};
