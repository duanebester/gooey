//! Web platform module
//!
//! Exports for WebAssembly/browser target.

pub const imports = @import("imports.zig");
pub const window = @import("window.zig");
pub const renderer = @import("renderer.zig");
pub const platform = @import("platform.zig");
pub const mouse_events = @import("mouse_events.zig");
pub const scroll_events = @import("scroll_events.zig");
pub const key_events = @import("key_events.zig");
pub const text_buffer = @import("text_buffer.zig");
pub const composition_buffer = @import("composition_buffer.zig");
pub const custom_shader = @import("custom_shader.zig");

pub const WebPlatform = platform.WebPlatform;
pub const WebWindow = window.WebWindow;
pub const WebRenderer = renderer.WebRenderer;
