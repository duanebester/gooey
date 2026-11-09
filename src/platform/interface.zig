//! Shared platform contract types.
//!
//! Gooey's platform abstraction is compile-time monomorphic: `platform/mod.zig`
//! selects exactly one backend namespace per target and every call site binds
//! directly to its concrete types. There is deliberately no runtime vtable —
//! see `docs/platform_interface_design.md` decision 2. There is no runtime type
//! erasure either, because it would create a second, drifting contract with no
//! consumers.
//!
//! This module owns the types both sides of the boundary agree on. The exact
//! signature checks that enforce the agreement live in `contract.zig`.
//!
//! ## Usage
//!
//! ```zig
//! const platform = @import("gooey").platform;
//!
//! var plat: platform.Platform = undefined;
//! try plat.initInPlace(allocator);
//! defer plat.deinit();
//!
//! const options = platform.WindowOptions{};
//! var window = try platform.PlatformWindow.init(allocator, &plat, &options);
//! defer window.deinit();
//!
//! plat.run();
//! ```
//!
//! ## Supported backends
//!
//! - macOS: AppKit + Metal
//! - Linux: Wayland + Vulkan
//! - Web: canvas + WebGPU
//! - Tests: `src/testing/test_backend.zig`

const std = @import("std");
const geometry = @import("../geometry/geometry.zig");
const ResourceLimits = @import("../core/limits.zig").ResourceLimits;
const window_registry = @import("window_registry.zig");

// =============================================================================
// Window identity
// =============================================================================

/// Unique identifier for windows, enabling cross-window references.
pub const WindowId = window_registry.WindowId;

/// Central registry for tracking windows by ID.
pub const WindowRegistry = window_registry.WindowRegistry;

// =============================================================================
// Timed redraw
// =============================================================================

/// Longest delay `Window.requestRenderAfter` accepts.
///
/// Timed redraws exist for views that change with the clock alone, such as a
/// caret blink (530 ms) or a once-per-second countdown. Both re-arm from every
/// frame they draw, so a minute is far beyond any legitimate single wait, and
/// the bound keeps deadline arithmetic in the backends trivially overflow-free.
pub const render_delay_ms_max: u32 = 60_000;

// =============================================================================
// Host drive model
// =============================================================================

/// How a backend's host hands control to Gooey.
///
/// Native and web genuinely differ here and forcing them into one event-loop
/// implementation would mean lying in one of them. Exposing the difference as a
/// comptime backend property keeps it explicit without runtime dispatch: the
/// untaken branch is never analyzed, so this costs nothing at runtime.
pub const DriveModel = enum(u8) {
    /// `Platform.run` blocks, pumping the host event loop until quit.
    /// macOS (`[NSApp run]`) and Linux (`wl_display_dispatch`) use this.
    blocking_event_loop,

    /// `Platform.run` arms a host callback and returns immediately. The host
    /// calls back per frame. Web (`requestAnimationFrame`) uses this.
    host_callback,
};

// =============================================================================
// Cursors
// =============================================================================

/// Cursor shapes selected by framework widgets.
pub const CursorShape = enum(u8) {
    default,
    text,
    /// Hand/pointing-finger cursor for clickable elements (buttons, links).
    pointer,
};

// =============================================================================
// Capabilities
// =============================================================================

/// Capabilities a backend supports. Declared per backend as a comptime
/// constant so feature checks fold away.
pub const PlatformCapabilities = struct {
    /// Supports high-DPI (Retina) displays.
    high_dpi: bool = true,

    /// Supports GPU-accelerated rendering.
    gpu_accelerated: bool = true,

    /// Supports vsync via a display link.
    display_link: bool = true,

    /// Can programmatically close windows.
    can_close_window: bool = true,

    /// Supports clipboard access.
    clipboard: bool = true,

    /// Supports native file dialogs.
    file_dialogs: bool = true,

    /// Supports IME (Input Method Editor).
    ime: bool = true,

    /// Supports cursor customization.
    custom_cursors: bool = true,

    /// Supports dragging the window by its content area.
    window_drag_by_content: bool = false,

    /// Backend name (for debugging).
    name: []const u8 = "unknown",

    /// Graphics backend name.
    graphics_backend: []const u8 = "unknown",
};

/// Renderer capabilities for feature detection.
pub const RendererCapabilities = struct {
    max_texture_size: u32 = 4096,
    msaa: bool = true,
    msaa_sample_count: u32 = 4,
    unified_memory: bool = false,
    name: []const u8 = "unknown",
};

// =============================================================================
// File dialog types
// =============================================================================

/// Options for file open dialogs: GPUI's `PathPromptOptions` (contract
/// decision 11). No defaults, so every call site states what it selects.
/// At least one of `files` and `directories` is set.
pub const PathPromptOptions = struct {
    files: bool,
    directories: bool,
    multiple: bool,
};

/// Options for file save dialogs: GPUI's `prompt_for_new_path` arguments
/// (contract decision 11). The panel always allows creating directories.
pub const SavePromptOptions = struct {
    /// The folder the panel starts in, or null for the platform's choice.
    directory: ?[]const u8,
    /// The file name the panel starts with, or null for none. Never empty.
    suggested_name: ?[]const u8,
};

/// Result from a file dialog.
///
/// Note: this still transfers ownership of heap-allocated path storage, which
/// conflicts with the static-allocation rule. Replacing it with bounded
/// request-slot storage is phase 6 of `docs/platform_interface_design.md` and
/// is deliberately not attempted here.
pub const PathPromptResult = struct {
    /// Selected paths (empty if cancelled).
    paths: [][]const u8,
    /// Allocator used — caller must free paths.
    allocator: std.mem.Allocator,

    pub fn deinit(self: PathPromptResult) void {
        for (self.paths) |path| {
            self.allocator.free(path);
        }
        self.allocator.free(self.paths);
    }
};

// =============================================================================
// Window options
// =============================================================================

/// Window creation options.
///
/// Passed as `*const WindowOptions` across the boundary: the struct is well
/// over the 16-byte by-value threshold, and an out-of-line pointer keeps the
/// caller's literal from being copied into every backend frame.
pub const WindowOptions = struct {
    /// Window title.
    title: []const u8 = "Gooey Window",

    /// Initial width in logical pixels.
    width: f64 = 800,

    /// Initial height in logical pixels.
    height: f64 = 600,

    /// Background color.
    background_color: geometry.Color = geometry.Color.rgba(0.2, 0.2, 0.25, 1.0),

    /// Enable vsync via display link (recommended).
    use_display_link: bool = true,

    /// Minimum window size.
    min_size: ?geometry.Size(f64) = null,

    /// Maximum window size.
    max_size: ?geometry.Size(f64) = null,

    /// Start the window centered on screen.
    centered: bool = true,

    /// The application's validated per-window budget. Backends size renderer
    /// instance storage from it during `PlatformWindow.init` rather than from
    /// framework ceilings. The runtime always sets it from the app config;
    /// there is no default profile (CLAUDE.md §2).
    limits: ResourceLimits,
};

// =============================================================================
// Tests
// =============================================================================

test "DriveModel distinguishes native from host-driven backends" {
    try std.testing.expect(DriveModel.blocking_event_loop != DriveModel.host_callback);
}
