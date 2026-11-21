const std = @import("std");

pub const KeyCode = @import("../../input/events.zig").KeyCode;

pub const NSPoint = extern struct {
    x: f64,
    y: f64,
};

pub const NSSize = extern struct {
    width: f64,
    height: f64,
};

pub const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

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

pub const NSTrackingAreaOptions = struct {
    pub const mouse_entered_and_exited: c_ulong = 0x01;
    pub const mouse_moved: c_ulong = 0x02;
    pub const cursor_update: c_ulong = 0x04;
    pub const active_when_first_responder: c_ulong = 0x10;
    pub const active_in_key_window: c_ulong = 0x20;
    pub const active_in_active_app: c_ulong = 0x40;
    pub const active_always: c_ulong = 0x80;
    pub const assume_inside: c_ulong = 0x100;
    pub const in_visible_rect: c_ulong = 0x200;
    pub const enabled_during_mouse_drag: c_ulong = 0x400;
};

/// NSUInteger is `c_ulong`, not `usize`, for Objective-C runtime
/// compatibility.
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

pub const NSModalResponse = enum(isize) {
    OK = 1, // NSModalResponseOK
    Cancel = 0, // NSModalResponseCancel
};
