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
