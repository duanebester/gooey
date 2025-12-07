//! Custom NSView subclass for receiving mouse/keyboard events
//! Follows the same pattern as window_delegate.zig

const std = @import("std");
const objc = @import("objc");
const input = @import("../../core/input.zig");
const geometry = @import("../../core/geometry.zig");
const appkit = @import("appkit.zig");
const Window = @import("window.zig").Window;

const NSRect = appkit.NSRect;
const NSPoint = appkit.NSPoint;
const NSEventModifierFlags = appkit.NSEventModifierFlags;

var view_class: ?objc.Class = null;

/// Register the GooeyMetalView class with the Objective-C runtime.
/// Must be called once before creating any windows.
pub fn registerClass() !void {
    if (view_class != null) return;

    const NSView = objc.getClass("NSView") orelse return error.ClassNotFound;

    var cls = objc.allocateClassPair(NSView, "GooeyMetalView") orelse
        return error.ClassAllocationFailed;

    // Add instance variable to store pointer to Zig Window
    if (!cls.addIvar("_gooeyWindow")) {
        return error.IvarAddFailed;
    }

    // Required for receiving events
    if (!cls.addMethod("acceptsFirstResponder", acceptsFirstResponder)) return error.MethodAddFailed;
    if (!cls.addMethod("isFlipped", isFlipped)) return error.MethodAddFailed;

    // Keyboard events
    if (!cls.addMethod("keyDown:", keyDown)) return error.MethodAddFailed;
    if (!cls.addMethod("keyUp:", keyUp)) return error.MethodAddFailed;
    if (!cls.addMethod("flagsChanged:", flagsChanged)) return error.MethodAddFailed;

    // Mouse events
    if (!cls.addMethod("mouseDown:", mouseDown)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseUp:", mouseUp)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseMoved:", mouseMoved)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseDragged:", mouseDragged)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseEntered:", mouseEntered)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseExited:", mouseExited)) return error.MethodAddFailed;

    if (!cls.addMethod("rightMouseDown:", rightMouseDown)) return error.MethodAddFailed;
    if (!cls.addMethod("rightMouseUp:", rightMouseUp)) return error.MethodAddFailed;
    if (!cls.addMethod("scrollWheel:", scrollWheel)) return error.MethodAddFailed;

    objc.registerClassPair(cls);
    view_class = cls;
}

/// Create a view instance
pub fn create(frame: NSRect, window: *Window) !objc.Object {
    if (view_class == null) {
        try registerClass();
    }

    const view = view_class.?.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});

    // Store the Zig window pointer
    const window_obj = objc.Object{ .value = @ptrCast(window) };
    view.setInstanceVariable("_gooeyWindow", window_obj);

    return view;
}

// =============================================================================
// Helpers
// =============================================================================

inline fn getWindow(self: objc.c.id) ?*Window {
    const view = objc.Object{ .value = self };
    const ptr = view.getInstanceVariable("_gooeyWindow");
    return @ptrCast(@alignCast(ptr.value));
}

fn parseModifiers(flags: c_ulong) input.Modifiers {
    const mods = NSEventModifierFlags.from(flags);
    return .{
        .shift = mods.shift,
        .ctrl = mods.control,
        .alt = mods.option,
        .cmd = mods.command,
    };
}

fn parseMouseEvent(self: objc.c.id, event_id: objc.c.id, comptime kind: std.meta.Tag(input.InputEvent)) input.InputEvent {
    const view = objc.Object{ .value = self };
    const event = objc.Object{ .value = event_id };

    // Get location in window, convert to view coordinates
    const window_loc: NSPoint = event.msgSend(NSPoint, "locationInWindow", .{});
    const view_loc: NSPoint = view.msgSend(NSPoint, "convertPoint:fromView:", .{ window_loc, @as(?objc.c.id, null) });

    const button: input.MouseButton = switch (event.msgSend(c_long, "buttonNumber", .{})) {
        0 => .left,
        1 => .right,
        else => .middle,
    };

    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const click_count = event.msgSend(c_long, "clickCount", .{});

    return @unionInit(input.InputEvent, @tagName(kind), .{
        .position = geometry.Point(f64).init(view_loc.x, view_loc.y),
        .button = button,
        .click_count = @intCast(@max(0, click_count)),
        .modifiers = parseModifiers(modifier_flags),
    });
}

// =============================================================================
// Method Implementations
// =============================================================================

fn acceptsFirstResponder(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

fn isFlipped(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true; // Use top-left origin like most UI frameworks
}

fn mouseDown(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleInput(parseMouseEvent(self, event, .mouse_down));
}

fn mouseUp(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleInput(parseMouseEvent(self, event, .mouse_up));
}

fn mouseMoved(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleInput(parseMouseEvent(self, event, .mouse_moved));
}

fn mouseDragged(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleInput(parseMouseEvent(self, event, .mouse_dragged));
}

fn mouseEntered(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleInput(.{ .mouse_entered = parseEnterExitEvent(self, event) });
}

fn mouseExited(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleInput(.{ .mouse_exited = parseEnterExitEvent(self, event) });
}

/// Parse enter/exit events (no button or click count)
fn parseEnterExitEvent(self_id: objc.c.id, event_id: objc.c.id) input.MouseEvent {
    const view = objc.Object{ .value = self_id };
    const event = objc.Object{ .value = event_id };

    const window_loc: appkit.NSPoint = event.msgSend(appkit.NSPoint, "locationInWindow", .{});
    const view_loc: appkit.NSPoint = view.msgSend(appkit.NSPoint, "convertPoint:fromView:", .{ window_loc, @as(?objc.c.id, null) });

    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});

    return .{
        .position = geometry.Point(f64).init(view_loc.x, view_loc.y),
        .button = .left, // N/A for enter/exit
        .click_count = 0, // N/A for enter/exit
        .modifiers = parseModifiers(modifier_flags),
    };
}

fn rightMouseDown(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleInput(parseMouseEvent(self, event, .mouse_down));
}

fn rightMouseUp(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.handleInput(parseMouseEvent(self, event, .mouse_up));
}

fn scrollWheel(self: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const view = objc.Object{ .value = self };
    const event = objc.Object{ .value = event_id };

    const window_loc: NSPoint = event.msgSend(NSPoint, "locationInWindow", .{});
    const view_loc: NSPoint = view.msgSend(NSPoint, "convertPoint:fromView:", .{ window_loc, @as(?objc.c.id, null) });

    const delta_x = event.msgSend(f64, "scrollingDeltaX", .{});
    const delta_y = event.msgSend(f64, "scrollingDeltaY", .{});
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});

    window.handleInput(.{ .scroll = .{
        .position = geometry.Point(f64).init(view_loc.x, view_loc.y),
        .delta = geometry.Point(f64).init(delta_x, delta_y),
        .modifiers = parseModifiers(modifier_flags),
    } });
}

// =============================================================================
// Keyboard Method Implementations
// =============================================================================

fn keyDown(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    if (parseKeyEvent(event)) |key_event| {
        window.handleInput(.{ .key_down = key_event });
    }
}

fn keyUp(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    if (parseKeyEvent(event)) |key_event| {
        window.handleInput(.{ .key_up = key_event });
    }
}

fn flagsChanged(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const ns_event = objc.Object{ .value = event };
    const modifier_flags = ns_event.msgSend(c_ulong, "modifierFlags", .{});
    window.handleInput(.{ .modifiers_changed = parseModifiers(modifier_flags) });
}

fn parseKeyEvent(event_id: objc.c.id) ?input.KeyEvent {
    const event = objc.Object{ .value = event_id };

    const key_code = event.msgSend(u16, "keyCode", .{});
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const is_repeat = event.msgSend(bool, "isARepeat", .{});

    // Get characters - call selectors directly (comptime requirement)
    const characters = getCharacters(event);
    const characters_unmod = getCharactersIgnoringModifiers(event);

    return .{
        .key = input.KeyCode.from(key_code),
        .modifiers = parseModifiers(modifier_flags),
        .characters = characters,
        .characters_ignoring_modifiers = characters_unmod,
        .is_repeat = is_repeat,
    };
}

fn getCharacters(event: objc.Object) ?[]const u8 {
    const ns_string = event.msgSend(?objc.Object, "characters", .{}) orelse return null;
    const cstr = ns_string.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
    return std.mem.span(cstr);
}

fn getCharactersIgnoringModifiers(event: objc.Object) ?[]const u8 {
    const ns_string = event.msgSend(?objc.Object, "charactersIgnoringModifiers", .{}) orelse return null;
    const cstr = ns_string.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
    return std.mem.span(cstr);
}
