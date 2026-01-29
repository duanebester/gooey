//! macOS Platform Module
//!
//! This module provides the macOS-specific platform implementation for gooey,
//! using Cocoa/AppKit for windowing and Metal for GPU rendering.
//!
//! ## Architecture
//!
//! - **AppKit**: Native Cocoa framework for window management
//! - **Metal**: Apple's low-level GPU API for rendering
//! - **CoreText**: Native text shaping and rendering
//!
//! ## Usage
//!
//! ```zig
//! const macos = @import("gooey").platform.macos;
//!
//! var platform = try macos.MacPlatform.init();
//! defer platform.deinit();
//!
//! var window = try macos.Window.init(allocator, &platform, .{
//!     .title = "My App",
//!     .width = 800,
//!     .height = 600,
//! });
//! defer window.deinit();
//!
//! platform.run();
//! ```

// Core platform types
pub const platform = @import("platform.zig");
pub const window = @import("window.zig");
pub const window_delegate = @import("window_delegate.zig");

// Metal renderer
pub const metal = @import("metal/metal.zig");

// Display synchronization
pub const display_link = @import("display_link.zig");

// System services
pub const clipboard = @import("clipboard.zig");
pub const file_dialog = @import("file_dialog.zig");

// Low-level bindings
pub const appkit = @import("appkit.zig");

// Input handling
pub const input_view = @import("input_view.zig");
pub const dispatcher = @import("dispatcher.zig");

// Shared GPU primitives
pub const unified = @import("../unified.zig");

// Type aliases for convenience
pub const MacPlatform = platform.MacPlatform;
pub const Window = window.Window;
pub const DisplayLink = display_link.DisplayLink;
pub const Renderer = metal.Renderer;

// Re-export capabilities
pub const capabilities = MacPlatform.capabilities;

// Re-export file dialog types (from platform interface)
pub const PathPromptOptions = @import("../interface.zig").PathPromptOptions;
pub const PathPromptResult = @import("../interface.zig").PathPromptResult;
pub const SavePromptOptions = @import("../interface.zig").SavePromptOptions;
