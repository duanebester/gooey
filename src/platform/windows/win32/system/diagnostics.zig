//! SHIM: system/diagnostics/debug.zig from the generated package.
//!
//! The vendored `zig.zig` helper references `FormatMessageA` from
//! `system/diagnostics/debug.zig`; the real file (44k lines) pulls in
//! kernel/ole/storage cascades nothing in gooey uses. `FORMAT_MESSAGE_OPTIONS`
//! and `FormatMessageA` are copied verbatim from the source package
//! (`win32-25.0.28-preview`, system/diagnostics/debug.zig:2947/:43224).

pub const FORMAT_MESSAGE_OPTIONS = packed struct(u32) {
    _0: u1 = 0,
    _1: u1 = 0,
    _2: u1 = 0,
    _3: u1 = 0,
    _4: u1 = 0,
    _5: u1 = 0,
    _6: u1 = 0,
    _7: u1 = 0,
    ALLOCATE_BUFFER: u1 = 0,
    IGNORE_INSERTS: u1 = 0,
    FROM_STRING: u1 = 0,
    FROM_HMODULE: u1 = 0,
    FROM_SYSTEM: u1 = 0,
    ARGUMENT_ARRAY: u1 = 0,
    _14: u1 = 0,
    _15: u1 = 0,
    _16: u1 = 0,
    _17: u1 = 0,
    _18: u1 = 0,
    _19: u1 = 0,
    _20: u1 = 0,
    _21: u1 = 0,
    _22: u1 = 0,
    _23: u1 = 0,
    _24: u1 = 0,
    _25: u1 = 0,
    _26: u1 = 0,
    _27: u1 = 0,
    _28: u1 = 0,
    _29: u1 = 0,
    _30: u1 = 0,
    _31: u1 = 0,
};

const PSTR = @import("../foundation.zig").PSTR;

pub extern "kernel32" fn FormatMessageA(
    dwFlags: FORMAT_MESSAGE_OPTIONS,
    lpSource: ?*const anyopaque,
    dwMessageId: u32,
    dwLanguageId: u32,
    lpBuffer: ?PSTR,
    nSize: u32,
    Arguments: ?*?*i8,
) callconv(.winapi) u32;
