//! SVG Rasterizer - CoreGraphics-based SVG path rendering
//!
//! Rasterizes SVG path data to RGBA bitmaps at device resolution.
//! Uses two-channel encoding: R = fill alpha, G = stroke alpha.
//! This allows the shader to apply different colors to fill and stroke.
//!
//! Key optimization: Builds CGPath directly from SVG commands, preserving
//! bezier curves for native CoreGraphics rendering with optimal anti-aliasing.

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

/// Build a CGPath directly from parsed SVG commands - preserves beziers for native CG rendering
fn buildCGPathFromCommands(
    path: *const svg_mod.SvgPath,
    close_subpaths: bool,
) ?cg.CGMutablePathRef {
    const cg_path = cg.CGPathCreateMutable();
    if (cg_path == null) return null;

    var cur_pt = svg_mod.Vec2{ .x = 0, .y = 0 };
    var subpath_start = svg_mod.Vec2{ .x = 0, .y = 0 };
    var last_control_pt: ?svg_mod.Vec2 = null;
    var data_idx: usize = 0;
    var in_subpath = false;

    for (path.commands.items) |cmd| {
        switch (cmd) {
            .move_to => {
                // Close previous subpath if requested
                if (close_subpaths and in_subpath) {
                    cg.CGPathCloseSubpath(cg_path);
                }
                const x = path.data.items[data_idx];
                const y = path.data.items[data_idx + 1];
                data_idx += 2;
                cg.CGPathMoveToPoint(cg_path, null, x, y);
                cur_pt = .{ .x = x, .y = y };
                subpath_start = cur_pt;
                last_control_pt = null;
                in_subpath = true;
            },
            .move_to_rel => {
                if (close_subpaths and in_subpath) {
                    cg.CGPathCloseSubpath(cg_path);
                }
                const x = cur_pt.x + path.data.items[data_idx];
                const y = cur_pt.y + path.data.items[data_idx + 1];
                data_idx += 2;
                cg.CGPathMoveToPoint(cg_path, null, x, y);
                cur_pt = .{ .x = x, .y = y };
                subpath_start = cur_pt;
                last_control_pt = null;
                in_subpath = true;
            },
            .line_to => {
                const x = path.data.items[data_idx];
                const y = path.data.items[data_idx + 1];
                data_idx += 2;
                cg.CGPathAddLineToPoint(cg_path, null, x, y);
                cur_pt = .{ .x = x, .y = y };
                last_control_pt = null;
            },
            .line_to_rel => {
                const x = cur_pt.x + path.data.items[data_idx];
                const y = cur_pt.y + path.data.items[data_idx + 1];
                data_idx += 2;
                cg.CGPathAddLineToPoint(cg_path, null, x, y);
                cur_pt = .{ .x = x, .y = y };
                last_control_pt = null;
            },
            .horiz_line_to => {
                const x = path.data.items[data_idx];
                data_idx += 1;
                cg.CGPathAddLineToPoint(cg_path, null, x, cur_pt.y);
                cur_pt.x = x;
                last_control_pt = null;
            },
            .horiz_line_to_rel => {
                const x = cur_pt.x + path.data.items[data_idx];
                data_idx += 1;
                cg.CGPathAddLineToPoint(cg_path, null, x, cur_pt.y);
                cur_pt.x = x;
                last_control_pt = null;
            },
            .vert_line_to => {
                const y = path.data.items[data_idx];
                data_idx += 1;
                cg.CGPathAddLineToPoint(cg_path, null, cur_pt.x, y);
                cur_pt.y = y;
                last_control_pt = null;
            },
            .vert_line_to_rel => {
                const y = cur_pt.y + path.data.items[data_idx];
                data_idx += 1;
                cg.CGPathAddLineToPoint(cg_path, null, cur_pt.x, y);
                cur_pt.y = y;
                last_control_pt = null;
            },
            .curve_to => {
                const cx1 = path.data.items[data_idx];
                const cy1 = path.data.items[data_idx + 1];
                const cx2 = path.data.items[data_idx + 2];
                const cy2 = path.data.items[data_idx + 3];
                const x = path.data.items[data_idx + 4];
                const y = path.data.items[data_idx + 5];
                data_idx += 6;
                cg.CGPathAddCurveToPoint(cg_path, null, cx1, cy1, cx2, cy2, x, y);
                cur_pt = .{ .x = x, .y = y };
                last_control_pt = .{ .x = cx2, .y = cy2 };
            },
            .curve_to_rel => {
                const cx1 = cur_pt.x + path.data.items[data_idx];
                const cy1 = cur_pt.y + path.data.items[data_idx + 1];
                const cx2 = cur_pt.x + path.data.items[data_idx + 2];
                const cy2 = cur_pt.y + path.data.items[data_idx + 3];
                const x = cur_pt.x + path.data.items[data_idx + 4];
                const y = cur_pt.y + path.data.items[data_idx + 5];
                data_idx += 6;
                cg.CGPathAddCurveToPoint(cg_path, null, cx1, cy1, cx2, cy2, x, y);
                cur_pt = .{ .x = x, .y = y };
                last_control_pt = .{ .x = cx2, .y = cy2 };
            },
            .smooth_curve_to => {
                // Reflect last control point
                const cx1 = if (last_control_pt) |lcp|
                    2 * cur_pt.x - lcp.x
                else
                    cur_pt.x;
                const cy1 = if (last_control_pt) |lcp|
                    2 * cur_pt.y - lcp.y
                else
                    cur_pt.y;
                const cx2 = path.data.items[data_idx];
                const cy2 = path.data.items[data_idx + 1];
                const x = path.data.items[data_idx + 2];
                const y = path.data.items[data_idx + 3];
                data_idx += 4;
                cg.CGPathAddCurveToPoint(cg_path, null, cx1, cy1, cx2, cy2, x, y);
                cur_pt = .{ .x = x, .y = y };
                last_control_pt = .{ .x = cx2, .y = cy2 };
            },
            .smooth_curve_to_rel => {
                const cx1 = if (last_control_pt) |lcp|
                    2 * cur_pt.x - lcp.x
                else
                    cur_pt.x;
                const cy1 = if (last_control_pt) |lcp|
                    2 * cur_pt.y - lcp.y
                else
                    cur_pt.y;
                const cx2 = cur_pt.x + path.data.items[data_idx];
                const cy2 = cur_pt.y + path.data.items[data_idx + 1];
                const x = cur_pt.x + path.data.items[data_idx + 2];
                const y = cur_pt.y + path.data.items[data_idx + 3];
                data_idx += 4;
                cg.CGPathAddCurveToPoint(cg_path, null, cx1, cy1, cx2, cy2, x, y);
                cur_pt = .{ .x = x, .y = y };
                last_control_pt = .{ .x = cx2, .y = cy2 };
            },
            .quad_to => {
                const cx = path.data.items[data_idx];
                const cy = path.data.items[data_idx + 1];
                const x = path.data.items[data_idx + 2];
                const y = path.data.items[data_idx + 3];
                data_idx += 4;
                cg.CGPathAddQuadCurveToPoint(cg_path, null, cx, cy, x, y);
                cur_pt = .{ .x = x, .y = y };
                last_control_pt = .{ .x = cx, .y = cy };
            },
            .quad_to_rel => {
                const cx = cur_pt.x + path.data.items[data_idx];
                const cy = cur_pt.y + path.data.items[data_idx + 1];
                const x = cur_pt.x + path.data.items[data_idx + 2];
                const y = cur_pt.y + path.data.items[data_idx + 3];
                data_idx += 4;
                cg.CGPathAddQuadCurveToPoint(cg_path, null, cx, cy, x, y);
                cur_pt = .{ .x = x, .y = y };
                last_control_pt = .{ .x = cx, .y = cy };
            },
            .smooth_quad_to => {
                const cx = if (last_control_pt) |lcp|
                    2 * cur_pt.x - lcp.x
                else
                    cur_pt.x;
                const cy = if (last_control_pt) |lcp|
                    2 * cur_pt.y - lcp.y
                else
                    cur_pt.y;
                const x = path.data.items[data_idx];
                const y = path.data.items[data_idx + 1];
                data_idx += 2;
                cg.CGPathAddQuadCurveToPoint(cg_path, null, cx, cy, x, y);
                cur_pt = .{ .x = x, .y = y };
                last_control_pt = .{ .x = cx, .y = cy };
            },
            .smooth_quad_to_rel => {
                const cx = if (last_control_pt) |lcp|
                    2 * cur_pt.x - lcp.x
                else
                    cur_pt.x;
                const cy = if (last_control_pt) |lcp|
                    2 * cur_pt.y - lcp.y
                else
                    cur_pt.y;
                const x = cur_pt.x + path.data.items[data_idx];
                const y = cur_pt.y + path.data.items[data_idx + 1];
                data_idx += 2;
                cg.CGPathAddQuadCurveToPoint(cg_path, null, cx, cy, x, y);
                cur_pt = .{ .x = x, .y = y };
                last_control_pt = .{ .x = cx, .y = cy };
            },
            .arc_to, .arc_to_rel => {
                const is_rel = cmd == .arc_to_rel;
                const rx = path.data.items[data_idx];
                const ry = path.data.items[data_idx + 1];
                const x_rot = path.data.items[data_idx + 2];
                const large_arc = path.data.items[data_idx + 3] > 0.5;
                const sweep = path.data.items[data_idx + 4] > 0.5;
                const x = if (is_rel) cur_pt.x + path.data.items[data_idx + 5] else path.data.items[data_idx + 5];
                const y = if (is_rel) cur_pt.y + path.data.items[data_idx + 6] else path.data.items[data_idx + 6];
                data_idx += 7;

                // Convert SVG arc to CGPath arc using center parameterization
                addArcToPath(cg_path, cur_pt.x, cur_pt.y, rx, ry, x_rot, large_arc, sweep, x, y);
                cur_pt = .{ .x = x, .y = y };
                last_control_pt = null;
            },
            .close_path => {
                cg.CGPathCloseSubpath(cg_path);
                cur_pt = subpath_start;
                last_control_pt = null;
                in_subpath = false;
            },
        }
    }

    // Close final subpath if requested and still open
    if (close_subpaths and in_subpath) {
        cg.CGPathCloseSubpath(cg_path);
    }

    return cg_path;
}

/// Convert SVG arc parameters to CGPath bezier approximation
fn addArcToPath(
    path: cg.CGMutablePathRef,
    x0: f32,
    y0: f32,
    rx_in: f32,
    ry_in: f32,
    x_rotation_deg: f32,
    large_arc: bool,
    sweep: bool,
    x1: f32,
    y1: f32,
) void {
    // Handle degenerate cases
    if (rx_in == 0 or ry_in == 0) {
        cg.CGPathAddLineToPoint(path, null, x1, y1);
        return;
    }

    var rx = @abs(rx_in);
    var ry = @abs(ry_in);

    const phi = x_rotation_deg * std.math.pi / 180.0;
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);

    // Step 1: Compute (x1', y1') - transformed midpoint
    const dx = (x0 - x1) / 2.0;
    const dy = (y0 - y1) / 2.0;
    const x1p = cos_phi * dx + sin_phi * dy;
    const y1p = -sin_phi * dx + cos_phi * dy;

    // Step 2: Compute center point (cx', cy')
    var lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1.0) {
        const sqrt_lambda = @sqrt(lambda);
        rx *= sqrt_lambda;
        ry *= sqrt_lambda;
        lambda = 1.0;
    }

    const rx_sq = rx * rx;
    const ry_sq = ry * ry;
    const x1p_sq = x1p * x1p;
    const y1p_sq = y1p * y1p;

    var sq = (rx_sq * ry_sq - rx_sq * y1p_sq - ry_sq * x1p_sq) / (rx_sq * y1p_sq + ry_sq * x1p_sq);
    if (sq < 0) sq = 0;
    var coef = @sqrt(sq);
    if (large_arc == sweep) coef = -coef;

    const cxp = coef * rx * y1p / ry;
    const cyp = -coef * ry * x1p / rx;

    // Step 3: Compute center point (cx, cy)
    const cx = cos_phi * cxp - sin_phi * cyp + (x0 + x1) / 2.0;
    const cy = sin_phi * cxp + cos_phi * cyp + (y0 + y1) / 2.0;

    // Step 4: Compute angles
    const ux = (x1p - cxp) / rx;
    const uy = (y1p - cyp) / ry;
    const vx = (-x1p - cxp) / rx;
    const vy = (-y1p - cyp) / ry;

    const n = @sqrt(ux * ux + uy * uy);
    var theta1 = std.math.acos(std.math.clamp(ux / n, -1.0, 1.0));
    if (uy < 0) theta1 = -theta1;

    const dot = ux * vx + uy * vy;
    const len = @sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
    var dtheta = std.math.acos(std.math.clamp(dot / len, -1.0, 1.0));
    if (ux * vy - uy * vx < 0) dtheta = -dtheta;

    if (sweep and dtheta < 0) {
        dtheta += 2.0 * std.math.pi;
    } else if (!sweep and dtheta > 0) {
        dtheta -= 2.0 * std.math.pi;
    }

    // Approximate arc with cubic beziers (max 90 degrees per segment)
    const num_segments: u32 = @max(1, @as(u32, @intFromFloat(@ceil(@abs(dtheta) / (std.math.pi / 2.0)))));
    const segment_angle = dtheta / @as(f32, @floatFromInt(num_segments));

    var angle = theta1;
    for (0..num_segments) |_| {
        const next_angle = angle + segment_angle;
        addArcSegment(path, cx, cy, rx, ry, cos_phi, sin_phi, angle, next_angle);
        angle = next_angle;
    }
}

/// Add a single arc segment (up to 90 degrees) as a cubic bezier
fn addArcSegment(
    path: cg.CGMutablePathRef,
    cx: f32,
    cy: f32,
    rx: f32,
    ry: f32,
    cos_phi: f32,
    sin_phi: f32,
    angle1: f32,
    angle2: f32,
) void {
    const dangle = angle2 - angle1;
    const t = @tan(dangle / 2.0);
    const alpha = @sin(dangle) * (@sqrt(4.0 + 3.0 * t * t) - 1.0) / 3.0;

    const cos1 = @cos(angle1);
    const sin1 = @sin(angle1);
    const cos2 = @cos(angle2);
    const sin2 = @sin(angle2);

    // End point of this segment (start of next)
    const ex = rx * cos2;
    const ey = ry * sin2;
    const x2 = cx + cos_phi * ex - sin_phi * ey;
    const y2 = cy + sin_phi * ex + cos_phi * ey;

    // Control points
    const dx1 = -rx * sin1;
    const dy1 = ry * cos1;
    const cp1x = cx + cos_phi * (rx * cos1 + alpha * dx1) - sin_phi * (ry * sin1 + alpha * dy1);
    const cp1y = cy + sin_phi * (rx * cos1 + alpha * dx1) + cos_phi * (ry * sin1 + alpha * dy1);

    const dx2 = -rx * sin2;
    const dy2 = ry * cos2;
    const cp2x = cx + cos_phi * (rx * cos2 - alpha * dx2) - sin_phi * (ry * sin2 - alpha * dy2);
    const cp2y = cy + sin_phi * (rx * cos2 - alpha * dx2) + cos_phi * (ry * sin2 - alpha * dy2);

    cg.CGPathAddCurveToPoint(path, null, cp1x, cp1y, cp2x, cp2y, x2, y2);
}

/// Setup a bitmap context with standard settings
fn createBitmapContext(
    buffer: [*]u8,
    device_size: u32,
    color_space: cg.CGColorSpaceRef,
    scale: f64,
) ?cg.CGContextRef {
    const ctx = cg.CGBitmapContextCreate(
        buffer,
        device_size,
        device_size,
        8,
        device_size * 4,
        color_space,
        cg.kCGImageAlphaPremultipliedLast,
    );
    if (ctx == null) return null;

    cg.CGContextSetAllowsAntialiasing(ctx, true);
    cg.CGContextSetShouldAntialias(ctx, true);
    cg.CGContextTranslateCTM(ctx, 0, @floatFromInt(device_size));
    cg.CGContextScaleCTM(ctx, scale, -scale);

    return ctx;
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
    if (path_data.len == 0) return error.EmptyPath;

    const pixel_count = device_size * device_size;
    const required_size = pixel_count * 4;
    if (buffer.len < required_size) return error.BufferTooSmall;

    // Clear buffer (transparent black)
    @memset(buffer[0..required_size], 0);

    // Parse SVG path
    var parser = svg_mod.PathParser.init(allocator);
    var path = svg_mod.SvgPath.init(allocator);
    defer path.deinit();

    parser.parse(&path, path_data) catch return error.EmptyPath;

    if (path.commands.items.len == 0) return error.EmptyPath;

    // Create color space once
    const color_space = cg.CGColorSpaceCreateDeviceRGB();
    if (color_space == null) return error.GraphicsError;
    defer cg.CGColorSpaceRelease(color_space);

    const scale: f64 = @as(f64, @floatFromInt(device_size)) / @as(f64, viewbox);

    if (fill and stroke.enabled) {
        // Two-channel mode: need separate paths - closed for fill, open for stroke
        const fill_path = buildCGPathFromCommands(&path, true) orelse return error.GraphicsError;
        defer cg.CGPathRelease(fill_path);
        const stroke_path = buildCGPathFromCommands(&path, false) orelse return error.GraphicsError;
        defer cg.CGPathRelease(stroke_path);

        const stroke_buffer = allocator.alloc(u8, required_size) catch return error.OutOfMemory;
        defer allocator.free(stroke_buffer);
        @memset(stroke_buffer, 0);

        // Render fill directly to output buffer
        {
            const ctx = createBitmapContext(buffer.ptr, device_size, color_space, scale) orelse return error.GraphicsError;
            defer cg.CGContextRelease(ctx);

            cg.CGContextAddPath(ctx, fill_path);
            cg.CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
            cg.CGContextFillPath(ctx);
        }

        // Render stroke to temp buffer (using open path)
        {
            const ctx = createBitmapContext(stroke_buffer.ptr, device_size, color_space, scale) orelse return error.GraphicsError;
            defer cg.CGContextRelease(ctx);

            cg.CGContextAddPath(ctx, stroke_path);
            cg.CGContextSetRGBStrokeColor(ctx, 1.0, 1.0, 1.0, 1.0);
            // Stroke width is in device pixels, but context is scaled, so convert to viewbox units
            cg.CGContextSetLineWidth(ctx, stroke.width / @as(f32, @floatCast(scale)));
            cg.CGContextSetLineCap(ctx, cg.kCGLineCapRound);
            cg.CGContextSetLineJoin(ctx, cg.kCGLineJoinRound);
            cg.CGContextStrokePath(ctx);
        }

        // Single pass: R = fill alpha, G = stroke alpha, A = max
        for (0..pixel_count) |i| {
            const idx = i * 4;
            const fill_a = buffer[idx + 3];
            const stroke_a = stroke_buffer[idx + 3];
            buffer[idx + 0] = fill_a;
            buffer[idx + 1] = stroke_a;
            buffer[idx + 2] = 0;
            buffer[idx + 3] = @max(fill_a, stroke_a);
        }
    } else {
        // Single channel mode (fill-only or stroke-only)
        const cg_path = buildCGPathFromCommands(&path, fill) orelse return error.GraphicsError;
        defer cg.CGPathRelease(cg_path);

        const ctx = createBitmapContext(buffer.ptr, device_size, color_space, scale) orelse return error.GraphicsError;
        defer cg.CGContextRelease(ctx);

        cg.CGContextAddPath(ctx, cg_path);

        if (fill) {
            cg.CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
            cg.CGContextFillPath(ctx);

            // R = fill alpha, G = 0
            for (0..pixel_count) |i| {
                const idx = i * 4;
                buffer[idx + 0] = buffer[idx + 3];
                buffer[idx + 1] = 0;
                buffer[idx + 2] = 0;
            }
        } else if (stroke.enabled) {
            cg.CGContextSetRGBStrokeColor(ctx, 1.0, 1.0, 1.0, 1.0);
            // Stroke width is in device pixels, but context is scaled, so convert to viewbox units
            cg.CGContextSetLineWidth(ctx, stroke.width / @as(f32, @floatCast(scale)));
            cg.CGContextSetLineCap(ctx, cg.kCGLineCapRound);
            cg.CGContextSetLineJoin(ctx, cg.kCGLineJoinRound);
            cg.CGContextStrokePath(ctx);

            // R = 0, G = stroke alpha
            for (0..pixel_count) |i| {
                const idx = i * 4;
                buffer[idx + 1] = buffer[idx + 3];
                buffer[idx + 0] = 0;
                buffer[idx + 2] = 0;
            }
        }
    }

    return RasterizedSvg{
        .width = device_size,
        .height = device_size,
        .offset_x = 0,
        .offset_y = 0,
    };
}
