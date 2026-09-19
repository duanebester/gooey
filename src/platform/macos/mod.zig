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
//! var plat: macos.Platform = undefined;
//! try plat.initInPlace(allocator);
//! defer plat.deinit();
//!
//! const options = macos.WindowOptions{ .title = "My App" };
//! var win = try macos.PlatformWindow.init(allocator, &plat, &options);
//! defer win.deinit();
//!
//! plat.run();
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

// Shared GPU primitives
pub const unified = @import("../unified.zig");

const interface = @import("../interface.zig");

// =============================================================================
// Canonical backend surface
// =============================================================================

// The three names `platform/mod.zig` and `contract.zig` bind to. Every other
// alias below is a convenience spelling layered on top of these.
pub const Platform = platform.MacPlatform;
pub const PlatformWindow = window.Window;

/// `[NSApp run]` owns the thread until `quit`, so macOS blocks in `run`.
pub const drive_model: interface.DriveModel = .blocking_event_loop;

// Type aliases for convenience
pub const MacPlatform = platform.MacPlatform;
pub const Window = window.Window;
pub const DisplayLink = display_link.DisplayLink;
pub const Renderer = metal.Renderer;

// Re-export capabilities
pub const capabilities = MacPlatform.capabilities;

// Re-export shared contract types (from platform interface)
pub const WindowOptions = interface.WindowOptions;
pub const GlassStyle = interface.GlassStyle;
pub const CursorShape = interface.CursorShape;
pub const PathPromptOptions = interface.PathPromptOptions;
pub const PathPromptResult = interface.PathPromptResult;
pub const SavePromptOptions = interface.SavePromptOptions;

// Pin this backend to the compile-time contract. A drifting signature is a
// build error here rather than a mystery at the first shared call site.
comptime {
    @import("../contract.zig").verifyBackend(@This());
}
