//! SHIM: ui/controls.zig from the generated package.
//!
//! `graphics/dwm.zig` imports MARGINS from `ui/controls.zig`; the real file
//! pulls in dialogs/rich_edit/input cascades nothing in gooey uses.
//! Definition copied verbatim from the source package
//! (`win32-25.0.28-preview`, ui/controls.zig:6579).

pub const MARGINS = extern struct {
    cxLeftWidth: i32,
    cxRightWidth: i32,
    cyTopHeight: i32,
    cyBottomHeight: i32,
};
