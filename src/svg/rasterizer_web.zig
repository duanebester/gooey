//! SVG Rasterizer - Web/Canvas2D-based SVG path rendering
//!
//! Rasterizes SVG path data to RGBA bitmaps via JavaScript's Path2D and Canvas2D APIs.
//! Uses two-channel encoding: R = fill alpha, G = stroke alpha.
//! This allows the shader to apply different colors to fill and stroke.

const std = @import("std");

pub const RasterizedSvg = struct {
    width: u32,
    height: u32,
    offset_x: i16,
    offset_y: i16,
};

pub const RasterizeError = error{
    EmptyPath,
    GraphicsError,
    BufferTooSmall,
    OutOfMemory,
};

/// Stroke options for SVG rendering
pub const StrokeOptions = struct {
    enabled: bool = false,
    width: f32 = 1.0,
};

// =============================================================================
// JavaScript Imports
// =============================================================================

extern "env" fn rasterizeSvgPath(
    path_ptr: [*]const u8,
    path_len: u32,
    device_size: u32,
    viewbox: f32,
    has_fill: bool,
    stroke_width: f32,
    out_buffer: [*]u8,
    buffer_size: u32,
    out_width: *u32,
    out_height: *u32,
    out_offset_x: *i16,
    out_offset_y: *i16,
) bool;

// =============================================================================
// Public API
// =============================================================================

/// Rasterize SVG path data to RGBA buffer (fill only, no stroke)
pub fn rasterize(
    allocator: std.mem.Allocator,
    path_data: []const u8,
    viewbox: f32,
    device_size: u32,
    buffer: []u8,
) RasterizeError!RasterizedSvg {
    return rasterizeWithOptions(allocator, path_data, viewbox, device_size, buffer, true, .{});
}

/// Rasterize SVG path data with fill and stroke options.
/// Output format: R = fill alpha, G = stroke alpha, B = unused, A = combined alpha
pub fn rasterizeWithOptions(
    allocator: std.mem.Allocator,
    path_data: []const u8,
    viewbox: f32,
    device_size: u32,
    buffer: []u8,
    fill: bool,
    stroke: StrokeOptions,
) RasterizeError!RasterizedSvg {
    _ = allocator; // Not needed for web - JS handles memory

    if (path_data.len == 0) return error.EmptyPath;

    const pixel_count = device_size * device_size;
    const required_size = pixel_count * 4;
    if (buffer.len < required_size) return error.BufferTooSmall;

    // Clear buffer (transparent black)
    @memset(buffer[0..required_size], 0);

    var width: u32 = 0;
    var height: u32 = 0;
    var offset_x: i16 = 0;
    var offset_y: i16 = 0;

    const stroke_width: f32 = if (stroke.enabled) stroke.width else 0;

    const success = rasterizeSvgPath(
        path_data.ptr,
        @intCast(path_data.len),
        device_size,
        viewbox,
        fill,
        stroke_width,
        buffer.ptr,
        @intCast(buffer.len),
        &width,
        &height,
        &offset_x,
        &offset_y,
    );

    if (!success) {
        return error.GraphicsError;
    }

    return RasterizedSvg{
        .width = width,
        .height = height,
        .offset_x = offset_x,
        .offset_y = offset_y,
    };
}
