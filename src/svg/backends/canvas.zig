const std = @import("std");
const svg_mod = @import("../path.zig");

pub const RasterizedSvg = struct {
    width: u32,
    height: u32,
    offset_x: i16,
    offset_y: i16,
};

pub const RasterBudget = svg_mod.RasterBudget;

const scratch_alignment_slack_bytes: u32 = 3;

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

pub const StrokeOptions = struct {
    enabled: bool = false,
    width: f32 = 1.0,
};

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

    return RasterizedSvg{
        .width = device_size,
        .height = device_size,
        .offset_x = 0,
        .offset_y = 0,
    };
}
