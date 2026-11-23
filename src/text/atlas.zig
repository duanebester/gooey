const std = @import("std");
const assert = std.debug.assert;

const reservation = @import("../core/reservation.zig");
const uploads_mod = @import("atlas_uploads.zig");
pub const AtlasUploads = uploads_mod.AtlasUploads;
pub const AtlasKind = uploads_mod.AtlasKind;
pub const AtlasStorage = uploads_mod.AtlasStorage;

pub const UVCoords = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

pub const Region = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn uv(self: Region, atlas_size: u32) UVCoords {
        const size_f: f32 = @floatFromInt(atlas_size);
        return .{
            .u0 = @as(f32, @floatFromInt(self.x)) / size_f,
            .v0 = @as(f32, @floatFromInt(self.y)) / size_f,
            .u1 = @as(f32, @floatFromInt(self.x + self.width)) / size_f,
            .v1 = @as(f32, @floatFromInt(self.y + self.height)) / size_f,
        };
    }
};

pub const Format = enum {
    grayscale,
    rgba,

    pub fn bytesPerPixel(self: Format) u8 {
        return switch (self) {
            .grayscale => 1,
            .rgba => 4,
        };
    }
};

pub const Placement = struct {
    region: Region,
    shelf: u16,
    generation: u32,
};

pub const shelf_none: u16 = std.math.maxInt(u16);

pub const shelf_height_quantum: u32 = 4;

pub const item_border: u32 = 1;

pub const Atlas = struct {
    allocator: std.mem.Allocator,
    kind: AtlasKind,
    format: Format,
    size: u32,
    storage: AtlasStorage,
    data: []u8,
    data_rows_written_end: u32,
    shelves: []Shelf,
    uploads: *AtlasUploads,
    rows_active: u32,
    rows_active_peak: u32,

    const Self = @This();

    const Shelf = struct {
        frame_used: u64,
        sequence_end: u64,
        generation: u32,
        y: u16,
        height: u16,
        x_cursor: u16,
        state: State,
        dead: bool,

        const State = enum(u8) { unused, free, active };
    };

    pub const Options = struct {
        kind: AtlasKind,
        size: u32,
        uploads: *AtlasUploads,
    };

    pub fn init(self: *Self, allocator: std.mem.Allocator, options: Options) !void {
        assert(options.size >= 64);
        assert(options.size <= std.math.maxInt(u16));
        assert(options.size % shelf_height_quantum == 0);
        const format: Format = if (options.kind == .text) .grayscale else .rgba;
        const storage = options.uploads.storage;
        self.data = if (storage == .cpu_texture)
            try reservation.reserve(u8, options.size * options.size * format.bytesPerPixel())
        else
            &.{};
        errdefer if (storage == .cpu_texture) reservation.release(u8, self.data, 0);
        self.data_rows_written_end = 0;
        self.shelves = try allocator.alloc(Shelf, options.size / shelf_height_quantum);

        self.allocator = allocator;
        self.kind = options.kind;
        self.format = format;
        self.size = options.size;
        self.storage = storage;
        self.uploads = options.uploads;
        self.rows_active = 0;
        self.rows_active_peak = 0;
        self.resetShelves();
        assert(self.shelves[0].state == .free);
        assert(self.shelves[0].height == self.size);
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.shelves);
        if (self.storage == .cpu_texture) {
            assert(self.data_rows_written_end <= self.size);
            const row_bytes = @as(usize, self.size) * self.format.bytesPerPixel();
            reservation.release(u8, self.data, self.data_rows_written_end * row_bytes);
        }
        self.* = undefined;
    }

    fn resetShelves(self: *Self) void {
        for (self.shelves) |*shelf| {
            shelf.* = .{
                .frame_used = 0,
                .sequence_end = 0,
                .generation = 0,
                .y = 0,
                .height = 0,
                .x_cursor = 0,
                .state = .unused,
                .dead = false,
            };
        }
        self.shelves[0].state = .free;
        self.shelves[0].height = @intCast(self.size);
        self.rows_active = 0;
    }

    pub inline fn isLive(self: *const Self, shelf: u16, generation: u32) bool {
        if (shelf == shelf_none) return true;
        assert(shelf < self.shelves.len);
        const entry = &self.shelves[shelf];
        if (entry.generation != generation) return false;
        assert(entry.state == .active);
        assert(!entry.dead);
        return true;
    }

    pub inline fn touch(self: *Self, shelf: u16, frame: u64) void {
        if (shelf == shelf_none) return;
        assert(shelf < self.shelves.len);
        assert(frame > 0);
        const entry = &self.shelves[shelf];
        assert(entry.state == .active);
        if (entry.frame_used < frame) entry.frame_used = frame;
    }

    pub fn insert(self: *Self, width: u32, height: u32, pixels: []const u8) ?Placement {
        assert(width > 0);
        assert(height > 0);
        assert(pixels.len >= @as(usize, width) * height * self.format.bytesPerPixel());
        const outer_width = width + 2 * item_border;
        const outer_height = height + 2 * item_border;
        if (outer_width > self.size or outer_height > self.size) {
            self.panicItemTooLarge(outer_width, outer_height);
        }

        self.uploads.lock();
        defer self.uploads.unlock();
        if (self.storage == .gpu_upload) {
            if (!self.uploads.reserveLocked(self.kind, outer_width, outer_height)) return null;
        }
        const placement = self.place(width, height);
        self.writeItem(placement, pixels);
        assert(self.isLive(placement.shelf, placement.generation));
        return placement;
    }

    pub fn evictOne(self: *Self) bool {
        self.uploads.lock();
        defer self.uploads.unlock();
        const victim = self.evictionCandidate() orelse return false;
        self.evict(victim);
        return true;
    }

    pub fn clear(self: *Self) void {
        for (self.shelves) |*shelf| {
            if (shelf.state != .active) continue;
            shelf.generation +%= 1;
            shelf.dead = true;
            shelf.x_cursor = @intCast(self.size);
        }
    }

    pub fn getData(self: *const Self) []const u8 {
        assert(self.storage == .cpu_texture);
        assert(self.data.len == @as(usize, self.size) * self.size * self.format.bytesPerPixel());
        return self.data;
    }

    fn place(self: *Self, width: u32, height: u32) Placement {
        const outer_width = width + 2 * item_border;
        const outer_height = height + 2 * item_border;
        const shelf_height = roundUpQuantum(outer_height);
        var attempt: usize = 0;
        while (attempt <= self.shelves.len) : (attempt += 1) {
            if (self.findShelf(outer_width, outer_height, shelf_height)) |slot| {
                return self.append(slot, width, height);
            }
            const victim = self.evictionCandidate() orelse break;
            self.evict(victim);
        }
        const taller: ShelfQuery = .{ .height_min = outer_height, .height_max = self.size };
        const slot = self.findActiveShelf(outer_width, taller) orelse
            self.growShelf(outer_width, shelf_height, 0) orelse
            self.panicLiveSetDoesNotFit(outer_width, outer_height);
        return self.append(slot, width, height);
    }

    fn findShelf(self: *Self, outer_width: u32, outer_height: u32, shelf_height: u32) ?u16 {
        assert(shelf_height >= outer_height);
        assert(shelf_height <= self.size);
        const exact: ShelfQuery = .{ .height_min = shelf_height, .height_max = shelf_height };
        if (self.findActiveShelf(outer_width, exact)) |slot| return slot;
        const frame_protected = self.uploads.frameProtectedLocked();
        const pinned: ShelfQuery = .{
            .height_min = outer_height,
            .height_max = @min(self.size, 2 * shelf_height),
            .frame_used_min = frame_protected,
        };
        if (self.findActiveShelf(outer_width, pinned)) |slot| return slot;
        if (self.openShelf(shelf_height)) |slot| return slot;
        return self.growShelf(outer_width, shelf_height, frame_protected);
    }

    fn growShelf(self: *Self, outer_width: u32, shelf_height: u32, frame_used_min: u64) ?u16 {
        assert(shelf_height <= self.size);
        var best: ?u16 = null;
        var best_below: u16 = 0;
        for (self.shelves, 0..) |*shelf, index| {
            if (shelf.state != .active) continue;
            if (shelf.height >= shelf_height) continue;
            if (shelf.frame_used < frame_used_min) continue;
            if (self.size - shelf.x_cursor < outer_width) continue;
            const below = self.freeNeighbour(shelf.y + shelf.height, .below) orelse continue;
            if (self.shelves[below].height < shelf_height - shelf.height) continue;
            if (best) |b| {
                if (shelf.height <= self.shelves[b].height) continue;
            }
            best = @intCast(index);
            best_below = below;
        }
        const slot = best orelse return null;
        const shelf = &self.shelves[slot];
        const free = &self.shelves[best_below];
        const rows: u16 = @intCast(shelf_height - shelf.height);
        assert(free.y == shelf.y + shelf.height);
        shelf.height += rows;
        free.y += rows;
        free.height -= rows;
        if (free.height == 0) free.state = .unused;
        self.rows_active += rows;
        self.rows_active_peak = @max(self.rows_active_peak, self.rows_active);
        assert(self.rows_active <= self.size);
        return slot;
    }

    const ShelfQuery = struct {
        height_min: u32,
        height_max: u32,
        frame_used_min: u64 = 0,
    };

    fn findActiveShelf(self: *const Self, outer_width: u32, query: ShelfQuery) ?u16 {
        assert(query.height_min <= query.height_max);
        var best: ?u16 = null;
        for (self.shelves, 0..) |*shelf, index| {
            if (shelf.state != .active) continue;
            if (shelf.height < query.height_min) continue;
            if (shelf.height > query.height_max) continue;
            if (shelf.frame_used < query.frame_used_min) continue;
            if (self.size - shelf.x_cursor < outer_width) continue;
            if (best) |b| {
                const current = &self.shelves[b];
                if (shelf.height > current.height) continue;
                if (shelf.height == current.height and shelf.y > current.y) continue;
            }
            best = @intCast(index);
        }
        return best;
    }

    fn openShelf(self: *Self, shelf_height: u32) ?u16 {
        var best: ?u16 = null;
        for (self.shelves, 0..) |*shelf, index| {
            if (shelf.state != .free) continue;
            if (shelf.height < shelf_height) continue;
            if (best) |b| {
                const current = &self.shelves[b];
                if (shelf.height > current.height) continue;
                if (shelf.height == current.height and shelf.y > current.y) continue;
            }
            best = @intCast(index);
        }
        const slot = best orelse return null;
        const free = &self.shelves[slot];
        if (free.height > shelf_height) {
            const rest = self.unusedSlot();
            self.shelves[rest].state = .free;
            self.shelves[rest].y = free.y + @as(u16, @intCast(shelf_height));
            self.shelves[rest].height = free.height - @as(u16, @intCast(shelf_height));
        }
        free.height = @intCast(shelf_height);
        free.state = .active;
        free.dead = false;
        free.x_cursor = 0;
        free.frame_used = 0;
        free.sequence_end = 0;
        self.rows_active += shelf_height;
        self.rows_active_peak = @max(self.rows_active_peak, self.rows_active);
        assert(self.rows_active <= self.size);
        return slot;
    }

    fn append(self: *Self, slot: u16, width: u32, height: u32) Placement {
        const shelf = &self.shelves[slot];
        const outer_width = width + 2 * item_border;
        assert(shelf.state == .active);
        assert(self.size - shelf.x_cursor >= outer_width);
        assert(height + 2 * item_border <= shelf.height);
        const x = shelf.x_cursor + item_border;
        shelf.x_cursor += @intCast(outer_width);
        shelf.frame_used = self.uploads.frameCurrent();
        return .{
            .region = .{
                .x = @intCast(x),
                .y = @intCast(shelf.y + item_border),
                .width = @intCast(width),
                .height = @intCast(height),
            },
            .shelf = slot,
            .generation = shelf.generation,
        };
    }

    fn evictionCandidate(self: *const Self) ?u16 {
        const frame_protected = self.uploads.frameProtectedLocked();
        const sequence_retired = self.uploads.sequenceRetiredLocked();
        var best: ?u16 = null;
        for (self.shelves, 0..) |*shelf, index| {
            if (shelf.state != .active) continue;
            if (shelf.frame_used >= frame_protected) continue;
            if (shelf.sequence_end > sequence_retired) continue;
            if (best) |b| {
                if (!evictsBefore(shelf, &self.shelves[b])) continue;
            }
            best = @intCast(index);
        }
        return best;
    }

    fn evictsBefore(a: *const Shelf, b: *const Shelf) bool {
        assert(a.state == .active);
        assert(b.state == .active);
        if (a.dead != b.dead) return a.dead;
        if (a.frame_used != b.frame_used) return a.frame_used < b.frame_used;
        return a.y < b.y;
    }

    fn evict(self: *Self, slot: u16) void {
        const shelf = &self.shelves[slot];
        assert(shelf.state == .active);
        assert(self.rows_active >= shelf.height);
        self.rows_active -= shelf.height;
        shelf.generation +%= 1;
        shelf.state = .free;
        shelf.dead = false;
        shelf.x_cursor = 0;
        var merged = slot;
        if (self.freeNeighbour(self.shelves[merged].y, .above)) |above| {
            self.shelves[above].height += self.shelves[merged].height;
            self.shelves[merged].state = .unused;
            merged = above;
        }
        const end = self.shelves[merged].y + self.shelves[merged].height;
        if (self.freeNeighbour(end, .below)) |below| {
            self.shelves[merged].height += self.shelves[below].height;
            self.shelves[below].state = .unused;
        }
        assert(self.shelves[merged].state == .free);
    }

    fn freeNeighbour(self: *const Self, edge: u32, side: enum { above, below }) ?u16 {
        assert(edge <= self.size);
        for (self.shelves, 0..) |*shelf, index| {
            if (shelf.state != .free) continue;
            const matches = switch (side) {
                .above => shelf.y + shelf.height == edge,
                .below => shelf.y == edge,
            };
            if (matches) return @intCast(index);
        }
        return null;
    }

    fn unusedSlot(self: *const Self) u16 {
        for (self.shelves, 0..) |*shelf, index| {
            if (shelf.state == .unused) return @intCast(index);
        }
        unreachable;
    }

    fn writeItem(self: *Self, placement: Placement, pixels: []const u8) void {
        const region = placement.region;
        assert(region.x >= item_border);
        assert(region.y >= item_border);
        const item: Item = .{
            .width = region.width,
            .height = region.height,
            .bpp = self.format.bytesPerPixel(),
        };
        const outer_x = region.x - item_border;
        const outer_y = region.y - item_border;
        switch (self.storage) {
            .cpu_texture => {
                const stride = @as(usize, self.size) * item.bpp;
                const origin = (@as(usize, outer_y) * self.size + outer_x) * item.bpp;
                writeBordered(self.data[origin..], stride, pixels, item);
                const rows_end = outer_y + region.height + 2 * item_border;
                assert(rows_end <= self.size);
                self.data_rows_written_end = @max(self.data_rows_written_end, rows_end);
            },
            .gpu_upload => {
                const outer_width = region.width + 2 * item_border;
                const staged = self.uploads.stageLocked(.{
                    .offset = 0,
                    .x = @intCast(outer_x),
                    .y = @intCast(outer_y),
                    .width = @intCast(outer_width),
                    .height = @intCast(region.height + 2 * item_border),
                    .kind = self.kind,
                }) orelse return;
                writeBordered(staged, @as(usize, outer_width) * item.bpp, pixels, item);
                self.shelves[placement.shelf].sequence_end = self.uploads.sequenceEnd();
            },
        }
    }

    const Item = struct { width: u32, height: u32, bpp: u32 };

    fn writeBordered(target: []u8, stride: usize, pixels: []const u8, item: Item) void {
        const outer_row = (@as(usize, item.width) + 2) * item.bpp;
        const inner_row = @as(usize, item.width) * item.bpp;
        const border = item.bpp;
        assert(stride >= outer_row);
        assert(target.len >= stride * (item.height + 1) + outer_row);
        @memset(target[0..outer_row], 0);
        var row: usize = 0;
        while (row < item.height) : (row += 1) {
            const line = target[(row + 1) * stride ..][0..outer_row];
            @memset(line[0..border], 0);
            @memcpy(line[border..][0..inner_row], pixels[row * inner_row ..][0..inner_row]);
            @memset(line[border + inner_row ..], 0);
        }
        @memset(target[(item.height + 1) * stride ..][0..outer_row], 0);
    }

    fn panicItemTooLarge(self: *const Self, outer_width: u32, outer_height: u32) noreturn {
        std.debug.panic("Atlas pool '{t}' cannot hold one item: capacity {d}x{d} px, " ++
            "requested {d}x{d} px (1 px border included), frame {d}.", .{
            self.kind,                   self.size, self.size, outer_width, outer_height,
            self.uploads.frameCurrent(),
        });
    }

    fn panicLiveSetDoesNotFit(self: *const Self, outer_width: u32, outer_height: u32) noreturn {
        std.debug.panic("Atlas pool '{t}' exhausted: capacity {d}x{d} px, {d} rows held " ++
            "by items in use since frame {d}, requested {d}x{d} px (1 px border included), " ++
            "frame {d}.", .{
            self.kind,
            self.size,
            self.size,
            self.rows_active,
            self.uploads.frameProtectedLocked(),
            outer_width,
            outer_height,
            self.uploads.frameCurrent(),
        });
    }
};

fn roundUpQuantum(value: u32) u32 {
    assert(value > 0);
    return std.mem.alignForward(u32, value, shelf_height_quantum);
}

const testing = std.testing;

const TestAtlas = struct {
    uploads: AtlasUploads,
    atlas: Atlas,

    const item_width: u32 = 62;
    const item_height: u32 = 14;
    const consumer: usize = 1;

    fn init(self: *TestAtlas, kind: AtlasKind, storage: AtlasStorage) !void {
        try self.uploads.init(testing.allocator, testing.io, .{
            .storage = storage,
            .upload_bytes_frame_max = 64 * 64 * 4,
            .consumer_count_max = 1,
        });
        errdefer self.uploads.deinit();
        self.uploads.registerConsumer(consumer);
        errdefer self.uploads.unregisterConsumer(consumer);
        try self.atlas.init(
            testing.allocator,
            .{ .kind = kind, .size = 64, .uploads = &self.uploads },
        );
        assert(self.atlas.shelves[0].height == 64);
    }

    fn deinit(self: *TestAtlas) void {
        self.atlas.deinit();
        self.uploads.unregisterConsumer(consumer);
        self.uploads.deinit();
    }

    fn frame(self: *TestAtlas) void {
        _ = self.uploads.beginFrame(consumer);
        _ = self.uploads.consumeBegin(consumer);
        self.uploads.consumeEnd(consumer);
    }

    fn item(self: *TestAtlas, value: u8) Placement {
        var pixels: [item_width * item_height * 4]u8 = undefined;
        @memset(&pixels, value);
        return self.atlas.insert(item_width, item_height, &pixels).?;
    }

    fn live(self: *const TestAtlas, placement: Placement) bool {
        return self.atlas.isLive(placement.shelf, placement.generation);
    }

    fn pixel(self: *const TestAtlas, x: u32, y: u32) u8 {
        return self.atlas.getData()[y * self.atlas.size + x];
    }
};

test "atlas evicts the least recently used shelf, lowest y on ties" {
    var t: TestAtlas = undefined;
    try t.init(.text, .cpu_texture);
    defer t.deinit();

    var placements: [4]Placement = undefined;
    for (&placements, 0..) |*placement, index| {
        t.frame();
        placement.* = t.item(@intCast(10 + index));
    }
    const a, const b, const c, const d = placements;
    try testing.expectEqual(@as(u32, 64), t.atlas.rows_active);

    t.frame();
    t.atlas.touch(a.shelf, t.atlas.uploads.frameCurrent());
    const e = t.item(20);
    try testing.expectEqual(b.region.y, e.region.y);
    try testing.expect(!t.live(b));
    try testing.expect(t.live(a) and t.live(c) and t.live(d));

    t.frame();
    const f = t.item(21);
    try testing.expectEqual(c.region.y, f.region.y);
    t.frame();
    const g = t.item(22);
    try testing.expectEqual(d.region.y, g.region.y);

    t.frame();
    const h = t.item(23);
    try testing.expectEqual(a.region.y, h.region.y);
    try testing.expect(t.live(e) and t.live(f) and t.live(g) and t.live(h));
    try testing.expect(!t.live(a));

    try testing.expectEqual(@as(u8, 23), t.pixel(h.region.x, h.region.y));
    try testing.expectEqual(@as(u8, 0), t.pixel(h.region.x - 1, h.region.y));
    try testing.expectEqual(@as(u8, 0), t.pixel(h.region.x, h.region.y - 1));
    try testing.expectEqual(@as(u8, 0), t.pixel(h.region.x, h.region.y + h.region.height));
}

test "atlas keeps a lagging consumer's shown frame until its next frame uploads" {
    var t: TestAtlas = undefined;
    try t.init(.text, .cpu_texture);
    defer t.deinit();
    const uploads = &t.uploads;
    uploads.protectShownFrame(TestAtlas.consumer);
    _ = uploads.beginFrame(TestAtlas.consumer);
    var placements: [4]Placement = undefined;
    for (&placements, 0..) |*placement, index| placement.* = t.item(@intCast(index + 1));
    _ = uploads.consumeBegin(TestAtlas.consumer);
    uploads.consumeEnd(TestAtlas.consumer);

    _ = uploads.beginFrame(TestAtlas.consumer);
    try testing.expect(!t.atlas.evictOne());
    for (placements) |placement| try testing.expect(t.live(placement));
    _ = uploads.consumeBegin(TestAtlas.consumer);
    uploads.consumeEnd(TestAtlas.consumer);

    _ = uploads.beginFrame(TestAtlas.consumer);
    try testing.expect(t.atlas.evictOne());
    try testing.expect(!t.live(placements[0]));
    _ = uploads.consumeBegin(TestAtlas.consumer);
    uploads.consumeEnd(TestAtlas.consumer);
}

test "atlas never evicts an item used this frame or awaiting upload" {
    var t: TestAtlas = undefined;
    try t.init(.text, .cpu_texture);
    defer t.deinit();
    t.frame();
    var placements: [4]Placement = undefined;
    for (&placements, 0..) |*placement, index| placement.* = t.item(@intCast(index + 1));
    t.frame();
    const frame = t.atlas.uploads.frameCurrent();
    for (placements) |placement| t.atlas.touch(placement.shelf, frame);
    try testing.expect(!t.atlas.evictOne());
    t.frame();
    try testing.expect(t.atlas.evictOne());
    try testing.expect(!t.live(placements[0]));
    try testing.expect(t.live(placements[1]));

    var g: TestAtlas = undefined;
    try g.init(.text, .gpu_upload);
    defer g.deinit();
    g.frame();
    for (&placements, 0..) |*placement, index| placement.* = g.item(@intCast(index + 1));
    var frame_index: u32 = 0;
    while (frame_index < 3) : (frame_index += 1) _ = g.uploads.beginFrame(TestAtlas.consumer);
    try testing.expect(!g.atlas.evictOne());
    const pending = g.uploads.consumeBegin(TestAtlas.consumer);
    try testing.expectEqual(@as(usize, 4), pending.records.len);
    try testing.expectEqual(@as(u16, 64), pending.records[0].width);
    try testing.expectEqual(@as(u16, 16), pending.records[0].height);
    g.uploads.consumeEnd(TestAtlas.consumer);
    g.frame();
    try testing.expect(g.atlas.evictOne());
}

test "atlas clear condemns every item and reuses its space" {
    var t: TestAtlas = undefined;
    try t.init(.text, .cpu_texture);
    defer t.deinit();
    t.frame();
    var placements: [4]Placement = undefined;
    for (&placements, 0..) |*placement, index| placement.* = t.item(@intCast(index + 1));
    t.atlas.clear();
    for (placements) |placement| try testing.expect(!t.live(placement));
    t.frame();
    for (&placements, 0..) |*placement, index| placement.* = t.item(@intCast(index + 5));
    for (placements) |placement| try testing.expect(t.live(placement));
    try testing.expectEqual(@as(u32, 64), t.atlas.rows_active);
}

test "atlas grows a shelf into the free rows below it" {
    var t: TestAtlas = undefined;
    try t.init(.text, .cpu_texture);
    defer t.deinit();
    t.frame();
    var index: u8 = 0;
    while (index < 3) : (index += 1) _ = t.item(index + 1);
    var pixels: [30 * 12]u8 = @splat(9);
    const short = t.atlas.insert(30, 10, &pixels).?;
    try testing.expectEqual(@as(u32, 60), t.atlas.rows_active);
    const tall = t.atlas.insert(30, 12, &pixels).?;
    try testing.expectEqual(short.shelf, tall.shelf);
    try testing.expectEqual(short.region.y, tall.region.y);
    try testing.expectEqual(short.region.x + 32, tall.region.x);
    try testing.expectEqual(@as(u32, 64), t.atlas.rows_active);
    try testing.expect(t.live(short) and t.live(tall));
}
