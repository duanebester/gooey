//! SVG Rasterizer Stub - For unsupported platforms
//!
//! Provides API compatibility for platforms without SVG rasterization support.
//! All rasterization calls return an error.

const std = @import("std");
const svg_mod = @import("../path.zig");

pub const RasterizedSvg = struct {
    width: u32,
    height: u32,
    offset_x: i16,
    offset_y: i16,
};

pub const RasterizeError = error{
    /// SVG rasterization is not supported on this platform
    PlatformNotSupported,
    /// Failed to allocate memory
    OutOfMemory,
    /// Invalid path data
    EmptyPath,
    /// The path exceeds its `RasterBudget`
    PathTooComplex,
    /// Graphics error
    GraphicsError,
    /// Buffer too small
    BufferTooSmall,
};

/// Stroke options for SVG rendering
pub const StrokeOptions = struct {
    enabled: bool = false,
    width: f32 = 1.0,
};

pub const RasterBudget = svg_mod.RasterBudget;

/// Rasterizes nothing, so it needs no scratch.
pub fn scratchBytes(budget: RasterBudget, device_size_max: u32) u32 {
    _ = budget;
    _ = device_size_max;
    return 0;
}

/// Rasterize SVG path data to RGBA buffer
///
/// Returns PlatformNotSupported on Linux and other unsupported platforms.
pub fn rasterize(
    allocator: std.mem.Allocator,
    path_data: []const u8,
    viewbox: f32,
    device_size: u32,
    buffer: []u8,
) RasterizeError!RasterizedSvg {
    return rasterizeWithOptions(
        allocator,
        path_data,
        viewbox,
        device_size,
        buffer,
        true,
        .{},
        RasterBudget.ceiling,
    );
}

/// Rasterize SVG path data with extended options
///
/// Returns PlatformNotSupported on Linux and other unsupported platforms.
pub fn rasterizeWithOptions(
    allocator: std.mem.Allocator,
    path_data: []const u8,
    viewbox: f32,
    device_size: u32,
    buffer: []u8,
    fill: bool,
    stroke_options: StrokeOptions,
    budget: RasterBudget,
) RasterizeError!RasterizedSvg {
    _ = budget;
    _ = allocator;
    _ = path_data;
    _ = viewbox;
    _ = device_size;
    _ = buffer;
    _ = fill;
    _ = stroke_options;
    return error.PlatformNotSupported;
}
