//! AppKit/Foundation type definitions for gooey
//!
//! Clean Zig types instead of magic numbers.
//! Reference: https://developer.apple.com/documentation/appkit

const std = @import("std");

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
// Key Codes
// ============================================================================

/// https://developer.apple.com/documentation/carbon/kVK_ANSI_A (and friends)
/// Virtual key codes for macOS keyboard events
pub const KeyCode = enum(u16) {
    // Letters
    a = 0x00,
    s = 0x01,
    d = 0x02,
    f = 0x03,
    h = 0x04,
    g = 0x05,
    z = 0x06,
    x = 0x07,
    c = 0x08,
    v = 0x09,
    b = 0x0B,
    q = 0x0C,
    w = 0x0D,
    e = 0x0E,
    r = 0x0F,
    y = 0x10,
    t = 0x11,
    o = 0x1F,
    u = 0x20,
    i = 0x22,
    p = 0x23,
    l = 0x25,
    j = 0x26,
    k = 0x28,
    n = 0x2D,
    m = 0x2E,

    // Numbers
    @"1" = 0x12,
    @"2" = 0x13,
    @"3" = 0x14,
    @"4" = 0x15,
    @"5" = 0x17,
    @"6" = 0x16,
    @"7" = 0x1A,
    @"8" = 0x1C,
    @"9" = 0x19,
    @"0" = 0x1D,

    // Special
    @"return" = 0x24,
    tab = 0x30,
    space = 0x31,
    delete = 0x33,
    escape = 0x35,
    forward_delete = 0x75,

    // Modifiers
    command = 0x37,
    shift = 0x38,
    caps_lock = 0x39,
    option = 0x3A,
    control = 0x3B,
    right_command = 0x36,
    right_shift = 0x3C,
    right_option = 0x3D,
    right_control = 0x3E,

    // Arrows
    left = 0x7B,
    right = 0x7C,
    down = 0x7D,
    up = 0x7E,

    // Function keys
    f1 = 0x7A,
    f2 = 0x78,
    f3 = 0x63,
    f4 = 0x76,
    f5 = 0x60,
    f6 = 0x61,
    f7 = 0x62,
    f8 = 0x64,
    f9 = 0x65,
    f10 = 0x6D,
    f11 = 0x67,
    f12 = 0x6F,

    // Navigation
    home = 0x73,
    end = 0x77,
    page_up = 0x74,
    page_down = 0x79,

    unknown = 0xFFFF,
    _,

    pub fn from(code: u16) KeyCode {
        // intToEnum doesn't error for non-exhaustive enums with unnamed values,
        // so we need to check if we got a named variant
        const result = std.meta.intToEnum(KeyCode, code) catch return .unknown;
        // Check if it's actually a named variant
        if (std.enums.tagName(KeyCode, result) == null) return .unknown;
        return result;
    }
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
