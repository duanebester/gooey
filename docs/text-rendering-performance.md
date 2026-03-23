# Text Rendering Performance Enhancements

Design doc for the next round of optimizations in the text rendering pipeline (`src/text/`).

## Context

The `shapeTextInto` optimization eliminated heap allocation on the warm (cache-hit) shaping path, yielding 38–518× speedups over the GPA path. The remaining cost in `renderText` is now dominated by **per-glyph overhead** in the glyph cache and scene layers — not shaping.

This document catalogs the concrete opportunities identified by auditing the hot path end-to-end, from `shapeTextInto` return through `scene.insertGlyphClipped`.

---

## Current Hot Path Profile (per `renderText` call, 50-char string)

```
shapeTextInto          ~23 ns   ✅ already optimized (stack buffer, owned=false)
├─ mutex lock/unlock    1×
├─ cache lookup         1×
└─ memcpy glyphs        1×

glyph cache lookups    ~50× getGlyphSubpixel
├─ mutex lock/unlock    50×  ← biggest remaining cost
├─ GlyphKey.hash()      50×  (15 FNV multiplies each)
├─ hash table probe     50×
└─ GlyphKey.eql()       50×

UV computation         ~50× cached.uv()
├─ 4 int→float casts    50×
└─ 4 float divisions    50×

scene insertion        ~50× insertGlyphClipped
├─ currentClip()        50×  (redundant — clip doesn't change mid-run)
├─ capacity branch      50×
└─ stats record         50×
```

---

## Enhancement 1: Batch Glyph Cache Lookups Under One Mutex Lock

**Impact: HIGH — eliminates N-1 lock/unlock pairs per text run**

### Problem

In `renderText()`, each glyph calls `text_system.getGlyphSubpixel()`, which individually locks and unlocks `glyph_cache_mutex`:

```zig
// text_system.zig — called 50× for a 50-char string
pub fn getGlyphSubpixel(self: *Self, glyph_id: u16, font_size: f32, subpixel_x: u8, subpixel_y: u8) !CachedGlyph {
    const face = try self.getFontFace();
    self.glyph_cache_mutex.lock();
    defer self.glyph_cache_mutex.unlock();
    return self.cache.getOrRenderSubpixel(face, glyph_id, font_size, subpixel_x, subpixel_y);
}
```

Each uncontended mutex lock/unlock is ~10–40 ns on macOS (atomic CAS + memory fence). For 50 glyphs: **500–2000 ns in pure synchronization overhead**.

### Solution

Expose a `withGlyphCacheLocked` callback pattern (mirroring the existing `withAtlasLocked` / `withAtlasLockedCtx` APIs) so `renderText` can lock once, process all glyphs, and unlock:

```zig
// In TextSystem — new method:
pub fn withGlyphCacheLockedCtx(
    self: *Self,
    comptime Ctx: type,
    ctx: Ctx,
    comptime callback: fn (Ctx, *GlyphCache, FontFace) anyerror!void,
) !void {
    const face = try self.getFontFace();
    self.glyph_cache_mutex.lock();
    defer self.glyph_cache_mutex.unlock();
    return callback(ctx, &self.cache, face);
}
```

In `renderText`, the glyph loop would call `cache.getOrRenderSubpixel()` directly inside the callback — no per-glyph lock. Build `GlyphInstance` values into a stack buffer during the locked phase, then flush to the scene after releasing the lock.

This is the glyph-cache equivalent of `shapeTextInto` — same pattern, next layer down.

### Design notes

- Thread safety semantics are unchanged: the lock is held for the duration of the batch, which is strictly stronger than per-glyph locking.
- Cold-path rasterization (atlas reserve, render, set) still works — it already runs under the same lock.
- Fallback fonts (`glyph.font_ref != null`) route through `cache.getOrRenderFallback()` instead; both paths are callable under the same lock since they operate on the same `GlyphCache`.

### Estimated savings

~500–2000 ns per text run (50 chars). More for longer strings.

---

## Enhancement 2: Faster GlyphKey Hash

**Impact: MEDIUM — ~15 multiplies → 2–3 per glyph lookup**

### Problem

`GlyphKey.hash()` uses byte-by-byte FNV-1a, processing the key in 15 separate XOR + multiply rounds:

```zig
// cache.zig — GlyphKey.hash() (simplified)
var h: u64 = FNV_OFFSET;
for (ptr_bytes) |b| { h ^= b; h *%= FNV_PRIME; }   // 8 rounds for font_ptr
h ^= glyph_id_lo; h *%= FNV_PRIME;                  // 2 rounds for glyph_id
h ^= glyph_id_hi; h *%= FNV_PRIME;
h ^= size_lo; h *%= FNV_PRIME;                       // 2 rounds for size_fixed
h ^= size_hi; h *%= FNV_PRIME;
h ^= scale; h *%= FNV_PRIME;                         // 1 round each
h ^= subpixel_x; h *%= FNV_PRIME;
h ^= subpixel_y; h *%= FNV_PRIME;
```

That's 15 dependent multiplies per glyph lookup — a long serial chain the CPU can't parallelize.

### Solution

Pack the non-pointer fields into a single `u64` (they fit: 16 + 16 + 8 + 8 + 8 = 56 bits) and use a 2-round wyhash-style mix:

```zig
pub fn hash(self: GlyphKey) u64 {
    const packed: u64 = @as(u64, self.glyph_id) |
        (@as(u64, self.size_fixed) << 16) |
        (@as(u64, self.scale_fixed) << 32) |
        (@as(u64, self.subpixel_x) << 40) |
        (@as(u64, self.subpixel_y) << 48);

    const ptr_u64: u64 = @intCast(self.font_ptr);

    const PRIME_A: u64 = 0x9E3779B97F4A7C15; // Golden ratio fractional bits
    const PRIME_B: u64 = 0xBF58476D1CE4E5B9;
    var h = (ptr_u64 ^ PRIME_A) *% (packed ^ PRIME_B);
    h = (h ^ (h >> 32)) *% PRIME_A;
    return h ^ (h >> 32);
}
```

Two multiplies with excellent avalanche properties. The `>> 32` shifts break up patterns that would cause clustering in the hash table.

### Validation

- Add a distribution test: hash all printable ASCII glyph IDs × 4 subpixel variants (95 × 4 = 380 keys), verify collision rate in a 512-slot table stays below 5%.
- Benchmark with `benchGlyphRasterWarm` — expect measurable improvement on the per-glyph ns/op.

### Estimated savings

~200–400 ns per text run (50 chars), depending on how much the serial multiply chain was bottlenecking.

---

## Enhancement 3: GlyphCache Free List for O(1) Insertion

**Impact: MEDIUM — eliminates O(4096) linear scan on cold path**

### Problem

`putInCache` linearly scans through all 4096 entries to find an invalid slot:

```zig
// cache.zig — putInCache (current)
var target_idx: ?usize = null;
for (&self.entries, 0..) |*entry, idx| {
    if (!entry.valid) {
        target_idx = idx;
        break;
    }
}
```

When the cache is 90% full (3686 valid entries), this scans ~1843 entries on average before finding a free slot. Each `GlyphEntry` is `GlyphKey` (15 bytes) + `CachedGlyph` (~28 bytes) + `bool` — strided access across cache lines.

### Solution

Maintain an intrusive free list through the entries array. Add a `next_free: u16` to `GlyphCache` (head pointer) and use a `next_free` field within each invalid entry to chain free slots:

```zig
// GlyphCache additions:
next_free: u16, // Head of free list (EMPTY_SLOT = none free)

// At init, chain all entries into the free list:
fn initFreeList(self: *Self) void {
    for (0..MAX_CACHED_GLYPHS - 1) |i| {
        self.free_chain[i] = @intCast(i + 1);
    }
    self.free_chain[MAX_CACHED_GLYPHS - 1] = EMPTY_SLOT;
    self.next_free = 0;
}

// putInCache becomes O(1):
fn putInCache(self: *Self, key: GlyphKey, glyph: CachedGlyph) void {
    if (self.next_free == EMPTY_SLOT) return; // Full
    const idx = self.next_free;
    self.next_free = self.free_chain[idx];
    self.entries[idx] = .{ .key = key, .glyph = glyph, .valid = true };
    self.entry_count += 1;
    self.insertIntoHashTable(key, idx);
}
```

Use a separate `free_chain: [MAX_CACHED_GLYPHS]u16` array rather than overloading the `GlyphEntry` struct — keeps the valid-entry data clean and avoids union gymnastics. The free chain is 8 KB (4096 × 2 bytes) — trivial memory cost.

When clearing the cache or evicting entries, push freed indices back onto the list head.

### Estimated savings

O(1) instead of O(N) insertion on every cache miss. Most visible during initial text rendering (cold start) and after atlas eviction clears the cache.

---

## Enhancement 4: Hot Loop Extraction in renderText

**Impact: MEDIUM — better register allocation, per CLAUDE.md Rule #20**

### Problem

The inner glyph loop in `renderText` accesses `text_system`, `scene`, `options`, `scale_factor`, `size_scale`, and `pen_x` — all through pointers or closure-captured state. The compiler can't easily prove these don't alias, forcing repeated loads from memory.

### Solution

Split the `renderText` loop into two phases:

**Phase A — Resolve glyphs (under glyph_cache lock):**

```zig
// Standalone function with primitive args — no self, no pointer chasing
fn resolveGlyphBatch(
    cache: *GlyphCache,
    face: FontFace,
    shaped_glyphs: []const ShapedGlyph,
    font_size: f32,
    scale_factor: f32,
    size_scale: f32,
    pen_x_start: f32,
    baseline_y: f32,
    // Output:
    out_cached: []CachedGlyph,
    out_device_x: []f32,
    out_device_y: []f32,
    out_pen_advance: []f32,
) u32 { ... }
```

**Phase B — Emit instances to scene (no lock needed):**

```zig
fn emitGlyphInstances(
    out_cached: []const CachedGlyph,
    out_device_x: []const f32,
    out_device_y: []const f32,
    count: u32,
    scale_factor: f32,
    color: Hsla,
    inverse_atlas_size: f32,
    // Output:
    out_instances: []GlyphInstance,
) u32 { ... }
```

The compiler can keep `scale_factor`, `size_scale`, `pen_x`, etc. in registers throughout the tight loops since there's no aliasing with `self` fields.

### Estimated savings

Compiler-dependent. Likely ~5–15% improvement in the inner loop on ARM64 (Apple Silicon) where register pressure matters more.

---

## Enhancement 5: Scene Batch Glyph Insertion

**Impact: MEDIUM — amortize per-glyph overhead**

### Problem

Each `insertGlyphClipped()` performs 7 operations per glyph:

```zig
// scene.zig — called N times per text run
pub fn insertGlyphClipped(self: *Self, glyph: GlyphInstance) !void {
    std.debug.assert(self.glyphs.items.len < MAX_GLYPHS_PER_FRAME);
    const clip = self.currentClip();             // Redundant — same clip for all glyphs in run
    var g = glyph.withClipBounds(clip);
    g.order = self.next_order;
    self.next_order += 1;
    try self.glyphs.append(self.allocator, g);   // Capacity check per glyph
    if (self.stats) |s| s.recordGlyphs(1);       // Stats per glyph
}
```

### Solution

Add `insertGlyphsClippedBatch`:

```zig
pub fn insertGlyphsClippedBatch(self: *Self, instances: []const GlyphInstance) !void {
    std.debug.assert(self.glyphs.items.len + instances.len <= MAX_GLYPHS_PER_FRAME);
    try self.glyphs.ensureUnusedCapacity(self.allocator, instances.len);

    const clip = self.currentClip();      // Once
    for (instances) |glyph| {
        var g = glyph.withClipBounds(clip);
        g.order = self.next_order;
        self.next_order += 1;
        self.glyphs.appendAssumeCapacity(g);  // No capacity branch
    }
    if (self.stats) |s| s.recordGlyphs(@intCast(instances.len));  // Once
}
```

One capacity check, one clip lookup, one stats call — regardless of glyph count. The `appendAssumeCapacity` inner loop compiles to a tight store sequence.

### Estimated savings

~100–300 ns per text run (50 chars). The savings compound with Enhancement #1 since glyph instances would be accumulated into a stack buffer during the locked phase and flushed here in one batch.

---

## Enhancement 6: Precompute Inverse Atlas Size for UV

**Impact: LOW — 4 divisions → 4 multiplications per glyph**

### Problem

`Region.uv()` divides by `atlas_size` four times per glyph:

```zig
// atlas.zig
pub fn uv(self: Region, atlas_size: u32) UVCoords {
    const size_f: f32 = @floatFromInt(atlas_size);
    return .{
        .u0 = @as(f32, @floatFromInt(self.x)) / size_f,
        .v0 = @as(f32, @floatFromInt(self.y)) / size_f,
        .u1 = @as(f32, @floatFromInt(self.x + self.width)) / size_f,
        .v1 = @as(f32, @floatFromInt(self.y + self.height)) / size_f,
    };
}
```

On the warm path, all glyphs share the same `atlas_size` (the atlas doesn't grow mid-batch). Float division is ~4× slower than multiplication on most hardware.

### Solution

Add a `uvFast` variant that takes a precomputed inverse:

```zig
pub fn uvFast(self: Region, inverse_atlas_size: f32) UVCoords {
    return .{
        .u0 = @as(f32, @floatFromInt(self.x)) * inverse_atlas_size,
        .v0 = @as(f32, @floatFromInt(self.y)) * inverse_atlas_size,
        .u1 = @as(f32, @floatFromInt(self.x + self.width)) * inverse_atlas_size,
        .v1 = @as(f32, @floatFromInt(self.y + self.height)) * inverse_atlas_size,
    };
}
```

In `renderText`, compute `const inverse_atlas_size = 1.0 / @as(f32, @floatFromInt(first_cached.atlas_size));` once before the emit loop. Assert that subsequent glyphs have the same atlas_size (they will on the warm path; if not, fall back to the division path).

### Estimated savings

~20–50 ns per text run (50 chars). Trivial to implement.

---

## Recommended Implementation Order

| # | Enhancement | Est. Savings (50 chars) | Complexity | Dependencies |
|---|---|---|---|---|
| 1 | Batch mutex lock | ~500–2000 ns | Medium | None |
| 2 | Faster GlyphKey hash | ~200–400 ns | Low | None |
| 3 | Free list for putInCache | O(N)→O(1) cold | Low | None |
| 4 | Hot loop extraction | ~5–15% inner loop | Medium | Benefits from #1 |
| 5 | Scene batch insert | ~100–300 ns | Low | Benefits from #1, #4 |
| 6 | Inverse atlas size | ~20–50 ns | Trivial | Benefits from #4 |

**#1, #2, and #3 are independent** — can be implemented and benchmarked in parallel.

**#4, #5, #6 build on #1** — the two-phase split (resolve under lock → emit to scene) creates the natural place for batch scene insertion and UV precomputation.

### Combined estimated savings

For a warm-cache 50-character `renderText` call, the full set would save ~1000–3000 ns, with the batch mutex lock (#1) contributing roughly half.

---

## Benchmarking Plan

Each enhancement should be benchmarked with the existing suite plus targeted additions:

- **#1**: New `benchRenderTextBatched` that compares per-glyph lock vs. batch lock. Use `benchGlyphRasterWarm` as baseline.
- **#2**: Run `benchGlyphRasterWarm` and `benchGlyphRasterWarmSubpixel` before/after. Add a hash distribution test.
- **#3**: Run `benchGlyphRasterCold` before/after — this is where insertion cost dominates.
- **#4–#6**: End-to-end `renderText` benchmark (requires scene setup). Consider adding `benchRenderText` to the suite.
