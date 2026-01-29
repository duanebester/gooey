//! Custom NSView subclass for receiving mouse/keyboard events
//! Implements NSTextInputClient for IME support (emoji, dead keys, CJK input)

const std = @import("std");
const objc = @import("objc");
const input = @import("../../input/events.zig");
const geometry = @import("../../core/geometry.zig");
const appkit = @import("appkit.zig");
const Window = @import("window.zig").Window;

const NSRect = appkit.NSRect;
const NSPoint = appkit.NSPoint;
const NSRange = appkit.NSRange;
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

    // Register NSTextInputClient protocol conformance (required for IME)
    const NSTextInputClient = objc.getProtocol("NSTextInputClient") orelse
        return error.ProtocolNotFound;
    if (!objc.c.class_addProtocol(cls.value, NSTextInputClient.value)) {
        return error.ProtocolAddFailed;
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

    // NSTextInputClient protocol methods (for IME support)
    if (!cls.addMethod("hasMarkedText", hasMarkedText)) return error.MethodAddFailed;
    if (!cls.addMethod("markedRange", markedRange)) return error.MethodAddFailed;
    if (!cls.addMethod("selectedRange", selectedRange)) return error.MethodAddFailed;
    if (!cls.addMethod("setMarkedText:selectedRange:replacementRange:", setMarkedText)) return error.MethodAddFailed;
    if (!cls.addMethod("unmarkText", unmarkText)) return error.MethodAddFailed;
    if (!cls.addMethod("validAttributesForMarkedText", validAttributesForMarkedText)) return error.MethodAddFailed;
    if (!cls.addMethod("attributedSubstringForProposedRange:actualRange:", attributedSubstring)) return error.MethodAddFailed;
    if (!cls.addMethod("insertText:replacementRange:", insertText)) return error.MethodAddFailed;
    if (!cls.addMethod("characterIndexForPoint:", characterIndexForPoint)) return error.MethodAddFailed;
    if (!cls.addMethod("firstRectForCharacterRange:actualRange:", firstRectForCharacterRange)) return error.MethodAddFailed;
    if (!cls.addMethod("doCommandBySelector:", doCommandBySelector)) return error.MethodAddFailed;
    if (!cls.addMethod("performKeyEquivalent:", performKeyEquivalent)) return error.MethodAddFailed;

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

fn parseEnterExitEvent(self_id: objc.c.id, event_id: objc.c.id) input.MouseEvent {
    const view = objc.Object{ .value = self_id };
    const event = objc.Object{ .value = event_id };

    const window_loc: NSPoint = event.msgSend(NSPoint, "locationInWindow", .{});
    const view_loc: NSPoint = view.msgSend(NSPoint, "convertPoint:fromView:", .{ window_loc, @as(?objc.c.id, null) });
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});

    return .{
        .position = geometry.Point(f64).init(view_loc.x, view_loc.y),
        .button = .left,
        .click_count = 0,
        .modifiers = parseModifiers(modifier_flags),
    };
}

/// Extract UTF-8 string from NSString or NSAttributedString
fn extractString(text_id: objc.c.id) ?[]const u8 {
    const text = objc.Object{ .value = text_id };

    // Check if it's an NSAttributedString
    const NSAttributedString = objc.getClass("NSAttributedString") orelse return null;
    const is_attributed = text.msgSend(bool, "isKindOfClass:", .{NSAttributedString.value});

    const ns_string = if (is_attributed)
        text.msgSend(objc.Object, "string", .{})
    else
        text;

    const cstr = ns_string.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
    return std.mem.span(cstr);
}

// =============================================================================
// NSView Method Implementations
// =============================================================================

fn acceptsFirstResponder(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

fn isFlipped(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

// =============================================================================
// Mouse Method Implementations
// =============================================================================

fn mouseDown(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(parseMouseEvent(self, event, .mouse_down));
}

fn mouseUp(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(parseMouseEvent(self, event, .mouse_up));
}

fn mouseMoved(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(parseMouseEvent(self, event, .mouse_moved));
}

fn mouseDragged(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(parseMouseEvent(self, event, .mouse_dragged));
}

fn mouseEntered(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(.{ .mouse_entered = parseEnterExitEvent(self, event) });
}

fn mouseExited(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(.{ .mouse_exited = parseEnterExitEvent(self, event) });
}

fn rightMouseDown(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(parseMouseEvent(self, event, .mouse_down));
}

fn rightMouseUp(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(parseMouseEvent(self, event, .mouse_up));
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

    _ = window.handleInput(.{ .scroll = .{
        .position = geometry.Point(f64).init(view_loc.x, view_loc.y),
        .delta = geometry.Point(f64).init(delta_x, delta_y),
        .modifiers = parseModifiers(modifier_flags),
    } });
}

// =============================================================================
// Keyboard Method Implementations
// =============================================================================

fn keyDown(self: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const view = objc.Object{ .value = self };

    // Always send key_down event first (for shortcuts, navigation, etc.)
    if (parseKeyEvent(event_id)) |key_event| {
        const handled = window.handleInput(.{ .key_down = key_event });

        // If the app handled the key, don't also send it to IME
        if (handled) {
            return;
        }
    }

    // Store the current event for doCommandBySelector fallback
    window.pending_key_event = event_id;
    defer window.pending_key_event = null;

    // Route through interpretKeyEvents for IME support
    const NSArray = objc.getClass("NSArray") orelse return;
    const event_array = NSArray.msgSend(objc.Object, "arrayWithObject:", .{event_id});
    view.msgSend(void, "interpretKeyEvents:", .{event_array.value});
}

fn keyUp(self: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const event = objc.Object{ .value = event_id };

    const key_code = event.msgSend(u16, "keyCode", .{});
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const is_repeat = event.msgSend(bool, "isARepeat", .{});

    // Don't try to get characters - they can be invalid for system events
    // Text input comes through insertText: via IME
    _ = window.handleInput(.{ .key_up = .{
        .key = input.KeyCode.from(key_code),
        .modifiers = parseModifiers(modifier_flags),
        .characters = null,
        .characters_ignoring_modifiers = null,
        .is_repeat = is_repeat,
    } });
}

fn flagsChanged(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const ns_event = objc.Object{ .value = event };
    const modifier_flags = ns_event.msgSend(c_ulong, "modifierFlags", .{});
    _ = window.handleInput(.{ .modifiers_changed = parseModifiers(modifier_flags) });
}

fn parseKeyEvent(event_id: objc.c.id) ?input.KeyEvent {
    const event = objc.Object{ .value = event_id };

    const key_code = event.msgSend(u16, "keyCode", .{});
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const is_repeat = event.msgSend(bool, "isARepeat", .{});

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
    // Get raw id and check for nil explicitly - ?objc.Object doesn't handle nil correctly
    const ns_string_id: objc.c.id = event.msgSend(objc.c.id, "characters", .{});
    if (ns_string_id == null) return null;

    const ns_string = objc.Object{ .value = ns_string_id };
    // Check length first - UTF8String on empty/special strings can be problematic
    const length: c_ulong = ns_string.msgSend(c_ulong, "length", .{});
    if (length == 0) return null;

    const cstr: ?[*:0]const u8 = ns_string.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (cstr == null) return null;

    return std.mem.span(cstr.?);
}

fn getCharactersIgnoringModifiers(event: objc.Object) ?[]const u8 {
    // Get raw id and check for nil explicitly - ?objc.Object doesn't handle nil correctly
    const ns_string_id: objc.c.id = event.msgSend(objc.c.id, "charactersIgnoringModifiers", .{});
    if (ns_string_id == null) return null;

    const ns_string = objc.Object{ .value = ns_string_id };
    // Check length first - UTF8String on empty/special strings can be problematic
    const length: c_ulong = ns_string.msgSend(c_ulong, "length", .{});
    if (length == 0) return null;

    const cstr: ?[*:0]const u8 = ns_string.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (cstr == null) return null;

    return std.mem.span(cstr.?);
}

// =============================================================================
// NSTextInputClient Protocol Implementation
// =============================================================================

fn hasMarkedText(self: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    const window = getWindow(self) orelse return false;
    return window.marked_text.len > 0;
}

fn markedRange(self: objc.c.id, _: objc.c.SEL) callconv(.c) NSRange {
    const window = getWindow(self) orelse return NSRange.invalid();
    if (window.marked_text.len > 0) {
        return .{ .location = 0, .length = window.marked_text.len };
    }
    return NSRange.invalid();
}

fn selectedRange(_: objc.c.id, _: objc.c.SEL) callconv(.c) NSRange {
    // For now, return an empty selection at position 0
    // A real implementation would query the focused text element
    return .{ .location = 0, .length = 0 };
}

fn performKeyEquivalent(self: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) bool {
    const window = getWindow(self) orelse return false;
    const event = objc.Object{ .value = event_id };

    const key_code = event.msgSend(u16, "keyCode", .{});
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const mods = parseModifiers(modifier_flags);

    // Only handle events with command modifier (key equivalents)
    if (mods.cmd) {
        const key_event = input.KeyEvent{
            .key = input.KeyCode.from(key_code),
            .modifiers = mods,
            .characters = null, // Don't get characters - can crash for key equivalents
            .characters_ignoring_modifiers = null,
            .is_repeat = false,
        };

        // Send to our input handler - if it returns true, we handled it
        if (window.handleInput(.{ .key_down = key_event })) {
            return true;
        }
    }

    // Return false to let the system handle unhandled key equivalents
    return false;
}

fn setMarkedText(
    self: objc.c.id,
    _: objc.c.SEL,
    text_id: objc.c.id,
    _: NSRange,
    _: NSRange,
) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const str = extractString(text_id) orelse "";

    std.debug.print("setMarkedText: \"{s}\"\n", .{str});

    window.setMarkedText(str);
    _ = window.handleInput(.{ .composition = .{ .text = window.marked_text } });
}

fn unmarkText(self: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.clearMarkedText();

    // Send empty composition to signal end
    _ = window.handleInput(.{ .composition = .{
        .text = "",
    } });
}

fn validAttributesForMarkedText(_: objc.c.id, _: objc.c.SEL) callconv(.c) objc.c.id {
    // Return empty array - we don't support styled marked text
    const NSArray = objc.getClass("NSArray") orelse return null;
    return NSArray.msgSend(objc.c.id, "array", .{});
}

fn attributedSubstring(
    _: objc.c.id,
    _: objc.c.SEL,
    _: NSRange, // range
    _: *NSRange, // actual_range
) callconv(.c) objc.c.id {
    // Return nil - we don't support this for now
    return null;
}

fn insertText(
    self: objc.c.id,
    _: objc.c.SEL,
    text_id: objc.c.id,
    _: NSRange,
) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const str = extractString(text_id) orelse return;

    std.debug.print("insertText: \"{s}\"\n", .{str});

    // Copy to window-owned buffer before the objc call returns
    window.setInsertedText(str);
    window.clearMarkedText();
    _ = window.handleInput(.{ .text_input = .{ .text = window.inserted_text } });
}

fn characterIndexForPoint(_: objc.c.id, _: objc.c.SEL, _: NSPoint) callconv(.c) c_ulong {
    // Return 0 - we don't support click-to-position in IME candidate window
    return 0;
}

fn firstRectForCharacterRange(
    self: objc.c.id,
    _: objc.c.SEL,
    _: NSRange, // range
    _: *NSRange, // actual_range
) callconv(.c) NSRect {
    const view = objc.Object{ .value = self };
    const window = getWindow(self) orelse {
        return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    };

    // Get the view's window
    const ns_window = view.msgSend(?objc.Object, "window", .{}) orelse {
        return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    };

    // Use the IME cursor rect set by the focused TextInput
    const view_rect = window.ime_cursor_rect;

    // Convert from view coordinates to window coordinates, then to screen coordinates
    const window_rect = view.msgSend(NSRect, "convertRect:toView:", .{ view_rect, @as(?objc.c.id, null) });
    const screen_rect = ns_window.msgSend(NSRect, "convertRectToScreen:", .{window_rect});

    return screen_rect;
}

fn doCommandBySelector(self: objc.c.id, _: objc.c.SEL, selector: objc.c.SEL) callconv(.c) void {
    std.debug.print("doCommandBySelector called: {*}\n", .{selector});

    const window = getWindow(self) orelse return;

    if (window.pending_key_event) |event_id| {
        if (parseKeyEvent(event_id)) |key_event| {
            _ = window.handleInput(.{ .key_down = key_event });
        }
    }
}
