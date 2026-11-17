//! Bridgetek EVE (BT81x) platform module for embedded boards whose panel sits
//! behind an EVE display controller on SPI, with no framebuffer.
//!
//! Selected with `-Dlinux-backend=eve`. Frames become BT81x display lists the
//! chip draws itself (`renderer.zig`), and input is the chip's touch engine.
//! See `platform.zig` for configuration, `window.zig` for the single
//! full-screen window, and `eve_preview.py` for rendering simulator dumps.

pub const platform = @import("platform.zig");
pub const window = @import("window.zig");
pub const chip = @import("chip.zig");
pub const display_list = @import("display_list.zig");
pub const cells = @import("cells.zig");
pub const renderer = @import("renderer.zig");
pub const images = @import("images.zig");
pub const limits = @import("limits.zig");

// The names `platform/mod.zig` aliases as `Platform` and `PlatformWindow`.
pub const Platform = platform.EvePlatform;
pub const PlatformWindow = window.Window;

test {
    _ = chip;
    _ = display_list;
    _ = cells;
    _ = renderer;
    _ = images;
    _ = limits;
}
