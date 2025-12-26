//! AppKit/Foundation type definitions for gooey
//!
//! Clean Zig types instead of magic numbers.
//! Reference: https://developer.apple.com/documentation/appkit

const std = @import("std");

// Re-export KeyCode from core input (canonical location)
pub const KeyCode = @import("../../core/input.zig").KeyCode;

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
