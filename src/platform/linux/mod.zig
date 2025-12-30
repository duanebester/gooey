//! Linux Platform Module
//!
//! This module provides the Linux-specific platform implementation for gooey,
//! using Wayland for windowing and Vulkan for GPU rendering.
//!
//! ## Architecture
//!
//! - **Wayland**: Native display server protocol for window management
//! - **XDG Shell**: Standard window decorations and lifecycle
//! - **Vulkan**: Direct GPU rendering (no wgpu-native dependency)
//!
//! ## Usage
//!
//! ```zig
//! const linux = @import("gooey").platform.linux;
//!
//! var platform = try linux.LinuxPlatform.init();
//! defer platform.deinit();
//!
//! var window = try linux.Window.init(allocator, &platform, .{
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

// Vulkan renderer (direct Vulkan, no wgpu dependency)
pub const vk_renderer = @import("vk_renderer.zig");
pub const vulkan = @import("vulkan.zig");
pub const scene_renderer = @import("scene_renderer.zig");

// D-Bus integration (for XDG portals)
pub const dbus = @import("dbus.zig");

// File dialogs (via XDG Desktop Portal)
pub const file_dialog = @import("file_dialog.zig");

// Low-level bindings
pub const wayland = @import("wayland.zig");

// Input handling
pub const input = @import("input.zig");

// Shared GPU primitives (same as web)
pub const unified = @import("../wgpu/unified.zig");

// Type aliases for convenience
pub const LinuxPlatform = platform.LinuxPlatform;
pub const Window = window.Window;
pub const VulkanRenderer = vk_renderer.VulkanRenderer;

// Re-export capabilities
pub const capabilities = LinuxPlatform.capabilities;

// Re-export file dialog types
pub const PathPromptOptions = file_dialog.PathPromptOptions;
pub const PathPromptResult = file_dialog.PathPromptResult;
pub const SavePromptOptions = file_dialog.SavePromptOptions;
