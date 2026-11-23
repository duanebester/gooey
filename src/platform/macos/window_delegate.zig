const objc = @import("objc");

const Window = @import("window.zig").Window;

var delegate_class: ?objc.Class = null;

pub fn registerClass() !void {
    if (delegate_class != null) return;

    const NSObject = objc.getClass("NSObject") orelse return error.ClassNotFound;

    var cls = objc.allocateClassPair(NSObject, "gooeyWindowDelegate") orelse
        return error.ClassAllocationFailed;

    if (!cls.addIvar("_gooeyWindow")) {
        return error.IvarAddFailed;
    }

    if (!cls.addMethod("windowShouldClose:", windowShouldClose)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowDidResize:", windowDidResize)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowDidChangeBackingProperties:", windowDidChangeBackingProperties)) {
        return error.MethodAddFailed;
    }
    if (!cls.addMethod("windowDidResignKey:", windowDidResignKey)) {
        return error.MethodAddFailed;
    }

    objc.registerClassPair(cls);
    delegate_class = cls;
}

pub fn create(window: *Window) !objc.Object {
    if (delegate_class == null) {
        try registerClass();
    }

    const cls = delegate_class.?;
    const delegate = cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});

    const window_obj = objc.Object.fromId(@as(objc.c.id, @ptrCast(window)));
    delegate.setInstanceVariable("_gooeyWindow", window_obj);

    return delegate;
}

inline fn getWindow(self: objc.c.id) ?*Window {
    const delegate = objc.Object.fromId(self);
    const ptr = delegate.getInstanceVariable("_gooeyWindow");
    return @ptrCast(@alignCast(ptr.value));
}

fn windowDidResize(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleResize();
}

fn windowDidChangeBackingProperties(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleResize();
}

fn windowDidResignKey(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const NSEvent = objc.getClass("NSEvent") orelse return;
    const buttons = NSEvent.msgSend(usize, "pressedMouseButtons", .{});
    if (buttons == 0) return;
    _ = window.handleInput(.pointer_cancelled);
}

fn windowShouldClose(self: objc.c.id, _: objc.c.SEL, _: objc.c.id) callconv(.c) bool {
    const window = getWindow(self) orelse return true;
    return window.handleClose();
}
