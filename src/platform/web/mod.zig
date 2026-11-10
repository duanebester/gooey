//! Web platform module
//!
//! Exports for WebAssembly/browser target.
//!
//! `Platform` and `PlatformWindow` are the declarations `platform/mod.zig`
//! binds to; the `Web*` names below are kept because the web-only modules
//! (renderer, event bridges) refer to them.

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

pub const WebPlatform = platform.WebPlatform;
pub const WebWindow = window.WebWindow;
pub const WebRenderer = renderer.WebRenderer;

// The names `platform/mod.zig` aliases as `Platform` and `PlatformWindow`.
pub const Platform = platform.WebPlatform;
pub const PlatformWindow = window.WebWindow;
