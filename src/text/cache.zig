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

const FontFace = font_face_mod.FontFace;
const RasterizedGlyph = types.RasterizedGlyph;
const SUBPIXEL_VARIANTS_X = types.SUBPIXEL_VARIANTS_X;
const SUBPIXEL_VARIANTS_Y = types.SUBPIXEL_VARIANTS_Y;

const is_wasm = platform.is_wasm;
const is_linux = platform.is_linux;

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
    /// Replaces a 15-round FNV-1a serial chain with 2 multiplies that
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
    /// Atlas size when this glyph was cached (for thread-safe UV calculation)
    /// In multi-window scenarios, the atlas may grow between glyph caching and
    /// UV calculation; storing the size ensures correct UVs.
    atlas_size: u32,

    /// Calculate UV coordinates using the cached atlas size
    pub fn uv(self: CachedGlyph) atlas_mod.UVCoords {
        return self.region.uv(self.atlas_size);
    }
};

/// Entry in the glyph cache
const GlyphEntry = struct {
    key: GlyphKey,
    glyph: CachedGlyph,
    valid: bool,
};

/// Glyph cache with atlas management - fixed capacity, zero runtime allocation
pub const GlyphCache = struct {
    allocator: std.mem.Allocator,

    /// Fixed-capacity glyph storage
    entries: [MAX_CACHED_GLYPHS]GlyphEntry,
    /// Hash table: maps hash slot -> entry index (EMPTY_SLOT = empty)
    hash_table: [HASH_TABLE_SIZE]u16,
    /// Number of valid entries
    entry_count: u32,

    /// Intrusive free list threaded through entries array.
    /// Each element stores the index of the next free slot, or EMPTY_SLOT for end-of-list.
    /// Separate array avoids union gymnastics in GlyphEntry — 8 KB (4096 × 2 bytes).
    ///
    /// INVARIANT: Any code path that sets `entry.valid = false` on an individual entry
    /// MUST push that entry's index back onto this free list (set `free_chain[idx] =
    /// next_free; next_free = idx`).  Currently only bulk `clear()` and `initFreeList()`
    /// rebuild the list — no individual eviction path exists.  If one is added without
    /// maintaining this invariant, the freed slot becomes permanently lost until `clear()`.
    free_chain: [MAX_CACHED_GLYPHS]u16,
    /// Head of the free list (EMPTY_SLOT = cache full, no free slots).
    next_free: u16,

    /// Grayscale atlas for regular text
    grayscale_atlas: Atlas,

    /// Reusable bitmap buffer for rendering
    render_buffer: []u8,
    render_buffer_size: u32,
    scale_factor: f32,

    const Self = @This();

    // Capacity limits
    pub const MAX_CACHED_GLYPHS: usize = 4096;
    const HASH_TABLE_SIZE: usize = 8192; // 2x entries for low collision rate
    const MAX_PROBE_LENGTH: usize = 64;
    const EMPTY_SLOT: u16 = 0xFFFF;
    const RENDER_BUFFER_SIZE: u32 = 256; // Max glyph size

    // Compile-time verification
    comptime {
        std.debug.assert(MAX_CACHED_GLYPHS < EMPTY_SLOT); // Ensure sentinel is valid
        std.debug.assert(HASH_TABLE_SIZE >= MAX_CACHED_GLYPHS * 2); // Good load factor
        // Free chain index type must be able to address all entries.
        std.debug.assert(MAX_CACHED_GLYPHS <= std.math.maxInt(u16));
    }

    pub fn init(allocator: std.mem.Allocator, scale: f32) !Self {
        std.debug.assert(scale > 0);
        std.debug.assert(scale <= 4.0);

        const buffer_bytes = RENDER_BUFFER_SIZE * RENDER_BUFFER_SIZE;
        const render_buffer = try allocator.alloc(u8, buffer_bytes);
        @memset(render_buffer, 0);

        var self = Self{
            .allocator = allocator,
            .entries = undefined,
            .hash_table = [_]u16{EMPTY_SLOT} ** HASH_TABLE_SIZE,
            .entry_count = 0,
            .free_chain = undefined,
            .next_free = 0,
            .grayscale_atlas = try Atlas.init(allocator, .grayscale),
            .render_buffer = render_buffer,
            .render_buffer_size = buffer_bytes,
            .scale_factor = scale,
        };

        // Initialize all entries as invalid
        for (&self.entries) |*entry| {
            entry.valid = false;
        }

        // Chain every slot into the free list: 0 → 1 → 2 → ... → EMPTY_SLOT.
        self.initFreeList();

        std.debug.assert(self.entry_count == 0);
        std.debug.assert(self.next_free == 0);
        return self;
    }

    /// Initialize GlyphCache in-place using out-pointer pattern.
    /// Avoids stack overflow on WASM where GlyphCache is ~200KB.
    /// Marked noinline to prevent stack accumulation in WASM builds.
    pub noinline fn initInPlace(self: *Self, allocator: std.mem.Allocator, scale: f32) !void {
        std.debug.assert(scale > 0);
        std.debug.assert(scale <= 4.0);

        const buffer_bytes = RENDER_BUFFER_SIZE * RENDER_BUFFER_SIZE;
        const render_buffer = try allocator.alloc(u8, buffer_bytes);
        @memset(render_buffer, 0);

        self.allocator = allocator;
        self.entry_count = 0;
        self.render_buffer = render_buffer;
        self.render_buffer_size = buffer_bytes;
        self.scale_factor = scale;

        // Initialize hash table to empty slots
        @memset(&self.hash_table, EMPTY_SLOT);

        // Initialize all entries as invalid
        for (&self.entries) |*entry| {
            entry.valid = false;
        }

        // Chain every slot into the free list: 0 → 1 → 2 → ... → EMPTY_SLOT.
        self.next_free = 0;
        self.initFreeList();

        // Initialize atlas in-place
        self.grayscale_atlas = try Atlas.init(allocator, .grayscale);

        std.debug.assert(self.entry_count == 0);
        std.debug.assert(self.next_free == 0);
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
        self.grayscale_atlas.deinit();
        self.allocator.free(self.render_buffer);
        self.* = undefined;
    }

    /// Chain all entry slots into the free list for O(1) insertion.
    /// Called at init and after clear.
    fn initFreeList(self: *Self) void {
        for (0..MAX_CACHED_GLYPHS - 1) |i| {
            self.free_chain[i] = @intCast(i + 1);
        }
        self.free_chain[MAX_CACHED_GLYPHS - 1] = EMPTY_SLOT;
        self.next_free = 0;

        std.debug.assert(self.free_chain[0] == 1);
        std.debug.assert(self.free_chain[MAX_CACHED_GLYPHS - 1] == EMPTY_SLOT);
    }

    /// Get a cached glyph, or null if not cached
    fn getFromCache(self: *Self, key: GlyphKey) ?CachedGlyph {
        std.debug.assert(key.font_ptr != 0);
        std.debug.assert(key.subpixel_x < SUBPIXEL_VARIANTS_X);

        const key_hash = key.hash();
        const start_slot = @as(usize, @truncate(key_hash)) % HASH_TABLE_SIZE;
        var probe: usize = start_slot;

        for (0..MAX_PROBE_LENGTH) |_| {
            const entry_idx = self.hash_table[probe];

            if (entry_idx == EMPTY_SLOT) {
                return null; // Not found
            }

            std.debug.assert(entry_idx < MAX_CACHED_GLYPHS);
            const entry = &self.entries[entry_idx];

            if (entry.valid and GlyphKey.eql(entry.key, key)) {
                return entry.glyph;
            }

            probe = (probe + 1) % HASH_TABLE_SIZE;
        }

        return null; // Max probe length reached
    }

    /// Store a glyph in the cache using O(1) free list pop.
    fn putInCache(self: *Self, key: GlyphKey, glyph: CachedGlyph) void {
        std.debug.assert(key.font_ptr != 0);
        std.debug.assert(self.entry_count <= MAX_CACHED_GLYPHS);

        // Pop the head of the free list — O(1) instead of O(N) linear scan.
        if (self.next_free == EMPTY_SLOT) {
            return; // Cache full (atlas eviction handles this case).
        }

        const idx = self.next_free;
        self.next_free = self.free_chain[idx];

        std.debug.assert(!self.entries[idx].valid);

        // Store the entry.
        self.entries[idx] = .{
            .key = key,
            .glyph = glyph,
            .valid = true,
        };
        self.entry_count += 1;

        // Insert into hash table.
        self.insertIntoHashTable(key, idx);

        std.debug.assert(self.entry_count <= MAX_CACHED_GLYPHS);
    }

    /// Insert entry into hash table using linear probing
    fn insertIntoHashTable(self: *Self, key: GlyphKey, entry_idx: u16) void {
        std.debug.assert(entry_idx < MAX_CACHED_GLYPHS);

        const key_hash = key.hash();
        const start_slot = @as(usize, @truncate(key_hash)) % HASH_TABLE_SIZE;
        var probe: usize = start_slot;

        for (0..MAX_PROBE_LENGTH) |_| {
            if (self.hash_table[probe] == EMPTY_SLOT) {
                self.hash_table[probe] = entry_idx;
                return;
            }
            probe = (probe + 1) % HASH_TABLE_SIZE;
        }

        // Max probe length reached - entry won't be in hash table
        // This is rare with 2x table size but we handle it gracefully
        std.debug.assert(false); // Should not happen with proper sizing
    }

    /// Try to reserve space, clearing atlas on SkylineFull error.
    /// Returns region on success, null if no space, or propagates other errors.
    fn reserveOrClearOnSkylineFull(self: *Self, width: u32, height: u32) !?Region {
        return self.grayscale_atlas.reserve(width, height) catch |err| {
            if (err == error.SkylineFull) {
                // Too many skyline nodes - clear atlas and retry
                self.clear();

                // Assert atlas is truly empty after clear
                std.debug.assert(self.entry_count == 0);
                std.debug.assert(self.grayscale_atlas.node_count == 1);

                return try self.grayscale_atlas.reserve(width, height);
            }
            return err;
        };
    }

    /// Reserve space in the atlas, with eviction on overflow.
    /// When the atlas is at max size and can't fit the glyph,
    /// clears the entire cache and tries again.
    fn reserveWithEviction(self: *Self, width: u32, height: u32) !Region {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);

        // First attempt: try to reserve directly
        if (try self.reserveOrClearOnSkylineFull(width, height)) |region| {
            return region;
        }

        // No space - try to grow the atlas
        self.grayscale_atlas.grow() catch |err| {
            if (err == error.AtlasFull) {
                // Atlas is at max size and full - evict everything and retry
                self.clear();

                // After clearing, we should definitely have space
                if (try self.grayscale_atlas.reserve(width, height)) |region| {
                    return region;
                }
                // If we still can't fit after clearing, the glyph is too large
                return error.GlyphTooLarge;
            }
            return err;
        };

        // Growth succeeded - update atlas_size in all cached entries
        // This is critical: cached glyphs store atlas_size for UV calculation.
        // When atlas grows, pixel positions stay the same but UVs change.
        self.updateAtlasSizeInCache();

        // Growth succeeded - try reserve again
        return try self.reserveOrClearOnSkylineFull(width, height) orelse error.GlyphTooLarge;
    }

    /// Update atlas_size in all cached entries after atlas growth.
    /// When the atlas grows, pixel positions are preserved but UV coordinates
    /// change (e.g., x=100 in 512px atlas is UV=0.195, but in 1024px is UV=0.098).
    /// This updates all cached glyphs to use the new atlas size for correct UVs.
    fn updateAtlasSizeInCache(self: *Self) void {
        const new_size = self.grayscale_atlas.size;

        for (&self.entries) |*entry| {
            if (entry.valid) {
                entry.glyph.atlas_size = new_size;
            }
        }
    }

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

        if (self.getFromCache(key)) |cached| {
            return cached;
        }

        const glyph = try self.renderGlyphSubpixel(face, glyph_id, font_size, subpixel_x, subpixel_y);
        self.putInCache(key, glyph);
        return glyph;
    }

    fn renderGlyphSubpixel(
        self: *Self,
        face: FontFace,
        glyph_id: u16,
        font_size: f32,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !CachedGlyph {
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

        // Handle empty glyphs (spaces, etc.)
        if (rasterized.width == 0 or rasterized.height == 0) {
            return CachedGlyph{
                .region = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .offset_x = rasterized.offset_x,
                .offset_y = rasterized.offset_y,
                .advance_x = rasterized.advance_x,
                .is_color = rasterized.is_color,
                .atlas_size = self.grayscale_atlas.size,
            };
        }

        // Reserve space in atlas with eviction support
        const region = try self.reserveWithEviction(rasterized.width, rasterized.height);

        // Copy rasterized data to atlas
        self.grayscale_atlas.set(region, self.render_buffer[0 .. rasterized.width * rasterized.height]);

        // Capture atlas size AFTER reservation (may have grown)
        const current_atlas_size = self.grayscale_atlas.size;

        return CachedGlyph{
            .region = region,
            .offset_x = rasterized.offset_x,
            .offset_y = rasterized.offset_y,
            .advance_x = rasterized.advance_x,
            .is_color = rasterized.is_color,
            .atlas_size = current_atlas_size,
        };
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

        if (self.getFromCache(key)) |cached| {
            return cached;
        }

        const glyph = try self.renderFallbackGlyph(font_ptr, glyph_id, font_size, subpixel_x, subpixel_y);
        self.putInCache(key, glyph);
        return glyph;
    }

    fn renderFallbackGlyph(
        self: *Self,
        font_ptr: *anyopaque,
        glyph_id: u16,
        font_size: f32,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !CachedGlyph {
        std.debug.assert(font_size > 0);
        // Fallback fonts are only supported on native platforms
        // On web, the browser handles font fallback automatically
        if (is_wasm) {
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

        // Handle empty glyphs
        if (rasterized.width == 0 or rasterized.height == 0) {
            return CachedGlyph{
                .region = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .offset_x = rasterized.offset_x,
                .offset_y = rasterized.offset_y,
                .advance_x = rasterized.advance_x,
                .is_color = rasterized.is_color,
                .atlas_size = self.grayscale_atlas.size,
            };
        }

        // Reserve space in atlas with eviction support
        const region = try self.reserveWithEviction(rasterized.width, rasterized.height);

        // Copy rasterized data to atlas
        self.grayscale_atlas.set(region, self.render_buffer[0 .. rasterized.width * rasterized.height]);

        // Capture atlas size AFTER reservation (may have grown)
        const current_atlas_size = self.grayscale_atlas.size;

        return CachedGlyph{
            .region = region,
            .offset_x = rasterized.offset_x,
            .offset_y = rasterized.offset_y,
            .advance_x = rasterized.advance_x,
            .is_color = rasterized.is_color,
            .atlas_size = current_atlas_size,
        };
    }

    /// Clear the cache (call when changing fonts).
    pub fn clear(self: *Self) void {
        // Clear all entries.
        for (&self.entries) |*entry| {
            entry.valid = false;
        }

        // Clear hash table.
        @memset(&self.hash_table, EMPTY_SLOT);

        self.entry_count = 0;
        self.grayscale_atlas.clear();

        // Rebuild the free list so every slot is available again.
        self.initFreeList();

        std.debug.assert(self.entry_count == 0);
        std.debug.assert(self.next_free == 0);
    }

    /// Get the grayscale atlas for GPU upload
    pub inline fn getAtlas(self: *const Self) *const Atlas {
        return &self.grayscale_atlas;
    }

    /// Get atlas generation (for detecting changes)
    pub inline fn getGeneration(self: *const Self) u32 {
        return self.grayscale_atlas.generation;
    }

    /// Get cache statistics for debugging
    pub fn getStats(self: *const Self) struct { entries: u32, capacity: u32 } {
        return .{
            .entries = self.entry_count,
            .capacity = MAX_CACHED_GLYPHS,
        };
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
    // Use the real HASH_TABLE_SIZE (8192) — that's what determines probe-chain length in practice.
    // At load factor 380/8192 ≈ 4.6%, birthday-paradox predicts ~2.4% collision rate.
    const testing = std.testing;
    const TABLE_SLOTS: u32 = GlyphCache.HASH_TABLE_SIZE;
    var buckets = [_]u16{0} ** TABLE_SLOTS;

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
