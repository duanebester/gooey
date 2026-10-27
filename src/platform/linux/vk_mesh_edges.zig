//! Path triangle edge classification for analytic anti-aliasing.
//!
//! The Vulkan renderer draws one sample per pixel. The triangle vertex shader
//! anti-aliases a path by pushing chosen triangle edges outward by a pixel and
//! fading coverage across them (`shaders/triangles.vert`, `shaders/mesh.frag`).
//! Fading every edge of every triangle would draw a visible seam wherever two
//! triangles meet: each covers about half of the pixels on the shared edge,
//! and blending two half-covered draws leaves a quarter of the background
//! showing. That happens inside one triangulated path and also between
//! separate draws that tile a shape, such as the pie and donut charts, whose
//! slices are hundreds of single-triangle paths.
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
//! silhouettes.
//!
//! Resource sketch (CLAUDE.md §7): one entry per path index the frame may
//! submit (`SceneLimits.path_index_count_frame_max`), at most two thirds full:
//! 20 B × 1.5 = 30 B per index budget, 491,540 B at `.standard`, reserved and
//! zeroed at init. An entry is live only when its stamp is the frame's, so a
//! frame starts without clearing the table. Per frame: three inserts
//! and three lookups per submitted triangle, each a 64-bit hash and a short
//! linear probe. Nothing allocates after init.

const std = @import("std");
const assert = std.debug.assert;

/// How the triangle shader treats one edge. Two bits per edge in the vertex
/// record; the values are part of the shader contract in `mesh.glsl`.
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
    assert(@import("../../core/limits.zig").MAX_PATHS_PER_FRAME <= std.math.maxInt(PathIndex));
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
