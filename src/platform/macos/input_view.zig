const std = @import("std");
const assert = std.debug.assert;
const objc = @import("objc");
const input = @import("../../input/events.zig");
const geometry = @import("../../geometry/geometry.zig");
const appkit = @import("appkit.zig");
const Window = @import("window.zig").Window;
const CoreBinding = @import("window.zig").CoreBinding;
const core_events = @import("../../core/events.zig");
const limits = @import("../../core/limits.zig");
const mac_bridge = @import("../../accessibility/mac_bridge.zig");

const NSRect = appkit.NSRect;
const NSPoint = appkit.NSPoint;
const NSRange = appkit.NSRange;
const NSEventModifierFlags = appkit.NSEventModifierFlags;

var view_class: ?objc.Class = null;

pub fn registerClass() !void {
    if (view_class != null) return;

    const NSView = objc.getClass("NSView") orelse return error.ClassNotFound;

    var cls = objc.allocateClassPair(NSView, "GooeyMetalView") orelse
        return error.ClassAllocationFailed;

    if (!cls.addIvar("_gooeyWindow")) {
        return error.IvarAddFailed;
    }

    if (!cls.addIvar(mac_bridge.focus_ivar)) {
        return error.IvarAddFailed;
    }

    const NSTextInputClient = objc.getProtocol("NSTextInputClient") orelse
        return error.ProtocolNotFound;
    if (objc.c.class_addProtocol(cls.value, NSTextInputClient.value) == 0) {
        return error.ProtocolAddFailed;
    }

    if (!cls.addMethod("acceptsFirstResponder", acceptsFirstResponder)) return error.MethodAddFailed;
    if (!cls.addMethod("isFlipped", isFlipped)) return error.MethodAddFailed;
    if (!cls.addMethod("acceptsFirstMouse:", acceptsFirstMouse)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseDownCanMoveWindow", mouseDownCanMoveWindow)) {
        return error.MethodAddFailed;
    }

    if (!cls.addMethod("keyDown:", keyDown)) return error.MethodAddFailed;
    if (!cls.addMethod("keyUp:", keyUp)) return error.MethodAddFailed;
    if (!cls.addMethod("flagsChanged:", flagsChanged)) return error.MethodAddFailed;

    if (!cls.addMethod("mouseDown:", mouseDown)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseUp:", mouseUp)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseMoved:", mouseMoved)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseDragged:", mouseDragged)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseEntered:", mouseEntered)) return error.MethodAddFailed;
    if (!cls.addMethod("mouseExited:", mouseExited)) return error.MethodAddFailed;
    if (!cls.addMethod("rightMouseDown:", rightMouseDown)) return error.MethodAddFailed;
    if (!cls.addMethod("rightMouseUp:", rightMouseUp)) return error.MethodAddFailed;
    if (!cls.addMethod("rightMouseDragged:", rightMouseDragged)) return error.MethodAddFailed;
    if (!cls.addMethod("scrollWheel:", scrollWheel)) return error.MethodAddFailed;

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
    if (!cls.addMethod("accessibilityFocusedUIElement", accessibilityFocusedUIElement)) {
        return error.MethodAddFailed;
    }

    objc.registerClassPair(cls);
    view_class = cls;
}

pub fn create(frame: NSRect, window: *Window) !objc.Object {
    if (view_class == null) {
        try registerClass();
    }

    const view = view_class.?.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithFrame:", .{frame});

    const window_obj = objc.Object.fromId(@as(objc.c.id, @ptrCast(window)));
    view.setInstanceVariable("_gooeyWindow", window_obj);

    return view;
}

inline fn getWindow(self: objc.c.id) ?*Window {
    const view = objc.Object.fromId(self);
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
    const view = objc.Object.fromId(self);
    const event = objc.Object.fromId(event_id);

    const window_loc: NSPoint = event.msgSend(NSPoint, "locationInWindow", .{});
    const view_loc: NSPoint = view.msgSend(NSPoint, "convertPoint:fromView:", .{ window_loc, @as(objc.c.id, @ptrFromInt(0)) });

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
    const view = objc.Object.fromId(self_id);
    const event = objc.Object.fromId(event_id);

    const window_loc: NSPoint = event.msgSend(NSPoint, "locationInWindow", .{});
    const view_loc: NSPoint = view.msgSend(NSPoint, "convertPoint:fromView:", .{ window_loc, @as(objc.c.id, @ptrFromInt(0)) });
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});

    return .{
        .position = geometry.Point(f64).init(view_loc.x, view_loc.y),
        .button = .left,
        .click_count = 0,
        .modifiers = parseModifiers(modifier_flags),
    };
}

fn extractString(text_id: objc.c.id) ?[]const u8 {
    const text = objc.Object.fromId(text_id);

    const NSAttributedString = objc.getClass("NSAttributedString") orelse return null;
    const is_attributed = text.msgSend(bool, "isKindOfClass:", .{NSAttributedString.value});

    const ns_string = if (is_attributed)
        text.msgSend(objc.Object, "string", .{})
    else
        text;

    const cstr = ns_string.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
    return std.mem.span(cstr);
}

fn acceptsFirstResponder(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

fn isFlipped(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return true;
}

fn acceptsFirstMouse(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) bool {
    const window = getWindow(self) orelse return false;
    if (event == null) return false;
    const mouse = parseMouseEvent(self, event, .mouse_down).mouse_down;
    return window.titleStripTakesPress(mouse.position);
}

fn mouseDownCanMoveWindow(_: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    return false;
}

fn mouseDown(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    if (window.hasMarkedText()) {
        const context = objc.Object.fromId(self).msgSend(objc.c.id, "inputContext", .{});
        if (context != null) {
            _ = objc.Object.fromId(context).msgSend(bool, "handleEvent:", .{event});
        }
    }
    const press = parseMouseEvent(self, event, .mouse_down);
    if (!window.handleInput(press)) window.pressTitleBar(event, press.mouse_down);
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

fn rightMouseDragged(self: objc.c.id, _: objc.c.SEL, event: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    _ = window.handleInput(parseMouseEvent(self, event, .mouse_dragged));
}

fn scrollWheel(self: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const view = objc.Object.fromId(self);
    const event = objc.Object.fromId(event_id);

    const window_loc: NSPoint = event.msgSend(NSPoint, "locationInWindow", .{});
    const view_loc: NSPoint = view.msgSend(NSPoint, "convertPoint:fromView:", .{ window_loc, @as(objc.c.id, @ptrFromInt(0)) });

    const delta = scrollDelta(
        event.msgSend(f64, "scrollingDeltaX", .{}),
        event.msgSend(f64, "scrollingDeltaY", .{}),
        event.msgSend(bool, "hasPreciseScrollingDeltas", .{}),
    );
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});

    _ = window.handleInput(.{ .scroll = .{
        .position = geometry.Point(f64).init(view_loc.x, view_loc.y),
        .delta = delta,
        .modifiers = parseModifiers(modifier_flags),
    } });
}

const wheel_line_points: f64 = 10;

fn scrollDelta(delta_x: f64, delta_y: f64, precise: bool) geometry.Point(f64) {
    const scale: f64 = if (precise) 1 else wheel_line_points;
    return geometry.Point(f64).init(delta_x * scale, delta_y * scale);
}

test "scrollDelta scales wheel lines to points and passes precise deltas through" {
    const wheel = scrollDelta(-3, 1.5, false);
    try std.testing.expectEqual(@as(f64, -30), wheel.x);
    try std.testing.expectEqual(@as(f64, 15), wheel.y);
    const precise = scrollDelta(-3, 1.5, true);
    try std.testing.expectEqual(@as(f64, -3), precise.x);
    try std.testing.expectEqual(@as(f64, 1.5), precise.y);
}

fn keyDown(self: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const view = objc.Object.fromId(self);

    if (parseKeyEvent(event_id)) |key_event| {
        const handled = window.handleInput(.{ .key_down = key_event });

        if (handled) {
            return;
        }
    }

    const NSArray = objc.getClass("NSArray") orelse return;
    const event_array = NSArray.msgSend(objc.Object, "arrayWithObject:", .{event_id});
    view.msgSend(void, "interpretKeyEvents:", .{event_array.value});
}

fn keyUp(self: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const event = objc.Object.fromId(event_id);

    const key_code = event.msgSend(u16, "keyCode", .{});
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const is_repeat = event.msgSend(bool, "isARepeat", .{});

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
    const ns_event = objc.Object.fromId(event);
    const modifier_flags = ns_event.msgSend(c_ulong, "modifierFlags", .{});
    _ = window.handleInput(.{ .modifiers_changed = parseModifiers(modifier_flags) });
}

fn parseKeyEvent(event_id: objc.c.id) ?input.KeyEvent {
    const event = objc.Object.fromId(event_id);

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
    const ns_string_id: objc.c.id = event.msgSend(objc.c.id, "characters", .{});
    if (ns_string_id == null) return null;

    const ns_string = objc.Object.fromId(ns_string_id);
    const length: c_ulong = ns_string.msgSend(c_ulong, "length", .{});
    if (length == 0) return null;

    const cstr: ?[*:0]const u8 = ns_string.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (cstr == null) return null;

    return std.mem.span(cstr.?);
}

fn getCharactersIgnoringModifiers(event: objc.Object) ?[]const u8 {
    const ns_string_id: objc.c.id = event.msgSend(objc.c.id, "charactersIgnoringModifiers", .{});
    if (ns_string_id == null) return null;

    const ns_string = objc.Object.fromId(ns_string_id);
    const length: c_ulong = ns_string.msgSend(c_ulong, "length", .{});
    if (length == 0) return null;

    const cstr: ?[*:0]const u8 = ns_string.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (cstr == null) return null;

    return std.mem.span(cstr.?);
}

fn accessibilityFocusedUIElement(self: objc.c.id, _: objc.c.SEL) callconv(.c) objc.c.id {
    std.debug.assert(self != null);
    const focus = objc.Object.fromId(self).getInstanceVariable(mac_bridge.focus_ivar);
    if (focus.value != null) return focus.value;
    return NSAccessibilityUnignoredAncestor(self);
}

extern "c" fn NSAccessibilityUnignoredAncestor(element: objc.c.id) objc.c.id;

fn hasMarkedText(self: objc.c.id, _: objc.c.SEL) callconv(.c) bool {
    const window = getWindow(self) orelse return false;
    return window.marked_length_utf16 > 0;
}

fn markedRange(self: objc.c.id, _: objc.c.SEL) callconv(.c) NSRange {
    const window = getWindow(self) orelse return NSRange.invalid();
    if (window.marked_length_utf16 == 0) return NSRange.invalid();
    return .{ .location = 0, .length = window.marked_length_utf16 };
}

fn selectedRange(self: objc.c.id, _: objc.c.SEL) callconv(.c) NSRange {
    const window = getWindow(self) orelse return .{ .location = 0, .length = 0 };
    const selection = window.marked_selection;
    assert(selection.location <= window.marked_length_utf16);
    assert(selection.length <= window.marked_length_utf16 - selection.location);
    return selection;
}

fn performKeyEquivalent(self: objc.c.id, _: objc.c.SEL, event_id: objc.c.id) callconv(.c) bool {
    const window = getWindow(self) orelse return false;
    const event = objc.Object.fromId(event_id);

    const key_code = event.msgSend(u16, "keyCode", .{});
    const modifier_flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const mods = parseModifiers(modifier_flags);

    if (mods.cmd) {
        const key_event = input.KeyEvent{
            .key = input.KeyCode.from(key_code),
            .modifiers = mods,
            .characters = null,
            .characters_ignoring_modifiers = null,
            .is_repeat = false,
        };

        const binding = window.core orelse return false;
        if (!binding.query.keymapClaims(key_event)) return false;
        if (window.handleInput(.{ .key_down = key_event })) {
            return true;
        }
    }

    return false;
}

fn setMarkedText(
    self: objc.c.id,
    _: objc.c.SEL,
    text_id: objc.c.id,
    selected: NSRange,
    _: NSRange,
) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const str = extractString(text_id) orelse "";
    const length_utf16 = objc.Object.fromId(text_id).msgSend(c_ulong, "length", .{});

    window.setMarkedText(str);
    window.marked_length_utf16 = length_utf16;
    window.marked_selection = clampRange(selected, length_utf16);
    _ = window.handleInput(.{ .composition = .{ .text = window.marked_text } });
}

fn clampRange(range: NSRange, length: c_ulong) NSRange {
    const location = @min(range.location, length);
    const result = NSRange{ .location = location, .length = @min(range.length, length - location) };
    assert(result.location + result.length <= length);
    return result;
}

fn unmarkText(self: objc.c.id, _: objc.c.SEL) callconv(.c) void {
    const window = getWindow(self) orelse return;
    window.clearMarkedText();
    _ = window.handleInput(.{ .composition = .{
        .text = "",
    } });
}

fn validAttributesForMarkedText(_: objc.c.id, _: objc.c.SEL) callconv(.c) objc.c.id {
    const NSArray = objc.getClass("NSArray") orelse return null;
    return NSArray.msgSend(objc.c.id, "array", .{});
}

fn attributedSubstring(
    self: objc.c.id,
    _: objc.c.SEL,
    range: NSRange,
    actual_range: ?*NSRange,
) callconv(.c) objc.c.id {
    const window = getWindow(self) orelse return null;
    const length = window.marked_length_utf16;
    if (length == 0) return null;
    if (range.location >= length) return null;
    const clamped = clampRange(range, length);
    const NSString = objc.getClass("NSString") orelse return null;
    const NSAttributedString = objc.getClass("NSAttributedString") orelse return null;
    assert(window.marked_text.ptr == window.marked_text_buffer.ptr);
    assert(window.marked_text_buffer[window.marked_text.len] == 0);
    const string = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{
        @as([*:0]const u8, @ptrCast(window.marked_text_buffer.ptr)),
    });
    if (string.value == null) return null;
    const stored = string.msgSend(c_ulong, "length", .{});
    if (clamped.location + clamped.length > stored) return null;
    const attributed = NSAttributedString.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithString:", .{string.value});
    defer attributed.release();
    if (actual_range) |actual| actual.* = clamped;
    return attributed.msgSend(objc.c.id, "attributedSubstringFromRange:", .{clamped});
}

fn insertText(
    self: objc.c.id,
    _: objc.c.SEL,
    text_id: objc.c.id,
    _: NSRange,
) callconv(.c) void {
    const window = getWindow(self) orelse return;
    const str = extractString(text_id) orelse return;

    window.clearMarkedText();
    _ = window.handleInput(.{ .text_input = .{ .text = str } });
}

fn characterIndexForPoint(_: objc.c.id, _: objc.c.SEL, _: NSPoint) callconv(.c) c_ulong {
    return ns_not_found;
}

const ns_not_found: c_ulong = std.math.maxInt(c_long);

fn firstRectForCharacterRange(
    self: objc.c.id,
    _: objc.c.SEL,
    _: NSRange,
    actual_range: ?*NSRange,
) callconv(.c) NSRect {
    const view = objc.Object.fromId(self);
    const window = getWindow(self) orelse {
        return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    };

    const ns_window_id: objc.c.id = view.msgSend(objc.c.id, "window", .{});
    if (ns_window_id == null) {
        return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    }
    const ns_window = objc.Object.fromId(ns_window_id);

    const binding = window.core orelse {
        return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    };
    const view_rect = coreImeRect(binding);
    const caret_utf16 = window.rendered_marked_length_utf16;
    if (actual_range) |actual| actual.* = .{ .location = caret_utf16, .length = 0 };

    const window_rect = view.msgSend(NSRect, "convertRect:toView:", .{ view_rect, @as(objc.c.id, @ptrFromInt(0)) });
    const screen_rect = ns_window.msgSend(NSRect, "convertRectToScreen:", .{window_rect});

    return screen_rect;
}

fn coreImeRect(binding: CoreBinding) NSRect {
    const rect = binding.query.imeCursorRect() orelse {
        return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1, .height = 20 } };
    };
    assert(rect.width >= 0);
    assert(rect.height >= 0);
    return .{
        .origin = .{ .x = rect.x, .y = rect.y },
        .size = .{ .width = rect.width, .height = rect.height },
    };
}

fn doCommandBySelector(_: objc.c.id, _: objc.c.SEL, _: objc.c.SEL) callconv(.c) void {}

fn testNoTick(_: *anyopaque) void {}

test "insertText delivers long text whole and setMarkedText cuts it at a codepoint" {
    var queue: core_events.EventQueue = undefined;
    try queue.initInPlace(std.testing.allocator, .{
        .event_count_max = 4,
        .text_bytes_max = 1024,
        .dialog_count_max = 1,
        .dialog_path_bytes_max = 8,
    });
    defer queue.deinit(std.testing.allocator);
    var window: Window = undefined;
    var context: u8 = 0;
    window.core = .{
        .queue = &queue,
        .query = undefined,
        .context = &context,
        .schedule_tick = testNoTick,
    };
    var marked_buffer: [limits.TextLimits.small.preedit_bytes_max + 1]u8 = undefined;
    window.marked_text_buffer = &marked_buffer;
    window.clearMarkedText();
    const frame = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 100, .height = 100 } };
    const view = try create(frame, &window);
    defer view.release();

    const filler: [255]u8 = @splat('a');
    const long: [:0]const u8 = filler ++ "東京";
    const NSString = objc.getClass("NSString").?;
    const string = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{
        long.ptr,
    });
    const none = NSRange{ .location = 0, .length = 0 };
    view.msgSend(void, "insertText:replacementRange:", .{ string.value, none });
    try std.testing.expectEqualStrings(long, queue.pending()[0].input.text_input.text);

    view.msgSend(void, "setMarkedText:selectedRange:replacementRange:", .{
        string.value,
        none,
        none,
    });
    const marked = queue.pending()[1].input.composition.text;
    try std.testing.expectEqualStrings(&filler, marked);
    try std.testing.expectEqualStrings(marked, window.marked_text);
}
