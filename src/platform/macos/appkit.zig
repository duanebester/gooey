//! AppKit/Foundation type definitions for gooey
//!
//! Clean Zig types instead of magic numbers.
//! Reference: https://developer.apple.com/documentation/appkit

const std = @import("std");

// ============================================================================
// Keyboard: macOS virtual keycodes → platform-neutral KeyTag
// ============================================================================

const input_events = @import("../../input/events.zig");
pub const KeyTag = input_events.KeyTag;

/// macOS virtual keycodes (Carbon `Events.h` `kVK_*` constants). These live
/// only here, at the macOS boundary; the rest of Gooey sees only KeyTag.
pub const kvk = struct {
    pub const ANSI_A: u16 = 0x00;
    pub const ANSI_S: u16 = 0x01;
    pub const ANSI_D: u16 = 0x02;
    pub const ANSI_F: u16 = 0x03;
    pub const ANSI_H: u16 = 0x04;
    pub const ANSI_G: u16 = 0x05;
    pub const ANSI_Z: u16 = 0x06;
    pub const ANSI_X: u16 = 0x07;
    pub const ANSI_C: u16 = 0x08;
    pub const ANSI_V: u16 = 0x09;
    pub const ANSI_B: u16 = 0x0B;
    pub const ANSI_Q: u16 = 0x0C;
    pub const ANSI_W: u16 = 0x0D;
    pub const ANSI_E: u16 = 0x0E;
    pub const ANSI_R: u16 = 0x0F;
    pub const ANSI_Y: u16 = 0x10;
    pub const ANSI_T: u16 = 0x11;
    pub const ANSI_1: u16 = 0x12;
    pub const ANSI_2: u16 = 0x13;
    pub const ANSI_3: u16 = 0x14;
    pub const ANSI_4: u16 = 0x15;
    pub const ANSI_6: u16 = 0x16;
    pub const ANSI_5: u16 = 0x17;
    pub const ANSI_EQUAL: u16 = 0x18;
    pub const ANSI_9: u16 = 0x19;
    pub const ANSI_7: u16 = 0x1A;
    pub const ANSI_MINUS: u16 = 0x1B;
    pub const ANSI_8: u16 = 0x1C;
    pub const ANSI_0: u16 = 0x1D;
    pub const ANSI_RIGHT_BRACKET: u16 = 0x1E;
    pub const ANSI_O: u16 = 0x1F;
    pub const ANSI_U: u16 = 0x20;
    pub const ANSI_LEFT_BRACKET: u16 = 0x21;
    pub const ANSI_I: u16 = 0x22;
    pub const ANSI_P: u16 = 0x23;
    pub const RETURN: u16 = 0x24;
    pub const ANSI_L: u16 = 0x25;
    pub const ANSI_J: u16 = 0x26;
    pub const ANSI_QUOTE: u16 = 0x27;
    pub const ANSI_K: u16 = 0x28;
    pub const ANSI_SEMICOLON: u16 = 0x29;
    pub const ANSI_BACKSLASH: u16 = 0x2A;
    pub const ANSI_COMMA: u16 = 0x2B;
    pub const ANSI_SLASH: u16 = 0x2C;
    pub const ANSI_N: u16 = 0x2D;
    pub const ANSI_M: u16 = 0x2E;
    pub const ANSI_PERIOD: u16 = 0x2F;
    pub const TAB: u16 = 0x30;
    pub const SPACE: u16 = 0x31;
    pub const ANSI_GRAVE: u16 = 0x32;
    pub const DELETE: u16 = 0x33;
    pub const ESCAPE: u16 = 0x35;
    pub const COMMAND: u16 = 0x37;
    pub const SHIFT: u16 = 0x38;
    pub const CAPS_LOCK: u16 = 0x39;
    pub const OPTION: u16 = 0x3A;
    pub const CONTROL: u16 = 0x3B;
    pub const RIGHT_COMMAND: u16 = 0x36;
    pub const RIGHT_SHIFT: u16 = 0x3C;
    pub const RIGHT_OPTION: u16 = 0x3D;
    pub const RIGHT_CONTROL: u16 = 0x3E;
    pub const F17: u16 = 0x40;
    pub const ANSI_KEYPAD_DECIMAL: u16 = 0x41;
    pub const F18: u16 = 0x4F;
    pub const ANSI_KEYPAD_MULTIPLY: u16 = 0x43;
    pub const F19: u16 = 0x50;
    pub const ANSI_KEYPAD_PLUS: u16 = 0x45;
    pub const ANSI_KEYPAD_CLEAR: u16 = 0x47;
    pub const VOLUME_UP: u16 = 0x48;
    pub const VOLUME_DOWN: u16 = 0x49;
    pub const MUTE: u16 = 0x4A;
    pub const ANSI_KEYPAD_DIVIDE: u16 = 0x4B;
    pub const ANSI_KEYPAD_ENTER: u16 = 0x4C;
    pub const ANSI_KEYPAD_MINUS: u16 = 0x4E;
    pub const F20: u16 = 0x5A;
    pub const ANSI_KEYPAD_EQUALS: u16 = 0x51;
    pub const ANSI_KEYPAD_0: u16 = 0x52;
    pub const ANSI_KEYPAD_1: u16 = 0x53;
    pub const ANSI_KEYPAD_2: u16 = 0x54;
    pub const ANSI_KEYPAD_3: u16 = 0x55;
    pub const ANSI_KEYPAD_4: u16 = 0x56;
    pub const ANSI_KEYPAD_5: u16 = 0x57;
    pub const ANSI_KEYPAD_6: u16 = 0x58;
    pub const ANSI_KEYPAD_7: u16 = 0x59;
    pub const ANSI_KEYPAD_8: u16 = 0x5B;
    pub const ANSI_KEYPAD_9: u16 = 0x5C;
    pub const F5: u16 = 0x60;
    pub const F6: u16 = 0x61;
    pub const F7: u16 = 0x62;
    pub const F3: u16 = 0x63;
    pub const F8: u16 = 0x64;
    pub const F9: u16 = 0x65;
    pub const F11: u16 = 0x67;
    pub const F13: u16 = 0x69;
    pub const F14: u16 = 0x6B;
    pub const F10: u16 = 0x6D;
    pub const F12: u16 = 0x6F;
    pub const F15: u16 = 0x71;
    pub const HELP: u16 = 0x72;
    pub const HOME: u16 = 0x73;
    pub const PAGE_UP: u16 = 0x74;
    pub const FORWARD_DELETE: u16 = 0x75;
    pub const F4: u16 = 0x76;
    pub const END: u16 = 0x77;
    pub const F2: u16 = 0x78;
    pub const PAGE_DOWN: u16 = 0x79;
    pub const F1: u16 = 0x7A;
    pub const LEFT_ARROW: u16 = 0x7B;
    pub const RIGHT_ARROW: u16 = 0x7C;
    pub const DOWN_ARROW: u16 = 0x7D;
    pub const UP_ARROW: u16 = 0x7E;
};

/// Translate a macOS virtual keycode (`NSEvent.keyCode`, i.e. `kVK_*`) to the
/// platform-neutral KeyTag. Codes with no US ANSI/extended-name counterpart
/// (ISO section, JIS keys, media keys) become `.unknown`.
pub fn keyTagFromVirtualKey(code: u16) KeyTag {
    return switch (code) {
        kvk.ANSI_A => .a,
        kvk.ANSI_S => .s,
        kvk.ANSI_D => .d,
        kvk.ANSI_F => .f,
        kvk.ANSI_H => .h,
        kvk.ANSI_G => .g,
        kvk.ANSI_Z => .z,
        kvk.ANSI_X => .x,
        kvk.ANSI_C => .c,
        kvk.ANSI_V => .v,
        kvk.ANSI_B => .b,
        kvk.ANSI_Q => .q,
        kvk.ANSI_W => .w,
        kvk.ANSI_E => .e,
        kvk.ANSI_R => .r,
        kvk.ANSI_Y => .y,
        kvk.ANSI_T => .t,
        kvk.ANSI_1 => .@"1",
        kvk.ANSI_2 => .@"2",
        kvk.ANSI_3 => .@"3",
        kvk.ANSI_4 => .@"4",
        kvk.ANSI_6 => .@"6",
        kvk.ANSI_5 => .@"5",
        kvk.ANSI_EQUAL => .equal,
        kvk.ANSI_9 => .@"9",
        kvk.ANSI_7 => .@"7",
        kvk.ANSI_MINUS => .minus,
        kvk.ANSI_8 => .@"8",
        kvk.ANSI_0 => .@"0",
        kvk.ANSI_RIGHT_BRACKET => .right_bracket,
        kvk.ANSI_O => .o,
        kvk.ANSI_U => .u,
        kvk.ANSI_LEFT_BRACKET => .left_bracket,
        kvk.ANSI_I => .i,
        kvk.ANSI_P => .p,
        kvk.RETURN => .@"return",
        kvk.ANSI_L => .l,
        kvk.ANSI_J => .j,
        kvk.ANSI_QUOTE => .quote,
        kvk.ANSI_K => .k,
        kvk.ANSI_SEMICOLON => .semicolon,
        kvk.ANSI_BACKSLASH => .backslash,
        kvk.ANSI_COMMA => .comma,
        kvk.ANSI_SLASH => .slash,
        kvk.ANSI_N => .n,
        kvk.ANSI_M => .m,
        kvk.ANSI_PERIOD => .period,
        kvk.TAB => .tab,
        kvk.SPACE => .space,
        kvk.ANSI_GRAVE => .grave,
        kvk.DELETE => .backspace,
        kvk.ESCAPE => .escape,
        kvk.COMMAND, kvk.RIGHT_COMMAND => .super,
        kvk.SHIFT, kvk.RIGHT_SHIFT => .shift,
        kvk.CAPS_LOCK => .caps_lock,
        kvk.OPTION, kvk.RIGHT_OPTION => .alt,
        kvk.CONTROL, kvk.RIGHT_CONTROL => .control,
        kvk.ANSI_KEYPAD_DECIMAL => .keypad_decimal,
        kvk.ANSI_KEYPAD_MULTIPLY => .keypad_multiply,
        kvk.ANSI_KEYPAD_PLUS => .keypad_plus,
        kvk.ANSI_KEYPAD_CLEAR => .keypad_clear,
        kvk.ANSI_KEYPAD_DIVIDE => .keypad_divide,
        kvk.ANSI_KEYPAD_ENTER => .keypad_enter,
        kvk.ANSI_KEYPAD_MINUS => .keypad_minus,
        kvk.ANSI_KEYPAD_EQUALS => .keypad_equals,
        kvk.ANSI_KEYPAD_0 => .keypad_0,
        kvk.ANSI_KEYPAD_1 => .keypad_1,
        kvk.ANSI_KEYPAD_2 => .keypad_2,
        kvk.ANSI_KEYPAD_3 => .keypad_3,
        kvk.ANSI_KEYPAD_4 => .keypad_4,
        kvk.ANSI_KEYPAD_5 => .keypad_5,
        kvk.ANSI_KEYPAD_6 => .keypad_6,
        kvk.ANSI_KEYPAD_7 => .keypad_7,
        kvk.ANSI_KEYPAD_8 => .keypad_8,
        kvk.ANSI_KEYPAD_9 => .keypad_9,
        kvk.F5 => .f5,
        kvk.F6 => .f6,
        kvk.F7 => .f7,
        kvk.F3 => .f3,
        kvk.F8 => .f8,
        kvk.F9 => .f9,
        kvk.F11 => .f11,
        kvk.F13 => .f13,
        kvk.F14 => .f14,
        kvk.F10 => .f10,
        kvk.F12 => .f12,
        kvk.F15 => .f15,
        kvk.F17 => .f17,
        kvk.F18 => .f18,
        kvk.F19 => .f19,
        kvk.F20 => .f20,
        kvk.HOME => .home,
        kvk.PAGE_UP => .page_up,
        kvk.FORWARD_DELETE => .delete,
        kvk.END => .end,
        kvk.F2 => .f2,
        kvk.PAGE_DOWN => .page_down,
        kvk.F1 => .f1,
        kvk.F4 => .f4,
        kvk.LEFT_ARROW => .left,
        kvk.RIGHT_ARROW => .right,
        kvk.DOWN_ARROW => .down,
        kvk.UP_ARROW => .up,
        else => .unknown,
    };
}

test "kVK resolves to platform-neutral key tags" {
    const testing = std.testing;

    // Writing keys, one per historical group.
    try testing.expectEqual(KeyTag.a, keyTagFromVirtualKey(kvk.ANSI_A));
    try testing.expectEqual(KeyTag.z, keyTagFromVirtualKey(kvk.ANSI_Z));
    try testing.expectEqual(KeyTag.@"5", keyTagFromVirtualKey(kvk.ANSI_5));
    try testing.expectEqual(KeyTag.@"return", keyTagFromVirtualKey(kvk.RETURN));

    // Punctuation (kVK_ANSI_*).
    try testing.expectEqual(KeyTag.minus, keyTagFromVirtualKey(kvk.ANSI_MINUS));
    try testing.expectEqual(KeyTag.left_bracket, keyTagFromVirtualKey(kvk.ANSI_LEFT_BRACKET));
    try testing.expectEqual(KeyTag.grave, keyTagFromVirtualKey(kvk.ANSI_GRAVE));

    // Backspace and Delete are distinct keys with PC names.
    try testing.expectEqual(KeyTag.backspace, keyTagFromVirtualKey(kvk.DELETE));
    try testing.expectEqual(KeyTag.delete, keyTagFromVirtualKey(kvk.FORWARD_DELETE));

    // Keypad. KeypadEnter produces no printable text, so collapsing it to
    // `.unknown` would drop the keystroke.
    try testing.expectEqual(KeyTag.keypad_enter, keyTagFromVirtualKey(kvk.ANSI_KEYPAD_ENTER));
    try testing.expectEqual(KeyTag.keypad_0, keyTagFromVirtualKey(kvk.ANSI_KEYPAD_0));
    try testing.expectEqual(KeyTag.keypad_9, keyTagFromVirtualKey(kvk.ANSI_KEYPAD_9));
    try testing.expectEqual(KeyTag.keypad_clear, keyTagFromVirtualKey(kvk.ANSI_KEYPAD_CLEAR));

    // Extended function keys.
    try testing.expectEqual(KeyTag.f13, keyTagFromVirtualKey(kvk.F13));
    try testing.expectEqual(KeyTag.f20, keyTagFromVirtualKey(kvk.F20));

    // Neutral modifier naming: Option → .alt, Command → .super.
    try testing.expectEqual(KeyTag.alt, keyTagFromVirtualKey(kvk.OPTION));
    try testing.expectEqual(KeyTag.super, keyTagFromVirtualKey(kvk.COMMAND));
    try testing.expectEqual(KeyTag.right_alt, keyTagFromVirtualKey(kvk.RIGHT_OPTION));
    try testing.expectEqual(KeyTag.right_super, keyTagFromVirtualKey(kvk.RIGHT_COMMAND));

    // Negative space: codes with no name collapse to `.unknown`.
    try testing.expectEqual(KeyTag.unknown, keyTagFromVirtualKey(0x42)); // gap in kVK table
    try testing.expectEqual(KeyTag.unknown, keyTagFromVirtualKey(0xFFFF));
}

// ============================================================================
// Geometry Types
// ============================================================================

/// https://developer.apple.com/documentation/foundation/nspoint
pub const NSPoint = extern struct {
    x: f64,
    y: f64,
};

/// https://developer.apple.com/documentation/foundation/nssize
pub const NSSize = extern struct {
    width: f64,
    height: f64,
};

/// https://developer.apple.com/documentation/foundation/nsrect
pub const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

// ============================================================================
// Event Modifier Flags
// ============================================================================

/// https://developer.apple.com/documentation/appkit/nseventmodifierflags
pub const NSEventModifierFlags = packed struct(c_ulong) {
    _reserved0: u16 = 0,
    caps_lock: bool = false, // 1 << 16
    shift: bool = false, // 1 << 17
    control: bool = false, // 1 << 18
    option: bool = false, // 1 << 19
    command: bool = false, // 1 << 20
    _reserved1: u43 = 0,

    pub fn from(flags: c_ulong) NSEventModifierFlags {
        return @bitCast(flags);
    }
};

// ============================================================================
// Tracking Area Options
// ============================================================================

/// https://developer.apple.com/documentation/appkit/nstrackingarea/options
pub const NSTrackingAreaOptions = struct {
    // Events to track
    pub const mouse_entered_and_exited: c_ulong = 0x01;
    pub const mouse_moved: c_ulong = 0x02;
    pub const cursor_update: c_ulong = 0x04;

    // When active
    pub const active_when_first_responder: c_ulong = 0x10;
    pub const active_in_key_window: c_ulong = 0x20;
    pub const active_in_active_app: c_ulong = 0x40;
    pub const active_always: c_ulong = 0x80;

    // Behavior
    pub const assume_inside: c_ulong = 0x100;
    pub const in_visible_rect: c_ulong = 0x200;
    pub const enabled_during_mouse_drag: c_ulong = 0x400;
};

// ============================================================================
// NSRange (for NSTextInputClient)
// ============================================================================

/// https://developer.apple.com/documentation/foundation/nsrange
/// Note: NSUInteger is `unsigned long` on macOS, which is `c_ulong` in Zig.
/// We must use c_ulong (not usize) for Objective-C runtime compatibility.
pub const NSRange = extern struct {
    location: c_ulong,
    length: c_ulong,

    pub const NotFound: c_ulong = std.math.maxInt(c_ulong);

    pub fn invalid() NSRange {
        return .{ .location = NotFound, .length = 0 };
    }

    pub fn isEmpty(self: NSRange) bool {
        return self.length == 0;
    }
};

// ============================================================================
// NSPanel / Modal Response
// ============================================================================

/// https://developer.apple.com/documentation/appkit/nsapplication/modalresponse
pub const NSModalResponse = enum(isize) {
    OK = 1, // NSModalResponseOK
    Cancel = 0, // NSModalResponseCancel
};
