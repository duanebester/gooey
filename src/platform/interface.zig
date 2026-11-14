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
    /// A divider that moves left and right, such as a vertical splitter.
    resize_left_right,
    /// A divider that moves up and down, such as a horizontal splitter.
    resize_up_down,
};

// =============================================================================
// Device pixels
// =============================================================================

/// Steps per unit of scale. Wayland's `wp_fractional_scale_v1` reports scales
/// in 120ths (180 is 1.5); integer scales and Windows' 25% DPI steps lie on
/// the same grid.
pub const scale_steps_per_unit: u32 = 120;

/// How far, in steps, a scale may sit from the grid and still count as on it.
/// A scale on the grid reaches the renderers through the frame's `f32`, which
/// is off by under 2^-24 of the scale: 6e-5 steps at the CPU renderer's 8x.
const scale_step_tolerance: f64 = 1e-3;

/// The scale factor `steps` 120ths make, as `wp_fractional_scale_v1` reports
/// it: 180 is 1.5.
pub fn scaleFromSteps(steps: u32) f64 {
    std.debug.assert(steps > 0);
    const scale = @as(f64, @floatFromInt(steps)) / @as(f64, @floatFromInt(scale_steps_per_unit));
    std.debug.assert(scale > 0);
    return scale;
}

/// Device pixels covering `logical_px` at `scale_factor`, rounded half away
/// from zero, as `wp_fractional_scale_v1` requires of buffer sizes so that the
/// viewport maps the buffer onto the output one to one. A scale on the 1/120
/// grid is computed exactly in integers: in floating point a product ending in
/// .5 can round down (405 px at 1.3 is 526.5, but 405 * @as(f32, 1.3) is
/// 526.49998). Any other scale, such as one lowered to fit a framebuffer
/// budget, rounds in floating point.
pub fn devicePxFromLogical(logical_px: u32, scale_factor: f64) u32 {
    std.debug.assert(logical_px > 0);
    std.debug.assert(scale_factor > 0);
    const steps = scale_factor * @as(f64, @floatFromInt(scale_steps_per_unit));
    const steps_nearest = @round(steps);
    var device_px: u64 = 0;
    if (@abs(steps - steps_nearest) <= scale_step_tolerance) {
        const steps_whole: u64 = @intFromFloat(steps_nearest);
        const product = @as(u64, logical_px) * steps_whole + scale_steps_per_unit / 2;
        device_px = @divFloor(product, scale_steps_per_unit);
    } else {
        device_px = @intFromFloat(@round(@as(f64, @floatFromInt(logical_px)) * scale_factor));
    }
    std.debug.assert(device_px <= std.math.maxInt(u32));
    return @intCast(device_px);
}

test "fractional scales convert exactly and round buffer sizes half away from zero" {
    // Goal: pin the scale and buffer size a fractional Wayland scale produces.
    // Methodology: scales arrive as 120ths and reach the renderers as f32, so each
    // case converts that way; expected values are logical * steps / 120 worked by
    // hand, on odd sizes where truncating, as the renderers did, gives one less.
    try std.testing.expectEqual(1.25, scaleFromSteps(150));
    try std.testing.expectEqual(1.5, scaleFromSteps(180));
    try std.testing.expectEqual(1.75, scaleFromSteps(210));
    const cases = [_]struct { steps: u32, logical_px: u32, device_px: u32 }{
        .{ .steps = 150, .logical_px = 2, .device_px = 3 }, // 1.25: 2.5 rounds up.
        .{ .steps = 150, .logical_px = 403, .device_px = 504 }, // 503.75
        .{ .steps = 180, .logical_px = 401, .device_px = 602 }, // 1.5: 601.5
        .{ .steps = 180, .logical_px = 400, .device_px = 600 },
        .{ .steps = 210, .logical_px = 401, .device_px = 702 }, // 1.75: 701.75
        .{ .steps = 210, .logical_px = 402, .device_px = 704 }, // 703.5
        .{ .steps = 240, .logical_px = 401, .device_px = 802 }, // Integer 2x.
        // 1.3: 526.5 exactly, which f32(1.3) * 405 alone would round down.
        .{ .steps = 156, .logical_px = 405, .device_px = 527 },
    };
    for (cases) |case| {
        const scale: f32 = @floatCast(scaleFromSteps(case.steps));
        try std.testing.expectEqual(case.device_px, devicePxFromLogical(case.logical_px, scale));
    }
    // A scale off the grid, such as a budget-fitted one, never rounds past the budget.
    try std.testing.expectEqual(3840, devicePxFromLogical(2561, 3840.0 / 2561.0));
}

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
