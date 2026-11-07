//! SHIM: security.zig from the generated package.
//!
//! `system/threading.zig` imports `SECURITY_ATTRIBUTES` and
//! `TOKEN_ACCESS_MASK` from `security.zig`; the real file pulls in dozens of
//! security submodules nothing in gooey uses. Definitions copied verbatim
//! from the source package (`win32-25.0.28-preview`, security.zig).

const BOOL = @import("foundation.zig").BOOL;

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

pub const TOKEN_ACCESS_MASK = packed struct(u32) {
    ASSIGN_PRIMARY: u1 = 0,
    DUPLICATE: u1 = 0,
    IMPERSONATE: u1 = 0,
    QUERY: u1 = 0,
    QUERY_SOURCE: u1 = 0,
    ADJUST_PRIVILEGES: u1 = 0,
    ADJUST_GROUPS: u1 = 0,
    ADJUST_DEFAULT: u1 = 0,
    ADJUST_SESSIONID: u1 = 0,
    _9: u1 = 0,
    _10: u1 = 0,
    _11: u1 = 0,
    _12: u1 = 0,
    _13: u1 = 0,
    _14: u1 = 0,
    _15: u1 = 0,
    DELETE: u1 = 0,
    READ_CONTROL: u1 = 0,
    WRITE_DAC: u1 = 0,
    WRITE_OWNER: u1 = 0,
    _20: u1 = 0,
    _21: u1 = 0,
    _22: u1 = 0,
    _23: u1 = 0,
    ACCESS_SYSTEM_SECURITY: u1 = 0,
    _25: u1 = 0,
    _26: u1 = 0,
    _27: u1 = 0,
    _28: u1 = 0,
    _29: u1 = 0,
    _30: u1 = 0,
    _31: u1 = 0,
};
