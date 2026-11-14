//! Glyph cache - maps (font_id, glyph_id, size, subpixel) to atlas regions
//!
//! Renders glyphs on-demand using the FontFace interface and caches
//! them in the texture atlas.
//!
//! Uses fixed-capacity hash table (no dynamic allocation after init).

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

/// Where the glyph atlas comes from: its fixed side and the shared upload journal.
pub const AtlasOptions = struct {
    /// `AtlasLimits.text_size`.
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

/// Key for glyph lookup - includes subpixel variant
pub const GlyphKey = struct {
    /// Font identifier (pointer-based)
    font_ptr: usize,
    /// Glyph ID from the font
    glyph_id: u16,
    /// Font size in 1/64th points (for subpixel precision)
    size_fixed: u16,
    /// Scale factor (1-4x)
    scale_fixed: u8,
    /// Subpixel X variant (0 to SUBPIXEL_VARIANTS_X - 1)
    subpixel_x: u8,
    /// Subpixel Y variant (0 to SUBPIXEL_VARIANTS_Y - 1)
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

    /// Create key for a fallback font (uses raw CTFontRef pointer)
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

    /// Compute hash using wyhash-style 2-multiply mix.
    /// Packs non-pointer fields into a single u64 (56 bits: 16+16+8+8+8)
    /// then mixes with the font pointer in two dependent multiplies.
    /// Two multiplies instead of a 15-round FNV-1a serial chain: they
    /// have excellent avalanche properties and allow instruction-level
    /// parallelism on the pack and pointer loads.
    pub fn hash(self: GlyphKey) u64 {
        // Pack glyph_id(16) | size_fixed(16) | scale_fixed(8) | subpixel_x(8) | subpixel_y(8).
        const fields: u64 = @as(u64, self.glyph_id) |
            (@as(u64, self.size_fixed) << 16) |
            (@as(u64, self.scale_fixed) << 32) |
            (@as(u64, self.subpixel_x) << 40) |
            (@as(u64, self.subpixel_y) << 48);

        // Convert to u64 for platform independence (wasm32 has 32-bit usize).
        const ptr_u64: u64 = @intCast(self.font_ptr);

        const PRIME_A: u64 = 0x9E3779B97F4A7C15; // golden ratio fractional bits
        const PRIME_B: u64 = 0xBF58476D1CE4E5B9;

        // Two dependent multiplies with xor-shift finalization.
        var h = (ptr_u64 ^ PRIME_A) *% (fields ^ PRIME_B);
        h = (h ^ (h >> 32)) *% PRIME_A;
        return h ^ (h >> 32);
    }

    /// Check equality of two keys
    pub fn eql(a: GlyphKey, b: GlyphKey) bool {
        return a.font_ptr == b.font_ptr and
            a.glyph_id == b.glyph_id and
            a.size_fixed == b.size_fixed and
            a.scale_fixed == b.scale_fixed and
            a.subpixel_x == b.subpixel_x and
            a.subpixel_y == b.subpixel_y;
    }
};

/// Cached glyph information
pub const CachedGlyph = struct {
    /// Region in the atlas (physical pixels)
    region: Region,
    /// Horizontal offset from pen position to glyph left edge (physical pixels)
    offset_x: i32,
    /// Vertical offset from baseline to glyph top edge (physical pixels)
    offset_y: i32,
    /// Horizontal advance to next glyph (logical pixels)
    advance_x: f32,
    /// Whether this glyph uses the color atlas (emoji)
    is_color: bool,
    /// Side of the atlas the region lies in; fixed for the atlas's lifetime.
    atlas_size: u32,

    /// UV coordinates of the region.
    pub fn uv(self: CachedGlyph) atlas_mod.UVCoords {
        return self.region.uv(self.atlas_size);
    }
};

/// Entry in the glyph cache. `shelf` and `generation` locate the glyph's atlas
/// shelf; when the atlas evicts that shelf the entry is stale and re-rendered.
const GlyphEntry = struct {
    key: GlyphKey,
    glyph: CachedGlyph,
    shelf: u16,
    generation: u32,
    valid: bool,
    /// Frame in which a hit last proved this entry live and stamped its shelf
    /// used; 0 when none has. See `GlyphCache.lookupHit`.
    frame_verified: u64,
};

/// Why `lookupHit` found no live glyph: where `store` puts the re-render.
const Lookup = union(enum) {
    /// The key is cached but its atlas pixels were evicted; re-render in place.
    stale: u16,
    miss,
};

/// Glyph cache with atlas management. Every table is reserved at init from
/// `ResourceLimits.text.glyph_cache_count_max` and never grows (CLAUDE.md §2).
///
/// Zero is "empty" everywhere, so the tables come from fresh pages and stay
/// non-resident until glyphs are cached: hash slots and free-list links hold
/// an entry index plus one, and entry slots are claimed in order up to
/// `entry_high_water` before the free list is used.
///
/// Memory at `standard` (4,096 glyphs): entries 4,096 × 64 B, free-list links
/// 4,096 × 2 B, hash slots 8,192 × 2 B: 280 KiB of virtual memory.
pub const GlyphCache = struct {
    allocator: std.mem.Allocator,

    /// Entry slots; those at or past `entry_high_water` were never written.
    entries: []GlyphEntry,
    /// Hash slot -> entry index + 1, or `slot_empty`. A power of two, at
    /// least twice the entries, so the modulo is a mask and probes stay short.
    hash_table: []u16,
    /// Number of valid entries
    entry_count: u32,
    /// Entry slots claimed so far; slots below it are valid or on the free
    /// list. `deinit` zeroes this prefix (§21).
    entry_high_water: u16,
    /// Whether any slot of `hash_table` was written, for `deinit`'s zeroing.
    hash_written: bool,

    /// Free-list link of each claimed slot: the next free index + 1, or
    /// `slot_empty` at the end of the list.
    ///
    /// INVARIANT: Any code path that sets `entry.valid = false` on an individual entry
    /// MUST push that entry's index back onto this free list. `reclaimStale`
    /// and bulk `clear()` do.
    free_chain: []u16,
    /// Head of the free list (index + 1), or `slot_empty`; when empty, the
    /// next slot is `entry_high_water`.
    next_free: u16,

    /// Grayscale atlas for regular text, fixed at `AtlasLimits.text_size`.
    grayscale_atlas: Atlas,

    /// Reusable bitmap buffer for rendering
    render_buffer: []u8,
    render_buffer_size: u32,
    scale_factor: f32,

    const Self = @This();

    const MAX_PROBE_LENGTH: usize = 64;
    const slot_empty: u16 = 0;
    const RENDER_BUFFER_SIZE: u32 = limits.MAX_GLYPH_SIZE; // Max glyph size

    /// Hash slots for `glyph_count_max` entries: twice as many, rounded up to
    /// a power of two.
    pub fn hashSlotCount(glyph_count_max: u32) u32 {
        assert(glyph_count_max > 0);
        assert(glyph_count_max <= limits.TextLimits.ceiling.glyph_cache_count_max);
        return std.math.ceilPowerOfTwoAssert(u32, 2 * glyph_count_max);
    }

    /// Reserve the cache's tables for `glyph_count_max` glyphs
    /// (`text.glyph_cache_count_max`) and its atlas. Nothing in the tables
    /// is written: fresh pages are an empty cache.
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

    /// Zero what any frame wrote before the pages go back (§21).
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

    /// Push slot `index` onto the free list.
    fn freeSlot(self: *Self, index: u16) void {
        assert(index < self.entry_high_water);
        assert(!self.entries[index].valid);
        self.free_chain[index] = self.next_free;
        self.next_free = index + 1;
    }

    /// Claim a slot: the free list's head, else the next never-used slot.
    /// The caller made room first, so one of the two exists.
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

    /// Whether `claimSlot` would succeed without `makeRoom`.
    fn hasFreeSlot(self: *const Self) bool {
        return self.next_free != slot_empty or self.entry_high_water < self.entries.len;
    }

    /// Classify a key `lookupHit` did not return: absent, or cached with
    /// evicted pixels.
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

    /// The cached glyph for `key` when its pixels are live, marking its shelf
    /// used this frame. Null on a miss or a stale entry; `lookup` tells which.
    /// This runs for every glyph drawn, so it returns a pointer: returning the
    /// glyph by value as an optional copied it through the stack twice and
    /// doubled the cost of a hit.
    ///
    /// Only the first hit on an entry in each frame checks its shelf and
    /// stamps it used; repeat hits that frame return at once. That is exact:
    /// the first hit stamped the shelf with `frame`, eviction takes only
    /// shelves used before every open frame, and the clock has not passed
    /// `frame` while the caller still holds it, since eviction and `clear` run
    /// under the same text system mutex as the caller's lookup. `clear` also
    /// drops every entry, and `store` resets the stamp.
    inline fn lookupHit(self: *Self, key: GlyphKey, frame: u64) ?*const CachedGlyph {
        std.debug.assert(frame > 0);
        const entry = self.findEntry(key) orelse return null;
        if (entry.frame_verified == frame) {
            // Checked only with runtime safety: the hit path must not load
            // the shelf, and ReleaseFast may keep loads an assert needs.
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

    /// The valid entry holding `key`, if any. The table and entries are loaded
    /// once, so the probe loop reloads neither (§20), and the hit path uses the
    /// pointer instead of indexing the entries again.
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

        return null; // Max probe length reached
    }

    /// Store a rendered glyph: overwrite a stale entry for the same key in
    /// place, or pop a free slot. When the table is full, reclaim entries whose
    /// shelves were evicted, evicting the least recently used shelf if none are.
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

    /// Free at least one entry slot. Entries whose shelves were evicted go
    /// first; otherwise the least recently used unprotected shelf is evicted.
    /// A full table with every shelf in use this frame fails fast.
    fn makeRoom(self: *Self) void {
        assert(!self.hasFreeSlot());
        assert(self.entry_count == self.entries.len);
        // Each eviction frees one shelf, so the loop ends within the shelf count.
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

    /// Drop every entry whose atlas pixels were evicted and rebuild the hash
    /// table (linear probing cannot delete in place). Returns the count freed.
    /// O(entries + hash slots); runs only when the table is full.
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

    /// Insert entry into hash table using linear probing
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

        // At most half the slots are occupied, so a probe of 64 finds a free
        // one unless the hash is badly broken.
        unreachable;
    }

    /// A rendered glyph and the shelf that holds its pixels.
    const Rendered = struct {
        glyph: CachedGlyph,
        shelf: u16,
        generation: u32,
        /// False when the upload budget was full: draw nothing, do not cache.
        cached: bool,
    };

    /// Get a cached glyph with subpixel variant, or render and cache it
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

    /// The atlas frame clock, for `getOrRenderKey`.
    pub inline fn frameCurrent(self: *const Self) u64 {
        return self.grayscale_atlas.uploads.frameCurrent();
    }

    /// `getOrRenderSubpixel` for a key and frame the caller built. A batch
    /// builds the loop-invariant key fields (face, size, scale) and reads the
    /// frame clock once: a hit can store the shelf's frame stamp, and the
    /// compiler cannot prove that store leaves `scale_factor` or the clock's
    /// pointers unchanged, so values read inside the loop are reloaded and the
    /// scale re-converted on every glyph, at the head of the hash chain.
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

    /// The miss and stale paths of `getOrRenderSubpixel`, kept out of line so
    /// the hit path stays a plain hash probe: the key is rebuilt here rather
    /// than passed, so the hit path never spills it to memory.
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

        // Calculate subpixel shift (0.0, 0.25, 0.5, or 0.75)
        const subpixel_shift_x = @as(f32, @floatFromInt(subpixel_x)) / @as(f32, @floatFromInt(SUBPIXEL_VARIANTS_X));
        const subpixel_shift_y = @as(f32, @floatFromInt(subpixel_y)) / @as(f32, @floatFromInt(SUBPIXEL_VARIANTS_Y));

        // Use the FontFace interface to render with subpixel shift
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

    /// Place a rasterized glyph from `render_buffer` in the atlas.
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

        // Empty glyphs (spaces, etc.) occupy no atlas space.
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

    /// Get a cached glyph for a fallback font (specified by raw CTFontRef)
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
        // Fallback fonts are only supported on native platforms
        // On web, the browser handles font fallback automatically
        if (is_wasm) {
            return error.FallbackNotSupported;
        }
        // The DirectWrite shaper does not substitute fonts yet, so it never
        // sets `font_ref` and no Windows glyph reaches this path.
        if (is_windows) {
            return error.FallbackNotSupported;
        }

        std.debug.assert(subpixel_x < SUBPIXEL_VARIANTS_X);
        std.debug.assert(subpixel_y < SUBPIXEL_VARIANTS_Y);

        @memset(self.render_buffer, 0);

        const subpixel_shift_x = @as(f32, @floatFromInt(subpixel_x)) / @as(f32, @floatFromInt(SUBPIXEL_VARIANTS_X));
        const subpixel_shift_y = @as(f32, @floatFromInt(subpixel_y)) / @as(f32, @floatFromInt(SUBPIXEL_VARIANTS_Y));

        // Platform-specific fallback rendering
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

    /// Clear the cache (call when changing fonts or scale). The atlas condemns
    /// every shelf; their space returns once no open frame still uses it.
    pub fn clear(self: *Self) void {
        // Every claimed slot goes back on the free list; slots past the
        // high-water mark are still unwritten.
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

    /// Get the grayscale atlas for GPU upload
    pub inline fn getAtlas(self: *const Self) *const Atlas {
        return &self.grayscale_atlas;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "GlyphKey size encoding" {
    const testing = std.testing;

    // Different sizes should produce different keys
    const key_16 = GlyphKey.initWithFontPtr(0x1234, 65, 16.0, 1.0, 0, 0);
    const key_24 = GlyphKey.initWithFontPtr(0x1234, 65, 24.0, 1.0, 0, 0);
    const key_32 = GlyphKey.initWithFontPtr(0x1234, 65, 32.0, 1.0, 0, 0);

    // size_fixed should be size * 64 (26.6 fixed point)
    try testing.expectEqual(@as(u16, 16 * 64), key_16.size_fixed);
    try testing.expectEqual(@as(u16, 24 * 64), key_24.size_fixed);
    try testing.expectEqual(@as(u16, 32 * 64), key_32.size_fixed);

    // Keys with different sizes should not be equal
    try testing.expect(!GlyphKey.eql(key_16, key_24));
    try testing.expect(!GlyphKey.eql(key_16, key_32));
    try testing.expect(!GlyphKey.eql(key_24, key_32));

    // Same size should produce equal keys
    const key_16_dup = GlyphKey.initWithFontPtr(0x1234, 65, 16.0, 1.0, 0, 0);
    try testing.expect(GlyphKey.eql(key_16, key_16_dup));
}

test "GlyphKey size hash distribution" {
    const testing = std.testing;

    // Different sizes should produce different hashes
    const hash_14 = GlyphKey.initWithFontPtr(0x1234, 65, 14.0, 1.0, 0, 0).hash();
    const hash_16 = GlyphKey.initWithFontPtr(0x1234, 65, 16.0, 1.0, 0, 0).hash();
    const hash_18 = GlyphKey.initWithFontPtr(0x1234, 65, 18.0, 1.0, 0, 0).hash();

    try testing.expect(hash_14 != hash_16);
    try testing.expect(hash_16 != hash_18);
    try testing.expect(hash_14 != hash_18);
}

test "GlyphKey subpixel variants" {
    const testing = std.testing;

    // Different subpixel positions should produce different keys
    const key_sub0 = GlyphKey.initWithFontPtr(0x1234, 65, 16.0, 1.0, 0, 0);
    const key_sub1 = GlyphKey.initWithFontPtr(0x1234, 65, 16.0, 1.0, 1, 0);
    const key_sub2 = GlyphKey.initWithFontPtr(0x1234, 65, 16.0, 1.0, 2, 0);

    try testing.expect(!GlyphKey.eql(key_sub0, key_sub1));
    try testing.expect(!GlyphKey.eql(key_sub1, key_sub2));

    // Different hashes
    try testing.expect(key_sub0.hash() != key_sub1.hash());
    try testing.expect(key_sub1.hash() != key_sub2.hash());
}

test "GlyphKey wyhash distribution — printable ASCII × subpixel variants" {
    // Hash all printable ASCII glyph IDs (32–126 = 95 chars) × 4 subpixel variants = 380 keys.
    // Use `standard`'s table (8,192 slots): that is what determines probe-chain length in practice.
    // At load factor 380/8192 ≈ 4.6%, birthday-paradox predicts ~2.4% collision rate.
    const testing = std.testing;
    const glyph_count = limits.TextLimits.standard.glyph_cache_count_max;
    const TABLE_SLOTS: u32 = comptime GlyphCache.hashSlotCount(glyph_count);
    var buckets: [TABLE_SLOTS]u16 = @splat(0);

    const font_ptr: usize = 0x7FFF_0000_1000;
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

    // Count collisions: any bucket with >1 entry contributes (count - 1) collisions.
    var collisions: u32 = 0;
    for (buckets) |count| {
        if (count > 1) {
            collisions += count - 1;
        }
    }

    // Collision rate must stay below 5%.
    const collision_rate = @as(f64, @floatFromInt(collisions)) / @as(f64, @floatFromInt(total_keys));
    try testing.expect(collision_rate < 0.05);

    // Sanity: we generated the expected number of keys.
    try testing.expectEqual(@as(u32, 95) * @as(u32, SUBPIXEL_VARIANTS_X), total_keys);
}
