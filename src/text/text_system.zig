//! High-level text system combining all components
//!
//! Provides a unified API for text rendering with:
//! - Font loading and metrics
//! - Text shaping (simple and complex)
//! - Glyph caching and atlas management
//! - GPU-ready glyph data

const std = @import("std");
const builtin = @import("builtin");

const types = @import("types.zig");
const font_face_mod = @import("font_face.zig");
const shaper_mod = @import("shaper.zig");
const cache_mod = @import("cache.zig");
const platform = @import("../platform/mod.zig");
const RenderStats = @import("../debug/render_stats.zig").RenderStats;

const Atlas = @import("atlas.zig").Atlas;

// =============================================================================
// Shaped Run Cache - Fixed Capacity, Zero Runtime Allocation
// =============================================================================

/// Cache key for shaped text runs using content hash (not pointer)
const ShapedRunKey = struct {
    text_hash: u64,
    text_len: u32,
    font_ptr: usize,
    size_fixed: u16, // Font size in 1/64th points
    /// First bytes of text for collision resistance
    text_prefix: [PREFIX_LEN]u8,
    /// Last bytes of text for collision resistance
    text_suffix: [SUFFIX_LEN]u8,

    const Self = @This();
    const PREFIX_LEN = 8;
    const SUFFIX_LEN = 8;
    /// 26.6 fixed point scale (common in font systems like FreeType)
    const FIXED_POINT_SCALE = 64.0;

    /// FNV-1a hash for text content - fast and good distribution
    fn hashText(text: []const u8) u64 {
        std.debug.assert(text.len > 0);
        std.debug.assert(text.len <= ShapedRunCache.MAX_TEXT_LEN);

        const FNV_OFFSET: u64 = 0xcbf29ce484222325;
        const FNV_PRIME: u64 = 0x100000001b3;

        var hash: u64 = FNV_OFFSET;
        for (text) |byte| {
            hash ^= byte;
            hash *%= FNV_PRIME;
        }
        return hash;
    }

    /// Extract prefix bytes, zero-padded if text is shorter
    fn extractPrefix(text: []const u8) [PREFIX_LEN]u8 {
        var prefix: [PREFIX_LEN]u8 = [_]u8{0} ** PREFIX_LEN;
        const copy_len = @min(text.len, PREFIX_LEN);
        @memcpy(prefix[0..copy_len], text[0..copy_len]);
        return prefix;
    }

    /// Extract suffix bytes, zero-padded if text is shorter
    fn extractSuffix(text: []const u8) [SUFFIX_LEN]u8 {
        var suffix: [SUFFIX_LEN]u8 = [_]u8{0} ** SUFFIX_LEN;
        const copy_len = @min(text.len, SUFFIX_LEN);
        const start = text.len - copy_len;
        @memcpy(suffix[0..copy_len], text[start..]);
        return suffix;
    }

    pub fn init(text: []const u8, font_ptr: usize, font_size: f32) Self {
        std.debug.assert(font_size > 0);
        std.debug.assert(font_size < 1000); // Reasonable font size limit

        return .{
            .text_hash = hashText(text),
            .text_len = @intCast(text.len),
            .font_ptr = font_ptr,
            .size_fixed = @intFromFloat(font_size * FIXED_POINT_SCALE),
            .text_prefix = extractPrefix(text),
            .text_suffix = extractSuffix(text),
        };
    }

    pub fn eql(a: Self, b: Self) bool {
        return a.text_hash == b.text_hash and
            a.text_len == b.text_len and
            a.font_ptr == b.font_ptr and
            a.size_fixed == b.size_fixed and
            std.mem.eql(u8, &a.text_prefix, &b.text_prefix) and
            std.mem.eql(u8, &a.text_suffix, &b.text_suffix);
    }
};

/// A single cache entry with fixed-capacity glyph storage
const CacheEntry = struct {
    key: ShapedRunKey,
    glyphs: [ShapedRunCache.MAX_GLYPHS_PER_ENTRY]ShapedGlyph,
    glyph_count: u16,
    width: f32,
    /// LRU tracking - higher = more recently used
    last_access: u32,
    /// Is this slot in use?
    valid: bool,

    const Self = @This();

    fn clear(self: *Self) void {
        self.valid = false;
        self.glyph_count = 0;
        self.last_access = 0;
    }
};

/// Cache for shaped text runs - fully pre-allocated, zero runtime allocation
/// Uses hash table with open addressing for O(1) average lookup.
/// Implements LRU eviction when capacity is reached.
pub const ShapedRunCache = struct {
    /// Pre-allocated cache entries
    entries: [MAX_ENTRIES]CacheEntry,
    /// Hash table: maps hash slot -> entry index (EMPTY_SLOT = empty)
    hash_table: [HASH_TABLE_SIZE]u16,
    /// Number of valid entries
    entry_count: u32,
    /// Global access counter for LRU
    access_counter: u32,
    /// Track font pointer to invalidate on font change
    current_font_ptr: usize,

    const Self = @This();

    // Compile-time capacity limits
    pub const MAX_ENTRIES: usize = 256;
    pub const MAX_GLYPHS_PER_ENTRY: usize = 128; // ~128 chars per cached string
    pub const MAX_TEXT_LEN: usize = 512; // Max cacheable text length

    // Hash table configuration
    // Size is 2x entries for low collision rate with open addressing
    const HASH_TABLE_SIZE: usize = 512;
    const MAX_PROBE_LENGTH: usize = HASH_TABLE_SIZE; // Must be able to probe entire table
    const EMPTY_SLOT: u16 = 0xFFFF; // Sentinel for empty hash slots

    // Compile-time size verification
    comptime {
        // Ensure reasonable memory footprint (~1.5MB for cache)
        const entry_size = @sizeOf(CacheEntry);
        const total_size = entry_size * MAX_ENTRIES;
        std.debug.assert(total_size < 2 * 1024 * 1024); // Under 2MB
        std.debug.assert(@sizeOf(ShapedGlyph) <= 48); // Glyph struct size check
    }

    pub fn init() Self {
        var self = Self{
            .entries = undefined,
            .hash_table = [_]u16{EMPTY_SLOT} ** HASH_TABLE_SIZE,
            .entry_count = 0,
            .access_counter = 0,
            .current_font_ptr = 0,
        };

        // Initialize all entries as invalid
        for (&self.entries) |*entry| {
            entry.clear();
        }

        std.debug.assert(self.entry_count == 0);
        std.debug.assert(self.access_counter == 0);

        return self;
    }

    pub fn deinit(self: *Self) void {
        // No dynamic memory to free - just clear state
        self.entry_count = 0;
        self.access_counter = 0;
        self.current_font_ptr = 0;
        self.* = undefined;
    }

    /// Check if font changed and invalidate if needed
    pub fn checkFont(self: *Self, font_ptr: usize) void {
        std.debug.assert(font_ptr != 0);

        if (self.current_font_ptr != font_ptr) {
            self.clearAll();
            self.current_font_ptr = font_ptr;
        }

        std.debug.assert(self.current_font_ptr == font_ptr);
    }

    /// Get cached shaped run, returns null if not cached
    /// Updates LRU access time on hit
    /// O(1) average case with hash table lookup
    pub fn get(self: *Self, key: ShapedRunKey) ?ShapedRun {
        std.debug.assert(key.text_len > 0);
        std.debug.assert(key.text_len <= MAX_TEXT_LEN);

        const start_slot = @as(usize, @truncate(key.text_hash)) % HASH_TABLE_SIZE;
        var probe: usize = start_slot;

        for (0..MAX_PROBE_LENGTH) |_| {
            const entry_idx = self.hash_table[probe];

            if (entry_idx == EMPTY_SLOT) {
                // Empty slot means key not in table
                return null;
            }

            std.debug.assert(entry_idx < MAX_ENTRIES);
            const entry = &self.entries[entry_idx];

            if (entry.valid and ShapedRunKey.eql(entry.key, key)) {
                // Update LRU
                self.access_counter += 1;
                entry.last_access = self.access_counter;

                std.debug.assert(entry.glyph_count <= MAX_GLYPHS_PER_ENTRY);
                std.debug.assert(entry.width >= 0);

                return ShapedRun{
                    .glyphs = entry.glyphs[0..entry.glyph_count],
                    .width = entry.width,
                    .owned = false, // Cache owns this memory
                };
            }

            // Linear probing: try next slot
            probe = (probe + 1) % HASH_TABLE_SIZE;
        }

        // Max probe length reached - treat as miss
        return null;
    }

    /// Store a shaped run in cache (copies glyphs into pre-allocated storage)
    /// Uses LRU eviction if cache is full
    pub fn put(self: *Self, key: ShapedRunKey, run: ShapedRun) void {
        std.debug.assert(key.text_len > 0);
        std.debug.assert(run.width >= 0);

        // Don't cache runs that are too long
        if (run.glyphs.len > MAX_GLYPHS_PER_ENTRY) {
            return;
        }

        // Don't cache runs with fallback fonts (font_ref lifecycle issues)
        for (run.glyphs) |g| {
            if (g.font_ref != null) {
                return;
            }
        }

        // Check if key already exists - update in place if so
        const existing_idx = self.findEntryIndex(key);
        if (existing_idx) |idx| {
            const slot = &self.entries[idx];
            const glyph_count: u16 = @intCast(run.glyphs.len);
            @memcpy(slot.glyphs[0..glyph_count], run.glyphs);
            slot.glyph_count = glyph_count;
            slot.width = run.width;
            self.access_counter += 1;
            slot.last_access = self.access_counter;
            return;
        }

        // Find slot: prefer empty, otherwise LRU
        var target_idx: usize = 0;
        var oldest_access: u32 = std.math.maxInt(u32);

        for (&self.entries, 0..) |*entry, idx| {
            if (!entry.valid) {
                // Found empty slot
                target_idx = idx;
                break;
            } else if (entry.last_access < oldest_access) {
                // Track LRU candidate
                oldest_access = entry.last_access;
                target_idx = idx;
            }
        }

        const slot = &self.entries[target_idx];

        // If evicting, remove old entry from hash table first
        if (slot.valid) {
            std.debug.assert(self.entry_count > 0);
            self.removeFromHashTable(slot.key, target_idx);
            self.entry_count -= 1;
        }

        // Copy glyphs into slot
        const glyph_count: u16 = @intCast(run.glyphs.len);
        @memcpy(slot.glyphs[0..glyph_count], run.glyphs);

        // Update slot metadata
        slot.key = key;
        slot.glyph_count = glyph_count;
        slot.width = run.width;
        self.access_counter += 1;
        slot.last_access = self.access_counter;
        slot.valid = true;

        self.entry_count += 1;

        // Insert into hash table
        self.insertIntoHashTable(key, @intCast(target_idx));

        std.debug.assert(self.entry_count <= MAX_ENTRIES);
        std.debug.assert(slot.valid);
    }

    /// Find entry index by key, returns null if not found
    fn findEntryIndex(self: *Self, key: ShapedRunKey) ?usize {
        const start_slot = @as(usize, @truncate(key.text_hash)) % HASH_TABLE_SIZE;
        var probe: usize = start_slot;

        for (0..MAX_PROBE_LENGTH) |_| {
            const entry_idx = self.hash_table[probe];

            if (entry_idx == EMPTY_SLOT) {
                return null;
            }

            std.debug.assert(entry_idx < MAX_ENTRIES);
            const entry = &self.entries[entry_idx];

            if (entry.valid and ShapedRunKey.eql(entry.key, key)) {
                return entry_idx;
            }

            probe = (probe + 1) % HASH_TABLE_SIZE;
        }

        return null;
    }

    /// Insert entry into hash table using linear probing
    fn insertIntoHashTable(self: *Self, key: ShapedRunKey, entry_idx: u16) void {
        std.debug.assert(entry_idx < MAX_ENTRIES);

        const start_slot = @as(usize, @truncate(key.text_hash)) % HASH_TABLE_SIZE;
        var probe: usize = start_slot;

        for (0..MAX_PROBE_LENGTH) |_| {
            if (self.hash_table[probe] == EMPTY_SLOT) {
                self.hash_table[probe] = entry_idx;
                return;
            }
            probe = (probe + 1) % HASH_TABLE_SIZE;
        }

        // Max probe length reached - this shouldn't happen with proper sizing
        // but we fail gracefully (entry just won't be in hash table)
        std.debug.assert(false); // Should never reach here with 2x table size
    }

    /// Remove entry from hash table (used during eviction)
    /// Uses tombstone-free deletion by rehashing subsequent entries
    fn removeFromHashTable(self: *Self, key: ShapedRunKey, entry_idx: usize) void {
        const start_slot = @as(usize, @truncate(key.text_hash)) % HASH_TABLE_SIZE;
        var probe: usize = start_slot;

        // Find the slot containing this entry
        for (0..MAX_PROBE_LENGTH) |_| {
            if (self.hash_table[probe] == EMPTY_SLOT) {
                return; // Entry not in hash table
            }

            if (self.hash_table[probe] == @as(u16, @intCast(entry_idx))) {
                // Found it - remove and rehash subsequent entries
                self.hash_table[probe] = EMPTY_SLOT;
                self.rehashAfterRemoval(probe);
                return;
            }

            probe = (probe + 1) % HASH_TABLE_SIZE;
        }
    }

    /// Rehash entries that may have been displaced by the removed entry
    fn rehashAfterRemoval(self: *Self, removed_slot: usize) void {
        var slot = (removed_slot + 1) % HASH_TABLE_SIZE;

        for (0..MAX_PROBE_LENGTH) |_| {
            const entry_idx = self.hash_table[slot];
            if (entry_idx == EMPTY_SLOT) {
                return; // Done - hit empty slot
            }

            // Check if this entry needs to be moved
            const entry = &self.entries[entry_idx];
            if (!entry.valid) {
                slot = (slot + 1) % HASH_TABLE_SIZE;
                continue;
            }

            const natural_slot = @as(usize, @truncate(entry.key.text_hash)) % HASH_TABLE_SIZE;

            // If entry's natural slot is between removed_slot and current slot
            // (wrapping around), it needs to be rehashed
            const needs_rehash = if (removed_slot < slot)
                (natural_slot <= removed_slot or natural_slot > slot)
            else
                (natural_slot <= removed_slot and natural_slot > slot);

            if (needs_rehash) {
                // Remove from current slot and reinsert
                self.hash_table[slot] = EMPTY_SLOT;
                self.insertIntoHashTable(entry.key, entry_idx);
            }

            slot = (slot + 1) % HASH_TABLE_SIZE;
        }
    }

    /// Clear all entries (e.g., on font change)
    fn clearAll(self: *Self) void {
        for (&self.entries) |*entry| {
            entry.clear();
        }
        // Clear hash table
        @memset(&self.hash_table, EMPTY_SLOT);

        self.entry_count = 0;
        // Don't reset access_counter to preserve LRU ordering after clear

        std.debug.assert(self.entry_count == 0);
    }

    /// Get cache statistics for debugging
    pub fn getStats(self: *const Self) struct { entries: u32, capacity: u32 } {
        std.debug.assert(self.entry_count <= MAX_ENTRIES);
        return .{
            .entries = self.entry_count,
            .capacity = MAX_ENTRIES,
        };
    }
};

// =============================================================================
// Platform Selection (compile-time)
// =============================================================================

const is_wasm = platform.is_wasm;
const is_linux = platform.is_linux;

const backend = if (is_wasm)
    @import("backends/web/mod.zig")
else if (is_linux)
    @import("backends/freetype/mod.zig")
else
    @import("backends/coretext/mod.zig");

/// Platform-specific font face type
const PlatformFace = if (is_wasm)
    backend.WebFontFace
else if (is_linux)
    backend.FreeTypeFace
else
    backend.CoreTextFace;

/// Platform-specific shaper type
const PlatformShaper = if (is_wasm)
    backend.WebShaper
else if (is_linux)
    backend.HarfBuzzShaper
else
    backend.CoreTextShaper;

// =============================================================================
// Public Types
// =============================================================================

pub const FontFace = font_face_mod.FontFace;
pub const Metrics = types.Metrics;
pub const GlyphMetrics = types.GlyphMetrics;
pub const ShapedGlyph = types.ShapedGlyph;
pub const ShapedRun = types.ShapedRun;
pub const TextMeasurement = types.TextMeasurement;
pub const SystemFont = types.SystemFont;
pub const CachedGlyph = cache_mod.CachedGlyph;
pub const SUBPIXEL_VARIANTS_X = types.SUBPIXEL_VARIANTS_X;

/// High-level text system
pub const TextSystem = struct {
    allocator: std.mem.Allocator,
    cache: cache_mod.GlyphCache,
    /// Current font face (platform-specific)
    current_face: ?PlatformFace,
    /// Complex shaper (native only, void on web)
    shaper: ?PlatformShaper,
    scale_factor: f32,
    /// Cache for shaped text runs (fixed capacity, pre-allocated)
    shape_cache: ShapedRunCache,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return initWithScale(allocator, 1.0);
    }

    pub fn initWithScale(allocator: std.mem.Allocator, scale: f32) !Self {
        std.debug.assert(scale > 0);
        std.debug.assert(scale <= 4.0); // Reasonable scale factor limit

        return .{
            .allocator = allocator,
            .cache = try cache_mod.GlyphCache.init(allocator, scale),
            .current_face = null,
            .shaper = null,
            .scale_factor = scale,
            .shape_cache = ShapedRunCache.init(),
        };
    }

    pub fn setScaleFactor(self: *Self, scale: f32) void {
        std.debug.assert(scale > 0);
        std.debug.assert(scale <= 4.0);

        self.scale_factor = scale;
        self.cache.setScaleFactor(scale);
    }

    pub fn deinit(self: *Self) void {
        if (self.current_face) |*f| f.deinit();
        if (self.shaper) |*s| s.deinit();
        self.cache.deinit();
        self.shape_cache.deinit();
        self.* = undefined;
    }

    /// Load a font by name
    pub fn loadFont(self: *Self, name: []const u8, size: f32) !void {
        std.debug.assert(name.len > 0);
        std.debug.assert(size > 0 and size < 1000);

        if (self.current_face) |*f| f.deinit();
        self.current_face = try PlatformFace.init(name, size);
        self.cache.clear();
        // Force shape cache invalidation by setting invalid font ptr
        self.shape_cache.current_font_ptr = 0;
    }

    /// Load a system font
    pub fn loadSystemFont(self: *Self, style: SystemFont, size: f32) !void {
        std.debug.assert(size > 0 and size < 1000);

        if (self.current_face) |*f| f.deinit();
        self.current_face = try PlatformFace.initSystem(style, size);
        self.cache.clear();
        // Force shape cache invalidation
        self.shape_cache.current_font_ptr = 0;
    }

    /// Get current font metrics
    pub inline fn getMetrics(self: *const Self) ?Metrics {
        if (self.current_face) |f| return f.metrics;
        return null;
    }

    /// Get the FontFace interface for the current font
    pub inline fn getFontFace(self: *Self) !FontFace {
        if (self.current_face) |*f| {
            return f.asFontFace();
        }
        return error.NoFontLoaded;
    }

    /// Shape text with proper kerning and ligature support
    /// Stats parameter is optional - pass null to skip performance tracking
    pub inline fn shapeText(self: *Self, text: []const u8, stats: ?*RenderStats) !ShapedRun {
        return self.shapeTextComplex(text, stats);
    }

    /// Shape text using complex shaper (ligatures, kerning)
    /// Stats parameter is optional - pass null to skip performance tracking
    pub fn shapeTextComplex(self: *Self, text: []const u8, stats: ?*RenderStats) !ShapedRun {
        std.debug.assert(text.len > 0);

        const face = self.current_face orelse return error.NoFontLoaded;

        std.debug.assert(face.metrics.point_size > 0);

        // Build cache key using content hash
        const font_ptr = @intFromPtr(&self.current_face);

        // Only use cache for reasonably sized text
        const use_cache = text.len <= ShapedRunCache.MAX_TEXT_LEN;

        // Build cache key once, reuse for lookup and store
        const cache_key = if (use_cache)
            ShapedRunKey.init(text, font_ptr, face.metrics.point_size)
        else
            undefined;

        if (use_cache) {
            // Check font hasn't changed
            self.shape_cache.checkFont(font_ptr);

            // Check cache first
            if (self.shape_cache.get(cache_key)) |cached_run| {
                if (stats) |s| s.recordShapeCacheHit();
                return cached_run;
            }
        }

        // Cache miss - perform shaping
        if (self.shaper == null) {
            self.shaper = PlatformShaper.init(self.allocator);
        }

        std.debug.assert(self.shaper != null);

        // Time the shaping call for performance debugging (not available on WASM)
        const start_time = if (!is_wasm) std.time.nanoTimestamp() else 0;
        const result = try self.shaper.?.shape(&face, text, self.allocator);
        const end_time = if (!is_wasm) std.time.nanoTimestamp() else 0;

        std.debug.assert(result.width >= 0);
        std.debug.assert(result.owned == true);

        // Record stats (safe even if negative due to clock issues)
        // On WASM, elapsed will always be 0 since timing is unavailable
        if (stats) |s| {
            const elapsed: u64 = if (end_time > start_time)
                @intCast(end_time - start_time)
            else
                0;
            s.recordShapeMiss(elapsed);
        }

        // Cache the result for next time (reuse key computed earlier)
        if (use_cache) {
            self.shape_cache.put(cache_key, result);
        }

        return result;
    }

    /// Get cached glyph with subpixel variant (renders if needed)
    pub inline fn getGlyphSubpixel(self: *Self, glyph_id: u16, subpixel_x: u8, subpixel_y: u8) !CachedGlyph {
        const face = try self.getFontFace();
        return self.cache.getOrRenderSubpixel(face, glyph_id, subpixel_x, subpixel_y);
    }

    /// Simple width measurement
    /// On web, uses a single JS call instead of character-by-character iteration
    pub fn measureText(self: *Self, text: []const u8) !f32 {
        if (is_wasm) {
            // Web optimization: single JS call to measure entire string
            // This avoids N boundary crossings for N characters
            const face = self.current_face orelse return error.NoFontLoaded;
            const font_name = face.font_name_buf[0..face.font_name_len];
            const web_imports = @import("../platform/wgpu/web/imports.zig");
            return web_imports.measureText(
                font_name.ptr,
                @intCast(font_name.len),
                face.metrics.point_size,
                text.ptr,
                @intCast(text.len),
            );
        } else {
            const face = try self.getFontFace();
            return shaper_mod.measureSimple(face, text);
        }
    }

    /// Extended text measurement with wrapping support
    pub fn measureTextEx(self: *Self, text: []const u8, max_width: ?f32) !TextMeasurement {
        const face = try self.getFontFace();
        var run = try shaper_mod.shapeSimple(self.allocator, face, text);
        defer run.deinit(self.allocator);

        if (max_width == null or run.width <= max_width.?) {
            return .{
                .width = run.width,
                .height = face.metrics.line_height,
                .line_count = 1,
            };
        }

        // Text wrapping measurement
        var current_width: f32 = 0;
        var max_line_width: f32 = 0;
        var line_count: u32 = 1;
        var word_width: f32 = 0;

        for (run.glyphs) |glyph| {
            const char_idx = glyph.cluster;
            const is_space = char_idx < text.len and text[char_idx] == ' ';
            const is_newline = char_idx < text.len and text[char_idx] == '\n';

            if (is_newline) {
                max_line_width = @max(max_line_width, current_width);
                current_width = 0;
                line_count += 1;
                word_width = 0;
                continue;
            }

            word_width += glyph.x_advance;

            if (is_space) {
                if (current_width + word_width > max_width.? and current_width > 0) {
                    max_line_width = @max(max_line_width, current_width);
                    current_width = word_width;
                    line_count += 1;
                } else {
                    current_width += word_width;
                }
                word_width = 0;
            }
        }

        current_width += word_width;
        max_line_width = @max(max_line_width, current_width);

        return .{
            .width = max_line_width,
            .height = face.metrics.line_height * @as(f32, @floatFromInt(line_count)),
            .line_count = line_count,
        };
    }

    /// Get the glyph atlas for GPU upload
    pub inline fn getAtlas(self: *const Self) *const Atlas {
        return self.cache.getAtlas();
    }

    /// Check if atlas needs re-upload
    pub inline fn atlasGeneration(self: *const Self) u32 {
        return self.cache.getGeneration();
    }

    /// Get cached glyph from a fallback font
    pub inline fn getGlyphFallback(
        self: *Self,
        font_ptr: *anyopaque,
        glyph_id: u16,
        subpixel_x: u8,
        subpixel_y: u8,
    ) !CachedGlyph {
        const metrics = self.getMetrics() orelse return error.NoFontLoaded;
        return self.cache.getOrRenderFallback(font_ptr, glyph_id, metrics.point_size, subpixel_x, subpixel_y);
    }

    /// Get shape cache statistics for debugging
    pub fn getShapeCacheStats(self: *const Self) struct { entries: u32, capacity: u32 } {
        return self.shape_cache.getStats();
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ShapedRunKey hash consistency" {
    const key1 = ShapedRunKey.init("Hello", 0x1234, 16.0);
    const key2 = ShapedRunKey.init("Hello", 0x1234, 16.0);
    const key3 = ShapedRunKey.init("World", 0x1234, 16.0);

    try std.testing.expect(ShapedRunKey.eql(key1, key2));
    try std.testing.expect(!ShapedRunKey.eql(key1, key3));
    try std.testing.expectEqual(key1.text_hash, key2.text_hash);
    try std.testing.expect(key1.text_hash != key3.text_hash);
}

test "ShapedRunCache basic operations" {
    var cache = ShapedRunCache.init();
    defer cache.deinit();

    // Create test glyphs
    var glyphs = [_]ShapedGlyph{
        .{ .glyph_id = 1, .x_offset = 0, .y_offset = 0, .x_advance = 10, .y_advance = 0, .cluster = 0 },
        .{ .glyph_id = 2, .x_offset = 0, .y_offset = 0, .x_advance = 10, .y_advance = 0, .cluster = 1 },
    };

    const run = ShapedRun{
        .glyphs = &glyphs,
        .width = 20.0,
        .owned = true,
    };

    const key = ShapedRunKey.init("ab", 0x1000, 16.0);
    cache.checkFont(0x1000);

    // Miss before put
    try std.testing.expect(cache.get(key) == null);

    // Put and hit
    cache.put(key, run);
    const cached = cache.get(key);
    try std.testing.expect(cached != null);
    try std.testing.expectEqual(@as(usize, 2), cached.?.glyphs.len);
    try std.testing.expectEqual(@as(f32, 20.0), cached.?.width);
    try std.testing.expect(!cached.?.owned); // Cache owns it
}

test "ShapedRunCache LRU eviction" {
    var cache = ShapedRunCache.init();
    defer cache.deinit();

    var glyph = ShapedGlyph{
        .glyph_id = 1,
        .x_offset = 0,
        .y_offset = 0,
        .x_advance = 10,
        .y_advance = 0,
        .cluster = 0,
    };

    const run = ShapedRun{
        .glyphs = @as(*[1]ShapedGlyph, &glyph),
        .width = 10.0,
        .owned = true,
    };

    cache.checkFont(0x1000);

    // Fill cache completely
    var i: usize = 0;
    while (i < ShapedRunCache.MAX_ENTRIES) : (i += 1) {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "text{d}", .{i}) catch unreachable;
        const key = ShapedRunKey.init(text, 0x1000, 16.0);
        cache.put(key, run);
    }

    try std.testing.expectEqual(@as(u32, ShapedRunCache.MAX_ENTRIES), cache.entry_count);

    // Access first entry to make it recently used
    const first_key = ShapedRunKey.init("text0", 0x1000, 16.0);
    _ = cache.get(first_key);

    // Add one more - should evict LRU (which is text1, not text0)
    const new_key = ShapedRunKey.init("newtext", 0x1000, 16.0);
    cache.put(new_key, run);

    // Cache should still be at capacity
    try std.testing.expectEqual(@as(u32, ShapedRunCache.MAX_ENTRIES), cache.entry_count);

    // New entry should be present
    try std.testing.expect(cache.get(new_key) != null);

    // text0 should still be present (was accessed recently)
    try std.testing.expect(cache.get(first_key) != null);
}

test "ShapedRunCache font change invalidation" {
    var cache = ShapedRunCache.init();
    defer cache.deinit();

    var glyph = ShapedGlyph{
        .glyph_id = 1,
        .x_offset = 0,
        .y_offset = 0,
        .x_advance = 10,
        .y_advance = 0,
        .cluster = 0,
    };

    const run = ShapedRun{
        .glyphs = @as(*[1]ShapedGlyph, &glyph),
        .width = 10.0,
        .owned = true,
    };

    cache.checkFont(0x1000);
    const key = ShapedRunKey.init("test", 0x1000, 16.0);
    cache.put(key, run);

    try std.testing.expect(cache.get(key) != null);
    try std.testing.expectEqual(@as(u32, 1), cache.entry_count);

    // Change font - should clear cache
    cache.checkFont(0x2000);

    try std.testing.expectEqual(@as(u32, 0), cache.entry_count);
    try std.testing.expect(cache.get(key) == null);
}

test "ShapedRunCache hash collision handling" {
    var cache = ShapedRunCache.init();
    defer cache.deinit();

    var glyph = ShapedGlyph{
        .glyph_id = 1,
        .x_offset = 0,
        .y_offset = 0,
        .x_advance = 10,
        .y_advance = 0,
        .cluster = 0,
    };

    const run = ShapedRun{
        .glyphs = @as(*[1]ShapedGlyph, &glyph),
        .width = 10.0,
        .owned = true,
    };

    cache.checkFont(0x1000);

    // Insert many entries that may have hash collisions
    // Using sequential strings which may hash to nearby slots
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "collision_test_{d}", .{i}) catch unreachable;
        const key = ShapedRunKey.init(text, 0x1000, 16.0);
        cache.put(key, run);
    }

    try std.testing.expectEqual(@as(u32, 100), cache.entry_count);

    // Verify all entries are still retrievable (hash probing works)
    i = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "collision_test_{d}", .{i}) catch unreachable;
        const key = ShapedRunKey.init(text, 0x1000, 16.0);
        try std.testing.expect(cache.get(key) != null);
    }

    // Test eviction maintains hash table consistency
    // Add more entries to trigger evictions
    i = 100;
    while (i < ShapedRunCache.MAX_ENTRIES + 50) : (i += 1) {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "evict_test_{d}", .{i}) catch unreachable;
        const key = ShapedRunKey.init(text, 0x1000, 16.0);
        cache.put(key, run);
    }

    // Cache should be at capacity
    try std.testing.expectEqual(@as(u32, ShapedRunCache.MAX_ENTRIES), cache.entry_count);

    // Most recent entries should be retrievable
    i = ShapedRunCache.MAX_ENTRIES;
    while (i < ShapedRunCache.MAX_ENTRIES + 50) : (i += 1) {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "evict_test_{d}", .{i}) catch unreachable;
        const key = ShapedRunKey.init(text, 0x1000, 16.0);
        try std.testing.expect(cache.get(key) != null);
    }
}
