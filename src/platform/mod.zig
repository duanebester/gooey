//! Platform abstraction layer for gooey
//!
//! This module provides a unified interface for platform-specific functionality.
//! The appropriate backend is selected at compile time based on the target OS.
//!
//! ## Usage
//!
//! ```zig
//! const platform = @import("gooey").platform;
//!
//! // Time (works on native and WASM)
//! const now = platform.time.milliTimestamp();
//!
//! // Platform detection
//! if (platform.is_wasm) { ... }
//!
//! // Capabilities
//! const caps = platform.getCapabilities();
//! if (caps.can_close_window) { ... }
//! ```

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Platform Interface (for runtime polymorphism)
// =============================================================================

pub const interface = @import("interface.zig");

/// Platform interface for runtime polymorphism
pub const PlatformVTable = interface.PlatformVTable;

/// Window interface for runtime polymorphism
pub const WindowVTable = interface.WindowVTable;

/// Platform capabilities
pub const PlatformCapabilities = interface.PlatformCapabilities;

/// Window creation options (platform-agnostic)
pub const WindowOptions = interface.WindowOptions;

/// Renderer capabilities
pub const RendererCapabilities = interface.RendererCapabilities;

/// File dialog options (open)
pub const PathPromptOptions = interface.PathPromptOptions;

/// File dialog options (save)
pub const SavePromptOptions = interface.SavePromptOptions;

/// File dialog result
pub const PathPromptResult = interface.PathPromptResult;

// =============================================================================
// Compile-time Platform Selection
// =============================================================================

pub const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// =============================================================================
// Platform-agnostic Time Utilities
// =============================================================================

pub const time = @import("time.zig");

// =============================================================================
// Backend Selection
// =============================================================================

pub const is_linux = builtin.os.tag == .linux;

pub const backend = if (is_wasm)
    @import("wgpu/web/mod.zig")
else switch (builtin.os.tag) {
    .macos => @import("mac/platform.zig"),
    .linux => @import("linux/mod.zig"),
    else => @compileError("Unsupported platform: " ++ @tagName(builtin.os.tag)),
};

/// Platform type for the current OS (compile-time selected)
pub const Platform = if (is_wasm)
    backend.WebPlatform
else if (is_linux)
    backend.LinuxPlatform
else
    backend.MacPlatform;

/// Window type for the current OS (compile-time selected)
pub const Window = if (is_wasm)
    backend.WebWindow
else if (is_linux)
    backend.Window
else
    @import("mac/window.zig").Window;

/// DisplayLink for vsync (native only, not available on Linux)
pub const DisplayLink = if (is_wasm)
    void // Not applicable on web
else if (is_linux)
    void // Linux uses Wayland frame callbacks
else
    @import("mac/display_link.zig").DisplayLink;

// =============================================================================
// Platform-specific modules (for advanced usage)
// =============================================================================

pub const mac = if (!is_wasm and !is_linux) struct {
    pub const platform = @import("mac/platform.zig");
    pub const window = @import("mac/window.zig");
    pub const display_link = @import("mac/display_link.zig");
    pub const appkit = @import("mac/appkit.zig");
    pub const metal = @import("mac/metal/metal.zig");
    pub const clipboard = @import("mac/clipboard.zig");
    pub const file_dialog = @import("mac/file_dialog.zig");
} else struct {};

pub const linux = if (is_linux) struct {
    pub const platform = @import("linux/platform.zig");
    pub const window = @import("linux/window.zig");
    pub const wayland = @import("linux/wayland.zig");
    pub const vulkan = @import("linux/vulkan.zig");
    pub const vk_renderer = @import("linux/vk_renderer.zig");
    pub const unified = @import("wgpu/unified.zig");
    pub const clipboard = @import("linux/clipboard.zig");
    pub const dbus = @import("linux/dbus.zig");
    pub const file_dialog = @import("linux/file_dialog.zig");

    // Type aliases
    pub const LinuxPlatform = platform.LinuxPlatform;
    pub const Window = window.Window;
    pub const VulkanRenderer = vk_renderer.VulkanRenderer;
} else struct {};

pub const web = if (is_wasm) struct {
    pub const platform = @import("wgpu/web/platform.zig");
    pub const window = @import("wgpu/web/window.zig");
    pub const imports = @import("wgpu/web/imports.zig");
    pub const file_dialog = @import("wgpu/web/file_dialog.zig");
} else struct {};

// =============================================================================
// Helpers
// =============================================================================

/// Get the capabilities of the current platform.
pub fn getCapabilities() PlatformCapabilities {
    return Platform.capabilities;
}
