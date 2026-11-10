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
//! ```

const std = @import("std");
const builtin = @import("builtin");

// =============================================================================
// Shared contract
// =============================================================================

pub const interface = @import("interface.zig");

/// Exact compile-time verification of backend signatures.
pub const contract = @import("contract.zig");

// `platform.PlatformWindow` and the framework-level `Window` are distinct
// names because they are very different things — `PlatformWindow` is the
// OS-level handle (NSWindow on macOS, wl_surface on Linux, canvas on web);
// the framework-level `Window` holds per-window frame state. One name for
// both would collide.
//
// See `docs/cleanup-implementation-plan.md` for the broader App/Window
// split, and `architectural-cleanup-plan.md` §10 for the GPUI mapping where
// `platform_window: PlatformWindow` is the adopted pattern.

/// Window creation options (platform-agnostic)
pub const WindowOptions = interface.WindowOptions;

/// Cursor shapes selected by framework widgets.
pub const CursorShape = interface.CursorShape;

/// Translucent-background style, shared by every backend.
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
// Note: There are no platform time utilities. Callers sample timestamps via
// `std.Io.Timestamp.now(io, .awake)` directly (see `docs/zig-0.16-io-migration.md`).

pub const is_linux = builtin.os.tag == .linux;

/// True on macOS. Read by policy that follows platform convention rather than
/// by backend selection, which goes through `backend` below.
pub const is_macos = builtin.os.tag == .macos;

pub const is_windows = builtin.os.tag == .windows;

pub const backend = if (is_wasm)
    @import("web/mod.zig")
else switch (builtin.os.tag) {
    .macos => @import("macos/mod.zig"),
    // `-Dlinux-backend` picks Wayland (GPU or CPU rendered) or the
    // display-server-free framebuffer backend; see `linux_backend.zig`.
    .linux => switch (@import("linux_backend.zig").selected) {
        .wayland_vulkan, .wayland_cpu => @import("linux/mod.zig"),
        .fbdev => @import("fbdev/mod.zig"),
    },
    .windows => @import("windows/mod.zig"),
    else => @compileError("Unsupported platform: " ++ @tagName(builtin.os.tag)),
};

// Every backend namespace declares `Platform` and `PlatformWindow`, so the
// aliases below do not have to know what any backend calls its own types.

/// Where atlas pixels live for the selected renderer. The CPU renderer samples
/// its atlases in place, so they are its textures; GPU renderers keep atlas
/// pixels only in their textures and receive them through `AtlasUploads`.
/// Synthetic-text builds draw with the `NullRenderer`, which reads the glyph
/// atlas in place like the CPU renderer, so they keep CPU pixels too.
pub const atlas_storage: @import("../text/atlas_uploads.zig").AtlasStorage = if (text_is_synthetic)
    .cpu_texture
else if (is_wasm)
    .gpu_upload
else switch (builtin.os.tag) {
    .linux => if (@import("linux_backend.zig").uses_cpu_renderer) .cpu_texture else .gpu_upload,
    else => .gpu_upload,
};

const text_is_synthetic = @import("../text/mod.zig").is_synthetic;

/// Platform type for the current target (compile-time selected).
pub const Platform = backend.Platform;

/// OS-level window handle for the current target (compile-time selected).
///
/// This is the platform's native window object — `NSWindow` on macOS
/// (wrapped), `wl_surface` plus xdg-shell state on Linux/Wayland, an
/// `HTMLCanvasElement`-backed shim on web. Framework code should
/// generally treat it as opaque and reach for it through `Window`
/// (the framework-level wrapper, see `context/gooey.zig`) rather than
/// here.
///
/// Named `PlatformWindow` so the framework wrapper can own the name `Window`
/// without a `platform.Window` collision.
pub const PlatformWindow = backend.PlatformWindow;

// =============================================================================
// Platform-specific modules (for advanced usage)
// =============================================================================

pub const macos = if (is_macos) @import("macos/mod.zig") else struct {};

// Short alias for `macos`, kept so existing callers compile.
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
    /// CPU renderer shared by the `wayland_cpu` and `fbdev` backends.
    pub const cpu = @import("cpu/renderer.zig");
    // Type aliases
    pub const LinuxPlatform = platform.LinuxPlatform;
    pub const Window = window.Window;
    pub const VulkanRenderer = vk_renderer.VulkanRenderer;
} else struct {};

pub const web = if (is_wasm) struct {
    pub const platform = @import("web/platform.zig");
    pub const window = @import("web/window.zig");
    pub const imports = @import("web/imports.zig");
} else struct {};
