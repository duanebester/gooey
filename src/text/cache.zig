//! Glyph cache - maps (font_id, glyph_id, size, subpixel) to atlas regions
//!
//! Renders glyphs on-demand using the FontFace interface and caches
//! them in the texture atlas.
//!
//! Uses fixed-capacity hash table (no dynamic allocation after init).

const std = @import("std");
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

    pub inline fn init(face: FontFace, glyph_id: u16, scale: f32, subpixel_x: u8, subpixel_y: u8) GlyphKey {
        return .{
            .font_ptr = @intFromPtr(face.ptr),
            .glyph_id = glyph_id,
            .size_fixed = @intFromFloat(face.metrics.point_size * 64.0),
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

    /// Compute hash for this key using FNV-1a
    pub fn hash(self: GlyphKey) u64 {
        const FNV_OFFSET: u64 = 0xcbf29ce484222325;
        const FNV_PRIME: u64 = 0x100000001b3;

        var h: u64 = FNV_OFFSET;

        // Hash font_ptr (convert to u64 first for platform independence - wasm32 has 32-bit usize)
        const ptr_as_u64: u64 = @intCast(self.font_ptr);
        const ptr_bytes: [8]u8 = @bitCast(ptr_as_u64);
        for (ptr_bytes) |b| {
            h ^= b;
            h *%= FNV_PRIME;
        }

        // Hash glyph_id (2 bytes)
        h ^= @as(u64, self.glyph_id & 0xFF);
        h *%= FNV_PRIME;
        h ^= @as(u64, self.glyph_id >> 8);
        h *%= FNV_PRIME;

        // Hash size_fixed (2 bytes)
        h ^= @as(u64, self.size_fixed & 0xFF);
        h *%= FNV_PRIME;
        h ^= @as(u64, self.size_fixed >> 8);
        h *%= FNV_PRIME;

        // Hash scale, subpixel_x, subpixel_y (1 byte each)
        h ^= @as(u64, self.scale_fixed);
        h *%= FNV_PRIME;
        h ^= @as(u64, self.subpixel_x);
        h *%= FNV_PRIME;
        h ^= @as(u64, self.subpixel_y);
        h *%= FNV_PRIME;

        return h;
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
            .grayscale_atlas = try Atlas.init(allocator, .grayscale),
            .render_buffer = render_buffer,
            .render_buffer_size = buffer_bytes,
            .scale_factor = scale,
        };

        // Initialize all entries as invalid
        for (&self.entries) |*entry| {
            entry.valid = false;
        }

        std.debug.assert(self.entry_count == 0);
        return self;
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

    /// Store a glyph in the cache
    fn putInCache(self: *Self, key: GlyphKey, glyph: CachedGlyph) void {
        std.debug.assert(key.font_ptr != 0);
        std.debug.assert(self.entry_count <= MAX_CACHED_GLYPHS);

        // Find an empty slot in entries array
        var target_idx: ?usize = null;
        for (&self.entries, 0..) |*entry, idx| {
            if (!entry.valid) {
                target_idx = idx;
                break;
            }
        }

        // If cache is full, we can't add more (atlas eviction handles this case)
        if (target_idx == null) {
            return;
        }

        const idx = target_idx.?;

        // Store the entry
        self.entries[idx] = .{
            .key = key,
            .glyph = glyph,
            .valid = true,
        };
        self.entry_count += 1;

        // Insert into hash table
        self.insertIntoHashTable(key, @intCast(idx));

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

    /// Reserve space in the atlas, with eviction on overflow.
    /// When the atlas is at max size and can't fit the glyph,
    /// clears the entire cache and tries again.
    fn reserveWithEviction(self: *Self, width: u32, height: u32) !Region {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);

        // First attempt: try to reserve directly
        if (try self.grayscale_atlas.reserve(width, height)) |region| {
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

        // Growth succeeded - try reserve again
        return try self.grayscale_atlas.reserve(width, height) orelse error.GlyphTooLarge;
    }

    /// Get a cached glyph with subpixel variant, or render and cache it
    pub inline fn getOrRenderSubpixel(
        self: *Self,
        face: FontFace,
        glyph_id: u16,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !CachedGlyph {
        const key = GlyphKey.init(face, glyph_id, self.scale_factor, subpixel_x, subpixel_y);

        if (self.getFromCache(key)) |cached| {
            return cached;
        }

        const glyph = try self.renderGlyphSubpixel(face, glyph_id, subpixel_x, subpixel_y);
        self.putInCache(key, glyph);
        return glyph;
    }

    fn renderGlyphSubpixel(
        self: *Self,
        face: FontFace,
        glyph_id: u16,
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
            };
        }

        // Reserve space in atlas with eviction support
        const region = try self.reserveWithEviction(rasterized.width, rasterized.height);

        // Copy rasterized data to atlas
        self.grayscale_atlas.set(region, self.render_buffer[0 .. rasterized.width * rasterized.height]);

        return CachedGlyph{
            .region = region,
            .offset_x = rasterized.offset_x,
            .offset_y = rasterized.offset_y,
            .advance_x = rasterized.advance_x,
            .is_color = rasterized.is_color,
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

        const glyph = try self.renderFallbackGlyph(font_ptr, glyph_id, subpixel_x, subpixel_y);
        self.putInCache(key, glyph);
        return glyph;
    }

    fn renderFallbackGlyph(
        self: *Self,
        font_ptr: *anyopaque,
        glyph_id: u16,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !CachedGlyph {
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
                self.scale_factor,
                subpixel_shift_x,
                subpixel_shift_y,
                self.render_buffer,
                self.render_buffer_size,
            );
        };

        if (rasterized.width == 0 or rasterized.height == 0) {
            return CachedGlyph{
                .region = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                .offset_x = rasterized.offset_x,
                .offset_y = rasterized.offset_y,
                .advance_x = rasterized.advance_x,
                .is_color = rasterized.is_color,
            };
        }

        // Reserve space in atlas with eviction support
        const region = try self.reserveWithEviction(rasterized.width, rasterized.height);

        self.grayscale_atlas.set(region, self.render_buffer[0 .. rasterized.width * rasterized.height]);

        return CachedGlyph{
            .region = region,
            .offset_x = rasterized.offset_x,
            .offset_y = rasterized.offset_y,
            .advance_x = rasterized.advance_x,
            .is_color = rasterized.is_color,
        };
    }

    /// Clear the cache (call when changing fonts)
    pub fn clear(self: *Self) void {
        // Clear all entries
        for (&self.entries) |*entry| {
            entry.valid = false;
        }

        // Clear hash table
        @memset(&self.hash_table, EMPTY_SLOT);

        self.entry_count = 0;
        self.grayscale_atlas.clear();

        std.debug.assert(self.entry_count == 0);
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
