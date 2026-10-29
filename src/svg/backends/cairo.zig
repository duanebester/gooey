//! SVG Rasterizer for Linux and Windows - Software rendering
//!
//! Rasterizes SVG path data to RGBA buffers using a scanline fill algorithm.
//! Output format: R = fill alpha, G = stroke alpha, B = 0, A = max(fill, stroke)
//!
//! Every allocation comes from the caller's allocator, reserved up front from
//! `RasterBudget` and the icon's side, and nothing grows after that: the
//! total is exactly what `scratchBytes` reports, so an `SvgAtlas` scratch of
//! that size is never exhausted. A path past its budget fails with
//! `PathTooComplex` before it can use more.

const std = @import("std");
const svg_mod = @import("../path.zig");

const assert = std.debug.assert;

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
    /// The path exceeds `RasterBudget`: too many bytes, or too many vertices
    /// once flattened at this size.
    PathTooComplex,
    /// Graphics error during rasterization
    GraphicsError,
    /// Buffer too small for requested size
    BufferTooSmall,
};

pub const RasterBudget = svg_mod.RasterBudget;

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

/// Alignment padding between the reservations: at most `@alignOf - 1` bytes
/// before each of the eight, all aligned to at most 4.
const scratch_alignment_slack_bytes: u32 = 8 * 3;

/// Bytes one rasterization of an icon at most `device_size_max` pixels on a
/// side allocates: the parsed path, the flattened points and polygons, one
/// edge and one active edge per point (each point starts one segment), a row
/// of coverage, and the stroke buffer used when fill and stroke combine.
pub fn scratchBytes(budget: RasterBudget, device_size_max: u32) u32 {
    assert(device_size_max > 0);
    assert(budget.vertex_count_max > 0);
    const edge_bytes = budget.vertex_count_max * (@sizeOf(Edge) + @sizeOf(ActiveEdge));
    const row_coverage_bytes = device_size_max * @sizeOf(f32);
    const stroke_buffer_bytes = device_size_max * device_size_max * 4;
    return RasterBudget.parseBytes(budget.path_bytes_max) + budget.flattenBytes() +
        edge_bytes + row_coverage_bytes + stroke_buffer_bytes + scratch_alignment_slack_bytes;
}

/// Rasterize SVG path data to RGBA buffer (simple version)
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
    assert(viewbox > 0);
    assert(device_size > 0);
    if (path_data.len == 0) return error.EmptyPath;
    if (path_data.len > budget.path_bytes_max) return error.PathTooComplex;

    const pixel_count = device_size * device_size;
    const required_size = pixel_count * 4;
    if (buffer.len < required_size) return error.BufferTooSmall;

    // Clear buffer (transparent black)
    @memset(buffer[0..required_size], 0);

    // Parse SVG path (supports both raw path data and SVG elements like circle, rect, etc.)
    var path = svg_mod.SvgPath.init(allocator);
    defer path.deinit();
    try svg_mod.parseBounded(allocator, &path, path_data);

    // Flatten to polygons with a tolerance of half a device pixel.
    var points: std.ArrayList(svg_mod.Vec2) = .empty;
    defer points.deinit(allocator);
    var polygons: std.ArrayList(svg_mod.IndexSlice) = .empty;
    defer polygons.deinit(allocator);

    const tolerance: f32 = viewbox / @as(f32, @floatFromInt(device_size * 2));
    try svg_mod.flattenBounded(allocator, &path, tolerance, &points, &polygons, budget);

    const geometry = Geometry{
        .points = &points,
        .polygons = &polygons,
        .scale = @as(f32, @floatFromInt(device_size)) / viewbox,
        .size = @intCast(device_size),
    };
    if (fill and stroke.enabled) {
        try renderFillAndStroke(allocator, &geometry, stroke.width, buffer[0..required_size]);
    } else if (fill) {
        try renderPolygonsFill(allocator, &geometry, buffer);
        moveAlphaToChannel(buffer[0..required_size], 0);
    } else if (stroke.enabled) {
        renderPolygonsStroke(&geometry, stroke.width, buffer);
        moveAlphaToChannel(buffer[0..required_size], 1);
    }

    return RasterizedSvg{
        .width = device_size,
        .height = device_size,
        .offset_x = 0,
        .offset_y = 0,
    };
}

/// A flattened icon and how it maps to device pixels.
const Geometry = struct {
    points: *const std.ArrayList(svg_mod.Vec2),
    polygons: *const std.ArrayList(svg_mod.IndexSlice),
    /// Device pixels per viewbox unit.
    scale: f32,
    /// Icon side in device pixels.
    size: i32,
};

/// Two-channel mode: fill into `buffer`, stroke into a scratch buffer, then
/// R = fill alpha, G = stroke alpha, A = their maximum.
fn renderFillAndStroke(
    allocator: std.mem.Allocator,
    geometry: *const Geometry,
    stroke_width: f32,
    buffer: []u8,
) RasterizeError!void {
    assert(geometry.size > 0);
    const size_u: u32 = @intCast(geometry.size);
    assert(buffer.len == size_u * size_u * 4);
    const stroke_buffer = allocator.alloc(u8, buffer.len) catch return error.OutOfMemory;
    defer allocator.free(stroke_buffer);
    @memset(stroke_buffer, 0);

    try renderPolygonsFill(allocator, geometry, buffer);
    renderPolygonsStroke(geometry, stroke_width, stroke_buffer);

    var index: usize = 0;
    while (index < buffer.len) : (index += 4) {
        const fill_alpha = buffer[index + 3];
        const stroke_alpha = stroke_buffer[index + 3];
        buffer[index + 0] = fill_alpha;
        buffer[index + 1] = stroke_alpha;
        buffer[index + 2] = 0;
        buffer[index + 3] = @max(fill_alpha, stroke_alpha);
    }
    assert(index == buffer.len);
}

/// Single-channel mode: copy each pixel's alpha into `channel` (0 for fill,
/// 1 for stroke) and clear the other two color channels.
fn moveAlphaToChannel(buffer: []u8, channel: u2) void {
    assert(channel <= 1);
    assert(buffer.len % 4 == 0);
    var index: usize = 0;
    while (index < buffer.len) : (index += 4) {
        const alpha = buffer[index + 3];
        buffer[index + 0] = 0;
        buffer[index + 1] = 0;
        buffer[index + 2] = 0;
        buffer[index + channel] = alpha;
    }
    assert(index == buffer.len);
}

/// Vertical samples per pixel for the fill's anti-aliasing.
const fill_samples_y: i32 = 4;

/// Render polygons with anti-aliased scanline fill algorithm using vertical
/// supersampling. Allocates one edge and one active edge per point and a row
/// of coverage, all reserved before the scan, so the scan cannot allocate.
fn renderPolygonsFill(
    allocator: std.mem.Allocator,
    geometry: *const Geometry,
    buffer: []u8,
) RasterizeError!void {
    assert(geometry.size > 0);
    const size_u: u32 = @intCast(geometry.size);
    assert(buffer.len >= size_u * size_u * 4);

    // Each polygon's points start one segment each, and polygons do not share
    // points, so no path has more edges than points.
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(allocator);
    edges.ensureTotalCapacityPrecise(allocator, geometry.points.items.len) catch
        return error.OutOfMemory;
    appendEdges(geometry, &edges);
    if (edges.items.len == 0) return;
    std.sort.pdq(Edge, edges.items, {}, Edge.lessThan);

    var active_edges: std.ArrayList(ActiveEdge) = .empty;
    defer active_edges.deinit(allocator);
    active_edges.ensureTotalCapacityPrecise(allocator, edges.items.len) catch
        return error.OutOfMemory;

    const row_coverage = allocator.alloc(f32, size_u) catch return error.OutOfMemory;
    defer allocator.free(row_coverage);

    scanFill(edges.items, &active_edges, row_coverage, buffer);
}

/// Build the edge table at supersampled resolution, skipping horizontal edges
/// and polygons of fewer than three points. `edges` has room for every point.
fn appendEdges(geometry: *const Geometry, edges: *std.ArrayList(Edge)) void {
    assert(edges.items.len == 0);
    assert(edges.capacity >= geometry.points.items.len);
    const samples_f: f32 = @floatFromInt(fill_samples_y);
    const supersample_height = geometry.size * fill_samples_y;
    const scale = geometry.scale;
    for (geometry.polygons.items) |poly| {
        if (poly.end <= poly.start + 2) continue; // Need at least 3 points
        const pts = geometry.points.items[poly.start..poly.end];
        for (0..pts.len) |i| {
            const p0 = pts[i];
            const p1 = pts[(i + 1) % pts.len];
            // Scale to device coordinates (Y is supersampled)
            const x0 = p0.x * scale;
            const y0 = p0.y * scale * samples_f;
            const x1 = p1.x * scale;
            const y1 = p1.y * scale * samples_f;

            // Skip horizontal edges (they don't contribute to fill)
            const dy = y1 - y0;
            if (@abs(dy) < 0.0001) continue;

            const is_down = y1 > y0;
            const top_x = if (is_down) x0 else x1;
            const top_y = if (is_down) y0 else y1;
            const bot_y = if (is_down) y1 else y0;

            // Integer scanlines at supersample resolution.
            const y_min: i32 = @max(0, @as(i32, @intFromFloat(@ceil(top_y))));
            const y_max: i32 = @min(supersample_height, @as(i32, @intFromFloat(@ceil(bot_y))));
            if (y_min >= y_max) continue;

            const inv_slope = (x1 - x0) / dy;
            const scanline_y = @as(f32, @floatFromInt(y_min)) + 0.5;
            edges.appendAssumeCapacity(.{
                .y_min = y_min,
                .y_max = y_max,
                .x_at_y_min = top_x + inv_slope * (scanline_y - top_y),
                .inv_slope = inv_slope,
            });
        }
    }
    assert(edges.items.len <= geometry.points.items.len);
}

/// Scan the sorted edges one supersampled row at a time, accumulating each
/// pixel row's coverage and writing it to the alpha channel.
fn scanFill(
    edges: []const Edge,
    active_edges: *std.ArrayList(ActiveEdge),
    row_coverage: []f32,
    buffer: []u8,
) void {
    assert(edges.len > 0);
    assert(active_edges.capacity >= edges.len);
    const size: i32 = @intCast(row_coverage.len);
    const supersample_height: usize = @intCast(size * fill_samples_y);
    var edge_index: usize = 0;
    var current_pixel_row: i32 = -1;

    for (0..supersample_height) |y_super_usize| {
        const y_super: i32 = @intCast(y_super_usize);
        const pixel_row: i32 = @divFloor(y_super, fill_samples_y);
        if (pixel_row != current_pixel_row) {
            if (current_pixel_row >= 0) writeRowCoverage(row_coverage, current_pixel_row, buffer);
            @memset(row_coverage, 0.0);
            current_pixel_row = pixel_row;
        }

        // Remove edges that end at or before this scanline. Each pass either
        // removes one or advances, so it is bounded by the active count.
        var i: usize = 0;
        while (i < active_edges.items.len) {
            if (active_edges.items[i].y_max <= y_super) {
                _ = active_edges.swapRemove(i);
            } else {
                i += 1;
            }
        }

        // Add edges that start at this scanline; each edge is added once.
        while (edge_index < edges.len and edges[edge_index].y_min <= y_super) {
            const e = edges[edge_index];
            edge_index += 1;
            if (e.y_max > y_super) {
                active_edges.appendAssumeCapacity(.{
                    .x = e.x_at_y_min + e.inv_slope * @as(f32, @floatFromInt(y_super - e.y_min)),
                    .inv_slope = e.inv_slope,
                    .y_max = e.y_max,
                });
            }
        }
        assert(edge_index <= edges.len);
        if (active_edges.items.len < 2) continue;

        std.sort.pdq(ActiveEdge, active_edges.items, {}, ActiveEdge.lessThan);
        accumulateSpans(active_edges.items, row_coverage);
        for (active_edges.items) |*active| active.x += active.inv_slope;
    }
    if (current_pixel_row >= 0) writeRowCoverage(row_coverage, current_pixel_row, buffer);
}

/// Add the horizontal coverage between each pair of sorted active edges
/// (even-odd rule), anti-aliased in x.
fn accumulateSpans(active_edges: []const ActiveEdge, row_coverage: []f32) void {
    assert(active_edges.len >= 2);
    assert(row_coverage.len > 0);
    const size_f: f32 = @floatFromInt(row_coverage.len);
    var pair_index: usize = 0;
    while (pair_index + 1 < active_edges.len) : (pair_index += 2) {
        const x0_f = active_edges[pair_index].x;
        const x1_f = active_edges[pair_index + 1].x;

        // Clamp in float space first: `@intFromFloat` of NaN, infinity, or an
        // out-of-range value is illegal behavior.
        const x_start_f = @max(@as(f32, 0.0), @floor(x0_f));
        const x_end_f = @min(size_f, @ceil(x1_f));
        if (!(x_start_f < x_end_f)) continue;

        const x_start: usize = @intFromFloat(x_start_f);
        const x_end: usize = @intFromFloat(x_end_f);
        assert(x_end <= row_coverage.len);
        for (x_start..x_end) |x| {
            const x_f: f32 = @floatFromInt(x);
            // How much of pixel [x, x+1] lies within [x0_f, x1_f].
            const left_edge = @max(x_f, x0_f);
            const right_edge = @min(x_f + 1.0, x1_f);
            row_coverage[x] += @max(0.0, right_edge - left_edge);
        }
    }
}

/// Write one pixel row's accumulated coverage into the alpha channel, keeping
/// the larger of the existing and new alpha.
fn writeRowCoverage(row_coverage: []const f32, pixel_row: i32, buffer: []u8) void {
    assert(pixel_row >= 0);
    const size_u: usize = row_coverage.len;
    const row: usize = @intCast(pixel_row);
    if (row >= size_u) return;
    assert(buffer.len >= size_u * size_u * 4);
    const samples_f: f32 = @floatFromInt(fill_samples_y);
    for (row_coverage, 0..) |sum, x| {
        const coverage = sum / samples_f;
        if (coverage > 0.0) {
            const alpha: u8 = @intFromFloat(@min(255.0, coverage * 255.0));
            const index = (row * size_u + x) * 4;
            buffer[index + 3] = @max(buffer[index + 3], alpha);
        }
    }
}

/// Render polygon strokes with anti-aliased lines
fn renderPolygonsStroke(geometry: *const Geometry, stroke_width: f32, buffer: []u8) void {
    assert(geometry.size > 0);
    assert(stroke_width >= 0);
    const points = geometry.points;
    const scale = geometry.scale;
    const size_u: u32 = @intCast(geometry.size);
    const half_width = stroke_width * 0.5;

    const size_f: f32 = @floatFromInt(geometry.size);

    for (geometry.polygons.items) |poly| {
        const start = poly.start;
        const end = poly.end;
        if (end <= start + 1) continue;

        const pts = points.items[start..end];

        // For closed subpaths (explicit Z command), draw all N segments
        // including the closing segment from last point back to first.
        // For open subpaths (arcs, curves without Z), draw only N-1
        // segments — do NOT connect the endpoints.
        const segment_count: usize = if (poly.closed) pts.len else pts.len -| 1;

        for (0..segment_count) |i| {
            const p0 = pts[i];
            const p1 = pts[(i + 1) % pts.len];

            const x0 = p0.x * scale;
            const y0 = p0.y * scale;
            const x1 = p1.x * scale;
            const y1 = p1.y * scale;

            // Skip lines with NaN/Inf coordinates or entirely outside the buffer
            if (!std.math.isFinite(x0) or !std.math.isFinite(y0) or
                !std.math.isFinite(x1) or !std.math.isFinite(y1)) continue;
            if (@min(x0, x1) > size_f + half_width or @max(x0, x1) < -half_width) continue;
            if (@min(y0, y1) > size_f + half_width or @max(y0, y1) < -half_width) continue;

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
    const size_f: f32 = @floatFromInt(size);

    // Clamp all four bounds to [0, size] using floats first.
    // This prevents negative values from ever reaching @intFromFloat → usize,
    // where they would overflow and crash.
    const min_x_f = @max(@as(f32, 0.0), @floor(@min(x0, x1) - expand));
    const max_x_f = @min(size_f, @ceil(@max(x0, x1) + expand));
    const min_y_f = @max(@as(f32, 0.0), @floor(@min(y0, y1) - expand));
    const max_y_f = @min(size_f, @ceil(@max(y0, y1) + expand));

    // Early exit when bounding box is empty or any coordinate is NaN.
    // Using negated comparisons so NaN (which fails all ordered comparisons)
    // correctly triggers the early return.
    if (!(min_x_f < max_x_f) or !(min_y_f < max_y_f)) return;

    const min_x: usize = @intFromFloat(min_x_f);
    const max_x: usize = @intFromFloat(max_x_f);
    const min_y: usize = @intFromFloat(min_y_f);
    const max_y: usize = @intFromFloat(max_y_f);

    std.debug.assert(min_x < max_x);
    std.debug.assert(min_y < max_y);
    std.debug.assert(max_x <= size);
    std.debug.assert(max_y <= size);

    for (min_y..max_y) |py_usize| {
        for (min_x..max_x) |px_usize| {
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
