const std = @import("std");
const chip_mod = @import("chip.zig");
const display_list = @import("display_list.zig");
const limits_mod = @import("../../core/limits.zig");
const eve_limits = @import("limits.zig");
const reservation = @import("../../core/reservation.zig");

const assert = std.debug.assert;
const Chip = chip_mod.Chip;

pub const cell_sizes = [_]u32{ 8, 16, 24, 32, 40, 48, 64, 80, 96, 128 };
pub const cell_size_max: u32 = cell_sizes[cell_sizes.len - 1];
pub const page_bytes: u32 = eve_limits.EveLimits.bt81x.cell_page_bytes;
pub const page_count_max: u32 = display_list.handle_count_max;
pub const page_cell_count_max: u32 = 128;
pub const cell_count_max: u32 = page_count_max * page_cell_count_max;
const slot_count: u32 = 4096;
const staging_bytes_max: u32 = 64 * 1024;
const svg_coverage_min: u8 = 5;
pub const atlas_size_max: u32 = 4096;

comptime {
    assert(cell_size_max * cell_size_max <= page_bytes);
    assert(page_count_max == eve_limits.EveLimits.bt81x.cell_page_count_max);
    assert(page_count_max * page_bytes <= chip_mod.ram_g_size);
    assert(cell_count_max <= slot_count / 2);
    assert(std.math.isPowerOfTwo(slot_count));
    assert(cell_size_max * cell_size_max <= staging_bytes_max);
    assert(atlas_size_max <= 8192);
}

pub const CellKind = enum(u2) { glyph, svg_fill, svg_stroke };

pub const Region = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const Cell = struct {
    page: u8,
    index: u8,
};

const Page = struct {
    class: u8 = 0,
    used_mask: u128 = 0,
    used_count: u8 = 0,
};

const Entry = struct {
    key: u64 = 0,
    cell: Cell = .{ .page = 0, .index = 0 },
    frame_used: u32 = 0,
};

const frame_in_use_count: u32 = 2;

const RetiredList = struct {
    cells: [cell_count_max]Cell = undefined,
    count: u32 = 0,
};

pub const CellCache = struct {
    glyph_atlas: []u8 = &.{},
    glyph_size: u32 = 0,
    svg_fill: []u8 = &.{},
    svg_stroke: []u8 = &.{},
    svg_size: u32 = 0,
    glyph_bytes_used: usize = 0,
    svg_bytes_used: usize = 0,

    entries: [slot_count]Entry = @splat(.{}),
    entry_count: u32 = 0,
    pages: [page_count_max]Page = @splat(.{}),
    page_count: u32 = 0,
    retired: [2]RetiredList = .{ .{}, .{} },
    retired_new: u1 = 0,
    frame: u32 = 0,

    staging: [staging_bytes_max]u8 = undefined,
    staging_address: u32 = 0,
    staging_len: u32 = 0,
    cell_bytes_frame: u32 = 0,

    const Self = @This();

    pub fn initInPlace(
        self: *Self,
        atlas: *const limits_mod.AtlasLimits,
        page_count: u32,
    ) !void {
        assert(atlas.check() == null);
        assert(atlas.text_size > 0);
        assert(page_count > 0);
        assert(page_count <= page_count_max);
        self.page_count = page_count;
        if (atlas.text_size > atlas_size_max) return error.EveGlyphAtlasTooLarge;
        if (atlas.svg_size > atlas_size_max) return error.EveSvgAtlasTooLarge;
        if (atlas.svg_icon_size_max > cell_size_max) return error.EveSvgIconsExceedCells;
        self.glyph_size = atlas.text_size;
        self.svg_size = atlas.svg_size;
        self.glyph_bytes_used = 0;
        self.svg_bytes_used = 0;
        self.forgetAll();
        self.cell_bytes_frame = 0;
        const glyph_bytes = atlas.text_size * atlas.text_size;
        const svg_bytes = atlas.svg_size * atlas.svg_size;
        self.glyph_atlas = try reservation.reserve(u8, glyph_bytes);
        errdefer reservation.release(u8, self.glyph_atlas, 0);
        self.svg_fill = try reservation.reserve(u8, svg_bytes);
        errdefer reservation.release(u8, self.svg_fill, 0);
        self.svg_stroke = try reservation.reserve(u8, svg_bytes);
        assert(self.entry_count == 0);
        assert(self.svg_stroke.len == self.svg_fill.len);
    }

    pub fn deinit(self: *Self) void {
        assert(self.glyph_bytes_used <= self.glyph_atlas.len);
        assert(self.svg_bytes_used <= self.svg_fill.len);
        reservation.release(u8, self.svg_stroke, self.svg_bytes_used);
        reservation.release(u8, self.svg_fill, self.svg_bytes_used);
        reservation.release(u8, self.glyph_atlas, self.glyph_bytes_used);
        self.glyph_atlas = &.{};
        self.svg_fill = &.{};
        self.svg_stroke = &.{};
    }

    pub fn uploadGlyphs(self: *Self, dirty: Region, pixels: []const u8) void {
        assert(dirty.x + dirty.w <= self.glyph_size);
        assert(dirty.y + dirty.h <= self.glyph_size);
        assert(pixels.len == @as(usize, dirty.w) * dirty.h);
        var row: u32 = 0;
        while (row < dirty.h) : (row += 1) {
            const target = (@as(usize, dirty.y) + row) * self.glyph_size + dirty.x;
            @memcpy(self.glyph_atlas[target..][0..dirty.w], pixels[row * dirty.w ..][0..dirty.w]);
        }
        const end = (@as(usize, dirty.y) + dirty.h) * self.glyph_size;
        self.glyph_bytes_used = @max(self.glyph_bytes_used, end);
        self.retireOverlapping(dirty, .glyph);
    }

    pub fn uploadSvgs(self: *Self, dirty: Region, pixels: []const u8) void {
        assert(dirty.x + dirty.w <= self.svg_size);
        assert(dirty.y + dirty.h <= self.svg_size);
        assert(pixels.len == @as(usize, dirty.w) * dirty.h * 4);
        var row: u32 = 0;
        while (row < dirty.h) : (row += 1) {
            const target = (@as(usize, dirty.y) + row) * self.svg_size + dirty.x;
            const source = pixels[@as(usize, row) * dirty.w * 4 ..][0 .. @as(usize, dirty.w) * 4];
            splitCoverage(
                source,
                self.svg_fill[target..][0..dirty.w],
                self.svg_stroke[target..][0..dirty.w],
            );
        }
        const end = (@as(usize, dirty.y) + dirty.h) * self.svg_size;
        self.svg_bytes_used = @max(self.svg_bytes_used, end);
        self.retireOverlapping(dirty, .svg_fill);
        self.retireOverlapping(dirty, .svg_stroke);
    }

    fn retireOverlapping(self: *Self, dirty: Region, kind: CellKind) void {
        assert(dirty.w > 0);
        assert(dirty.h > 0);
        var slot: u32 = 0;
        var visits: u32 = 0;
        while (slot < slot_count) {
            visits += 1;
            assert(visits <= 2 * slot_count);
            const entry = self.entries[slot];
            const stale = entry.key != 0 and keyKind(entry.key) == kind and
                overlaps(keyRegion(entry.key), dirty);
            if (stale) {
                const list = &self.retired[self.retired_new];
                list.cells[list.count] = entry.cell;
                list.count += 1;
                self.removeSlot(slot);
                continue;
            }
            slot += 1;
        }
        assert(self.retired[0].count + self.retired[1].count <= cell_count_max);
    }

    pub fn beginFrame(self: *Self) void {
        assert(self.staging_len == 0);
        const old = &self.retired[1 - self.retired_new];
        for (old.cells[0..old.count]) |cell| self.freeCell(cell);
        old.count = 0;
        self.retired_new = 1 - self.retired_new;
        self.frame +%= 1;
        self.cell_bytes_frame = 0;
        assert(self.retired[self.retired_new].count == 0);
    }

    pub fn lookup(
        self: *Self,
        chip: *Chip,
        kind: CellKind,
        region: Region,
        frame_number: u64,
    ) chip_mod.Error!Cell {
        assert(region.w > 0);
        assert(region.h > 0);
        const class = cellClass(@max(region.w, region.h)) orelse std.debug.panic(
            "EVE renderer: a {d}x{d} px {t} region in frame {d} exceeds the largest " ++
                "glyph cell ({d} px); draw it smaller",
            .{ region.w, region.h, kind, frame_number, cell_size_max },
        );
        const key = cacheKey(kind, region);
        const found = self.findSlot(key);
        if (self.entries[found].key == key) {
            self.entries[found].frame_used = self.frame;
            return self.entries[found].cell;
        }
        const cell = self.allocateCell(class) orelse cell: {
            self.dropIdle();
            break :cell self.allocateCell(class) orelse self.panicExhausted(class, frame_number);
        };
        const slot = self.findSlot(key);
        assert(self.entries[slot].key == 0);
        assert(self.entry_count < cell_count_max);
        self.entries[slot] = .{ .key = key, .cell = cell, .frame_used = self.frame };
        self.entry_count += 1;
        try self.stageCell(chip, kind, region, cell);
        return cell;
    }

    fn dropIdle(self: *Self) void {
        assert(self.entry_count <= cell_count_max);
        const live_before = self.liveCellCount();
        var slot: u32 = 0;
        var visits: u32 = 0;
        while (slot < slot_count) {
            visits += 1;
            assert(visits <= 2 * slot_count);
            const entry = self.entries[slot];
            if (entry.key != 0 and self.frame -% entry.frame_used >= frame_in_use_count) {
                self.freeCell(entry.cell);
                self.removeSlot(slot);
                continue;
            }
            slot += 1;
        }
        assert(self.liveCellCount() <= live_before);
    }

    pub fn flush(self: *Self, chip: *Chip) chip_mod.Error!void {
        assert(self.staging_len <= staging_bytes_max);
        if (self.staging_len == 0) return;
        const len = self.staging_len;
        self.staging_len = 0;
        try chip.writeMemory(self.staging_address, self.staging[0..len]);
    }

    pub fn forgetAll(self: *Self) void {
        self.entries = @splat(.{});
        self.entry_count = 0;
        self.pages = @splat(.{});
        self.retired[0].count = 0;
        self.retired[1].count = 0;
        self.retired_new = 0;
        self.staging_address = 0;
        self.staging_len = 0;
        assert(self.liveCellCount() == 0);
    }

    pub fn pageLayout(self: *const Self, page: u8) display_list.PageLayout {
        assert(page < page_count_max);
        assert(self.pages[page].used_count > 0);
        return .{
            .address = @as(u32, page) * page_bytes,
            .cell_size = cell_sizes[self.pages[page].class],
        };
    }

    pub fn pagesInUse(self: *const Self) u32 {
        var count: u32 = 0;
        for (self.pages[0..self.page_count]) |page| count += @intFromBool(page.used_count > 0);
        assert(count <= self.page_count);
        return count;
    }

    fn allocateCell(self: *Self, class: u32) ?Cell {
        assert(class < cell_sizes.len);
        const capacity = pageCapacity(class);
        var empty_page: ?u8 = null;
        assert(self.page_count <= page_count_max);
        for (self.pages[0..self.page_count], 0..) |*page, index| {
            if (page.used_count == 0) {
                if (empty_page == null) empty_page = @intCast(index);
                continue;
            }
            if (page.class != class or page.used_count >= capacity) continue;
            const free = @ctz(~page.used_mask);
            assert(free < capacity);
            return claim(page, @intCast(index), @intCast(free));
        }
        const index = empty_page orelse return null;
        const page = &self.pages[index];
        page.* = .{ .class = @intCast(class) };
        return claim(page, index, 0);
    }

    fn claim(page: *Page, page_index: u8, cell_index: u8) Cell {
        const bit = @as(u128, 1) << @intCast(cell_index);
        assert(page.used_mask & bit == 0);
        assert(page.used_count < pageCapacity(page.class));
        page.used_mask |= bit;
        page.used_count += 1;
        return .{ .page = page_index, .index = cell_index };
    }

    fn freeCell(self: *Self, cell: Cell) void {
        assert(cell.page < page_count_max);
        const page = &self.pages[cell.page];
        const bit = @as(u128, 1) << @intCast(cell.index);
        assert(page.used_mask & bit != 0);
        assert(page.used_count > 0);
        page.used_mask &= ~bit;
        page.used_count -= 1;
    }

    fn panicExhausted(self: *const Self, class: u32, frame_number: u64) noreturn {
        std.debug.panic(
            "EVE renderer: glyph cell pool exhausted in frame {d}: no free {d} px cell, " ++
                "{d} of {d} pages ({d} KiB of RAM_G) in use, {d} cells drawn in this frame " ++
                "or the last, {d} retiring. Draw fewer distinct glyphs and icons per frame.",
            .{
                frame_number,
                cell_sizes[class],
                self.pagesInUse(),
                self.page_count,
                self.page_count * page_bytes / 1024,
                self.entry_count,
                self.retired[0].count + self.retired[1].count,
            },
        );
    }

    fn liveCellCount(self: *const Self) u32 {
        var count: u32 = 0;
        for (self.pages) |page| count += page.used_count;
        return count;
    }

    fn stageCell(
        self: *Self,
        chip: *Chip,
        kind: CellKind,
        region: Region,
        cell: Cell,
    ) chip_mod.Error!void {
        const size = cell_sizes[self.pages[cell.page].class];
        assert(region.w <= size);
        assert(region.h <= size);
        const bytes = size * size;
        const address = @as(u32, cell.page) * page_bytes + @as(u32, cell.index) * bytes;
        const contiguous = self.staging_address + self.staging_len == address;
        const fits = contiguous and self.staging_len + bytes <= staging_bytes_max;
        if (self.staging_len > 0 and !fits) {
            try self.flush(chip);
        }
        if (self.staging_len == 0) self.staging_address = address;
        const plane, const stride = self.planeOf(kind);
        copyCell(plane, stride, region, self.staging[self.staging_len..][0..bytes], size);
        self.staging_len += bytes;
        self.cell_bytes_frame += bytes;
        assert(self.staging_len <= staging_bytes_max);
    }

    fn planeOf(self: *const Self, kind: CellKind) struct { []const u8, u32 } {
        return switch (kind) {
            .glyph => .{ self.glyph_atlas, self.glyph_size },
            .svg_fill => .{ self.svg_fill, self.svg_size },
            .svg_stroke => .{ self.svg_stroke, self.svg_size },
        };
    }

    fn findSlot(self: *const Self, key: u64) u32 {
        assert(key != 0);
        assert(self.entry_count < slot_count);
        var slot = homeSlot(key);
        var probes: u32 = 0;
        while (self.entries[slot].key != 0 and self.entries[slot].key != key) {
            probes += 1;
            assert(probes < slot_count);
            slot = (slot + 1) & (slot_count - 1);
        }
        return slot;
    }

    fn removeSlot(self: *Self, slot: u32) void {
        assert(self.entries[slot].key != 0);
        assert(self.entry_count > 0);
        var hole = slot;
        var next = (hole + 1) & (slot_count - 1);
        var probes: u32 = 0;
        while (self.entries[next].key != 0) : (next = (next + 1) & (slot_count - 1)) {
            probes += 1;
            assert(probes < slot_count);
            const home = homeSlot(self.entries[next].key);
            const from_home = (next -% home) & (slot_count - 1);
            const from_hole = (next -% hole) & (slot_count - 1);
            if (from_home >= from_hole) {
                self.entries[hole] = self.entries[next];
                hole = next;
            }
        }
        self.entries[hole] = .{};
        self.entry_count -= 1;
    }
};

fn homeSlot(key: u64) u32 {
    assert(key != 0);
    return @truncate(std.hash.int(key) & (slot_count - 1));
}

fn pageCapacity(class: u32) u32 {
    assert(class < cell_sizes.len);
    const size = cell_sizes[class];
    return @min(page_cell_count_max, page_bytes / (size * size));
}

fn cellClass(extent: u32) ?u32 {
    assert(extent > 0);
    for (cell_sizes, 0..) |size, class| {
        if (extent <= size) return @intCast(class);
    }
    return null;
}

fn cacheKey(kind: CellKind, region: Region) u64 {
    assert(region.x < 8192);
    assert(region.y < 8192);
    assert(region.w <= cell_size_max);
    assert(region.h <= cell_size_max);
    return (1 << 63) | (@as(u64, @backingInt(kind)) << 42) | (@as(u64, region.x) << 29) |
        (@as(u64, region.y) << 16) | (@as(u64, region.w) << 8) | region.h;
}

fn keyKind(key: u64) CellKind {
    return @fromBackingInt(@intCast(@as(u2, @truncate(key >> 42))));
}

fn keyRegion(key: u64) Region {
    return .{
        .x = @as(u32, @truncate(key >> 29)) & 0x1FFF,
        .y = @as(u32, @truncate(key >> 16)) & 0x1FFF,
        .w = @as(u32, @truncate(key >> 8)) & 0xFF,
        .h = @as(u32, @truncate(key)) & 0xFF,
    };
}

fn overlaps(a: Region, b: Region) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

fn splitCoverage(rgba: []const u8, fill: []u8, stroke: []u8) void {
    assert(rgba.len == fill.len * 4);
    assert(fill.len == stroke.len);
    for (fill, stroke, 0..) |*f, *s, index| {
        const red = rgba[index * 4];
        const green = rgba[index * 4 + 1];
        f.* = if (red > svg_coverage_min) red else 0;
        s.* = if (green > svg_coverage_min) green else 0;
    }
}

fn copyCell(plane: []const u8, stride: u32, region: Region, target: []u8, size: u32) void {
    assert(target.len == size * size);
    assert((region.y + region.h - 1) * stride + region.x + region.w <= plane.len);
    @memset(target, 0);
    var row: u32 = 0;
    while (row < region.h) : (row += 1) {
        const source = (@as(usize, region.y) + row) * stride + region.x;
        @memcpy(target[row * size ..][0..region.w], plane[source..][0..region.w]);
    }
}

const testing = std.testing;

fn testCache(cache: *CellCache) !void {
    try cache.initInPlace(&limits_mod.AtlasLimits.nano, page_count_max);
}

test "a glyph uploads once into a zero-padded cell and later draws reuse it" {
    var chip: Chip = .{};
    try chip.openSimulated(null);
    defer chip.close();
    const cache = try testing.allocator.create(CellCache);
    defer testing.allocator.destroy(cache);
    try testCache(cache);
    defer cache.deinit();
    cache.uploadGlyphs(.{ .x = 5, .y = 4, .w = 3, .h = 2 }, &.{ 10, 20, 30, 40, 50, 60 });
    cache.beginFrame();
    const region = Region{ .x = 5, .y = 4, .w = 3, .h = 2 };
    const first = try cache.lookup(&chip, .glyph, region, 1);
    const second = try cache.lookup(&chip, .glyph, region, 1);
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(u32, 64), cache.cell_bytes_frame);
    try cache.flush(&chip);
    const cell = chip.sim_memory[0..64];
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 0 }, cell[0..4]);
    try testing.expectEqualSlices(u8, &.{ 40, 50, 60, 0 }, cell[8..12]);
    try testing.expect(std.mem.allEqual(u8, cell[16..], 0));
}

test "a rewritten atlas region retires its cell, which frees two frames later" {
    var chip: Chip = .{};
    try chip.openSimulated(null);
    defer chip.close();
    const cache = try testing.allocator.create(CellCache);
    defer testing.allocator.destroy(cache);
    try testCache(cache);
    defer cache.deinit();
    const region = Region{ .x = 0, .y = 0, .w = 8, .h = 8 };
    cache.beginFrame();
    const cell = try cache.lookup(&chip, .glyph, region, 1);
    try cache.flush(&chip);
    cache.uploadGlyphs(.{ .x = 7, .y = 7, .w = 1, .h = 1 }, &.{255});
    try testing.expectEqual(@as(u32, 0), cache.entry_count);
    cache.beginFrame();
    const other = try cache.lookup(&chip, .glyph, .{ .x = 16, .y = 0, .w = 8, .h = 8 }, 2);
    try testing.expect(!std.meta.eql(cell, other));
    try cache.flush(&chip);
    cache.beginFrame();
    const reused = try cache.lookup(&chip, .glyph, .{ .x = 32, .y = 0, .w = 8, .h = 8 }, 3);
    try testing.expectEqual(cell, reused);
    try cache.flush(&chip);
}

test "removal keeps every other key of a probe chain reachable" {
    var chip: Chip = .{};
    try chip.openSimulated(null);
    defer chip.close();
    const cache = try testing.allocator.create(CellCache);
    defer testing.allocator.destroy(cache);
    try testCache(cache);
    defer cache.deinit();
    cache.beginFrame();
    var index: u32 = 0;
    while (index < 300) : (index += 1) {
        _ = try cache.lookup(&chip, .glyph, .{ .x = index, .y = 0, .w = 1, .h = 1 }, 1);
    }
    try cache.flush(&chip);
    index = 0;
    while (index < 300) : (index += 3) {
        cache.uploadGlyphs(.{ .x = index, .y = 0, .w = 1, .h = 1 }, &.{0});
    }
    try testing.expectEqual(@as(u32, 200), cache.entry_count);
    const staged = cache.cell_bytes_frame;
    index = 0;
    while (index < 300) : (index += 1) {
        if (index % 3 == 0) continue;
        _ = try cache.lookup(&chip, .glyph, .{ .x = index, .y = 0, .w = 1, .h = 1 }, 1);
    }
    try testing.expectEqual(staged, cache.cell_bytes_frame);
    try cache.flush(&chip);
}

test "the page pool fills exactly, then the next size class has no page" {
    const cache = try testing.allocator.create(CellCache);
    defer testing.allocator.destroy(cache);
    try testCache(cache);
    defer cache.deinit();
    const class: u32 = cell_sizes.len - 1;
    var count: u32 = 0;
    while (count < page_count_max * 4) : (count += 1) {
        try testing.expect(cache.allocateCell(class) != null);
    }
    try testing.expectEqual(page_count_max, cache.pagesInUse());
    try testing.expectEqual(@as(?Cell, null), cache.allocateCell(class));
    try testing.expectEqual(@as(?Cell, null), cache.allocateCell(0));
}

test "glyphs churned over many frames reuse idle cells and keep the shown list's cells" {
    var chip: Chip = .{};
    try chip.openSimulated(null);
    defer chip.close();
    const cache = try testing.allocator.create(CellCache);
    defer testing.allocator.destroy(cache);
    try testCache(cache);
    defer cache.deinit();
    try testing.expectEqual(@as(u32, 128), pageCapacity(1));
    try testing.expect(120 * 40 > page_count_max * pageCapacity(1));
    churnFillAtlas(cache);
    var steady: [8]Cell = undefined;
    var previous: [48]Cell = undefined;
    var current: [48]Cell = undefined;
    var fresh: u32 = 0;
    var frame: u32 = 0;
    while (frame < 120) : (frame += 1) {
        cache.beginFrame();
        for (&current, 0..) |*cell, index| {
            const steady_glyph = index < steady.len;
            const region = if (steady_glyph) churnRegion(@intCast(index)) else region: {
                fresh += 1;
                break :region churnRegion(@as(u32, steady.len) + fresh);
            };
            cell.* = try cache.lookup(&chip, .glyph, region, frame);
            if (steady_glyph and frame == 0) steady[index] = cell.*;
            if (steady_glyph) try testing.expectEqual(steady[index], cell.*);
            if (frame > 0 and !steady_glyph) {
                for (previous) |shown| try testing.expect(!std.meta.eql(shown, cell.*));
            }
        }
        try cache.flush(&chip);
        for (current, 0..) |cell, index| {
            const region = if (index < steady.len)
                churnRegion(@intCast(index))
            else
                churnRegion(@intCast(steady.len + fresh - (current.len - 1 - index)));
            try expectCellHolds(cache, &chip, cell, region);
        }
        previous = current;
    }
}

fn churnRegion(number: u32) Region {
    assert(number < 1024 * 8);
    return .{
        .x = (number % 32) * 16,
        .y = (number / 32 % 32) * 16,
        .w = 16 - number / 1024,
        .h = 16,
    };
}

fn churnFillAtlas(cache: *CellCache) void {
    assert(cache.glyph_size == 512);
    assert(cache.entry_count == 0);
    for (cache.glyph_atlas[0 .. 512 * 512], 0..) |*texel, index| {
        texel.* = @truncate(index % 512 * 7 + index / 512 * 13);
    }
    cache.glyph_bytes_used = 512 * 512;
}

fn expectCellHolds(cache: *const CellCache, chip: *const Chip, cell: Cell, region: Region) !void {
    const layout = cache.pageLayout(cell.page);
    const size = layout.cell_size;
    assert(region.w <= size);
    const base = layout.address + @as(u32, cell.index) * size * size;
    var row: u32 = 0;
    while (row < region.h) : (row += 1) {
        const source = (region.y + row) * cache.glyph_size + region.x;
        try testing.expectEqualSlices(
            u8,
            cache.glyph_atlas[source..][0..region.w],
            chip.sim_memory[base + row * size ..][0..region.w],
        );
    }
}

test "SVG uploads split fill and stroke coverage and drop channel bleed" {
    const cache = try testing.allocator.create(CellCache);
    defer testing.allocator.destroy(cache);
    try testCache(cache);
    defer cache.deinit();
    cache.uploadSvgs(.{ .x = 0, .y = 0, .w = 2, .h = 1 }, &.{ 200, 5, 0, 255, 4, 90, 0, 255 });
    try testing.expectEqualSlices(u8, &.{ 200, 0 }, cache.svg_fill[0..2]);
    try testing.expectEqualSlices(u8, &.{ 0, 90 }, cache.svg_stroke[0..2]);
}
