//! Linux framebuffer platform module for embedded devices.
//!
//! Selected with `-Dlinux-backend=fbdev`. There is no display server: frames
//! are rendered on the CPU (`platform/cpu`) and copied to `/dev/fb0`, and
//! input is read from evdev devices. See `platform.zig` for configuration and
//! `window.zig` for the single full-screen window.

const interface = @import("../interface.zig");

pub const platform = @import("platform.zig");
pub const window = @import("window.zig");
pub const framebuffer = @import("framebuffer.zig");
pub const evdev = @import("evdev.zig");
pub const clipboard = @import("clipboard.zig");

// Canonical backend contract; see `linux/mod.zig`.
pub const Platform = platform.FbdevPlatform;
pub const PlatformWindow = window.Window;

/// `Platform.run` blocks in its own poll loop until the window closes.
pub const drive_model: interface.DriveModel = .blocking_event_loop;

comptime {
    @import("../contract.zig").verifyBackend(@This());
}

test {
    _ = framebuffer;
    _ = evdev;
    _ = clipboard;
}
