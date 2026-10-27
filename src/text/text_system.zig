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
const cache_mod = @import("cache.zig");
const platform = @import("../platform/mod.zig");
const render_stats = @import("../debug/render_stats.zig");
const RenderStats = render_stats.RenderStats;

const atlas_mod = @import("atlas.zig");
const Atlas = atlas_mod.Atlas;

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
        var prefix: [PREFIX_LEN]u8 = @splat(0);
        const copy_len = @min(text.len, PREFIX_LEN);
        @memcpy(prefix[0..copy_len], text[0..copy_len]);
        return prefix;
    }

    /// Extract suffix bytes, zero-padded if text is shorter
    fn extractSuffix(text: []const u8) [SUFFIX_LEN]u8 {
        var suffix: [SUFFIX_LEN]u8 = @splat(0);
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
            .hash_table = @as([HASH_TABLE_SIZE]u16, @splat(EMPTY_SLOT)),
            .entry_count = 0,
            .access_counter = 0,
        };

        // Initialize all entries as invalid
        for (&self.entries) |*entry| {
            entry.clear();
        }

        std.debug.assert(self.entry_count == 0);
        std.debug.assert(self.access_counter == 0);

        return self;
    }

    /// Initialize ShapedRunCache in-place using out-pointer pattern.
    /// Avoids stack overflow on WASM where ShapedRunCache is ~1.5MB.
    /// Marked noinline to prevent stack accumulation in WASM builds.
    pub noinline fn initInPlace(self: *Self) void {
        self.entry_count = 0;
        self.access_counter = 0;

        // Initialize hash table to empty slots
        @memset(&self.hash_table, EMPTY_SLOT);

        // Initialize all entries as invalid
        for (&self.entries) |*entry| {
            entry.clear();
        }

        std.debug.assert(self.entry_count == 0);
        std.debug.assert(self.access_counter == 0);
    }

    pub fn deinit(self: *Self) void {
        // No dynamic memory to free - just clear state
        self.entry_count = 0;
        self.access_counter = 0;
        self.* = undefined;
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

    /// Drop every entry. Keys hold the face address, and `TextSystem` reloads
    /// faces into the same slots, so a font change must clear explicitly.
    /// Entries for different faces coexist; nothing clears on a face switch.
    pub fn clear(self: *Self) void {
        for (&self.entries) |*entry| {
            entry.clear();
        }
        // Clear hash table
        @memset(&self.hash_table, EMPTY_SLOT);

        self.entry_count = 0;
        // Don't reset access_counter to preserve LRU ordering after clear

        std.debug.assert(self.entry_count == 0);
    }
};

// =============================================================================
// Measure Cache - Width-Only, Fixed Capacity, Zero Runtime Allocation
// =============================================================================

/// A single width-only measurement slot.
const MeasureEntry = struct {
    key: ShapedRunKey,
    width: f32,
    /// LRU tracking - higher = more recently used
    last_access: u32,
    /// Is this slot in use?
    valid: bool,

    const Self = @This();

    fn clear(self: *Self) void {
        self.valid = false;
        self.last_access = 0;
        self.width = 0;
    }
};

/// Cache of text *widths*, independent of the shaped-run cache.
///
/// Why this exists as a separate cache: `ShapedRunCache` refuses any run longer
/// than `MAX_GLYPHS_PER_ENTRY` (128), because every entry embeds its glyph array
/// inline -- 128 glyphs x 44 bytes is ~5.6KB per entry, and 256 of those already
/// sit just under the 2MB comptime budget asserted above.  Raising that limit to
/// cover `MAX_TEXT_LEN` (512) would multiply the cache by 4x and blow it.
///
/// But `measureText` never looks at the glyphs -- it reads the scalar `width` and
/// throws the rest away.  Storing only the width costs ~56 bytes per entry
/// instead of ~5.6KB, which is ~100x cheaper and comfortably covers the whole
/// `MAX_TEXT_LEN` range.  Without this, every string between 129 and 512 bytes is
/// a *permanent* miss: it passes the lookup gate, shapes through CoreText, then
/// gets refused on insert, so the next frame repeats the entire cycle.
///
/// Layout is set-associative rather than the index-plus-hash-table scheme used by
/// `ShapedRunCache`.  Entries are small enough to live directly in the probe
/// window, so a bounded linear probe with LRU eviction inside that window needs no
/// separate hash table, no tombstones, and no rehash-on-removal.
pub const MeasureCache = struct {
    /// Pre-allocated slots, indexed directly by hash
    slots: [SLOT_COUNT]MeasureEntry,
    /// Global access counter for LRU
    access_counter: u32,

    const Self = @This();

    // Capacity limits. 1024 x ~56 bytes is ~57KB -- two orders of magnitude below
    // the shaped-run cache, so this is affordable at a much higher entry count.
    pub const SLOT_COUNT: usize = 1024;
    /// Associativity: how far a key may probe from its natural slot before the
    /// least-recently-used slot in that window is evicted. Bounds worst-case
    /// lookup to a fixed number of comparisons.
    pub const MAX_PROBE_LENGTH: usize = 8;

    comptime {
        // Power of two keeps the modulo a mask.
        std.debug.assert(std.math.isPowerOfTwo(SLOT_COUNT));
        std.debug.assert(MAX_PROBE_LENGTH < SLOT_COUNT);
        // Stay far below the shaped-run cache budget; this is the whole point.
        std.debug.assert(@sizeOf(MeasureEntry) * SLOT_COUNT < 128 * 1024);
    }

    /// Initialize in-place using the out-pointer pattern, matching
    /// `ShapedRunCache`. Marked noinline to keep the ~57KB off the WASM stack.
    pub noinline fn initInPlace(self: *Self) void {
        self.access_counter = 0;

        for (&self.slots) |*slot| {
            slot.clear();
        }

        std.debug.assert(self.access_counter == 0);
        std.debug.assert(!self.slots[0].valid);
    }

    pub fn init() Self {
        var self: Self = undefined;
        self.initInPlace();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.access_counter = 0;
        self.* = undefined;
    }

    /// Look up a cached width. Returns null on miss. Updates LRU on hit.
    pub fn get(self: *Self, key: ShapedRunKey) ?f32 {
        std.debug.assert(key.text_len > 0);
        std.debug.assert(key.text_len <= ShapedRunCache.MAX_TEXT_LEN);

        const start_slot = @as(usize, @truncate(key.text_hash)) % SLOT_COUNT;

        for (0..MAX_PROBE_LENGTH) |offset| {
            const slot = &self.slots[(start_slot + offset) % SLOT_COUNT];

            if (slot.valid) {
                if (ShapedRunKey.eql(slot.key, key)) {
                    self.access_counter += 1;
                    slot.last_access = self.access_counter;

                    std.debug.assert(slot.width >= 0);
                    return slot.width;
                }
            } else {
                // An empty slot inside the probe window means the key was never
                // inserted: `put` always fills the first empty slot it finds.
                return null;
            }
        }

        return null;
    }

    /// Store a width, evicting the least-recently-used slot in the probe window
    /// if every slot there is already taken.
    pub fn put(self: *Self, key: ShapedRunKey, width: f32) void {
        std.debug.assert(key.text_len > 0);
        std.debug.assert(key.text_len <= ShapedRunCache.MAX_TEXT_LEN);
        std.debug.assert(width >= 0);

        const start_slot = @as(usize, @truncate(key.text_hash)) % SLOT_COUNT;

        var victim_index: usize = start_slot;
        var oldest_access: u32 = std.math.maxInt(u32);

        for (0..MAX_PROBE_LENGTH) |offset| {
            const index = (start_slot + offset) % SLOT_COUNT;
            const slot = &self.slots[index];

            if (slot.valid) {
                // Refresh in place when the key is already present.
                if (ShapedRunKey.eql(slot.key, key)) {
                    victim_index = index;
                    break;
                }
                if (slot.last_access < oldest_access) {
                    oldest_access = slot.last_access;
                    victim_index = index;
                }
            } else {
                victim_index = index;
                break;
            }
        }

        const victim = &self.slots[victim_index];
        victim.key = key;
        victim.width = width;
        victim.valid = true;
        self.access_counter += 1;
        victim.last_access = self.access_counter;

        std.debug.assert(victim.valid);
        std.debug.assert(victim.width == width);
    }

    /// Drop every width. Widths are only meaningful for the face that produced
    /// them; keys carry the face address, so faces coexist and only a font
    /// reload, which reuses those addresses, clears.
    pub fn clear(self: *Self) void {
        for (&self.slots) |*slot| {
            slot.clear();
        }
        // Don't reset access_counter, to preserve LRU ordering after clear.

        std.debug.assert(!self.slots[0].valid);
        std.debug.assert(!self.slots[SLOT_COUNT - 1].valid);
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
pub const FontVariant = types.FontVariant;
pub const FontLimits = @import("../core/limits.zig").FontLimits;
pub const CachedGlyph = cache_mod.CachedGlyph;
pub const AtlasOptions = cache_mod.AtlasOptions;
pub const SUBPIXEL_VARIANTS_X = types.SUBPIXEL_VARIANTS_X;

/// High-level text system
pub const TextSystem = struct {
    allocator: std.mem.Allocator,
    cache: cache_mod.GlyphCache,
    /// One face per variant in `FontLimits.variants`, allocated at init and
    /// reloaded in place by `loadFont`. Slot addresses never change, so
    /// `@intFromPtr(&faces[slot])` is a stable per-face cache key.
    faces: []PlatformFace,
    /// The variant each slot holds, in `FontLimits.variants` order.
    face_variants: [FontVariant.count]FontVariant,
    /// Slot of each variant, or `face_slot_none` when the set omits it.
    face_slot_by_variant: [FontVariant.count]u8,
    /// True once every slot holds a loaded face.
    faces_loaded: bool,
    /// Where the loaded set came from; meaningful only while `faces_loaded`.
    loaded_source: LoadedSource,
    /// Complex shaper (native only, void on web)
    shaper: ?PlatformShaper,
    scale_factor: f32,
    /// Cache for shaped text runs (fixed capacity, pre-allocated)
    shape_cache: ShapedRunCache,
    /// Cache for text widths (fixed capacity, pre-allocated). Covers the full
    /// MAX_TEXT_LEN range that `shape_cache` cannot -- see `MeasureCache`.
    measure_cache: MeasureCache,
    /// IO instance for mutex operations. Stored on the struct because lock
    /// sites run on CVDisplayLink threads that have no access to `*Cx` and
    /// therefore cannot reach `cx.io()`. Io is a pair of pointers into the
    /// process-lifetime vtable — safe to copy across threads.
    io: std.Io,
    /// Mutex for thread-safe shape cache access in multi-window scenarios.
    /// Multiple DisplayLink threads may call shapeText concurrently.
    /// Uses `lockUncancelable` everywhere — none of the text call sites
    /// propagate `std.Io.Cancelable`, and the critical sections are short
    /// enough that cancelation points would add noise without value.
    shape_cache_mutex: std.Io.Mutex,
    /// Mutex for thread-safe glyph cache/atlas access in multi-window scenarios.
    /// Multiple DisplayLink threads may render glyphs concurrently, and the
    /// atlas skyline data structure is not thread-safe.
    glyph_cache_mutex: std.Io.Mutex,

    const Self = @This();

    const face_slot_none: u8 = std.math.maxInt(u8);

    comptime {
        std.debug.assert(FontVariant.count < face_slot_none);
    }

    /// Initialize TextSystem in-place using out-pointer pattern.
    /// Avoids stack overflow on WASM where TextSystem is ~1.7MB
    /// (GlyphCache: ~200KB, ShapedRunCache: ~1.5MB).
    /// Marked noinline to prevent stack accumulation in WASM builds.
    ///
    /// Reserves one face slot per `font_limits.variants` entry; `loadFont` or
    /// `loadSystemFont` fills every slot before the first frame.
    pub noinline fn initInPlace(
        self: *Self,
        allocator: std.mem.Allocator,
        scale: f32,
        io: std.Io,
        font_limits: *const FontLimits,
        atlas_options: cache_mod.AtlasOptions,
    ) !void {
        std.debug.assert(scale > 0);
        std.debug.assert(scale <= 4.0); // Reasonable scale factor limit
        font_limits.assertValid();

        self.faces = try allocator.alloc(PlatformFace, font_limits.variants.len);
        errdefer allocator.free(self.faces);

        self.face_variants = @splat(.regular);
        self.face_slot_by_variant = @splat(face_slot_none);
        for (font_limits.variants, 0..) |variant, slot| {
            self.face_variants[slot] = variant;
            self.face_slot_by_variant[@backingInt(variant)] = @intCast(slot);
        }
        self.faces_loaded = false;
        self.loaded_source.system = null;
        self.loaded_source.name_buffer = @splat(0);
        self.loaded_source.name_len = 0;
        self.loaded_source.size = 0;
        self.allocator = allocator;
        self.shaper = null;
        self.scale_factor = scale;
        self.io = io;

        // Initialize caches in-place to avoid large stack temporaries
        try self.cache.initInPlace(allocator, scale, atlas_options);
        errdefer self.cache.deinit();
        self.shape_cache.initInPlace();
        self.measure_cache.initInPlace();
        self.shape_cache_mutex = .init;
        self.glyph_cache_mutex = .init;

        std.debug.assert(self.faces.len == font_limits.variants.len);
        const regular_slot = self.face_slot_by_variant[@backingInt(FontVariant.regular)];
        std.debug.assert(regular_slot < self.faces.len);
    }

    pub fn setScaleFactor(self: *Self, scale: f32) void {
        std.debug.assert(scale > 0);
        std.debug.assert(scale <= 4.0);

        self.scale_factor = scale;
        self.cache.setScaleFactor(scale);
    }

    pub fn deinit(self: *Self) void {
        self.unloadFaces();
        self.allocator.free(self.faces);
        if (self.shaper) |*s| s.deinit();
        self.cache.deinit();
        self.shape_cache.deinit();
        self.measure_cache.deinit();
        self.* = undefined;
    }

    /// Load every variant in the face set from the named family. `cx.setFont`
    /// reaches this at runtime, under the platform's render exclusion: the set
    /// is reloaded into the same slots, so a font change claims no new storage.
    pub fn loadFont(self: *Self, name: []const u8, size: f32) !void {
        std.debug.assert(name.len > 0);
        std.debug.assert(size > 0 and size < 1000);
        // Checked before any face is unloaded, so a bad name changes nothing.
        if (name.len > family_name_bytes_max) return error.FontNameTooLong;
        try self.loadFaces(.{ .name = name }, size);
    }

    /// Load every variant in the face set from a system family.
    pub fn loadSystemFont(self: *Self, style: SystemFont, size: f32) !void {
        std.debug.assert(size > 0 and size < 1000);
        try self.loadFaces(.{ .system = style }, size);
    }

    /// Longest family name `loadFont` accepts; the loaded name is kept so a
    /// failed reload can restore it.
    pub const family_name_bytes_max: u32 = 255;

    const FaceSource = union(enum) {
        name: []const u8,
        system: SystemFont,
    };

    /// The source of the loaded set, with the family name copied inline.
    const LoadedSource = struct {
        system: ?SystemFont,
        name_buffer: [family_name_bytes_max]u8,
        name_len: u8,
        size: f32,

        fn faceSource(self: *const LoadedSource) FaceSource {
            if (self.system) |style| return .{ .system = style };
            std.debug.assert(self.name_len > 0);
            return .{ .name = self.name_buffer[0..self.name_len] };
        }
    };

    /// Replace every face, then drop cached data keyed by the old faces.
    ///
    /// The set is never left empty once loaded: if the new family fails
    /// partway, the previous one is reloaded before the error is returned, so
    /// a frame after a failed `cx.setFont` still has a complete set. Only the
    /// first load at init can fail with nothing loaded, before any frame.
    fn loadFaces(self: *Self, source: FaceSource, size: f32) !void {
        std.debug.assert(self.faces.len > 0);
        std.debug.assert(self.faces.len <= FontVariant.count);

        const previous: ?LoadedSource = if (self.faces_loaded) self.loaded_source else null;
        self.unloadFaces();
        self.loadEveryFace(source, size) catch |err| {
            const restore = previous orelse return err;
            self.loadEveryFace(restore.faceSource(), restore.size) catch |restore_err| {
                std.debug.panic(
                    "TextSystem: font reload failed ({s}) and the previous font " ++
                        "could not be restored ({s})",
                    .{ @errorName(err), @errorName(restore_err) },
                );
            };
            self.clearCaches();
            return err;
        };

        self.loaded_source.size = size;
        switch (source) {
            .system => |style| self.loaded_source.system = style,
            .name => |name| {
                std.debug.assert(name.len <= family_name_bytes_max);
                self.loaded_source.system = null;
                @memcpy(self.loaded_source.name_buffer[0..name.len], name);
                self.loaded_source.name_len = @intCast(name.len);
            },
        }
        self.clearCaches();

        std.debug.assert(self.faces_loaded);
        std.debug.assert(self.faceFor(.regular).metrics.point_size == size);
    }

    /// Load one face per slot; on failure, release the faces already loaded.
    fn loadEveryFace(self: *Self, source: FaceSource, size: f32) !void {
        std.debug.assert(!self.faces_loaded);
        var loaded_count: usize = 0;
        errdefer for (self.faces[0..loaded_count]) |*face| face.deinit();

        while (loaded_count < self.faces.len) : (loaded_count += 1) {
            const variant = self.face_variants[loaded_count];
            self.faces[loaded_count] = switch (source) {
                .name => |name| try PlatformFace.init(name, size, variant),
                .system => |style| try PlatformFace.initSystem(style, size, variant),
            };
        }
        self.faces_loaded = true;
        std.debug.assert(loaded_count == self.faces.len);
    }

    /// Drop every cached glyph; the atlas condemns their pixels. Called when a
    /// renderer whose texture starts empty begins drawing from the atlas.
    pub fn clearGlyphCache(self: *Self) void {
        self.glyph_cache_mutex.lockUncancelable(self.io);
        defer self.glyph_cache_mutex.unlock(self.io);
        self.cache.clear();
        std.debug.assert(self.cache.entry_count == 0);
    }

    /// Faces reuse their slot addresses across reloads, so the keyed pointers
    /// cannot signal the change: every cache is cleared explicitly instead.
    fn clearCaches(self: *Self) void {
        self.glyph_cache_mutex.lockUncancelable(self.io);
        self.cache.clear();
        self.glyph_cache_mutex.unlock(self.io);
        self.shape_cache_mutex.lockUncancelable(self.io);
        self.shape_cache.clear();
        self.measure_cache.clear();
        self.shape_cache_mutex.unlock(self.io);
    }

    fn unloadFaces(self: *Self) void {
        if (self.faces_loaded) {
            for (self.faces) |*face| face.deinit();
        }
        self.faces_loaded = false;
    }

    /// The loaded face for `variant`. A variant outside `FontLimits.variants`
    /// is a programmer error and panics in every build mode: the check is one
    /// byte compare, and substituting another face would silently mis-measure.
    pub fn faceFor(self: *Self, variant: FontVariant) *PlatformFace {
        std.debug.assert(self.faces_loaded);
        const slot = self.face_slot_by_variant[@backingInt(variant)];
        if (slot < self.faces.len) {
            std.debug.assert(self.face_variants[slot] == variant);
            return &self.faces[slot];
        } else {
            self.panicVariantNotLoaded(variant);
        }
    }

    fn panicVariantNotLoaded(self: *const Self, variant: FontVariant) noreturn {
        // Each entry is a ", " separator plus one tag name.
        const entry_bytes_max = comptime blk: {
            var tag_len_max: usize = 0;
            for (std.meta.fieldNames(FontVariant)) |name| tag_len_max = @max(tag_len_max, name.len);
            break :blk tag_len_max + 2;
        };
        var names_buffer: [FontVariant.count * entry_bytes_max]u8 = undefined;
        var names_len: usize = 0;
        std.debug.assert(self.faces.len <= FontVariant.count);
        for (self.face_variants[0..self.faces.len], 0..) |loaded, index| {
            const separator = if (index == 0) "" else ", ";
            // Cannot fail: at most `count` entries of at most `entry_bytes_max` bytes.
            const written = std.fmt.bufPrint(names_buffer[names_len..], "{s}{s}", .{
                separator,
                @tagName(loaded),
            }) catch unreachable;
            names_len += written.len;
        }
        std.debug.panic(
            "TextSystem: font variant '{s}' (font_id {d}) is not loaded; " ++
                "FontLimits.variants loads {d} face{s}: {s}. Add it to the app's font_limits.",
            .{
                @tagName(variant),
                variant.fontId(),
                self.faces.len,
                if (self.faces.len == 1) "" else "s",
                names_buffer[0..names_len],
            },
        );
    }

    /// Metrics of the regular face, which set line height and baseline for all
    /// variants so mixed weights on one line share a baseline.
    pub inline fn getMetrics(self: *const Self) ?Metrics {
        if (!self.faces_loaded) return null;
        const slot = self.face_slot_by_variant[@backingInt(FontVariant.regular)];
        return self.faces[slot].metrics;
    }

    /// The FontFace interface of the regular face.
    pub inline fn getFontFace(self: *Self) !FontFace {
        if (!self.faces_loaded) return error.NoFontLoaded;
        return self.faceFor(.regular).asFontFace();
    }

    /// Shape text with proper kerning and ligature support.
    /// Stats parameter is optional - pass null to skip performance tracking.
    pub fn shapeText(
        self: *Self,
        text: []const u8,
        variant: FontVariant,
        stats: ?*RenderStats,
    ) !ShapedRun {
        std.debug.assert(text.len > 0);

        if (!self.faces_loaded) return error.NoFontLoaded;
        const face = self.faceFor(variant);

        std.debug.assert(face.metrics.point_size > 0);

        const font_ptr = @intFromPtr(face);
        const use_cache = text.len <= ShapedRunCache.MAX_TEXT_LEN;

        // Build the key once, reuse for lookup and store.
        const cache_key = if (use_cache)
            ShapedRunKey.init(text, font_ptr, face.metrics.point_size)
        else
            undefined;

        if (use_cache) {
            self.shape_cache_mutex.lockUncancelable(self.io);
            defer self.shape_cache_mutex.unlock(self.io);

            if (self.shape_cache.get(cache_key)) |cached_run| {
                if (stats) |s| s.recordShapeCacheHit();
                // Copy glyphs to owned memory to prevent use-after-free race.
                // The cache entry may be evicted by another thread after we release
                // shape_cache_mutex, so we must not return a slice pointing into cache memory.
                const glyphs_copy = try self.allocator.alloc(types.ShapedGlyph, cached_run.glyphs.len);
                @memcpy(glyphs_copy, cached_run.glyphs);
                return types.ShapedRun{
                    .glyphs = glyphs_copy,
                    .width = cached_run.width,
                    .owned = true,
                };
            }
        }

        // Cache miss - perform shaping
        if (self.shaper == null) {
            self.shaper = PlatformShaper.init(self.allocator);
        }

        std.debug.assert(self.shaper != null);

        // Time the shaping call for stats (native only — skip the JS FFI clock
        // read on WASM's hot path). Monotonic `.awake` keeps `elapsed` >= 0.
        const start_ts = if (!is_wasm) std.Io.Timestamp.now(self.io, .awake) else std.Io.Timestamp.zero;
        const result = try self.shaper.?.shape(face, text, self.allocator);
        const end_ts = if (!is_wasm) std.Io.Timestamp.now(self.io, .awake) else std.Io.Timestamp.zero;

        std.debug.assert(result.width >= 0);
        std.debug.assert(result.owned == true);

        // Record stats. On WASM, `elapsed` is always 0 since timing is skipped.
        if (stats) |s| {
            const elapsed_ns: i96 = start_ts.durationTo(end_ts).toNanoseconds();
            std.debug.assert(elapsed_ns >= 0);
            s.recordShapeMiss(@intCast(elapsed_ns));
        }

        // Cache the result for next time (reuse key computed earlier)
        if (use_cache) {
            // Lock for thread-safe cache write
            self.shape_cache_mutex.lockUncancelable(self.io);
            defer self.shape_cache_mutex.unlock(self.io);
            self.shape_cache.put(cache_key, result);
        }

        return result;
    }

    /// Shape text into a caller-provided glyph buffer, avoiding heap allocation
    /// on the warm (cache-hit) path.  On a hit, glyphs are memcpy'd into
    /// `out_glyphs` and the returned ShapedRun has `owned = false` — no deinit
    /// needed.  On a cache miss (or if the glyph count exceeds the buffer),
    /// falls through to `shapeText` which heap-allocates via GPA; the returned
    /// run then has `owned = true` and the caller must deinit it.
    ///
    /// Typical usage with a stack buffer (zero heap alloc on warm path):
    ///
    ///   var buf: [ShapedRunCache.MAX_GLYPHS_PER_ENTRY]ShapedGlyph = undefined;
    ///   var shaped = try ts.shapeTextInto(text, .regular, stats, &buf);
    ///   defer if (shaped.owned) shaped.deinit(ts.allocator);
    pub fn shapeTextInto(
        self: *Self,
        text: []const u8,
        variant: FontVariant,
        stats: ?*RenderStats,
        out_glyphs: []types.ShapedGlyph,
    ) !ShapedRun {
        std.debug.assert(text.len > 0);
        std.debug.assert(out_glyphs.len > 0);

        if (!self.faces_loaded) return error.NoFontLoaded;
        const face = self.faceFor(variant);

        std.debug.assert(face.metrics.point_size > 0);

        const font_ptr = @intFromPtr(face);
        const use_cache = text.len <= ShapedRunCache.MAX_TEXT_LEN;

        // Warm path: copy cached glyphs into caller's buffer — zero heap allocation.
        if (use_cache) {
            const cache_key = ShapedRunKey.init(text, font_ptr, face.metrics.point_size);

            self.shape_cache_mutex.lockUncancelable(self.io);
            defer self.shape_cache_mutex.unlock(self.io);

            if (self.shape_cache.get(cache_key)) |cached_run| {
                if (stats) |s| s.recordShapeCacheHit();
                std.debug.assert(cached_run.glyphs.len <= ShapedRunCache.MAX_GLYPHS_PER_ENTRY);

                if (cached_run.glyphs.len <= out_glyphs.len) {
                    const count = cached_run.glyphs.len;
                    @memcpy(out_glyphs[0..count], cached_run.glyphs);
                    return types.ShapedRun{
                        .glyphs = out_glyphs[0..count],
                        .width = cached_run.width,
                        .owned = false,
                    };
                }
                // Buffer too small — fall through to heap path.
            }
        }

        // Cold path (or buffer overflow): delegate to heap-allocating shapeText.
        // Returns owned = true; caller must deinit with self.allocator.
        return self.shapeText(text, variant, stats);
    }

    /// Get cached glyph with subpixel variant (renders if needed)
    /// Thread-safe: protected by glyph_cache_mutex for multi-window scenarios.
    pub fn getGlyphSubpixel(self: *Self, glyph_id: u16, font_size: f32, subpixel_x: u8, subpixel_y: u8) !CachedGlyph {
        std.debug.assert(font_size > 0);
        const face = try self.getFontFace();

        // Lock for thread-safe glyph cache/atlas access (multiple DisplayLink threads)
        self.glyph_cache_mutex.lockUncancelable(self.io);
        defer self.glyph_cache_mutex.unlock(self.io);

        return self.cache.getOrRenderSubpixel(face, glyph_id, font_size, subpixel_x, subpixel_y);
    }

    /// Simple width measurement.
    /// Zero-alloc fast path: on a shape cache hit, reads width directly from the
    /// cache entry under the mutex — no glyph array copy, no allocator call
    /// (~200x faster than the alloc+memcpy+free path: ~25 ns vs ~5200 ns warm).
    /// On web, uses a single JS call instead of character-by-character iteration.
    pub fn measureText(self: *Self, text: []const u8, variant: FontVariant) !f32 {
        if (!self.faces_loaded) return error.NoFontLoaded;
        // The width comes from the face that renders the text: a bold run is
        // wider than the same string in regular, so layout must measure it bold.
        const face = self.faceFor(variant);
        if (is_wasm) {
            // Web optimization: single JS call to measure entire string.
            // This avoids N boundary crossings for N characters.
            const font_name = face.font_name_buf[0..face.font_name_len];
            const web_imports = @import("../platform/web/imports.zig");
            return web_imports.measureText(
                font_name.ptr,
                @intCast(font_name.len),
                face.metrics.point_size,
                text.ptr,
                @intCast(text.len),
            );
        } else {
            if (text.len == 0) return 0;
            std.debug.assert(face.metrics.point_size > 0);

            // Text past MAX_TEXT_LEN cannot even be keyed -- `hashText` asserts
            // that bound -- so it shapes uncached on every call.  Accepted: it is
            // far rarer than the 129..512 band that `MeasureCache` covers.
            if (text.len > ShapedRunCache.MAX_TEXT_LEN) {
                var shaped_long = try self.shapeText(text, variant, &render_stats.frame_stats);
                defer shaped_long.deinit(self.allocator);
                return shaped_long.width;
            }

            // Keyed by face, like the shaped-run cache, so each variant's
            // widths stay resident side by side.
            const font_ptr = @intFromPtr(face);
            const cache_key = ShapedRunKey.init(text, font_ptr, face.metrics.point_size);

            // Fast path: both caches are read under the same mutex, and only the
            // scalar `width` is copied out — no slice escapes the lock scope.
            {
                self.shape_cache_mutex.lockUncancelable(self.io);
                defer self.shape_cache_mutex.unlock(self.io);

                if (self.measure_cache.get(cache_key)) |cached_width| {
                    std.debug.assert(cached_width >= 0);
                    render_stats.frame_stats.recordShapeCacheHit();
                    return cached_width;
                }

                // The shaped-run cache may already hold this text from a render
                // pass. Promote the width so later measurements skip it entirely.
                if (self.shape_cache.get(cache_key)) |cached_run| {
                    std.debug.assert(cached_run.width >= 0);
                    self.measure_cache.put(cache_key, cached_run.width);
                    render_stats.frame_stats.recordShapeCacheHit();
                    return cached_run.width;
                }
            }

            // Miss: shape once via CoreText/HarfBuzz, then record the width so
            // this text never shapes again.  `shapeText` populates the shaped-run
            // cache only when the run fits MAX_GLYPHS_PER_ENTRY; the width cache
            // has no such limit, which is what makes the miss non-recurring.
            //
            // Stats are reported so the cost is visible in the profiler rather
            // than silent. Measurement runs on the main thread during frame
            // building -- the same thread that resets `frame_stats` in
            // `beginFrame` -- so the unsynchronised increment is safe here.
            var shaped = try self.shapeText(text, variant, &render_stats.frame_stats);
            defer shaped.deinit(self.allocator);
            std.debug.assert(shaped.width >= 0);

            {
                self.shape_cache_mutex.lockUncancelable(self.io);
                defer self.shape_cache_mutex.unlock(self.io);
                self.measure_cache.put(cache_key, shaped.width);
            }

            return shaped.width;
        }
    }

    /// Extended text measurement with wrapping support.
    /// Zero-alloc fast path: on a shape cache hit, computes the word-wrapping
    /// measurement directly over the cached glyph slice under the mutex — no
    /// glyph array copy, no allocator call.  Falls through to `shapeText` on
    /// cache miss.
    pub fn measureTextEx(
        self: *Self,
        text: []const u8,
        variant: FontVariant,
        max_width: ?f32,
    ) !TextMeasurement {
        if (!self.faces_loaded) return error.NoFontLoaded;
        const face = self.faceFor(variant);
        // Rows take their height from the regular face, as in layout and
        // rendering, so wrapped bold text measures as many pixels tall as it draws.
        const line_height = self.faceFor(.regular).metrics.line_height;
        std.debug.assert(line_height > 0);

        // Fast path: measure directly from shape cache under the lock.
        // The cache entry is valid while the mutex is held; we iterate the
        // glyph slice in-place and never let a pointer escape the lock scope.
        if (text.len > 0 and text.len <= ShapedRunCache.MAX_TEXT_LEN) {
            const font_ptr = @intFromPtr(face);
            const cache_key = ShapedRunKey.init(text, font_ptr, face.metrics.point_size);

            self.shape_cache_mutex.lockUncancelable(self.io);
            defer self.shape_cache_mutex.unlock(self.io);

            if (self.shape_cache.get(cache_key)) |cached_run| {
                std.debug.assert(cached_run.width >= 0);
                return measureGlyphRun(cached_run.glyphs, text, cached_run.width, max_width, line_height);
            }
        }

        // Cache miss: full shape via CoreText/HarfBuzz, measure, free.
        // The shapeText call also populates the cache for next time.
        var run = try self.shapeText(text, variant, null);
        defer run.deinit(self.allocator);
        return measureGlyphRun(run.glyphs, text, run.width, max_width, line_height);
    }

    /// The glyph atlas. Its size, kind, and upload journal are fixed at init;
    /// placement state is guarded by `glyph_cache_mutex`.
    pub inline fn getAtlas(self: *const Self) *const Atlas {
        return self.cache.getAtlas();
    }

    /// Batch resolve glyphs under a single glyph_cache_mutex lock.
    /// Writes CachedGlyph results into `out_cached[0..glyphs.len]`.
    /// For glyphs with font_ref != null, uses the fallback font path;
    /// otherwise uses the face for `variant`, the one that shaped the run.
    ///
    /// This is the glyph-cache equivalent of `shapeTextInto`: same batch
    /// pattern, next layer down.  Eliminates N-1 lock/unlock pairs when
    /// rendering a text run of N glyphs.
    pub fn resolveGlyphBatch(
        self: *Self,
        glyphs: []const types.ShapedGlyph,
        variant: FontVariant,
        font_size: f32,
        subpixel_xs: []const u8,
        out_cached: []CachedGlyph,
    ) !void {
        std.debug.assert(glyphs.len > 0);
        std.debug.assert(glyphs.len == subpixel_xs.len);
        std.debug.assert(glyphs.len == out_cached.len);
        std.debug.assert(font_size > 0);
        std.debug.assert(font_size < 1000);

        if (!self.faces_loaded) return error.NoFontLoaded;
        // `GlyphKey` holds this face's address, so variants rasterize and cache
        // separately even for the same glyph id.
        const face = self.faceFor(variant).asFontFace();

        self.glyph_cache_mutex.lockUncancelable(self.io);
        defer self.glyph_cache_mutex.unlock(self.io);

        // Build the key's loop-invariant fields and read the frame clock once,
        // under the lock that keeps `scale_factor` stable; see
        // `GlyphCache.getOrRenderKey`.
        const key_base = cache_mod.GlyphKey.init(face, 0, font_size, self.cache.scale_factor, 0, 0);
        const frame = self.cache.frameCurrent();
        for (0..glyphs.len) |i| {
            if (glyphs[i].font_ref) |fallback_font| {
                out_cached[i] = try self.cache.getOrRenderFallback(fallback_font, glyphs[i].glyph_id, font_size, subpixel_xs[i], 0);
            } else {
                var key = key_base;
                key.glyph_id = glyphs[i].glyph_id;
                key.subpixel_x = subpixel_xs[i];
                out_cached[i] = try self.cache.getOrRenderKey(face, key, font_size, frame);
            }
        }
    }
};

// =============================================================================
// Standalone Helpers — extracted for hot-loop clarity (CLAUDE.md rule #20)
// =============================================================================

/// Compute text measurement (width, height, line_count) from a glyph slice.
/// Handles the no-wrap fast path (max_width null or total width fits) and the
/// word-wrapping slow path.  Takes only primitives and slices — no `self`,
/// no struct indirection — so the compiler can keep everything in registers.
fn measureGlyphRun(
    glyphs: []const types.ShapedGlyph,
    text: []const u8,
    total_width: f32,
    max_width: ?f32,
    line_height: f32,
) TextMeasurement {
    std.debug.assert(line_height > 0);
    std.debug.assert(total_width >= 0);

    // No-wrap fast path: text fits on a single line.
    if (max_width == null or total_width <= max_width.?) {
        return .{
            .width = total_width,
            .height = line_height,
            .line_count = 1,
        };
    }

    const limit = max_width.?;
    std.debug.assert(limit > 0);

    // Word-wrapping measurement.
    var current_width: f32 = 0;
    var max_line_width: f32 = 0;
    var line_count: u32 = 1;
    var word_width: f32 = 0;

    for (glyphs) |glyph| {
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
            if (current_width + word_width > limit and current_width > 0) {
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

    std.debug.assert(line_count >= 1);
    std.debug.assert(max_line_width >= 0);

    return .{
        .width = max_line_width,
        .height = line_height * @as(f32, @floatFromInt(line_count)),
        .line_count = line_count,
    };
}

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

test "cache keys differ by face, and faces stay resident side by side" {
    // Goal: the variant contract for every text cache. Each loaded face has its
    // own slot address, so the same string in regular and bold must key apart
    // in the shaped-run cache, the width cache, and the glyph cache, and
    // alternating between faces must not evict the other face's entries.
    // Methodology: same text and size, two face addresses, distinct payloads;
    // read both back after interleaved writes, then check `clear` drops both.
    const testing = std.testing;
    const regular_face: usize = 0x1000;
    const bold_face: usize = 0x2000;

    const regular_key = ShapedRunKey.init("Total", regular_face, 16.0);
    const bold_key = ShapedRunKey.init("Total", bold_face, 16.0);
    try testing.expect(!ShapedRunKey.eql(regular_key, bold_key));

    const glyph_regular = cache_mod.GlyphKey.initWithFontPtr(regular_face, 55, 16.0, 2.0, 0, 0);
    const glyph_bold = cache_mod.GlyphKey.initWithFontPtr(bold_face, 55, 16.0, 2.0, 0, 0);
    try testing.expect(!cache_mod.GlyphKey.eql(glyph_regular, glyph_bold));

    var shape_cache = ShapedRunCache.init();
    defer shape_cache.deinit();
    var regular_glyph = [_]ShapedGlyph{.{
        .glyph_id = 55,
        .x_offset = 0,
        .y_offset = 0,
        .x_advance = 9,
        .y_advance = 0,
        .cluster = 0,
    }};
    var bold_glyph = [_]ShapedGlyph{.{
        .glyph_id = 55,
        .x_offset = 0,
        .y_offset = 0,
        .x_advance = 11,
        .y_advance = 0,
        .cluster = 0,
    }};
    shape_cache.put(regular_key, .{ .glyphs = &regular_glyph, .width = 9, .owned = true });
    shape_cache.put(bold_key, .{ .glyphs = &bold_glyph, .width = 11, .owned = true });
    try testing.expectEqual(@as(f32, 9), shape_cache.get(regular_key).?.width);
    try testing.expectEqual(@as(f32, 11), shape_cache.get(bold_key).?.width);

    var measure_cache = MeasureCache.init();
    defer measure_cache.deinit();
    measure_cache.put(regular_key, 40);
    measure_cache.put(bold_key, 46);
    try testing.expectEqual(@as(f32, 40), measure_cache.get(regular_key).?);
    try testing.expectEqual(@as(f32, 46), measure_cache.get(bold_key).?);

    // A font reload reuses the face addresses, so it clears everything.
    shape_cache.clear();
    measure_cache.clear();
    try testing.expect(shape_cache.get(regular_key) == null);
    try testing.expect(shape_cache.get(bold_key) == null);
    try testing.expect(measure_cache.get(regular_key) == null);
    try testing.expect(measure_cache.get(bold_key) == null);
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

test "ShapedRunKey includes font size" {
    const testing = std.testing;

    const key1 = ShapedRunKey.init("Hello", 0x1234, 16.0);
    const key2 = ShapedRunKey.init("Hello", 0x1234, 24.0);
    const key3 = ShapedRunKey.init("Hello", 0x1234, 16.0);

    // Same text, same font, different size = different keys
    try testing.expect(!ShapedRunKey.eql(key1, key2));

    // Same text, same font, same size = equal keys
    try testing.expect(ShapedRunKey.eql(key1, key3));

    // size_fixed should reflect the size
    try testing.expectEqual(key1.size_fixed, key3.size_fixed);
    try testing.expect(key1.size_fixed != key2.size_fixed);

    // Verify size_fixed encoding (size * 64 for 26.6 fixed point)
    try testing.expectEqual(@as(u16, 16 * 64), key1.size_fixed);
    try testing.expectEqual(@as(u16, 24 * 64), key2.size_fixed);
}

test "ShapedRunKey size differentiation" {
    const testing = std.testing;

    // Different sizes should produce different keys even with same text
    const key_14 = ShapedRunKey.init("Test", 0x1234, 14.0);
    const key_16 = ShapedRunKey.init("Test", 0x1234, 16.0);
    const key_18 = ShapedRunKey.init("Test", 0x1234, 18.0);

    // Keys should not be equal due to different sizes
    try testing.expect(!ShapedRunKey.eql(key_14, key_16));
    try testing.expect(!ShapedRunKey.eql(key_16, key_18));
    try testing.expect(!ShapedRunKey.eql(key_14, key_18));

    // Text hash is the same (same text), but size_fixed differs
    try testing.expectEqual(key_14.text_hash, key_16.text_hash);
    try testing.expect(key_14.size_fixed != key_16.size_fixed);
    try testing.expect(key_16.size_fixed != key_18.size_fixed);
}

test "shapeTextInto warm path copies into caller buffer with owned=false" {
    // Goal: verify the core pattern that shapeTextInto's warm path uses —
    // get from cache, memcpy into a caller-provided buffer, return owned=false.
    // We test at the cache level since the full TextSystem needs a loaded font.
    const testing = std.testing;

    var cache = ShapedRunCache.init();
    defer cache.deinit();

    // Populate cache with a known 3-glyph run.
    var source_glyphs = [_]ShapedGlyph{
        .{ .glyph_id = 42, .x_offset = 1.0, .y_offset = 2.0, .x_advance = 8.5, .y_advance = 0, .cluster = 0 },
        .{ .glyph_id = 43, .x_offset = 0.5, .y_offset = 0, .x_advance = 7.0, .y_advance = 0, .cluster = 1 },
        .{ .glyph_id = 44, .x_offset = 0, .y_offset = -1.0, .x_advance = 9.0, .y_advance = 0, .cluster = 2 },
    };
    const source_run = ShapedRun{
        .glyphs = &source_glyphs,
        .width = 24.5,
        .owned = true,
    };

    const font_ptr: usize = 0x1000;
    const key = ShapedRunKey.init("abc", font_ptr, 14.0);
    cache.put(key, source_run);

    // Simulate shapeTextInto warm path: get from cache, copy into caller buffer.
    const cached_run = cache.get(key).?;

    var out_buffer: [ShapedRunCache.MAX_GLYPHS_PER_ENTRY]ShapedGlyph = undefined;
    const count = cached_run.glyphs.len;

    try testing.expect(count <= out_buffer.len);
    @memcpy(out_buffer[0..count], cached_run.glyphs);

    const result = ShapedRun{
        .glyphs = out_buffer[0..count],
        .width = cached_run.width,
        .owned = false,
    };

    // Verify: owned=false (no deinit needed), correct width and glyph count.
    try testing.expect(!result.owned);
    try testing.expectEqual(@as(usize, 3), result.glyphs.len);
    try testing.expectEqual(@as(f32, 24.5), result.width);

    // Verify glyph data was copied correctly.
    try testing.expectEqual(@as(u16, 42), result.glyphs[0].glyph_id);
    try testing.expectEqual(@as(f32, 8.5), result.glyphs[0].x_advance);
    try testing.expectEqual(@as(u16, 43), result.glyphs[1].glyph_id);
    try testing.expectEqual(@as(f32, 7.0), result.glyphs[1].x_advance);
    try testing.expectEqual(@as(u16, 44), result.glyphs[2].glyph_id);
    try testing.expectEqual(@as(f32, 9.0), result.glyphs[2].x_advance);

    // Verify buffer independence: invalidating the cache does not corrupt our copy.
    cache.clear();
    try testing.expectEqual(@as(u16, 42), result.glyphs[0].glyph_id);
    try testing.expectEqual(@as(f32, 24.5), result.width);
}

/// Fill `glyphs` and `text_buf` with a uniform run so cache tests can hit an
/// exact glyph count without needing a loaded font.
fn fillTestRun(glyphs: []ShapedGlyph, text_buf: []u8) ShapedRun {
    std.debug.assert(glyphs.len == text_buf.len);
    std.debug.assert(glyphs.len > 0);

    for (glyphs, 0..) |*glyph, index| {
        glyph.* = .{
            .glyph_id = @intCast(index),
            .x_offset = 0,
            .y_offset = 0,
            .x_advance = 10,
            .y_advance = 0,
            .cluster = @intCast(index),
        };
    }
    @memset(text_buf, 'a');

    return .{
        .glyphs = glyphs,
        .width = @as(f32, @floatFromInt(glyphs.len)) * 10,
        .owned = false,
    };
}

test "shape cache insert limit is MAX_GLYPHS_PER_ENTRY, not MAX_TEXT_LEN" {
    // Goal: pin the two different limits that govern the shape cache, because
    // they disagree.  `MAX_TEXT_LEN` (512) gates the *lookup* in
    // `TextSystem.measureText`, but `put` refuses any run over
    // `MAX_GLYPHS_PER_ENTRY` (128).  Text between the two never gets stored, so
    // it probes, misses, shapes, and is refused again — every frame, forever.
    // The miss is permanent rather than merely cold.
    //
    // This asymmetry is intentional and still holds: an entry embeds its glyph
    // array inline, so raising the insert limit to MAX_TEXT_LEN would blow the
    // 2MB comptime budget.  `MeasureCache` is what compensates -- it stores width
    // without glyphs, so `measureText` does not pay for this refusal.  The test
    // pins the refusal itself so that compensation stays necessary and visible.
    //
    // Methodology: drive the cache at exactly the limit and one past it, using
    // text short enough that the lookup gate would happily admit both.
    const testing = std.testing;

    var cache = ShapedRunCache.init();
    defer cache.deinit();

    const at_limit = ShapedRunCache.MAX_GLYPHS_PER_ENTRY;
    const over_limit = ShapedRunCache.MAX_GLYPHS_PER_ENTRY + 1;

    // Both lengths sit under the lookup gate, so any difference in behaviour
    // below comes from the insert limit alone.
    try testing.expect(over_limit <= ShapedRunCache.MAX_TEXT_LEN);

    // Control: a run exactly at the limit round-trips.
    var glyphs_at: [at_limit]ShapedGlyph = undefined;
    var text_at: [at_limit]u8 = undefined;
    const run_at = fillTestRun(&glyphs_at, &text_at);
    const key_at = ShapedRunKey.init(&text_at, 0x1000, 16.0);

    cache.put(key_at, run_at);
    try testing.expect(cache.get(key_at) != null);
    try testing.expectEqual(@as(u32, 1), cache.entry_count);

    // One glyph more, and the insert is silently dropped.
    var glyphs_over: [over_limit]ShapedGlyph = undefined;
    var text_over: [over_limit]u8 = undefined;
    const run_over = fillTestRun(&glyphs_over, &text_over);
    const key_over = ShapedRunKey.init(&text_over, 0x1000, 16.0);

    cache.put(key_over, run_over);
    try testing.expect(cache.get(key_over) == null);
    try testing.expectEqual(@as(u32, 1), cache.entry_count); // unchanged

    // Repeating the shape-then-store cycle never converges.  Each iteration
    // stands in for one frame re-shaping the same unchanged string.
    var frame: u32 = 0;
    while (frame < 8) : (frame += 1) {
        cache.put(key_over, run_over);
        try testing.expect(cache.get(key_over) == null);
    }
    try testing.expectEqual(@as(u32, 1), cache.entry_count);
}

// =============================================================================
// MeasureCache Tests
// =============================================================================

/// Fill `buf` with deterministic ASCII derived from `seed`, so each seed yields
/// a distinct string. Keeps the cache tests free of any font or platform state.
///
/// The seed is written as little-endian base-26 with 'a' as the zero digit, which
/// makes the mapping injective. A tempting `'a' + (seed + index) % 26` is not: it
/// is periodic in 26, so seeds 26 apart produce byte-identical text and therefore
/// identical cache keys, which silently turns a correctness test into a tautology.
fn fillTestText(buf: []u8, seed: u32) void {
    std.debug.assert(buf.len > 0);
    std.debug.assert(buf.len <= ShapedRunCache.MAX_TEXT_LEN);

    @memset(buf, 'a');

    var remaining = seed;
    var index: usize = 0;
    while (index < buf.len) : (index += 1) {
        buf[index] = 'a' + @as(u8, @intCast(remaining % 26));
        remaining /= 26;
        if (remaining == 0) break;
    }

    // The seed must fit, or distinct seeds could alias.
    std.debug.assert(remaining == 0);
}

test "MeasureCache stores widths the shape cache refuses" {
    // Goal: the entire purpose of MeasureCache is covering the band between
    // MAX_GLYPHS_PER_ENTRY and MAX_TEXT_LEN, where `ShapedRunCache.put` bails
    // out. Verify a round-trip at the first refused length and across the band.
    const testing = std.testing;

    var cache = MeasureCache.init();
    defer cache.deinit();

    const font_ptr: usize = 0x2000;

    const lengths = [_]usize{
        ShapedRunCache.MAX_GLYPHS_PER_ENTRY + 1, // 129: first refused length
        300,
        ShapedRunCache.MAX_TEXT_LEN - 1, // 511
        ShapedRunCache.MAX_TEXT_LEN, // 512: the lookup gate itself
    };

    var buf: [ShapedRunCache.MAX_TEXT_LEN]u8 = undefined;

    for (lengths, 0..) |len, index| {
        const text = buf[0..len];
        fillTestText(text, @intCast(index));

        // Precisely the lengths the shaped-run cache turns away.
        try testing.expect(len > ShapedRunCache.MAX_GLYPHS_PER_ENTRY);
        try testing.expect(len <= ShapedRunCache.MAX_TEXT_LEN);

        const key = ShapedRunKey.init(text, font_ptr, 16.0);
        const width: f32 = @floatFromInt(len);

        try testing.expect(cache.get(key) == null); // Cold.
        cache.put(key, width);
        try testing.expectEqual(width, cache.get(key).?);
    }
}

test "MeasureCache converges after a single miss for over-limit text" {
    // Goal: prove `MeasureCache` covers that band.  The shape-cache test above runs
    // the same put-then-get cycle and never converges; here the second frame
    // onward must hit.  Methodology: replay 8 frames of an unchanged string and
    // count how many of them would have had to shape.
    const testing = std.testing;

    var cache = MeasureCache.init();
    defer cache.deinit();

    const font_ptr: usize = 0x3000;

    var buf: [ShapedRunCache.MAX_GLYPHS_PER_ENTRY + 1]u8 = undefined;
    fillTestText(&buf, 7);

    const key = ShapedRunKey.init(&buf, font_ptr, 16.0);
    const width: f32 = 1234.5;

    var shape_count: u32 = 0;
    var frame: u32 = 0;
    while (frame < 8) : (frame += 1) {
        if (cache.get(key)) |cached_width| {
            try testing.expectEqual(width, cached_width);
        } else {
            // Stands in for a full CoreText shape.
            shape_count += 1;
            cache.put(key, width);
        }
    }

    try testing.expectEqual(@as(u32, 1), shape_count);
}

test "MeasureCache keys distinguish font size" {
    // Goal: the same string at two sizes has two different widths. Guard against
    // a key that hashes text but forgets the size.
    const testing = std.testing;

    var cache = MeasureCache.init();
    defer cache.deinit();

    const font_ptr: usize = 0x5555;

    var buf: [200]u8 = undefined;
    fillTestText(&buf, 3);

    const key_16 = ShapedRunKey.init(&buf, font_ptr, 16.0);
    const key_24 = ShapedRunKey.init(&buf, font_ptr, 24.0);

    cache.put(key_16, 160.0);
    cache.put(key_24, 240.0);

    try testing.expectEqual(@as(f32, 160.0), cache.get(key_16).?);
    try testing.expectEqual(@as(f32, 240.0), cache.get(key_24).?);
}

test "MeasureCache never returns a stale width under eviction pressure" {
    // Goal: eviction is the riskiest part of a set-associative cache -- a slot
    // whose key and payload fall out of sync silently returns a wrong width,
    // which would corrupt layout rather than merely slow it down.  Methodology:
    // overflow the cache several times over, then verify that every key which
    // still hits carries exactly the width it was stored with.
    const testing = std.testing;

    var cache = MeasureCache.init();
    defer cache.deinit();

    const font_ptr: usize = 0x4000;

    const insert_count: u32 = @intCast(MeasureCache.SLOT_COUNT * 4);
    var buf: [200]u8 = undefined;

    var seed: u32 = 0;
    while (seed < insert_count) : (seed += 1) {
        fillTestText(&buf, seed);
        const key = ShapedRunKey.init(&buf, font_ptr, 16.0);
        cache.put(key, @floatFromInt(seed));
    }

    var hits: u32 = 0;
    seed = 0;
    while (seed < insert_count) : (seed += 1) {
        fillTestText(&buf, seed);
        const key = ShapedRunKey.init(&buf, font_ptr, 16.0);

        if (cache.get(key)) |cached_width| {
            try testing.expectEqual(@as(f32, @floatFromInt(seed)), cached_width);
            hits += 1;
        }
    }

    // Some entries must survive, and the cache cannot hold more than it has
    // slots -- the latter guards against the probe window silently growing.
    try testing.expect(hits > 0);
    try testing.expect(hits <= MeasureCache.SLOT_COUNT);

    // The most recent insert is always resident.
    fillTestText(&buf, insert_count - 1);
    const newest = ShapedRunKey.init(&buf, font_ptr, 16.0);
    try testing.expectEqual(@as(f32, @floatFromInt(insert_count - 1)), cache.get(newest).?);
}

test "glyph cache re-renders a glyph whose atlas shelf was evicted" {
    // Goal: a cached glyph never points at evicted pixels. Methodology: a 64²
    // CPU atlas holds only a few 40 px glyphs. Render 'A' and save its pixels,
    // then render one other glyph per frame until far more than the atlas
    // holds have passed, so LRU eviction must have reclaimed 'A's shelf.
    // Asking for 'A' again must return a region holding 'A's own pixels, not
    // the pixels of whichever glyph took its place.
    const testing = std.testing;
    var uploads: atlas_mod.AtlasUploads = undefined;
    try uploads.init(testing.allocator, testing.io, .{
        .storage = .cpu_texture,
        .upload_bytes_frame_max = 64,
    });
    defer uploads.deinit();
    const consumer: usize = 1;
    uploads.registerConsumer(consumer);
    defer uploads.unregisterConsumer(consumer);

    const text_system = try testing.allocator.create(TextSystem);
    defer testing.allocator.destroy(text_system);
    try text_system.initInPlace(testing.allocator, 1.0, testing.io, &FontLimits.standard, .{
        .size = 64,
        .uploads = &uploads,
    });
    defer text_system.deinit();
    try text_system.loadSystemFont(.sans_serif, 40);

    const letters = "ABCDEFGHKMNOPQRSUVWXYZ";
    var run = try text_system.shapeText(letters, .regular, null);
    defer run.deinit(testing.allocator);
    try testing.expectEqual(letters.len, run.glyphs.len);

    const atlas = text_system.getAtlas();
    var saved: [64 * 64]u8 = undefined;
    _ = uploads.beginFrame(consumer);
    const first = try text_system.getGlyphSubpixel(run.glyphs[0].glyph_id, 40, 0, 0);
    try testing.expect(first.region.width > 8);
    const saved_len = copyRegion(atlas, first.region, &saved);

    for (run.glyphs[1..]) |glyph| {
        _ = uploads.beginFrame(consumer);
        _ = uploads.consumeBegin(consumer);
        uploads.consumeEnd(consumer);
        _ = try text_system.getGlyphSubpixel(glyph.glyph_id, 40, 0, 0);
    }
    // Twenty-one glyphs of about 30² with borders do not fit four times over in
    // 64²; the atlas must have evicted and reused space, including 'A's.
    try testing.expect(atlas.rows_active <= 64);

    _ = uploads.beginFrame(consumer);
    const again = try text_system.getGlyphSubpixel(run.glyphs[0].glyph_id, 40, 0, 0);
    var current: [64 * 64]u8 = undefined;
    const current_len = copyRegion(atlas, again.region, &current);
    try testing.expectEqual(first.region.width, again.region.width);
    try testing.expectEqual(first.region.height, again.region.height);
    try testing.expectEqualSlices(u8, saved[0..saved_len], current[0..current_len]);
}

/// Copy a region of a CPU grayscale atlas into `out`, row by row (test helper).
fn copyRegion(atlas: *const Atlas, region: atlas_mod.Region, out: []u8) usize {
    std.debug.assert(atlas.format == .grayscale);
    const data = atlas.getData();
    var row: usize = 0;
    while (row < region.height) : (row += 1) {
        const source = (@as(usize, region.y) + row) * atlas.size + region.x;
        @memcpy(out[row * region.width ..][0..region.width], data[source..][0..region.width]);
    }
    return @as(usize, region.width) * region.height;
}
