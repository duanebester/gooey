const std = @import("std");
const atlas_mod = @import("atlas.zig");
const builtin = @import("builtin");
const types = @import("types.zig");
const font_face_mod = @import("font_face.zig");
const platform = @import("../platform/mod.zig");

const Atlas = @import("atlas.zig").Atlas;
const Region = @import("atlas.zig").Region;
const AtlasUploads = @import("atlas.zig").AtlasUploads;
const limits = @import("../core/limits.zig");
const reservation = @import("../core/reservation.zig");

const assert = std.debug.assert;

pub const AtlasOptions = struct {
    size: u32,
    uploads: *AtlasUploads,
};

const FontFace = font_face_mod.FontFace;
const RasterizedGlyph = types.RasterizedGlyph;
const SUBPIXEL_VARIANTS_X = types.SUBPIXEL_VARIANTS_X;
const SUBPIXEL_VARIANTS_Y = types.SUBPIXEL_VARIANTS_Y;

const is_wasm = platform.is_wasm;
const is_linux = platform.is_linux;
const is_windows = platform.is_windows;

pub const GlyphKey = struct {
    font_ptr: usize,
    glyph_id: u16,
    size_fixed: u16,
    scale_fixed: u8,
    subpixel_x: u8,
    subpixel_y: u8,

    pub inline fn init(face: FontFace, glyph_id: u16, font_size: f32, scale: f32, subpixel_x: u8, subpixel_y: u8) GlyphKey {
        return .{
            .font_ptr = @intFromPtr(face.ptr),
            .glyph_id = glyph_id,
            .size_fixed = @intFromFloat(font_size * 64.0),
            .scale_fixed = @intFromFloat(@max(1.0, @min(4.0, scale))),
            .subpixel_x = subpixel_x,
            .subpixel_y = subpixel_y,
        };
    }

    pub inline fn initWithFontPtr(font_ptr: usize, glyph_id: u16, size: f32, scale: f32, subpixel_x: u8, subpixel_y: u8) GlyphKey {
        return .{
            .font_ptr = font_ptr,
            .glyph_id = glyph_id,
            .size_fixed = @intFromFloat(size * 64.0),
            .scale_fixed = @intFromFloat(@max(1.0, @min(4.0, scale))),
            .subpixel_x = subpixel_x,
            .subpixel_y = subpixel_y,
        };
    }

    pub fn hash(self: GlyphKey) u64 {
        const fields: u64 = @as(u64, self.glyph_id) |
            (@as(u64, self.size_fixed) << 16) |
            (@as(u64, self.scale_fixed) << 32) |
            (@as(u64, self.subpixel_x) << 40) |
            (@as(u64, self.subpixel_y) << 48);

        const ptr_u64: u64 = @intCast(self.font_ptr);

        const PRIME_A: u64 = 0x9E3779B97F4A7C15;
        const PRIME_B: u64 = 0xBF58476D1CE4E5B9;

        var h = (ptr_u64 ^ PRIME_A) *% (fields ^ PRIME_B);
        h = (h ^ (h >> 32)) *% PRIME_A;
        return h ^ (h >> 32);
    }

    pub fn eql(a: GlyphKey, b: GlyphKey) bool {
        return a.font_ptr == b.font_ptr and
            a.glyph_id == b.glyph_id and
            a.size_fixed == b.size_fixed and
            a.scale_fixed == b.scale_fixed and
            a.subpixel_x == b.subpixel_x and
            a.subpixel_y == b.subpixel_y;
    }
};

pub const CachedGlyph = struct {
    region: Region,
    offset_x: i32,
    offset_y: i32,
    advance_x: f32,
    is_color: bool,
    atlas_size: u32,

    pub fn uv(self: CachedGlyph) atlas_mod.UVCoords {
        return self.region.uv(self.atlas_size);
    }
};

const GlyphEntry = struct {
    key: GlyphKey,
    glyph: CachedGlyph,
    shelf: u16,
    generation: u32,
    valid: bool,
    frame_verified: u64,
};

const Lookup = union(enum) {
    stale: u16,
    miss,
};

pub const GlyphCache = struct {
    allocator: std.mem.Allocator,

    entries: []GlyphEntry,
    hash_table: []u16,
    entry_count: u32,
    entry_high_water: u16,
    hash_written: bool,

    free_chain: []u16,
    next_free: u16,

    grayscale_atlas: Atlas,

    render_buffer: []u8,
    render_buffer_size: u32,
    scale_factor: f32,

    const Self = @This();

    const MAX_PROBE_LENGTH: usize = 64;
    const slot_empty: u16 = 0;
    const RENDER_BUFFER_SIZE: u32 = limits.MAX_GLYPH_SIZE;

    pub fn hashSlotCount(glyph_count_max: u32) u32 {
        assert(glyph_count_max > 0);
        assert(glyph_count_max <= limits.TextLimits.ceiling.glyph_cache_count_max);
        return std.math.ceilPowerOfTwoAssert(u32, 2 * glyph_count_max);
    }

    pub noinline fn initInPlace(
        self: *Self,
        allocator: std.mem.Allocator,
        scale: f32,
        glyph_count_max: u32,
        atlas_options: AtlasOptions,
    ) !void {
        assert(scale > 0);
        assert(scale <= 4.0);

        self.entries = try reservation.reserve(GlyphEntry, glyph_count_max);
        errdefer reservation.release(GlyphEntry, self.entries, 0);

        self.free_chain = try reservation.reserve(u16, glyph_count_max);
        errdefer reservation.release(u16, self.free_chain, 0);

        self.hash_table = try reservation.reserveZeroed(u16, hashSlotCount(glyph_count_max));
        errdefer reservation.release(u16, self.hash_table, 0);

        const buffer_bytes = RENDER_BUFFER_SIZE * RENDER_BUFFER_SIZE;
        const render_buffer = try allocator.alloc(u8, buffer_bytes);
        errdefer allocator.free(render_buffer);

        try self.grayscale_atlas.init(allocator, .{
            .kind = .text,
            .size = atlas_options.size,
            .uploads = atlas_options.uploads,
        });

        self.allocator = allocator;
        self.entry_count = 0;
        self.entry_high_water = 0;
        self.hash_written = false;
        self.next_free = slot_empty;
        self.render_buffer = render_buffer;
        self.render_buffer_size = buffer_bytes;
        self.scale_factor = scale;

        assert(self.entries.len == glyph_count_max);
        assert(self.hash_table.len >= 2 * self.entries.len);
    }

    pub fn setScaleFactor(self: *Self, scale: f32) void {
        std.debug.assert(scale > 0);
        std.debug.assert(scale <= 4.0);

        if (self.scale_factor != scale) {
            self.scale_factor = scale;
            self.clear();
        }
    }

    pub fn deinit(self: *Self) void {
        assert(self.entry_count <= self.entry_high_water);
        assert(self.entry_high_water <= self.entries.len);
        self.grayscale_atlas.deinit();
        self.allocator.free(self.render_buffer);
        const hash_used = if (self.hash_written) self.hash_table.len else 0;
        reservation.release(u16, self.hash_table, hash_used);
        reservation.release(u16, self.free_chain, self.entry_high_water);
        reservation.release(GlyphEntry, self.entries, self.entry_high_water);
        self.* = undefined;
    }

    fn freeSlot(self: *Self, index: u16) void {
        assert(index < self.entry_high_water);
        assert(!self.entries[index].valid);
        self.free_chain[index] = self.next_free;
        self.next_free = index + 1;
    }

    fn claimSlot(self: *Self) u16 {
        if (self.next_free != slot_empty) {
            const index = self.next_free - 1;
            self.next_free = self.free_chain[index];
            assert(!self.entries[index].valid);
            return index;
        }
        assert(self.entry_high_water < self.entries.len);
        const index = self.entry_high_water;
        self.entry_high_water += 1;
        return index;
    }

    fn hasFreeSlot(self: *const Self) bool {
        return self.next_free != slot_empty or self.entry_high_water < self.entries.len;
    }

    fn lookup(self: *Self, key: GlyphKey) Lookup {
        std.debug.assert(key.font_ptr != 0);
        std.debug.assert(key.subpixel_x < SUBPIXEL_VARIANTS_X);

        const entry = self.findEntry(key) orelse return .miss;
        std.debug.assert(!self.grayscale_atlas.isLive(entry.shelf, entry.generation));
        const offset = @intFromPtr(entry) - @intFromPtr(self.entries.ptr);
        const index: u16 = @intCast(@divExact(offset, @sizeOf(GlyphEntry)));
        assert(index < self.entry_high_water);
        return .{ .stale = index };
    }

    inline fn lookupHit(self: *Self, key: GlyphKey, frame: u64) ?*const CachedGlyph {
        std.debug.assert(frame > 0);
        const entry = self.findEntry(key) orelse return null;
        if (entry.frame_verified == frame) {
            if (std.debug.runtime_safety) {
                std.debug.assert(self.grayscale_atlas.isLive(entry.shelf, entry.generation));
            }
            return &entry.glyph;
        }
        if (!self.grayscale_atlas.isLive(entry.shelf, entry.generation)) return null;
        self.grayscale_atlas.touch(entry.shelf, frame);
        entry.frame_verified = frame;
        return &entry.glyph;
    }

    inline fn findEntry(self: *const Self, key: GlyphKey) ?*GlyphEntry {
        const hash_table = self.hash_table;
        const entries = self.entries;
        const mask = hash_table.len - 1;
        var probe: usize = @as(usize, @truncate(key.hash())) & mask;

        for (0..MAX_PROBE_LENGTH) |_| {
            const stored = hash_table[probe];
            if (stored == slot_empty) return null;

            const entry_idx = stored - 1;
            assert(entry_idx < entries.len);
            const entry = &entries[entry_idx];
            if (entry.valid and GlyphKey.eql(entry.key, key)) return entry;

            probe = (probe + 1) & mask;
        }

        return null;
    }

    fn store(self: *Self, key: GlyphKey, lookup_result: Lookup, rendered: Rendered) void {
        assert(key.font_ptr != 0);
        assert(self.entry_count <= self.entries.len);
        const entry: GlyphEntry = .{
            .key = key,
            .glyph = rendered.glyph,
            .shelf = rendered.shelf,
            .generation = rendered.generation,
            .valid = true,
            .frame_verified = 0,
        };
        switch (lookup_result) {
            .stale => |index| {
                std.debug.assert(GlyphKey.eql(self.entries[index].key, key));
                self.entries[index] = entry;
                return;
            },
            .miss => {},
        }
        if (!self.hasFreeSlot()) self.makeRoom();

        const idx = self.claimSlot();
        self.entries[idx] = entry;
        self.entry_count += 1;
        self.insertIntoHashTable(key, idx);

        assert(self.entry_count <= self.entries.len);
    }

    fn makeRoom(self: *Self) void {
        assert(!self.hasFreeSlot());
        assert(self.entry_count == self.entries.len);
        var attempt: usize = 0;
        while (attempt <= self.grayscale_atlas.shelves.len) : (attempt += 1) {
            if (self.reclaimStale() > 0) return;
            if (!self.grayscale_atlas.evictOne()) break;
        }
        std.debug.panic("text pool 'glyph cache' exhausted: capacity {d}, {d} in use, " ++
            "1 requested, every glyph used since frame {d}. " ++
            "Raise ResourceLimits.text.glyph_cache_count_max.", .{
            self.entries.len,
            self.entry_count,
            self.grayscale_atlas.uploads.frameCurrent(),
        });
    }

    fn reclaimStale(self: *Self) u32 {
        const claimed = self.entries[0..self.entry_high_water];
        var freed: u32 = 0;
        for (claimed, 0..) |*entry, index| {
            if (!entry.valid) continue;
            if (self.grayscale_atlas.isLive(entry.shelf, entry.generation)) continue;
            entry.valid = false;
            self.freeSlot(@intCast(index));
            freed += 1;
        }
        if (freed == 0) return 0;
        assert(self.entry_count >= freed);
        self.entry_count -= freed;
        @memset(self.hash_table, slot_empty);
        for (claimed, 0..) |*entry, index| {
            if (entry.valid) self.insertIntoHashTable(entry.key, @intCast(index));
        }
        return freed;
    }

    fn insertIntoHashTable(self: *Self, key: GlyphKey, entry_idx: u16) void {
        assert(entry_idx < self.entry_high_water);

        const hash_table = self.hash_table;
        const mask = hash_table.len - 1;
        var probe: usize = @as(usize, @truncate(key.hash())) & mask;
        self.hash_written = true;

        for (0..MAX_PROBE_LENGTH) |_| {
            if (hash_table[probe] == slot_empty) {
                hash_table[probe] = entry_idx + 1;
                return;
            }
            probe = (probe + 1) & mask;
        }

        unreachable;
    }

    const Rendered = struct {
        glyph: CachedGlyph,
        shelf: u16,
        generation: u32,
        cached: bool,
    };

    pub inline fn getOrRenderSubpixel(
        self: *Self,
        face: FontFace,
        glyph_id: u16,
        font_size: f32,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !CachedGlyph {
        const key = GlyphKey.init(face, glyph_id, font_size, self.scale_factor, subpixel_x, subpixel_y);
        return self.getOrRenderKey(face, key, font_size, self.frameCurrent());
    }

    pub inline fn frameCurrent(self: *const Self) u64 {
        return self.grayscale_atlas.uploads.frameCurrent();
    }

    pub inline fn getOrRenderKey(
        self: *Self,
        face: FontFace,
        key: GlyphKey,
        font_size: f32,
        frame: u64,
    ) !CachedGlyph {
        std.debug.assert(key.font_ptr == @intFromPtr(face.ptr));
        std.debug.assert(key.size_fixed == @as(u16, @intFromFloat(font_size * 64.0)));
        if (self.lookupHit(key, frame)) |glyph| return glyph.*;
        return self.renderAndStore(face, key.glyph_id, font_size, key.subpixel_x, key.subpixel_y);
    }

    noinline fn renderAndStore(
        self: *Self,
        face: FontFace,
        glyph_id: u16,
        font_size: f32,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !CachedGlyph {
        const scale = self.scale_factor;
        const key = GlyphKey.init(face, glyph_id, font_size, scale, subpixel_x, subpixel_y);
        const found = self.lookup(key);
        const rendered = try self.renderGlyphSubpixel(
            face,
            glyph_id,
            font_size,
            subpixel_x,
            subpixel_y,
        );
        if (rendered.cached) self.store(key, found, rendered);
        return rendered.glyph;
    }

    fn renderGlyphSubpixel(
        self: *Self,
        face: FontFace,
        glyph_id: u16,
        font_size: f32,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !Rendered {
        std.debug.assert(subpixel_x < SUBPIXEL_VARIANTS_X);
        std.debug.assert(subpixel_y < SUBPIXEL_VARIANTS_Y);

        @memset(self.render_buffer, 0);

        const subpixel_shift_x = @as(f32, @floatFromInt(subpixel_x)) / @as(f32, @floatFromInt(SUBPIXEL_VARIANTS_X));
        const subpixel_shift_y = @as(f32, @floatFromInt(subpixel_y)) / @as(f32, @floatFromInt(SUBPIXEL_VARIANTS_Y));

        const rasterized = try face.renderGlyphSubpixel(
            glyph_id,
            font_size,
            self.scale_factor,
            subpixel_shift_x,
            subpixel_shift_y,
            self.render_buffer,
            self.render_buffer_size,
        );
        return self.placeRasterized(rasterized);
    }

    fn placeRasterized(self: *Self, rasterized: RasterizedGlyph) Rendered {
        var rendered: Rendered = .{
            .glyph = .{
                .region = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .offset_x = rasterized.offset_x,
                .offset_y = rasterized.offset_y,
                .advance_x = rasterized.advance_x,
                .is_color = rasterized.is_color,
                .atlas_size = self.grayscale_atlas.size,
            },
            .shelf = atlas_mod.shelf_none,
            .generation = 0,
            .cached = true,
        };

        if (rasterized.width == 0 or rasterized.height == 0) return rendered;
        std.debug.assert(rasterized.width <= RENDER_BUFFER_SIZE);
        std.debug.assert(rasterized.height <= RENDER_BUFFER_SIZE);

        const width = rasterized.width;
        const height = rasterized.height;
        const pixels = self.render_buffer[0 .. width * height];
        const placement = self.grayscale_atlas.insert(width, height, pixels) orelse {
            rendered.cached = false;
            return rendered;
        };
        rendered.glyph.region = placement.region;
        rendered.shelf = placement.shelf;
        rendered.generation = placement.generation;
        return rendered;
    }

    pub fn getOrRenderFallback(
        self: *Self,
        font_ptr: *anyopaque,
        glyph_id: u16,
        font_size: f32,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !CachedGlyph {
        const key = GlyphKey.initWithFontPtr(
            @intFromPtr(font_ptr),
            glyph_id,
            font_size,
            self.scale_factor,
            subpixel_x,
            subpixel_y,
        );

        if (self.lookupHit(key, self.frameCurrent())) |glyph| return glyph.*;
        const found = self.lookup(key);

        const rendered = try self.renderFallbackGlyph(
            font_ptr,
            glyph_id,
            font_size,
            subpixel_x,
            subpixel_y,
        );
        if (rendered.cached) self.store(key, found, rendered);
        return rendered.glyph;
    }

    fn renderFallbackGlyph(
        self: *Self,
        font_ptr: *anyopaque,
        glyph_id: u16,
        font_size: f32,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !Rendered {
        std.debug.assert(font_size > 0);
        if (is_wasm) {
            return error.FallbackNotSupported;
        }
        if (is_windows) {
            return error.FallbackNotSupported;
        }

        std.debug.assert(subpixel_x < SUBPIXEL_VARIANTS_X);
        std.debug.assert(subpixel_y < SUBPIXEL_VARIANTS_Y);

        @memset(self.render_buffer, 0);

        const subpixel_shift_x = @as(f32, @floatFromInt(subpixel_x)) / @as(f32, @floatFromInt(SUBPIXEL_VARIANTS_X));
        const subpixel_shift_y = @as(f32, @floatFromInt(subpixel_y)) / @as(f32, @floatFromInt(SUBPIXEL_VARIANTS_Y));

        const rasterized = if (is_linux) blk: {
            const FreeTypeFace = @import("backends/freetype/face.zig").FreeTypeFace;
            break :blk try FreeTypeFace.renderGlyphFromFont(
                @ptrCast(@alignCast(font_ptr)),
                glyph_id,
                font_size,
                self.scale_factor,
                subpixel_shift_x,
                subpixel_shift_y,
                self.render_buffer,
                self.render_buffer_size,
            );
        } else blk: {
            const CoreTextFace = @import("backends/coretext/face.zig").CoreTextFace;
            break :blk try CoreTextFace.renderGlyphFromFont(
                font_ptr,
                glyph_id,
                font_size,
                self.scale_factor,
                subpixel_shift_x,
                subpixel_shift_y,
                self.render_buffer,
                self.render_buffer_size,
            );
        };
        return self.placeRasterized(rasterized);
    }

    pub fn clear(self: *Self) void {
        self.next_free = slot_empty;
        for (self.entries[0..self.entry_high_water], 0..) |*entry, index| {
            entry.valid = false;
            self.freeSlot(@intCast(index));
        }
        if (self.hash_written) @memset(self.hash_table, slot_empty);

        self.entry_count = 0;
        self.grayscale_atlas.clear();

        assert(self.entry_count == 0);
        assert(self.hasFreeSlot());
    }

    pub inline fn getAtlas(self: *const Self) *const Atlas {
        return &self.grayscale_atlas;
    }
};

test "GlyphKey size encoding" {
    const testing = std.testing;

    const key_16 = GlyphKey.initWithFontPtr(0x1234, 65, 16.0, 1.0, 0, 0);
    const key_24 = GlyphKey.initWithFontPtr(0x1234, 65, 24.0, 1.0, 0, 0);
    const key_32 = GlyphKey.initWithFontPtr(0x1234, 65, 32.0, 1.0, 0, 0);

    try testing.expectEqual(@as(u16, 16 * 64), key_16.size_fixed);
    try testing.expectEqual(@as(u16, 24 * 64), key_24.size_fixed);
    try testing.expectEqual(@as(u16, 32 * 64), key_32.size_fixed);

    try testing.expect(!GlyphKey.eql(key_16, key_24));
    try testing.expect(!GlyphKey.eql(key_16, key_32));
    try testing.expect(!GlyphKey.eql(key_24, key_32));

    const key_16_dup = GlyphKey.initWithFontPtr(0x1234, 65, 16.0, 1.0, 0, 0);
    try testing.expect(GlyphKey.eql(key_16, key_16_dup));
}

test "GlyphKey size hash distribution" {
    const testing = std.testing;

    const hash_14 = GlyphKey.initWithFontPtr(0x1234, 65, 14.0, 1.0, 0, 0).hash();
    const hash_16 = GlyphKey.initWithFontPtr(0x1234, 65, 16.0, 1.0, 0, 0).hash();
    const hash_18 = GlyphKey.initWithFontPtr(0x1234, 65, 18.0, 1.0, 0, 0).hash();

    try testing.expect(hash_14 != hash_16);
    try testing.expect(hash_16 != hash_18);
    try testing.expect(hash_14 != hash_18);
}

test "GlyphKey subpixel variants" {
    const testing = std.testing;

    const key_sub0 = GlyphKey.initWithFontPtr(0x1234, 65, 16.0, 1.0, 0, 0);
    const key_sub1 = GlyphKey.initWithFontPtr(0x1234, 65, 16.0, 1.0, 1, 0);
    const key_sub2 = GlyphKey.initWithFontPtr(0x1234, 65, 16.0, 1.0, 2, 0);

    try testing.expect(!GlyphKey.eql(key_sub0, key_sub1));
    try testing.expect(!GlyphKey.eql(key_sub1, key_sub2));

    try testing.expect(key_sub0.hash() != key_sub1.hash());
    try testing.expect(key_sub1.hash() != key_sub2.hash());
}

test "GlyphKey wyhash distribution — printable ASCII × subpixel variants" {
    const testing = std.testing;
    const glyph_count = limits.TextLimits.standard.glyph_cache_count_max;
    const TABLE_SLOTS: u32 = comptime GlyphCache.hashSlotCount(glyph_count);
    var buckets: [TABLE_SLOTS]u16 = @splat(0);

    const font_ptr: usize = if (@sizeOf(usize) == 8) 0x7FFF_0000_1000 else 0x7FFF_1000;
    var total_keys: u32 = 0;

    var glyph_id: u16 = 32;
    while (glyph_id <= 126) : (glyph_id += 1) {
        for (0..SUBPIXEL_VARIANTS_X) |sx| {
            const key = GlyphKey.initWithFontPtr(font_ptr, glyph_id, 14.0, 2.0, @intCast(sx), 0);
            const slot = @as(u32, @truncate(key.hash())) % TABLE_SLOTS;
            buckets[slot] += 1;
            total_keys += 1;
        }
    }

    var collisions: u32 = 0;
    for (buckets) |count| {
        if (count > 1) {
            collisions += count - 1;
        }
    }

    const collision_rate = @as(f64, @floatFromInt(collisions)) / @as(f64, @floatFromInt(total_keys));
    try testing.expect(collision_rate < 0.05);

    try testing.expectEqual(@as(u32, 95) * @as(u32, SUBPIXEL_VARIANTS_X), total_keys);
}
