//! Path triangle edge classification for analytic anti-aliasing.
//!
//! The Vulkan and Metal renderers draw one sample per pixel. Their triangle
//! vertex shaders anti-alias a path by pushing chosen triangle edges outward by
//! a pixel and fading coverage across them (Vulkan `shaders/triangles.vert` and
//! `shaders/mesh.frag`, Metal `path_pipeline.zig`). Fading every edge of every
//! triangle would draw a visible seam wherever two triangles meet: each covers
//! about half of the pixels on the shared edge, and blending two half-covered
//! draws leaves a quarter of the background showing. That happens inside one
//! triangulated path and also between separate draws that tile a shape, such
//! as the pie and donut charts, whose slices are hundreds of single-triangle
//! paths.
//!
//! So every edge is classified once per frame, over all path draws, by its
//! exact endpoint positions in screen space:
//!
//! - `fade`: no other triangle in the frame shares the edge. It is a silhouette
//!   edge: expand outward and fade across it.
//! - `interior`: every triangle sharing the edge has the same fill. Draw it
//!   with the plain rasterization rule, like a single mesh, so the triangles
//!   tile the area exactly once.
//! - `underlap`: the edge is shared with a later draw of a different fill. The
//!   earlier draw expands half a pixel under the later one at full coverage
//!   and the later draw fades over it, so the boundary blends the two colours
//!   the way 4x MSAA resolved it, without background bleeding through.
//!
//! Edges are matched by exact float equality after the path transform. Charts
//! compute shared vertices with identical arithmetic, so their shared edges
//! match; edges that only overlap partially (T-junctions) are treated as
//! silhouettes. Both backends classify with `classify` and write their vertex
//! records with `write_triangles`, so they choose the same mode for every edge.
//!
//! Geometry (`triangle_draw_vertex_count`): the shaders draw every triangle at
//! its exact corners and add a separate fringe quad outside each fade and
//! underlap edge, as NanoVG and Skia draw anti-aliasing fringes. An interior
//! edge therefore has bit-identical endpoints in both triangles that share it,
//! and the rasterization rule covers each pixel on it exactly once. Moving a
//! corner instead (sliding it along an interior edge so the triangle itself
//! grows over its faded edge) left the two copies of the shared edge a few
//! ulps apart, and pixel centres in the sliver between them, inside donut
//! slices, showed the background.
//!
//! Resource sketch (CLAUDE.md §7): one entry per path index the frame may
//! submit (`SceneLimits.path_index_count_frame_max`), at most two thirds full:
//! 20 B × 1.5 = 30 B per index budget, 491,540 B at `.standard`, reserved and
//! zeroed at init. An entry is live only when its stamp is the frame's, so a
//! frame starts without clearing the table. Per frame: three inserts
//! and three lookups per submitted triangle, each a 64-bit hash and a short
//! linear probe. Nothing allocates after init. The fringe quads add no
//! memory: the shaders generate them from the triangle's three records, 21
//! draw vertices per triangle.

const std = @import("std");
const assert = std.debug.assert;

const scene_mod = @import("../scene/mod.zig");
const path_mesh = @import("../scene/path_mesh.zig");

/// How the triangle shader treats one edge. Two bits per edge in the vertex
/// record; the values are part of the shader contract in Vulkan's `mesh.glsl`
/// and Metal's `path_pipeline.zig`.
pub const EdgeMode = enum(u2) {
    interior = 0,
    fade = 1,
    underlap = 2,
};

/// A 64-bit hash of an edge's endpoints, independent of their order.
pub const Key = u64;

/// Index of a path in the frame's draw order. Path draws per frame are bounded
/// by `MAX_PATHS_PER_FRAME` (4,096), well inside `u16`.
pub const PathIndex = u16;

comptime {
    assert(@import("../core/limits.zig").MAX_PATHS_PER_FRAME <= std.math.maxInt(PathIndex));
}

/// One de-indexed path triangle vertex: the source `PathVertex` plus the
/// triangle's edge modes, two bits per edge in order (v0→v1, v1→v2, v2→v0),
/// values from `EdgeMode`. All three vertices of a triangle carry the same
/// modes; the vertex shader reads its two neighbours from the buffer. The
/// modes are stored as an integral float (0..63) because the Vulkan shader
/// reads the payload as `float[]`; a small integer bit pattern would be a
/// denormal, which a GPU may flush to zero on load.
pub const TriangleVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    edge_modes: f32,

    comptime {
        assert(@sizeOf(TriangleVertex) == 20);
        assert(@offsetOf(TriangleVertex, "edge_modes") == 16);
        assert(@sizeOf(TriangleVertex) == @sizeOf(scene_mod.PathVertex) + 4);
    }
};

/// Vertices the triangle shaders draw per path triangle (Vulkan
/// `triangles.vert`, Metal `path_pipeline.zig`): the triangle at its exact
/// corners, then a fringe quad of two triangles outside each of its three
/// edges. A quad whose edge is interior collapses to a point.
pub const triangle_draw_vertex_count: u32 = 3 + 3 * 6;

/// Draw vertices for one path draw of `index_count` triangle records.
pub fn draw_vertex_count(index_count: u32) u32 {
    assert(index_count % 3 == 0);
    assert(index_count <= path_mesh.MAX_MESH_INDICES);
    return @divExact(index_count, 3) * triangle_draw_vertex_count;
}

/// Hash an edge so that both orientations, and +0.0 and -0.0, give one key.
pub fn edgeKey(a: [2]f32, b: [2]f32) Key {
    // Adding +0.0 turns -0.0 into +0.0 and leaves every other value unchanged.
    const a_bits = [2]u32{ @bitCast(a[0] + 0.0), @bitCast(a[1] + 0.0) };
    const b_bits = [2]u32{ @bitCast(b[0] + 0.0), @bitCast(b[1] + 0.0) };
    const a_first = a_bits[0] < b_bits[0] or (a_bits[0] == b_bits[0] and a_bits[1] <= b_bits[1]);
    const ordered: [4]u32 = if (a_first)
        .{ a_bits[0], a_bits[1], b_bits[0], b_bits[1] }
    else
        .{ b_bits[0], b_bits[1], a_bits[0], a_bits[1] };
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&ordered));
}

const Entry = extern struct {
    key: [2]u32,
    /// Fill hash of the first path to submit the edge this frame.
    fill: u32,
    /// The frame that wrote the entry; older entries are empty.
    stamp: u32,
    /// The first (lowest) path index to submit the edge.
    owner: PathIndex,
    /// Occurrences this frame, saturating.
    count: u8,
    /// 1 when a later occurrence had a different fill.
    mixed: u8,

    comptime {
        assert(@sizeOf(Entry) == 20);
    }
};

pub const EdgeTable = struct {
    entries: []Entry = &.{},
    stamp: u32 = 0,
    /// Edges inserted this frame; bounded by `edge_count_max`.
    edge_count: u32 = 0,
    edge_count_max: u32 = 0,

    /// Reserve room for `edge_count_max` edges per frame (the path index
    /// budget: a triangle's three indices bring three edges).
    pub fn init(self: *EdgeTable, gpa: std.mem.Allocator, edge_count_max: u32) !void {
        assert(self.entries.len == 0);
        assert(edge_count_max > 0);
        // Load factor at most 2/3 keeps linear probes short.
        const capacity: usize = @as(usize, edge_count_max) + edge_count_max / 2 + 1;
        self.entries = try gpa.alloc(Entry, capacity);
        @memset(self.entries, std.mem.zeroes(Entry));
        self.stamp = 0;
        self.edge_count = 0;
        self.edge_count_max = edge_count_max;
        assert(self.entries.len > self.edge_count_max);
    }

    pub fn deinit(self: *EdgeTable, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
        self.* = .{};
    }

    /// Start a frame: every entry written by earlier frames becomes empty.
    pub fn begin(self: *EdgeTable) void {
        assert(self.entries.len > 0);
        self.stamp +%= 1;
        if (self.stamp == 0) {
            // Stamp wrap-around, once per 2^32 frames: really empty the table.
            @memset(self.entries, std.mem.zeroes(Entry));
            self.stamp = 1;
        }
        self.edge_count = 0;
    }

    /// Record one occurrence of an edge, drawn by path `path` with `fill`.
    /// Paths must be inserted in draw order.
    pub fn insert(self: *EdgeTable, key: Key, path: PathIndex, fill: u32) void {
        const entry = self.slot(key);
        if (entry.stamp != self.stamp) {
            assert(self.edge_count < self.edge_count_max);
            self.edge_count += 1;
            entry.* = .{
                .key = splitKey(key),
                .fill = fill,
                .stamp = self.stamp,
                .owner = path,
                .count = 1,
                .mixed = 0,
            };
            return;
        }
        assert(path >= entry.owner);
        entry.count +|= 1;
        if (entry.fill != fill) entry.mixed = 1;
    }

    /// The shader mode for path `path`'s occurrence of an edge. An edge the
    /// frame never inserted (the classification pass stopped at the geometry
    /// budget, which the draw pass then reports) is treated as a silhouette.
    pub fn mode(self: *const EdgeTable, key: Key, path: PathIndex) EdgeMode {
        const entry = self.find(key) orelse return .fade;
        assert(entry.count >= 1);
        if (entry.count == 1) return .fade;
        if (entry.mixed == 0) return .interior;
        if (path == entry.owner) return .underlap;
        return .fade;
    }

    fn splitKey(key: Key) [2]u32 {
        return .{ @truncate(key), @truncate(key >> 32) };
    }

    /// The live entry for `key`, or the empty entry where it would go.
    fn slot(self: *EdgeTable, key: Key) *Entry {
        const split = splitKey(key);
        var index: usize = @intCast(key % self.entries.len);
        for (0..self.entries.len) |_| {
            const entry = &self.entries[index];
            if (entry.stamp != self.stamp) return entry;
            if (entry.key[0] == split[0] and entry.key[1] == split[1]) return entry;
            index = if (index + 1 == self.entries.len) 0 else index + 1;
        }
        // The load factor stays below 2/3, so a probe always meets an empty slot.
        unreachable;
    }

    fn find(self: *const EdgeTable, key: Key) ?*const Entry {
        const entry = @constCast(self).slot(key);
        if (entry.stamp != self.stamp) return null;
        return entry;
    }
};

/// Classify every path triangle edge of the frame before any path is drawn.
/// Paths are visited in draw order, the order the backends draw them in, and
/// `path_index` in `write_triangles` is the same index into
/// `scene.getPathInstances()`. Classification stops at the frame's path index
/// budget; the draw pass then reports the exhausted pool.
pub fn classify(table: *EdgeTable, scene: *const scene_mod.Scene) void {
    assert(table.entries.len > 0);
    const paths = scene.getPathInstances();
    const gradients = scene.getPathGradients();
    assert(paths.len == gradients.len);
    assert(paths.len <= scene.limits.path_count_frame_max);
    table.begin();
    const index_count_max = table.edge_count_max;
    var index_count: u64 = 0;
    for (paths, gradients, 0..) |*path, *gradient, path_index| {
        const mesh = scene.getMeshPool().getMesh(path.getMeshRef());
        const indices = mesh.indices.constSlice();
        if (index_count + indices.len > index_count_max) break;
        index_count += indices.len;
        const fill = fill_hash(path, gradient);
        const vertices = mesh.vertices.constSlice();
        var triangle: usize = 0;
        while (triangle < indices.len) : (triangle += 3) {
            const corners = triangle_corners(path, vertices, indices[triangle..][0..3]);
            for (0..3) |edge| {
                const key = edgeKey(corners[edge], corners[(edge + 1) % 3]);
                table.insert(key, @intCast(path_index), fill);
            }
        }
    }
    assert(index_count <= index_count_max);
}

pub const TriangleSource = struct {
    edges: *const EdgeTable,
    path: *const scene_mod.PathInstance,
    /// The path's index in `scene.getPathInstances()`, as `classify` saw it.
    path_index: PathIndex,
    vertices: []const scene_mod.PathVertex,
    indices: []const u32,
};

/// De-index a path mesh into vertex records, each triangle tagged with the
/// modes `classify` chose for its three edges.
pub fn write_triangles(target: []TriangleVertex, source: *const TriangleSource) void {
    assert(target.len == source.indices.len);
    assert(target.len % 3 == 0);
    assert(target.len <= path_mesh.MAX_MESH_INDICES);
    var triangle: usize = 0;
    while (triangle < target.len) : (triangle += 3) {
        const indices = source.indices[triangle..][0..3];
        const corners = triangle_corners(source.path, source.vertices, indices);
        var edge_modes: u8 = 0;
        for (0..3) |edge| {
            const key = edgeKey(corners[edge], corners[(edge + 1) % 3]);
            const mode = source.edges.mode(key, source.path_index);
            edge_modes |= @as(u8, @backingInt(mode)) << @intCast(2 * edge);
        }
        assert(edge_modes < 64);
        for (indices, target[triangle..][0..3]) |index, *record| {
            const vertex = source.vertices[index];
            record.* = .{
                .x = vertex.x,
                .y = vertex.y,
                .u = vertex.u,
                .v = vertex.v,
                .edge_modes = @floatFromInt(edge_modes),
            };
        }
    }
}

/// Everything that decides a path's colour after its transform: fill colour,
/// clip, gradient parameters and the gradient's live stops. Two paths with
/// equal hashes blend identically across a shared edge. Unused stops are
/// zeroed so stale bytes past `stop_count` cannot split equal fills.
fn fill_hash(
    path: *const scene_mod.PathInstance,
    gradient: *const scene_mod.GradientUniforms,
) u32 {
    const Fill = extern struct {
        color: [4]f32,
        clip: [4]f32,
        params: [4]f32,
        gradient_type: u32,
        stop_count: u32,
        stops: [5][16]f32,
    };
    var fill = std.mem.zeroes(Fill);
    fill.color = .{ path.fill_color.h, path.fill_color.s, path.fill_color.l, path.fill_color.a };
    fill.clip = .{ path.clip_x, path.clip_y, path.clip_width, path.clip_height };
    fill.params = .{ path.grad_param0, path.grad_param1, path.grad_param2, path.grad_param3 };
    fill.gradient_type = path.gradient_type;
    fill.stop_count = gradient.stop_count;
    assert(fill.gradient_type <= 2);
    if (fill.gradient_type != 0) {
        assert(fill.stop_count >= 2);
        assert(fill.stop_count <= 16);
        const count = fill.stop_count;
        @memcpy(fill.stops[0][0..count], gradient.stop_offsets[0..count]);
        @memcpy(fill.stops[1][0..count], gradient.stop_h[0..count]);
        @memcpy(fill.stops[2][0..count], gradient.stop_s[0..count]);
        @memcpy(fill.stops[3][0..count], gradient.stop_l[0..count]);
        @memcpy(fill.stops[4][0..count], gradient.stop_a[0..count]);
    }
    return @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&fill)));
}

/// A triangle's corners in screen space, transformed exactly as the vertex
/// shaders transform them, so equal corners compare equal across draws.
fn triangle_corners(
    path: *const scene_mod.PathInstance,
    vertices: []const scene_mod.PathVertex,
    indices: *const [3]u32,
) [3][2]f32 {
    var corners: [3][2]f32 = undefined;
    for (indices, &corners) |index, *corner| {
        assert(index < vertices.len);
        const vertex = vertices[index];
        corner.* = .{
            vertex.x * path.scale_x + path.offset_x,
            vertex.y * path.scale_y + path.offset_y,
        };
    }
    return corners;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "edge keys ignore orientation and the sign of zero" {
    // Goal: the two triangles on either side of an edge list its endpoints in
    // opposite orders, and charts can produce -0.0 where a neighbour has 0.0.
    const a = [2]f32{ 10.5, -0.0 };
    const b = [2]f32{ 3.25, 7.0 };
    try testing.expectEqual(edgeKey(a, b), edgeKey(b, a));
    try testing.expectEqual(edgeKey(a, b), edgeKey(.{ 10.5, 0.0 }, b));
    // A one-ulp difference is a different edge: matching is exact.
    const nudged = [2]f32{ std.math.nextAfter(f32, 10.5, 11.0), 0.0 };
    try testing.expect(edgeKey(a, b) != edgeKey(nudged, b));
    // Swapping coordinates within an endpoint is a different edge.
    try testing.expect(edgeKey(.{ 1, 2 }, .{ 3, 4 }) != edgeKey(.{ 2, 1 }, .{ 3, 4 }));
}

test "classification distinguishes silhouettes, shared fills and fill boundaries" {
    // Goal: pin each mode with an input where a wrong rule gives a different
    // answer. Path 0 and path 1 share edge `ab` with the same fill; path 1 and
    // path 2 share `bc` with different fills; `cd` belongs to path 2 alone.
    var table: EdgeTable = .{};
    try table.init(testing.allocator, 8);
    defer table.deinit(testing.allocator);
    table.begin();
    const ab = edgeKey(.{ 0, 0 }, .{ 1, 0 });
    const bc = edgeKey(.{ 1, 0 }, .{ 1, 1 });
    const cd = edgeKey(.{ 1, 1 }, .{ 0, 1 });
    table.insert(ab, 0, 7);
    table.insert(ab, 1, 7);
    table.insert(bc, 1, 7);
    table.insert(bc, 2, 9);
    table.insert(cd, 2, 9);
    try testing.expectEqual(EdgeMode.interior, table.mode(ab, 0));
    try testing.expectEqual(EdgeMode.interior, table.mode(ab, 1));
    // The earlier draw of a fill boundary underlaps; the later one fades over it.
    try testing.expectEqual(EdgeMode.underlap, table.mode(bc, 1));
    try testing.expectEqual(EdgeMode.fade, table.mode(bc, 2));
    try testing.expectEqual(EdgeMode.fade, table.mode(cd, 2));
    try testing.expectEqual(@as(u32, 3), table.edge_count);
}

test "a new frame forgets the previous frame's edges" {
    // Goal: stamps, not clearing, empty the table. An edge shared last frame
    // is a silhouette this frame when only one triangle submits it.
    var table: EdgeTable = .{};
    try table.init(testing.allocator, 4);
    defer table.deinit(testing.allocator);
    const key = edgeKey(.{ 2, 3 }, .{ 5, 8 });
    table.begin();
    table.insert(key, 0, 1);
    table.insert(key, 1, 1);
    try testing.expectEqual(EdgeMode.interior, table.mode(key, 0));
    table.begin();
    try testing.expectEqual(EdgeMode.fade, table.mode(key, 0));
    table.insert(key, 0, 1);
    try testing.expectEqual(EdgeMode.fade, table.mode(key, 0));
    // Wrap the stamp: the table must still read as empty afterwards.
    table.stamp = std.math.maxInt(u32);
    table.begin();
    try testing.expectEqual(@as(u32, 1), table.stamp);
    try testing.expectEqual(EdgeMode.fade, table.mode(key, 0));
}

test "a full frame of distinct edges fits and every edge stays findable" {
    // Goal: fill the table to its edge budget exactly. Each edge must keep its
    // own entry under collisions, so every lookup still returns silhouette.
    var table: EdgeTable = .{};
    const edge_count_max: u32 = 300;
    try table.init(testing.allocator, edge_count_max);
    defer table.deinit(testing.allocator);
    table.begin();
    for (0..edge_count_max) |index| {
        const x: f32 = @floatFromInt(index);
        table.insert(edgeKey(.{ x, 0 }, .{ x, 1 }), 0, 3);
    }
    try testing.expectEqual(edge_count_max, table.edge_count);
    for (0..edge_count_max) |index| {
        const x: f32 = @floatFromInt(index);
        try testing.expectEqual(EdgeMode.fade, table.mode(edgeKey(.{ x, 0 }, .{ x, 1 }), 0));
    }
    // Re-inserting an existing edge does not consume budget.
    table.insert(edgeKey(.{ 0, 0 }, .{ 0, 1 }), 1, 3);
    try testing.expectEqual(edge_count_max, table.edge_count);
    try testing.expectEqual(EdgeMode.interior, table.mode(edgeKey(.{ 0, 0 }, .{ 0, 1 }), 1));
}
