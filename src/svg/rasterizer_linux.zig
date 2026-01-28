//! SVG Rasterizer for Linux - Software rendering
//!
//! Rasterizes SVG path data to RGBA buffers using a scanline fill algorithm.
//! Output format: R = fill alpha, G = stroke alpha, B = 0, A = max(fill, stroke)

const std = @import("std");
const svg_mod = @import("../scene/svg.zig");

pub const RasterizedSvg = struct {
    width: u32,
    height: u32,
    offset_x: i16,
    offset_y: i16,
};

pub const RasterizeError = error{
    /// SVG rasterization failed
    PlatformNotSupported,
    /// Failed to allocate memory
    OutOfMemory,
    /// Invalid or empty path data
    EmptyPath,
    /// Graphics error during rasterization
    GraphicsError,
    /// Buffer too small for requested size
    BufferTooSmall,
};

/// Stroke options for SVG rendering
pub const StrokeOptions = struct {
    enabled: bool = false,
    width: f32 = 1.0,
};

/// Edge structure for scanline fill algorithm
const Edge = struct {
    y_min: i32,
    y_max: i32,
    x_at_y_min: f32,
    inv_slope: f32, // dx/dy

    fn lessThan(_: void, a: Edge, b: Edge) bool {
        if (a.y_min != b.y_min) return a.y_min < b.y_min;
        return a.x_at_y_min < b.x_at_y_min;
    }
};

/// Active edge for scanline processing
const ActiveEdge = struct {
    x: f32,
    inv_slope: f32,
    y_max: i32,

    fn lessThan(_: void, a: ActiveEdge, b: ActiveEdge) bool {
        return a.x < b.x;
    }
};

/// Rasterize SVG path data to RGBA buffer (simple version)
pub fn rasterize(
    allocator: std.mem.Allocator,
    path_data: []const u8,
    viewbox: f32,
    device_size: u32,
    buffer: []u8,
) RasterizeError!RasterizedSvg {
    return rasterizeWithOptions(allocator, path_data, viewbox, device_size, buffer, true, .{});
}

/// Rasterize SVG path data with extended options
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

    // Parse SVG path (supports both raw path data and SVG elements like circle, rect, etc.)
    var parser = svg_mod.SvgElementParser.init(allocator);
    var path = svg_mod.SvgPath.init(allocator);
    defer path.deinit();

    parser.parse(&path, path_data) catch return error.EmptyPath;

    if (path.commands.items.len == 0) return error.EmptyPath;

    // Flatten path to polygons
    var points: std.ArrayList(svg_mod.Vec2) = .{};
    defer points.deinit(allocator);
    var polygons: std.ArrayList(svg_mod.IndexSlice) = .{};
    defer polygons.deinit(allocator);

    // Use tolerance based on device size for good quality curves
    const tolerance: f32 = viewbox / @as(f32, @floatFromInt(device_size * 2));
    svg_mod.flattenPath(allocator, &path, tolerance, &points, &polygons) catch return error.OutOfMemory;

    const scale: f32 = @as(f32, @floatFromInt(device_size)) / viewbox;
    const size_i: i32 = @intCast(device_size);

    if (fill and stroke.enabled) {
        // Two-channel mode: fill in R, stroke in G
        const stroke_buffer = allocator.alloc(u8, required_size) catch return error.OutOfMemory;
        defer allocator.free(stroke_buffer);
        @memset(stroke_buffer, 0);

        // Render fill
        renderPolygonsFill(allocator, &points, &polygons, scale, size_i, buffer) catch return error.OutOfMemory;

        // Render stroke
        renderPolygonsStroke(&points, &polygons, scale, size_i, stroke.width, stroke_buffer);

        // Combine: R = fill alpha, G = stroke alpha, A = max
        for (0..pixel_count) |i| {
            const idx = i * 4;
            const fill_a = buffer[idx + 3];
            const stroke_a = stroke_buffer[idx + 3];
            buffer[idx + 0] = fill_a;
            buffer[idx + 1] = stroke_a;
            buffer[idx + 2] = 0;
            buffer[idx + 3] = @max(fill_a, stroke_a);
        }
    } else if (fill) {
        // Fill only
        renderPolygonsFill(allocator, &points, &polygons, scale, size_i, buffer) catch return error.OutOfMemory;

        // R = fill alpha, G = 0
        for (0..pixel_count) |i| {
            const idx = i * 4;
            buffer[idx + 0] = buffer[idx + 3];
            buffer[idx + 1] = 0;
            buffer[idx + 2] = 0;
        }
    } else if (stroke.enabled) {
        // Stroke only
        renderPolygonsStroke(&points, &polygons, scale, size_i, stroke.width, buffer);

        // R = 0, G = stroke alpha
        for (0..pixel_count) |i| {
            const idx = i * 4;
            buffer[idx + 1] = buffer[idx + 3];
            buffer[idx + 0] = 0;
            buffer[idx + 2] = 0;
        }
    }

    return RasterizedSvg{
        .width = device_size,
        .height = device_size,
        .offset_x = 0,
        .offset_y = 0,
    };
}

/// Render polygons with anti-aliased scanline fill algorithm using vertical supersampling
fn renderPolygonsFill(
    allocator: std.mem.Allocator,
    points: *const std.ArrayList(svg_mod.Vec2),
    polygons: *const std.ArrayList(svg_mod.IndexSlice),
    scale: f32,
    size: i32,
    buffer: []u8,
) !void {
    // Number of vertical samples per pixel for anti-aliasing
    const Y_SAMPLES: i32 = 4;
    const Y_SAMPLES_F: f32 = @floatFromInt(Y_SAMPLES);
    const supersample_height = size * Y_SAMPLES;

    // Build edge table for all polygons (at supersampled resolution)
    var edges: std.ArrayList(Edge) = .{};
    defer edges.deinit(allocator);

    for (polygons.items) |poly| {
        const start = poly.start;
        const end = poly.end;
        if (end <= start + 2) continue; // Need at least 3 points

        const pts = points.items[start..end];

        for (0..pts.len) |i| {
            const p0 = pts[i];
            const p1 = pts[(i + 1) % pts.len];

            // Scale to device coordinates (Y is supersampled)
            const x0 = p0.x * scale;
            const y0 = p0.y * scale * Y_SAMPLES_F;
            const x1 = p1.x * scale;
            const y1 = p1.y * scale * Y_SAMPLES_F;

            // Skip horizontal edges (they don't contribute to fill)
            const dy = y1 - y0;
            if (@abs(dy) < 0.0001) continue;

            // Determine which point is top and bottom
            const is_down = y1 > y0;
            const top_x = if (is_down) x0 else x1;
            const top_y = if (is_down) y0 else y1;
            const bot_y = if (is_down) y1 else y0;

            // Convert to scanline coordinates (integer y values at supersample resolution)
            const y_min: i32 = @max(0, @as(i32, @intFromFloat(@ceil(top_y))));
            const y_max: i32 = @min(supersample_height, @as(i32, @intFromFloat(@ceil(bot_y))));

            if (y_min >= y_max) continue;

            // Calculate inverse slope (change in x per unit y)
            const inv_slope = (x1 - x0) / dy;

            // Calculate x at the first scanline
            const scanline_y = @as(f32, @floatFromInt(y_min)) + 0.5;
            const x_at_scanline = top_x + inv_slope * (scanline_y - top_y);

            try edges.append(allocator, .{
                .y_min = y_min,
                .y_max = y_max,
                .x_at_y_min = x_at_scanline,
                .inv_slope = inv_slope,
            });
        }
    }

    if (edges.items.len == 0) return;

    // Sort edges by y_min, then by x
    std.sort.pdq(Edge, edges.items, {}, Edge.lessThan);

    // Active edge table
    var active_edges: std.ArrayList(ActiveEdge) = .{};
    defer active_edges.deinit(allocator);

    // Coverage accumulator for current pixel row
    const size_u: u32 = @intCast(size);
    var row_coverage = allocator.alloc(f32, size_u) catch return error.OutOfMemory;
    defer allocator.free(row_coverage);

    var edge_idx: usize = 0;
    var current_pixel_row: i32 = -1;

    // Scanline loop (at supersample resolution)
    for (0..@as(usize, @intCast(supersample_height))) |y_super_usize| {
        const y_super: i32 = @intCast(y_super_usize);
        const pixel_row: i32 = @divFloor(y_super, Y_SAMPLES);

        // When moving to a new pixel row, write accumulated coverage
        if (pixel_row != current_pixel_row) {
            if (current_pixel_row >= 0 and current_pixel_row < size) {
                const row_offset: usize = @intCast(current_pixel_row);
                for (0..size_u) |x| {
                    const coverage = row_coverage[x] / Y_SAMPLES_F;
                    if (coverage > 0.0) {
                        const alpha: u8 = @intFromFloat(@min(255.0, coverage * 255.0));
                        const idx = (row_offset * size_u + x) * 4;
                        buffer[idx + 3] = @max(buffer[idx + 3], alpha);
                    }
                }
            }
            // Reset coverage for new row
            @memset(row_coverage, 0.0);
            current_pixel_row = pixel_row;
        }

        // Remove edges that end at or before this scanline
        var i: usize = 0;
        while (i < active_edges.items.len) {
            if (active_edges.items[i].y_max <= y_super) {
                _ = active_edges.swapRemove(i);
            } else {
                i += 1;
            }
        }

        // Add edges that start at this scanline
        while (edge_idx < edges.items.len and edges.items[edge_idx].y_min <= y_super) {
            const e = edges.items[edge_idx];
            edge_idx += 1;
            if (e.y_max > y_super) {
                try active_edges.append(allocator, .{
                    .x = e.x_at_y_min + e.inv_slope * @as(f32, @floatFromInt(y_super - e.y_min)),
                    .inv_slope = e.inv_slope,
                    .y_max = e.y_max,
                });
            }
        }

        if (active_edges.items.len < 2) continue;

        // Sort active edges by x coordinate
        std.sort.pdq(ActiveEdge, active_edges.items, {}, ActiveEdge.lessThan);

        // Accumulate coverage between pairs of edges (even-odd rule) with X anti-aliasing
        var pair_idx: usize = 0;
        while (pair_idx + 1 < active_edges.items.len) : (pair_idx += 2) {
            const x0_f = active_edges.items[pair_idx].x;
            const x1_f = active_edges.items[pair_idx + 1].x;

            // Expand bounds to include partial coverage pixels
            const x_start: i32 = @max(0, @as(i32, @intFromFloat(@floor(x0_f))));
            const x_end: i32 = @min(size, @as(i32, @intFromFloat(@ceil(x1_f))));

            if (x_start < x_end) {
                for (@as(usize, @intCast(x_start))..@as(usize, @intCast(x_end))) |x| {
                    const x_f: f32 = @floatFromInt(x);

                    // Calculate coverage: how much of pixel [x, x+1] is covered by [x0_f, x1_f]
                    const left_edge = @max(x_f, x0_f);
                    const right_edge = @min(x_f + 1.0, x1_f);
                    const coverage = @max(0.0, right_edge - left_edge);

                    row_coverage[x] += coverage;
                }
            }
        }

        // Update x coordinates for next scanline
        for (active_edges.items) |*ae| {
            ae.x += ae.inv_slope;
        }
    }

    // Write final row coverage
    if (current_pixel_row >= 0 and current_pixel_row < size) {
        const row_offset: usize = @intCast(current_pixel_row);
        for (0..size_u) |x| {
            const coverage = row_coverage[x] / Y_SAMPLES_F;
            if (coverage > 0.0) {
                const alpha: u8 = @intFromFloat(@min(255.0, coverage * 255.0));
                const idx = (row_offset * size_u + x) * 4;
                buffer[idx + 3] = @max(buffer[idx + 3], alpha);
            }
        }
    }
}

/// Render polygon strokes with anti-aliased lines
fn renderPolygonsStroke(
    points: *const std.ArrayList(svg_mod.Vec2),
    polygons: *const std.ArrayList(svg_mod.IndexSlice),
    scale: f32,
    size: i32,
    stroke_width: f32,
    buffer: []u8,
) void {
    const size_u: u32 = @intCast(size);
    const half_width = stroke_width * 0.5;

    for (polygons.items) |poly| {
        const start = poly.start;
        const end = poly.end;
        if (end <= start + 1) continue;

        const pts = points.items[start..end];

        for (0..pts.len) |i| {
            const p0 = pts[i];
            const p1 = pts[(i + 1) % pts.len];

            const x0 = p0.x * scale;
            const y0 = p0.y * scale;
            const x1 = p1.x * scale;
            const y1 = p1.y * scale;

            drawThickLine(buffer, size_u, x0, y0, x1, y1, half_width);
        }
    }
}

/// Draw an anti-aliased thick line
fn drawThickLine(
    buffer: []u8,
    size: u32,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    half_width: f32,
) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const length = @sqrt(dx * dx + dy * dy);

    if (length < 0.001) return;

    // Normal vector
    const nx = -dy / length;
    const ny = dx / length;

    // Expand bounds by half_width + 1 for anti-aliasing
    const expand = half_width + 1.0;
    const min_x = @max(0, @as(i32, @intFromFloat(@floor(@min(x0, x1) - expand))));
    const max_x = @min(@as(i32, @intCast(size)), @as(i32, @intFromFloat(@ceil(@max(x0, x1) + expand))));
    const min_y = @max(0, @as(i32, @intFromFloat(@floor(@min(y0, y1) - expand))));
    const max_y = @min(@as(i32, @intCast(size)), @as(i32, @intFromFloat(@ceil(@max(y0, y1) + expand))));

    for (@as(usize, @intCast(min_y))..@as(usize, @intCast(max_y))) |py_usize| {
        for (@as(usize, @intCast(min_x))..@as(usize, @intCast(max_x))) |px_usize| {
            const px: f32 = @as(f32, @floatFromInt(px_usize)) + 0.5;
            const py: f32 = @as(f32, @floatFromInt(py_usize)) + 0.5;

            // Distance to line segment
            const dist = distanceToLineSegment(px, py, x0, y0, x1, y1, nx, ny, length);

            if (dist < half_width + 1.0) {
                // Anti-aliased alpha based on distance from edge
                const alpha_f = 1.0 - @max(0.0, (dist - half_width + 0.5));
                const alpha: u8 = @intFromFloat(@min(255.0, @max(0.0, alpha_f * 255.0)));

                if (alpha > 0) {
                    const idx = (py_usize * size + px_usize) * 4;
                    buffer[idx + 3] = @max(buffer[idx + 3], alpha);
                }
            }
        }
    }
}

/// Calculate distance from point to line segment
fn distanceToLineSegment(
    px: f32,
    py: f32,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    nx: f32,
    ny: f32,
    length: f32,
) f32 {
    // Project point onto line
    const dx = px - x0;
    const dy = py - y0;
    const t = (dx * (x1 - x0) + dy * (y1 - y0)) / (length * length);

    if (t < 0) {
        // Before start of segment
        return @sqrt(dx * dx + dy * dy);
    } else if (t > 1) {
        // After end of segment
        const dx2 = px - x1;
        const dy2 = py - y1;
        return @sqrt(dx2 * dx2 + dy2 * dy2);
    } else {
        // Perpendicular distance to line
        return @abs(dx * nx + dy * ny);
    }
}
