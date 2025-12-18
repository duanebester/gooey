//! Web platform module
//!
//! Exports for WebAssembly/browser target.

pub const platform = @import("platform.zig");
pub const window = @import("window.zig");
pub const imports = @import("imports.zig");
pub const renderer = @import("renderer.zig");

// Keyboard/text input (shared memory ring buffers)
pub const key_events = @import("key_events.zig");
pub const text_buffer = @import("text_buffer.zig");

pub const WebPlatform = platform.WebPlatform;
pub const WebWindow = window.WebWindow;
pub const WebRenderer = renderer.WebRenderer;
