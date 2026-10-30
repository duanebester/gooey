//! Test root for the Windows backend, the DirectWrite text backend, the WIC
//! image backend, the software SVG rasterizer behind the SVG atlas, and the
//! UI Automation accessibility bridge.
//!
//! The input translation and binding tests call no Win32 functions. The
//! DirectWrite and WIC tests call the system's real DirectWrite and WIC, so
//! they run on any Windows host. The clipboard tests use the real system
//! clipboard and replace its contents. The file dialog tests create and
//! configure real Common Item Dialogs without showing them. The accessibility
//! tests drive the providers through their COM vtables against hidden
//! windows. `root.zig`'s test block is not wired up for Windows yet. This root
//! lives in `src/` because a module cannot import files above its root's
//! directory.

test {
    _ = @import("platform/windows/clipboard.zig");
    _ = @import("platform/windows/file_dialog.zig");
    _ = @import("platform/windows/shell.zig");
    _ = @import("platform/windows/input.zig");
    _ = @import("platform/windows/uia.zig");
    _ = @import("platform/windows/win32.zig");
    _ = @import("accessibility/windows_snapshot.zig");
    _ = @import("accessibility/windows_provider.zig");
    _ = @import("accessibility/windows_bridge.zig");
    _ = @import("text/backends/directwrite/mod.zig");
    _ = @import("image/backends/wic/tests.zig");
    _ = @import("svg/atlas.zig");
}
