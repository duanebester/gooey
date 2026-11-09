//! Platform types shared by the core hosts and the backend files.
//!
//! Gooey binds to exactly one backend per target at compile time; there is no
//! runtime vtable (`docs/platform_interface_design.md` decision 2). Each core
//! host (`<platform>/core_host.zig`) opens its window with `WindowOptions`,
//! sets `CursorShape`, and runs file dialogs with the prompt types declared
//! here.

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
// Renderer capabilities
// =============================================================================

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
