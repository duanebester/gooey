//! Path triangle edge classification for analytic anti-aliasing.
//!
//! The Vulkan and Metal renderers draw one sample per pixel. Their triangle
//! vertex shaders anti-alias a path by pushing chosen triangle edges outward by
//! a pixel and fading coverage across them (Vulkan `shaders/triangles.vert` and
//! `shaders/mesh.frag`, Metal `shaders.zig`). Fading every edge of every
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
//! silhouettes. Pack classifies every edge of the packed frame once and
//! writes the modes to its `edge_modes` (`core/pack.zig`), so every backend
//! chooses the same mode for every edge.
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
//! Resource sketch (CLAUDE.md §7): one entry per triangle point the frame may
//! hold (`PaintLimits.path_vertex_count_frame_max`), at most two thirds full:
//! 20 B × 1.5 = 30 B per point budget, 491,540 B at `.standard` and 7,864,340 B
//! at `.large`. The table is mapped from fresh pages at init and not cleared:
//! the pages are zero and not resident until touched. A frame hashes only into
//! the first 1.5 × (its own triangle point count) entries, so resident memory
//! follows the largest frame drawn so far, 30 B per triangle point it packed;
//! an app that draws no paths keeps one page. An entry is live only when its
//! stamp is the frame's, so a frame starts without clearing the table. Per
//! frame: three inserts and three lookups per packed triangle, each a 64-bit
//! hash and a short linear probe. Nothing allocates after init. The fringe
//! quads add no memory: the shaders generate them from the triangle's three
//! records, 21 draw vertices per triangle.

const std = @import("std");
const assert = std.debug.assert;

const limits = @import("../core/limits.zig");

/// How the triangle shader treats one edge. Two bits per edge in the vertex
/// record; the values are part of the shader contract in Vulkan's `mesh.glsl`
/// and Metal's `shaders.zig`.
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
    assert(limits.MAX_PATHS_PER_FRAME <= std.math.maxInt(PathIndex));
}

/// Vertices the triangle shaders draw per path triangle (Vulkan
/// `triangles.vert`, Metal `shaders.zig`): the triangle at its exact
/// corners, then a fringe quad of two triangles outside each of its three
/// edges. A quad whose edge is interior collapses to a point.
pub const triangle_draw_vertex_count: u32 = 3 + 3 * 6;

/// Draw vertices for one path draw of `index_count` triangle records.
pub fn draw_vertex_count(index_count: u32) u32 {
    assert(index_count % 3 == 0);
    assert(index_count <= limits.MAX_PATH_INDICES);
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
    /// Room for `edge_count_max` edges, mapped from fresh pages at init and
    /// never cleared there: fresh pages are zero by kernel contract, and stamp
    /// 0 marks an entry empty. A frame probes only its first `slot_count`
    /// entries, so the resident part follows the frames' edge counts, not the
    /// budget: an app that draws no paths keeps one page resident.
    entries: []Entry = &.{},
    stamp: u32 = 0,
    /// Entries this frame hashes into: 1.5 × its edge bound, plus one.
    slot_count: u32 = 0,
    /// The largest `slot_count` of any frame; no entry past it was written.
    slot_count_high: u32 = 0,
    /// Edges inserted this frame; bounded by `edge_count_frame`.
    edge_count: u32 = 0,
    /// This frame's edge bound: its triangle points, one edge each.
    edge_count_frame: u32 = 0,
    edge_count_max: u32 = 0,

    /// Reserve room for `edge_count_max` edges per frame (the triangle point
    /// budget: a triangle's three points bring three edges).
    pub fn init(self: *EdgeTable, edge_count_max: u32) !void {
        assert(self.entries.len == 0);
        assert(edge_count_max > 0);
        // Fresh anonymous pages (CLAUDE.md §21): zero, and not resident
        // until a frame touches them. A general-purpose allocator could hand
        // back reused bytes, and `Allocator.alloc` fills safe builds with
        // 0xAA, which would touch every page; `rawAlloc` does neither.
        const entry_count = slot_count_for(edge_count_max);
        const bytes = std.heap.page_allocator.rawAlloc(
            @as(usize, entry_count) * @sizeOf(Entry),
            .of(Entry),
            @returnAddress(),
        ) orelse return error.OutOfMemory;
        self.entries = @as([*]Entry, @ptrCast(@alignCast(bytes)))[0..entry_count];
        assert(self.entries[0].stamp == 0);
        self.stamp = 0;
        self.slot_count = 0;
        self.slot_count_high = 0;
        self.edge_count = 0;
        self.edge_count_frame = 0;
        self.edge_count_max = edge_count_max;
        assert(self.entries.len > self.edge_count_max);
    }

    pub fn deinit(self: *EdgeTable) void {
        assert(self.entries.len > 0);
        // The pages go back to the kernel, which zeroes them for any next owner.
        std.heap.page_allocator.rawFree(
            std.mem.sliceAsBytes(self.entries),
            .of(Entry),
            @returnAddress(),
        );
        self.* = .{};
    }

    /// Start a frame of at most `edge_count_frame` edges: every entry written
    /// by earlier frames becomes empty.
    pub fn begin(self: *EdgeTable, edge_count_frame: u32) void {
        assert(self.entries.len > 0);
        assert(edge_count_frame <= self.edge_count_max);
        self.stamp +%= 1;
        if (self.stamp == 0) {
            // Stamp wrap-around, once per 2^32 frames: really empty every
            // entry a frame has written.
            @memset(self.entries[0..self.slot_count_high], std.mem.zeroes(Entry));
            self.stamp = 1;
        }
        self.slot_count = slot_count_for(edge_count_frame);
        self.slot_count_high = @max(self.slot_count_high, self.slot_count);
        assert(self.slot_count_high <= self.entries.len);
        self.edge_count = 0;
        self.edge_count_frame = edge_count_frame;
    }

    /// Record one occurrence of an edge, drawn by path `path` with `fill`.
    /// Paths must be inserted in draw order.
    pub fn insert(self: *EdgeTable, key: Key, path: PathIndex, fill: u32) void {
        const entry = self.slot(key);
        if (entry.stamp != self.stamp) {
            assert(self.edge_count < self.edge_count_frame);
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
        assert(self.slot_count > 0);
        assert(self.slot_count <= self.entries.len);
        const slots = self.entries[0..self.slot_count];
        var index: usize = @intCast(key % slots.len);
        for (0..slots.len) |_| {
            const entry = &slots[index];
            if (entry.stamp != self.stamp) return entry;
            if (entry.key[0] == split[0] and entry.key[1] == split[1]) return entry;
            index = if (index + 1 == slots.len) 0 else index + 1;
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

/// Bytes `EdgeTable.init(edge_count_max)` maps.
pub fn table_bytes(edge_count_max: u32) u64 {
    assert(edge_count_max > 0);
    const bytes = @as(u64, slot_count_for(edge_count_max)) * @sizeOf(Entry);
    assert(bytes > @as(u64, edge_count_max) * @sizeOf(Entry));
    return bytes;
}

/// Hash slots for `edge_count` edges: a load factor of at most 2/3 keeps
/// linear probes short, and the extra slot keeps an empty frame probe-able.
fn slot_count_for(edge_count: u32) u32 {
    const slot_count = @as(u64, edge_count) + edge_count / 2 + 1;
    assert(slot_count <= std.math.maxInt(u32));
    return @intCast(slot_count);
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
    try table.init(8);
    defer table.deinit();
    table.begin(6);
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
    try table.init(4);
    defer table.deinit();
    const key = edgeKey(.{ 2, 3 }, .{ 5, 8 });
    table.begin(4);
    table.insert(key, 0, 1);
    table.insert(key, 1, 1);
    try testing.expectEqual(EdgeMode.interior, table.mode(key, 0));
    table.begin(4);
    try testing.expectEqual(EdgeMode.fade, table.mode(key, 0));
    table.insert(key, 0, 1);
    try testing.expectEqual(EdgeMode.fade, table.mode(key, 0));
    // Wrap the stamp: the table must still read as empty afterwards.
    table.stamp = std.math.maxInt(u32);
    table.begin(4);
    try testing.expectEqual(@as(u32, 1), table.stamp);
    try testing.expectEqual(EdgeMode.fade, table.mode(key, 0));
}

test "a full frame of distinct edges fits and every edge stays findable" {
    // Goal: fill the table to its edge budget exactly. Each edge must keep its
    // own entry under collisions, so every lookup still returns silhouette.
    var table: EdgeTable = .{};
    const edge_count_max: u32 = 300;
    try table.init(edge_count_max);
    defer table.deinit();
    table.begin(edge_count_max);
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

test "a frame hashes into slots for its own edge count, not the budget" {
    // Goal: resident memory follows use. A small frame after a full one must
    // touch only its own slots and still ignore the full frame's entries,
    // which sit both inside and outside the small frame's slot range.
    var table: EdgeTable = .{};
    const edge_count_max: u32 = 600;
    try table.init(edge_count_max);
    defer table.deinit();
    table.begin(edge_count_max);
    for (0..edge_count_max) |index| {
        const x: f32 = @floatFromInt(index);
        table.insert(edgeKey(.{ x, 0 }, .{ x, 1 }), 0, 3);
    }
    try testing.expectEqual(@as(u32, 901), table.slot_count_high);
    table.begin(4);
    try testing.expectEqual(@as(u32, 7), table.slot_count);
    try testing.expectEqual(@as(u32, 901), table.slot_count_high);
    const stale = edgeKey(.{ 3, 0 }, .{ 3, 1 });
    try testing.expectEqual(EdgeMode.fade, table.mode(stale, 0));
    // Four edges, the frame's bound, fit in seven slots and stay distinct.
    for (0..4) |index| {
        const x: f32 = @floatFromInt(index);
        table.insert(edgeKey(.{ x, 0 }, .{ x, 1 }), 0, 3);
        table.insert(edgeKey(.{ x, 0 }, .{ x, 1 }), 1, 3);
    }
    try testing.expectEqual(@as(u32, 4), table.edge_count);
    try testing.expectEqual(EdgeMode.interior, table.mode(stale, 0));
    // An empty frame still has one slot to probe.
    table.begin(0);
    try testing.expectEqual(@as(u32, 1), table.slot_count);
    try testing.expectEqual(EdgeMode.fade, table.mode(stale, 0));
}
