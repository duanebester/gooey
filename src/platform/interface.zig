//! Shared platform contract types.
//!
//! Gooey's platform abstraction is compile-time monomorphic: `platform/mod.zig`
//! selects exactly one backend namespace per target and every call site binds
//! directly to its concrete types. There is deliberately no runtime vtable —
//! see `docs/platform_interface_design.md` decision 2. Runtime type erasure was
//! removed because it created a second, drifting contract with zero consumers.
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
const geometry = @import("../core/geometry.zig");
const window_registry = @import("window_registry.zig");

// =============================================================================
// Window identity
// =============================================================================

/// Unique identifier for windows, enabling cross-window references.
pub const WindowId = window_registry.WindowId;

/// Central registry for tracking windows by ID.
pub const WindowRegistry = window_registry.WindowRegistry;

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
// Glass / blur styling
// =============================================================================

/// Translucent-background style for a window.
///
/// One canonical enum shared by every backend. Previously macOS, web, and the
/// shared options each declared their own variant list with *different tag
/// values*, and `runtime/runner.zig` bridged them with
/// `@enumFromInt(@intFromEnum(...))` — a cast that silently produced the wrong
/// style the moment the orderings diverged, which they had. Backends that
/// cannot honour a given style must degrade visibly (see `glass_effects` in
/// `PlatformCapabilities`) rather than remap tags.
pub const GlassStyle = enum(u8) {
    /// No glass effect; the window background color is used as-is.
    none = 0,
    /// Traditional background blur.
    blur = 1,
    /// macOS 26+ liquid glass, regular density.
    glass_regular = 2,
    /// macOS 26+ liquid glass, clear/lighter density.
    glass_clear = 3,
    /// Browser `backdrop-filter` vibrancy. Web only.
    vibrancy = 4,

    /// Whether this style requires a transparent framebuffer clear so the
    /// host-composited backdrop shows through.
    pub fn needsTransparentClear(self: GlassStyle) bool {
        return self != .none;
    }
};

// =============================================================================
// Capabilities
// =============================================================================

/// Capabilities a backend supports. Declared per backend as a comptime
/// constant so feature checks fold away.
pub const PlatformCapabilities = struct {
    /// Supports high-DPI (Retina) displays.
    high_dpi: bool = true,

    /// Supports more than one window.
    multi_window: bool = true,

    /// Supports GPU-accelerated rendering.
    gpu_accelerated: bool = true,

    /// Supports vsync via a display link.
    display_link: bool = true,

    /// Can programmatically close windows.
    can_close_window: bool = true,

    /// The host can composite a translucent backdrop behind the window
    /// surface, so a non-`.none` `GlassStyle` is actually visible.
    ///
    /// Setting this true obliges the backend to declare
    /// `PlatformWindow.setGlassStyle`, which is how a caller selects the
    /// style; `contract.verifyPlatformWindow` checks that conditionally.
    ///
    /// This says nothing about the renderer. See `has_post_process` for the
    /// renderer-side fact; the two were conflated until a caller that needed
    /// only the latter started gating on this one.
    glass_effects: bool = false,

    /// The backend's `PlatformWindow.renderer` exposes
    /// `getPostProcess() ?*PostProcessState`, whose `uniforms` shared code
    /// writes through (`Window.setAccentColor`).
    ///
    /// A backend must not set this true until its renderer declares that
    /// method, because the gated bodies name it directly and a missing member
    /// is a compile error rather than a degraded effect. Independent of
    /// `glass_effects`: a host can composite a translucent backdrop with no
    /// post-process pass at all, and a renderer can own a post-process pass on
    /// a fully opaque window.
    has_post_process: bool = false,

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

/// Options for file open dialogs.
pub const PathPromptOptions = struct {
    /// Allow selecting directories.
    directories: bool = false,
    /// Allow selecting files.
    files: bool = true,
    /// Allow multiple selection.
    multiple: bool = false,
    /// Button text (e.g. "Open", "Select").
    prompt: ?[]const u8 = null,
    /// Window title/message.
    message: ?[]const u8 = null,
    /// Starting directory path.
    starting_directory: ?[]const u8 = null,
    /// Allowed file extensions (e.g. `&.{ "txt", "md" }`).
    allowed_extensions: ?[]const []const u8 = null,
};

/// Options for file save dialogs.
pub const SavePromptOptions = struct {
    /// Starting directory path.
    directory: ?[]const u8 = null,
    /// Suggested filename.
    suggested_name: ?[]const u8 = null,
    /// Button text (e.g. "Save").
    prompt: ?[]const u8 = null,
    /// Window title/message.
    message: ?[]const u8 = null,
    /// Allowed file extensions (e.g. `&.{ "txt", "md" }`).
    allowed_extensions: ?[]const []const u8 = null,
    /// Allow creating directories.
    can_create_directories: bool = true,
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

    /// Custom shaders (MSL on macOS, WGSL on web, ignored on Linux).
    custom_shaders: []const @import("../core/shader.zig").CustomShader = &.{},

    /// Background opacity (0.0 = fully transparent, 1.0 = opaque).
    /// Honoured where `PlatformCapabilities.glass_effects` is set.
    background_opacity: f64 = 1.0,

    /// Translucent-background style.
    glass_style: GlassStyle = .none,

    /// Corner radius for the glass effect.
    glass_corner_radius: f64 = 16.0,

    /// Make the titlebar transparent (macOS only).
    titlebar_transparent: bool = false,

    /// Extend content under the titlebar (macOS only).
    full_size_content: bool = false,

    /// Effective clear color for this configuration.
    ///
    /// A glass style requires a transparent clear so the host-composited
    /// backdrop is visible; otherwise the configured background color is used.
    pub fn clearColor(self: *const WindowOptions) geometry.Color {
        if (self.glass_style.needsTransparentClear()) return geometry.Color.transparent;
        return self.background_color;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "GlassStyle tag values are stable across backends" {
    // These tag values are load-bearing: they are persisted in `WindowOptions`
    // literals in application code and were previously reinterpreted across
    // three separate enums. Pin them so a reordering is a test failure rather
    // than a silently wrong window appearance.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(GlassStyle.none));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(GlassStyle.blur));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(GlassStyle.glass_regular));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(GlassStyle.glass_clear));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(GlassStyle.vibrancy));
}

test "GlassStyle.needsTransparentClear covers every variant" {
    // Positive and negative space: exactly one variant keeps its own color.
    try std.testing.expect(!GlassStyle.none.needsTransparentClear());

    var transparent_count: u32 = 0;
    inline for (comptime std.enums.values(GlassStyle)) |style| {
        if (style.needsTransparentClear()) transparent_count += 1;
    }
    const variant_count = comptime std.enums.values(GlassStyle).len;
    try std.testing.expectEqual(variant_count - 1, transparent_count);
}

test "WindowOptions.clearColor follows the glass style" {
    const opaque_options = WindowOptions{
        .glass_style = .none,
        .background_color = geometry.Color.rgba(0.1, 0.2, 0.3, 1.0),
    };
    try std.testing.expectEqual(@as(f32, 1.0), opaque_options.clearColor().a);

    const glass_options = WindowOptions{ .glass_style = .glass_regular };
    try std.testing.expectEqual(@as(f32, 0.0), glass_options.clearColor().a);
}

test "DriveModel distinguishes native from host-driven backends" {
    try std.testing.expect(DriveModel.blocking_event_loop != DriveModel.host_callback);
}
