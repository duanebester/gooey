//! SVG Rasterizer - CoreGraphics-based SVG path rendering
//!
//! Rasterizes SVG path data to RGBA bitmaps at device resolution.
//! Produces white-on-transparent alpha masks for shader tinting.

const std = @import("std");
const svg_mod = @import("../core/svg.zig");

const cg = @cImport({
    @cInclude("CoreGraphics/CoreGraphics.h");
});

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

/// Rasterize SVG path data to RGBA buffer
pub fn rasterize(
    allocator: std.mem.Allocator,
    path_data: []const u8,
    viewbox: f32,
    device_size: u32,
    buffer: []u8,
) RasterizeError!RasterizedSvg {
    return rasterizeWithOptions(allocator, path_data, viewbox, device_size, buffer, true, .{});
}

/// Rasterize SVG path data with fill and stroke options
pub fn rasterizeWithOptions(
    allocator: std.mem.Allocator,
    path_data: []const u8,
    viewbox: f32,
    device_size: u32,
    buffer: []u8,
    fill: bool,
    stroke: StrokeOptions,
) RasterizeError!RasterizedSvg {
    if (path_data.len == 0) return error.EmptyPath;

    const required_size = device_size * device_size * 4;
    if (buffer.len < required_size) return error.BufferTooSmall;

    // Clear buffer (transparent black)
    @memset(buffer[0..required_size], 0);

    // Parse SVG path
    var parser = svg_mod.PathParser.init(allocator);
    var path = svg_mod.SvgPath.init(allocator);
    defer path.deinit();

    parser.parse(&path, path_data) catch return error.EmptyPath;
    if (path.commands.items.len == 0) return error.EmptyPath;

    // Flatten to points
    var points = std.ArrayList(svg_mod.Vec2){};
    defer points.deinit(allocator);
    var polygons = std.ArrayList(svg_mod.IndexSlice){};
    defer polygons.deinit(allocator);

    svg_mod.flattenPath(allocator, &path, 0.5, &points, &polygons) catch return error.OutOfMemory;

    if (points.items.len < 2) return error.EmptyPath;
    // For stroke-only, we need at least 2 points (a line)
    if (fill and (points.items.len < 3 or polygons.items.len == 0)) return error.EmptyPath;

    // Create CoreGraphics context
    const color_space = cg.CGColorSpaceCreateDeviceRGB();
    if (color_space == null) return error.GraphicsError;
    defer cg.CGColorSpaceRelease(color_space);

    const context = cg.CGBitmapContextCreate(
        buffer.ptr,
        device_size,
        device_size,
        8,
        device_size * 4,
        color_space,
        cg.kCGImageAlphaPremultipliedLast,
    );
    if (context == null) return error.GraphicsError;
    defer cg.CGContextRelease(context);

    // Enable antialiasing
    cg.CGContextSetAllowsAntialiasing(context, true);
    cg.CGContextSetShouldAntialias(context, true);

    // Transform: flip Y, scale viewbox to device size
    const scale: f64 = @as(f64, @floatFromInt(device_size)) / @as(f64, viewbox);
    cg.CGContextTranslateCTM(context, 0, @floatFromInt(device_size));
    cg.CGContextScaleCTM(context, scale, -scale);

    // Build the path
    for (polygons.items) |poly| {
        const pts = points.items[poly.start..poly.end];
        if (pts.len < 2) continue;

        cg.CGContextBeginPath(context);
        cg.CGContextMoveToPoint(context, pts[0].x, pts[0].y);

        for (pts[1..]) |pt| {
            cg.CGContextAddLineToPoint(context, pt.x, pt.y);
        }

        if (fill) {
            cg.CGContextClosePath(context);
        }
    }

    // Set colors to white (alpha mask - tint applied in shader)
    cg.CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0);
    cg.CGContextSetRGBStrokeColor(context, 1.0, 1.0, 1.0, 1.0);

    // Draw based on options
    if (fill and stroke.enabled) {
        cg.CGContextSetLineWidth(context, stroke.width);
        cg.CGContextSetLineCap(context, cg.kCGLineCapRound);
        cg.CGContextSetLineJoin(context, cg.kCGLineJoinRound);
        cg.CGContextDrawPath(context, cg.kCGPathFillStroke);
    } else if (fill) {
        cg.CGContextFillPath(context);
    } else if (stroke.enabled) {
        cg.CGContextSetLineWidth(context, stroke.width);
        cg.CGContextSetLineCap(context, cg.kCGLineCapRound);
        cg.CGContextSetLineJoin(context, cg.kCGLineJoinRound);
        cg.CGContextStrokePath(context);
    }

    return RasterizedSvg{
        .width = device_size,
        .height = device_size,
        .offset_x = 0,
        .offset_y = 0,
    };
}
