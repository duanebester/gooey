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
//! var plat: linux.Platform = undefined;
//! try plat.initInPlace(allocator);
//! defer plat.deinit();
//!
//! const options = gooey.platform.WindowOptions{
//!     .title = "My App",
//!     .width = 800,
//!     .height = 600,
//! };
//! var win = try linux.PlatformWindow.init(allocator, &plat, &options);
//! defer win.deinit();
//!
//! plat.run();
//! ```

const interface = @import("../interface.zig");

// Core platform types
pub const platform = @import("platform.zig");
pub const window = @import("window.zig");

// Vulkan renderer (direct Vulkan, no wgpu dependency)
pub const vk_renderer = @import("vk_renderer.zig");
pub const vk_types = @import("vk_types.zig");
pub const vk_pipelines = @import("vk_pipelines.zig");
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
pub const unified = @import("../unified.zig");

// Canonical backend contract. `platform/mod.zig` derives its public aliases
// from exactly these three names, so the backend cannot invent parallel ones.
pub const Platform = platform.LinuxPlatform;
pub const PlatformWindow = window.Window;

/// `Platform.run` blocks inside the Wayland poll/dispatch loop until quit.
pub const drive_model: interface.DriveModel = .blocking_event_loop;

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

// Fail at compile time, in this file, if the backend drifts from the shared
// contract — rather than at some distant shared call site.
comptime {
    @import("../contract.zig").verifyBackend(@This());
}
