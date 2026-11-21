const std = @import("std");
const builtin = @import("builtin");

const types = @import("types.zig");
const font_face_mod = @import("font_face.zig");
const cache_mod = @import("cache.zig");
const platform = @import("../platform/mod.zig");
const render_stats = @import("../core/render_stats.zig");
const RenderStats = render_stats.RenderStats;

const atlas_mod = @import("atlas.zig");
const Atlas = atlas_mod.Atlas;
const limits_mod = @import("../core/limits.zig");
const reservation = @import("../core/reservation.zig");

const assert = std.debug.assert;

/// Content hash key, not a pointer key like `GlyphKey`.
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

    fn extractPrefix(text: []const u8) [PREFIX_LEN]u8 {
        var prefix: [PREFIX_LEN]u8 = @splat(0);
        const copy_len = @min(text.len, PREFIX_LEN);
        @memcpy(prefix[0..copy_len], text[0..copy_len]);
        return prefix;
    }

    fn extractSuffix(text: []const u8) [SUFFIX_LEN]u8 {
        var suffix: [SUFFIX_LEN]u8 = @splat(0);
        const copy_len = @min(text.len, SUFFIX_LEN);
        const start = text.len - copy_len;
        @memcpy(suffix[0..copy_len], text[start..]);
        return suffix;
    }

    pub fn init(text: []const u8, font_ptr: usize, font_size: f32) Self {
        std.debug.assert(font_size > 0);
        std.debug.assert(font_size < 1000);

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

const CacheEntry = struct {
    key: ShapedRunKey,
    glyphs: [ShapedRunCache.MAX_GLYPHS_PER_ENTRY]ShapedGlyph,
    glyph_count: u16,
    width: f32,
    /// LRU tracking - higher = more recently used
    last_access: u32,
    valid: bool,

    const Self = @This();

    fn clear(self: *Self) void {
        self.valid = false;
        self.glyph_count = 0;
        self.last_access = 0;
    }
};

/// Cache for shaped text runs, reserved at init from
/// `ResourceLimits.text.shaped_run_count_max` and never grown.
/// A hash table with open addressing finds an entry in O(1) on average; a full
/// cache evicts the least recently used entry, so a miss costs shaping time,
/// never correctness.
///
/// Zero is "empty": hash slots hold an entry index plus one, and entry slots
/// are claimed in order up to `entry_high_water`, so fresh pages are an empty
/// cache. Memory at `standard` (256 runs): entries 256 × 4,152 B and 512 hash
/// slots × 2 B, 1.0 MiB of virtual memory, resident as runs are cached.
pub const ShapedRunCache = struct {
    /// Entry slots; those at or past `entry_high_water` were never written.
    entries: []CacheEntry,
    /// Hash slot -> entry index + 1, or `slot_empty`; a power of two, at least
    /// twice the entries.
    hash_table: []u16,
    entry_count: u32,
    /// Entry slots claimed so far; `deinit` zeroes this prefix.
    entry_high_water: u32,
    /// Whether any hash slot was written, for `deinit`'s zeroing.
    hash_written: bool,
    access_counter: u32,

    const Self = @This();

    // Which runs are cacheable at all; longer ones are shaped uncached.
    pub const MAX_GLYPHS_PER_ENTRY: usize = 128;
    pub const MAX_TEXT_LEN: usize = 512;

    const slot_empty: u16 = 0;

    comptime {
        std.debug.assert(@sizeOf(ShapedGlyph) <= 48);
        // Entry indexes plus one fit a `u16` at the ceiling.
        std.debug.assert(limits_mod.TextLimits.ceiling.shaped_run_count_max < std.math.maxInt(u16));
    }

    /// Reserve `entry_count_max` entries (`text.shaped_run_count_max`) and
    /// twice as many hash slots, rounded up to a power of two.
    pub fn init(entry_count_max: u32) error{OutOfMemory}!Self {
        assert(entry_count_max > 0);
        assert(entry_count_max <= limits_mod.TextLimits.ceiling.shaped_run_count_max);
        const slot_count = std.math.ceilPowerOfTwoAssert(u32, 2 * entry_count_max);

        const entries = try reservation.reserve(CacheEntry, entry_count_max);
        errdefer reservation.release(CacheEntry, entries, 0);

        const hash_table = try reservation.reserveZeroed(u16, slot_count);
        const self: Self = .{
            .entries = entries,
            .hash_table = hash_table,
            .entry_count = 0,
            .entry_high_water = 0,
            .hash_written = false,
            .access_counter = 0,
        };
        assert(self.hash_table.len >= 2 * self.entries.len);
        return self;
    }

    /// Zero what was written before the pages go back.
    pub fn deinit(self: *Self) void {
        assert(self.entry_count <= self.entry_high_water);
        const hash_used = if (self.hash_written) self.hash_table.len else 0;
        reservation.release(u16, self.hash_table, hash_used);
        reservation.release(CacheEntry, self.entries, self.entry_high_water);
        self.* = undefined;
    }

    pub fn get(self: *Self, key: ShapedRunKey) ?ShapedRun {
        std.debug.assert(key.text_len > 0);
        std.debug.assert(key.text_len <= MAX_TEXT_LEN);

        const index = self.findEntryIndex(key) orelse return null;
        const entry = &self.entries[index];
        self.access_counter += 1;
        entry.last_access = self.access_counter;

        std.debug.assert(entry.glyph_count <= MAX_GLYPHS_PER_ENTRY);
        std.debug.assert(entry.width >= 0);

        return ShapedRun{
            .glyphs = entry.glyphs[0..entry.glyph_count],
            .width = entry.width,
            .owned = false,
        };
    }

    pub fn put(self: *Self, key: ShapedRunKey, run: ShapedRun) void {
        std.debug.assert(key.text_len > 0);
        std.debug.assert(run.width >= 0);

        if (run.glyphs.len > MAX_GLYPHS_PER_ENTRY) {
            return;
        }

        // Not cached: `font_ref` lifetime is not tracked by the cache.
        for (run.glyphs) |g| {
            if (g.font_ref != null) {
                return;
            }
        }

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

        const target_idx = self.claimSlot();
        const slot = &self.entries[target_idx];

        if (slot.valid) {
            std.debug.assert(self.entry_count > 0);
            self.removeFromHashTable(slot.key, target_idx);
            self.entry_count -= 1;
        }

        const glyph_count: u16 = @intCast(run.glyphs.len);
        @memcpy(slot.glyphs[0..glyph_count], run.glyphs);

        slot.key = key;
        slot.glyph_count = glyph_count;
        slot.width = run.width;
        self.access_counter += 1;
        slot.last_access = self.access_counter;
        slot.valid = true;

        self.entry_count += 1;

        self.insertIntoHashTable(key, @intCast(target_idx));

        std.debug.assert(self.entry_count <= self.entries.len);
        std.debug.assert(slot.valid);
    }

    /// The slot a new run goes in: the next never-used slot, else the first
    /// invalid one, else the least recently used. One scan of the claimed
    /// slots, at most `shaped_run_count_max`, only when every slot was used.
    fn claimSlot(self: *Self) usize {
        if (self.entry_high_water < self.entries.len) {
            const index = self.entry_high_water;
            self.entry_high_water += 1;
            self.entries[index].valid = false;
            return index;
        }
        var target_idx: usize = 0;
        var oldest_access: u32 = std.math.maxInt(u32);
        for (self.entries, 0..) |*entry, idx| {
            if (!entry.valid) return idx;
            if (entry.last_access < oldest_access) {
                oldest_access = entry.last_access;
                target_idx = idx;
            }
        }
        assert(self.entry_count == self.entries.len);
        return target_idx;
    }

    /// The table and
    /// entries are loaded once, so the probe loop reloads neither.
    fn findEntryIndex(self: *const Self, key: ShapedRunKey) ?usize {
        const hash_table = self.hash_table;
        const entries = self.entries;
        const mask = hash_table.len - 1;
        var probe: usize = @as(usize, @truncate(key.text_hash)) & mask;

        for (0..hash_table.len) |_| {
            const stored = hash_table[probe];
            if (stored == slot_empty) return null;

            const entry_idx = stored - 1;
            std.debug.assert(entry_idx < entries.len);
            const entry = &entries[entry_idx];
            if (entry.valid and ShapedRunKey.eql(entry.key, key)) return entry_idx;

            probe = (probe + 1) & mask;
        }

        return null;
    }

    /// Insert entry into hash table using linear probing. At most half the
    /// slots are occupied, so a free one is always found.
    fn insertIntoHashTable(self: *Self, key: ShapedRunKey, entry_idx: u16) void {
        std.debug.assert(entry_idx < self.entry_high_water);

        const mask = self.hash_table.len - 1;
        var probe: usize = @as(usize, @truncate(key.text_hash)) & mask;
        self.hash_written = true;

        for (0..self.hash_table.len) |_| {
            if (self.hash_table[probe] == slot_empty) {
                self.hash_table[probe] = entry_idx + 1;
                return;
            }
            probe = (probe + 1) & mask;
        }
        unreachable;
    }

    /// Tombstone-free deletion: rehashes the entries after the removed slot.
    fn removeFromHashTable(self: *Self, key: ShapedRunKey, entry_idx: usize) void {
        const mask = self.hash_table.len - 1;
        var probe: usize = @as(usize, @truncate(key.text_hash)) & mask;
        const stored: u16 = @intCast(entry_idx + 1);

        for (0..self.hash_table.len) |_| {
            if (self.hash_table[probe] == slot_empty) {
                return; // Entry not in hash table
            }

            if (self.hash_table[probe] == stored) {
                self.hash_table[probe] = slot_empty;
                self.rehashAfterRemoval(probe);
                return;
            }

            probe = (probe + 1) & mask;
        }
    }

    fn rehashAfterRemoval(self: *Self, removed_slot: usize) void {
        const mask = self.hash_table.len - 1;
        var slot = (removed_slot + 1) & mask;

        for (0..self.hash_table.len) |_| {
            const stored = self.hash_table[slot];
            if (stored == slot_empty) {
                return; // Done - hit empty slot
            }

            const entry_idx = stored - 1;
            const entry = &self.entries[entry_idx];
            if (!entry.valid) {
                slot = (slot + 1) & mask;
                continue;
            }

            const natural_slot = @as(usize, @truncate(entry.key.text_hash)) & mask;

            // The natural slot falls in the removed slot's gap, wrapping around.
            const needs_rehash = if (removed_slot < slot)
                (natural_slot <= removed_slot or natural_slot > slot)
            else
                (natural_slot <= removed_slot and natural_slot > slot);

            if (needs_rehash) {
                self.hash_table[slot] = slot_empty;
                self.insertIntoHashTable(entry.key, entry_idx);
            }

            slot = (slot + 1) & mask;
        }
    }

    /// Drop every entry. Keys hold the face address, and `TextSystem` reloads
    /// faces into the same slots, so a font change must clear explicitly.
    /// Entries for different faces coexist; nothing clears on a face switch.
    pub fn clear(self: *Self) void {
        for (self.entries[0..self.entry_high_water]) |*entry| {
            entry.clear();
        }
        if (self.hash_written) @memset(self.hash_table, slot_empty);

        self.entry_count = 0;
        // Don't reset access_counter to preserve LRU ordering after clear

        std.debug.assert(self.entry_count == 0);
    }
};

const MeasureEntry = struct {
    key: ShapedRunKey,
    width: f32,
    /// LRU tracking - higher = more recently used
    last_access: u32,
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
/// `ShapedRunCache` refuses runs longer than `MAX_GLYPHS_PER_ENTRY` (128):
/// each entry embeds its glyph array inline, so raising the limit to
/// `MAX_TEXT_LEN` would multiply the cache fourfold. `measureText` only
/// reads the scalar width, so storing just that (~56 B per entry) covers the
/// whole 512-byte range; without this, every string of 129..512 bytes is a
/// permanent miss that shapes again every frame.
///
/// Set-associative rather than index-plus-hash-table: entries are small
/// enough to live directly in the probe window, so a bounded linear probe
/// with LRU eviction needs no separate table, tombstones, or rehash.
pub const MeasureCache = struct {
    /// Slots indexed directly by hash, `text.measure_slot_count_max` of them
    /// (a power of two). Zero is an empty slot, so fresh pages are an empty
    /// cache. Memory at `standard` (2,048 slots × 56 B): 112 KiB of virtual
    /// memory, resident as widths are cached.
    slots: []MeasureEntry,
    /// Whether any slot was written, for `deinit`'s zeroing.
    written: bool,
    access_counter: u32,

    const Self = @This();

    /// Associativity: how far a key may probe from its natural slot before the
    /// least-recently-used slot in that window is evicted. Bounds worst-case
    /// lookup to a fixed number of comparisons.
    pub const MAX_PROBE_LENGTH: usize = limits_mod.measure_probe_count;

    /// Reserve `slot_count` slots (`text.measure_slot_count_max`).
    pub fn init(slot_count: u32) error{OutOfMemory}!Self {
        // Power of two keeps the modulo a mask; the budget's check holds both.
        assert(std.math.isPowerOfTwo(slot_count));
        assert(slot_count > MAX_PROBE_LENGTH);
        const self: Self = .{
            .slots = try reservation.reserveZeroed(MeasureEntry, slot_count),
            .written = false,
            .access_counter = 0,
        };
        assert(!self.slots[0].valid);
        return self;
    }

    /// Zero the slots if any were written, then release them.
    pub fn deinit(self: *Self) void {
        const used = if (self.written) self.slots.len else 0;
        reservation.release(MeasureEntry, self.slots, used);
        self.* = undefined;
    }

    pub fn get(self: *Self, key: ShapedRunKey) ?f32 {
        std.debug.assert(key.text_len > 0);
        std.debug.assert(key.text_len <= ShapedRunCache.MAX_TEXT_LEN);

        const slots = self.slots;
        const mask = slots.len - 1;
        const start_slot = @as(usize, @truncate(key.text_hash)) & mask;

        for (0..MAX_PROBE_LENGTH) |offset| {
            const slot = &slots[(start_slot + offset) & mask];

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

        const slots = self.slots;
        const mask = slots.len - 1;
        const start_slot = @as(usize, @truncate(key.text_hash)) & mask;

        var victim_index: usize = start_slot;
        var oldest_access: u32 = std.math.maxInt(u32);

        for (0..MAX_PROBE_LENGTH) |offset| {
            const index = (start_slot + offset) & mask;
            const slot = &slots[index];

            if (slot.valid) {
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

        const victim = &slots[victim_index];
        victim.key = key;
        victim.width = width;
        victim.valid = true;
        self.written = true;
        self.access_counter += 1;
        victim.last_access = self.access_counter;

        std.debug.assert(victim.valid);
        std.debug.assert(victim.width == width);
    }

    /// Drop every width. Widths are only meaningful for the face that produced
    /// them; keys carry the face address, so faces coexist and only a font
    /// reload, which reuses those addresses, clears.
    pub fn clear(self: *Self) void {
        if (self.written) {
            for (self.slots) |*slot| slot.clear();
        }
        // Don't reset access_counter, to preserve LRU ordering after clear.

        std.debug.assert(!self.slots[0].valid);
        std.debug.assert(!self.slots[self.slots.len - 1].valid);
    }
};

/// One text measured as layout sizes it: its bytes' hash and length, the
/// layout style packed into `style`, and the wrap width's bits. A 64-bit hash
/// of the bytes stands for them, as it does for shaped runs.
pub const TextSizeKey = struct {
    text_hash: u64,
    text_len: u32,
    max_width_bits: u32,
    style: u64,

    pub fn eql(a: TextSizeKey, b: TextSizeKey) bool {
        return a.text_hash == b.text_hash and a.text_len == b.text_len and
            a.max_width_bits == b.max_width_bits and a.style == b.style;
    }
};

const TextSizeEntry = struct {
    key: TextSizeKey,
    width: f32,
    height: f32,
    last_access: u32,
    valid: bool,
};

/// Sizes of whole wrapped texts, so `cx.measureText` wraps a text once per
/// style and width rather than every frame: a `List` sums every row's height
/// each render. Set-associative with LRU eviction in a window of
/// `measure_probe_count` slots, like `MeasureCache`, so a lookup costs one
/// hash of the text and at most eight compares, and a miss costs one wrap.
/// Memory at `standard` (4,096 slots × 40 B): 160 KiB of fresh pages,
/// resident as texts are measured.
pub const TextSizeCache = struct {
    /// `text.text_size_slot_count_max` slots, a power of two; zero is empty.
    slots: []TextSizeEntry,
    written: bool,
    access_counter: u32,

    const Self = @This();
    const probe_count: usize = limits_mod.measure_probe_count;

    comptime {
        assert(@sizeOf(TextSizeEntry) == 40);
    }

    pub fn init(slot_count: u32) error{OutOfMemory}!Self {
        assert(std.math.isPowerOfTwo(slot_count));
        assert(slot_count > probe_count);
        const self: Self = .{
            .slots = try reservation.reserveZeroed(TextSizeEntry, slot_count),
            .written = false,
            .access_counter = 0,
        };
        assert(!self.slots[0].valid);
        return self;
    }

    /// Zero the slots if any were written, then release them.
    pub fn deinit(self: *Self) void {
        const used = if (self.written) self.slots.len else 0;
        reservation.release(TextSizeEntry, self.slots, used);
        self.* = undefined;
    }

    /// The cached width and height, or null; a hit becomes most recent.
    pub fn get(self: *Self, key: TextSizeKey) ?[2]f32 {
        const mask = self.slots.len - 1;
        const start_slot = @as(usize, @truncate(key.text_hash)) & mask;
        for (0..probe_count) |offset| {
            const slot = &self.slots[(start_slot + offset) & mask];
            // `put` fills the first empty slot, so an empty one ends the key.
            if (!slot.valid) return null;
            if (TextSizeKey.eql(slot.key, key)) {
                self.access_counter += 1;
                slot.last_access = self.access_counter;
                assert(slot.width >= 0);
                assert(slot.height >= 0);
                return .{ slot.width, slot.height };
            }
        }
        return null;
    }

    /// Store a size in the first empty slot of the key's window, else over
    /// that window's least recently used.
    pub fn put(self: *Self, key: TextSizeKey, width: f32, height: f32) void {
        assert(width >= 0);
        assert(height >= 0);
        const mask = self.slots.len - 1;
        const start_slot = @as(usize, @truncate(key.text_hash)) & mask;
        var victim_index: usize = start_slot;
        var oldest_access: u32 = std.math.maxInt(u32);
        for (0..probe_count) |offset| {
            const index = (start_slot + offset) & mask;
            const slot = &self.slots[index];
            if (!slot.valid or TextSizeKey.eql(slot.key, key)) {
                victim_index = index;
                break;
            }
            if (slot.last_access < oldest_access) {
                oldest_access = slot.last_access;
                victim_index = index;
            }
        }
        self.access_counter += 1;
        self.slots[victim_index] = .{
            .key = key,
            .width = width,
            .height = height,
            .last_access = self.access_counter,
            .valid = true,
        };
        self.written = true;
        assert(self.slots[victim_index].valid);
    }

    /// Drop every size, for a font reload (`TextSystem.clearCaches`).
    pub fn clear(self: *Self) void {
        if (self.written) {
            for (self.slots) |*slot| slot.valid = false;
        }
        assert(!self.slots[0].valid);
        assert(!self.slots[self.slots.len - 1].valid);
    }
};

const is_wasm = platform.is_wasm;
const is_linux = platform.is_linux;
const is_windows = platform.is_windows;

/// `text_backend = .synthetic` replaces the platform's fonts with derived
/// metrics on every target, so headless goldens match across hosts.
pub const is_synthetic = @import("gooey_build_options").text_backend == .synthetic;

const backend = if (is_synthetic)
    @import("backends/synthetic/mod.zig")
else if (is_wasm)
    @import("backends/web/mod.zig")
else if (is_linux)
    @import("backends/freetype/mod.zig")
else if (is_windows)
    @import("backends/directwrite/mod.zig")
else
    @import("backends/coretext/mod.zig");

const PlatformFace = if (is_synthetic)
    backend.SyntheticFace
else if (is_wasm)
    backend.WebFontFace
else if (is_linux)
    backend.FreeTypeFace
else if (is_windows)
    backend.DirectWriteFace
else
    backend.CoreTextFace;

const PlatformShaper = if (is_synthetic)
    backend.SyntheticShaper
else if (is_wasm)
    backend.WebShaper
else if (is_linux)
    backend.HarfBuzzShaper
else if (is_windows)
    backend.DirectWriteShaper
else
    backend.CoreTextShaper;

/// The most codepoints one shaped run may hold, on every backend; documented
/// with the budget it bounds in `core/limits.zig`.
pub const run_codepoint_count_max = @import("../core/limits.zig").run_codepoint_count_max;

pub const FontFace = font_face_mod.FontFace;
pub const Metrics = types.Metrics;
pub const GlyphMetrics = types.GlyphMetrics;
pub const ShapedGlyph = types.ShapedGlyph;
pub const ShapedRun = types.ShapedRun;
pub const TextMeasurement = types.TextMeasurement;
pub const SystemFont = types.SystemFont;
pub const FontVariant = types.FontVariant;
pub const FontFamily = types.FontFamily;
pub const FontLimits = @import("../core/limits.zig").FontLimits;
pub const TextLimits = @import("../core/limits.zig").TextLimits;
pub const CachedGlyph = cache_mod.CachedGlyph;
pub const AtlasOptions = cache_mod.AtlasOptions;
pub const SUBPIXEL_VARIANTS_X = types.SUBPIXEL_VARIANTS_X;

pub const TextSystem = struct {
    allocator: std.mem.Allocator,
    /// Owns every `ShapedRun` a shape miss returns; callers free runs with it.
    /// It is `allocator` unless a caller with reserved scratch storage sets it
    /// (`useRunAllocator`), so a shape miss after initialization claims that
    /// storage instead of the heap.
    run_allocator: std.mem.Allocator,
    cache: cache_mod.GlyphCache,
    /// One face per variant in `FontLimits.variants` (the app family), then
    /// one per `FontLimits.mono_variants` (the second family), allocated at
    /// init and reloaded in place by `loadFont`. Slot addresses never change,
    /// so `@intFromPtr(&faces[slot])` is a stable per-face cache key.
    faces: []PlatformFace,
    /// Slots `0..app_face_count` hold the app family; the rest hold mono.
    app_face_count: u8,
    /// The variant each slot holds, in `FontLimits` order.
    face_variants: [face_slot_count_max]FontVariant,
    /// Slot of each family's variant, or `face_slot_none` when its set omits it.
    face_slot_by_variant: [FontFamily.count][FontVariant.count]u8,
    /// True once every app-family slot holds a loaded face.
    faces_loaded: bool,
    /// True once every mono-family slot holds a loaded face (`loadMonoFont`).
    mono_loaded: bool,
    /// Where the loaded set came from; meaningful only while `faces_loaded`.
    loaded_source: LoadedSource,
    /// Complex shaper (native only, void on web)
    shaper: ?PlatformShaper,
    scale_factor: f32,
    shape_cache: ShapedRunCache,
    /// Covers the full `MAX_TEXT_LEN` range `shape_cache` cannot; see
    /// `MeasureCache`.
    measure_cache: MeasureCache,
    /// Wrapped text sizes for `cx.measureText` (see `TextSizeCache`).
    text_size_cache: TextSizeCache,
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
    const face_slot_count_max: u8 = FontFamily.count * FontVariant.count;

    comptime {
        std.debug.assert(face_slot_count_max < face_slot_none);
    }

    /// Initialize TextSystem in-place from the app's `ResourceLimits.text`:
    /// one face slot per `fonts.variants` entry, which `loadFont` or
    /// `loadSystemFont` fills before the first frame, and the glyph,
    /// shaped-run and width caches at their budgeted sizes.
    /// Marked noinline to prevent stack accumulation in WASM builds.
    pub noinline fn initInPlace(
        self: *Self,
        allocator: std.mem.Allocator,
        scale: f32,
        io: std.Io,
        text_limits: *const TextLimits,
        atlas_options: cache_mod.AtlasOptions,
    ) !void {
        std.debug.assert(scale > 0);
        std.debug.assert(scale <= 4.0);
        std.debug.assert(text_limits.check() == null); // The app's budget checked it.
        const font_limits = &text_limits.fonts;

        const app_count = font_limits.variants.len;
        const face_count = app_count + font_limits.mono_variants.len;
        self.faces = try allocator.alloc(PlatformFace, face_count);
        errdefer allocator.free(self.faces);

        self.app_face_count = @intCast(app_count);
        self.face_variants = @splat(.regular);
        self.face_slot_by_variant = @splat(@splat(face_slot_none));
        for (font_limits.variants, 0..) |variant, slot| {
            self.face_variants[slot] = variant;
            self.face_slot_by_variant[0][@backingInt(variant)] = @intCast(slot);
        }
        for (font_limits.mono_variants, app_count..) |variant, slot| {
            self.face_variants[slot] = variant;
            self.face_slot_by_variant[1][@backingInt(variant)] = @intCast(slot);
        }
        self.faces_loaded = false;
        self.mono_loaded = false;
        self.loaded_source.system = null;
        self.loaded_source.name_buffer = @splat(0);
        self.loaded_source.name_len = 0;
        self.loaded_source.size = 0;
        self.allocator = allocator;
        self.run_allocator = allocator;
        self.shaper = null;
        self.scale_factor = scale;
        self.io = io;

        try self.cache.initInPlace(
            allocator,
            scale,
            text_limits.glyph_cache_count_max,
            atlas_options,
        );
        errdefer self.cache.deinit();
        self.shape_cache = try ShapedRunCache.init(text_limits.shaped_run_count_max);
        errdefer self.shape_cache.deinit();
        self.measure_cache = try MeasureCache.init(text_limits.measure_slot_count_max);
        errdefer self.measure_cache.deinit();
        self.text_size_cache = try TextSizeCache.init(text_limits.text_size_slot_count_max);
        self.shape_cache_mutex = .init;
        self.glyph_cache_mutex = .init;

        std.debug.assert(self.faces.len == face_count);
        const regular_slot = self.face_slot_by_variant[0][@backingInt(FontVariant.regular)];
        std.debug.assert(regular_slot < self.app_face_count);
    }

    /// Make `run_allocator` own shaped runs from now on, and create the
    /// shaper now so its lazy creation cannot happen after initialization.
    pub fn useRunAllocator(self: *Self, run_allocator: std.mem.Allocator) void {
        std.debug.assert(self.faces_loaded);
        if (self.shaper == null) self.shaper = PlatformShaper.init(self.allocator);
        self.run_allocator = run_allocator;
        std.debug.assert(self.shaper != null);
    }

    pub fn setScaleFactor(self: *Self, scale: f32) void {
        std.debug.assert(scale > 0);
        std.debug.assert(scale <= 4.0);

        self.scale_factor = scale;
        self.cache.setScaleFactor(scale);
    }

    pub fn deinit(self: *Self) void {
        self.unloadFaces();
        self.unloadMonoFaces();
        self.allocator.free(self.faces);
        if (self.shaper) |*s| s.deinit();
        self.cache.deinit();
        self.shape_cache.deinit();
        self.measure_cache.deinit();
        self.text_size_cache.deinit();
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

    pub fn loadSystemFont(self: *Self, style: SystemFont, size: f32) !void {
        std.debug.assert(size > 0 and size < 1000);
        try self.loadFaces(.{ .system = style }, size);
    }

    /// Load the second family into the `FontLimits.mono_variants` slots, once
    /// during init. It keeps its size when `loadFont` replaces the app family;
    /// each family scales by its own regular face's point size.
    pub fn loadMonoFont(self: *Self, source: FaceSource, size: f32) !void {
        std.debug.assert(size > 0 and size < 1000);
        std.debug.assert(!self.mono_loaded);
        if (self.faces.len == self.app_face_count) {
            std.debug.panic("TextSystem: a second family was loaded but " ++
                "ResourceLimits.text.fonts.mono_variants is empty; list its faces there", .{});
        }
        if (source == .name and source.name.len > family_name_bytes_max) {
            return error.FontNameTooLong;
        }
        try self.loadFaceRange(source, size, self.app_face_count, self.faces.len);
        self.mono_loaded = true;
        self.clearCaches();
        std.debug.assert(self.faceFor(.mono, .regular).metrics.point_size == size);
    }

    /// Longest family name `loadFont` accepts; the loaded name is kept so a
    /// failed reload can restore it.
    pub const family_name_bytes_max: u32 = 255;

    pub const FaceSource = union(enum) {
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
        std.debug.assert(self.faceFor(.app, .regular).metrics.point_size == size);
    }

    fn loadEveryFace(self: *Self, source: FaceSource, size: f32) !void {
        std.debug.assert(!self.faces_loaded);
        try self.loadFaceRange(source, size, 0, self.app_face_count);
        self.faces_loaded = true;
    }

    fn loadFaceRange(self: *Self, source: FaceSource, size: f32, first: usize, end: usize) !void {
        std.debug.assert(first < end);
        std.debug.assert(end <= self.faces.len);
        var slot: usize = first;
        errdefer for (self.faces[first..slot]) |*face| face.deinit();

        while (slot < end) : (slot += 1) {
            const variant = self.face_variants[slot];
            self.faces[slot] = switch (source) {
                .name => |name| try PlatformFace.init(name, size, variant),
                .system => |style| try PlatformFace.initSystem(style, size, variant),
            };
        }
        std.debug.assert(slot == end);
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
        self.text_size_cache.clear();
        self.shape_cache_mutex.unlock(self.io);
    }

    fn unloadFaces(self: *Self) void {
        if (self.faces_loaded) {
            for (self.faces[0..self.app_face_count]) |*face| face.deinit();
        }
        self.faces_loaded = false;
    }

    fn unloadMonoFaces(self: *Self) void {
        if (self.mono_loaded) {
            for (self.faces[self.app_face_count..]) |*face| face.deinit();
        }
        self.mono_loaded = false;
    }

    /// The loaded face for `variant` in `family`. A variant outside the
    /// family's `FontLimits` set, or the mono family when none was loaded, is
    /// a programmer error and panics in every build mode: the check is one
    /// byte compare, and substituting another face would silently mis-measure.
    pub fn faceFor(self: *Self, family: FontFamily, variant: FontVariant) *PlatformFace {
        std.debug.assert(self.faces_loaded);
        if (family == .mono and !self.mono_loaded) {
            std.debug.panic("TextSystem: text uses family .mono, but no second family " ++
                "is loaded; set Config.fonts.mono and " ++
                "ResourceLimits.text.fonts.mono_variants", .{});
        }
        const slot = self.face_slot_by_variant[@backingInt(family)][@backingInt(variant)];
        if (slot < self.faces.len) {
            std.debug.assert(self.face_variants[slot] == variant);
            return &self.faces[slot];
        } else {
            self.panicVariantNotLoaded(family, variant);
        }
    }

    fn panicVariantNotLoaded(self: *const Self, family: FontFamily, variant: FontVariant) noreturn {
        // Each entry is a ", " separator plus one tag name.
        const entry_bytes_max = comptime blk: {
            var tag_len_max: usize = 0;
            for (std.meta.fieldNames(FontVariant)) |name| tag_len_max = @max(tag_len_max, name.len);
            break :blk tag_len_max + 2;
        };
        var names_buffer: [FontVariant.count * entry_bytes_max]u8 = undefined;
        var names_len: usize = 0;
        const first: usize = if (family == .app) 0 else self.app_face_count;
        const end: usize = if (family == .app) self.app_face_count else self.faces.len;
        std.debug.assert(end - first <= FontVariant.count);
        for (self.face_variants[first..end], 0..) |loaded, index| {
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
                "ResourceLimits.text.fonts.{s} loads {d} face{s}: {s}. Add it there.",
            .{
                @tagName(variant),
                family.fontId(variant),
                if (family == .app) "variants" else "mono_variants",
                end - first,
                if (end - first == 1) "" else "s",
                names_buffer[0..names_len],
            },
        );
    }

    /// Metrics of the app family's regular face, which set line height and
    /// baseline for all variants so mixed weights on one line share a baseline.
    pub inline fn getMetrics(self: *const Self) ?Metrics {
        if (!self.faces_loaded) return null;
        const slot = self.face_slot_by_variant[0][@backingInt(FontVariant.regular)];
        return self.faces[slot].metrics;
    }

    /// Metrics of `family`'s regular face: the line height, baseline, and
    /// point size that family's runs scale by.
    pub fn getMetricsFor(self: *Self, family: FontFamily) Metrics {
        return self.faceFor(family, .regular).metrics;
    }

    /// The FontFace interface of the regular face.
    pub inline fn getFontFace(self: *Self) !FontFace {
        if (!self.faces_loaded) return error.NoFontLoaded;
        return self.faceFor(.app, .regular).asFontFace();
    }

    pub fn shapeText(
        self: *Self,
        family: FontFamily,
        text: []const u8,
        variant: FontVariant,
        stats: ?*RenderStats,
    ) !ShapedRun {
        std.debug.assert(text.len > 0);

        if (!self.faces_loaded) return error.NoFontLoaded;
        const face = self.faceFor(family, variant);

        std.debug.assert(face.metrics.point_size > 0);

        const font_ptr = @intFromPtr(face);
        const use_cache = text.len <= ShapedRunCache.MAX_TEXT_LEN;

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
                const glyph_count = cached_run.glyphs.len;
                const glyphs_copy = try self.run_allocator.alloc(types.ShapedGlyph, glyph_count);
                @memcpy(glyphs_copy, cached_run.glyphs);
                return types.ShapedRun{
                    .glyphs = glyphs_copy,
                    .width = cached_run.width,
                    .owned = true,
                };
            }
        }

        if (codepointCount(text) > run_codepoint_count_max) return error.TextRunTooLong;
        if (self.shaper == null) {
            self.shaper = PlatformShaper.init(self.allocator);
        }

        std.debug.assert(self.shaper != null);

        // Time the shaping call for stats (native only — skip the JS FFI clock
        // read on WASM's hot path). Monotonic `.awake` keeps `elapsed` >= 0.
        const start_ts = if (!is_wasm) std.Io.Timestamp.now(self.io, .awake) else std.Io.Timestamp.zero;
        const result = try self.shaper.?.shape(face, text, self.run_allocator);
        const end_ts = if (!is_wasm) std.Io.Timestamp.now(self.io, .awake) else std.Io.Timestamp.zero;

        std.debug.assert(result.width >= 0);
        std.debug.assert(result.owned == true);

        if (stats) |s| {
            const elapsed_ns: i96 = start_ts.durationTo(end_ts).toNanoseconds();
            std.debug.assert(elapsed_ns >= 0);
            s.recordShapeMiss(@intCast(elapsed_ns));
        }

        if (use_cache) {
            self.shape_cache_mutex.lockUncancelable(self.io);
            defer self.shape_cache_mutex.unlock(self.io);
            self.shape_cache.put(cache_key, result);
        }

        return result;
    }

    /// Shape text into a caller-provided glyph buffer. On a shape-cache hit the
    /// glyphs are copied into `out_glyphs` and the run has `owned = false`; on a
    /// miss or a run longer than the buffer it falls through to `shapeText`,
    /// which allocates from `run_allocator` and returns `owned = true`.
    pub fn shapeTextInto(
        self: *Self,
        family: FontFamily,
        text: []const u8,
        variant: FontVariant,
        stats: ?*RenderStats,
        out_glyphs: []types.ShapedGlyph,
    ) !ShapedRun {
        std.debug.assert(text.len > 0);
        std.debug.assert(out_glyphs.len > 0);

        if (!self.faces_loaded) return error.NoFontLoaded;
        const face = self.faceFor(family, variant);

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
            }
        }

        return self.shapeText(family, text, variant, stats);
    }

    pub fn getGlyphSubpixel(self: *Self, glyph_id: u16, font_size: f32, subpixel_x: u8, subpixel_y: u8) !CachedGlyph {
        std.debug.assert(font_size > 0);
        const face = try self.getFontFace();

        self.glyph_cache_mutex.lockUncancelable(self.io);
        defer self.glyph_cache_mutex.unlock(self.io);

        return self.cache.getOrRenderSubpixel(face, glyph_id, font_size, subpixel_x, subpixel_y);
    }

    /// Simple width measurement, of any length: a text past one shaping run
    /// is measured run by run (`runLength`), which splits only where no
    /// glyph joins its neighbour, so the sum is the whole text's width.
    pub fn measureText(
        self: *Self,
        family: FontFamily,
        text: []const u8,
        variant: FontVariant,
    ) !f32 {
        if (text.len <= ShapedRunCache.MAX_TEXT_LEN) return self.measureRun(family, text, variant);
        var width: f32 = 0;
        var rest = text;
        // Each run takes at least one byte, so the bytes bound the runs.
        var run_count: usize = 0;
        while (rest.len > 0) : (run_count += 1) {
            std.debug.assert(run_count < text.len);
            const length = runLength(rest);
            std.debug.assert(length > 0);
            std.debug.assert(length <= rest.len);
            width += try self.measureRun(family, rest[0..length], variant);
            rest = rest[length..];
        }
        std.debug.assert(width >= 0);
        return width;
    }

    /// One shaping run's width.
    /// Zero-alloc fast path: on a shape cache hit, reads width directly from the
    /// cache entry under the mutex — no glyph array copy, no allocator call
    /// (~200x faster than the alloc+memcpy+free path: ~25 ns vs ~5200 ns warm).
    /// On web, uses a single JS call instead of character-by-character iteration.
    fn measureRun(
        self: *Self,
        family: FontFamily,
        text: []const u8,
        variant: FontVariant,
    ) !f32 {
        if (!self.faces_loaded) return error.NoFontLoaded;
        // The width comes from the face that renders the text: a bold run is
        // wider than the same string in regular, so layout must measure it bold.
        const face = self.faceFor(family, variant);
        if (is_wasm and !is_synthetic) {
            // One JS call measures the whole string instead of N boundary
            // crossings.
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
                const stats = &render_stats.frame_stats;
                var shaped_long = try self.shapeText(family, text, variant, stats);
                defer shaped_long.deinit(self.run_allocator);
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
            var shaped = try self.shapeText(family, text, variant, &render_stats.frame_stats);
            defer shaped.deinit(self.run_allocator);
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
        family: FontFamily,
        text: []const u8,
        variant: FontVariant,
        max_width: ?f32,
    ) !TextMeasurement {
        if (!self.faces_loaded) return error.NoFontLoaded;
        const face = self.faceFor(family, variant);
        // Rows take their height from the regular face, as in layout and
        // rendering, so wrapped bold text measures as many pixels tall as it draws.
        const line_height = self.faceFor(family, .regular).metrics.line_height;
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
        var run = try self.shapeText(family, text, variant, null);
        defer run.deinit(self.run_allocator);
        return measureGlyphRun(run.glyphs, text, run.width, max_width, line_height);
    }

    /// The glyph atlas. Its size, kind, and upload journal are fixed at init;
    /// placement state is guarded by `glyph_cache_mutex`.
    pub inline fn getAtlas(self: *const Self) *const Atlas {
        return self.cache.getAtlas();
    }

    /// Batch resolve glyphs under one `glyph_cache_mutex` lock, eliminating
    /// the N-1 lock/unlock pairs of per-glyph resolution. Glyphs with a
    /// `font_ref` take the fallback path; others use the face for `variant`.
    pub fn resolveGlyphBatch(
        self: *Self,
        family: FontFamily,
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
        const face = self.faceFor(family, variant).asFontFace();

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

/// Compute text measurement (width, height, line_count) from a glyph slice:
/// the no-wrap fast path first, then word wrapping. Takes only primitives and
/// slices, so the compiler can keep everything in registers.
fn measureGlyphRun(
    glyphs: []const types.ShapedGlyph,
    text: []const u8,
    total_width: f32,
    max_width: ?f32,
    line_height: f32,
) TextMeasurement {
    std.debug.assert(line_height > 0);
    std.debug.assert(total_width >= 0);

    if (max_width == null or total_width <= max_width.?) {
        return .{
            .width = total_width,
            .height = line_height,
            .line_count = 1,
        };
    }

    const limit = max_width.?;
    std.debug.assert(limit > 0);

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

/// The caches' sizes in these tests: `standard`'s 256 runs and `small`'s
/// 1,024 width slots.
const test_shaped_run_count: u32 = TextLimits.standard.shaped_run_count_max;
const test_measure_slot_count: u32 = TextLimits.small.measure_slot_count_max;

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
    var cache = try ShapedRunCache.init(test_shaped_run_count);
    defer cache.deinit();

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

    try std.testing.expect(cache.get(key) == null);

    cache.put(key, run);
    const cached = cache.get(key);
    try std.testing.expect(cached != null);
    try std.testing.expectEqual(@as(usize, 2), cached.?.glyphs.len);
    try std.testing.expectEqual(@as(f32, 20.0), cached.?.width);
    try std.testing.expect(!cached.?.owned);
}

test "ShapedRunCache holds exactly its budget, then evicts only the least recent" {
    const capacity = TextLimits.nano.shaped_run_count_max;
    var cache = try ShapedRunCache.init(capacity);
    defer cache.deinit();

    var glyph = ShapedGlyph{
        .glyph_id = 1,
        .x_offset = 0,
        .y_offset = 0,
        .x_advance = 10,
        .y_advance = 0,
        .cluster = 0,
    };
    const run = ShapedRun{ .glyphs = @as(*[1]ShapedGlyph, &glyph), .width = 10, .owned = true };

    var buf: [32]u8 = undefined;
    for (0..capacity) |i| {
        cache.put(ShapedRunKey.init(try std.fmt.bufPrint(&buf, "text{d}", .{i}), 0x1000, 16), run);
    }
    try std.testing.expectEqual(capacity, cache.entry_count);
    for (0..capacity) |i| {
        const key = ShapedRunKey.init(try std.fmt.bufPrint(&buf, "text{d}", .{i}), 0x1000, 16);
        try std.testing.expect(cache.get(key) != null);
    }

    // Leave run 0 least recent, then put one more.
    for (1..capacity) |i| {
        const key = ShapedRunKey.init(try std.fmt.bufPrint(&buf, "text{d}", .{i}), 0x1000, 16);
        _ = cache.get(key);
    }
    const extra_key = ShapedRunKey.init("extra", 0x1000, 16);
    cache.put(extra_key, run);

    try std.testing.expectEqual(capacity, cache.entry_count);
    try std.testing.expect(cache.get(extra_key) != null);
    try std.testing.expect(cache.get(ShapedRunKey.init("text0", 0x1000, 16)) == null);
    for (1..capacity) |i| {
        const key = ShapedRunKey.init(try std.fmt.bufPrint(&buf, "text{d}", .{i}), 0x1000, 16);
        try std.testing.expect(cache.get(key) != null);
    }
}

test "cache keys differ by face, and faces stay resident side by side" {
    const testing = std.testing;
    const regular_face: usize = 0x1000;
    const bold_face: usize = 0x2000;

    const regular_key = ShapedRunKey.init("Total", regular_face, 16.0);
    const bold_key = ShapedRunKey.init("Total", bold_face, 16.0);
    try testing.expect(!ShapedRunKey.eql(regular_key, bold_key));

    const glyph_regular = cache_mod.GlyphKey.initWithFontPtr(regular_face, 55, 16.0, 2.0, 0, 0);
    const glyph_bold = cache_mod.GlyphKey.initWithFontPtr(bold_face, 55, 16.0, 2.0, 0, 0);
    try testing.expect(!cache_mod.GlyphKey.eql(glyph_regular, glyph_bold));

    var shape_cache = try ShapedRunCache.init(test_shaped_run_count);
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

    var measure_cache = try MeasureCache.init(test_measure_slot_count);
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
    var cache = try ShapedRunCache.init(test_shaped_run_count);
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

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "collision_test_{d}", .{i}) catch unreachable;
        const key = ShapedRunKey.init(text, 0x1000, 16.0);
        cache.put(key, run);
    }

    try std.testing.expectEqual(@as(u32, 100), cache.entry_count);

    i = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "collision_test_{d}", .{i}) catch unreachable;
        const key = ShapedRunKey.init(text, 0x1000, 16.0);
        try std.testing.expect(cache.get(key) != null);
    }

    i = 100;
    while (i < test_shaped_run_count + 50) : (i += 1) {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "evict_test_{d}", .{i}) catch unreachable;
        const key = ShapedRunKey.init(text, 0x1000, 16.0);
        cache.put(key, run);
    }

    try std.testing.expectEqual(@as(u32, test_shaped_run_count), cache.entry_count);

    i = test_shaped_run_count;
    while (i < test_shaped_run_count + 50) : (i += 1) {
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

    try testing.expect(!ShapedRunKey.eql(key1, key2));

    try testing.expect(ShapedRunKey.eql(key1, key3));

    try testing.expectEqual(key1.size_fixed, key3.size_fixed);
    try testing.expect(key1.size_fixed != key2.size_fixed);

    try testing.expectEqual(@as(u16, 16 * 64), key1.size_fixed);
    try testing.expectEqual(@as(u16, 24 * 64), key2.size_fixed);
}

test "ShapedRunKey size differentiation" {
    const testing = std.testing;

    const key_14 = ShapedRunKey.init("Test", 0x1234, 14.0);
    const key_16 = ShapedRunKey.init("Test", 0x1234, 16.0);
    const key_18 = ShapedRunKey.init("Test", 0x1234, 18.0);

    try testing.expect(!ShapedRunKey.eql(key_14, key_16));
    try testing.expect(!ShapedRunKey.eql(key_16, key_18));
    try testing.expect(!ShapedRunKey.eql(key_14, key_18));

    try testing.expectEqual(key_14.text_hash, key_16.text_hash);
    try testing.expect(key_14.size_fixed != key_16.size_fixed);
    try testing.expect(key_16.size_fixed != key_18.size_fixed);
}

test "shapeTextInto warm path copies into caller buffer with owned=false" {
    const testing = std.testing;

    var cache = try ShapedRunCache.init(test_shaped_run_count);
    defer cache.deinit();

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

    try testing.expect(!result.owned);
    try testing.expectEqual(@as(usize, 3), result.glyphs.len);
    try testing.expectEqual(@as(f32, 24.5), result.width);

    try testing.expectEqual(@as(u16, 42), result.glyphs[0].glyph_id);
    try testing.expectEqual(@as(f32, 8.5), result.glyphs[0].x_advance);
    try testing.expectEqual(@as(u16, 43), result.glyphs[1].glyph_id);
    try testing.expectEqual(@as(f32, 7.0), result.glyphs[1].x_advance);
    try testing.expectEqual(@as(u16, 44), result.glyphs[2].glyph_id);
    try testing.expectEqual(@as(f32, 9.0), result.glyphs[2].x_advance);

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
    const testing = std.testing;

    var cache = try ShapedRunCache.init(test_shaped_run_count);
    defer cache.deinit();

    const at_limit = ShapedRunCache.MAX_GLYPHS_PER_ENTRY;
    const over_limit = ShapedRunCache.MAX_GLYPHS_PER_ENTRY + 1;

    // Both lengths sit under the lookup gate, so any difference in behaviour
    // below comes from the insert limit alone.
    try testing.expect(over_limit <= ShapedRunCache.MAX_TEXT_LEN);

    var glyphs_at: [at_limit]ShapedGlyph = undefined;
    var text_at: [at_limit]u8 = undefined;
    const run_at = fillTestRun(&glyphs_at, &text_at);
    const key_at = ShapedRunKey.init(&text_at, 0x1000, 16.0);

    cache.put(key_at, run_at);
    try testing.expect(cache.get(key_at) != null);
    try testing.expectEqual(@as(u32, 1), cache.entry_count);

    var glyphs_over: [over_limit]ShapedGlyph = undefined;
    var text_over: [over_limit]u8 = undefined;
    const run_over = fillTestRun(&glyphs_over, &text_over);
    const key_over = ShapedRunKey.init(&text_over, 0x1000, 16.0);

    cache.put(key_over, run_over);
    try testing.expect(cache.get(key_over) == null);
    try testing.expectEqual(@as(u32, 1), cache.entry_count);

    // Repeating the shape-then-store cycle never converges.  Each iteration
    // stands in for one frame re-shaping the same unchanged string.
    var frame: u32 = 0;
    while (frame < 8) : (frame += 1) {
        cache.put(key_over, run_over);
        try testing.expect(cache.get(key_over) == null);
    }
    try testing.expectEqual(@as(u32, 1), cache.entry_count);
}

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

test "TextSizeCache holds its slot count, then evicts the least recently used" {
    const testing = std.testing;
    const slot_count: u32 = 64;
    var cache = try TextSizeCache.init(slot_count);
    defer cache.deinit();
    var index: u32 = 0;
    while (index < slot_count) : (index += 1) {
        cache.put(textSizeKey(index), @floatFromInt(index), 20);
    }
    index = 0;
    while (index < slot_count) : (index += 1) {
        const size = cache.get(textSizeKey(index)).?;
        try testing.expectEqual(@as(f32, @floatFromInt(index)), size[0]);
    }
    var extra = textSizeKey(slot_count);
    extra.max_width_bits = 1;
    try testing.expect(cache.get(extra) == null);
    cache.put(extra, 99, 40);
    try testing.expectEqual(@as(f32, 40), cache.get(extra).?[1]);
    try testing.expect(cache.get(textSizeKey(0)) == null);
    index = 1;
    while (index < slot_count) : (index += 1) {
        try testing.expect(cache.get(textSizeKey(index)) != null);
    }
    cache.clear();
    try testing.expect(cache.get(textSizeKey(1)) == null);
}

fn textSizeKey(index: u32) TextSizeKey {
    return .{ .text_hash = index, .text_len = 1, .max_width_bits = 0, .style = 0 };
}

test "MeasureCache stores widths the shape cache refuses" {
    const testing = std.testing;

    var cache = try MeasureCache.init(test_measure_slot_count);
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

        try testing.expect(cache.get(key) == null);
        cache.put(key, width);
        try testing.expectEqual(width, cache.get(key).?);
    }
}

test "MeasureCache converges after a single miss for over-limit text" {
    const testing = std.testing;

    var cache = try MeasureCache.init(test_measure_slot_count);
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
    const testing = std.testing;

    var cache = try MeasureCache.init(test_measure_slot_count);
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
    const testing = std.testing;

    var cache = try MeasureCache.init(test_measure_slot_count);
    defer cache.deinit();

    const font_ptr: usize = 0x4000;

    const insert_count: u32 = @intCast(test_measure_slot_count * 4);
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
    try testing.expect(hits <= test_measure_slot_count);

    // The most recent insert is always resident.
    fillTestText(&buf, insert_count - 1);
    const newest = ShapedRunKey.init(&buf, font_ptr, 16.0);
    try testing.expectEqual(@as(f32, @floatFromInt(insert_count - 1)), cache.get(newest).?);
}

test "MeasureCache fills a probe window exactly, then evicts its least recent" {
    const testing = std.testing;
    const window = MeasureCache.MAX_PROBE_LENGTH;
    var cache = try MeasureCache.init(window * 2);
    defer cache.deinit();
    const mask = cache.slots.len - 1;

    var texts: [window + 1][16]u8 = undefined;
    var lens: [window + 1]usize = undefined;
    var found: usize = 0;
    var seed: u32 = 0;
    const target = ShapedRunKey.init("k0", 0x5000, 16).text_hash & mask;
    while (found < texts.len) : (seed += 1) {
        assert(seed < 100_000);
        const text = try std.fmt.bufPrint(&texts[found], "k{d}", .{seed});
        if (ShapedRunKey.init(text, 0x5000, 16).text_hash & mask != target) continue;
        lens[found] = text.len;
        found += 1;
    }

    for (0..window) |i| {
        cache.put(ShapedRunKey.init(texts[i][0..lens[i]], 0x5000, 16), @floatFromInt(i));
    }
    for (0..window) |i| {
        const key = ShapedRunKey.init(texts[i][0..lens[i]], 0x5000, 16);
        try testing.expectEqual(@as(f32, @floatFromInt(i)), cache.get(key).?);
    }
    for (1..window) |i| _ = cache.get(ShapedRunKey.init(texts[i][0..lens[i]], 0x5000, 16));

    cache.put(ShapedRunKey.init(texts[window][0..lens[window]], 0x5000, 16), 99);
    try testing.expect(cache.get(ShapedRunKey.init(texts[0][0..lens[0]], 0x5000, 16)) == null);
    for (1..window + 1) |i| {
        const key = ShapedRunKey.init(texts[i][0..lens[i]], 0x5000, 16);
        try testing.expect(cache.get(key) != null);
    }
}

test "glyph cache re-renders a glyph whose atlas shelf was evicted" {
    const testing = std.testing;
    var uploads: atlas_mod.AtlasUploads = undefined;
    try uploads.init(testing.allocator, testing.io, .{
        .storage = .cpu_texture,
        .upload_bytes_frame_max = 64,
        .consumer_count_max = 1,
    });
    defer uploads.deinit();
    const consumer: usize = 1;
    uploads.registerConsumer(consumer);
    defer uploads.unregisterConsumer(consumer);

    const text_system = try testing.allocator.create(TextSystem);
    defer testing.allocator.destroy(text_system);
    try text_system.initInPlace(testing.allocator, 1.0, testing.io, &TextLimits.standard, .{
        .size = 64,
        .uploads = &uploads,
    });
    defer text_system.deinit();
    try text_system.loadSystemFont(.sans_serif, 40);

    const letters = "ABCDEFGHKMNOPQRSUVWXYZ";
    var run = try text_system.shapeText(.app, letters, .regular, null);
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

test "glyph cache holds exactly its budget in one frame and reuses evicted slots after" {
    const testing = std.testing;
    var uploads: atlas_mod.AtlasUploads = undefined;
    try uploads.init(testing.allocator, testing.io, .{
        .storage = .cpu_texture,
        .upload_bytes_frame_max = 64 * 1024,
        .consumer_count_max = 1,
    });
    defer uploads.deinit();
    const consumer: usize = 1;
    uploads.registerConsumer(consumer);
    defer uploads.unregisterConsumer(consumer);

    var text_limits = TextLimits.standard;
    text_limits.glyph_cache_count_max = 8;
    const text_system = try testing.allocator.create(TextSystem);
    defer testing.allocator.destroy(text_system);
    try text_system.initInPlace(testing.allocator, 1.0, testing.io, &text_limits, .{
        .size = 256,
        .uploads = &uploads,
    });
    defer text_system.deinit();
    try text_system.loadSystemFont(.sans_serif, 20);

    var run = try text_system.shapeText(.app, "ABCDEFGHK", .regular, null);
    defer run.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 9), run.glyphs.len);

    _ = uploads.beginFrame(consumer);
    var regions: [8]atlas_mod.Region = undefined;
    for (run.glyphs[0..8], &regions) |glyph, *region| {
        region.* = (try text_system.getGlyphSubpixel(glyph.glyph_id, 20, 0, 0)).region;
    }
    try testing.expectEqual(@as(u32, 8), text_system.cache.entry_count);
    for (run.glyphs[0..8], regions) |glyph, region| {
        const hit = try text_system.getGlyphSubpixel(glyph.glyph_id, 20, 0, 0);
        try testing.expectEqual(region, hit.region);
    }
    try testing.expectEqual(@as(u32, 8), text_system.cache.entry_count);

    // Frame 1 closes once a consume starts after frame 2 began. The 9th
    // glyph is 40 px so it opens its own shelf: rendered at 20 px it would
    // share frame 1's shelf, stamp it current, and leave nothing evictable.
    _ = uploads.beginFrame(consumer);
    _ = uploads.consumeBegin(consumer);
    uploads.consumeEnd(consumer);
    const ninth = try text_system.getGlyphSubpixel(run.glyphs[8].glyph_id, 40, 0, 0);
    try testing.expect(ninth.region.height > regions[0].height);
    // Evicting frame 1's shelves made their entries stale, and the 9th took a
    // reclaimed slot: the cache holds at most 8 and never claimed a 9th slot.
    // How many shelves 8 glyphs at 20 px span depends on the backend's glyph
    // heights, so how many entries one eviction reclaims is not fixed.
    try testing.expect(text_system.cache.entry_count <= 8);
    try testing.expectEqual(@as(u16, 8), text_system.cache.entry_high_water);
    try testing.expectEqual(@as(usize, 8), text_system.cache.entries.len);
}

test "glyph cache hits protect their shelf in every frame they are used" {
    const testing = std.testing;
    var uploads: atlas_mod.AtlasUploads = undefined;
    try uploads.init(testing.allocator, testing.io, .{
        .storage = .cpu_texture,
        .upload_bytes_frame_max = 4096,
        .consumer_count_max = 1,
    });
    defer uploads.deinit();
    const consumer: usize = 1;
    uploads.registerConsumer(consumer);
    defer uploads.unregisterConsumer(consumer);

    const text_system = try testing.allocator.create(TextSystem);
    defer testing.allocator.destroy(text_system);
    try text_system.initInPlace(testing.allocator, 1.0, testing.io, &TextLimits.standard, .{
        .size = 128,
        .uploads = &uploads,
    });
    defer text_system.deinit();
    try text_system.loadSystemFont(.sans_serif, 40);

    var run = try text_system.shapeText(.app, "AB", .regular, null);
    defer run.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), run.glyphs.len);
    const id_a = run.glyphs[0].glyph_id;
    const id_b = run.glyphs[1].glyph_id;
    const atlas = text_system.getAtlas();

    _ = uploads.beginFrame(consumer);
    const first = try text_system.getGlyphSubpixel(id_a, 20, 0, 0);
    _ = try text_system.getGlyphSubpixel(id_a, 20, 0, 0);
    const tall = try text_system.getGlyphSubpixel(id_b, 40, 0, 0);
    try testing.expect(tall.region.y > first.region.y);
    var saved: [128 * 128]u8 = undefined;
    const saved_len = copyRegion(atlas, first.region, &saved);
    const rows_frame_1 = atlas.rows_active;

    _ = uploads.beginFrame(consumer);
    const pair = [_]types.ShapedGlyph{ run.glyphs[0], run.glyphs[0] };
    const subpixels = [_]u8{ 0, 0 };
    var resolved: [2]CachedGlyph = undefined;
    try text_system.resolveGlyphBatch(.app, &pair, .regular, 20, &subpixels, &resolved);
    try testing.expectEqual(first.region.y, resolved[1].region.y);
    _ = uploads.consumeBegin(consumer);
    uploads.consumeEnd(consumer);

    // Each eviction frees one shelf, so the shelf count bounds the loop.
    var evicted: u32 = 0;
    while (evicted < atlas.shelves.len) : (evicted += 1) {
        if (!text_system.cache.grayscale_atlas.evictOne()) break;
    }
    try testing.expectEqual(@as(u32, 1), evicted);
    try testing.expect(atlas.rows_active < rows_frame_1);

    const again = try text_system.getGlyphSubpixel(id_a, 20, 0, 0);
    try testing.expectEqual(first.region.x, again.region.x);
    try testing.expectEqual(first.region.y, again.region.y);
    var current: [128 * 128]u8 = undefined;
    const current_len = copyRegion(atlas, again.region, &current);
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

/// The bytes of `text`'s first shaping run: the whole text when it is at most
/// `ShapedRunCache.MAX_TEXT_LEN` bytes, else up to the last break within that
/// size, or the first break after it; an unbroken word ends at
/// `run_codepoint_count_max` codepoints, the bound only the shapers know.
/// `measureText` and `render.placeText` walk a text run by run.
pub fn runLength(text: []const u8) usize {
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= std.math.maxInt(u32));
    comptime std.debug.assert(ShapedRunCache.MAX_TEXT_LEN <= run_codepoint_count_max);
    if (text.len <= ShapedRunCache.MAX_TEXT_LEN) return text.len;
    var offset: usize = 0;
    var codepoints: u32 = 0;
    var break_end: usize = 0;
    while (offset < text.len) : (offset += 1) {
        const byte = text[offset];
        // A continuation byte belongs to the codepoint already counted.
        if (byte & 0xC0 == 0x80) continue;
        // The codepoint before this one started inside the cacheable size, so
        // a break found up to here ends within it.
        if (offset >= ShapedRunCache.MAX_TEXT_LEN and break_end > 0) return break_end;
        if (codepoints == run_codepoint_count_max) {
            std.debug.assert(break_end == 0);
            return offset;
        }
        codepoints += 1;
        if (byte == ' ' or byte == '\n' or byte == '\t') break_end = offset + 1;
    }
    std.debug.assert(codepoints <= run_codepoint_count_max);
    return text.len;
}

/// The codepoints in `text`, counting lead bytes, so invalid UTF-8 still
/// yields a bound rather than an error.
pub fn codepointCount(text: []const u8) u32 {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    var count: u32 = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }
    std.debug.assert(count <= text.len);
    return count;
}

test "runLength splits at the last break within the cacheable size, or at the bound" {
    const at_size: [ShapedRunCache.MAX_TEXT_LEN]u8 = @splat('a');
    try std.testing.expectEqual(at_size.len, runLength(&at_size));
    const words = repeatText("abc ", 150);
    try std.testing.expectEqual(@as(usize, 512), runLength(&words));
    try std.testing.expectEqual(@as(usize, 88), runLength(words[512..]));
    const sevens = repeatText("abcdef ", 100);
    try std.testing.expectEqual(@as(usize, 511), runLength(&sevens));
    const late = repeatText("b", 600) ++ " x".* ++ repeatText("c", 100);
    try std.testing.expectEqual(@as(usize, 601), runLength(&late));
    const wide = repeatText("\u{e9}", run_codepoint_count_max + 1);
    try std.testing.expectEqual(@as(usize, 2 * run_codepoint_count_max), runLength(&wide));
}

/// `count` copies of `unit`.
fn repeatText(comptime unit: []const u8, comptime count: usize) [unit.len * count]u8 {
    @setEvalBranchQuota(100_000);
    var bytes: [unit.len * count]u8 = undefined;
    for (0..count) |index| @memcpy(bytes[index * unit.len ..][0..unit.len], unit);
    return bytes;
}
