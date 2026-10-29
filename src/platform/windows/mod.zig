//! Windows platform module: Win32 windows rendered with Vulkan.
//!
//! The Vulkan renderer is shared with the Wayland backend and still lives
//! under `platform/linux/`; this backend adds only the window system half
//! (`vk_surface_win32.zig`). See `docs/windows-port.md` for the plan and the
//! seams 0.4.0 changes.
//!
//! 64-bit only: `linux/vulkan.zig` declares every handle as a pointer, which
//! matches the C ABI only on 64-bit targets.

const std = @import("std");
const interface = @import("../interface.zig");

pub const platform = @import("platform.zig");
pub const window = @import("window.zig");
pub const input = @import("input.zig");
pub const clipboard = @import("clipboard.zig");
pub const win32 = @import("win32.zig");
pub const vk_surface_win32 = @import("vk_surface_win32.zig");

// Canonical backend contract; see `linux/mod.zig`.
pub const Platform = platform.WindowsPlatform;
pub const PlatformWindow = window.Window;

/// `Platform.run` blocks in its own message loop until no window is open.
pub const drive_model: interface.DriveModel = .blocking_event_loop;

comptime {
    if (@sizeOf(usize) != 8) {
        @compileError("the Windows backend supports 64-bit targets only (x86_64-windows)");
    }
    @import("../contract.zig").verifyBackend(@This());
}

test {
    _ = input;
    _ = win32;
}
