//! Web platform module
//!
//! Exports for WebAssembly/browser target.
//!
//! `Platform`, `PlatformWindow`, and `drive_model` are the three declarations
//! `platform/mod.zig` binds to; the `Web*` names below are kept because the
//! web-only modules (renderer, file dialog, event bridges) refer to them.

const interface = @import("../interface.zig");

pub const imports = @import("imports.zig");
pub const io = @import("io.zig");
pub const window = @import("window.zig");
pub const renderer = @import("renderer.zig");
pub const platform = @import("platform.zig");
pub const mouse_events = @import("mouse_events.zig");
pub const scroll_events = @import("scroll_events.zig");
pub const key_events = @import("key_events.zig");
pub const text_buffer = @import("text_buffer.zig");
pub const composition_buffer = @import("composition_buffer.zig");
pub const custom_shader = @import("custom_shader.zig");
pub const image_loader = @import("image_loader.zig");
pub const file_dialog = @import("file_dialog.zig");

pub const WebPlatform = platform.WebPlatform;
pub const WebWindow = window.WebWindow;
pub const WebRenderer = renderer.WebRenderer;

// Canonical backend contract. See `docs/platform_interface_design.md`.
pub const Platform = platform.WebPlatform;
pub const PlatformWindow = window.WebWindow;

/// `Platform.run` arms `requestAnimationFrame` and returns; the browser owns
/// the clock and calls back per frame.
pub const drive_model: interface.DriveModel = .host_callback;

comptime {
    @import("../contract.zig").verifyBackend(@This());
}
