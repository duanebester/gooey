# Text Rendering Performance Enhancements

Design doc for the optimizations in the text rendering pipeline (`src/text/`).
The `renderText` path (`src/text/render.zig`) is now a three-phase split:
compute device positions → batch-resolve glyphs under one lock → emit to scene.

## Status

Of the six enhancements catalogued below, **four landed** and **two were
evaluated and rejected**. Landed items carry an inline **`Implemented.`** callout
(same convention as `scene-data-plane-performance.md`); the two Phase-3 items
now carry **`Evaluated — rejected.`** with the benchmark evidence.

| #   | Enhancement                                        | Status                  | Where it lives                                     |
| --- | -------------------------------------------------- | ----------------------- | -------------------------------------------------- |
| 1   | Batch glyph-cache lookups under one mutex          | ✅ Implemented          | `TextSystem.resolveGlyphBatch`                     |
| 2   | Faster `GlyphKey` hash                             | ✅ Implemented          | `cache.zig` `GlyphKey.hash` (packed `u64` mix)     |
| 3   | Free list for O(1) `putInCache`                    | ✅ Implemented          | `cache.zig` `free_chain` / `next_free`             |
| 4   | Hot-loop extraction in `renderText`                | ✅ Implemented          | `render.zig` three-phase split                     |
| 5   | Scene batch glyph insertion                        | ❌ Evaluated — rejected | benchmarked neutral (`emit_*`)                     |
| 6   | Precompute run-constant reciprocals for UV / scale | ❌ Evaluated — rejected | benchmarked neutral (`emit_div` vs `emit_hoisted`) |

Both rejected items targeted **Phase 3 (`emitGlyphsToScene`)**. Benchmarking the
phase in isolation (new `emit_div` / `emit_hoisted` pairing in `bench-text`)
showed it is **memory-store-bound** — one 80-byte `GlyphInstance` write per glyph
at ~3.1 ns/glyph on Apple Silicon. The proposed arithmetic and insert-batching
changes did not move that floor, so Phase 3 was left as the simple per-glyph
emit. See enhancements 5 and 6 for the measured results.

> **Key finding.** At ~3.1 ns/glyph the emit loop is bottlenecked on the store,
> not on the four UV divisions or the per-glyph `insertGlyphClipped` bookkeeping.
> Replacing divisions with hoisted multiplies needs a per-glyph
> `atlas_size == run_constant` guard for correctness (the atlas can grow
> mid-resolve), and that guard branch cost **more** (~+0.5 ns/glyph) than the
> divisions saved. Batching the scene insert via a temp buffer doubled the
> per-glyph memory traffic (regressed ~2×); an inline single-pass batch landed
> back at parity. Net: no win, so no change shipped.

## Context

The `shapeTextInto` optimization eliminated heap allocation on the warm (cache-hit) shaping path, yielding 38–518× speedups over the GPA path. With enhancements 1–4 landed, the remaining `renderText` cost was _expected_ to be concentrated in **Phase 3 per-glyph emission** (scene insertion + UV/scale arithmetic). Benchmarking that phase in isolation (enhancements 5 & 6 below) instead showed it is **memory-store-bound and already at its floor** — the proposed micro-opts were neutral and not shipped.

This document catalogs the opportunities identified by auditing the hot path end-to-end, and — for the two Phase-3 items — records the benchmark evidence for why they were evaluated and rejected rather than landed.

---

## Current Hot Path Profile (per `renderText` call, 50-char string)

Reflects the pipeline **after** enhancements 1–4. The `← Phase 3` lines were the
candidate targets for enhancements 5 and 6; both were measured neutral and not
changed (see Status) — the emit loop is memory-store-bound at ~3.1 ns/glyph.

```
shapeTextInto          ~23 ns   ✅ optimized (stack buffer, owned=false)
├─ mutex lock/unlock    1×
├─ cache lookup         1×
└─ memcpy glyphs        1×

Phase 1: positions     ~50× computeGlyphDevicePositions  (pure, no lock)

Phase 2: glyph resolve ~1 lock + 50× cache.getOrRenderSubpixel  ✅ #1, #2, #3
├─ mutex lock/unlock    1×   (was 50× — batched by resolveGlyphBatch)
├─ GlyphKey.hash()      50×  (packed u64, 2 mixes — was 15 FNV multiplies)
├─ hash table probe     50×
└─ putInCache (miss)    O(1) free-list pop  (was O(N) linear scan)

Phase 3: emit          ~50× emitGlyphsToScene   ← memory-store-bound (~3.1 ns/glyph)
├─ cached.uv()          50×  (4 float divisions by atlas_size)   ← #6 (neutral: overlaps store)
├─ /scale_factor        50× ×3  (width, height, x/y snap)        ← #6 (neutral)
└─ insertGlyphClipped   50×  (currentClip + capacity + stats each) ← #5 (neutral: at memory floor)
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

**Implemented.** `TextSystem.resolveGlyphBatch` takes the whole shaped run plus a
slice of per-glyph subpixel offsets, acquires `glyph_cache_mutex` once, and fills
a caller-provided `[]CachedGlyph` — one lock/unlock for the entire run. `renderText`
(`render.zig`) calls it as Phase 2 between the lock-free position pass (Phase 1)
and the lock-free scene emit (Phase 3). The benchmark gates the win directly:
`glyph_warm_batch` (4.66 ns/glyph) vs `glyph_warm_perglyph` (9.23 ns/glyph) —
~2× / −49% on the same working set.

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

**Implemented.** `cache.zig` `GlyphKey.hash` now packs the non-pointer fields
(`glyph_id | size_fixed | scale_fixed | subpixel_x | subpixel_y`) into a single
`u64` and mixes it with the pointer in two multiply rounds — the byte-by-byte
FNV-1a chain is retired. The source comment notes the pack and pointer loads
are independent, so the two multiplies pipeline. Covered by `glyph_warm_*`.

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

**Implemented.** `cache.zig` carries `free_chain: [MAX_CACHED_GLYPHS]u16` and a
`next_free` head; `initFreeList` chains every slot at init and `putInCache` pops
the head — O(1), no scan. A load-bearing invariant is documented inline: any path
that sets `entry.valid = false` must push the slot back onto the list, or it
leaks until `clear()`. Today only bulk `clear()` / `initFreeList` rebuild the
list (no individual eviction path exists), and `init`/`clear` assert
`next_free == 0`. The cold-path benchmark to watch is `glyph_raster_cold`.

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

**Implemented (as a three-phase split, not two).** `renderText` (`render.zig`) is
now `computeGlyphDevicePositions` (Phase 1, pure: positions + subpixel offsets
from primitive args) → `resolveGlyphBatch` (Phase 2, under the lock) →
`emitGlyphsToScene` (Phase 3, no lock). The split is cleaner than the two-phase
sketch here: position computation moved _out_ of the locked phase entirely, so
the lock covers only cache lookups. Phase 3 is `emitGlyphsToScene` — which is
exactly where the two remaining open items (5, 6) live.

---

## Enhancement 5: Scene Batch Glyph Insertion

**Impact: MEDIUM (estimated) → none (measured). Status: ❌ Evaluated — rejected.**

> **Evaluated — rejected.** Two batched designs were prototyped and benchmarked
> against the per-glyph emit over identical resolved-glyph inputs:
>
> - **Temp-buffer batch** (build N `GlyphInstance`s into a stack chunk, then
>   `insertGlyphsClippedBatch`): **regressed ~2×** (2.8 → 5.0 ns/glyph). The
>   build-then-copy doubles the per-glyph memory traffic, and the emit loop is
>   memory-store-bound, so the extra 80-byte pass dominates any amortization.
> - **Inline single-pass batch** (reserve once, hoist clip/stats, append
>   directly): landed at **parity** with the per-glyph path (~3.0 vs ~3.1
>   ns/glyph — within noise). `insertGlyphClipped` is already at the memory
>   floor: `currentClip()` on an empty clip stack is trivial, the capacity
>   assert is compiled out in release, and the stats branch is predictable.
>
> Neither beat per-glyph insertion, so no batch API was added to `scene.zig` and
> `emitGlyphsToScene` keeps its per-glyph `insertGlyphClipped` /
> `insertGlyphWithOrder` calls. The `emit_div` benchmark gates the phase against
> future regressions. The original problem analysis below is retained for context.

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

## Enhancement 6: Precompute Run-Constant Reciprocals (UV + scale)

**Impact: LOW–MEDIUM (estimated) → none (measured). Status: ❌ Evaluated — rejected.**

> **Evaluated — rejected.** Isolated with the `emit_div` (per-glyph divisions) vs
> `emit_hoisted` (run-constant reciprocals hoisted, multiplies) benchmark pairing
> over identical inputs and the same insert path. Result, 3 runs on Apple
> Silicon: **3.1 ns/glyph either way** — the multiplies are _not_ faster. The
> emit loop is memory-store-bound (one 80-byte `GlyphInstance`/glyph), so the
> four independent UV divisions overlap with the store and never reach the
> critical path.
>
> Worse, hoisting is not free of correctness cost: the atlas can grow _during_
> `resolveGlyphBatch`, leaving earlier `CachedGlyph` copies with a stale
> `atlas_size`, so a hoisted `1/atlas_size` reciprocal is only valid behind a
> per-glyph `cached.atlas_size == run_constant` guard. That guard branch measured
> **~+0.5 ns/glyph** — a net regression. `emitGlyphsToScene` therefore keeps the
> straightforward per-glyph `cached.uv()` / `/scale_factor` form, and no
> `uvFast` helper was added. The analysis below is retained for context.

### Problem (part A: atlas size)

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

### Problem (part B: scale factor — un-doc'd until now)

The original doc only caught the UV divisions. Auditing the _current_
`emitGlyphsToScene` surfaced the same class of bug three more times in the same
loop — every glyph divides by `scale_factor`, a `renderText` parameter that is
constant for the entire run:

```zig
// render.zig — emitGlyphsToScene, per glyph
const glyph_width  = @as(f32, @floatFromInt(cached.region.width))  / scale_factor;
const glyph_height = @as(f32, @floatFromInt(cached.region.height)) / scale_factor;
const glyph_x = (@floor(device_x) + @as(f32, @floatFromInt(cached.offset_x))) / scale_factor;
const glyph_y = (@floor(device_y) - @as(f32, @floatFromInt(cached.offset_y))) / scale_factor;
```

That is ~3–4 divisions/glyph (the `glyph_x`/`glyph_y` pair shares the same
denominator), all by a value fixed before the loop starts. Hoist a single
`const inverse_scale_factor = 1.0 / scale_factor;` and multiply — same fix, same
loop, same run-constant-denominator invariant to assert.

### Estimated savings

~20–50 ns per text run (50 chars) for the UV divisions, plus a comparable amount
for the scale-factor divisions — together the largest pure-arithmetic win left in
the emit loop. Trivial to implement; pairs naturally with Enhancement 5 (both
rewrite the same loop).

---

## Recommended Implementation Order

| #   | Enhancement              | Est. Savings (50 chars) | Measured        | Complexity | Status                  |
| --- | ------------------------ | ----------------------- | --------------- | ---------- | ----------------------- |
| 1   | Batch mutex lock         | ~500–2000 ns            | ~2× on lock     | Medium     | ✅ Implemented          |
| 2   | Faster GlyphKey hash     | ~200–400 ns             | within hash     | Low        | ✅ Implemented          |
| 3   | Free list for putInCache | O(N)→O(1) cold          | O(1) insert     | Low        | ✅ Implemented          |
| 4   | Hot loop extraction      | ~5–15% inner loop       | structural      | Medium     | ✅ Implemented          |
| 5   | Scene batch insert       | ~100–300 ns             | **0 (neutral)** | Low        | ❌ Evaluated — rejected |
| 6   | Run-constant reciprocals | ~40–100 ns              | **0 (neutral)** | Trivial    | ❌ Evaluated — rejected |

**1–4 are landed.** They covered the lock, the hash, the cold-path insert scan,
and the loop structure — the shaping and glyph-resolve phases are now optimized.

**5 and 6 were the proposed remaining work, both in the Phase 3
`emitGlyphsToScene` loop.** Implementing and benchmarking them showed the loop
is already at its memory-store floor (~3.1 ns/glyph), so neither produced a
measurable win and both were rejected rather than shipped as dead complexity.
The estimates in the table above were derived from instruction counting and did
not account for the loop being memory-bound — the divisions overlap with the
80-byte store, and the per-glyph insert is already minimal.

### Outcome (remaining work)

Enhancements 1–4 banked the bulk of the original ~1000–3000 ns estimate (the
batch mutex lock alone was roughly half). The expected further ~150–400 ns from
5 + 6 did **not** materialize: Phase 3 is memory-bound, so the arithmetic and
insert-batching micro-opts are neutral. The pipeline's remaining cost lives in
shaping and glyph resolution (Phases 1–2) and the unavoidable per-glyph store,
not in Phase 3 bookkeeping. Future text-rendering wins should target reducing
the number of glyphs emitted (culling, caching whole runs) rather than shaving
the already-minimal per-glyph emit.

---

## Benchmarking Plan

What the `bench-text` suite already covers (landed work), and what still needs an
entry to gate the open items:

- **#1 — covered.** `benchGlyphRasterWarmPerGlyph` (`glyph_warm_perglyph`) vs
  `benchGlyphRasterWarmBatch` (`glyph_warm_batch`) is the per-glyph-lock vs
  batch-lock comparison, on the same working set — `bench-compare` gates the gap.
- **#2 — covered.** `benchGlyphRasterWarm` / `benchGlyphRasterWarmSubpixel`
  (`glyph_warm_ascii_x20`, `glyph_warm_subpixel_ascii_x5`) exercise the packed
  hash. A standalone hash-distribution test is still worth adding.
- **#3 — covered.** `benchGlyphRasterCold` (`glyph_raster_cold_ascii`) is where the
  insert dominates; the free-list pop replaced the O(N) scan there.
- **#4 — covered.** `benchRenderText` (`render_text_{short,medium,long}`) measures
  the three-phase split end-to-end.
- **#5, #6 — covered, and the gate is what rejected them.** `benchEmitGlyphsDiv`
  (`emit_div_ascii_x20`) and `benchEmitGlyphsHoisted` (`emit_hoisted_ascii_x20`)
  isolate Phase 3 on identical resolved-glyph inputs and the same insert path,
  differing only in arithmetic (per-glyph divisions vs hoisted reciprocals) —
  mirroring the `glyph_warm_perglyph` vs `glyph_warm_batch` pairing. Both land at
  **~3.1 ns/glyph (p50)**, which is the evidence that Phase 3 is memory-store-
  bound and the micro-opts are neutral. `bench-compare` now gates the phase
  against regressions, and the pairing stands as the recorded rationale for not
  shipping 5/6.

### How to reproduce

```
zig build bench-text          # prints the "Phase 3 Emit" section
zig build bench-text -Dbench-json-dir=out   # JSON for bench-compare
```

Note on methodology: the `emit_hoisted` candidate is benchmarked as a
bench-local function structurally identical to the shipping per-glyph emit
except for the arithmetic. Calling the real `emitGlyphsToScene` across the bench
module boundary instead measures non-inlined call overhead (it inlines into
`renderText` within its own module), which masks the arithmetic signal — an
earlier iteration of this benchmark made exactly that mistake and reported a
spurious 2× "regression."
