//! Mesh rasterization for the CPU renderer: path triangles, polyline strips,
//! and point clouds.
//!
//! These draw the packed frame's three mesh pipelines (`triangles`,
//! `strip_expanded`, and `point_instanced`), each in one solid colour:
//!
//! - Triangles and strip segments are convex polygons. The Vulkan renderer
//!   draws them with 4x MSAA, so coverage here is the share of the four
//!   standard Vulkan sample locations inside the shape, and color is
//!   evaluated once per pixel at its center, as a fragment shader is. A
//!   sample exactly on an edge follows Vulkan's top-left rule: it is inside
//!   on a top or left edge and outside on a bottom or right edge, so draws
//!   that share an edge cover each sample on it exactly once.
//! - All polygons of one draw (one path or one polyline) accumulate into one
//!   per-row sample mask before the row is shaded. Two triangles sharing an
//!   edge therefore add up to full coverage instead of blending twice, which
//!   is what MSAA's per-sample resolve gives on the GPU.
//! - Points are quads whose fragment shader fades alpha across the circle's
//!   edge (`pointFalloff`, the same falloff as `mesh.frag` and Metal's point
//!   shaders), so they need no sample coverage: the shader alone decides
//!   every pixel.
//!
//! Every coordinate here is in device pixels; `renderer.zig` converts from
//! logical pixels. Nothing allocates: polygons, bucket chains, and the row
//! mask live in a `Scratch` the renderer reserves at initialization.
//!
//! ## Resource sketch (CLAUDE.md §7)
//!
//! - Memory: `Scratch` holds `polygon_count_max` polygons (40 B each) plus two
//!   `u32` indices per polygon, one `u32` bucket head per framebuffer row, and
//!   one mask byte per framebuffer column. At `.standard` limits that is
//!   8,191 polygons (the longest polyline) and a 3840x2160 framebuffer: about
//!   400 KiB per window.
//! - CPU per draw: one pass over the polygons to bucket them by first row,
//!   then per covered row one interval evaluation per active polygon per
//!   sample row (four), one mask write per covered sample, and one shade per
//!   covered pixel. Work is O(polygons + rows + covered samples); a polygon is
//!   visited only on the rows it spans (an active edge table).
//! - Points: one shade per pixel inside each point's square.
//! - The paint budget's mesh point limits (`PaintLimits.path_vertex_count_frame_max`
//!   and friends, enforced when the frame is built) bound the polygons and
//!   points per frame, and the framebuffer bounds the pixels per polygon.

const std = @import("std");
const raster = @import("raster.zig");

const assert = std.debug.assert;
const Premul = raster.Premul;
const Span = raster.Span;
const Target = raster.Target;

/// Vulkan's standard 4x sample locations, as offsets inside a pixel. Each sits
/// on its own sub-row, so one interval per polygon per sub-row covers it.
const sample_x = [sample_count]f32{ 0.375, 0.875, 0.125, 0.625 };
const sample_y = [sample_count]f32{ 0.125, 0.375, 0.625, 0.875 };
const sample_count: u8 = 4;

/// `round(covered * 255 / 4)`, indexed by the number of covered samples.
const coverage_bytes = [sample_count + 1]u8{ 0, 64, 128, 191, 255 };

/// Sentinel ending a bucket chain.
const chain_end: u32 = std.math.maxInt(u32);

/// A convex polygon in device pixels: a triangle or a strip segment's quad.
pub const Polygon = struct {
    x: [4]f32,
    y: [4]f32,
    vertex_count: u8,
    /// First and last pixel rows whose sample rows can meet the polygon.
    row_first: u32,
    row_last: u32,

    pub fn triangle(x: [3]f32, y: [3]f32) Polygon {
        for (x, y) |vertex_x, vertex_y| {
            assert(!std.math.isNan(vertex_x));
            assert(!std.math.isNan(vertex_y));
        }
        return .{
            .x = .{ x[0], x[1], x[2], 0 },
            .y = .{ y[0], y[1], y[2], 0 },
            .vertex_count = 3,
            .row_first = 0,
            .row_last = 0,
        };
    }

    /// The vertices in order around the outline.
    pub fn quad(x: [4]f32, y: [4]f32) Polygon {
        for (x, y) |vertex_x, vertex_y| {
            assert(!std.math.isNan(vertex_x));
            assert(!std.math.isNan(vertex_y));
        }
        return .{ .x = x, .y = y, .vertex_count = 4, .row_first = 0, .row_last = 0 };
    }

    fn yMin(self: *const Polygon) f32 {
        assert(self.vertex_count == 3 or self.vertex_count == 4);
        var low = self.y[0];
        for (self.y[1..self.vertex_count]) |y| low = @min(low, y);
        return low;
    }

    fn yMax(self: *const Polygon) f32 {
        assert(self.vertex_count == 3 or self.vertex_count == 4);
        var high = self.y[0];
        for (self.y[1..self.vertex_count]) |y| high = @max(high, y);
        return high;
    }

    /// The half-open x interval `[low, high)` of samples the polygon covers
    /// on the horizontal line `y`, or null when the line misses it. Exact for
    /// convex polygons. Under the top-left rule a line through the bottom
    /// vertex or bottom edge (`y == yMax`) covers nothing, a line through a
    /// top edge covers it, and the right end of every span is excluded.
    fn interval(self: *const Polygon, y: f32) ?[2]f32 {
        assert(self.vertex_count == 3 or self.vertex_count == 4);
        assert(!std.math.isNan(y));
        if (y >= self.yMax()) return null;
        var low = std.math.inf(f32);
        var high = -std.math.inf(f32);
        var index: u8 = 0;
        while (index < self.vertex_count) : (index += 1) {
            const next = (index + 1) % self.vertex_count;
            const edge = Edge.canonical(
                .{ self.x[index], self.y[index] },
                .{ self.x[next], self.y[next] },
            );
            if (y < edge.y0) continue;
            if (y > edge.y1) continue;
            const crossing = edge.xRange(y);
            low = @min(low, crossing[0]);
            high = @max(high, crossing[1]);
        }
        if (low < high) return .{ low, high };
        return null;
    }
};

/// A polygon edge with its endpoints ordered by `(y, x)`.
///
/// Two triangles that share an edge list its endpoints in opposite orders.
/// Ordering them first makes both evaluate the identical float expression, so
/// a sample exactly on the shared edge is the left end of one span and the
/// right end of the other: covered once, with no crack and no overlap.
const Edge = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    fn canonical(a: [2]f32, b: [2]f32) Edge {
        assert(!std.math.isNan(a[1]));
        assert(!std.math.isNan(b[1]));
        const a_first = a[1] < b[1] or (a[1] == b[1] and a[0] <= b[0]);
        const first = if (a_first) a else b;
        const second = if (a_first) b else a;
        return .{ .x0 = first[0], .y0 = first[1], .x1 = second[0], .y1 = second[1] };
    }

    /// The x span the edge covers on line `y`, which lies in `[y0, y1]`. A
    /// horizontal edge covers its whole length.
    fn xRange(self: Edge, y: f32) [2]f32 {
        assert(y >= self.y0);
        assert(y <= self.y1);
        if (self.y1 == self.y0) return .{ self.x0, self.x1 };
        const x = self.x0 + (y - self.y0) * ((self.x1 - self.x0) / (self.y1 - self.y0));
        return .{ x, x };
    }
};

/// Storage one mesh draw uses, reserved by the renderer at initialization.
pub const Scratch = struct {
    polygons: []Polygon,
    /// Bucket chain links, parallel to `polygons`.
    next: []u32,
    /// Polygons spanning the row being rasterized.
    active: []u32,
    /// First polygon of each row's bucket, one per framebuffer row.
    heads: []u32,
    /// Covered-sample bits of each pixel of the row being rasterized. All
    /// zero between draws: a draw clears exactly the columns it set.
    mask: []u8,

    pub fn bytes(polygon_count_max: u32, width_max: u32, height_max: u32) u64 {
        assert(polygon_count_max > 0);
        assert(width_max > 0);
        assert(height_max > 0);
        const per_polygon: u64 = @sizeOf(Polygon) + 2 * @sizeOf(u32);
        return per_polygon * polygon_count_max + @as(u64, height_max) * @sizeOf(u32) +
            width_max;
    }
};

/// Fill the union of `polygons` (one draw) clipped to `clip` with `color`,
/// each pixel weighted by its covered-sample count.
pub fn fillPolygons(
    target: Target,
    scratch: *const Scratch,
    polygon_count: u32,
    clip: raster.DeviceRect,
    color: Premul,
) void {
    assert(polygon_count <= scratch.polygons.len);
    assert(target.width <= scratch.mask.len);
    assert(target.height <= scratch.heads.len);
    assert(color.r <= color.a);
    if (polygon_count == 0) return;
    if (color.a == 0) return;
    const rows = raster.centerSpanClosed(clip.y, clip.y + clip.height, target.height);
    const columns = raster.centerSpanClosed(clip.x, clip.x + clip.width, target.width);
    if (rows.isEmpty() or columns.isEmpty()) return;

    @memset(scratch.heads[rows.start..rows.end], chain_end);
    bucketPolygons(scratch, polygon_count, rows);

    var active_count: u32 = 0;
    var y = rows.start;
    while (y < rows.end) : (y += 1) {
        active_count = activateRow(scratch, y, active_count, polygon_count);
        const covered = coverRow(scratch, y, &active_count, columns);
        if (covered.isEmpty()) continue;
        shadeRow(target.row(y), covered, scratch.mask, color);
        @memset(scratch.mask[covered.start..covered.end], 0);
    }
}

/// Link each polygon into the bucket of the first row in `rows` it can
/// reach, after computing its row range. Polygons outside `rows` are skipped.
fn bucketPolygons(scratch: *const Scratch, polygon_count: u32, rows: Span) void {
    assert(polygon_count <= scratch.polygons.len);
    assert(!rows.isEmpty());
    for (scratch.polygons[0..polygon_count], 0..) |*polygon, index| {
        const top = polygon.yMin();
        const bottom = polygon.yMax();
        // A sample row sits at least 0.125 below a pixel row's top edge.
        const first = raster.clampIndex(@floor(top), rows.end);
        const last_exclusive = raster.clampIndex(@floor(bottom) + 1.0, rows.end);
        if (last_exclusive <= rows.start) continue;
        if (first >= last_exclusive) continue;
        polygon.row_first = @max(first, rows.start);
        polygon.row_last = last_exclusive - 1;
        assert(polygon.row_first <= polygon.row_last);
        scratch.next[index] = scratch.heads[polygon.row_first];
        scratch.heads[polygon.row_first] = @intCast(index);
    }
}

/// Append row `y`'s bucket to the active list. Returns the new active count.
fn activateRow(scratch: *const Scratch, y: u32, active_count: u32, polygon_count: u32) u32 {
    assert(active_count <= polygon_count);
    assert(y < scratch.heads.len);
    var count = active_count;
    var index = scratch.heads[y];
    // Each polygon sits in exactly one bucket, so the chain is bounded.
    while (index != chain_end) : (index = scratch.next[index]) {
        assert(count < polygon_count);
        scratch.active[count] = index;
        count += 1;
    }
    assert(count <= polygon_count);
    return count;
}

/// Set the covered-sample bits of row `y` for every active polygon, retiring
/// polygons that end above the row. Returns the columns that gained bits.
fn coverRow(scratch: *const Scratch, y: u32, active_count: *u32, columns: Span) Span {
    assert(active_count.* <= scratch.active.len);
    assert(!columns.isEmpty());
    var covered = Span{ .start = columns.end, .end = columns.start };
    var slot: u32 = 0;
    while (slot < active_count.*) {
        const polygon = &scratch.polygons[scratch.active[slot]];
        if (polygon.row_last < y) {
            active_count.* -= 1;
            scratch.active[slot] = scratch.active[active_count.*];
            continue;
        }
        coverPolygonRow(polygon, y, columns, scratch.mask, &covered);
        slot += 1;
    }
    if (covered.start >= covered.end) return Span.empty;
    return covered;
}

fn coverPolygonRow(
    polygon: *const Polygon,
    y: u32,
    columns: Span,
    mask: []u8,
    covered: *Span,
) void {
    assert(y >= polygon.row_first);
    assert(y <= polygon.row_last);
    const row_y: f32 = @floatFromInt(y);
    for (sample_x, sample_y, 0..) |offset_x, offset_y, sample| {
        const range = polygon.interval(row_y + offset_y) orelse continue;
        // Pixels whose sample `x + offset_x` lies in `[low, high)`.
        const first = raster.clampIndex(@ceil(range[0] - offset_x), columns.end);
        const last_exclusive = raster.clampIndex(@ceil(range[1] - offset_x), columns.end);
        const start = @max(first, columns.start);
        if (start >= last_exclusive) continue;
        const bit: u8 = @as(u8, 1) << @intCast(sample);
        for (mask[start..last_exclusive]) |*bits| bits.* |= bit;
        covered.start = @min(covered.start, start);
        covered.end = @max(covered.end, last_exclusive);
    }
}

fn shadeRow(row: []u32, covered: Span, mask: []const u8, color: Premul) void {
    assert(covered.end <= row.len);
    assert(covered.end <= mask.len);
    var x = covered.start;
    while (x < covered.end) : (x += 1) {
        const bits = mask[x];
        if (bits == 0) continue;
        assert(bits < (@as(u8, 1) << sample_count));
        const coverage = coverage_bytes[@popCount(bits)];
        const source = raster.premulScale(color, coverage);
        if (source.a != 0) row[x] = raster.blendPixel(row[x], source);
    }
}

/// One point of a point cloud: a circle of `radius` device pixels whose alpha
/// fades across its edge (`pointFalloff`). The pixels visited are the square
/// that reaches the end of the falloff, as the GPU's quad does.
pub fn drawPoint(
    target: Target,
    center: [2]f32,
    radius: f32,
    clip: raster.DeviceRect,
    color: Premul,
) void {
    assert(radius > 0);
    assert(color.r <= color.a);
    if (color.a == 0) return;
    const extent = pointFalloffEnd(radius);
    assert(extent >= radius);
    // The GPU rasterizes the square's pixel centers half-open and the shader
    // discards centers outside the clip.
    const rows = raster.centerSpanHalfOpen(center[1] - extent, center[1] + extent, target.height)
        .intersect(raster.centerSpanClosed(clip.y, clip.y + clip.height, target.height));
    const columns = raster.centerSpanHalfOpen(center[0] - extent, center[0] + extent, target.width)
        .intersect(raster.centerSpanClosed(clip.x, clip.x + clip.width, target.width));
    if (rows.isEmpty() or columns.isEmpty()) return;
    const inverse_radius = 1.0 / radius;
    var y = rows.start;
    while (y < rows.end) : (y += 1) {
        const v = (@as(f32, @floatFromInt(y)) + 0.5 - center[1]) * inverse_radius;
        const row = target.row(y);
        var x = columns.start;
        while (x < columns.end) : (x += 1) {
            const u = (@as(f32, @floatFromInt(x)) + 0.5 - center[0]) * inverse_radius;
            const coverage = raster.unitToByte(pointFalloff(@sqrt(u * u + v * v), radius));
            if (coverage == 0) continue;
            row[x] = raster.blendPixel(row[x], raster.premulScale(color, coverage));
        }
    }
}

/// Smallest radius, in device pixels, whose historical falloff band (the
/// outer 15% of the radius) is at least one pixel wide.
const point_radius_band_min: f32 = 1.0 / 0.15;

/// Point alpha at `uv_distance` (distance from the center over the radius)
/// for a point of `radius` device pixels. The contract shared with
/// `shaders/mesh.frag` and Metal's point shaders:
///
/// - From a 6.7 px radius up: `1 - smoothstep(0.85, 1, uv_distance)`, the
///   historical falloff, computed the same way so large points do not change.
/// - Smaller points: a one-pixel band that moves outward to straddle the edge,
///   so a sub-pixel dot keeps roughly its true area instead of vanishing.
fn pointFalloff(uv_distance: f32, radius: f32) f32 {
    assert(radius > 0);
    assert(uv_distance >= 0);
    if (radius >= point_radius_band_min) {
        return 1.0 - raster.smoothstep(0.85, 1.0, uv_distance);
    }
    const end = pointFalloffEnd(radius);
    return 1.0 - raster.smoothstep(end - 1.0, end, uv_distance * radius);
}

/// Distance from the center, in device pixels, where a point's alpha reaches
/// zero: the radius for large points, up to half a pixel beyond for small ones.
fn pointFalloffEnd(radius: f32) f32 {
    assert(radius > 0);
    const end = radius + 0.5 * @max(1.0 - 0.15 * radius, 0.0);
    assert(end >= radius);
    assert(end <= radius + 0.5);
    return end;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const TestScratch = struct {
    polygons: [8]Polygon = undefined,
    next: [8]u32 = undefined,
    active: [8]u32 = undefined,
    heads: [16]u32 = undefined,
    mask: [16]u8 = @splat(0),

    fn view(self: *TestScratch) Scratch {
        return .{
            .polygons = &self.polygons,
            .next = &self.next,
            .active = &self.active,
            .heads = &self.heads,
            .mask = &self.mask,
        };
    }
};

const test_background: u32 = 0xFF00_0000;
const open_clip = raster.DeviceRect{ .x = -1e6, .y = -1e6, .width = 2e6, .height = 2e6 };
const red = Premul{ .r = 255, .g = 0, .b = 0, .a = 255 };

fn testTarget(pixels: []u32, width: u32, height: u32) Target {
    assert(pixels.len == @as(usize, width) * height);
    @memset(pixels, test_background);
    return .{ .pixels = pixels, .width = width, .height = height, .stride = width };
}

test "two triangles sharing a diagonal fill their square with no seam" {
    // Goal: the per-draw sample mask must make the shared diagonal of a
    // square split into two triangles fully covered. Blending each triangle
    // separately would leave diagonal pixels near 75% red; a crack in the
    // edge test would leave some below 100%.
    var storage = TestScratch{};
    const scratch = storage.view();
    scratch.polygons[0] = Polygon.triangle(.{ 1, 7, 7 }, .{ 1, 1, 7 });
    scratch.polygons[1] = Polygon.triangle(.{ 1, 7, 1 }, .{ 1, 7, 7 });
    var pixels: [8 * 8]u32 = undefined;
    const target = testTarget(&pixels, 8, 8);
    fillPolygons(target, &scratch, 2, open_clip, red);
    var y: u32 = 1;
    while (y < 7) : (y += 1) {
        var x: u32 = 1;
        while (x < 7) : (x += 1) try testing.expectEqual(@as(u32, 0xFFFF_0000), target.row(y)[x]);
    }
    try testing.expectEqual(test_background, target.row(0)[0]);
    try testing.expectEqual(test_background, target.row(7)[3]);
    try testing.expectEqual(test_background, target.row(3)[7]);
}

test "a half-pixel edge covers the samples on its side only" {
    // Goal: pin the sample pattern. A rectangle whose left edge is x = 1.5
    // covers pixel 1's samples at x offsets 0.875 and 0.625 (two of four):
    // red byte 128. Pixel 0 gets none and pixel 2 all four.
    var storage = TestScratch{};
    const scratch = storage.view();
    scratch.polygons[0] = Polygon.quad(.{ 1.5, 4, 4, 1.5 }, .{ 0, 0, 1, 1 });
    var pixels: [5 * 1]u32 = undefined;
    const target = testTarget(&pixels, 5, 1);
    fillPolygons(target, &scratch, 1, open_clip, red);
    try testing.expectEqual(test_background, pixels[0]);
    try testing.expectEqual(@as(u32, 0xFF80_0000), pixels[1]);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), pixels[2]);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), pixels[3]);
    try testing.expectEqual(test_background, pixels[4]);
}

test "clip discards pixels by center, and polygons outside the clip are skipped" {
    // Goal: a mesh fragment is discarded when its center leaves the clip, so
    // a clip ending at x = 2.5 keeps pixel 2 and drops pixel 3, whatever the
    // coverage. A second polygon entirely below the clip must not draw.
    var storage = TestScratch{};
    const scratch = storage.view();
    scratch.polygons[0] = Polygon.quad(.{ 0, 5, 5, 0 }, .{ 0, 0, 2, 2 });
    scratch.polygons[1] = Polygon.quad(.{ 0, 5, 5, 0 }, .{ 3, 3, 4, 4 });
    var pixels: [5 * 4]u32 = undefined;
    const target = testTarget(&pixels, 5, 4);
    const clip = raster.DeviceRect{ .x = 0, .y = 0, .width = 2.5, .height = 2 };
    fillPolygons(target, &scratch, 2, clip, red);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), target.row(1)[2]);
    try testing.expectEqual(test_background, target.row(1)[3]);
    try testing.expectEqual(test_background, target.row(3)[0]);
}

test "samples exactly on an edge follow the top-left rule" {
    // Goal: Vulkan covers a sample on a top or left edge and not on a bottom
    // or right edge. Pixel 0's samples sit at y 0.125, 0.375, 0.625, 0.875
    // and x 0.375, 0.875, 0.125, 0.625. A rectangle from y = 0.375 to 0.875
    // has its top edge on sample 1 and its bottom edge on sample 3, so it
    // covers samples 1 and 2: red byte 128. One spanning x = 0.375 to 0.875
    // over the full row has its left edge on sample 0 and its right edge on
    // sample 1, so it covers samples 0 and 3: again 128, where a closed test
    // would give 191 for both.
    var storage = TestScratch{};
    const scratch = storage.view();
    var pixels: [2 * 1]u32 = undefined;
    const target = testTarget(&pixels, 2, 1);
    scratch.polygons[0] = Polygon.quad(.{ -1, 3, 3, -1 }, .{ 0.375, 0.375, 0.875, 0.875 });
    fillPolygons(target, &scratch, 1, open_clip, red);
    try testing.expectEqual(@as(u32, 0xFF80_0000), pixels[0]);
    @memset(&pixels, test_background);
    scratch.polygons[0] = Polygon.quad(.{ 0.375, 0.875, 0.875, 0.375 }, .{ -1, -1, 2, 2 });
    fillPolygons(target, &scratch, 1, open_clip, red);
    try testing.expectEqual(@as(u32, 0xFF80_0000), pixels[0]);
}

test "rows reuse the mask without leaking coverage downward" {
    // Goal: the row mask is shared by every row of a draw. A triangle that
    // narrows downward must not leave its wider upper coverage behind in the
    // rows beneath, and a second draw must start from a clean mask.
    var storage = TestScratch{};
    const scratch = storage.view();
    scratch.polygons[0] = Polygon.triangle(.{ 0, 8, 4 }, .{ 0, 0, 4 });
    var pixels: [8 * 6]u32 = undefined;
    const target = testTarget(&pixels, 8, 6);
    fillPolygons(target, &scratch, 1, open_clip, red);
    try testing.expectEqual(@as(u32, 0xFFFF_0000), target.row(0)[4]);
    try testing.expectEqual(test_background, target.row(3)[0]);
    try testing.expectEqual(test_background, target.row(4)[4]);
    scratch.polygons[0] = Polygon.triangle(.{ 0, 1, 0 }, .{ 5, 5, 6 });
    fillPolygons(target, &scratch, 1, open_clip, red);
    try testing.expectEqual(test_background, target.row(5)[7]);
    try testing.expectEqualSlices(u8, &(@as([16]u8, @splat(0))), &storage.mask);
}

test "degenerate polygons draw nothing" {
    // Goal: the GPU emits no fragments for a zero-area polygon, even where
    // samples lie exactly on it. A zero-length strip segment collapses to a
    // vertical line at x = 1.375, pixel 1's first sample column, and a flat
    // triangle lies on the sample row y = 0.125.
    var storage = TestScratch{};
    const scratch = storage.view();
    scratch.polygons[0] = Polygon.quad(.{ 1.375, 1.375, 1.375, 1.375 }, .{ 0, 0, 2, 2 });
    scratch.polygons[1] = Polygon.triangle(.{ 0, 2, 4 }, .{ 0.125, 0.125, 0.125 });
    var pixels: [4 * 2]u32 = undefined;
    const target = testTarget(&pixels, 4, 2);
    fillPolygons(target, &scratch, 2, open_clip, red);
    for (pixels) |pixel| try testing.expectEqual(test_background, pixel);
}

test "large point alpha keeps the historical falloff" {
    // Goal: from a 6.7 px radius up a point is unchanged: full alpha inside
    // 85% of the radius and none outside the circle. Radius 8 at (10, 10.5):
    // the center pixel is opaque and the square's corner pixel (3, 3), at
    // |uv| = 1.19, is untouched.
    var pixels: [24 * 24]u32 = undefined;
    const target = testTarget(&pixels, 24, 24);
    const white = Premul{ .r = 255, .g = 255, .b = 255, .a = 255 };
    drawPoint(target, .{ 10, 10.5 }, 8, open_clip, white);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), target.row(10)[10]);
    try testing.expectEqual(test_background, target.row(3)[3]);
    // Pixel (17, 10) has |uv| = 7.5 / 8 = 0.9375. smoothstep(0.85, 1, 0.9375)
    // = 0.6238, so coverage 0.3762 rounds to byte 96.
    try testing.expectEqual(@as(u32, 0xFF60_6060), target.row(10)[17]);
}

test "sub-pixel point keeps its area with a one-pixel falloff" {
    // Goal: a radius-0.7 point centered on a pixel corner draws its four
    // pixels at about its true area (pi * 0.49 / 4 = 0.385 each). The old
    // falloff left it invisible: every pixel center, at 0.707 px, lies past
    // the radius. The band ends at 0.7 + 0.5 * (1 - 0.105) = 1.1475 px, so
    // t = 0.7071 - 0.1475 = 0.5596, smoothstep = 0.5890 and alpha 0.4110,
    // byte 105. The next pixel out, at 1.58 px, is untouched.
    var pixels: [8 * 8]u32 = undefined;
    const target = testTarget(&pixels, 8, 8);
    const white = Premul{ .r = 255, .g = 255, .b = 255, .a = 255 };
    drawPoint(target, .{ 4, 4 }, 0.7, open_clip, white);
    for ([_][2]u32{ .{ 3, 3 }, .{ 4, 3 }, .{ 3, 4 }, .{ 4, 4 } }) |pixel| {
        try testing.expectEqual(@as(u32, 0xFF69_6969), target.row(pixel[1])[pixel[0]]);
    }
    try testing.expectEqual(test_background, target.row(4)[5]);
    try testing.expectEqual(test_background, target.row(2)[3]);
}
