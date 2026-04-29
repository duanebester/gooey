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

// PR 7b.1a — `platform.Window` was renamed to `platform.PlatformWindow`
// to free up the `Window` name for the upcoming `Gooey → Window` rename
// in PR 7b.1b. The two are very different things — `PlatformWindow` is
// the OS-level handle (NSWindow on macOS, wl_surface on Linux, canvas
// on web); the framework-level `Window` will hold per-window frame
// state. Keeping them under one name was always going to bite once the
// `Gooey` god object split landed; this PR pre-empts the collision.
//
// See `docs/cleanup-implementation-plan.md` PR 7b for the broader
// App/Window split, and `architectural-cleanup-plan.md` §10 for the
// GPUI mapping where `platform_window: PlatformWindow` is the pattern
// being adopted.

/// Platform capabilities
pub const PlatformCapabilities = interface.PlatformCapabilities;

/// Window creation options (platform-agnostic)
pub const WindowOptions = interface.WindowOptions;

/// Renderer capabilities
pub const RendererCapabilities = interface.RendererCapabilities;

/// Unique identifier for windows
pub const WindowId = interface.WindowId;

/// Central registry for tracking windows by ID
pub const WindowRegistry = interface.WindowRegistry;

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
// Backend Selection
// =============================================================================
//
// Note: Time utilities previously lived here as `platform.time`. As of the
// Zig 0.16 `std.Io` migration, callers sample timestamps via
// `std.Io.Timestamp.now(io, .awake)` directly (see `docs/zig-0.16-io-migration.md`,
// phase 5.4/5.6). The `platform/time.zig` shim has been retired.

pub const is_linux = builtin.os.tag == .linux;

pub const backend = if (is_wasm)
    @import("web/mod.zig")
else switch (builtin.os.tag) {
    .macos => @import("macos/mod.zig"),
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

/// OS-level window handle for the current target (compile-time selected).
///
/// This is the platform's native window object — `NSWindow` on macOS
/// (wrapped), `wl_surface` plus xdg-shell state on Linux/Wayland, an
/// `HTMLCanvasElement`-backed shim on web. Framework code should
/// generally treat it as opaque and reach for it through `Window`
/// (the framework-level wrapper, see `context/gooey.zig`) rather than
/// here.
///
/// Renamed from `Window` in PR 7b.1a so the framework wrapper can
/// claim that name in PR 7b.1b without a `platform.Window` collision.
pub const PlatformWindow = if (is_wasm)
    backend.WebWindow
else if (is_linux)
    backend.Window
else
    backend.Window;

/// DisplayLink for vsync (native only, not available on Linux)
pub const DisplayLink = if (is_wasm)
    void // Not applicable on web
else if (is_linux)
    void // Linux uses Wayland frame callbacks
else
    backend.DisplayLink;

// =============================================================================
// Platform-specific modules (for advanced usage)
// =============================================================================

pub const macos = if (!is_wasm and !is_linux) @import("macos/mod.zig") else struct {};

// Legacy alias for backwards compatibility
pub const mac = macos;

pub const linux = if (is_linux) struct {
    pub const platform = @import("linux/platform.zig");
    pub const window = @import("linux/window.zig");
    pub const wayland = @import("linux/wayland.zig");
    pub const vulkan = @import("linux/vulkan.zig");
    pub const vk_renderer = @import("linux/vk_renderer.zig");
    pub const unified = @import("unified.zig");
    pub const clipboard = @import("linux/clipboard.zig");
    pub const dbus = @import("linux/dbus.zig");
    pub const file_dialog = @import("linux/file_dialog.zig");
    // Type aliases
    pub const LinuxPlatform = platform.LinuxPlatform;
    pub const Window = window.Window;
    pub const VulkanRenderer = vk_renderer.VulkanRenderer;
} else struct {};

pub const web = if (is_wasm) struct {
    pub const platform = @import("web/platform.zig");
    pub const window = @import("web/window.zig");
    pub const imports = @import("web/imports.zig");
    pub const file_dialog = @import("web/file_dialog.zig");
} else struct {};

// =============================================================================
// Helpers
// =============================================================================

/// Get the capabilities of the current platform.
pub fn getCapabilities() PlatformCapabilities {
    return Platform.capabilities;
}
