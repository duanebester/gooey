//! NSWindowDelegate implementation for handling window events
//! This is the most performant approach - zero overhead when not resizing.

const objc = @import("objc");

const Window = @import("window.zig").Window;

var delegate_class: ?objc.Class = null;

/// Register the gooeyWindowDelegate class with the Objective-C runtime.
/// Must be called once before creating any windows.
pub fn registerClass() !void {
    if (delegate_class != null) return;

    const NSObject = objc.getClass("NSObject") orelse return error.ClassNotFound;

    var cls = objc.allocateClassPair(NSObject, "gooeyWindowDelegate") orelse
        return error.ClassAllocationFailed;

    // Add instance variable to store pointer to Zig Window
    if (!cls.addIvar("_gooeyWindow")) {
        return error.IvarAddFailed;
    }

    // Add delegate methods
    if (!cls.addMethod("windowShouldClose:", windowShouldClose)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowDidResize:", windowDidResize)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowDidChangeBackingProperties:", windowDidChangeBackingProperties)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowWillClose:", windowWillClose)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowDidBecomeKey:", windowDidBecomeKey)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowDidResignKey:", windowDidResignKey)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowWillStartLiveResize:", windowWillStartLiveResize)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowDidEndLiveResize:", windowDidEndLiveResize)) {
        return error.MethodAddFailed;
    }

    objc.registerClassPair(cls);
    delegate_class = cls;
}

/// Create a delegate instance for a window
pub fn create(window: *Window) !objc.Object {
    if (delegate_class == null) {
        try registerClass();
    }

    const cls = delegate_class.?;
    const delegate = cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});

    // Store the Zig window pointer in the delegate's ivar
    // Wrap the raw pointer as an objc.Object (it's just stored as an id)
    const window_obj = objc.Object.fromId(@as(objc.c.id, @ptrCast(window)));
    delegate.setInstanceVariable("_gooeyWindow", window_obj);

    return delegate;
}

/// Get the Zig Window from a delegate instance
inline fn getWindow(self: objc.c.id) ?*Window {
    const delegate = objc.Object.fromId(self);
    const ptr = delegate.getInstanceVariable("_gooeyWindow");
    return @ptrCast(@alignCast(ptr.value));
}

// =============================================================================
// Delegate Method Implementations
// =============================================================================

fn windowDidResize(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleResize();
}

fn windowDidChangeBackingProperties(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    // Called when window moves to a display with different scale factor
    const window = getWindow(self) orelse return;
    window.handleResize(); // Scale factor may have changed
}

fn windowShouldClose(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) bool {
    const window = getWindow(self) orelse return true;
    return window.handleClose();
}

fn windowWillClose(_: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    // Window is definitely closing now - cleanup happens in handleClose via windowShouldClose
}

fn windowDidBecomeKey(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleFocusChange(true);
}

fn windowDidResignKey(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleFocusChange(false);
}

fn windowWillStartLiveResize(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleLiveResizeStart();
}

fn windowDidEndLiveResize(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleLiveResizeEnd();
}
