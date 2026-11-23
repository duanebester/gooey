const std = @import("std");
const assert = std.debug.assert;

const limits = @import("../core/limits.zig");

pub const EdgeMode = enum(u2) {
    interior = 0,
    fade = 1,
    underlap = 2,
};

pub const Key = u64;

pub const PathIndex = u16;

comptime {
    assert(limits.MAX_PATHS_PER_FRAME <= std.math.maxInt(PathIndex));
}

pub const triangle_draw_vertex_count: u32 = 3 + 3 * 6;

pub fn draw_vertex_count(index_count: u32) u32 {
    assert(index_count % 3 == 0);
    assert(index_count <= limits.MAX_PATH_INDICES);
    return @divExact(index_count, 3) * triangle_draw_vertex_count;
}

pub fn edgeKey(a: [2]f32, b: [2]f32) Key {
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
    fill: u32,
    stamp: u32,
    owner: PathIndex,
    count: u8,
    mixed: u8,

    comptime {
        assert(@sizeOf(Entry) == 20);
    }
};

pub const EdgeTable = struct {
    entries: []Entry = &.{},
    stamp: u32 = 0,
    slot_count: u32 = 0,
    slot_count_high: u32 = 0,
    edge_count: u32 = 0,
    edge_count_frame: u32 = 0,
    edge_count_max: u32 = 0,

    pub fn init(self: *EdgeTable, edge_count_max: u32) !void {
        assert(self.entries.len == 0);
        assert(edge_count_max > 0);
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
        std.heap.page_allocator.rawFree(
            std.mem.sliceAsBytes(self.entries),
            .of(Entry),
            @returnAddress(),
        );
        self.* = .{};
    }

    pub fn begin(self: *EdgeTable, edge_count_frame: u32) void {
        assert(self.entries.len > 0);
        assert(edge_count_frame <= self.edge_count_max);
        self.stamp +%= 1;
        if (self.stamp == 0) {
            @memset(self.entries[0..self.slot_count_high], std.mem.zeroes(Entry));
            self.stamp = 1;
        }
        self.slot_count = slot_count_for(edge_count_frame);
        self.slot_count_high = @max(self.slot_count_high, self.slot_count);
        assert(self.slot_count_high <= self.entries.len);
        self.edge_count = 0;
        self.edge_count_frame = edge_count_frame;
    }

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
        unreachable;
    }

    fn find(self: *const EdgeTable, key: Key) ?*const Entry {
        const entry = @constCast(self).slot(key);
        if (entry.stamp != self.stamp) return null;
        return entry;
    }
};

pub fn table_bytes(edge_count_max: u32) u64 {
    assert(edge_count_max > 0);
    const bytes = @as(u64, slot_count_for(edge_count_max)) * @sizeOf(Entry);
    assert(bytes > @as(u64, edge_count_max) * @sizeOf(Entry));
    return bytes;
}

fn slot_count_for(edge_count: u32) u32 {
    const slot_count = @as(u64, edge_count) + edge_count / 2 + 1;
    assert(slot_count <= std.math.maxInt(u32));
    return @intCast(slot_count);
}

const testing = std.testing;

test "edge keys ignore orientation and the sign of zero" {
    const a = [2]f32{ 10.5, -0.0 };
    const b = [2]f32{ 3.25, 7.0 };
    try testing.expectEqual(edgeKey(a, b), edgeKey(b, a));
    try testing.expectEqual(edgeKey(a, b), edgeKey(.{ 10.5, 0.0 }, b));
    const nudged = [2]f32{ std.math.nextAfter(f32, 10.5, 11.0), 0.0 };
    try testing.expect(edgeKey(a, b) != edgeKey(nudged, b));
    try testing.expect(edgeKey(.{ 1, 2 }, .{ 3, 4 }) != edgeKey(.{ 2, 1 }, .{ 3, 4 }));
}

test "classification distinguishes silhouettes, shared fills and fill boundaries" {
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
    try testing.expectEqual(EdgeMode.underlap, table.mode(bc, 1));
    try testing.expectEqual(EdgeMode.fade, table.mode(bc, 2));
    try testing.expectEqual(EdgeMode.fade, table.mode(cd, 2));
    try testing.expectEqual(@as(u32, 3), table.edge_count);
}

test "a new frame forgets the previous frame's edges" {
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
    table.stamp = std.math.maxInt(u32);
    table.begin(4);
    try testing.expectEqual(@as(u32, 1), table.stamp);
    try testing.expectEqual(EdgeMode.fade, table.mode(key, 0));
}

test "a full frame of distinct edges fits and every edge stays findable" {
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
    table.insert(edgeKey(.{ 0, 0 }, .{ 0, 1 }), 1, 3);
    try testing.expectEqual(edge_count_max, table.edge_count);
    try testing.expectEqual(EdgeMode.interior, table.mode(edgeKey(.{ 0, 0 }, .{ 0, 1 }), 1));
}

test "a frame hashes into slots for its own edge count, not the budget" {
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
    for (0..4) |index| {
        const x: f32 = @floatFromInt(index);
        table.insert(edgeKey(.{ x, 0 }, .{ x, 1 }), 0, 3);
        table.insert(edgeKey(.{ x, 0 }, .{ x, 1 }), 1, 3);
    }
    try testing.expectEqual(@as(u32, 4), table.edge_count);
    try testing.expectEqual(EdgeMode.interior, table.mode(stale, 0));
    table.begin(0);
    try testing.expectEqual(@as(u32, 1), table.slot_count);
    try testing.expectEqual(EdgeMode.fade, table.mode(stale, 0));
}
