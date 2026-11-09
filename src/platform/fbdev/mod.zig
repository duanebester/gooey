//! Linux framebuffer platform module for embedded devices.
//!
//! Selected with `-Dlinux-backend=fbdev`. There is no display server: frames
//! are rendered on the CPU (`platform/cpu`) and copied to `/dev/fb0`, and
//! input is read from evdev devices. See `platform.zig` for configuration and
//! `window.zig` for the single full-screen window.

pub const platform = @import("platform.zig");
pub const window = @import("window.zig");
pub const framebuffer = @import("framebuffer.zig");
pub const evdev = @import("evdev.zig");
pub const clipboard = @import("clipboard.zig");

// The names `platform/mod.zig` aliases as `Platform` and `PlatformWindow`.
pub const Platform = platform.FbdevPlatform;
pub const PlatformWindow = window.Window;

test {
    _ = framebuffer;
    _ = evdev;
    _ = clipboard;
}
