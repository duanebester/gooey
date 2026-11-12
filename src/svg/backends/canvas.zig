//! SVG Rasterizer - Web/Canvas2D-based SVG path rendering
//!
//! Rasterizes SVG icons to RGBA bitmaps via JavaScript's Path2D and Canvas2D APIs.
//! Uses two-channel encoding: R = fill alpha, G = stroke alpha.
//! This allows the shader to apply different colors to fill and stroke.
//!
//! `Path2D` reads only path data, so the icon is parsed here, as the native
//! backends parse it, and handed over as the path data of its commands.

const std = @import("std");
const svg_mod = @import("../path.zig");

pub const RasterizedSvg = struct {
    width: u32,
    height: u32,
    offset_x: i16,
    offset_y: i16,
};

pub const RasterBudget = svg_mod.RasterBudget;

/// Alignment padding before the parsed numbers, the one 4-byte aligned
/// reservation; the path data and the parsed commands are bytes.
const scratch_alignment_slack_bytes: u32 = 3;

/// Bytes one rasterization allocates: the parsed path and the path data the
/// browser draws. The browser flattens curves itself, so `vertex_count_max`
/// does not apply here.
pub fn scratchBytes(budget: RasterBudget, device_size_max: u32) u32 {
    std.debug.assert(device_size_max > 0);
    std.debug.assert(budget.path_bytes_max > 0);
    return RasterBudget.parseBytes(budget.path_bytes_max) +
        RasterBudget.pathDataBytes(budget.path_bytes_max) + scratch_alignment_slack_bytes;
}

pub const RasterizeError = error{
    EmptyPath,
    PathTooComplex,
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

/// Draw `path_data` into a `device_size` square of RGBA pixels at `out_buffer`
/// (`buffer_size` = `device_size² × 4` bytes), with `viewbox` units scaled to
/// it, as CoreGraphics and Cairo do: the stroke is clipped at the square's
/// edge. Returns false if the browser could not draw it.
extern "env" fn rasterizeSvgPath(
    path_ptr: [*]const u8,
    path_len: u32,
    device_size: u32,
    viewbox: f32,
    has_fill: bool,
    stroke_width: f32,
    out_buffer: [*]u8,
    buffer_size: u32,
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
    budget: RasterBudget,
) RasterizeError!RasterizedSvg {
    if (path_data.len == 0) return error.EmptyPath;
    if (path_data.len > budget.path_bytes_max) return error.PathTooComplex;

    const pixel_count = device_size * device_size;
    const required_size = pixel_count * 4;
    if (buffer.len < required_size) return error.BufferTooSmall;

    // Clear buffer (transparent black)
    @memset(buffer[0..required_size], 0);

    const path_data_bytes = RasterBudget.pathDataBytes(@intCast(path_data.len));
    const path_data_buffer = allocator.alloc(u8, path_data_bytes) catch return error.OutOfMemory;
    defer allocator.free(path_data_buffer);

    const browser_path_data = try svg_mod.pathDataBounded(allocator, path_data, path_data_buffer);
    std.debug.assert(browser_path_data.len > 0);
    std.debug.assert(browser_path_data.len <= path_data_buffer.len);

    const stroke_width: f32 = if (stroke.enabled) stroke.width else 0;
    const drawn = rasterizeSvgPath(
        browser_path_data.ptr,
        @intCast(browser_path_data.len),
        device_size,
        viewbox,
        fill,
        stroke_width,
        buffer.ptr,
        required_size,
    );
    if (!drawn) return error.GraphicsError;

    // The browser drew the square the native backends draw, at its origin.
    return RasterizedSvg{
        .width = device_size,
        .height = device_size,
        .offset_x = 0,
        .offset_y = 0,
    };
}
