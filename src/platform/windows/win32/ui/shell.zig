//! SHIM: ui/shell.zig from the generated package.
//!
//! `ui/windows_and_messaging.zig` imports `HELPINFO` from `ui/shell.zig`;
//! the real file (35k lines) pulls in ole/urlmon/storage cascades nothing in
//! gooey's windowing uses. HELPINFO is copied verbatim from the source
//! package (`win32-25.0.28-preview`, ui/shell.zig:2886). If a compile error
//! reports another missing symbol from shell.zig, add it here with its
//! original definition rather than copying the whole file.

const HANDLE = @import("../foundation.zig").HANDLE;
const POINT = @import("../foundation.zig").POINT;

pub const HELPINFO = extern struct {
    cbSize: u32,
    iContextType: i32,
    iCtrlId: i32,
    hItemHandle: ?HANDLE,
    dwContextId: usize,
    MousePos: POINT,
};
